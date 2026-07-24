use std::ffi::{CString, c_char, c_void};
use std::ptr::NonNull;
use std::sync::Arc;

use crate::state::PlayerError;

#[repr(C)]
struct ZmEngine {
    _private: [u8; 0],
}

#[repr(C)]
struct ZmSound {
    _private: [u8; 0],
}

pub type StreamReadCallback = unsafe extern "C" fn(
    user_data: *mut c_void,
    buffer_out: *mut c_void,
    bytes_to_read: usize,
    bytes_read: *mut usize,
) -> i32;

pub type StreamSeekCallback =
    unsafe extern "C" fn(user_data: *mut c_void, byte_offset: i64, origin: i32) -> i32;

unsafe extern "C" {
    fn zm_engine_create() -> *mut ZmEngine;
    fn zm_engine_destroy(engine: *mut ZmEngine);
    fn zm_engine_set_volume(engine: *mut ZmEngine, volume: f32) -> i32;

    fn zm_sound_create_file(engine: *mut ZmEngine, path: *const c_char) -> *mut ZmSound;
    fn zm_sound_create_stream(
        engine: *mut ZmEngine,
        read_proc: StreamReadCallback,
        seek_proc: StreamSeekCallback,
        user_data: *mut c_void,
    ) -> *mut ZmSound;
    fn zm_sound_destroy(sound: *mut ZmSound);
    fn zm_sound_start(sound: *mut ZmSound) -> i32;
    fn zm_sound_stop(sound: *mut ZmSound) -> i32;
    fn zm_sound_set_volume(sound: *mut ZmSound, volume: f32) -> i32;
    fn zm_sound_seek_ms(sound: *mut ZmSound, position_ms: u64) -> i32;
    fn zm_sound_position_ms(sound: *const ZmSound) -> u64;
    fn zm_sound_duration_ms(sound: *const ZmSound) -> u64;
    fn zm_sound_at_end(sound: *const ZmSound) -> i32;
}

struct EngineInner {
    raw: NonNull<ZmEngine>,
}

// miniaudio synchronizes engine operations internally. Rust callers additionally serialize
// Player mutations per instance.
unsafe impl Send for EngineInner {}
unsafe impl Sync for EngineInner {}

impl Drop for EngineInner {
    fn drop(&mut self) {
        unsafe { zm_engine_destroy(self.raw.as_ptr()) };
    }
}

#[derive(Clone)]
pub struct Engine {
    inner: Arc<EngineInner>,
}

impl Engine {
    pub fn new() -> Result<Self, PlayerError> {
        let raw =
            NonNull::new(unsafe { zm_engine_create() }).ok_or(PlayerError::DeviceInitFailed)?;
        Ok(Self {
            inner: Arc::new(EngineInner { raw }),
        })
    }

    pub fn set_volume(&self, volume: f32) -> Result<(), PlayerError> {
        result(unsafe { zm_engine_set_volume(self.inner.raw.as_ptr(), volume) })
    }

    pub fn sound_from_file(&self, path: &str) -> Result<Sound, PlayerError> {
        let path = CString::new(path).map_err(|_| PlayerError::InvalidArgument)?;
        let raw =
            NonNull::new(unsafe { zm_sound_create_file(self.inner.raw.as_ptr(), path.as_ptr()) })
                .ok_or(PlayerError::DecodeFailed)?;
        Ok(Sound {
            raw,
            _engine: self.inner.clone(),
        })
    }

    /// # Safety
    ///
    /// `user_data` must remain valid until the returned `Sound` is dropped. Both callbacks must
    /// follow their C ABI contracts and may be called from miniaudio's audio thread.
    pub unsafe fn sound_from_stream(
        &self,
        read: StreamReadCallback,
        seek: StreamSeekCallback,
        user_data: *mut c_void,
    ) -> Result<Sound, PlayerError> {
        let raw = NonNull::new(unsafe {
            zm_sound_create_stream(self.inner.raw.as_ptr(), read, seek, user_data)
        })
        .ok_or(PlayerError::DecodeFailed)?;
        Ok(Sound {
            raw,
            _engine: self.inner.clone(),
        })
    }
}

pub struct Sound {
    raw: NonNull<ZmSound>,
    _engine: Arc<EngineInner>,
}

// A Sound is owned by one PlaybackSession. Player synchronization prevents concurrent mutation.
unsafe impl Send for Sound {}

impl Sound {
    pub fn start(&self) -> Result<(), PlayerError> {
        result(unsafe { zm_sound_start(self.raw.as_ptr()) })
    }

    pub fn stop(&self) -> Result<(), PlayerError> {
        result(unsafe { zm_sound_stop(self.raw.as_ptr()) })
    }

    pub fn set_volume(&self, volume: f32) -> Result<(), PlayerError> {
        result(unsafe { zm_sound_set_volume(self.raw.as_ptr(), volume) })
    }

    pub fn seek(&self, position_ms: u64) -> Result<(), PlayerError> {
        result(unsafe { zm_sound_seek_ms(self.raw.as_ptr(), position_ms) })
    }

    pub fn position_ms(&self) -> u64 {
        unsafe { zm_sound_position_ms(self.raw.as_ptr()) }
    }

    pub fn duration_ms(&self) -> u64 {
        unsafe { zm_sound_duration_ms(self.raw.as_ptr()) }
    }

    pub fn at_end(&self) -> bool {
        unsafe { zm_sound_at_end(self.raw.as_ptr()) != 0 }
    }
}

impl Drop for Sound {
    fn drop(&mut self) {
        unsafe { zm_sound_destroy(self.raw.as_ptr()) };
    }
}

fn result(code: i32) -> Result<(), PlayerError> {
    if code == 0 {
        Ok(())
    } else {
        Err(PlayerError::DecodeFailed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_initializes_without_a_physical_device() {
        let engine = Engine::new().unwrap();
        engine.set_volume(0.25).unwrap();
    }
}
