//! 音频处理模块
//!
//! 提供音频输出、重采样、播放器和类型定义功能

pub mod output;
pub mod resampler;
pub mod types;

use symphonia::core::audio::SignalSpec;
use symphonia::core::units::Duration;
use crate::audio::types::Result;

/// 创建音频输出设备
///
/// # 参数
/// * `spec` - 音频信号规格
/// * `duration` - 音频持续时间
///
/// # 返回值
/// * `Result<AudioOutput>` - 音频输出设备或错误
pub fn create_audio_output(spec: SignalSpec, duration: Duration) -> Result<crate::audio::output::AudioOutput> {
    crate::audio::output::create_audio_output(spec, duration)
}
