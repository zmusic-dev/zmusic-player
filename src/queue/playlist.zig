//! # 播放队列/播放列表管理模块
//!
//! 管理播放器的曲目列表，支持以下功能：
//! - 曲目的增删和清空
//! - 播放导航（下一曲、上一曲、跳转到指定位置）
//! - 循环模式（不循环 / 单曲循环 / 列表循环）
//! - 随机播放（基于 Fisher-Yates 洗牌算法）
//!
//! 在整体架构中，本模块被 Player 模块持有，
//! Player 通过委托方式调用本模块管理播放顺序，
//! 本身不涉及音频播放逻辑。

const std = @import("std");
const platform = @import("platform");

/// ## Track — 曲目信息
///
/// 描述播放队列中的单个曲目。
/// 所有字符串字段为借用引用，不拥有内存，生命周期由调用者管理。
pub const Track = struct {
    /// 音频资源地址，可以是 URL 或本地文件路径
    url: []const u8,
    /// 曲目标题，可选
    title: ?[]const u8 = null,
    /// 艺术家名称，可选
    artist: ?[]const u8 = null,
    /// 时长（毫秒），可选
    duration_ms: ?u64 = null,
    /// 歌词文件地址，可选
    lyrics_url: ?[]const u8 = null,
};

/// ## RepeatMode — 循环播放模式
///
/// 控制播放到队列末尾时的行为：
/// - `none`：播放到末尾即停止
/// - `one`：单曲循环，始终重复当前曲目
/// - `all`：列表循环，到末尾后回到第一首继续
pub const RepeatMode = enum(u8) {
    /// 不循环，播完即止
    none = 0,
    /// 单曲循环
    one = 1,
    /// 列表循环
    all = 2,
};

/// ## Playlist — 播放列表
///
/// 持有曲目列表并维护当前播放位置。
/// 支持随机播放模式，内部维护一个洗牌后的索引序列。
pub const Playlist = struct {
    /// 曲目列表
    tracks: std.array_list.Managed(Track),
    /// 当前播放位置的索引
    current_index: usize,
    /// 循环模式
    repeat_mode: RepeatMode,
    /// 是否启用随机播放
    shuffle: bool,
    /// 随机播放时的索引序列（洗牌后的播放顺序）
    shuffle_order: ?std.array_list.Managed(usize),
    /// 内存分配器
    allocator: std.mem.Allocator,

    /// ## init — 创建空的播放列表
    ///
    /// - `allocator` 用于内部数据结构的内存分配
    pub fn init(allocator: std.mem.Allocator) Playlist {
        return .{
            .tracks = std.array_list.Managed(Track).init(allocator),
            .current_index = 0,
            .repeat_mode = .none,
            .shuffle = false,
            .shuffle_order = null,
            .allocator = allocator,
        };
    }

    /// ## deinit — 销毁播放列表
    ///
    /// 释放曲目列表和洗牌序列的内存。
    /// 注意：Track 中的字符串是借用引用，不会在此释放。
    pub fn deinit(self: *Playlist) void {
        self.tracks.deinit();
        if (self.shuffle_order) |*so| so.deinit();
    }

    /// ## add — 添加曲目到列表末尾
    ///
    /// 如果当前处于随机播放模式，会重新生成洗牌序列
    /// 以确保新曲目被纳入随机顺序。
    pub fn add(self: *Playlist, track: Track) !void {
        try self.tracks.append(track);
        if (self.shuffle) self.regenerateShuffleOrder() catch {};
    }

    /// ## addNext — 添加曲目到当前播放位置之后
    ///
    /// 用于"下一首播放"功能，将曲目插入到当前曲目的后面，
    /// 使其在当前曲目结束后立即播放。
    pub fn addNext(self: *Playlist, track: Track) !void {
        const real_current = self.realIndex();
        const insert_pos = if (real_current + 1 <= self.tracks.items.len)
            real_current + 1
        else
            self.tracks.items.len;
        try self.tracks.insert(insert_pos, track);
        if (self.shuffle) self.regenerateShuffleOrder() catch {};
    }

    /// ## remove — 移除指定位置的曲目
    ///
    /// 移除后会自动修正 `current_index`，防止越界：
    /// 如果删除导致当前索引超出范围，则回退到最后一首。
    pub fn remove(self: *Playlist, index: usize) !void {
        if (index >= self.tracks.items.len) return error.IndexOutOfBounds;
        _ = self.tracks.orderedRemove(index);
        // 删除后修正当前索引，防止指向已不存在的位置
        if (self.current_index >= self.tracks.items.len and self.tracks.items.len > 0) {
            self.current_index = self.tracks.items.len - 1;
        }
        if (self.shuffle) self.regenerateShuffleOrder() catch {};
    }

    /// ## clear — 清空播放列表
    ///
    /// 移除所有曲目，重置播放位置到起始。
    pub fn clear(self: *Playlist) void {
        self.tracks.clearAndFree();
        self.current_index = 0;
        if (self.shuffle_order) |*so| {
            so.clearAndFree();
        }
    }

    /// ## current — 获取当前曲目
    ///
    /// 返回当前播放位置处的曲目，队列为空或索引越界时返回 `null`。
    pub fn current(self: *Playlist) ?Track {
        if (self.tracks.items.len == 0) return null;
        const idx = self.realIndex();
        if (idx >= self.tracks.items.len) return null;
        return self.tracks.items[idx];
    }

    /// ## next — 前进到下一曲
    ///
    /// 根据 `repeat_mode` 的不同行为：
    /// - `one`：返回当前曲目（单曲循环）
    /// - `all`：索引 +1，到末尾后回到 0（列表循环）
    /// - `none`：索引 +1，到末尾后返回 null（停止）
    pub fn next(self: *Playlist) ?Track {
        if (self.tracks.items.len == 0) return null;

        switch (self.repeat_mode) {
            .one => return self.current(),
            .all => {
                // 列表循环：取模实现首尾衔接
                self.current_index = (self.current_index + 1) % self.tracks.items.len;
            },
            .none => {
                // 不循环：到达末尾即停止
                if (self.current_index + 1 >= self.tracks.items.len) return null;
                self.current_index += 1;
            },
        }
        return self.current();
    }

    /// ## previous — 回退到上一曲
    ///
    /// 根据 `repeat_mode` 的不同行为：
    /// - `one`：返回当前曲目（单曲循环）
    /// - `all`：索引 -1，到开头后跳到末尾（列表循环）
    /// - `none`：索引 -1，到开头后返回 null（停止）
    pub fn previous(self: *Playlist) ?Track {
        if (self.tracks.items.len == 0) return null;

        switch (self.repeat_mode) {
            .one => return self.current(),
            .all => {
                // 列表循环：在开头时跳到末尾
                if (self.current_index == 0) {
                    self.current_index = self.tracks.items.len - 1;
                } else {
                    self.current_index -= 1;
                }
            },
            .none => {
                // 不循环：在开头时停止
                if (self.current_index == 0) return null;
                self.current_index -= 1;
            },
        }
        return self.current();
    }

    /// ## jumpTo — 跳转到指定索引的曲目
    ///
    /// 直接设置播放位置到给定索引并返回对应曲目。
    /// `index` 为曲目在 `tracks` 中的真实位置。
    /// 随机播放模式下，会查找该曲目在洗牌序列中的位置以保持一致性。
    /// 索引越界时返回 `IndexOutOfBounds` 错误。
    pub fn jumpTo(self: *Playlist, index: usize) !Track {
        if (index >= self.tracks.items.len) return error.IndexOutOfBounds;
        if (self.shuffle) {
            if (self.shuffle_order) |*so| {
                // 在洗牌序列中查找该曲目的位置
                for (so.items, 0..) |track_idx, pos| {
                    if (track_idx == index) {
                        self.current_index = pos;
                        return self.tracks.items[index];
                    }
                }
            }
            // 找不到则回退：重新生成洗牌序列后设为末尾
            self.regenerateShuffleOrder() catch {};
            self.current_index = self.tracks.items.len - 1;
        } else {
            self.current_index = index;
        }
        return self.tracks.items[index];
    }

    /// ## setRepeatMode — 设置循环模式
    pub fn setRepeatMode(self: *Playlist, mode: RepeatMode) void {
        self.repeat_mode = mode;
    }

    /// ## setShuffle — 启用或禁用随机播放
    ///
    /// 启用时生成新的洗牌序列，并将当前曲目定位到洗牌序列中的对应位置。
    /// 禁用时将当前播放位置从洗牌位置映射回真实曲目索引。
    pub fn setShuffle(self: *Playlist, enabled: bool) void {
        self.shuffle = enabled;
        if (enabled) {
            // 记住当前正在播放的真实曲目索引
            const current_track = if (self.tracks.items.len > 0 and self.current_index < self.tracks.items.len)
                self.current_index
            else
                0;
            self.regenerateShuffleOrder() catch {};
            // 在新洗牌序列中找到当前曲目，保持播放不跳变
            if (self.shuffle_order) |*so| {
                for (so.items, 0..) |track_idx, pos| {
                    if (track_idx == current_track) {
                        self.current_index = pos;
                        return;
                    }
                }
            }
        } else {
            // 关闭 shuffle：从洗牌位置映射回真实曲目索引
            const idx = self.realIndex();
            if (self.shuffle_order) |*so| {
                so.deinit();
                self.shuffle_order = null;
            }
            self.current_index = idx;
        }
    }

    /// ## realIndex — 将逻辑播放位置映射到真实曲目索引
    ///
    /// 随机播放开启时，`current_index` 是洗牌序列中的位置，
    /// 通过 `shuffle_order` 映射回 `tracks` 中的真实索引。
    /// 关闭时直接返回 `current_index`。
    fn realIndex(self: *const Playlist) usize {
        if (self.shuffle) {
            if (self.shuffle_order) |*so| {
                if (self.current_index < so.items.len) {
                    return so.items[self.current_index];
                }
            }
        }
        return self.current_index;
    }

    /// ## regenerateShuffleOrder — 重新生成随机播放顺序
    ///
    /// 使用 **Fisher-Yates 洗牌算法**生成一个 0..n-1 的随机排列，
    /// 确保每首曲目在随机播放中恰好出现一次。
    ///
    /// 随机数种子基于当前时间（秒与纳秒的异或值），
    /// 这不是密码学安全的随机源，但对播放列表洗牌已经足够。
    fn regenerateShuffleOrder(self: *Playlist) !void {
        if (self.shuffle_order) |*so| so.deinit();
        var order = std.array_list.Managed(usize).init(self.allocator);
        errdefer order.deinit();

        // 步骤 1：生成顺序索引序列 [0, 1, 2, ..., n-1]
        const n = self.tracks.items.len;
        for (0..n) |i| {
            try order.append(i);
        }

        // 步骤 2：基于系统时钟初始化伪随机数生成器
        const ts = platform.timestamp();
        var rng = std.Random.DefaultPrng.init(@as(u64, @intCast(ts.sec)) ^ @as(u64, @intCast(ts.nsec)));
        const rand = rng.random();

        // 步骤 3：Fisher-Yates 洗牌
        // 从末尾向前遍历，每次随机选取一个位置与当前位置交换，
        // 保证每个排列出现的概率相等（1/n!）
        var i: usize = n;
        while (i > 1) {
            i -= 1;
            const j = rand.intRangeAtMost(usize, 0, i);
            const tmp = order.items[i];
            order.items[i] = order.items[j];
            order.items[j] = tmp;
        }

        self.shuffle_order = order;
    }
};
