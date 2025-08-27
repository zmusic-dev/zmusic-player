/// ZMusic Player 错误码定义
/// 与 Java ErrorCode 枚举保持一致
#[repr(i32)]
#[derive(Copy, Clone)]
pub enum ErrorCode {
    // 成功
    Success = 0,
    
    // 通用错误 (1000-1999)
    UnknownError = 1000,
    InvalidParameter = 1001,
    NullPointer = 1002,
    MemoryError = 1003,
    
    // JNI 相关错误 (2000-2999)
    JniEnvError = 2000,
    JniClassNotFound = 2001,
    JniMethodNotFound = 2002,
    JniFieldNotFound = 2003,
    JniObjectCreationFailed = 2004,
    JniStringConversionFailed = 2005,
    
    // 播放器相关错误 (3000-3999)
    PlayerNotInitialized = 3000,
    PlayerAlreadyInitialized = 3001,
    PlayerLockFailed = 3002,
    PlayerOperationFailed = 3003,
    PlayerThreadError = 3004,
    
    // 网络相关错误 (4000-4999)
    NetworkError = 4000,
    UrlInvalid = 4001,
    UrlUnsupportedProtocol = 4002,
    HttpError = 4003,
    ConnectionTimeout = 4004,
    ConnectionRefused = 4005,
    
    // 音频相关错误 (5000-5999)
    AudioDeviceError = 5000,
    AudioFormatError = 5001,
    AudioDecodeError = 5002,
    AudioOutputError = 5003,
    AudioVolumeError = 5004,
    
    // 媒体相关错误 (6000-6999)
    MediaNotFound = 6000,
    MediaFormatUnsupported = 6001,
    MediaCorrupted = 6002,
    MediaReadError = 6003,
    MediaDurationError = 6004,
}

impl ErrorCode {
    /// 获取错误码数值
    pub fn code(&self) -> i32 {
        *self as i32
    }
    
    /// 获取错误码描述
    pub fn description(&self) -> &'static str {
        match self {
            ErrorCode::Success => "operation successful",
            ErrorCode::UnknownError => "unknown error",
            ErrorCode::InvalidParameter => "invalid parameter",
            ErrorCode::NullPointer => "null pointer error",
            ErrorCode::MemoryError => "memory error",
            ErrorCode::JniEnvError => "jni environment error",
            ErrorCode::JniClassNotFound => "jni class not found",
            ErrorCode::JniMethodNotFound => "jni method not found",
            ErrorCode::JniFieldNotFound => "jni field not found",
            ErrorCode::JniObjectCreationFailed => "jni object creation failed",
            ErrorCode::JniStringConversionFailed => "jni string conversion failed",
            ErrorCode::PlayerNotInitialized => "player not initialized",
            ErrorCode::PlayerAlreadyInitialized => "player already initialized",
            ErrorCode::PlayerLockFailed => "player lock failed",
            ErrorCode::PlayerOperationFailed => "player operation failed",
            ErrorCode::PlayerThreadError => "player thread error",
            ErrorCode::NetworkError => "network error",
            ErrorCode::UrlInvalid => "url invalid",
            ErrorCode::UrlUnsupportedProtocol => "unsupported protocol",
            ErrorCode::HttpError => "http error",
            ErrorCode::ConnectionTimeout => "connection timeout",
            ErrorCode::ConnectionRefused => "connection refused",
            ErrorCode::AudioDeviceError => "audio device error",
            ErrorCode::AudioFormatError => "audio format error",
            ErrorCode::AudioDecodeError => "audio decode error",
            ErrorCode::AudioOutputError => "audio output error",
            ErrorCode::AudioVolumeError => "audio volume error",
            ErrorCode::MediaNotFound => "media not found",
            ErrorCode::MediaFormatUnsupported => "unsupported media format",
            ErrorCode::MediaCorrupted => "media corrupted",
            ErrorCode::MediaReadError => "media read error",
            ErrorCode::MediaDurationError => "media duration error",
        }
    }
    
    /// 检查是否成功
    pub fn is_success(&self) -> bool {
        matches!(self, ErrorCode::Success)
    }
    
    /// 检查是否错误
    pub fn is_error(&self) -> bool {
        !self.is_success()
    }
    
    /// 根据错误码获取错误码枚举
    pub fn from_code(code: i32) -> Self {
        match code {
            0 => ErrorCode::Success,
            1000 => ErrorCode::UnknownError,
            1001 => ErrorCode::InvalidParameter,
            1002 => ErrorCode::NullPointer,
            1003 => ErrorCode::MemoryError,
            2000 => ErrorCode::JniEnvError,
            2001 => ErrorCode::JniClassNotFound,
            2002 => ErrorCode::JniMethodNotFound,
            2003 => ErrorCode::JniFieldNotFound,
            2004 => ErrorCode::JniObjectCreationFailed,
            2005 => ErrorCode::JniStringConversionFailed,
            3000 => ErrorCode::PlayerNotInitialized,
            3001 => ErrorCode::PlayerAlreadyInitialized,
            3002 => ErrorCode::PlayerLockFailed,
            3003 => ErrorCode::PlayerOperationFailed,
            3004 => ErrorCode::PlayerThreadError,
            4000 => ErrorCode::NetworkError,
            4001 => ErrorCode::UrlInvalid,
            4002 => ErrorCode::UrlUnsupportedProtocol,
            4003 => ErrorCode::HttpError,
            4004 => ErrorCode::ConnectionTimeout,
            4005 => ErrorCode::ConnectionRefused,
            5000 => ErrorCode::AudioDeviceError,
            5001 => ErrorCode::AudioFormatError,
            5002 => ErrorCode::AudioDecodeError,
            5003 => ErrorCode::AudioOutputError,
            5004 => ErrorCode::AudioVolumeError,
            6000 => ErrorCode::MediaNotFound,
            6001 => ErrorCode::MediaFormatUnsupported,
            6002 => ErrorCode::MediaCorrupted,
            6003 => ErrorCode::MediaReadError,
            6004 => ErrorCode::MediaDurationError,
            _ => ErrorCode::UnknownError,
        }
    }
    
    /// 创建格式化的错误消息
    pub fn format_message(&self) -> String {
        format!("{} (ErrorCode: {})", self.description(), self.code())
    }
}

// 实现 From trait 以支持类型转换
impl From<i32> for ErrorCode {
    fn from(code: i32) -> Self {
        Self::from_code(code)
    }
}

impl From<ErrorCode> for i32 {
    fn from(error_code: ErrorCode) -> Self {
        error_code.code()
    }
}
