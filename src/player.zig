//! # Player API 统一入口
//!
//! 本模块是播放器的顶层公共接口，整合了以下子系统：
//! - **音频引擎**（miniaudio）：负责底层音频设备管理和声音播放
//! - **播放队列**（Playlist）：管理曲目列表和播放顺序
//! - **歌词引擎**（Lyrics）：解析和查询 LRC 歌词
//! - **网络层**（StreamingSource）：支持 HTTP 流式播放
//!
//! 外部调用者只需引入本模块即可获得完整的播放控制能力，
//! 无需关心底层各子系统的交互细节。
//!
//! ## 设计要点
//! - 引擎采用**延迟初始化**策略，仅在首次播放时才占用音频设备
//! - 支持本地文件和网络流两种播放源，通过 URL 前缀自动判断
//! - 提供事件回调机制（状态变更、进度更新、播放结束、错误通知）

const std = @import("std");
const state = @import("state/player_state.zig");
const queue = @import("queue/playlist.zig");
const lyrics_types = @import("lyrics/types.zig");
const lyrics_parser = @import("lyrics/parser.zig");
const net = @import("net/http_client.zig");
const streaming = @import("net/streaming.zig");
const ma = @import("miniaudio");
const platform = @import("platform");

// ---- 公共类型重导出 ----
// 将子模块的核心类型提升到 Player 命名空间下，
// 方便外部使用 `player.PlaybackState` 等简短路径访问

pub const PlaybackState = state.PlaybackState;
pub const PlayerError = state.PlayerError;
pub const Track = queue.Track;
pub const RepeatMode = queue.RepeatMode;
pub const Lyrics = lyrics_types.Lyrics;
pub const LyricLine = lyrics_types.LyricLine;

/// 播放状态变更回调。
/// 当 Player 内部状态（playing / paused / stopped / error / loading）发生变化时触发。
pub const StateCallback = *const fn (PlaybackState) void;

/// 播放进度回调。
/// 定期触发，报告当前播放位置和总时长（均为毫秒）。
pub const ProgressCallback = *const fn (position_ms: u64, duration_ms: u64) void;

/// 曲目播放结束回调。
/// 当一首曲目播放到末尾时触发，可用于自动播放下一曲。
pub const TrackEndedCallback = *const fn () void;

/// 错误回调。
/// 播放过程中发生错误时触发，携带具体错误类型。
pub const ErrorCallback = *const fn (PlayerError) void;

/// # Player — 播放器核心结构体
///
/// 持有音频引擎、当前声音对象、解码器、网络流源、播放队列和歌词数据，
/// 是整个播放器的状态中心。
///
/// 生命周期：`init()` → 多次 `play()` / `pause()` / `stop()` → `deinit()`
pub const Player = struct {
    /// 内存分配器，用于所有动态内存操作
    allocator: std.mem.Allocator,

    /// miniaudio 引擎实例，管理音频设备和混音
    engine: ma.ma_engine,

    /// 当前正在播放的声音对象，为 null 表示无活跃播放
    sound: ?*ma.ma_sound,

    /// 当前音频解码器，仅在网络流播放时使用
    /// 本地文件播放由 miniaudio 内部解码，无需此字段
    decoder: ?*ma.ma_decoder,

    /// 网络流式数据源，仅在网络播放时使用
    /// 负责后台下载和环形缓冲区管理
    stream_source: ?*streaming.StreamingSource,

    /// 播放队列，管理曲目列表和播放顺序
    playlist: queue.Playlist,

    /// 当前加载的歌词数据，为 null 表示无歌词
    lyrics_data: ?Lyrics,

    /// 当前音量，范围 [0.0, 1.0]
    volume: f32,

    /// 当前播放状态
    state: PlaybackState,

    /// 引擎是否已初始化，用于实现延迟初始化
    engine_initialized: bool,

    // ---- 事件回调函数指针 ----
    // 全部为可选类型，未注册时为 null

    /// 状态变更回调
    on_state_changed: ?StateCallback,

    /// 进度更新回调
    on_progress: ?ProgressCallback,

    /// 曲目结束回调
    on_track_ended: ?TrackEndedCallback,

    /// 错误回调
    on_error_cb: ?ErrorCallback,

    /// ## init — 创建 Player 实例
    ///
    /// 只初始化播放队列和默认值，**不立即初始化音频引擎**。
    /// 音频引擎在首次调用 `play()` 时才通过 `ensureEngine()` 延迟创建，
    /// 避免在不播放时占用系统音频设备资源。
    ///
    /// - `allocator` 用于后续所有动态内存分配
    /// - 返回一个处于 `stopped` 状态的 Player 实例
    pub fn init(allocator: std.mem.Allocator) !Player {
        return .{
            .allocator = allocator,
            .engine = undefined,
            .sound = null,
            .decoder = null,
            .stream_source = null,
            .playlist = queue.Playlist.init(allocator),
            .lyrics_data = null,
            .volume = 1.0,
            .state = .stopped,
            .engine_initialized = false,
            .on_state_changed = null,
            .on_progress = null,
            .on_track_ended = null,
            .on_error_cb = null,
        };
    }

    /// ## deinit — 销毁 Player 实例
    ///
    /// 按依赖关系的逆序释放资源：
    /// 1. 停止当前播放并释放声音对象、解码器、网络流
    /// 2. 关闭 miniaudio 引擎（释放音频设备）
    /// 3. 释放歌词数据
    /// 4. 释放播放队列
    pub fn deinit(self: *Player) void {
        self.stop();
        if (self.engine_initialized) {
            ma.ma_engine_uninit(&self.engine);
            self.engine_initialized = false;
        }
        if (self.lyrics_data) |*l| l.deinit();
        self.playlist.deinit();
    }

    /// ## ensureEngine — 延迟初始化音频引擎
    ///
    /// 仅在首次播放时调用。如果引擎已初始化则直接返回。
    ///
    /// 延迟初始化的原因：miniaudio 引擎初始化时会打开系统音频设备，
    /// 如果用户只是创建 Player 但不播放（例如构建播放列表），
    /// 不应浪费音频设备资源。
    fn ensureEngine(self: *Player) !void {
        if (self.engine_initialized) return;
        const config = ma.ma_engine_config_init();
        const result = ma.ma_engine_init(&config, &self.engine);
        if (result != ma.MA_SUCCESS) return PlayerError.DeviceInitFailed;
        self.engine_initialized = true;
        // 引擎初始化后立即同步之前设置的音量值
        _ = ma.ma_engine_set_volume(&self.engine, self.volume);
    }

    /// ## play — 播放指定音频
    ///
    /// 统一入口方法，自动判断播放源类型：
    /// - 以 `http://` 或 `https://` 开头 → 网络流播放（`playFromUrl`）
    /// - 其他情况 → 本地文件播放（`playFromFile`）
    ///
    /// 调用前会先停止当前播放，确保同一时间只有一首曲目在播放。
    ///
    /// - `url` 音频资源路径，可以是 URL 或本地文件路径
    pub fn play(self: *Player, url: []const u8) !void {
        self.stop();
        self.setState(.loading);

        if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
            try self.playFromUrl(url);
        } else {
            try self.playFromFile(url);
        }

        const snd = self.sound orelse return PlayerError.DecodeFailed;
        _ = ma.ma_sound_start(snd);
        self.setState(.playing);
    }

    /// ## playFromFile — 从本地文件播放
    ///
    /// 使用 miniaudio 的 `ma_sound_init_from_file` 直接从文件解码播放，
    /// miniaudio 内部处理解码和文件读取，无需手动管理解码器。
    ///
    /// - `path` 本地文件路径
    fn playFromFile(self: *Player, path: []const u8) !void {
        try self.ensureEngine();

        // miniaudio 需要 C 风格的 null 终止字符串作为文件路径
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        const snd = try self.allocator.create(ma.ma_sound);
        const result = ma.ma_sound_init_from_file(
            &self.engine,
            path_z.ptr,
            ma.MA_SOUND_FLAG_DECODE,
            null,
            null,
            snd,
        );
        if (result != ma.MA_SUCCESS) {
            self.allocator.destroy(snd);
            self.setState(.@"error");
            return PlayerError.DecodeFailed;
        }
        self.sound = snd;
    }

    /// ## playFromUrl — 从网络 URL 流式播放
    ///
    /// 完整流程：
    /// 1. 发送 HEAD 请求获取 `Content-Length`（用于缓冲区大小和进度计算）
    /// 2. 创建 `StreamingSource`，启动后台下载线程
    /// 3. 等待初始缓冲数据到达
    /// 4. 初始化解码器（可能需要重试，见下方说明）
    /// 5. 创建声音对象并关联解码器
    ///
    /// 解码器初始化重试机制的设计意图：
    /// miniaudio 的解码器需要读取足够的音频头部数据才能成功初始化。
    /// 但网络下载是异步的，首次尝试时可能还没有足够数据。
    /// 因此采用重试策略：等待 50ms 后再次尝试，
    /// 只有当缓冲数据没有增长时才计为一次失败重试，
    /// 避免在网络正常下载时浪费重试次数。
    ///
    /// - `url` 音频资源的 HTTP/HTTPS URL
    fn playFromUrl(self: *Player, url: []const u8) !void {
        try self.ensureEngine();

        // 步骤 1：获取内容长度
        const content_length = net.HttpClient.headContentLength(url) catch {
            self.setState(.@"error");
            return PlayerError.HttpError;
        } orelse {
            self.setState(.@"error");
            return PlayerError.HttpError;
        };

        // 步骤 2：创建流式数据源，启动后台下载
        const src = streaming.StreamingSource.start(self.allocator, url, content_length) catch {
            self.setState(.@"error");
            return PlayerError.HttpError;
        };
        self.stream_source = src;

        // 步骤 3：等待初始缓冲区填入足够数据
        src.waitInitialBuffer();

        // 步骤 4：初始化解码器（带重试）
        const dec = try self.allocator.create(ma.ma_decoder);
        var decode_result: c_int = ma.MA_SUCCESS;
        var retries: usize = 0;
        const max_retries = 20;

        while (retries < max_retries) {
            decode_result = ma.ma_decoder_init(
                streaming.decoderReadCallback,
                streaming.decoderSeekCallback,
                src,
                null,
                dec,
            );
            if (decode_result == ma.MA_SUCCESS) break;

            // 如果下载已完成但解码仍然失败，说明数据不足或格式不支持，不再重试
            if (src.download_done.load(.acquire)) break;

            // 等待 50ms 让网络继续下载
            const current_pos = src.write_pos.load(.acquire);
            platform.sleepMs(50);

            // 只有当缓冲数据没有增长时才算一次失败重试，
            // 数据在持续增长说明网络正常，只是解码器需要更多头部数据
            if (src.write_pos.load(.acquire) == current_pos) {
                retries += 1;
            }
        }

        if (decode_result != ma.MA_SUCCESS) {
            self.allocator.destroy(dec);
            self.setState(.@"error");
            return PlayerError.DecodeFailed;
        }
        self.decoder = dec;

        // 步骤 5：创建声音对象，关联解码器作为数据源
        const snd = try self.allocator.create(ma.ma_sound);
        const ds: ?*ma.ma_data_source = @ptrCast(dec);
        const sound_result = ma.ma_sound_init_from_data_source(
            &self.engine,
            ds,
            ma.MA_SOUND_FLAG_NO_PITCH | ma.MA_SOUND_FLAG_NO_SPATIALIZATION,
            null,
            snd,
        );
        if (sound_result != ma.MA_SUCCESS) {
            _ = ma.ma_decoder_uninit(dec);
            self.allocator.destroy(dec);
            self.allocator.destroy(snd);
            self.decoder = null;
            self.setState(.@"error");
            return PlayerError.DecodeFailed;
        }
        _ = ma.ma_sound_set_volume(snd, self.volume);
        self.sound = snd;
    }

    /// ## pause — 暂停当前播放
    ///
    /// 仅在 `playing` 状态下生效，暂停后状态变为 `paused`。
    pub fn pause(self: *Player) !void {
        if (self.state != .playing) return;
        if (self.sound) |snd| _ = ma.ma_sound_stop(snd);
        self.setState(.paused);
    }

    /// ## stop — 停止播放并释放当前资源
    ///
    /// 释放声音对象、解码器和网络流源，回到 `stopped` 状态。
    /// 此方法是安全的：即使在未播放时调用也不会出错。
    pub fn stop(self: *Player) void {
        if (self.sound) |snd| {
            _ = ma.ma_sound_stop(snd);
            ma.ma_sound_uninit(snd);
            self.allocator.destroy(snd);
            self.sound = null;
        }
        if (self.decoder) |dec| {
            _ = ma.ma_decoder_uninit(dec);
            self.allocator.destroy(dec);
            self.decoder = null;
        }
        if (self.stream_source) |src| {
            src.deinit();
            self.stream_source = null;
        }
        if (self.state != .stopped) {
            self.setState(.stopped);
        }
    }

    /// ## resume — 恢复播放
    ///
    /// 仅在 `paused` 状态下生效，恢复后状态变为 `playing`。
    pub fn @"resume"(self: *Player) !void {
        if (self.state != .paused) return;
        if (self.sound) |snd| {
            _ = ma.ma_sound_start(snd);
            self.setState(.playing);
        }
    }

    /// ## seek — 跳转到指定位置
    ///
    /// 将播放位置跳转到指定的毫秒时间点。
    /// 内部通过采样率将毫秒转换为 PCM 帧号，再调用 miniaudio 的 seek 接口。
    ///
    /// - `position_ms` 目标位置，单位毫秒
    pub fn seek(self: *Player, position_ms: u64) !void {
        const snd = self.sound orelse return PlayerError.DecodeFailed;
        var sample_rate: u32 = 0;
        _ = ma.ma_sound_get_data_format(snd, null, null, &sample_rate, null, 0);
        if (sample_rate == 0) return PlayerError.DecodeFailed;
        // 毫秒 → PCM 帧：frame = ms × sampleRate / 1000
        const target_frame: u64 = position_ms * @as(u64, sample_rate) / 1000;
        _ = ma.ma_sound_seek_to_pcm_frame(snd, target_frame);
    }

    /// ## getState — 获取当前播放状态
    pub fn getState(self: *Player) PlaybackState {
        return self.state;
    }

    /// ## getProgress — 获取当前播放进度
    ///
    /// 返回当前位置和总时长（均为毫秒）。
    /// 通过 miniaudio 获取当前 PCM 帧位置和总帧数，
    /// 结合采样率转换为毫秒。
    pub fn getProgress(self: *Player) struct { position_ms: u64, duration_ms: u64 } {
        var duration_ms: u64 = 0;
        var position_ms: u64 = 0;
        if (self.sound) |snd| {
            var cursor: u64 = 0;
            _ = ma.ma_sound_get_cursor_in_pcm_frames(snd, &cursor);
            var sample_rate: u32 = 0;
            _ = ma.ma_sound_get_data_format(snd, null, null, &sample_rate, null, 0);
            if (sample_rate > 0) {
                // PCM 帧 → 毫秒：ms = frames × 1000 / sampleRate
                position_ms = cursor * 1000 / @as(u64, sample_rate);
            }
            var length: u64 = 0;
            _ = ma.ma_sound_get_length_in_pcm_frames(snd, &length);
            if (sample_rate > 0) {
                duration_ms = length * 1000 / @as(u64, sample_rate);
            }
        }
        return .{ .position_ms = position_ms, .duration_ms = duration_ms };
    }

    /// ## setVolume — 设置音量
    ///
    /// 将音量限制在 [0.0, 1.0] 范围内，并同步更新到当前声音对象。
    pub fn setVolume(self: *Player, vol: f32) void {
        self.volume = @max(0.0, @min(1.0, vol));
        if (self.sound) |snd| {
            _ = ma.ma_sound_set_volume(snd, self.volume);
        }
    }

    /// ## getVolume — 获取当前音量
    pub fn getVolume(self: *Player) f32 {
        return self.volume;
    }

    // ---- 播放队列操作 ----
    // 以下方法全部委托给内部 Playlist 实例，
    // Player 本身不维护队列逻辑，只做转发。

    /// 添加曲目到队列末尾
    pub fn enqueue(self: *Player, track: Track) !void {
        try self.playlist.add(track);
    }

    /// 添加曲目到当前播放位置之后（优先播放）
    pub fn enqueueNext(self: *Player, track: Track) !void {
        try self.playlist.addNext(track);
    }

    /// 从队列中移除指定位置的曲目
    pub fn removeFromQueue(self: *Player, index: usize) !void {
        try self.playlist.remove(index);
    }

    /// 清空播放队列
    pub fn clearQueue(self: *Player) void {
        self.playlist.clear();
    }

    /// 播放队列中的下一曲
    pub fn playNext(self: *Player) !void {
        const track = self.playlist.next() orelse return PlayerError.QueueEmpty;
        try self.play(track.url);
    }

    /// 播放队列中的上一曲
    pub fn playPrevious(self: *Player) !void {
        const track = self.playlist.previous() orelse return PlayerError.QueueEmpty;
        try self.play(track.url);
    }

    /// 播放队列中指定索引的曲目
    pub fn playAtIndex(self: *Player, index: usize) !void {
        const track = try self.playlist.jumpTo(index);
        try self.play(track.url);
    }

    // ---- 歌词功能 ----

    /// ## loadLyrics — 加载歌词
    ///
    /// 解析 LRC 格式的歌词内容。如果已有歌词会先释放旧数据。
    ///
    /// - `lrc_content` LRC 格式的歌词文本
    pub fn loadLyrics(self: *Player, lrc_content: []const u8) !void {
        if (self.lyrics_data) |*l| l.deinit();
        self.lyrics_data = try lyrics_parser.parse(self.allocator, lrc_content);
    }

    /// ## getCurrentLyric — 获取当前时间对应的歌词行
    ///
    /// 根据当前播放进度，查找时间匹配的歌词行。
    /// 返回 `null` 表示无歌词或当前时间没有匹配的歌词。
    pub fn getCurrentLyric(self: *Player) ?LyricLine {
        const progress = self.getProgress();
        const lrc = self.lyrics_data orelse return null;
        const idx = lrc.getLineAt(progress.position_ms) orelse return null;
        return lrc.lines.items[idx];
    }

    // ---- 回调注册 ----

    /// 注册播放状态变更回调
    pub fn onStateChanged(self: *Player, cb: StateCallback) void {
        self.on_state_changed = cb;
    }

    /// 注册播放进度更新回调
    pub fn onProgress(self: *Player, cb: ProgressCallback) void {
        self.on_progress = cb;
    }

    /// 注册曲目播放结束回调
    pub fn onTrackEnded(self: *Player, cb: TrackEndedCallback) void {
        self.on_track_ended = cb;
    }

    /// 注册错误回调
    pub fn onError(self: *Player, cb: ErrorCallback) void {
        self.on_error_cb = cb;
    }

    /// ## setState — 内部状态变更（含回调通知）
    ///
    /// 更新内部状态并触发已注册的 `on_state_changed` 回调。
    /// 这是所有状态变更的唯一出口，确保回调不会遗漏。
    fn setState(self: *Player, new_state: PlaybackState) void {
        self.state = new_state;
        if (self.on_state_changed) |cb| cb(new_state);
    }
};
