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
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--lyrics")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("错误: --lyrics 需要指定歌词文件路径\n", .{});
                return;
            }
            lyrics_path = args[i];
        }
    }

    var p = try Player.init(allocator);
    defer p.deinit();

    // 加载歌词（如果指定），支持本地文件和 HTTP(S) URL
    var has_lyrics = false;
    if (lyrics_path) |path| {
        const is_url = std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://");
        const lrc_content: []u8 = result: {
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
        defer allocator.free(lrc_content);
        p.loadLyrics(lrc_content) catch |err| {
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

    // 主显示循环
    // 单行 \r 原地刷新：进度 + 歌词合并在同一行
    var prev_lyric_text: ?[]const u8 = null;
    var last_displayed_sec: u32 = 0xFFFFFFFF;
    // 停滞检测：流式播放时 ma_sound_at_end 可能过早返回 true，
    // 改用位置停滞检测判断播放结束
    var last_position_ms: u64 = 0;
    var stall_count: u32 = 0;

    while (p.getState() == .playing or p.getState() == .paused) {
        if (p.getState() == .playing) {
            const snd = p.sound orelse break;
            const progress = p.getProgress();

            // 播放结束判断：声音标记结束且已播放超过 1 秒（正常结束）
            if (ma.ma_sound_at_end(snd) != 0 and progress.position_ms > 1000) {
                if (p.on_track_ended) |cb| cb();
                break;
            }

            // 停滞检测：位置连续 3 秒不变则退出
            if (progress.position_ms == last_position_ms) {
                stall_count += 1;
                if (stall_count >= 15) break;
            } else {
                stall_count = 0;
            }
            last_position_ms = progress.position_ms;
        }

        const progress = p.getProgress();
        const lyric_line = p.getCurrentLyric();
        const current_text = if (lyric_line) |l| l.text else null;

        const lyric_changed = blk: {
            if (prev_lyric_text == null and current_text == null) break :blk false;
            if (prev_lyric_text == null or current_text == null) break :blk true;
            break :blk !std.mem.eql(u8, prev_lyric_text.?, current_text.?);
        };

        const current_sec = @as(u32, @intCast(progress.position_ms / 1000));
        const sec_changed = current_sec != last_displayed_sec;

        if (lyric_changed or sec_changed) {
            prev_lyric_text = current_text;
            last_displayed_sec = current_sec;

            const state_icon = switch (p.getState()) {
                .playing => "▶",
                .paused => "⏸",
                else => "■",
            };
            const pos_min = progress.position_ms / 60000;
            const pos_sec = (progress.position_ms % 60000) / 1000;
            const dur_min = progress.duration_ms / 60000;
            const dur_sec = (progress.duration_ms % 60000) / 1000;

            std.debug.print("\r\x1b[2K{s} {d:0>2}:{d:0>2}/{d:0>2}:{d:0>2}", .{
                state_icon, pos_min, pos_sec, dur_min, dur_sec,
            });
            if (lyric_line) |l| {
                if (l.translation) |t| {
                    std.debug.print("  {s} · {s}", .{ l.text, t });
                } else {
                    std.debug.print("  {s}", .{l.text});
                }
            }
        }

        platform.sleepMs(200);
    }

    std.debug.print("\n", .{});
}

fn printUsage() void {
    std.debug.print("用法: zmusic-player <命令> [参数...]\n", .{});
    std.debug.print("命令:\n", .{});
    std.debug.print("  play <URL或路径>  播放 URL 或本地音频文件\n", .{});
    std.debug.print("  --help            显示帮助信息\n", .{});
}

fn printHelp() void {
    std.debug.print("ZMusic Player - 网络音频播放器\n\n", .{});
    std.debug.print("用法: zmusic-player play <URL或路径> [--lyrics <LRC文件路径>]\n\n", .{});
    std.debug.print("选项:\n", .{});
    std.debug.print("  --lyrics <路径>   加载 LRC 格式歌词文件\n", .{});
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
    list: std.array_list.Managed(u8),
    staging: [8192]u8,
    writer: std.Io.Writer,

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

    fn flushFn(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *BufferWriter = @alignCast(@fieldParentPtr("writer", w));
        self.commit();
    }

    fn rebaseFn(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        _ = capacity;
        const self: *BufferWriter = @alignCast(@fieldParentPtr("writer", w));
        self.commit();
        if (preserve > 0) return error.WriteFailed;
    }

    fn commit(self: *BufferWriter) void {
        if (self.writer.end == 0) return;
        self.list.appendSlice(self.writer.buffer[0..self.writer.end]) catch return;
        self.writer.end = 0;
    }
};
///
/// 通过 extern 声明直接调用 C 标准库函数（项目已链接 libc），
/// 避免 Zig 0.16.0 I/O 子系统复杂的初始化流程。
/// 限制最大 10MB，防止意外读取过大文件。
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

// C 标准库文件 I/O 函数声明
const c_SEEK_END: c_int = 2;
const c_SEEK_SET: c_int = 0;
const c_fopen = @extern(*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque, .{ .name = "fopen" });
const c_fclose = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "fclose" });
const c_fseek = @extern(*const fn (?*anyopaque, c_long, c_int) callconv(.c) c_int, .{ .name = "fseek" });
const c_ftell = @extern(*const fn (?*anyopaque) callconv(.c) c_long, .{ .name = "ftell" });
const c_fread = @extern(*const fn (?*anyopaque, usize, usize, ?*anyopaque) callconv(.c) usize, .{ .name = "fread" });
