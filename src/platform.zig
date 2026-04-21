//! 跨平台工具函数
//!
//! 封装各操作系统的差异，提供统一的平台无关接口。
//! 调用方只需使用本模块提供的函数，无需关心底层平台分支。

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
