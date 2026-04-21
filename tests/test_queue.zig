// 播放队列模块的单元测试
//
// 验证 Playlist 播放列表的核心功能，包括：
// - 曲目添加（追加和插入到当前曲目之后）
// - 前后导航（next/previous）
// - 曲目移除（含越界错误处理）
// - 循环模式（无循环/列表循环）
// - 跳转和清空操作
const std = @import("std");
const playlist_mod = @import("queue");

const Playlist = playlist_mod.Playlist;
const Track = playlist_mod.Track;

// 测试添加曲目和前后导航
//
// 验证基本播放流程：添加曲目后，current() 指向第一首；
// next() 推进到下一首，previous() 回退到上一首。
test "add and navigate" {
    const allocator = std.testing.allocator;
    var pl = Playlist.init(allocator);
    defer pl.deinit();

    // 按顺序添加三首曲目
    try pl.add(.{ .url = "a.mp3" });
    try pl.add(.{ .url = "b.mp3" });
    try pl.add(.{ .url = "c.mp3" });

    try std.testing.expectEqual(@as(usize, 3), pl.tracks.items.len);
    // 初始位置指向第一首曲目
    try std.testing.expectEqualStrings("a.mp3", pl.current().?.url);

    // next() 推进到第二首
    const n = pl.next();
    try std.testing.expect(n != null);
    try std.testing.expectEqualStrings("b.mp3", n.?.url);

    // previous() 回退到第一首
    const p = pl.previous();
    try std.testing.expect(p != null);
    try std.testing.expectEqualStrings("a.mp3", p.?.url);
}

// 测试在当前曲目后插入
//
// addNext 的设计意图是支持"下一首播放"功能——将曲目插入到
// 当前播放位置之后，而非追加到队列末尾。常用于用户点播场景。
test "addNext inserts after current" {
    const allocator = std.testing.allocator;
    var pl = Playlist.init(allocator);
    defer pl.deinit();

    // 队列: [a, c]，当前播放 a
    try pl.add(.{ .url = "a.mp3" });
    try pl.add(.{ .url = "c.mp3" });
    // 在 a 之后插入 b → 队列变为 [a, b, c]
    try pl.addNext(.{ .url = "b.mp3" });

    try std.testing.expectEqual(@as(usize, 3), pl.tracks.items.len);
    // b 应出现在索引 1 的位置（a 之后）
    try std.testing.expectEqualStrings("b.mp3", pl.tracks.items[1].url);
}

// 测试移除指定位置的曲目
//
// 验证移除中间曲目后，剩余曲目自动前移填补空位，
// 列表长度和顺序保持正确。
test "remove track" {
    const allocator = std.testing.allocator;
    var pl = Playlist.init(allocator);
    defer pl.deinit();

    try pl.add(.{ .url = "a.mp3" });
    try pl.add(.{ .url = "b.mp3" });
    try pl.add(.{ .url = "c.mp3" });

    // 移除索引 1（b.mp3）后，队列变为 [a, c]
    try pl.remove(1);
    try std.testing.expectEqual(@as(usize, 2), pl.tracks.items.len);
    try std.testing.expectEqualStrings("a.mp3", pl.tracks.items[0].url);
    try std.testing.expectEqualStrings("c.mp3", pl.tracks.items[1].url);
}

// 测试越界删除的错误处理
//
// 尝试删除不存在的索引应返回 IndexOutOfBounds 错误，
// 而非静默忽略或触发未定义行为。
test "remove out of bounds" {
    const allocator = std.testing.allocator;
    var pl = Playlist.init(allocator);
    defer pl.deinit();

    try pl.add(.{ .url = "a.mp3" });
    // 队列只有 1 首曲目，索引 5 远超范围
    const result = pl.remove(5);
    try std.testing.expectError(error.IndexOutOfBounds, result);
}

// 测试无循环模式在队列末尾停止
//
// 默认的 RepeatMode.none 下，播放到最后一首后再调用 next()
// 应返回 null，表示队列已播放完毕。
test "repeat mode none stops at end" {
    const allocator = std.testing.allocator;
    var pl = Playlist.init(allocator);
    defer pl.deinit();

    try pl.add(.{ .url = "a.mp3" });
    try pl.add(.{ .url = "b.mp3" });

    // 第一次 next(): a → b
    _ = pl.next();
    // 第二次 next(): 已到末尾，无循环模式下返回 null
    const end = pl.next();
    try std.testing.expect(end == null);
}

// 测试列表循环模式在队列末尾回到开头
//
// RepeatMode.all 下，播放到最后一首后再调用 next()
// 应回到第一首，实现无限循环播放。
test "repeat mode all wraps" {
    const allocator = std.testing.allocator;
    var pl = Playlist.init(allocator);
    defer pl.deinit();

    try pl.add(.{ .url = "a.mp3" });
    try pl.add(.{ .url = "b.mp3" });
    // 启用列表循环模式
    pl.setRepeatMode(.all);

    // 第一次 next(): a → b
    _ = pl.next();
    // 第二次 next(): b → a（循环回到开头）
    const wrapped = pl.next();
    try std.testing.expect(wrapped != null);
    try std.testing.expectEqualStrings("a.mp3", wrapped.?.url);
}

// 测试跳转到指定位置
//
// jumpTo 允许用户直接跳到任意索引的曲目（如点击播放列表中的某首歌），
// 同时更新当前播放指针。
test "jumpTo" {
    const allocator = std.testing.allocator;
    var pl = Playlist.init(allocator);
    defer pl.deinit();

    try pl.add(.{ .url = "a.mp3" });
    try pl.add(.{ .url = "b.mp3" });
    try pl.add(.{ .url = "c.mp3" });

    // 直接跳到索引 2（c.mp3）
    const track = try pl.jumpTo(2);
    try std.testing.expectEqualStrings("c.mp3", track.url);
    // 当前播放指针应同步更新
    try std.testing.expectEqual(@as(usize, 2), pl.current_index);
}

// 测试清空队列
//
// 清空后队列长度应为 0，且 current() 返回 null（无当前曲目）。
// 用于停止播放并重置播放列表的场景。
test "clear" {
    const allocator = std.testing.allocator;
    var pl = Playlist.init(allocator);
    defer pl.deinit();

    try pl.add(.{ .url = "a.mp3" });
    try pl.add(.{ .url = "b.mp3" });
    pl.clear();

    try std.testing.expectEqual(@as(usize, 0), pl.tracks.items.len);
    // 清空后没有当前曲目
    try std.testing.expect(pl.current() == null);
}
