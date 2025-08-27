/// 音频输出错误
#[derive(Debug)]
pub enum AudioOutputError {
    /// 打开音频流失败
    OpenStreamError,
    /// 播放音频流失败
    PlayStreamError,
    /// 音量设置失败
    VolumeError,
}

impl std::fmt::Display for AudioOutputError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AudioOutputError::OpenStreamError => write!(f, "打开音频流失败"),
            AudioOutputError::PlayStreamError => write!(f, "播放音频流失败"),
            AudioOutputError::VolumeError => write!(f, "音量设置失败"),
        }
    }
}

impl std::error::Error for AudioOutputError {}

/// 音频结果类型
pub type Result<T> = std::result::Result<T, AudioOutputError>;
