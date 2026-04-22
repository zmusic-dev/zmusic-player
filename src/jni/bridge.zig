//! JNI 导出函数桥接层
//!
//! 本模块定义所有供 Java 侧调用的 native 方法，函数命名遵循 JNI 规范：
//! `Java_me_zhenxin_zmusic_ZMusicPlayer_{method}`，对应 Java 包名
//! `me.zhenxin.zmusic.ZMusicPlayer`。
//!
//! 每个 native 方法通过 JNI 环境指针（`*JNIEnv`）和对象指针（`jobject`）
//! 与 JVM 交互，内部委托给 Zig Player 引擎执行实际操作。
//!
//! ## 实例管理
//!
//! 采用指针即句柄（pointer-as-handle）模式：
//! - `nativeInit` 在堆上创建 `PlayerHandle`，返回其指针作为 `i64` 句柄
//! - 其他函数通过句柄恢复 `PlayerHandle` 指针，调用 Player API
//! - `nativeDestroy` 释放 `PlayerHandle` 及其所有关联资源
//!
//! ## 字符串内存管理
//!
//! JNI 字符串仅在当前 JNI 调用期间有效，因此入队等需要持久化字符串的操作
//! 必须复制一份独立副本。所有复制副本在 `nativeDestroy` 时统一释放。
//!
//! ## 回调机制
//!
//! 播放器引擎的回调通过 `callback.postEvent()` 发布到原子事件标志，
//! Java 侧通过 `nativePollEvent` 主动轮询消费，避免在音频线程中
//! 直接调用 JNI（防止死锁）。

const std = @import("std");
const callback = @import("callback");
const jni = @import("jni_types.zig");
const player_mod = @import("player");

const Player = player_mod.Player;
const PlaybackState = player_mod.PlaybackState;
const PlayerError = player_mod.PlayerError;
const Track = player_mod.Track;
const RepeatMode = player_mod.RepeatMode;

const allocator = std.heap.c_allocator;

/// JNI 播放器实例句柄。
///
/// 封装 Player 引擎和通过 JNI 分配的字符串副本列表。
/// 字符串副本用于安全地在 JNI 调用之外持有 Java 传入的文本数据，
/// 例如播放队列中的曲目 URL、标题、艺术家等。
const PlayerHandle = struct {
    /// 播放器引擎实例
    player: Player,
    /// 所有通过 `copyAndTrackJniString` 复制的字符串副本，
    /// 在 destroy 时统一释放
    string_allocs: std.array_list.Managed([]const u8),

    /// 在堆上创建并初始化 PlayerHandle。
    ///
    /// 使用 `c_allocator` 分配内存，Player 使用延迟初始化策略
    /// （不在创建时占用音频设备）。
    ///
    /// 返回：指向新创建的 PlayerHandle 的指针
    fn create() !*PlayerHandle {
        const h = try allocator.create(PlayerHandle);
        errdefer allocator.destroy(h);
        h.* = .{
            .player = try Player.init(allocator),
            .string_allocs = std.array_list.Managed([]const u8).init(allocator),
        };
        return h;
    }

    /// 销毁 PlayerHandle，释放所有关联资源。
    ///
    /// 释放顺序：
    /// 1. 释放所有字符串副本
    /// 2. 释放字符串追踪列表
    /// 3. 销毁播放器引擎（停止播放、释放音频设备）
    /// 4. 释放 PlayerHandle 结构体自身
    fn destroy(self: *PlayerHandle) void {
        for (self.string_allocs.items) |s| {
            allocator.free(s);
        }
        self.string_allocs.deinit();
        self.player.deinit();
        allocator.destroy(self);
    }
};

/// 从 i64 句柄恢复 PlayerHandle 指针。
///
/// 句柄为 0 时返回 null，表示无效的播放器实例。
inline fn handleToPtr(handle: i64) ?*PlayerHandle {
    if (handle == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(handle)));
}

/// 从 JNI 字符串复制一份独立的数据并追加到追踪列表。
///
/// JNI 字符串（通过 `GetStringUTFChars` 获取）仅在当前 JNI 调用期间有效，
/// 必须复制后才能在 JNI 调用返回后继续使用（如播放队列中的曲目信息）。
///
/// 复制的数据在 `PlayerHandle.destroy()` 时统一释放。
///
/// 参数：
///   `env`    - JNI 环境指针
///   `jstr`   - Java 字符串对象，为 null 时返回 null
///   `handle` - PlayerHandle 实例，用于追踪分配
///
/// 返回：复制的字符串切片，分配失败时返回 null
fn copyAndTrackJniString(env: *jni.JNIEnv, jstr: ?*jni.JString, handle: *PlayerHandle) ?[]const u8 {
    const chars = jni.getStringUTFChars(env, jstr) orelse return null;
    defer jni.releaseStringUTFChars(env, jstr, chars);
    const slice = std.mem.sliceTo(chars, 0);
    const copy = allocator.dupe(u8, slice) catch return null;
    errdefer allocator.free(copy);
    handle.string_allocs.append(copy) catch {
        allocator.free(copy);
        return null;
    };
    return copy;
}

// ============================================================================
// 播放器事件回调
// ============================================================================

/// 播放状态变更回调。
/// 将状态变更事件发布到原子事件标志，由 Java 轮询消费。
fn onStateChangedCb(_: PlaybackState) void {
    callback.postEvent(.state_changed);
}

/// 曲目播放结束回调。
fn onTrackEndedCb() void {
    callback.postEvent(.track_ended);
}

/// 播放错误回调。
fn onErrorCb(_: PlayerError) void {
    callback.postEvent(.error_occurred);
}

/// 播放进度更新回调。
fn onProgressCb(_: u64, _: u64) void {
    callback.postEvent(.progress_update);
}

// ============================================================================
// 生命周期管理
// ============================================================================

/// 初始化 native 播放器实例。
///
/// 创建 PlayerHandle 并注册播放器事件回调。
/// 返回非零句柄表示成功，Java 构造函数检查返回值为 0 时应抛出异常。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeInit(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
) i64 {
    _ = env;
    _ = obj;
    const handle = PlayerHandle.create() catch return 0;
    // 注册回调，将播放器内部事件桥接到 JNI 事件轮询机制
    handle.player.onStateChanged(onStateChangedCb);
    handle.player.onTrackEnded(onTrackEndedCb);
    handle.player.onError(onErrorCb);
    handle.player.onProgress(onProgressCb);
    return @as(i64, @bitCast(@intFromPtr(handle)));
}

/// 销毁 native 播放器实例，释放所有关联资源。
///
/// 句柄无效时安全返回（不执行任何操作）。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeDestroy(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) void {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return;
    h.destroy();
}

// ============================================================================
// 播放控制
// ============================================================================

/// 开始播放指定 URL 的音频。
///
/// 支持 HTTP/HTTPS 网络流和本地文件路径。
/// 返回 0 表示成功，-1 表示失败（无效句柄、URL 解析失败、解码失败等）。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlay(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
    url: ?*jni.JString,
) i32 {
    _ = obj;
    const h = handleToPtr(handle) orelse return -1;
    const chars = jni.getStringUTFChars(env, url) orelse return -1;
    defer jni.releaseStringUTFChars(env, url, chars);
    const slice = std.mem.sliceTo(chars, 0);
    h.player.play(slice) catch return -1;
    return 0;
}

/// 暂停当前播放。
///
/// 仅在 playing 状态下生效。
/// 返回 0 表示成功，-1 表示失败。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePause(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) i32 {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return -1;
    h.player.pause() catch return -1;
    return 0;
}

/// 停止当前播放并重置播放位置。
///
/// 始终返回 0（stop 操作不会失败）。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeStop(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) i32 {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return -1;
    h.player.stop();
    return 0;
}

/// 恢复已暂停的播放。
///
/// 使用 `@"resume"` 语法，因为 `resume` 是 Zig 保留关键字（用于异步挂起恢复）。
/// 返回 0 表示成功，-1 表示失败。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeResume(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) i32 {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return -1;
    h.player.@"resume"() catch return -1;
    return 0;
}

/// 跳转到指定播放位置。
///
/// `position_ms` 为目标位置的毫秒偏移量（相对于曲目起始位置）。
/// 返回 0 表示成功，-1 表示失败。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSeek(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
    position_ms: i64,
) i32 {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return -1;
    h.player.seek(@intCast(position_ms)) catch return -1;
    return 0;
}

// ============================================================================
// 状态查询
// ============================================================================

/// 获取当前播放状态。
///
/// 返回值为 PlaybackState 枚举的整数值：
/// 0=stopped, 1=loading, 2=playing, 3=paused, 4=error
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetState(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) i32 {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return 0;
    return @intFromEnum(h.player.getState());
}

/// 获取当前播放位置，单位为毫秒。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetPosition(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) i64 {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return 0;
    const progress = h.player.getProgress();
    return @intCast(progress.position_ms);
}

/// 获取当前曲目的总时长，单位为毫秒。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetDuration(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) i64 {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return 0;
    const progress = h.player.getProgress();
    return @intCast(progress.duration_ms);
}

/// 获取当前音量。
///
/// 返回值范围 [0.0, 1.0]，默认为 1.0。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetVolume(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) f32 {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return 1.0;
    return h.player.getVolume();
}

/// 设置播放音量。
///
/// `volume` 取值范围 [0.0, 1.0]，超出范围会被自动钳制。
/// 始终返回 0。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSetVolume(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
    volume: f32,
) i32 {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return -1;
    h.player.setVolume(volume);
    return 0;
}

// ============================================================================
// 队列操作
// ============================================================================

/// 将曲目添加到播放队列末尾。
///
/// JNI 字符串会被复制为独立副本，原始 JNI 字符串在函数返回后失效。
/// URL 为 null 时静默跳过。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeEnqueue(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
    url: ?*jni.JString,
    title: ?*jni.JString,
    artist: ?*jni.JString,
) void {
    _ = obj;
    const h = handleToPtr(handle) orelse return;
    const url_copy = copyAndTrackJniString(env, url, h) orelse return;
    const title_copy: ?[]const u8 = if (title != null) copyAndTrackJniString(env, title, h) else null;
    const artist_copy: ?[]const u8 = if (artist != null) copyAndTrackJniString(env, artist, h) else null;
    const track = Track{
        .url = url_copy,
        .title = title_copy,
        .artist = artist_copy,
    };
    h.player.enqueue(track) catch {};
}

/// 将曲目插入到当前播放位置之后（"下一首播放"）。
///
/// 行为与 nativeEnqueue 相同，但插入位置为当前播放曲目的下一个。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeEnqueueNext(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
    url: ?*jni.JString,
    title: ?*jni.JString,
    artist: ?*jni.JString,
) void {
    _ = obj;
    const h = handleToPtr(handle) orelse return;
    const url_copy = copyAndTrackJniString(env, url, h) orelse return;
    const title_copy: ?[]const u8 = if (title != null) copyAndTrackJniString(env, title, h) else null;
    const artist_copy: ?[]const u8 = if (artist != null) copyAndTrackJniString(env, artist, h) else null;
    const track = Track{
        .url = url_copy,
        .title = title_copy,
        .artist = artist_copy,
    };
    h.player.enqueueNext(track) catch {};
}

/// 从播放队列中移除指定索引位置的曲目。
///
/// 索引越界时静默跳过。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeRemoveFromQueue(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
    index: i32,
) void {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return;
    h.player.removeFromQueue(@intCast(index)) catch {};
}

/// 清空播放队列中的所有曲目。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeClearQueue(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) void {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return;
    h.player.clearQueue();
}

/// 播放队列中的下一首曲目。
///
/// 队列为空或到达末尾时静默跳过。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlayNext(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) void {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return;
    h.player.playNext() catch {};
}

/// 播放队列中的上一首曲目。
///
/// 队列为空或到达开头时静默跳过。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlayPrevious(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) void {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return;
    h.player.playPrevious() catch {};
}

/// 播放队列中指定索引位置的曲目。
///
/// 索引越界时静默跳过。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlayAtIndex(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
    index: i32,
) void {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return;
    h.player.playAtIndex(@intCast(index)) catch {};
}

/// 获取播放队列中的曲目数量。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetQueueSize(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) i32 {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return 0;
    return @intCast(h.player.playlist.tracks.items.len);
}

/// 获取当前正在播放的曲目在队列中的索引。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetCurrentIndex(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) i32 {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return 0;
    return @intCast(h.player.playlist.current_index);
}

// ============================================================================
// 歌词
// ============================================================================

/// 加载 LRC 格式歌词内容。
///
/// 替换之前加载的歌词。解析失败时静默跳过。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeLoadLyrics(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
    content: ?*jni.JString,
) void {
    _ = obj;
    const h = handleToPtr(handle) orelse return;
    const chars = jni.getStringUTFChars(env, content) orelse return;
    defer jni.releaseStringUTFChars(env, content, chars);
    const slice = std.mem.sliceTo(chars, 0);
    h.player.loadLyrics(slice) catch {};
}

/// 获取当前时间对应的歌词行文本。
///
/// 根据当前播放进度查找匹配的歌词行，通过 `newStringUTF` 创建 Java 字符串返回。
/// 无歌词或当前时间无匹配时返回 null。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetCurrentLyric(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) ?*jni.JString {
    _ = obj;
    const h = handleToPtr(handle) orelse return null;
    const line = h.player.getCurrentLyric() orelse return null;
    // lyrics text 是 slice（不保证以 null 结尾），需要 dupeZ 添加终止符
    const text_z = allocator.dupeZ(u8, line.text) catch return null;
    defer allocator.free(text_z);
    return jni.newStringUTF(env, text_z.ptr);
}

/// 获取指定时间点对应的歌词行文本。
///
/// `time_ms` 为目标时间的毫秒偏移量。
/// 无歌词或指定时间无匹配时返回 null。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetLyricLineAt(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
    time_ms: i64,
) ?*jni.JString {
    _ = obj;
    const h = handleToPtr(handle) orelse return null;
    // lyrics_data 为 ?Lyrics，使用 |*lyrics| 获取内部指针
    if (h.player.lyrics_data) |*lyrics| {
        const idx = lyrics.getLineAt(@intCast(time_ms)) orelse return null;
        const text = lyrics.lines.items[idx].text;
        const text_z = allocator.dupeZ(u8, text) catch return null;
        defer allocator.free(text_z);
        return jni.newStringUTF(env, text_z.ptr);
    }
    return null;
}

// ============================================================================
// 模式设置
// ============================================================================

/// 设置循环播放模式。
///
/// `mode` 取值：
/// - 0：不循环（播放到末尾即停止）
/// - 1：单曲循环
/// - 2：列表循环
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSetRepeatMode(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
    mode: i32,
) void {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return;
    h.player.playlist.setRepeatMode(@enumFromInt(mode));
}

/// 设置随机播放开关。
///
/// 启用时基于 Fisher-Yates 算法生成随机播放序列。
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSetShuffle(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
    enabled: bool,
) void {
    _ = env;
    _ = obj;
    const h = handleToPtr(handle) orelse return;
    h.player.playlist.setShuffle(enabled);
}

// ============================================================================
// 事件轮询
// ============================================================================

/// 轮询待处理的 native 事件。
///
/// 采用原子交换操作"读取并清除"事件标志，确保每个事件只被消费一次。
///
/// 返回值为事件类型码：
/// - 0：无事件
/// - 1：播放状态变更
/// - 2：曲目播放结束
/// - 3：播放进度更新
/// - 4：播放错误
/// - 5：缓冲状态变更
pub export fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePollEvent(
    env: *jni.JNIEnv,
    obj: ?*anyopaque,
    handle: i64,
) u32 {
    _ = env;
    _ = obj;
    _ = handle;
    return @intFromEnum(callback.pollEvent());
}
