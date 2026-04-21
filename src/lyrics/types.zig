//! 歌词数据类型定义模块
//!
//! 本模块定义了歌词子系统的核心数据结构，包括单行歌词、歌词集合、
//! 以及 LRC 格式的元数据。在整体架构中，这些类型作为歌词解析器
//! (`parser`) 和歌词渲染器之间的共享契约，解析器负责填充数据，
//! 渲染器负责根据时间戳定位并展示歌词。

const std = @import("std");

/// 单行歌词
///
/// 表示一条歌词在某一时间点的文本内容，可选附带翻译文本。
/// `text` 和 `translation` 的生命周期由所属 `Lyrics` 结构管理。
pub const LyricLine = struct {
    /// 该行歌词的起始时间，单位毫秒
    time_ms: u64,
    /// 歌词原文文本
    text: []const u8,
    /// 可选的翻译文本（如中文翻译），不存在时为 null
    translation: ?[]const u8,
};

/// LRC 格式元数据
///
/// 对应 LRC 文件中的 `[ti:...]`、`[ar:...]`、`[al:...]`、`[by:...]`
/// 和 `[offset:...]` 标签。字符串字段为可选类型，因为并非所有 LRC
/// 文件都包含完整的元数据信息。
pub const LrcMetadata = struct {
    /// 歌曲标题，对应 `[ti:...]` 标签
    title: ?[]const u8 = null,
    /// 艺术家名称，对应 `[ar:...]` 标签
    artist: ?[]const u8 = null,
    /// 专辑名称，对应 `[al:...]` 标签
    album: ?[]const u8 = null,
    /// LRC 文件作者/制作者，对应 `[by:...]` 标签
    author: ?[]const u8 = null,
    /// 全局时间偏移量，单位毫秒，正值表示歌词提前，负值表示延后
    /// 对应 `[offset:...]` 标签
    offset_ms: i32 = 0,
};

/// 歌词集合
///
/// 包含完整的歌词数据和元数据，是歌词子系统的顶层容器。
/// 通过 `init` 创建，使用完毕后必须调用 `deinit` 释放内存。
/// 所有字符串（歌词文本、元数据字段）均通过内部持有的分配器管理。
pub const Lyrics = struct {
    /// LRC 文件元数据（标题、艺术家等）
    metadata: LrcMetadata,
    /// 按时间排序的歌词行列表
    lines: std.array_list.Managed(LyricLine),
    /// 用于管理所有内部字符串内存的分配器
    allocator: std.mem.Allocator,

    /// 初始化一个空的歌词集合
    ///
    /// 参数：
    /// - `allocator`：内存分配器，用于后续所有字符串和列表的内存管理
    ///
    /// 返回：初始化后的 `Lyrics` 实例，元数据为默认值，歌词行列表为空
    pub fn init(allocator: std.mem.Allocator) Lyrics {
        return .{
            .metadata = .{},
            .lines = std.array_list.Managed(LyricLine).init(allocator),
            .allocator = allocator,
        };
    }

    /// 释放所有已分配的内存
    ///
    /// 依次释放元数据中的字符串（title/artist/album/author），
    /// 然后释放歌词行列表。注意：歌词行中 `text` 和 `translation`
    /// 字段指向的内存由 `parser` 模块管理，此处只释放列表容器本身。
    pub fn deinit(self: *Lyrics) void {
        if (self.metadata.title) |v| self.allocator.free(v);
        if (self.metadata.artist) |v| self.allocator.free(v);
        if (self.metadata.album) |v| self.allocator.free(v);
        if (self.metadata.author) |v| self.allocator.free(v);
        self.lines.deinit();
    }

    /// 对所有歌词行应用全局时间偏移
    ///
    /// 根据 LRC 元数据中的 `offset` 值统一调整每行歌词的时间戳。
    /// 使用饱和运算（`+|=` / `-|=`）确保偏移后不会产生溢出或下溢：
    /// - 正偏移使用 `+|=`（饱和加法），超出 u64 最大值时饱和为 max
    /// - 负偏移使用 `-|=`（饱和减法），且 `@min(abs_off, line.time_ms)`
    ///   确保不会减到 0 以下（饱和为 0）
    ///
    /// 参数：
    /// - `offset_ms`：偏移量（毫秒），正值提前，负值延后
    pub fn applyOffset(self: *Lyrics, offset_ms: i32) void {
        for (self.lines.items) |*line| {
            if (offset_ms >= 0) {
                // 饱和加法：溢出时结果为 u64 最大值而非回绕
                line.time_ms +|= @intCast(offset_ms);
            } else {
                const abs_off: u64 = @intCast(-offset_ms);
                // 饱和减法：取偏移量和当前时间戳的较小值，确保结果不低于 0
                line.time_ms -|= @min(abs_off, line.time_ms);
            }
        }
    }

    /// 根据时间戳查找当前应显示的歌词行索引
    ///
    /// 使用二分查找（上界变体）在已排序的歌词行列表中定位。
    /// 查找逻辑：找到最后一个 `time_ms <= time_ms` 的歌词行，
    /// 即在给定时间点"正在显示"的那一行。
    ///
    /// 算法说明：
    /// - 循环结束后 `lo` 指向第一个 `time_ms > time_ms` 的位置
    /// - `lo - 1` 就是最后一个 `time_ms <= time_ms` 的位置
    /// - 若 `lo == 0` 说明所有歌词行的时间戳都大于给定时间，返回 null
    ///
    /// 参数：
    /// - `time_ms`：当前播放位置（毫秒）
    ///
    /// 返回：当前应显示的歌词行索引，若在第一行歌词之前则返回 null
    pub fn getLineAt(self: *Lyrics, time_ms: u64) ?usize {
        if (self.lines.items.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = self.lines.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.lines.items[mid].time_ms <= time_ms) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return null;
        return lo - 1;
    }
};
