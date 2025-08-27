//! 音频输出模块
//!
//! 提供基于CPAL的跨平台音频输出功能

use crate::audio::resampler::Resampler;
use crate::audio::types::{AudioOutputError, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use rb::*;
use symphonia::core::{
    audio::{AudioBufferRef, SampleBuffer, SignalSpec},
    conv::IntoSample,
    units::Duration,
};


/// 音频输出实现
pub struct AudioOutput {
    ring_buf_producer: rb::Producer<f32>,
    sample_buf: SampleBuffer<f32>,
    stream: cpal::Stream,
    resampler: Option<Resampler<f32>>,
    volume: f32,
}

impl AudioOutput {
    /// 创建音频输出设备
    pub fn new(spec: SignalSpec, duration: Duration) -> Result<Self> {
        let host = cpal::default_host();
        let device = match host.default_output_device() {
            Some(device) => device,
            _ => return Err(AudioOutputError::OpenStreamError),
        };

        let config = match device.default_output_config() {
            Ok(config) => config,
            Err(_) => return Err(AudioOutputError::OpenStreamError),
        };

        // 优先使用 f32 格式，如果不支持则尝试其他格式
        if config.sample_format() == cpal::SampleFormat::F32 {
            Self::create_impl(spec, duration, &device)
        } else {
            // 如果设备不支持 f32，尝试使用设备默认格式
            Self::create_with_device_format(spec, duration, &device, &config)
        }
    }

    /// 使用 f32 格式创建音频输出实现
    fn create_impl(spec: SignalSpec, duration: Duration, device: &cpal::Device) -> Result<Self> {
        let num_channels = spec.channels.count();

        let config = cpal::StreamConfig {
            channels: num_channels as cpal::ChannelCount,
            sample_rate: cpal::SampleRate(spec.rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let ring_len = ((200 * config.sample_rate.0 as usize) / 1000) * num_channels;
        let ring_buf = SpscRb::new(ring_len);
        let (ring_buf_producer, ring_buf_consumer) = (ring_buf.producer(), ring_buf.consumer());

        let stream_result = device.build_output_stream(
            &config,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                let written = ring_buf_consumer.read(data).unwrap_or(0);
                data[written..].iter_mut().for_each(|s| *s = 0.0);
            },
            move |_| {},
        );

        if let Err(_) = stream_result {
            return Err(AudioOutputError::OpenStreamError);
        }

        let stream = stream_result.unwrap();
        if let Err(_) = stream.play() {
            return Err(AudioOutputError::PlayStreamError);
        }

        let sample_buf = SampleBuffer::<f32>::new(duration, spec);
        let resampler = if spec.rate != config.sample_rate.0 {
            Some(Resampler::new(
                spec,
                config.sample_rate.0 as usize,
                duration,
            ))
        } else {
            None
        };

        Ok(Self {
            ring_buf_producer,
            sample_buf,
            stream,
            resampler,
            volume: 1.0,
        })
    }

    /// 使用设备默认格式创建音频输出实现
    fn create_with_device_format(
        spec: SignalSpec,
        duration: Duration,
        device: &cpal::Device,
        _device_config: &cpal::SupportedStreamConfig,
    ) -> Result<Self> {
        let num_channels = spec.channels.count();

        let config = cpal::StreamConfig {
            channels: num_channels as cpal::ChannelCount,
            sample_rate: cpal::SampleRate(spec.rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let ring_len = ((200 * config.sample_rate.0 as usize) / 1000) * num_channels;
        let ring_buf = SpscRb::new(ring_len);
        let (ring_buf_producer, ring_buf_consumer) = (ring_buf.producer(), ring_buf.consumer());

        let stream_result = device.build_output_stream(
            &config,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                let written = ring_buf_consumer.read(data).unwrap_or(0);
                data[written..].iter_mut().for_each(|s| *s = 0.0);
            },
            move |_| {},
        );

        if let Err(_) = stream_result {
            return Err(AudioOutputError::OpenStreamError);
        }

        let stream = stream_result.unwrap();
        if let Err(_) = stream.play() {
            return Err(AudioOutputError::PlayStreamError);
        }

        let sample_buf = SampleBuffer::<f32>::new(duration, spec);
        let resampler = if spec.rate != config.sample_rate.0 {
            Some(Resampler::new(
                spec,
                config.sample_rate.0 as usize,
                duration,
            ))
        } else {
            None
        };

        Ok(Self {
            ring_buf_producer,
            sample_buf,
            stream,
            resampler,
            volume: 1.0,
        })
    }

    /// 写入音频数据
    pub fn write(&mut self, decoded: AudioBufferRef<'_>) -> Result<()> {
        if decoded.frames() == 0 {
            return Ok(());
        }

        let samples = if let Some(resampler) = &mut self.resampler {
            match resampler.resample(decoded) {
                Some(resampled) => resampled,
                None => return Ok(()),
            }
        } else {
            self.sample_buf.copy_interleaved_ref(decoded);
            self.sample_buf.samples()
        };

        // 应用音量控制并写入
        if self.volume != 1.0 {
            let mut adjusted_samples = Vec::with_capacity(samples.len());
            for sample in samples {
                let sample_f32: f32 = (*sample).into_sample();
                let adjusted_sample = sample_f32 * self.volume;
                adjusted_samples.push(adjusted_sample.into_sample());
            }
            let mut adjusted_slice = adjusted_samples.as_slice();
            while let Some(written) = self.ring_buf_producer.write_blocking(adjusted_slice) {
                adjusted_slice = &adjusted_slice[written..];
            }
        } else {
            let mut samples_slice = samples;
            while let Some(written) = self.ring_buf_producer.write_blocking(samples_slice) {
                samples_slice = &samples_slice[written..];
            }
        }

        Ok(())
    }

    /// 刷新音频缓冲区
    pub fn flush(&mut self) {
        if let Some(resampler) = &mut self.resampler {
            let remaining_samples = resampler.flush().unwrap_or_default();
            if self.volume != 1.0 {
                let mut adjusted_samples = Vec::with_capacity(remaining_samples.len());
                for sample in remaining_samples {
                    let sample_f32: f32 = (*sample).into_sample();
                    let adjusted_sample = sample_f32 * self.volume;
                    adjusted_samples.push(adjusted_sample.into_sample());
                }
                let mut adjusted_slice = adjusted_samples.as_slice();
                while let Some(written) = self.ring_buf_producer.write_blocking(adjusted_slice) {
                    adjusted_slice = &adjusted_slice[written..];
                }
            } else {
                let mut remaining_slice = remaining_samples;
                while let Some(written) = self.ring_buf_producer.write_blocking(remaining_slice) {
                    remaining_slice = &remaining_slice[written..];
                }
            }
        }
        let _ = self.stream.pause();
    }

    /// 设置音量
    pub fn set_volume(&mut self, volume: f32) -> Result<()> {
        if volume < 0.0 || volume > 1.0 {
            return Err(AudioOutputError::VolumeError);
        }
        self.volume = volume;
        Ok(())
    }
}

/// 创建音频输出设备
pub fn create_audio_output(spec: SignalSpec, duration: Duration) -> Result<AudioOutput> {
    AudioOutput::new(spec, duration)
}
