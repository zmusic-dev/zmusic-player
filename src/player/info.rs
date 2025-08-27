/// 播放状态
#[derive(Debug, Clone, PartialEq)]
pub enum Status {
    /// 停止
    Stopped,
    /// 播放中
    Playing,
    /// 暂停
    Paused,
    /// 加载中
    Loading,
}

/// 播放器信息
#[derive(Debug, Clone)]
pub struct PlayerInfo {
    /// 状态
    pub status: Status,
    /// 当前时间(秒)
    pub current_time: u64,
    /// 总时长(秒)
    pub total_time: Option<u64>,
    /// 音量
    pub volume: f32,
}

impl PlayerInfo {
    /// 创建播放器信息
    pub fn new() -> Self {
        Self {
            status: Status::Stopped,
            current_time: 0,
            total_time: None,
            volume: 1.0,
        }
    }

    // 数据获取方法
    /// 播放状态
    pub fn status(&self) -> Status {
        self.status.clone()
    }

    /// 总时长
    pub fn total_time(&self) -> Option<u64> {
        self.total_time
    }

    /// 当前时间
    pub fn current_time(&self) -> u64 {
        self.current_time
    }

    /// 音量
    pub fn volume(&self) -> f32 {
        self.volume
    }

    // 数据设置方法
    /// 播放状态
    pub fn set_status(&mut self, status: Status) {
        self.status = status;
    }

    /// 总时长
    pub fn set_total_time(&mut self, total_time: Option<u64>) {
        self.total_time = total_time;
    }

    /// 当前时间
    pub fn set_current_time(&mut self, current_time: u64) {
        self.current_time = current_time;
    }

    /// 音量
    pub fn set_volume(&mut self, volume: f32) -> Result<(), String> {
        if !(0.0..=1.0).contains(&volume) {
            return Err("Volume must be between 0.0 and 1.0".to_string());
        }
        self.volume = volume;
        Ok(())
    }

    /// 重置播放器信息到初始状态
    pub fn reset(&mut self) {
        *self = Self::new();
    }
}
