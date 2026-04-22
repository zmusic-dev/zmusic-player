//! JNI 类型定义与辅助函数
//!
//! 提供 JNI 桥接层所需的最小类型定义和字符串操作辅助函数。
//! 使用 opaque 类型表示 JNI 的不透明指针，通过 vtable 指针算术
//! 访问 JNI 环境函数，避免引入完整的 JNI 头文件。
//!
//! ## JNI vtable 访问原理
//!
//! JNI 的 `JNIEnv` 实际上是 `const struct JNINativeInterface* const*` 类型，
//! 即指向函数指针表的二级指针。本模块通过指针转换直接访问 vtable 中的函数：
//! 1. 将 `*JNIEnv` 解引用为函数表指针
//! 2. 按索引访问对应的函数指针
//! 3. 将函数指针转换为具体的 Zig 函数类型
//!
//! ## 修改版 UTF-8 说明
//!
//! JNI 使用修改版 UTF-8 编码（与标准 UTF-8 在处理空字符和补充字符时有差异），
//! 但对于大多数文本内容（ASCII、常见中文/日文/韩文字符），行为与标准 UTF-8 一致。

const std = @import("std");

/// JNI 环境指针，对应 Java 的 `JNIEnv*`。
///
/// 在 JNI 中，`JNIEnv` 实际上是一个函数指针表（vtable）的二级指针，
/// 通过它调用 JNI 提供的各种函数（如字符串操作、对象创建等）。
pub const JNIEnv = opaque {};

/// Java 字符串类型，对应 JNI 的 `jstring`。
///
/// 表示 Java 中 `java.lang.String` 对象的不透明指针。
pub const JString = opaque {};

/// Java 对象类型，对应 JNI 的 `jobject`。
///
/// 表示任意 Java 对象实例的不透明指针。
pub const JObject = opaque {};

/// 从 JNI vtable 中获取指定索引处的函数指针。
///
/// JNI 的 vtable 是一个函数指针数组，每个函数有固定的索引位置。
/// 本函数将 `env` 指针解引用为 vtable 指针，然后按索引取出函数指针。
///
/// 参数：
///   `env`   - JNI 环境指针
///   `index` - vtable 中的函数索引（编译期常量）
///
/// 返回：vtable 中指定索引处的函数指针（以 `usize` 地址值形式返回）
inline fn getVtableFnAddr(env: *JNIEnv, comptime index: usize) usize {
    // env 实际上是 const JNINativeInterface**
    // 解引用一次得到函数表指针
    const ptr: *const *const anyopaque = @ptrCast(@alignCast(env));
    const vtable: [*]const *const anyopaque = @ptrCast(@alignCast(ptr.*));
    return @intFromPtr(vtable[index]);
}

/// 获取 Java 字符串的修改版 UTF-8 编码表示。
///
/// 对应 JNI 的 `GetStringUTFChars` 函数（vtable 索引 169）。
/// 返回的指针必须通过 `releaseStringUTFChars` 释放，否则可能导致内存泄漏。
/// 调用方不应修改返回的字符串内容。
///
/// 参数：
///   `env` - JNI 环境指针
///   `str` - Java 字符串对象，为 null 时返回 null
///
/// 返回：指向以 null 结尾的 UTF-8 字符串的指针，失败时返回 null
pub fn getStringUTFChars(env: *JNIEnv, str: ?*JString) ?[*:0]const u8 {
    if (str == null) return null;
    const Fn = *const fn (*JNIEnv, ?*JString, ?*u8) callconv(.c) ?[*:0]const u8;
    const f: Fn = @ptrFromInt(getVtableFnAddr(env, 169));
    return f(env, str, null);
}

/// 释放由 `getStringUTFChars` 获取的字符串指针。
///
/// 对应 JNI 的 `ReleaseStringUTFChars` 函数（vtable 索引 170）。
/// 调用此函数后，之前获取的字符指针不再有效，不应继续使用。
///
/// 参数：
///   `env`   - JNI 环境指针
///   `str`   - 对应的 Java 字符串对象
///   `chars` - 之前通过 `getStringUTFChars` 获取的字符指针
pub fn releaseStringUTFChars(env: *JNIEnv, str: ?*JString, chars: [*:0]const u8) void {
    const Fn = *const fn (*JNIEnv, ?*JString, [*:0]const u8) callconv(.c) void;
    const f: Fn = @ptrFromInt(getVtableFnAddr(env, 170));
    f(env, str, chars);
}

/// 从修改版 UTF-8 C 字符串创建新的 Java 字符串对象。
///
/// 对应 JNI 的 `NewStringUTF` 函数（vtable 索引 167）。
/// JVM 会复制输入字符串，因此调用方可以在函数返回后立即释放输入缓冲区。
///
/// 参数：
///   `env`   - JNI 环境指针
///   `chars` - 以 null 结尾的修改版 UTF-8 字符串
///
/// 返回：新创建的 Java 字符串对象，内存不足时返回 null
pub fn newStringUTF(env: *JNIEnv, chars: [*:0]const u8) ?*JString {
    const Fn = *const fn (*JNIEnv, [*:0]const u8) callconv(.c) ?*JString;
    const f: Fn = @ptrFromInt(getVtableFnAddr(env, 167));
    return f(env, chars);
}

/// 便利函数：获取 Java 字符串的内容作为 Zig byte 切片。
///
/// 内部调用 `getStringUTFChars` 获取字符指针，然后通过 `std.mem.sliceTo`
/// 计算字符串长度并返回切片。
///
/// **注意**：调用方不得对返回的切片调用 `releaseStringUTFChars`。
/// 此函数适用于短生命周期的字符串访问场景，在 JNI 调用返回前
/// 应完成对返回数据的处理。
///
/// 参数：
///   `env` - JNI 环境指针
///   `str` - Java 字符串对象，为 null 时返回 null
///
/// 返回：字符串内容的 byte 切片，失败时返回 null
pub fn toString(env: *JNIEnv, str: ?*JString) ?[]const u8 {
    const chars = getStringUTFChars(env, str) orelse return null;
    return std.mem.sliceTo(chars, 0);
}
