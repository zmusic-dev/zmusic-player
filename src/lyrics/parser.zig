//! LRC 歌词解析器模块
//!
//! 本模块实现了 LRC 格式歌词的完整解析流程，支持标准 LRC 格式和翻译歌词。
//!
//! 解析流程：编码检测 → 逐行扫描 → 元数据提取 → 时间戳解析 → 排序 → 翻译配对 → 应用偏移
//!
//! 在整体架构中，本模块是歌词子系统的数据入口，负责将原始 LRC 文本转换为
//! 结构化的 `Lyrics` 对象，供歌词渲染器使用。
//!
//! 翻译歌词的配对策略：如果两行歌词的时间戳差值不超过 500ms，
//! 则将后一行视为前一行的翻译。这是业界常见的翻译歌词排版约定。
//!
//! ## 编码处理
//!
//! 中文 LRC 歌词文件常见 GBK 编码（尤其是国内音乐平台），本模块在解析前
//! 自动检测编码：先验证 UTF-8 有效性，如果无效则尝试通过 iconv 将 GBK
//! 转换为 UTF-8。iconv 在 Linux（glibc 内置）和 macOS（libiconv）上可用。
//! Windows 目标暂不支持 GBK 自动转换（Zig 交叉编译工具链未包含 libiconv），
//! 非 UTF-8 内容将原样传递给解析器尽力处理。

const std = @import("std");
const builtin = @import("builtin");
const types = @import("lyrics_types");

const LyricLine = types.LyricLine;
const LrcMetadata = types.LrcMetadata;
const Lyrics = types.Lyrics;

// ---- iconv C 函数声明（仅 Linux / macOS） ----
// 用于 GBK → UTF-8 编码转换。Linux 通过 glibc 内置 iconv，macOS 通过 libiconv。
// Windows 目标不链接 iconv，编译时通过条件编译排除相关代码。

/// iconv 转换描述符，实际类型为 opaque 指针。
const IconvT = opaque {};

const has_iconv = builtin.os.tag != .windows;

extern fn iconv_open(tocode: [*:0]const u8, fromcode: [*:0]const u8) ?*IconvT;
extern fn iconv(
    cd: *IconvT,
    inbuf: *?[*]const u8,
    inbytesleft: *usize,
    outbuf: *?[*]u8,
    outbytesleft: *usize,
) usize;
extern fn iconv_close(cd: *IconvT) c_int;

/// 将非 UTF-8 内容从 GBK 转换为 UTF-8。
///
/// 采用启发式策略：先用 `std.unicode.utf8Validate` 检查 UTF-8 有效性，
/// 如果无效则假设为 GBK 编码并通过 iconv 转换。转换失败时返回原始内容，
/// 让后续解析逻辑尽力处理（不会导致整体失败）。
///
/// Windows 目标不支持 iconv，非 UTF-8 内容将原样返回。
///
/// 参数：
///   `allocator` - 内存分配器，用于分配转换后的 UTF-8 缓冲区
///   `content`   - 原始 LRC 文件内容
///
/// 返回：UTF-8 编码的内容切片。如果是新分配的缓冲区，调用方负责释放。
fn ensureUtf8(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    // 如果已经是合法 UTF-8，直接返回
    if (std.unicode.utf8ValidateSlice(content)) return content;

    // Windows 目标不链接 iconv，非 UTF-8 内容原样返回
    if (!has_iconv) return content;

    // 尝试通过 iconv 从 GBK 转换为 UTF-8
    const cd = iconv_open("UTF-8", "GBK") orelse return content;
    defer _ = iconv_close(cd);

    // GBK → UTF-8 最坏情况下每个字节扩展为 3 字节（中文字符），
    // 预留额外空间避免反复扩展
    const out_len = content.len * 3;
    const out_buf = try allocator.alloc(u8, out_len);

    var in_ptr: ?[*]const u8 = content.ptr;
    var in_left: usize = content.len;
    var out_ptr: ?[*]u8 = out_buf.ptr;
    var out_left: usize = out_len;

    const result = iconv(cd, &in_ptr, &in_left, &out_ptr, &out_left);
    _ = result;

    const converted_len = out_len - out_left;
    if (converted_len == 0) {
        // 转换失败（可能是非 GBK 编码），释放缓冲区并返回原始内容
        allocator.free(out_buf);
        return content;
    }

    // 截断到实际转换长度
    return allocator.realloc(out_buf, converted_len) catch out_buf[0..converted_len];
}

/// 解析中间态：原始歌词行
///
/// 在排序和翻译配对之前，每行歌词以原始时间戳和文本表示。
/// 与 `LyricLine` 的区别是没有 `translation` 字段，翻译配对
/// 在后续阶段完成。
const RawLine = struct { time_ms: u64, text: []const u8 };

/// 解析 LRC 格式歌词内容为结构化的 `Lyrics` 对象
///
/// 整体流程：
/// 1. 逐行扫描 LRC 文本，跳过空行
/// 2. 尝试解析元数据标签（`[ti:]`、`[ar:]` 等）
/// 3. 对非元数据行解析时间戳前缀和歌词文本
/// 4. 支持一行多时间戳（如 `[00:01.00][00:05.00]歌词`），为每个时间戳创建独立的原始行
/// 5. 按时间戳排序所有原始行
/// 6. 配对翻译歌词（时间差 ≤ 500ms 的相邻行视为原文+翻译）
/// 7. 应用全局时间偏移（`[offset:]` 标签）
///
/// 参数：
/// - `allocator`：内存分配器，用于分配歌词文本和元数据字符串的内存
/// - `content`：LRC 文件的原始文本内容
///
/// 返回：解析完成的 `Lyrics` 对象，调用者负责在使用后调用 `deinit`
///
/// 错误：内存分配失败时返回相应的错误
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Lyrics {
    // 编码预处理：检测并转换 GBK 等非 UTF-8 编码为 UTF-8。
    // 如果触发了转换，converted_content 为新分配的缓冲区，函数结束时释放。
    const converted_content = try ensureUtf8(allocator, content);
    defer {
        // 只有当 ensureUtf8 分配了新缓冲区时才释放
        // （如果内容已经是 UTF-8，返回的切片等于原始 content，不持有独立内存）
        if (converted_content.ptr != content.ptr) {
            allocator.free(converted_content);
        }
    }

    var lyrics = Lyrics.init(allocator);
    // 解析失败时自动清理已分配的 Lyrics 资源
    errdefer lyrics.deinit();

    var metadata = LrcMetadata{};
    // raw_lines 是解析中间态，函数退出时释放其中所有文本内存
    var raw_lines = std.array_list.Managed(RawLine).init(allocator);
    defer {
        for (raw_lines.items) |item| allocator.free(item.text);
        raw_lines.deinit();
    }

    // 第一阶段：逐行扫描，提取元数据和带时间戳的歌词行
    var lines = std.mem.splitSequence(u8, converted_content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // 优先尝试解析元数据标签
        if (try parseMetadataTag(trimmed)) |tag| {
            switch (tag) {
                .title => |v| metadata.title = try allocator.dupe(u8, v),
                .artist => |v| metadata.artist = try allocator.dupe(u8, v),
                .album => |v| metadata.album = try allocator.dupe(u8, v),
                .author => |v| metadata.author = try allocator.dupe(u8, v),
                .offset => |v| metadata.offset_ms = v,
            }
            continue;
        }

        // 尝试解析行首的时间戳序列
        var parser = TimestampParser.init(trimmed);
        const ts_list = parser.parseTimestamps();
        if (ts_list.len == 0) continue;

        // 时间戳之后的部分就是歌词文本
        const text = std.mem.trim(u8, TimestampParser.remainder(&parser), " \t\r");
        if (text.len == 0) continue;

        // 一行多时间戳场景：为每个时间戳创建独立的原始行，共享同一文本
        // 每个副本都需要独立的 owned 内存，因为后续翻译配对可能会释放部分副本
        for (ts_list) |time_ms| {
            const owned_text = try allocator.dupe(u8, text);
            try raw_lines.append(.{ .time_ms = time_ms, .text = owned_text });
        }
    }

    // 第二阶段：按时间戳升序排序
    std.mem.sort(RawLine, raw_lines.items, {}, cmpLines);

    // 第三阶段：翻译配对
    var i: usize = 0;
    while (i < raw_lines.items.len) : (i += 1) {
        const current_ms = raw_lines.items[i].time_ms;
        const current_text = raw_lines.items[i].text;

        var translation: ?[]const u8 = null;
        if (i + 1 < raw_lines.items.len) {
            const next_ms = raw_lines.items[i + 1].time_ms;
            // 计算相邻两行的时间差，使用 i64 避免无符号减法回绕
            const diff: i64 = @as(i64, @intCast(next_ms)) - @as(i64, @intCast(current_ms));
            // 翻译歌词的配对条件：时间差在 [0, 500ms] 范围内
            // 500ms 阈值基于翻译歌词通常与原文几乎同时出现的惯例
            if (diff >= 0 and diff <= 500) {
                translation = raw_lines.items[i + 1].text;
                // 配对成功后释放原文的 text 所有权（翻译行会接管显示），
                // 因为当前行的 text 将直接使用 current_text 指针
                allocator.free(raw_lines.items[i].text);
                _ = raw_lines.orderedRemove(i);
            }
        }

        try lyrics.lines.append(.{
            .time_ms = current_ms,
            // text 字段：如果存在翻译，使用 raw_lines 中对应行的 text（已排序配对后）；
            // 否则使用原始的 current_text。这里的条件分支处理了 orderedRemove 后
            // 索引可能偏移的情况
            .text = if (translation != null) raw_lines.items[if (i > 0 and raw_lines.items[i - 1].time_ms == current_ms) i else i].text else current_text,
            .translation = translation,
        });
    }

    // 第四阶段：应用全局时间偏移
    lyrics.metadata = metadata;
    lyrics.applyOffset(metadata.offset_ms);
    return lyrics;
}

/// 原始歌词行的比较函数，用于按时间戳升序排序
fn cmpLines(_: void, a: RawLine, b: RawLine) bool {
    return a.time_ms < b.time_ms;
}

/// 元数据标签联合类型
///
/// LRC 文件中 `[key:value]` 格式的元数据标签，解析后以联合类型表示。
/// 字符串字段指向原始输入中的切片（零拷贝），在 `parse` 函数中再
/// 由分配器拷贝为独立内存。
const MetadataTag = union(enum) {
    /// 歌曲标题 `[ti:value]`
    title: []const u8,
    /// 艺术家 `[ar:value]`
    artist: []const u8,
    /// 专辑 `[al:value]`
    album: []const u8,
    /// LRC 制作者 `[by:value]`
    author: []const u8,
    /// 全局时间偏移 `[offset:value]`，单位毫秒
    offset: i32,
};

/// 尝试从一行文本中解析 LRC 元数据标签
///
/// 仅匹配 `[key:value]` 格式，其中 key 为已知的元数据标识符。
/// `offset` 标签需要特殊处理（解析为整数），其余标签直接取字符串值。
/// 无法识别的标签格式返回 null，由调用方决定是否当作歌词行处理。
///
/// 参数：
/// - `line`：已去除首尾空白的一行文本
///
/// 返回：成功解析则返回对应的 `MetadataTag`，否则返回 null
fn parseMetadataTag(line: []const u8) !?MetadataTag {
    // 最短的有效元数据标签形如 `[x:]`，至少需要 4 个字符
    if (line.len < 4 or line[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, line, ']') orelse return null;
    const inner = line[1..close];

    // 元数据标签必须包含冒号分隔 key 和 value
    const colon_pos = std.mem.indexOfScalar(u8, inner, ':') orelse return null;
    const key = inner[0..colon_pos];
    const value = if (colon_pos + 1 < inner.len) inner[colon_pos + 1 ..] else "";

    // offset 标签需要解析为有符号整数，单独处理
    if (std.mem.eql(u8, key, "offset")) {
        const trimmed_val = std.mem.trim(u8, value, " \t");
        const offset = std.fmt.parseInt(i32, trimmed_val, 10) catch return null;
        return MetadataTag{ .offset = offset };
    }

    // LRC 标准元数据标签映射表
    const tags = .{
        .{ "ti", "title" },
        .{ "ar", "artist" },
        .{ "al", "album" },
        .{ "by", "author" },
    };
    // 使用 inline for 在编译期展开循环，生成直接匹配代码，避免运行时字符串比较开销
    inline for (tags) |tag_pair| {
        if (std.mem.eql(u8, key, tag_pair[0])) {
            // @unionInit 通过编译期字段名初始化联合类型，这里利用 tag_pair[1] 作为字段名
            return @unionInit(MetadataTag, tag_pair[1], value);
        }
    }

    return null;
}

/// 时间戳解析器
///
/// 负责从一行歌词的开头提取所有时间戳标签（如 `[00:01.23]`），
/// 并返回时间戳之后的歌词文本。
///
/// 支持一行多时间戳的场景，最多解析 8 个时间戳，覆盖绝大多数实际需求。
/// 例如 `[00:10.00][00:30.00]合唱歌词` 表示该歌词在两个时间点都应显示。
const TimestampParser = struct {
    /// 待解析的输入文本（一整行歌词）
    input: []const u8,
    /// 当前解析位置
    pos: usize,
    /// 时间戳缓冲区，固定大小 8，避免动态分配
    /// 实际场景中一行歌词极少超过 8 个时间戳
    timestamps: [8]u64,
    /// 已解析的时间戳数量
    timestamp_count: usize,
    /// 时间戳结束后歌词文本的起始位置
    remainder_start: usize,

    /// 创建解析器实例
    ///
    /// 参数：
    /// - `input`：一整行歌词文本（可能包含多个时间戳前缀）
    fn init(input: []const u8) @This() {
        return .{
            .input = input,
            .pos = 0,
            .timestamps = undefined,
            .timestamp_count = 0,
            .remainder_start = 0,
        };
    }

    /// 获取时间戳之后的歌词文本
    ///
    /// 必须在 `parseTimestamps` 之后调用。返回的切片指向原始输入中的子串，
    /// 不涉及内存分配。
    fn remainder(self: *const @This()) []const u8 {
        if (self.remainder_start >= self.input.len) return "";
        return self.input[self.remainder_start..];
    }

    /// 解析行首的所有时间戳标签
    ///
    /// 从当前位置开始，逐个匹配 `[mm:ss.xx]` 格式的时间戳。
    /// 遇到非时间戳格式或已达到缓冲区上限（8 个）时停止。
    ///
    /// 返回：解析出的时间戳切片（毫秒），指向内部缓冲区
    fn parseTimestamps(self: *@This()) []u64 {
        while (self.timestamp_count < self.timestamps.len) {
            if (self.pos >= self.input.len) break;
            // 时间戳必须以 '[' 开头
            if (self.input[self.pos] != '[') break;

            const close = std.mem.indexOfScalarPos(u8, self.input, self.pos, ']') orelse break;
            const inner = self.input[self.pos + 1 .. close];

            // 尝试解析方括号内的内容为时间戳，失败则停止（可能不是时间戳）
            const ts = parseTimestamp(inner) orelse break;
            self.timestamps[self.timestamp_count] = ts;
            self.timestamp_count += 1;
            self.pos = close + 1;
        }
        // 记录歌词文本的起始位置
        self.remainder_start = self.pos;
        return self.timestamps[0..self.timestamp_count];
    }

    /// 将 `[mm:ss.xx]` 或 `[mm:ss]` 格式的时间戳转换为毫秒值
    ///
    /// 支持的格式：
    /// - `[mm:ss]` — 精确到秒
    /// - `[mm:ss.x]` — 精确到百毫秒（x * 100ms）
    /// - `[mm:ss.xx]` — 精确到十毫秒（xx * 10ms）
    /// - `[mm:ss.xxx]` — 精确到毫秒，仅取前两位（与 xx 等价）
    ///
    /// 参数：
    /// - `text`：方括号内的时间戳文本，如 `"01:23.45"`
    ///
    /// 返回：转换后的毫秒值，解析失败返回 null
    fn parseTimestamp(text: []const u8) ?u64 {
        // 最短的有效时间戳为 `0:0`，至少 3 个字符，加上至少 1 位秒数共 4 字符
        if (text.len < 4) return null;

        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
        const minutes = std.fmt.parseInt(u64, text[0..colon], 10) catch return null;

        const rest = text[colon + 1 ..];
        const dot = std.mem.indexOfScalar(u8, rest, '.');

        if (dot) |d| {
            const seconds = std.fmt.parseInt(u64, rest[0..d], 10) catch return null;
            const frac_str = rest[d + 1 ..];
            // 小数部分的解析取决于位数：
            // - 0 位：无小数部分，计为 0ms
            // - 1 位：百毫秒精度，乘以 100 转换为毫秒（如 "5" → 500ms）
            // - 2+ 位：十毫秒/毫秒精度，直接取前两位作为毫秒值
            //   （如 "45" → 450ms，"456" → 450ms 截断）
            const frac = if (frac_str.len == 0)
                @as(u64, 0)
            else if (frac_str.len == 1)
                @as(u64, @intCast(std.fmt.parseUnsigned(u8, frac_str, 10) catch return null)) * 100
            else
                std.fmt.parseUnsigned(u64, if (frac_str.len > 2) frac_str[0..2] else frac_str, 10) catch return null;

            const total_ms = minutes * 60 * 1000 + seconds * 1000 + frac;
            return total_ms;
        } else {
            // 无小数点格式 `[mm:ss]`，精确到秒
            const seconds = std.fmt.parseInt(u64, rest, 10) catch return null;
            return minutes * 60 * 1000 + seconds * 1000;
        }
    }
};
