//! JNI 导出函数桥接层
//!
//! 本模块定义所有供 Java 侧调用的 native 方法，函数命名遵循 JNI 规范：
//! `Java_me_zhenxin_zmusic_ZMusicPlayer_{method}`，对应 Java 包名
//! `me.zhenxin.zmusic.ZMusicPlayer`。
//!
//! 当前所有函数为桩实现（返回 0 或空值），仅建立接口契约，等待后续接入
//! 实际的播放引擎。

const std = @import("std");
const callback = @import("callback");

// ============================================================================
// 生命周期管理
// ============================================================================

/// 初始化 native 播放器实例。
/// 返回值将作为 handle 传递给后续所有调用，用于关联 native 状态。
/// 当前为桩实现，固定返回 0。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeInit() i64 {
    return 0;
}

/// 销毁 native 播放器实例，释放相关资源。
/// handle 由 nativeInit 返回，标识需要销毁的实例。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeDestroy(handle: i64) void {
    _ = handle;
}

// ============================================================================
// 播放控制
// ============================================================================

/// 开始播放指定 URL 的音频。
/// url 为以 null 结尾的 C 字符串，指向音频资源的网络或本地地址。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlay(handle: i64, url: [*:0]const u8) i32 {
    _ = handle;
    _ = url;
    return 0;
}

/// 暂停当前播放。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePause(handle: i64) i32 {
    _ = handle;
    return 0;
}

/// 停止当前播放并重置播放位置。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeStop(handle: i64) i32 {
    _ = handle;
    return 0;
}

/// 恢复已暂停的播放。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeResume(handle: i64) i32 {
    _ = handle;
    return 0;
}

/// 跳转到指定位置。
/// position_ms 为目标位置的毫秒偏移量。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSeek(handle: i64, position_ms: i64) i32 {
    _ = handle;
    _ = position_ms;
    return 0;
}

// ============================================================================
// 状态查询
// ============================================================================

/// 获取当前播放状态（停止、播放、暂停等）。
/// 返回值为状态枚举的整数值。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetState(handle: i64) i32 {
    _ = handle;
    return 0;
}

/// 获取当前播放位置，单位为毫秒。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetPosition(handle: i64) i64 {
    _ = handle;
    return 0;
}

/// 获取当前曲目的总时长，单位为毫秒。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetDuration(handle: i64) i64 {
    _ = handle;
    return 0;
}

/// 获取当前音量，范围 [0.0, 1.0]。
/// 默认返回 1.0（最大音量）。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetVolume(handle: i64) f32 {
    _ = handle;
    return 1.0;
}

/// 设置播放音量。
/// volume 取值范围 [0.0, 1.0]。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSetVolume(handle: i64, volume: f32) i32 {
    _ = handle;
    _ = volume;
    return 0;
}

// ============================================================================
// 队列操作
// ============================================================================

/// 将曲目添加到播放队列末尾。
/// url、title、artist 均为以 null 结尾的 C 字符串。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeEnqueue(handle: i64, url: [*:0]const u8, title: [*:0]const u8, artist: [*:0]const u8) void {
    _ = handle;
    _ = url;
    _ = title;
    _ = artist;
}

/// 将曲目插入到当前播放曲目的下一个位置（优先播放）。
/// 参数同 nativeEnqueue。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeEnqueueNext(handle: i64, url: [*:0]const u8, title: [*:0]const u8, artist: [*:0]const u8) void {
    _ = handle;
    _ = url;
    _ = title;
    _ = artist;
}

/// 从播放队列中移除指定索引位置的曲目。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeRemoveFromQueue(handle: i64, index: i32) void {
    _ = handle;
    _ = index;
}

/// 清空播放队列中的所有曲目。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeClearQueue(handle: i64) void {
    _ = handle;
}

/// 播放队列中的下一首曲目。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlayNext(handle: i64) void {
    _ = handle;
}

/// 播放队列中的上一首曲目。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlayPrevious(handle: i64) void {
    _ = handle;
}

/// 播放队列中指定索引位置的曲目。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlayAtIndex(handle: i64, index: i32) void {
    _ = handle;
    _ = index;
}

/// 获取播放队列中的曲目数量。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetQueueSize(handle: i64) i32 {
    _ = handle;
    return 0;
}

/// 获取当前正在播放的曲目在队列中的索引。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetCurrentIndex(handle: i64) i32 {
    _ = handle;
    return 0;
}

// ============================================================================
// 歌词
// ============================================================================

/// 加载歌词内容。content 为以 null 结尾的 C 字符串，包含 LRC 格式歌词文本。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeLoadLyrics(handle: i64, content: [*:0]const u8) void {
    _ = handle;
    _ = content;
}

/// 获取当前时间对应的歌词行文本。
/// 返回以 null 结尾的 C 字符串，无歌词时返回空字符串。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetCurrentLyric(handle: i64) [*:0]const u8 {
    _ = handle;
    return "";
}

/// 获取指定时间点对应的歌词行文本。
/// time_ms 为目标时间的毫秒偏移量。
/// 返回以 null 结尾的 C 字符串，无匹配时返回空字符串。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetLyricLineAt(handle: i64, time_ms: i64) [*:0]const u8 {
    _ = handle;
    _ = time_ms;
    return "";
}

// ============================================================================
// 模式设置
// ============================================================================

/// 设置循环播放模式。
/// mode 为循环模式枚举值（如：不循环、单曲循环、列表循环）。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSetRepeatMode(handle: i64, mode: i32) void {
    _ = handle;
    _ = mode;
}

/// 设置随机播放开关。
/// enabled 为 true 时启用随机播放，false 时关闭。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSetShuffle(handle: i64, enabled: bool) void {
    _ = handle;
    _ = enabled;
}

// ============================================================================
// 事件轮询
// ============================================================================

/// 轮询待处理的 native 事件。
/// Java 侧定期调用此函数检查是否有状态变化、播放结束等事件需要处理。
/// 返回值为 Event 枚举的整数值，0 表示无事件。
/// 设计说明：采用原子事件标志 + Java 主动轮询的模式，避免在音频线程中
/// 直接调用 JNI（可能导致死锁或崩溃）。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePollEvent(handle: i64) u32 {
    _ = handle;
    return @intFromEnum(callback.pollEvent());
}
