// Player 播放器核心模块的单元测试
//
// 验证 Player 顶层 API 的非音频功能，包括：
// - 生命周期（init/deinit，不触发音频引擎）
// - 音量控制（边界值和正常值）
// - 播放队列委托（增删清空、空队列错误）
// - 状态机（非播放状态下的暂停/恢复/轮询）
// - 歌词加载与查询
// - 回调注册
//
// 注意：所有测试均不调用 play()，避免触发 miniaudio 音频引擎初始化。
const std = @import("std");
const player_mod = @import("player");
const Player = player_mod.Player;
const PlaybackState = player_mod.PlaybackState;
const Track = player_mod.Track;

// ==================== 生命周期测试 ====================

// 测试初始化状态
//
// Player.init() 应创建一个处于 stopped 状态的实例，
// 默认音量为 1.0，且不需要音频设备。
test "init state is stopped" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    try std.testing.expectEqual(PlaybackState.stopped, p.getState());
    try std.testing.expectEqual(@as(f32, 1.0), p.getVolume());
}

// 测试不播放直接 deinit
//
// 验证 init 后立即 deinit 不会崩溃。
// 这对应"创建 Player 但未播放就销毁"的使用场景。
test "deinit without play" {
    var p = try Player.init(std.testing.allocator);
    p.deinit();
}

// ==================== 音量控制测试 ====================

// 测试音量负值钳位
//
// setVolume 应将负值钳位到 0.0，防止音量越界。
test "set volume clamps negative" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    p.setVolume(-0.5);
    try std.testing.expectEqual(@as(f32, 0.0), p.getVolume());
}

// 测试音量超过 1.0 钳位
//
// setVolume 应将超过 1.0 的值钳位到 1.0。
test "set volume clamps over 1" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    p.setVolume(1.5);
    try std.testing.expectEqual(@as(f32, 1.0), p.getVolume());
}

// 测试音量边界值
//
// 0.0 和 1.0 都是合法边界值，不应被修改。
test "set volume boundary values" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    p.setVolume(0.0);
    try std.testing.expectEqual(@as(f32, 0.0), p.getVolume());

    p.setVolume(1.0);
    try std.testing.expectEqual(@as(f32, 1.0), p.getVolume());
}

// 测试音量正常值设置
//
// 验证在合法范围内的音量值能被正确存储和读取。
test "set volume normal" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    p.setVolume(0.5);
    try std.testing.expectEqual(@as(f32, 0.5), p.getVolume());
}

// ==================== 播放队列操作测试 ====================

// 测试添加曲目到队列
//
// 连续 enqueue 三首曲目后，内部播放列表应包含三首。
test "enqueue adds tracks" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    try p.enqueue(.{ .url = "a.mp3" });
    try p.enqueue(.{ .url = "b.mp3" });
    try p.enqueue(.{ .url = "c.mp3" });

    try std.testing.expectEqual(@as(usize, 3), p.playlist.tracks.items.len);
}

// 测试 enqueueNext 在当前曲目后插入
//
// addNext 的设计意图是支持"下一首播放"功能——将曲目插入到
// 当前播放位置之后。先添加 a、c 两首，再在当前位置后插入 b，
// 队列顺序应变为 [a, b, c]。
test "enqueueNext inserts after current" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    try p.enqueue(.{ .url = "a.mp3" });
    try p.enqueue(.{ .url = "c.mp3" });
    try p.enqueueNext(.{ .url = "b.mp3" });

    try std.testing.expectEqual(@as(usize, 3), p.playlist.tracks.items.len);
    try std.testing.expectEqualStrings("b.mp3", p.playlist.tracks.items[1].url);
}

// 测试从队列中移除曲目
//
// 添加三首后移除索引 1，应剩两首且顺序正确。
test "removeFromQueue removes track" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    try p.enqueue(.{ .url = "a.mp3" });
    try p.enqueue(.{ .url = "b.mp3" });
    try p.enqueue(.{ .url = "c.mp3" });

    try p.removeFromQueue(1);
    try std.testing.expectEqual(@as(usize, 2), p.playlist.tracks.items.len);
    try std.testing.expectEqualStrings("a.mp3", p.playlist.tracks.items[0].url);
    try std.testing.expectEqualStrings("c.mp3", p.playlist.tracks.items[1].url);
}

// 测试清空播放队列
//
// 添加曲目后调用 clearQueue，队列应为空。
test "clearQueue empties list" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    try p.enqueue(.{ .url = "a.mp3" });
    try p.enqueue(.{ .url = "b.mp3" });
    p.clearQueue();

    try std.testing.expectEqual(@as(usize, 0), p.playlist.tracks.items.len);
}

// 测试空队列时 playNext 返回错误
//
// 当队列为空时调用 playNext，应返回 QueueEmpty 错误，
// 而非崩溃或静默忽略。
test "playNext empty queue returns error" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    try std.testing.expectError(error.QueueEmpty, p.playNext());
}

// 测试空队列时 playPrevious 返回错误
//
// 当队列为空时调用 playPrevious，应返回 QueueEmpty 错误。
test "playPrevious empty queue returns error" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    try std.testing.expectError(error.QueueEmpty, p.playPrevious());
}

// ==================== 状态机测试（无音频） ====================

// 测试 stopped 状态下 pause 无效
//
// pause() 仅在 playing 状态下生效。在 stopped 状态调用后，
// 状态应保持 stopped 不变。
test "pause when stopped does nothing" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    try p.pause();
    try std.testing.expectEqual(PlaybackState.stopped, p.getState());
}

// 测试 stopped 状态下 resume 无效
//
// resume() 仅在 paused 状态下生效。在 stopped 状态调用后，
// 状态应保持 stopped 不变。
test "resume when stopped does nothing" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    try p.@"resume"();
    try std.testing.expectEqual(PlaybackState.stopped, p.getState());
}

// 测试 stopped 状态下 tick 返回 false
//
// tick() 仅在 playing 状态下处理进度和结束检测。
// 在 stopped 状态应直接返回 false。
test "tick when stopped returns false" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    try std.testing.expectEqual(false, p.tick());
}

// ==================== 歌词功能测试 ====================

// 测试加载和解析歌词
//
// 加载有效的 LRC 内容后，歌词数据应被正确解析。
test "loadLyrics and parse" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    const lrc =
        \\[00:01.00]First line
        \\[00:05.00]Second line
    ;
    try p.loadLyrics(lrc);

    try std.testing.expect(p.lyrics_data != null);
    try std.testing.expectEqual(@as(usize, 2), p.lyrics_data.?.lines.items.len);
    try std.testing.expectEqualStrings("First line", p.lyrics_data.?.lines.items[0].text);
}

// 测试未播放时 getCurrentLyric 返回 null
//
// 未调用 play() 时没有播放进度，getCurrentLyric 依赖 getProgress()
// 返回的 position_ms，在 stopped 状态下 position 为 0。
// 如果第一行歌词时间戳大于 0，则没有匹配的歌词行。
test "getCurrentLyric without play returns null" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    const lrc =
        \\[00:01.00]First line
        \\[00:05.00]Second line
    ;
    try p.loadLyrics(lrc);

    // position_ms 为 0，第一行歌词在 1000ms，因此没有匹配
    try std.testing.expectEqual(@as(?player_mod.LyricLine, null), p.getCurrentLyric());
}

// 测试重复加载歌词会替换旧数据
//
// 连续两次调用 loadLyrics，第二次应替换第一次的内容。
// 验证不会造成内存泄漏（旧数据被正确释放）。
test "loadLyrics replaces previous" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    // 第一次加载
    const lrc1 =
        \\[00:01.00]First set
    ;
    try p.loadLyrics(lrc1);
    try std.testing.expectEqual(@as(usize, 1), p.lyrics_data.?.lines.items.len);

    // 第二次加载，应替换为新的歌词
    const lrc2 =
        \\[00:02.00]Second set line 1
        \\[00:06.00]Second set line 2
        \\[00:10.00]Second set line 3
    ;
    try p.loadLyrics(lrc2);
    try std.testing.expectEqual(@as(usize, 3), p.lyrics_data.?.lines.items.len);
    try std.testing.expectEqualStrings("Second set line 1", p.lyrics_data.?.lines.items[0].text);
}

// ==================== 回调注册测试 ====================

// 测试回调注册不崩溃
//
// 由于无法在不播放音频的情况下触发状态变更，
// 此测试仅验证回调注册接口可正常调用，不会引发崩溃。
test "callback registration does not crash" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    p.onStateChanged(struct {
        fn callback(_: ?*anyopaque, _: PlaybackState) void {}
    }.callback);
    p.onProgress(struct {
        fn callback(_: ?*anyopaque, _: u64, _: u64) void {}
    }.callback);
    p.onTrackEnded(struct {
        fn callback(_: ?*anyopaque) void {}
    }.callback);
    p.onError(struct {
        fn callback(_: ?*anyopaque, _: player_mod.PlayerError) void {}
    }.callback);
    p.setCallbackContext(null);
}

// 测试注册回调后 tick 在 stopped 状态仍返回 false
//
// 回调注册不应影响 tick 在非播放状态下的行为。
test "tick returns false with callbacks registered" {
    var p = try Player.init(std.testing.allocator);
    defer p.deinit();

    p.onProgress(struct {
        fn callback(_: ?*anyopaque, _: u64, _: u64) void {}
    }.callback);

    try std.testing.expectEqual(false, p.tick());
}
