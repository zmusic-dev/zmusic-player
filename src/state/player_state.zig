//! 播放状态机定义模块
//!
//! 本模块定义了播放器核心状态枚举和错误类型，是播放器状态机的基础。
//! 在整体架构中，播放器各组件（如播放引擎、UI、歌词同步器）通过
//! `PlaybackState` 协调当前播放进度状态，通过 `PlayerError` 统一
//! 错误处理和错误传播。

/// 播放器状态枚举
///
/// 状态转换关系：
/// ```text
/// stopped → loading → playing ⇄ paused
///                 ↘ error
/// playing/paused → stopped（用户停止或列表播完）
/// ```
///
/// 使用 `u8` 底层类型便于与 C FFI 及序列化场景兼容。
pub const PlaybackState = enum(u8) {
    /// 停止状态：初始状态，或用户主动停止、播放列表播完后的状态
    stopped = 0,
    /// 加载中状态：正在从网络或本地加载音频数据，尚未开始解码播放
    loading = 1,
    /// 播放中状态：音频正在解码输出
    playing = 2,
    /// 暂停状态：音频输出已暂停，可随时恢复播放
    paused = 3,
    /// 错误状态：播放过程中出现不可恢复的错误，需用户干预
    /// 使用 @"error" 语法是因为 `error` 是 Zig 保留关键字
    @"error" = 4,
};

/// 播放器错误集合
///
/// 按错误来源分为四组：
///
/// 网络相关（音频数据获取阶段）：
/// - `NetworkUnavailable`：网络不可用，无法建立连接
/// - `HttpError`：HTTP 请求失败（如 4xx/5xx 响应）
/// - `StreamTimeout`：音频流读取超时
/// - `InvalidUrl`：提供的音频 URL 格式不合法
///
/// 解码相关（音频数据处理阶段）：
/// - `DecodeFailed`：音频数据解码失败（如文件损坏）
/// - `UnsupportedFormat`：音频格式不在支持范围内
///
/// 设备相关（音频输出阶段）：
/// - `DeviceNotAvailable`：音频输出设备不可用（如被其他程序占用）
/// - `DeviceInitFailed`：音频设备初始化失败（如驱动问题）
///
/// 业务逻辑相关（播放队列操作）：
/// - `QueueEmpty`：播放队列为空时尝试播放
/// - `IndexOutOfBounds`：队列索引越界
/// - `InvalidLrcFormat`：LRC 歌词文件格式不合法
pub const PlayerError = error{
    NetworkUnavailable,
    HttpError,
    StreamTimeout,
    InvalidUrl,
    DecodeFailed,
    UnsupportedFormat,
    DeviceNotAvailable,
    DeviceInitFailed,
    QueueEmpty,
    IndexOutOfBounds,
    InvalidLrcFormat,
};
