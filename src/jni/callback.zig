//! JNI 事件回调机制
//!
//! 采用原子事件标志 + Java 轮询的设计模式，实现 native 侧到 Java 侧的异步通知。
//!
//! 核心原则：音频线程（由 miniaudio 回调驱动）禁止直接调用 JNI 函数，
//! 因为 JNI 调用需要持有 Java 环境指针（JNIEnv*），在音频回调中获取或使用
//! 它可能导致死锁或崩溃。因此通过原子变量作为中转：native 侧写入事件标志，
//! Java 侧通过 nativePollEvent 主动读取。
//!
//! 本模块不持有任何全局状态，所有函数以指定原子值为目标操作，
//! 支持 per-instance 事件隔离。

const std = @import("std");
const atomic = std.atomic;

/// 播放器事件类型。
///
/// 每个值对应一种需要通知 Java 侧的状态变化。使用 u32 底层类型以便
/// 与原子操作和 JNI 返回值无缝对接。
pub const Event = enum(u32) {
    none = 0,
    /// 播放状态发生变化（如：播放→暂停、停止→播放）
    state_changed = 1,
    /// 当前曲目播放结束
    track_ended = 2,
    /// 播放进度更新
    progress_update = 3,
    /// 发生错误
    error_occurred = 4,
    /// 正在缓冲中
    buffering = 5,
};

/// 创建初始化为零值的待处理事件原子标志。
pub fn createPendingEvent() atomic.Value(u32) {
    return atomic.Value(u32).init(0);
}

/// 发布事件到指定原子标志。由 native 侧在音频线程中调用。
///
/// 使用 `.release` 内存序确保：事件发布前的所有写入操作在消费端
/// 读取到该事件后可见。
pub fn postEvent(target: *atomic.Value(u32), event: Event) void {
    target.store(@intFromEnum(event), .release);
}

/// 消费指定原子标志中的事件。由 Java 侧通过 nativePollEvent 定期调用。
///
/// 使用 `.acq_rel` 的 swap 操作实现"读取并清除"的原子操作，
/// 确保事件只被消费一次。消费后将标志重置为 0（none），
/// 避免同一事件被重复读取。
pub fn pollEvent(target: *atomic.Value(u32)) Event {
    const val = target.swap(0, .acq_rel);
    return @enumFromInt(val);
}
