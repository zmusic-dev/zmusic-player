//! # ZMusic Player CLI 入口
//!
//! 命令行界面的入口模块，负责：
//! - 解析命令行参数（`play` 命令 + `--lyrics` 选项）
//! - 创建 Player 实例并启动播放
//! - 实时显示播放进度和歌词
//!
//! ## 使用方式
//! ```sh
//! zmusic-player play <URL或路径> [--lyrics <LRC文件路径>]
//! ```

const std = @import("std");
const builtin = @import("builtin");
const player_mod = @import("player.zig");
const Player = player_mod.Player;
const PlaybackState = player_mod.PlaybackState;
const ma = @import("miniaudio");
const platform = @import("platform");
const HttpClient = @import("net/http_client.zig").HttpClient;

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;

    // Windows 控制台初始化：设置 UTF-8 代码页和 ANSI 转义序列支持
    platform.initWindowsConsole();

    var iter = if (builtin.os.tag == .windows)
        try std.process.Args.Iterator.initAllocator(init.args, allocator)
    else
        init.args.iterate();
    defer iter.deinit();

    var args_list = std.array_list.Managed([]const u8).init(allocator);
    defer args_list.deinit();
    while (iter.next()) |arg| {
        try args_list.append(arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printHelp();
        return;
    }

    if (!std.mem.eql(u8, command, "play")) {
        std.debug.print("未知命令: {s}\n", .{command});
        return;
    }

    if (args.len < 3) {
        std.debug.print("错误: play 命令需要一个 URL 或文件路径\n", .{});
        return;
    }

    const source = args[2];

    // 解析可选参数
    var lyrics_path: ?[]const u8 = null;
    var volume_pct: u8 = 20;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--lyrics")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("错误: --lyrics 需要指定歌词文件路径\n", .{});
                return;
            }
            lyrics_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--volume")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("错误: --volume 需要指定音量 (0-100)\n", .{});
                return;
            }
            const vol = std.fmt.parseInt(u8, args[i], 10) catch {
                std.debug.print("错误: --volume 参数无效 (需要 0-100 整数)\n", .{});
                return;
            };
            volume_pct = vol;
        }
    }

    var p = try Player.init(allocator);
    defer p.deinit();
    p.setVolume(@as(f32, @floatFromInt(volume_pct)) / 100.0);

    // 加载歌词（如果指定），支持本地文件和 HTTP(S) URL
    var has_lyrics = false;
    if (lyrics_path) |path| {
        const is_url = std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://");
        const lrc_raw: []u8 = result: {
            if (is_url) {
                break :result downloadContent(allocator, path) catch |err| {
                    std.debug.print("无法下载歌词 '{s}': {}\n", .{ path, err });
                    return;
                };
            } else {
                break :result readFileAlloc(allocator, path) catch |err| {
                    std.debug.print("无法加载歌词文件 '{s}': {}\n", .{ path, err });
                    return;
                };
            }
        };
        defer allocator.free(lrc_raw);
        // GBK 等非 UTF-8 编码的歌词需要转换为 UTF-8
        const lrc_utf8 = platform.ensureUtf8(allocator, lrc_raw) catch lrc_raw;
        defer if (lrc_utf8.ptr != lrc_raw.ptr) allocator.free(lrc_utf8);
        p.loadLyrics(lrc_utf8) catch |err| {
            std.debug.print("歌词解析失败: {}\n", .{err});
            return;
        };
        has_lyrics = true;
    }

    std.debug.print("正在播放: {s}\n", .{source});
    if (has_lyrics) {
        std.debug.print("歌词已加载: {s}\n", .{lyrics_path.?});
    }

    p.play(source) catch |err| {
        std.debug.print("错误: {}\n", .{err});
        return;
    };

    // 进入终端原始模式：关闭行缓冲和回显，支持非阻塞按键读取
    platform.enterRawMode() catch {};
    defer platform.restoreTerminal();

    // 主显示循环
    // 固定 3 行显示区，全部用 \r + 光标上移原地刷新：
    //   第 1 行：进度条
    //   第 2 行：播放状态 + 时间 + 音量 + 歌词
    //   第 3 行：控制提示
    var last_position_ms: u64 = 0;
    var stall_count: u32 = 0;
    var seek_cooldown: u32 = 0;
    var display_started = false;

    while (p.getState() == .playing or p.getState() == .paused) {
        // 键盘控制
        if (platform.readKey()) |key| {
            switch (key) {
                .space => {
                    if (p.getState() == .playing) {
                        p.pause() catch {};
                    } else if (p.getState() == .paused) {
                        p.@"resume"() catch {};
                    }
                },
                .q => {
                    p.stop();
                    break;
                },
                .left => {
                    const prog = p.getProgress();
                    p.seek(if (prog.position_ms > 5000) prog.position_ms - 5000 else 0) catch {};
                    seek_cooldown = 2;
                },
                .right => {
                    const prog = p.getProgress();
                    const target = prog.position_ms + 5000;
                    if (target < prog.duration_ms) p.seek(target) catch {};
                    seek_cooldown = 2;
                },
                .up => {
                    p.setVolume(p.getVolume() + 0.1);
                },
                .down => {
                    p.setVolume(p.getVolume() - 0.1);
                },
                .unknown => {},
            }
        }

        if (p.getState() == .playing) {
            const snd = p.sound orelse break;
            const progress = p.getProgress();

            if (ma.ma_sound_at_end(snd) != 0 and progress.position_ms > 1000) {
                if (p.on_track_ended) |cb| cb();
                break;
            }

            if (seek_cooldown > 0) {
                seek_cooldown -= 1;
                stall_count = 0;
                last_position_ms = progress.position_ms;
            } else {
                if (progress.position_ms == last_position_ms) {
                    stall_count += 1;
                    if (stall_count >= 15) break;
                } else {
                    stall_count = 0;
                }
                last_position_ms = progress.position_ms;
            }
        }

        // ---- 重绘 3 行显示区 ----
        const progress = p.getProgress();
        const lyric_line = p.getCurrentLyric();

        // 第 1 行：进度条（亚字符精度，使用 Unicode 左侧分块字符）
        const pct_f32: f32 = if (progress.duration_ms > 0)
            @as(f32, @floatFromInt(progress.position_ms)) / @as(f32, @floatFromInt(progress.duration_ms))
        else
            0;
        const bar_width: usize = 40;
        const sub_blocks = [8][]const u8{ "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" };
        const total_sub: i32 = @intFromFloat(pct_f32 * @as(f32, @floatFromInt(bar_width * 8)));
        var bar_buf: [256]u8 = undefined;
        var bar_len: usize = 0;
        const prefix = "进度：[";
        @memcpy(bar_buf[0..prefix.len], prefix);
        bar_len = prefix.len;
        for (0..bar_width) |j| {
            const sub: i32 = total_sub - @as(i32, @intCast(j * 8));
            if (sub >= 8) {
                const ch = "█";
                @memcpy(bar_buf[bar_len .. bar_len + ch.len], ch);
                bar_len += ch.len;
            } else if (sub > 0) {
                const ch = sub_blocks[@intCast(sub - 1)];
                @memcpy(bar_buf[bar_len .. bar_len + ch.len], ch);
                bar_len += ch.len;
            } else {
                bar_buf[bar_len] = ' ';
                bar_len += 1;
            }
        }
        bar_buf[bar_len] = ']';
        bar_len += 1;
        // 用空格填满行尾，覆盖上一帧可能残留的字符
        @memset(bar_buf[bar_len .. bar_len + 20], ' ');
        bar_len += 20;
        const bar_slice = bar_buf[0..bar_len];

        // 第 2 行：播放状态 + 时间 + 音量 + 歌词
        const state_icon = switch (p.getState()) {
            .playing => "▶",
            .paused => "⏸",
            else => "■",
        };
        const pos_min = progress.position_ms / 60000;
        const pos_sec = (progress.position_ms % 60000) / 1000;
        const dur_min = progress.duration_ms / 60000;
        const dur_sec = (progress.duration_ms % 60000) / 1000;
        const vol_pct = @as(u32, @intFromFloat(p.getVolume() * 100));

        var line2_buf: [512]u8 = undefined;
        const line2 = std.fmt.bufPrint(&line2_buf, "{s} {d:0>2}:{d:0>2}/{d:0>2}:{d:0>2}", .{
            state_icon, pos_min, pos_sec, dur_min, dur_sec,
        }) catch "";

        // 第 3 行：控制提示
        const help_text = "Space:暂停/播放  q:退出  ←→:快退/快进  ↑↓:音量";

        // 拼接完整的 3 行内容，一次性输出避免闪烁
        var frame_buf: [1024]u8 = undefined;
        var frame_len: usize = 0;
        // 辅助：追加字节到 frame_buf
        const appendBuf = struct {
            fn append(buf: []u8, len: *usize, data: []const u8) void {
                @memcpy(buf[len.* .. len.* + data.len], data);
                len.* += data.len;
            }
        }.append;
        // 辅助：追加填充空格
        const appendPad = struct {
            fn pad(buf: []u8, len: *usize, n: usize) void {
                @memset(buf[len.* .. len.* + n], ' ');
                len.* += n;
            }
        }.pad;

        // \r 回到行首覆写第 1 行
        appendBuf(&frame_buf, &frame_len, "\r");
        appendBuf(&frame_buf, &frame_len, bar_slice);
        appendBuf(&frame_buf, &frame_len, "\n\r");
        appendBuf(&frame_buf, &frame_len, line2);
        if (vol_pct != 100) {
            const vol_str = std.fmt.bufPrint(line2_buf[line2.len..], " vol:{d:0>2}%", .{vol_pct}) catch "";
            appendBuf(&frame_buf, &frame_len, vol_str);
        }
        if (lyric_line) |l| {
            appendBuf(&frame_buf, &frame_len, "  ");
            appendBuf(&frame_buf, &frame_len, l.text);
        }
        appendPad(&frame_buf, &frame_len, 20);
        appendBuf(&frame_buf, &frame_len, "\n\r");
        appendBuf(&frame_buf, &frame_len, help_text);
        appendPad(&frame_buf, &frame_len, 20);
        appendBuf(&frame_buf, &frame_len, "\n\x1b[3A");

        std.debug.print("{s}", .{frame_buf[0..frame_len]});

        display_started = true;
        platform.sleepMs(200);
    }

    if (display_started) std.debug.print("\n", .{});
}

fn printUsage() void {
    std.debug.print("用法: zmusic-player <命令> [参数...]\n", .{});
    std.debug.print("命令:\n", .{});
    std.debug.print("  play <URL或路径>  播放 URL 或本地音频文件\n", .{});
    std.debug.print("  --help            显示帮助信息\n", .{});
}

fn printHelp() void {
    std.debug.print("ZMusic Player - 网络音频播放器\n\n", .{});
    std.debug.print("用法: zmusic-player play <URL或路径> [--lyrics <LRC文件路径>] [--volume <0-100>]\n\n", .{});
    std.debug.print("选项:\n", .{});
    std.debug.print("  --lyrics <路径>      加载 LRC 格式歌词文件\n", .{});
    std.debug.print("  --volume <0-100>     设置初始音量百分比，默认 20\n\n", .{});
    std.debug.print("播放控制:\n", .{});
    std.debug.print("  Space   播放 / 暂停\n", .{});
    std.debug.print("  q       停止并退出\n", .{});
    std.debug.print("  ←/→     快退/快进 5 秒\n", .{});
    std.debug.print("  ↑/↓     音量增减 10%\n", .{});
}

/// 通过 HTTP 下载 URL 内容到堆分配的缓冲区。
///
/// 使用项目已有的 HttpClient 进行网络请求，通过 BufferWriter 将
/// HTTP 响应体捕获到 ArrayList 中。歌词文件通常很小（< 100KB），
/// 整体下载后一次性返回。
fn downloadContent(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var http = try HttpClient.create(allocator);
    defer http.destroy();

    var bw = BufferWriter{
        .list = std.array_list.Managed(u8).init(allocator),
        .staging = undefined,
        .writer = undefined,
    };
    bw.writer = std.Io.Writer{
        .vtable = &.{
            .drain = BufferWriter.drainFn,
            .flush = BufferWriter.flushFn,
            .rebase = BufferWriter.rebaseFn,
        },
        .buffer = bw.staging[0..],
    };
    errdefer {
        bw.list.deinit();
    }

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);

    _ = http.client.fetch(.{
        .location = .{ .url = url_z },
        .response_writer = &bw.writer,
    }) catch return error.HttpError;

    // 刷出 Writer 缓冲区中残留的数据
    if (bw.writer.end > 0) {
        try bw.list.appendSlice(bw.writer.buffer[0..bw.writer.end]);
        bw.writer.end = 0;
    }

    const result = try bw.list.toOwnedSlice();
    return result;
}

/// 简易 Writer 实现，将 HTTP 响应数据累积到 ArrayList。
///
/// 参考 streaming.zig 中 StreamingWriter 的设计，但面向小文件场景简化了实现：
/// 数据先写入 staging 暂存区，满后批量提交到 ArrayList。
const BufferWriter = struct {
    /// 数据累积目标，最终通过 toOwnedSlice 获取完整响应体
    list: std.array_list.Managed(u8),
    /// 8KB 暂存区，作为 Writer 的底层缓冲区
    staging: [8192]u8,
    /// 标准库 Writer 接口，供 HTTP 客户端写入响应数据
    writer: std.Io.Writer,

    /// Writer.drain 回调：暂存区满时触发，将数据批量写入 list。
    /// 此时 staging 中的数据已在 commit 中刷出，剩余数据直接追加到 list。
    fn drainFn(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = splat;
        const self: *BufferWriter = @alignCast(@fieldParentPtr("writer", w));
        self.commit();
        var total: usize = 0;
        for (data) |bytes| {
            self.list.appendSlice(bytes) catch return error.WriteFailed;
            total += bytes.len;
        }
        return total;
    }

    /// Writer.flush 回调：将暂存区中残留的数据刷出到 list。
    fn flushFn(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *BufferWriter = @alignCast(@fieldParentPtr("writer", w));
        self.commit();
    }

    /// Writer.rebase 回调：暂存区需要重新分配时触发。
    /// 小文件场景下不支持保留数据（preserve > 0 视为错误）。
    fn rebaseFn(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        _ = capacity;
        const self: *BufferWriter = @alignCast(@fieldParentPtr("writer", w));
        self.commit();
        if (preserve > 0) return error.WriteFailed;
    }

    /// 将暂存区中已写入的数据批量提交到 list，并重置暂存区。
    fn commit(self: *BufferWriter) void {
        if (self.writer.end == 0) return;
        self.list.appendSlice(self.writer.buffer[0..self.writer.end]) catch return;
        self.writer.end = 0;
    }
};
/// 通过 C 标准库文件 I/O 读取本地文件到堆分配的缓冲区。
///
/// 使用 extern 声明直接调用 C 标准库函数（项目已链接 libc），
/// 避免 Zig 0.16.0 I/O 子系统复杂的初始化流程。
/// 限制最大 10MB，防止意外读取过大文件。
///
/// 参数：
///   allocator - 用于分配文件内容缓冲区的分配器
///   path      - 文件路径（不需要以 null 结尾）
///
/// 返回：文件内容的堆分配切片，调用方负责释放。
/// 错误：FileNotFound（文件不存在/为空/大小获取失败）、FileTooBig（超过 10MB）。
fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const max_size: usize = 10 * 1024 * 1024;

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const file = c_fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = c_fclose(file);

    _ = c_fseek(file, 0, c_SEEK_END);
    const file_size = c_ftell(file);
    _ = c_fseek(file, 0, c_SEEK_SET);
    if (file_size < 0) return error.FileNotFound;
    const size: usize = @intCast(file_size);
    if (size > max_size) return error.FileTooBig;
    if (size == 0) return error.FileNotFound;

    const buf = try allocator.alloc(u8, size);
    const read_bytes = c_fread(buf.ptr, 1, size, file);
    return buf[0..read_bytes];
}

/// C 标准库文件 I/O 常量和函数声明。
/// 通过 @extern 直接链接 libc，用于 readFileAlloc 中避免依赖 Zig I/O 子系统。
const c_SEEK_END: c_int = 2;
const c_SEEK_SET: c_int = 0;
/// 打开文件，返回 FILE* 句柄（失败返回 null）
const c_fopen = @extern(*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque, .{ .name = "fopen" });
/// 关闭文件句柄
const c_fclose = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "fclose" });
/// 设置文件读写位置
const c_fseek = @extern(*const fn (?*anyopaque, c_long, c_int) callconv(.c) c_int, .{ .name = "fseek" });
/// 获取当前文件读写位置（用于计算文件大小）
const c_ftell = @extern(*const fn (?*anyopaque) callconv(.c) c_long, .{ .name = "ftell" });
/// 从文件读取数据到缓冲区
const c_fread = @extern(*const fn (?*anyopaque, usize, usize, ?*anyopaque) callconv(.c) usize, .{ .name = "fread" });
