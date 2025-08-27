//! 播放器模块
//!
//! 包含播放器核心功能、状态管理和数据

pub mod core;
pub mod info;
pub mod network;

// 重新导出常用类型
pub use core::StreamPlayer;
pub use info::{PlayerInfo, Status};
pub use network::NetworkMediaSource;
