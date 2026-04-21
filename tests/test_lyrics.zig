// 歌词解析模块的单元测试
//
// 验证 LRC 格式歌词的解析能力，包括：
// - 标准 LRC 元数据（标题/艺术家/专辑）和时间戳行的解析
// - 时间偏移量（offset）的正确应用
// - 基于时间戳的歌词行查找（二分搜索）
// - 空输入和畸形输入的容错处理
const std = @import("std");
const lyrics_parser = @import("lyrics_parser");
const lyrics_types = @import("lyrics");

// 测试标准 LRC 格式解析（元数据 + 时间戳行）
//
// 验证解析器能正确提取 LRC 头部的元数据字段（ti/ar/al），
// 以及将时间戳行转化为有序的歌词行列表。
test "parse standard LRC" {
    const input =
        \\[ti:Test Song]
        \\[ar:Artist Name]
        \\[al:Test Album]
        \\[00:01.00]First line
        \\[00:05.50]Second line
        \\[00:10.00]Third line
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    // 验证元数据字段被正确提取
    try std.testing.expectEqualStrings("Test Song", lyrics.metadata.title.?);
    try std.testing.expectEqualStrings("Artist Name", lyrics.metadata.artist.?);
    try std.testing.expectEqualStrings("Test Album", lyrics.metadata.album.?);
    // 三行带时间戳的歌词应全部解析
    try std.testing.expectEqual(@as(usize, 3), lyrics.lines.items.len);
}

// 测试时间偏移量应用
//
// LRC 格式支持 [offset:ms] 标签，表示所有时间戳需要加上该偏移量。
// 这里 offset=500 表示时间戳需要向后偏移 500ms，
// 所以 [00:01.00]（1000ms）应变为 1500ms。
test "parse with offset" {
    const input =
        \\[offset:500]
        \\[00:01.00]Hello
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    // 验证偏移量被记录
    try std.testing.expectEqual(@as(i32, 500), lyrics.metadata.offset_ms);
    // 原始时间 1000ms + 偏移 500ms = 1500ms
    try std.testing.expectEqual(@as(u64, 1500), lyrics.lines.items[0].time_ms);
}

// 测试基于时间戳的歌词行查找（二分搜索）
//
// getLineAt 根据给定的时间位置返回当前应显示的歌词行索引。
// 内部使用二分搜索，时间复杂度 O(log n)。
// 测试覆盖了：行内时间、行间时间、最后一行之后、第一行之前（应返回 null）。
test "getLineAt basic" {
    const input =
        \\[00:01.00]First
        \\[00:05.00]Second
        \\[00:10.00]Third
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    // 1500ms 落在第一行 [00:01.00] 之后、第二行之前 → 索引 0
    try std.testing.expectEqual(@as(?usize, 0), lyrics.getLineAt(1500));
    // 7000ms 落在第二行 [00:05.00] 之后、第三行之前 → 索引 1
    try std.testing.expectEqual(@as(?usize, 1), lyrics.getLineAt(7000));
    // 15000ms 在最后一行 [00:10.00] 之后 → 索引 2
    try std.testing.expectEqual(@as(?usize, 2), lyrics.getLineAt(15000));
    // 500ms 在第一行 [00:01.00] 之前 → 无匹配，返回 null
    try std.testing.expectEqual(@as(?usize, null), lyrics.getLineAt(500));
}

// 测试空输入的容错处理
//
// 空字符串不应导致解析崩溃，而应返回一个不含任何歌词行的空结果。
test "empty lyrics" {
    const input = "";
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();
    try std.testing.expectEqual(@as(usize, 0), lyrics.lines.items.len);
}

// 测试畸形输入的过滤（垃圾行和无效时间戳）
//
// LRC 文件中可能混杂无法识别的行（纯文本、无效标签格式等），
// 解析器应静默忽略这些行，仅保留格式正确的时间戳行。
test "malformed input ignored" {
    const input =
        \\garbage line
        \\[00:01.00]Valid line
        \\also garbage
        \\[invalid]Not a timestamp
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();
    // 只有 [00:01.00]Valid line 是有效的时间戳行
    try std.testing.expectEqual(@as(usize, 1), lyrics.lines.items.len);
}
