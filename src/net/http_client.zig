//! HTTP 客户端模块
//!
//! 封装 Zig 标准库的 HTTP 客户端能力，为网络音频流播放提供基础的网络请求支持。
//! 在整体架构中，本模块位于网络层底层，被 `streaming.zig` 调用来获取远程音频资源。
//!
//! 核心设计决策：使用 `std.Io.Threaded` 实现线程化 I/O，确保网络读写不阻塞调用线程。
//! 由于 `Threaded.io()` 捕获的是结构体指针，HttpClient 必须在堆上分配以保持地址稳定。

const std = @import("std");

/// HTTP 客户端，封装线程化 I/O 与标准库 HTTP 客户端。
///
/// 采用堆分配而非栈分配，因为 `std.Io.Threaded.io()` 内部持有指向 `Threaded` 的指针，
/// 如果结构体在栈上，函数返回后指针将悬空。
pub const HttpClient = struct {
    /// 内存分配器，用于创建和销毁 HttpClient 实例自身
    allocator: std.mem.Allocator,
    /// 线程化 I/O 运行时，在后台线程中执行实际的网络 I/O 操作，
    /// 使调用方无需自行管理异步事件循环
    threaded_io: std.Io.Threaded,
    /// Zig 标准库 HTTP 客户端，依赖上述 threaded_io 提供的 I/O 接口
    client: std.http.Client,

    /// 在堆上创建 HttpClient 实例。
    ///
    /// 调用方拥有返回指针的所有权，使用完毕后必须调用 `destroy` 释放。
    /// 必须使用堆分配的原因：`std.Io.Threaded.io()` 捕获了 `Threaded` 结构体的指针，
    /// 该指针在后续所有 HTTP 操作中都会被使用，因此 `Threaded` 必须位于稳定地址。
    ///
    /// 参数：
    ///   `allocator` - 用于分配 HttpClient 内存的分配器
    ///
    /// 返回：指向新创建的 HttpClient 的指针
    pub fn create(allocator: std.mem.Allocator) !*HttpClient {
        const self = try allocator.create(HttpClient);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            // Threaded.init 可能失败（例如线程创建失败），这里用默认配置
            .threaded_io = std.Io.Threaded.init(allocator, .{}),
            .client = .{
                .allocator = allocator,
                // io() 返回的接口内部持有指向 threaded_io 的指针，
                // 这就是为什么 self 必须在堆上：保证指针在整个生命周期内有效
                .io = self.threaded_io.io(),
            },
        };
        return self;
    }

    /// 销毁 HttpClient 实例，释放所有关联资源。
    ///
    /// 释放顺序很重要：先释放 client（它会使用 threaded_io 的 I/O 接口），
    /// 再释放 threaded_io 本身，最后销毁 self 结构体。逆序释放会导致悬空指针。
    pub fn destroy(self: *HttpClient) void {
        const alloc = self.allocator;
        // 先 deinit client，它可能仍在使用 threaded_io 的 I/O 接口
        self.client.deinit();
        // 再 deinit I/O 运行时，停止后台线程并释放线程资源
        self.threaded_io.deinit();
        // 最后销毁结构体自身
        alloc.destroy(self);
    }

    /// 通过 HEAD 请求获取指定 URL 的内容长度（Content-Length）。
    ///
    /// 设计意图：在正式下载音频流之前，先用 HEAD 请求探测资源大小。
    /// 这样 streaming 模块就能预分配完整缓冲区，避免动态扩容的开销。
    /// HEAD 请求只返回头部而不传输正文，开销极小。
    ///
    /// 这是一个独立的便利函数，内部自行创建和销毁临时 HttpClient，
    /// 不依赖调用方管理生命周期。
    ///
    /// 参数：
    ///   `url` - 目标资源的完整 URL
    ///
    /// 返回：
    ///   `?usize` - Content-Length 值，如果服务器未提供则为 null
    ///   失败时返回 HttpError
    pub fn headContentLength(url: []const u8) !?usize {
        // 使用系统级多线程安全分配器，因为此函数是自包含的临时操作
        const allocator = std.heap.smp_allocator;
        var http = try create(allocator);
        defer http.destroy();

        // URL 解析失败视为 HTTP 错误，调用方无需区分解析错误和网络错误
        const uri = std.Uri.parse(url) catch return error.HttpError;
        var req = try http.client.request(.HEAD, uri, .{});
        defer req.deinit();

        // HEAD 请求没有请求体
        try req.sendBodiless();

        // 重定向缓冲区：用于处理 HTTP 重定向时的临时存储
        var redirect_buf: [4096]u8 = undefined;
        const response = try req.receiveHead(&redirect_buf);

        // 非 2xx 响应统一返回 HttpError
        if (response.head.status.class() != .success) return error.HttpError;

        // Content-Length 可能不存在（如分块传输编码），此时返回 null
        return if (response.head.content_length) |cl| @intCast(cl) else null;
    }
};
