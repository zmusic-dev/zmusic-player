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

// ---- 翻译配对 ----

// 测试翻译歌词配对 — 时间差在阈值内
//
// 两行歌词时间差 ≤ 500ms 时，后一行视为前一行的翻译。
// 这里 1000ms 和 1020ms 相差 20ms，应配对。
test "translation pairing within threshold" {
    const input =
        \\[00:01.00]Line one
        \\[00:01.20]Translation
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(usize, 1), lyrics.lines.items.len);
    try std.testing.expectEqualStrings("Line one", lyrics.lines.items[0].text);
    try std.testing.expectEqualStrings("Translation", lyrics.lines.items[0].translation.?);
}

// 测试翻译歌词配对 — 恰好 500ms 边界
//
// 时间差恰好为 500ms 时仍应配对（≤ 500ms 条件）。
// [00:01.00] = 1000ms，[00:01.5] = 1500ms，差值 = 500ms。
test "translation pairing exact 500ms boundary" {
    const input =
        \\[00:01.00]Line one
        \\[00:01.5]Translation
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(usize, 1), lyrics.lines.items.len);
    try std.testing.expect(lyrics.lines.items[0].translation != null);
}

// 测试翻译歌词配对 — 超过 500ms 不配对
//
// 时间差超过 500ms 时不应配对，两行各自独立。
// [00:01.00] = 1000ms，[00:01.6] = 1600ms，差值 = 600ms。
test "translation pairing over 500ms not paired" {
    const input =
        \\[00:01.00]Line one
        \\[00:01.6]Line two
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(usize, 2), lyrics.lines.items.len);
    try std.testing.expect(lyrics.lines.items[0].translation == null);
    try std.testing.expect(lyrics.lines.items[1].translation == null);
}

// 测试翻译歌词配对 — 多组原文+翻译连续配对
//
// 多组原文和翻译交替出现时，每组都应正确配对，互不干扰。
test "translation pairing multiple pairs" {
    const input =
        \\[00:01.00]Line A
        \\[00:01.20]Trans A
        \\[00:05.00]Line B
        \\[00:05.20]Trans B
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(usize, 2), lyrics.lines.items.len);
    try std.testing.expectEqualStrings("Line A", lyrics.lines.items[0].text);
    try std.testing.expectEqualStrings("Trans A", lyrics.lines.items[0].translation.?);
    try std.testing.expectEqualStrings("Line B", lyrics.lines.items[1].text);
    try std.testing.expectEqualStrings("Trans B", lyrics.lines.items[1].translation.?);
}

// ---- 多时间戳行 ----

// 测试多时间戳行 — 两个时间戳生成两条独立歌词
//
// 一行歌词带有两个时间戳（如副歌重复），应为每个时间戳创建
// 独立的 LyricLine 条目，共享相同文本。
test "multi timestamp line creates two entries" {
    const input =
        \\[00:01.00][00:05.00]Chorus
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(usize, 2), lyrics.lines.items.len);
    try std.testing.expectEqual(@as(u64, 1000), lyrics.lines.items[0].time_ms);
    try std.testing.expectEqual(@as(u64, 5000), lyrics.lines.items[1].time_ms);
    try std.testing.expectEqualStrings("Chorus", lyrics.lines.items[0].text);
    try std.testing.expectEqualStrings("Chorus", lyrics.lines.items[1].text);
}

// 测试多时间戳行 — 三个时间戳
//
// 一行歌词带有三个时间戳，应创建三个独立的歌词行，
// 按时间戳升序排列。
test "multi timestamp line three timestamps" {
    const input =
        \\[00:01.00][00:05.00][00:10.00]Chorus
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(usize, 3), lyrics.lines.items.len);
    try std.testing.expectEqual(@as(u64, 1000), lyrics.lines.items[0].time_ms);
    try std.testing.expectEqual(@as(u64, 5000), lyrics.lines.items[1].time_ms);
    try std.testing.expectEqual(@as(u64, 10000), lyrics.lines.items[2].time_ms);
    try std.testing.expectEqualStrings("Chorus", lyrics.lines.items[0].text);
    try std.testing.expectEqualStrings("Chorus", lyrics.lines.items[1].text);
    try std.testing.expectEqualStrings("Chorus", lyrics.lines.items[2].text);
}

// ---- 偏移量边界 ----

// 测试负偏移量 — 时间戳减小
//
// offset 为负值时，所有时间戳应相应减小。
// 1000ms - 200ms = 800ms。
test "negative offset reduces timestamps" {
    const input =
        \\[offset:-200]
        \\[00:01.00]Hello
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(i32, -200), lyrics.metadata.offset_ms);
    try std.testing.expectEqual(@as(u64, 800), lyrics.lines.items[0].time_ms);
}

// 测试负偏移量 — 饱和到零
//
// 当负偏移量会使时间戳变为负数时，使用饱和运算确保不低于零。
// 1000ms - 2000ms → 饱和到 0ms。
test "negative offset saturates to zero" {
    const input =
        \\[offset:-2000]
        \\[00:01.00]Hello
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(u64, 0), lyrics.lines.items[0].time_ms);
}

// 测试大正偏移量
//
// 正偏移量应正常叠加到所有时间戳上。
// 1000ms + 10000ms = 11000ms。
test "large positive offset" {
    const input =
        \\[offset:10000]
        \\[00:01.00]Hello
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(u64, 11000), lyrics.lines.items[0].time_ms);
}

// ---- 时间戳格式变体 ----

// 测试时间戳格式 — 无小数部分 [mm:ss]
//
// 不带小数部分的时间戳精确到秒。
// [01:30] = 1×60000 + 30×1000 = 90000ms。
test "timestamp format without decimal" {
    const input =
        \\[01:30]Lyrics
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(u64, 90000), lyrics.lines.items[0].time_ms);
}

// 测试时间戳格式 — 一位小数 [mm:ss.x]
//
// 一位小数表示百毫秒精度（x × 100ms）。
// [01:30.5] = 90000 + 5×100 = 90500ms。
test "timestamp format single decimal" {
    const input =
        \\[01:30.5]Lyrics
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(u64, 90500), lyrics.lines.items[0].time_ms);
}

// 测试时间戳格式 — 三位小数截断为两位
//
// 三位小数时仅取前两位作为毫秒值（与两位小数等价）。
// [01:30.567] → 取 "56" → 90000 + 56 = 90056ms。
test "timestamp format three digits truncated" {
    const input =
        \\[01:30.567]Lyrics
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(u64, 90056), lyrics.lines.items[0].time_ms);
}

// ---- 元数据 ----

// 测试元数据 — by 标签解析为 author
//
// [by:value] 标签应解析为 metadata.author 字段。
test "metadata by tag" {
    const input =
        \\[by:author]
        \\[00:01.00]Hello
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqualStrings("author", lyrics.metadata.author.?);
}

// 测试元数据 — al 标签解析为 album
//
// [al:value] 标签应解析为 metadata.album 字段。
test "metadata al tag" {
    const input =
        \\[al:Album]
        \\[00:01.00]Hello
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqualStrings("Album", lyrics.metadata.album.?);
}

// 测试元数据 — 空值标签
//
// 元数据标签的值为空（如 [ti:]）时，应解析为空字符串而非 null。
test "metadata empty value" {
    const input =
        \\[ti:]
        \\[00:01.00]Hello
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expect(lyrics.metadata.title != null);
    try std.testing.expectEqualStrings("", lyrics.metadata.title.?);
}

// ---- 过滤 ----

// 测试过滤 — 有时间戳但文本为空的行
//
// 只有时间戳没有歌词文本的行应被过滤掉，不进入歌词行列表。
test "filter empty text line" {
    const input =
        \\[00:01.00]
        \\[00:05.00]Valid
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(usize, 1), lyrics.lines.items.len);
    try std.testing.expectEqualStrings("Valid", lyrics.lines.items[0].text);
}

// 测试过滤 — 有时间戳但文本仅含空白的行
//
// 时间戳后只有空白字符的行，经 trim 后文本为空，应被过滤掉。
test "filter whitespace only text line" {
    const input =
        \\[00:01.00]   
        \\[00:05.00]Valid
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(usize, 1), lyrics.lines.items.len);
    try std.testing.expectEqualStrings("Valid", lyrics.lines.items[0].text);
}

// ---- getLineAt 边界 ----

// 测试 getLineAt — 单行歌词精确时间匹配
//
// 只有一行歌词时，查询精确的时间戳应返回索引 0。
test "getLineAt single line exact time" {
    const input =
        \\[00:01.00]Only line
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(?usize, 0), lyrics.getLineAt(1000));
}

// 测试 getLineAt — 单行歌词查询早于第一行
//
// 查询时间早于唯一歌词行的时间戳（500ms < 1000ms），应返回 null。
test "getLineAt single line before" {
    const input =
        \\[00:01.00]Only line
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(?usize, null), lyrics.getLineAt(500));
}

// 测试 getLineAt — 单行歌词查询晚于第一行
//
// 查询时间晚于唯一歌词行的时间戳（5000ms > 1000ms），该行仍在显示，返回索引 0。
test "getLineAt single line after" {
    const input =
        \\[00:01.00]Only line
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    try std.testing.expectEqual(@as(?usize, 0), lyrics.getLineAt(5000));
}

// ---- applyOffset 边界（通过 parse 测试） ----

// 测试偏移量部分饱和
//
// 当负偏移量的绝对值大于某些时间戳但小于其他时间戳时，
// 超出部分饱和到零，其余正常计算。
// 第一行 1000ms - 2000ms → 饱和到 0；第二行 5000ms - 2000ms = 3000ms。
test "offset partial saturation" {
    const input =
        \\[offset:-2000]
        \\[00:01.00]First
        \\[00:05.00]Second
    ;
    var lyrics = try lyrics_parser.parse(std.testing.allocator, input);
    defer lyrics.deinit();

    // 1000ms - 2000ms 饱和到 0
    try std.testing.expectEqual(@as(u64, 0), lyrics.lines.items[0].time_ms);
    // 5000ms - 2000ms = 3000ms
    try std.testing.expectEqual(@as(u64, 3000), lyrics.lines.items[1].time_ms);
}
