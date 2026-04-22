//! 网络流式播放模块
//!
//! 实现音频"边下边播"的核心机制：后台线程持续下载 HTTP 音频流写入共享缓冲区，
//! miniaudio 解码器通过回调从同一缓冲区读取数据进行播放。
//!
//! 架构概览：
//!   1. `StreamingSource` — 管理共享缓冲区和下载线程的生命周期
//!   2. `StreamingWriter` — 自定义 Writer，将 HTTP 响应数据桥接到共享缓冲区
//!   3. `decoderReadCallback` / `decoderSeekCallback` — miniaudio C 回调，实现生产者-消费者读取模式
//!
//! 线程安全保证：
//!   - `write_pos` 和 `download_done` 使用原子变量，确保下载线程与音频解码线程之间的同步
//!   - `read_offset` 仅在解码线程中访问（miniaudio 回调是单线程的），无需原子操作
//!   - 缓冲区以"只追加写入、只前移读取"的方式使用，避免数据竞争

const std = @import("std");
const ma = @import("miniaudio");
const HttpClient = @import("http_client.zig").HttpClient;
const platform = @import("platform");

/// 流式音频源，管理"边下边播"所需的全部状态。
///
/// 核心数据流：HTTP 下载线程 → data 缓冲区 → miniaudio 解码回调
/// 下载线程通过 `write_pos` 原子变量公布已写入的数据量，
/// 解码回调通过 `read_offset` 追踪已读取的位置。
pub const StreamingSource = struct {
    /// 内存分配器，用于释放 data 缓冲区和 self 结构体
    allocator: std.mem.Allocator,
    /// 预分配的完整音频数据缓冲区，大小等于 content_length。
    /// 一次性分配避免了动态扩容带来的数据搬移和锁开销。
    data: []u8,
    /// 音频资源的总字节数，由 HEAD 请求预先获取
    total_size: usize,
    /// 已写入缓冲区的字节数（生产者端）。
    /// 原子变量确保下载线程与解码线程之间的可见性。
    /// 使用 acquire/release 内存序实现轻量级同步，无需互斥锁。
    write_pos: std.atomic.Value(usize),
    /// 解码器当前读取位置（消费者端）。
    /// 仅在 miniaudio 解码回调中访问，解码回调是单线程的，因此不需要原子操作。
    read_offset: usize,
    /// 下载是否已完成（无论成功或失败）。
    /// 原子变量：解码线程通过检查此标志判断是否到达数据末尾。
    download_done: std.atomic.Value(bool),
    /// 是否已取消下载。deinit 时设置为 true，下载线程在写入路径检测到后
    /// 主动中止，避免 thread.join() 无限等待阻塞在网络 I/O 上的下载线程。
    cancelled: std.atomic.Value(bool),
    /// 下载过程中遇到的错误，供调用方在播放结束后检查
    download_err: ?anyerror,
    /// 后台下载线程句柄，deinit 时通过 join 等待其结束
    thread: std.Thread,

    /// 初始缓冲阈值：至少下载 64KB 后才通知调用方可以开始播放。
    /// 64KB 对于大多数音频格式而言足以包含文件头和若干帧数据，
    /// 能让解码器顺利完成初始化并开始输出音频。
    /// 太小可能导致解码器因数据不足而卡顿，太大会增加首播延迟。
    const INITIAL_BUFFER_SIZE = 64 * 1024;

    /// 启动流式下载，返回就绪的 StreamingSource 指针。
    ///
    /// 流程：分配结构体 → 分配缓冲区 → 拷贝 URL → 启动下载线程。
    /// 如果线程启动失败，会自动回滚所有已分配的资源。
    ///
    /// 参数：
    ///   `allocator`      - 内存分配器
    ///   `url`            - 音频资源的完整 URL
    ///   `content_length` - 资源总字节数，用于预分配缓冲区
    ///
    /// 返回：指向 StreamingSource 的指针，调用方负责调用 `deinit` 释放
    pub fn start(allocator: std.mem.Allocator, url: []const u8, content_length: usize) !*StreamingSource {
        const self = try allocator.create(StreamingSource);
        // 一次性分配整个文件大小的缓冲区，避免后续动态扩容
        const data = try allocator.alloc(u8, content_length);
        self.* = .{
            .allocator = allocator,
            .data = data,
            .total_size = content_length,
            .write_pos = std.atomic.Value(usize).init(0),
            .read_offset = 0,
            .download_done = std.atomic.Value(bool).init(false),
            .cancelled = std.atomic.Value(bool).init(false),
            .download_err = null,
            // thread 稍后赋值；这里用 undefined 是安全的，因为必定会被覆盖
            .thread = undefined,
        };

        // URL 必须复制一份并以 null 结尾（C 字符串），因为下载线程异步使用，
        // 原始 slice 可能在下载完成前就失效
        const url_copy = try allocator.dupeZ(u8, url);
        self.thread = std.Thread.spawn(.{}, downloadWorker, .{ self, url_copy }) catch |err| {
            // 线程启动失败时手动回滚所有已分配资源，保持语义上的异常安全
            allocator.free(data);
            allocator.destroy(self);
            allocator.free(url_copy);
            return err;
        };
        return self;
    }

    /// 等待初始缓冲填充到足够播放的数据量。
    ///
    /// 在将 StreamingSource 交给 miniaudio 解码器之前调用，
    /// 确保解码器首次读取时能获得足够的数据来完成格式探测和初始化。
    /// 使用忙等待（5ms 间隔的 nanosleep），因为等待时间通常很短（取决于网络速度），
    /// 不值得引入条件变量的复杂度。
    pub fn waitInitialBuffer(self: *StreamingSource) void {
        // 目标：至少下载 64KB 或整个文件（当文件小于 64KB 时）
        const target = @min(self.total_size, INITIAL_BUFFER_SIZE);
        while (self.write_pos.load(.acquire) < target and !self.download_done.load(.acquire)) {
            // 短暂休眠避免空转浪费 CPU，5ms 在网络下载场景下是合理的轮询间隔
            platform.sleepMs(5);
        }
    }

    /// 释放 StreamingSource 的所有资源。
    ///
    /// 必须先 join 下载线程，确保下载线程不再访问缓冲区后再释放内存。
    /// 调用此方法后，所有指向该 StreamingSource 的指针都失效。
    pub fn deinit(self: *StreamingSource) void {
        // 设置取消标志，让下载线程在下次写入时主动退出。
        // 如果下载线程正阻塞在网络 I/O 上，它会继续等待数据，
        // 但一旦有数据到来并触发写入回调，就会检测到取消并中止。
        // 同时设置 download_done 防止解码线程永远等待。
        self.cancelled.store(true, .release);
        self.download_done.store(true, .release);
        // 等待下载线程结束。由于 cancelled 标志会导致写入回调返回错误，
        // http.client.fetch() 会因写入失败而提前退出，join 通常很快返回。
        self.thread.join();
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }

    /// 后台下载线程的入口函数。
    ///
    /// 创建临时 HttpClient，通过自定义 StreamingWriter 将 HTTP 响应数据
    /// 流式写入共享缓冲区。下载完成后通过 `download_done` 通知解码线程。
    ///
    /// 设计为独立线程运行，不阻塞主线程和音频线程。
    fn downloadWorker(self: *StreamingSource, url: [:0]const u8) void {
        // url 是 start 中 dupeZ 分配的拷贝，函数结束时释放
        defer self.allocator.free(url);

        var http = HttpClient.create(self.allocator) catch {
            self.download_err = error.HttpError;
            // 即使创建失败也要设置 download_done，否则解码线程会永远等待
            self.download_done.store(true, .release);
            return;
        };
        defer http.destroy();

        // 构建自定义 Writer，桥接 HTTP 响应到共享缓冲区
        var sw = StreamingWriter{
            .source = self,
            // staging 是 Writer 的内部缓冲区，数据先写入这里再 commit 到共享缓冲区
            // 16KB 的暂存区在内存拷贝开销和提交频率之间取得平衡
            .staging = undefined,
            .writer = undefined,
            .committed = 0,
        };
        sw.writer = std.Io.Writer{
            .vtable = &.{
                .drain = StreamingWriter.drainFn,
                .flush = StreamingWriter.flushFn,
                .rebase = StreamingWriter.rebaseFn,
            },
            // staging 数组作为 Writer 的初始缓冲区，Writer 会将数据先写入此缓冲区
            .buffer = sw.staging[0..],
        };

        // fetch 会将整个 HTTP 响应体写入 sw.writer
        _ = http.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &sw.writer,
        }) catch {
            self.download_err = error.HttpError;
            self.download_done.store(true, .release);
            return;
        };

        // 处理 Writer 缓冲区中可能残留的最后一批数据
        if (sw.writer.end > 0) {
            sw.commit();
        }
        // 通知解码线程：数据已全部写入（或下载已结束）
        self.download_done.store(true, .release);
    }

    /// 自定义 Writer 实现，将 HTTP 响应数据桥接到 StreamingSource 的共享缓冲区。
    ///
    /// 为什么需要自定义 Writer 而不直接写入 data？
    /// 标准 HTTP 客户端需要一个 std.Io.Writer 来接收响应体，
    /// 我们通过实现 Writer 虚表方法，将数据从 Writer 内部机制无缝导向共享缓冲区，
    /// 并通过原子变量实时更新 write_pos，让解码线程能感知新数据的到来。
    ///
    /// 数据流：HTTP 响应 → staging 缓冲区 → commit → 共享缓冲区(data)
    const StreamingWriter = struct {
        /// 所属的 StreamingSource，用于访问共享缓冲区和更新 write_pos
        source: *StreamingSource,
        /// Writer 的内部暂存区，数据先写入这里，满后批量 commit 到共享缓冲区
        staging: [16384]u8,
        /// 标准库 Writer 实例，其 vtable 指向本结构体的方法
        writer: std.Io.Writer,
        /// 已确认写入共享缓冲区的字节数，与 writer.end（暂存区中的数据量）配合使用
        committed: usize,

        /// Writer 虚表的 drain 方法。
        ///
        /// 当 Writer 内部缓冲区满时被调用，负责将数据刷新到共享缓冲区。
        /// 处理流程：先 commit 暂存区中的已有数据，再直接写入新传入的数据。
        ///
        /// 参数：
        ///   `w`     - Writer 实例指针（通过 fieldParentPtr 反推出 StreamingWriter）
        ///   `data`  - 待写入的数据片段数组（可能包含多个不连续的缓冲区）
        ///   `splat` - 未使用（Zig Writer 接口要求但本实现不需要）
        fn drainFn(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            _ = splat;
            const sw: *StreamingWriter = @alignCast(@fieldParentPtr("writer", w));

            // 检查取消标志：如果已取消，立即返回错误让 fetch 中止。
            // 这是 deinit → join 能快速返回的关键路径：
            // fetch 收到写入错误后会停止下载，下载线程退出，join 返回。
            if (sw.source.cancelled.load(.acquire)) return error.WriteFailed;

            sw.commit();

            // 然后直接将新数据写入共享缓冲区，跳过暂存区中转
            var total: usize = 0;
            for (data) |bytes| {
                // 防止写入超过预分配的缓冲区大小
                if (sw.committed + total + bytes.len > sw.source.total_size) {
                    // 如果第一批数据就超出范围，返回错误；
                    // 否则停止处理剩余数据，返回已成功写入的部分
                    if (total == 0) return error.WriteFailed;
                    break;
                }
                @memcpy(sw.source.data[sw.committed + total .. sw.committed + total + bytes.len], bytes);
                total += bytes.len;
            }

            sw.committed += total;
            // 更新 write_pos，让解码线程能看到新数据
            sw.source.write_pos.store(sw.committed, .release);
            return total;
        }

        /// Writer 虚表的 flush 方法。
        ///
        /// 将暂存区中所有未提交的数据写入共享缓冲区。
        fn flushFn(w: *std.Io.Writer) std.Io.Writer.Error!void {
            const sw: *StreamingWriter = @alignCast(@fieldParentPtr("writer", w));
            sw.commit();
        }

        /// Writer 虚表的 rebase 方法。
        ///
        /// 当 Writer 需要重新定位缓冲区时调用。在流式下载场景中，
        /// 我们不允许保留未提交的数据（preserve 必须为 0），
        /// 因为所有数据都必须通过 commit 写入共享缓冲区。
        fn rebaseFn(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
            _ = capacity;
            const sw: *StreamingWriter = @alignCast(@fieldParentPtr("writer", w));
            // 先提交暂存区中的数据
            sw.commit();
            // 流式模式下不允许保留未提交的数据，因为这意味着数据丢失了到共享缓冲区的路径
            if (preserve > 0) return error.WriteFailed;
        }

        /// 将暂存区中的数据提交到共享缓冲区。
        ///
        /// 这是数据从 Writer 内部机制进入共享缓冲区的关键路径。
        /// 每次 commit 后立即更新 write_pos，让解码线程能读取到新数据。
        fn commit(sw: *StreamingWriter) void {
            if (sw.writer.end == 0) return;
            const buf = sw.writer.buffer[0..sw.writer.end];
            if (sw.committed + buf.len <= sw.source.total_size) {
                @memcpy(sw.source.data[sw.committed .. sw.committed + buf.len], buf);
                sw.committed += buf.len;
                // 使用 release 内存序确保数据拷贝对解码线程可见
                sw.source.write_pos.store(sw.committed, .release);
            }
            // 重置 Writer 的写入位置，使暂存区可以复用
            sw.writer.end = 0;
        }
    };
};

/// miniaudio 解码器读取回调（消费者端）。
///
/// 实现"边下边播"的核心读取逻辑：解码器请求数据时，从共享缓冲区中
/// 读取已下载的部分。如果数据尚未就绪，返回 MA_BUSY 让解码器稍后重试；
/// 如果下载已完成且数据已全部读取，返回 MA_AT_END。
///
/// 这是典型的生产者-消费者模式：
///   - 生产者：downloadWorker 通过 StreamingWriter 写入 data 并更新 write_pos
///   - 消费者：本函数从 data 读取并推进 read_offset
///
/// 线程安全由 write_pos 的原子操作保证，read_offset 仅在解码线程中访问。
///
/// 参数：
///   `pDecoder`    - miniaudio 解码器指针
///   `pBufferOut`  - 输出缓冲区，用于存放读取到的数据
///   `bytesToRead` - 请求读取的字节数
///   `pBytesRead`  - 输出参数，实际读取到的字节数
///
/// 返回：
///   MA_SUCCESS   - 成功读取数据
///   MA_BUSY      - 数据尚未就绪，解码器应稍后重试
///   MA_AT_END    - 数据已全部读取完毕
///   MA_INVALID_ARGS - 参数无效
pub fn decoderReadCallback(
    pDecoder: [*c]ma.ma_decoder,
    pBufferOut: ?*anyopaque,
    bytesToRead: usize,
    pBytesRead: [*c]usize,
) callconv(.c) c_int {
    const decoder = pDecoder orelse return ma.MA_INVALID_ARGS;
    // 通过 miniaudio 的 pUserData 恢复 StreamingSource 上下文
    const self: *StreamingSource = @ptrCast(@alignCast(decoder.*.pUserData orelse return ma.MA_INVALID_ARGS));
    const out: [*]u8 = @ptrCast(@alignCast(pBufferOut orelse return ma.MA_INVALID_ARGS));

    pBytesRead.* = 0;

    const offset = self.read_offset;
    // acquire 内存序：确保能看到下载线程写入的数据
    const available = self.write_pos.load(.acquire);
    if (offset >= available) {
        // 读取位置追上了写入位置
        if (self.download_done.load(.acquire)) return ma.MA_AT_END;
        // 下载尚未完成，告诉解码器数据暂时不可用，稍后重试
        return ma.MA_BUSY;
    }

    // 只读取已下载的部分，不会超过 write_pos
    const readable = @min(bytesToRead, available - offset);
    @memcpy(out[0..readable], self.data[offset .. offset + readable]);
    self.read_offset = offset + readable;
    pBytesRead.* = readable;
    return ma.MA_SUCCESS;
}

/// miniaudio 解码器定位回调。
///
/// 支持三种定位模式，与标准 C 的 fseek 语义一致：
///   - `ma_seek_origin_start`    : 从文件起始位置偏移
///   - `ma_seek_origin_current`  : 从当前读取位置偏移
///   - `ma_seek_origin_end`      : 从文件末尾偏移（byteOffset 通常为负值）
///
/// 参数：
///   `pDecoder`   - miniaudio 解码器指针
///   `byteOffset` - 偏移量（可正可负）
///   `origin`     - 偏移起点
///
/// 返回：
///   MA_SUCCESS       - 定位成功
///   MA_INVALID_ARGS  - 参数无效或计算结果超出范围
///   MA_NOT_IMPLEMENTED - 不支持的定位模式
pub fn decoderSeekCallback(
    pDecoder: [*c]ma.ma_decoder,
    byteOffset: i64,
    origin: ma.ma_seek_origin,
) callconv(.c) c_int {
    const decoder = pDecoder orelse return ma.MA_INVALID_ARGS;
    const self: *StreamingSource = @ptrCast(@alignCast(decoder.*.pUserData orelse return ma.MA_INVALID_ARGS));

    // 根据不同的定位起点计算绝对偏移量
    const abs_offset: usize = if (origin == ma.ma_seek_origin_start)
        // 从头开始：偏移量必须非负
        if (byteOffset < 0) return ma.MA_INVALID_ARGS else @intCast(byteOffset)
    else if (origin == ma.ma_seek_origin_current)
        // 从当前位置：允许正向或反向偏移，使用溢出检测安全的加法
        std.math.add(usize, self.read_offset, @intCast(byteOffset)) catch return ma.MA_INVALID_ARGS
    else if (origin == ma.ma_seek_origin_end)
        // 从末尾：byteOffset 通常为负值（向前偏移），total_size + byteOffset 得到目标位置
        std.math.add(usize, self.total_size, @intCast(byteOffset)) catch return ma.MA_INVALID_ARGS
    else
        return ma.MA_NOT_IMPLEMENTED;
    // 确保最终位置不超出缓冲区范围
    if (abs_offset > self.total_size) return ma.MA_INVALID_ARGS;
    self.read_offset = abs_offset;
    return ma.MA_SUCCESS;
}
