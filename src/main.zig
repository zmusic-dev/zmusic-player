//! # ZMusic Player CLI/TUI 入口
//!
//! 命令行界面的入口模块，负责：
//! - 解析命令行参数（目前仅支持 `play` 命令）
//! - 创建 Player 实例并启动播放
//! - 轮询播放状态直到播放结束或用户中断
//!
//! ## 使用方式
//! ```sh
//! zmusic-player play <URL或路径> [--lyrics <歌词路径>]
//! ```

const std = @import("std");
const builtin = @import("builtin");
const player_mod = @import("player.zig");
const Player = player_mod.Player;
const PlaybackState = player_mod.PlaybackState;
const ma = @import("miniaudio");

/// ## main — 程序入口
///
/// 解析命令行参数，根据子命令执行对应操作。
/// 当前仅支持 `play` 子命令用于播放音频。
pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;

    // 跨平台参数迭代：Windows 需要通过分配器获取参数，
    // Linux/macOS 可以直接使用栈上的迭代器
    var iter = if (builtin.os.tag == .windows)
        try std.process.Args.Iterator.initAllocator(init.args, allocator)
    else
        init.args.iterate();
    defer iter.deinit();

    // 收集所有命令行参数到动态数组
    var args_list = std.array_list.Managed([]const u8).init(allocator);
    defer args_list.deinit();
    while (iter.next()) |arg| {
        try args_list.append(arg);
    }
    const args = args_list.items;

    // 未提供任何参数时显示用法
    if (args.len < 2) {
        std.debug.print("用法: zmusic-player <命令> [参数...]\n", .{});
        std.debug.print("命令:\n", .{});
        std.debug.print("  play <URL或路径>  播放 URL 或本地音频文件\n", .{});
        std.debug.print("  --help            显示帮助信息\n", .{});
        return;
    }

    const command = args[1];

    // 处理帮助请求
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        std.debug.print("ZMusic Player - 网络音频播放器\n\n", .{});
        std.debug.print("用法: zmusic-player play <URL或路径> [--lyrics <歌词路径>]\n\n", .{});
        std.debug.print("播放控制:\n", .{});
        std.debug.print("  Space   播放 / 暂停\n", .{});
        std.debug.print("  q       停止并退出\n", .{});
        std.debug.print("  n       下一曲\n", .{});
        std.debug.print("  p       上一曲\n", .{});
        std.debug.print("  ←/→     快退/快进 5 秒\n", .{});
        std.debug.print("  ↑/↓     音量增减\n", .{});
        return;
    }

    // 目前仅支持 play 子命令
    if (!std.mem.eql(u8, command, "play")) {
        std.debug.print("未知命令: {s}\n", .{command});
        return;
    }

    // play 命令需要至少一个参数（URL 或文件路径）
    if (args.len < 3) {
        std.debug.print("错误: play 命令需要一个 URL 或文件路径\n", .{});
        return;
    }

    const source = args[2];

    // 创建播放器实例
    var p = try Player.init(allocator);
    defer p.deinit();

    // 注册状态变更回调，在控制台打印状态转换
    p.onStateChanged(struct {
        fn cb(s: PlaybackState) void {
            std.debug.print("[状态] {s}\n", .{@tagName(s)});
        }
    }.cb);

    std.debug.print("正在播放: {s}\n", .{source});

    // 启动播放，失败时打印错误信息并退出
    p.play(source) catch |err| {
        std.debug.print("错误: {}\n", .{err});
        return;
    };

    std.debug.print("按 Ctrl+C 停止\n", .{});

    // 播放状态轮询循环
    // 持续检查播放是否结束，100ms 轮询一次以平衡响应速度和 CPU 占用
    while (p.getState() == .playing or p.getState() == .paused) {
        if (p.getState() == .playing) {
            // 检查声音是否已播放到末尾
            const snd = p.sound orelse break;
            if (ma.ma_sound_at_end(snd) != 0) {
                // 播放结束，触发回调后退出循环
                if (p.on_track_ended) |cb| cb();
                break;
            }
        }
        var req: std.c.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&req, null);
    }
}
