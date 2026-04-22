//! 跨平台工具函数
//!
//! 封装各操作系统的差异，提供统一的平台无关接口。
//! 调用方只需使用本模块提供的函数，无需关心底层平台分支。
//!
//! ## 终端控制
//!
//! 提供 `enterRawMode` / `restoreTerminal` 用于将终端设置为原始模式
//! （关闭行缓冲和回显），配合 `readKey` 实现非阻塞键盘输入。
//!
//! ## Windows 控制台初始化
//!
//! `initWindowsConsole` 在程序启动时设置 UTF-8 代码页并启用 ANSI
//! 转义序列支持，确保中文输出和终端 UI 正常工作。

const std = @import("std");
const builtin = @import("builtin");

/// 初始化 Windows 控制台：设置 UTF-8 代码页并启用 ANSI 转义序列支持。
///
/// 仅在 Windows 上生效，其他平台为空操作。
/// 必须在首次输出前调用，否则中文字符和终端 UI（进度条、光标移动）会乱码。
pub fn initWindowsConsole() void {
    if (builtin.os.tag != .windows) return;

    const SetConsoleOutputCP = @extern(*const fn (u32) callconv(.c) i32, .{ .name = "SetConsoleOutputCP" });
    const SetConsoleCP = @extern(*const fn (u32) callconv(.c) i32, .{ .name = "SetConsoleCP" });
    _ = SetConsoleOutputCP(65001);
    _ = SetConsoleCP(65001);

    // 启用 VT（虚拟终端）处理，使 ANSI 转义序列（\x1B[2K、\x1B[3A 等）生效
    const GetStdHandle = @extern(*const fn (u32) callconv(.c) ?*anyopaque, .{ .name = "GetStdHandle" });
    const GetConsoleMode = @extern(*const fn (?*anyopaque, *u32) callconv(.c) i32, .{ .name = "GetConsoleMode" });
    const SetConsoleMode = @extern(*const fn (?*anyopaque, u32) callconv(.c) i32, .{ .name = "SetConsoleMode" });

    const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;

    const hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    if (hOut) |handle| {
        var mode: u32 = 0;
        if (GetConsoleMode(handle, &mode) != 0) {
            _ = SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }
    }
}

/// 将可能是 GBK 编码的字节序列转换为 UTF-8。
///
/// 如果已经是有效 UTF-8 则直接复制返回；否则尝试从 GBK (CP936) 转换。
/// Windows 使用 MultiByteToWideChar / WideCharToMultiByte 进行转换。
/// 返回的切片由调用方负责释放。
pub fn ensureUtf8(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return allocator.dupe(u8, bytes);
    if (builtin.os.tag == .windows) {
        return convertFromGbkWindows(allocator, bytes);
    }
    // POSIX: 非 UTF-8 内容直接复制返回（GBK 等 CJK 编码需要 iconv 支持，暂不实现）
    return allocator.dupe(u8, bytes);
}

/// Windows 平台 GBK → UTF-8 转换。
///
/// 使用 Win32 API 的两步转换：GBK(CP936) → UTF-16LE → UTF-8(CP65001)。
/// 转换失败时回退为直接复制原始字节。
fn convertFromGbkWindows(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const MultiByteToWideChar = @extern(
        *const fn (u32, u32, ?[*]const u8, i32, ?[*]u16, i32) callconv(.c) i32,
        .{ .name = "MultiByteToWideChar" },
    );
    const WideCharToMultiByte = @extern(
        *const fn (u32, u32, ?[*]const u16, i32, ?[*]u8, i32, ?[*]const u8, ?*i32) callconv(.c) i32,
        .{ .name = "WideCharToMultiByte" },
    );
    const CP_GB2312: u32 = 936;
    const CP_UTF8: u32 = 65001;

    // 第一步：GBK → UTF-16LE，查询所需缓冲区大小
    const wlen = MultiByteToWideChar(CP_GB2312, 0, bytes.ptr, @intCast(bytes.len), null, 0);
    if (wlen <= 0) return allocator.dupe(u8, bytes);
    const wbuf = try allocator.alloc(u16, @intCast(wlen));
    defer allocator.free(wbuf);
    _ = MultiByteToWideChar(CP_GB2312, 0, bytes.ptr, @intCast(bytes.len), wbuf.ptr, wlen);

    // 第二步：UTF-16LE → UTF-8，查询所需缓冲区大小
    const u8len = WideCharToMultiByte(CP_UTF8, 0, wbuf.ptr, wlen, null, 0, null, null);
    if (u8len <= 0) return allocator.dupe(u8, bytes);
    const result = try allocator.alloc(u8, @intCast(u8len));
    _ = WideCharToMultiByte(CP_UTF8, 0, wbuf.ptr, wlen, result.ptr, u8len, null, null);
    return result;
}

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

/// 保存原始终端属性，用于恢复（POSIX）/ Windows 输入控制台模式
var orig_termios: ?c.termios = null;
var orig_win_input_mode: ?u32 = null;

/// 将终端设置为原始模式（关闭行缓冲和回显）。
///
/// 调用后 stdin 上的 read 不会等待换行符，按键立即可读。
/// 必须在程序退出前调用 `restoreTerminal` 恢复原始设置。
pub fn enterRawMode() !void {
    if (builtin.os.tag == .windows) {
        // Windows: 关闭输入回显和行缓冲模式
        const GetStdHandle = @extern(*const fn (u32) callconv(.c) ?*anyopaque, .{ .name = "GetStdHandle" });
        const GetConsoleMode = @extern(*const fn (?*anyopaque, *u32) callconv(.c) i32, .{ .name = "GetConsoleMode" });
        const SetConsoleMode = @extern(*const fn (?*anyopaque, u32) callconv(.c) i32, .{ .name = "SetConsoleMode" });

        const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
        const ENABLE_ECHO_INPUT: u32 = 0x0004;
        const ENABLE_LINE_INPUT: u32 = 0x0002;

        const hIn = GetStdHandle(STD_INPUT_HANDLE);
        if (hIn) |handle| {
            var mode: u32 = 0;
            if (GetConsoleMode(handle, &mode) != 0) {
                orig_win_input_mode = mode;
                _ = SetConsoleMode(handle, mode & ~@as(u32, ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT));
            }
        }
        return;
    }
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
    if (builtin.os.tag == .windows) {
        if (orig_win_input_mode) |mode| {
            const GetStdHandle = @extern(*const fn (u32) callconv(.c) ?*anyopaque, .{ .name = "GetStdHandle" });
            const SetConsoleMode = @extern(*const fn (?*anyopaque, u32) callconv(.c) i32, .{ .name = "SetConsoleMode" });
            const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
            const hIn = GetStdHandle(STD_INPUT_HANDLE);
            if (hIn) |handle| {
                _ = SetConsoleMode(handle, mode);
            }
            orig_win_input_mode = null;
        }
        return;
    }
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
/// Windows 使用 `_kbhit` / `_getch` 读取按键。
/// 如果没有输入可用，返回 `null`。
pub fn readKey() ?Key {
    if (builtin.os.tag == .windows) {
        const _kbhit = @extern(*const fn () callconv(.c) i32, .{ .name = "_kbhit" });
        const _getch = @extern(*const fn () callconv(.c) i32, .{ .name = "_getch" });
        if (_kbhit() == 0) return null;
        const ch = _getch();
        // Windows 功能键先返回 0 或 0xE0，第二次返回实际键码
        if (ch == 0 or ch == 0xE0) {
            const ch2 = _getch();
            return switch (ch2) {
                72 => .up,
                80 => .down,
                75 => .left,
                77 => .right,
                else => .unknown,
            };
        }
        return switch (ch) {
            ' ' => .space,
            'q' => .q,
            else => .unknown,
        };
    }
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
