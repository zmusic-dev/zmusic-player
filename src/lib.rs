pub mod audio;
pub mod error_codes;
pub mod player;

use crate::error_codes::ErrorCode;
use crate::player::StreamPlayer;
use ez_jni::utils::get_env;
use ez_jni::*;
use lazy_static::lazy_static;
use std::sync::Mutex;

lazy_static! {
    static ref PLAYER: Mutex<StreamPlayer> = Mutex::new(StreamPlayer::new());
}

fn with_player<F, R>(f: F) -> Result<R, ErrorCode>
where
    F: FnOnce(&mut StreamPlayer) -> R,
{
    PLAYER
        .lock()
        .map_err(|_| ErrorCode::PlayerLockFailed)
        .map(|mut player_guard| f(&mut player_guard))
}

fn throw_error(message: &str) {
    let _ = get_env().throw_new("me/zhenxin/zmusic/player/JniPlayerException", message);
}

macro_rules! handle_void {
    ($result:expr) => {
        if let Err(error_code) = $result {
            throw_error(&error_code.format_message());
            return;
        }
    };
}

macro_rules! handle_getter {
    ($result:expr, |$info:ident| $extract:expr, $error_value:expr) => {
        match $result {
            Ok($info) => $extract,
            Err(error_code) => {
                throw_error(&error_code.format_message());
                return $error_value;
            }
        }
    };
}

jni_fn! { me.zhenxin.zmusic.player.JniPlayer =>
    pub fn nativeResetPlayer<'local>() {
        handle_void!(with_player(|player| player.reset()))
    }

    pub fn nativePlayUrl<'local>(url: String) {
        match with_player(|player| player.play_url(&url)) {
            Ok(Ok(_)) => {},
            Ok(Err(_player_error)) => {
                throw_error(&_player_error.format_message());
            }
            Err(error_code) => {
                throw_error(&error_code.format_message());
            }
        }
    }

    pub fn nativePause<'local>() {
        handle_void!(with_player(|player| player.pause()))
    }

    pub fn nativeResume<'local>() {
        handle_void!(with_player(|player| player.resume()))
    }

    pub fn nativeStop<'local>() {
        handle_void!(with_player(|player| player.stop()))
    }

    pub fn nativeSetVolume<'local>(volume: f32) {
        if volume < 0.0 || volume > 1.0 {
            throw_error(&ErrorCode::InvalidParameter.format_message());
            return;
        }
        handle_void!(with_player(|player| player.set_volume(volume)))
    }

    pub fn nativeGetStatus<'local>() -> i32 {
        handle_getter!(with_player(|player| player.get_player_info()), |info| info.status as i32, -1)
    }

    pub fn nativeGetPosition<'local>() -> i64 {
        handle_getter!(with_player(|player| player.get_player_info()), |info| info.current_time as i64, -1)
    }

    pub fn nativeGetDuration<'local>() -> i64 {
        handle_getter!(with_player(|player| player.get_player_info()), |info| info.total_time.unwrap_or(0) as i64, -1)
    }

    pub fn nativeGetVolume<'local>() -> f32 {
        handle_getter!(with_player(|player| player.get_player_info()), |info| info.volume, -1.0)
    }
}
