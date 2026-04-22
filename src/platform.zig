//! 跨平台工具函数
//!
//! 封装各操作系统的差异，提供统一的平台无关接口。
//! 调用方只需使用本模块提供的函数，无需关心底层平台分支。
//!
//! ## 终端控制
//!
//! 提供 `enterRawMode` / `restoreTerminal` 用于将终端设置为原始模式
//! （关闭行缓冲和回显），配合 `readKey` 实现非阻塞键盘输入。

const std = @import("std");
const builtin = @import("builtin");

/// 跨平台毫秒级休眠。
///
/// Windows 使用 kernel32 的 Sleep 函数，
/// Linux / macOS 使用 POSIX nanosleep。
pub fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        const F = *const fn (u32) callconv(.c) void;
        @extern(F, .{ .name = "Sleep" })(ms);
    } else {
        const ns: isize = @intCast(@as(u64, ms) * std.time.ns_per_ms);
        var req: std.c.timespec = .{ .sec = 0, .nsec = ns };
        _ = std.c.nanosleep(&req, null);
    }
}

/// 获取跨平台的时间戳（秒和纳秒），可用于随机数种子等场景。
///
/// Linux / macOS 使用 POSIX clock_gettime + CLOCK_REALTIME，
/// Windows 使用 GetSystemTimePreciseAsFileTime。
pub fn timestamp() struct { sec: i64, nsec: i64 } {
    if (builtin.os.tag == .windows) {
        const F = *const fn (*std.os.windows.FILETIME) callconv(.c) void;
        const GetSystemTimePreciseAsFileTime = @extern(F, .{
            .name = "GetSystemTimePreciseAsFileTime",
        });
        var ft: std.os.windows.FILETIME = undefined;
        GetSystemTimePreciseAsFileTime(&ft);
        // FILETIME 是 100 纳秒间隔，从 1601-01-01 UTC 起
        const combined = @as(u64, ft.dwHighDateTime) << 32 | @as(u64, ft.dwLowDateTime);
        // 转换为 Unix 纪元（1970-01-01）：差值 11644473600 秒
        const unix_100ns = if (combined > 116444736000000000) combined - 116444736000000000 else 0;
        return .{
            .sec = @intCast(unix_100ns / 10_000_000),
            .nsec = @intCast(unix_100ns % 10_000_000 * 100),
        };
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return .{
            .sec = @intCast(ts.sec),
            .nsec = @intCast(ts.nsec),
        };
    }
}

// ---- 终端原始模式 ----
// 用于 CLI 播放控制：将终端设置为原始模式（无行缓冲、无回显），
// 然后在主循环中非阻塞读取按键。

/// POSIX termios 相关常量和函数
const c = std.c;

/// 保存原始终端属性，用于恢复
var orig_termios: ?c.termios = null;

/// 将终端设置为原始模式（关闭行缓冲和回显）。
///
/// 调用后 stdin 上的 read 不会等待换行符，按键立即可读。
/// 必须在程序退出前调用 `restoreTerminal` 恢复原始设置。
pub fn enterRawMode() !void {
    if (builtin.os.tag == .windows) return;
    var term: c.termios = undefined;
    if (c.tcgetattr(std.posix.STDIN_FILENO, &term) != 0) return error.TerminalError;
    orig_termios = term;

    // 关闭输入处理标志
    term.iflag.INPCK = false;
    term.iflag.ISTRIP = false;
    term.iflag.ICRNL = false;

    // 关闭输出处理
    term.oflag.OPOST = false;

    // 关闭回显（ECHO）和规范模式（ICANON，即行缓冲）
    // 关闭 ISIG 避免 Ctrl+C 等中断播放
    term.lflag.ECHO = false;
    term.lflag.ICANON = false;
    term.lflag.ISIG = false;

    // 设置非阻塞读取，最小读取 0 字节（立即返回）
    term.cc[@intFromEnum(c.V.MIN)] = 0;
    term.cc[@intFromEnum(c.V.TIME)] = 0;
    if (c.tcsetattr(std.posix.STDIN_FILENO, c.TCSA.FLUSH, &term) != 0) return error.TerminalError;
}

/// 恢复终端到进入原始模式前的状态。
///
/// 安全调用：即使从未调用 `enterRawMode` 也不会出错。
pub fn restoreTerminal() void {
    if (builtin.os.tag == .windows) return;
    if (orig_termios) |term| {
        _ = c.tcsetattr(std.posix.STDIN_FILENO, c.TCSA.FLUSH, &term);
        orig_termios = null;
    }
}

/// 按键标识
pub const Key = union(enum) {
    space,
    q,
    up,
    down,
    left,
    right,
    unknown,
};

/// 非阻塞读取一个按键。
///
/// 在原始模式下，从 stdin 读取最多 6 字节的转义序列并解析为 `Key`。
/// 如果没有输入可用，返回 `null`。
pub fn readKey() ?Key {
    if (builtin.os.tag == .windows) return null;
    var buf: [6]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return null;
    if (n == 0) return null;

    // 转义序列：ESC [ A/B/C/D = 上/下/右/左
    if (n >= 3 and buf[0] == 0x1b and buf[1] == '[') {
        return switch (buf[2]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => .unknown,
        };
    }
    return switch (buf[0]) {
        ' ' => .space,
        'q' => .q,
        else => .unknown,
    };
}
