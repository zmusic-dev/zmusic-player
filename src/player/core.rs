use crate::{
    audio::create_audio_output,
    player::{NetworkMediaSource, PlayerInfo, Status},
    error_codes::ErrorCode,
};
use std::thread;
use std::time::{Duration as StdDuration, Instant};
use symphonia::core::{
    codecs::{DecoderOptions, CODEC_TYPE_NULL},
    errors::Error,
    formats::{FormatOptions, FormatReader},
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
};

use std::sync::{Arc, Mutex};

// 类型别名，简化复杂的类型嵌套
type PlayerInfoArc = Arc<Mutex<PlayerInfo>>;

/// 播放器
pub struct StreamPlayer {
    player_info: PlayerInfoArc,
    playback_thread: Option<thread::JoinHandle<()>>,
}

impl StreamPlayer {
    /// 创建播放器
    pub fn new() -> Self {
        Self {
            player_info: Arc::new(Mutex::new(PlayerInfo::new())),
            playback_thread: None,
        }
    }

    /// 验证URL
    fn validate_url(&self, url: &str) -> Result<(), ErrorCode> {
        // 检查URL格式
        if !url.starts_with("http://") && !url.starts_with("https://") {
            return Err(ErrorCode::UrlUnsupportedProtocol);
        }

        // 尝试建立连接并获取响应头
        let response = match ureq::head(url)
            .timeout(std::time::Duration::from_secs(3))
            .call() {
                Ok(resp) => resp,
                Err(ureq::Error::Status(status, _)) => {
                    return if status == 404 {
                        Err(ErrorCode::MediaNotFound)
                    } else {
                        Err(ErrorCode::HttpError)
                    };
                }
                Err(ureq::Error::Transport(_)) => {
                    return Err(ErrorCode::ConnectionTimeout);
                }
            };
 
        // 检查状态码
        let status = response.status();
        
        if status < 200 || status >= 300 {
            return Err(ErrorCode::HttpError);
        }

        Ok(())
    }

    /// 播放
    pub fn play_url(&mut self, url: &str) -> Result<i32, ErrorCode> {
        // 先停止当前播放
        self.stop().map_err(|_| ErrorCode::PlayerOperationFailed)?;

        // 设置加载状态
        {
            let mut info = self.player_info.lock().unwrap();
            info.set_status(Status::Loading);
            info.set_current_time(0); // 重置播放时间
        }

        // 验证网络文件
        self.validate_url(url)?;

        // 在新线程中播放
        let player_info = Arc::clone(&self.player_info);
        let url = url.to_string();

        let handle = thread::spawn(move || {
            let result = Self::play_internal(&url, &player_info);

            match result {
                Ok(_) => {
                    let mut info = player_info.lock().unwrap();
                    info.set_status(Status::Stopped);
                }
                Err(_) => {
                    // 播放错误时，保持当前状态，错误通过返回值处理
                    // 不再设置Status::Error，因为已从Status枚举中移除
                }
            }
        });

        self.playback_thread = Some(handle);
        Ok(0)
    }

    /// 播放实现
    fn play_internal(
        url: &str,
        player_info: &PlayerInfoArc,
    ) -> std::result::Result<i32, Box<dyn std::error::Error>> {
        let mut hint = Hint::new();
        if url.ends_with(".mp3") {
            hint.with_extension("mp3");
        } else if url.ends_with(".flac") {
            hint.with_extension("flac");
        }

        let source = Box::new(NetworkMediaSource::new(url.to_string())?);
        let mss = MediaSourceStream::new(source, Default::default());

        let probed = symphonia::default::get_probe()
            .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())?;

        let mut reader = probed.format;

        // 获取总时长
        if let Some(track) = reader.tracks().iter().find(|t| t.codec_params.codec != CODEC_TYPE_NULL) {
            let params = &track.codec_params;
            let total_time = params.n_frames.map(|frames| frames / params.sample_rate.unwrap_or(44100) as u64);

            let mut info = player_info.lock().unwrap();
            info.set_total_time(total_time);
        }

        // 设置播放状态
        {
            let mut info = player_info.lock().unwrap();
            info.set_status(Status::Playing);
        }

        // 开始时间跟踪
        let start_time = Instant::now();
        let last_update = Instant::now();

        Self::play_track_internal(&mut reader, player_info, start_time, last_update)
    }

    /// 轨道播放
    fn play_track_internal(
        reader: &mut Box<dyn FormatReader>,
        player_info: &PlayerInfoArc,
        start_time: Instant,
        mut last_update: Instant,
    ) -> std::result::Result<i32, Box<dyn std::error::Error>> {
        let decode_opts = &DecoderOptions::default();

        let track = reader
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != CODEC_TYPE_NULL);
        let track_id = match track {
            Some(track) => track.id,
            _ => return Ok(0),
        };

        let mut decoder =
            symphonia::default::get_codecs().make(&track.unwrap().codec_params, decode_opts)?;
        let mut audio_output = None;

        loop {
            // 检查停止状态
            {
                let info = player_info.lock().unwrap();
                if info.status() == Status::Stopped {
                    break;
                }
            }

            // 检查暂停状态
            loop {
                let status = {
                    let info = player_info.lock().unwrap();
                    info.status()
                };

                if status == Status::Paused {
                    thread::sleep(StdDuration::from_millis(10));
                    let status = {
                        let info = player_info.lock().unwrap();
                        info.status()
                    };
                    if status == Status::Stopped {
                        return Ok(0);
                    }
                } else {
                    break;
                }
            }

            // 更新播放时间（每秒更新一次）
            let now = Instant::now();
            if now.duration_since(last_update).as_secs() >= 1 {
                let elapsed = now.duration_since(start_time).as_secs();
                {
                    let mut info = player_info.lock().unwrap();
                    info.set_current_time(elapsed);
                }
                last_update = now;
            }

            let packet = match reader.next_packet() {
                Ok(packet) => packet,
                Err(Error::ResetRequired) => return Err(Error::ResetRequired.into()),
                Err(Error::IoError(err)) => {
                    if err.kind() == std::io::ErrorKind::UnexpectedEof {
                        break;
                    }
                    return Err(Error::IoError(err).into());
                }
                Err(err) => return Err(err.into()),
            };

            if packet.track_id() != track_id {
                continue;
            }

            match decoder.decode(&packet) {
                Ok(decoded) => {
                    if audio_output.is_none() {
                        let spec = *decoded.spec();
                        let duration = decoded.capacity() as u64;
                        match create_audio_output(spec, duration) {
                            Ok(output) => audio_output = Some(output),
                            Err(e) => {
                                return Err(
                                    format!("Audio output initialization failed: {:?}", e).into()
                                )
                            }
                        }
                    }

                    if let Some(ref mut audio_output) = audio_output {
                        // 获取当前音量并设置
                        let current_volume = {
                            let info = player_info.lock().unwrap();
                            info.volume()
                        };
                        if let Err(e) = audio_output.set_volume(current_volume) {
                            eprintln!("Volume setting failed: {:?}", e);
                        }
                        audio_output
                            .write(decoded)
                            .map_err(|e| format!("Audio write failed: {:?}", e))?;
                    }
                }
                Err(Error::IoError(_)) => break,
                Err(Error::DecodeError(_)) => continue,
                Err(err) => return Err(err.into()),
            }
        }

        // 清理音频输出
        if let Some(mut audio_output) = audio_output {
            audio_output.flush();
        }

        Ok(0)
    }

    /// 暂停
    pub fn pause(&mut self) -> std::result::Result<i32, Box<dyn std::error::Error>> {
        let mut info = self.player_info.lock().unwrap();
        info.set_status(Status::Paused);
        Ok(0)
    }

    /// 恢复
    pub fn resume(&mut self) -> std::result::Result<i32, Box<dyn std::error::Error>> {
        let mut info = self.player_info.lock().unwrap();
        info.set_status(Status::Playing);
        Ok(0)
    }

    /// 停止
    pub fn stop(&mut self) -> std::result::Result<i32, Box<dyn std::error::Error>> {
        // 设置停止状态
        {
            let mut info = self.player_info.lock().unwrap();
            info.set_status(Status::Stopped);
            info.set_current_time(0);
        }

        // 等待播放线程结束
        if let Some(handle) = self.playback_thread.take() {
            let _ = handle.join();
        }

        Ok(0)
    }

    /// 重置播放器
    pub fn reset(&mut self) -> std::result::Result<i32, Box<dyn std::error::Error>> {
        // 先停止播放
        self.stop()?;

        // 重置播放器信息到初始状态
        {
            let mut info = self.player_info.lock().unwrap();
            info.reset();
        }

        Ok(0)
    }

    /// 音量
    pub fn set_volume(&mut self, volume: f32) -> std::result::Result<i32, Box<dyn std::error::Error>> {
        let mut info = self.player_info.lock().unwrap();
        info.set_volume(volume)?;
        Ok(0)
    }

    /// 播放器信息
    pub fn get_player_info(&self) -> PlayerInfo {
        let info = self.player_info.lock().unwrap();
        info.clone()
    }
}

impl Drop for StreamPlayer {
    fn drop(&mut self) {
        let _ = self.reset();
    }
}
