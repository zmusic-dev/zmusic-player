use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use jni::EnvUnowned;
use jni::errors::LogErrorAndDefault;
#[cfg(target_os = "android")]
use jni::objects::{Global, JClass};
use jni::objects::{JObject, JString, Reference};
use jni::sys::{jboolean, jfloat, jint, jlong};
#[cfg(target_os = "android")]
use jni::{jni_sig, jni_str};

use crate::Player;
use crate::event::Event;
use crate::queue::Track;
use crate::state::RepeatMode;

type SharedPlayer = Arc<Mutex<Player>>;

static NEXT_HANDLE: AtomicI64 = AtomicI64::new(1);
static HANDLES: OnceLock<Mutex<HashMap<jlong, SharedPlayer>>> = OnceLock::new();
#[cfg(target_os = "android")]
static ANDROID_CONTEXT: Mutex<Option<Global<JObject<'static>>>> = Mutex::new(None);

fn handles() -> &'static Mutex<HashMap<jlong, SharedPlayer>> {
    HANDLES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn get_player(handle: jlong) -> Option<SharedPlayer> {
    lock(handles()).get(&handle).cloned()
}

fn with_player<R>(handle: jlong, default: R, operation: impl FnOnce(&mut Player) -> R) -> R {
    let Some(player) = get_player(handle) else {
        return default;
    };
    operation(&mut lock(&player))
}

fn report_error(handle: jlong) {
    with_player(handle, (), Player::report_error);
}

fn optional_string(env: &jni::Env<'_>, value: &JString<'_>) -> jni::errors::Result<Option<String>> {
    if value.is_null() {
        Ok(None)
    } else {
        value.try_to_string(env).map(Some)
    }
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeInitializeAndroid<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _class: JClass<'local>,
    context: JObject<'local>,
) -> jint {
    unowned_env
        .with_env(|env| -> jni::errors::Result<_> {
            if context.is_null() {
                return Ok(Some(-1));
            }

            let mut android_context = lock(&ANDROID_CONTEXT);
            if android_context.is_some() {
                return Ok(Some(0));
            }

            let application_context = env
                .call_method(
                    &context,
                    jni_str!("getApplicationContext"),
                    jni_sig!("()Landroid/content/Context;"),
                    &[],
                )?
                .l()?;
            if application_context.is_null() {
                return Ok(Some(-1));
            }

            let java_vm = env.get_java_vm()?;
            let context = env.new_global_ref(application_context)?;
            let initialized = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                // SAFETY: JNI 提供有效的 VM 指针，全局引用在进程生命周期内保持有效，
                // 且互斥锁保证 ndk-context 只由本库初始化一次。
                unsafe {
                    ndk_context::initialize_android_context(
                        java_vm.get_raw().cast(),
                        context.as_raw().cast(),
                    );
                }
            }))
            .is_ok();
            if !initialized {
                return Ok(Some(-1));
            }

            *android_context = Some(context);
            Ok(Some(0))
        })
        .resolve::<LogErrorAndDefault>()
        .unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeInit<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
) -> jlong {
    unowned_env
        .with_env(|_| -> jni::errors::Result<_> {
            let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
            if handle <= 0 {
                return Ok(0);
            }
            lock(handles()).insert(handle, Arc::new(Mutex::new(Player::new())));
            Ok(handle)
        })
        .resolve::<LogErrorAndDefault>()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeDestroy<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
) {
    unowned_env
        .with_env(|_| -> jni::errors::Result<_> {
            let player = lock(handles()).remove(&handle);
            drop(player);
            Ok(())
        })
        .resolve::<LogErrorAndDefault>()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlay<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
    source: JString<'local>,
) -> jint {
    unowned_env
        .with_env(|env| -> jni::errors::Result<_> {
            let source = source.try_to_string(env)?;
            Ok(Some(with_player(handle, -1, |player| {
                player.play(&source).map_or(-1, |_| 0)
            })))
        })
        .resolve::<LogErrorAndDefault>()
        .unwrap_or(-1)
}

macro_rules! player_result_method {
    ($name:ident, $method:ident) => {
        #[unsafe(no_mangle)]
        pub extern "system" fn $name<'local>(
            mut unowned_env: EnvUnowned<'local>,
            _this: JObject<'local>,
            handle: jlong,
        ) -> jint {
            unowned_env
                .with_env(|_| -> jni::errors::Result<_> {
                    Ok(Some(with_player(handle, -1, |player| {
                        player.$method().map_or(-1, |_| 0)
                    })))
                })
                .resolve::<LogErrorAndDefault>()
                .unwrap_or(-1)
        }
    };
}

player_result_method!(Java_me_zhenxin_zmusic_ZMusicPlayer_nativePause, pause);
player_result_method!(Java_me_zhenxin_zmusic_ZMusicPlayer_nativeResume, resume);

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeStop<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
) -> jint {
    unowned_env
        .with_env(|_| -> jni::errors::Result<_> {
            Ok(Some(with_player(handle, -1, |player| {
                player.stop();
                0
            })))
        })
        .resolve::<LogErrorAndDefault>()
        .unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSeek<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
    position_ms: jlong,
) -> jint {
    unowned_env
        .with_env(|_| -> jni::errors::Result<_> {
            if position_ms < 0 {
                report_error(handle);
                return Ok(Some(-1));
            }
            Ok(Some(with_player(handle, -1, |player| {
                player.seek(position_ms as u64).map_or(-1, |_| 0)
            })))
        })
        .resolve::<LogErrorAndDefault>()
        .unwrap_or(-1)
}

macro_rules! player_getter {
    ($name:ident, $return_type:ty, $default:expr, $body:expr) => {
        #[unsafe(no_mangle)]
        pub extern "system" fn $name<'local>(
            mut unowned_env: EnvUnowned<'local>,
            _this: JObject<'local>,
            handle: jlong,
        ) -> $return_type {
            unowned_env
                .with_env(|_| -> jni::errors::Result<_> {
                    Ok(with_player(handle, $default, $body))
                })
                .resolve::<LogErrorAndDefault>()
        }
    };
}

player_getter!(
    Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetState,
    jint,
    0,
    |player| player.state() as jint
);
player_getter!(
    Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetPosition,
    jlong,
    0,
    |player| player.position_ms().min(jlong::MAX as u64) as jlong
);
player_getter!(
    Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetDuration,
    jlong,
    0,
    |player| player.duration_ms().min(jlong::MAX as u64) as jlong
);
player_getter!(
    Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetVolume,
    jfloat,
    1.0,
    |player| player.volume()
);
player_getter!(
    Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetQueueSize,
    jint,
    0,
    |player| player.queue_len().min(jint::MAX as usize) as jint
);
player_getter!(
    Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetCurrentIndex,
    jint,
    0,
    |player| player.current_index().min(jint::MAX as usize) as jint
);

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSetVolume<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
    volume: jfloat,
) -> jint {
    unowned_env
        .with_env(|_| -> jni::errors::Result<_> {
            Ok(Some(with_player(handle, -1, |player| {
                player.set_volume(volume).map_or(-1, |_| 0)
            })))
        })
        .resolve::<LogErrorAndDefault>()
        .unwrap_or(-1)
}

fn enqueue(handle: jlong, track: Track, next: bool) {
    with_player(handle, (), |player| {
        if next {
            player.enqueue_next(track);
        } else {
            player.enqueue(track);
        }
    });
}

macro_rules! enqueue_method {
    ($name:ident, $next:expr) => {
        #[unsafe(no_mangle)]
        pub extern "system" fn $name<'local>(
            mut unowned_env: EnvUnowned<'local>,
            _this: JObject<'local>,
            handle: jlong,
            url: JString<'local>,
            title: JString<'local>,
            artist: JString<'local>,
        ) {
            unowned_env
                .with_env(|env| -> jni::errors::Result<_> {
                    let mut track = Track::new(url.try_to_string(env)?);
                    track.title = optional_string(env, &title)?;
                    track.artist = optional_string(env, &artist)?;
                    enqueue(handle, track, $next);
                    Ok(())
                })
                .resolve::<LogErrorAndDefault>()
        }
    };
}

enqueue_method!(Java_me_zhenxin_zmusic_ZMusicPlayer_nativeEnqueue, false);
enqueue_method!(Java_me_zhenxin_zmusic_ZMusicPlayer_nativeEnqueueNext, true);

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeRemoveFromQueue<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
    index: jint,
) {
    unowned_env
        .with_env(|_| -> jni::errors::Result<_> {
            if index < 0
                || with_player(handle, true, |player| {
                    player.remove_from_queue(index as usize).is_err()
                })
            {
                report_error(handle);
            }
            Ok(())
        })
        .resolve::<LogErrorAndDefault>()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeClearQueue<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
) {
    unowned_env
        .with_env(|_| -> jni::errors::Result<_> {
            with_player(handle, (), Player::clear_queue);
            Ok(())
        })
        .resolve::<LogErrorAndDefault>()
}

macro_rules! queue_play_method {
    ($name:ident, $method:ident) => {
        #[unsafe(no_mangle)]
        pub extern "system" fn $name<'local>(
            mut unowned_env: EnvUnowned<'local>,
            _this: JObject<'local>,
            handle: jlong,
        ) {
            unowned_env
                .with_env(|_| -> jni::errors::Result<_> {
                    if with_player(handle, true, |player| player.$method().is_err()) {
                        report_error(handle);
                    }
                    Ok(())
                })
                .resolve::<LogErrorAndDefault>()
        }
    };
}

queue_play_method!(
    Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlayNext,
    play_next
);
queue_play_method!(
    Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlayPrevious,
    play_previous
);

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePlayAtIndex<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
    index: jint,
) {
    unowned_env
        .with_env(|_| -> jni::errors::Result<_> {
            if index < 0
                || with_player(handle, true, |player| {
                    player.play_at_index(index as usize).is_err()
                })
            {
                report_error(handle);
            }
            Ok(())
        })
        .resolve::<LogErrorAndDefault>()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeLoadLyrics<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
    content: JString<'local>,
) {
    unowned_env
        .with_env(|env| -> jni::errors::Result<_> {
            let content = content.try_to_string(env)?;
            with_player(handle, (), |player| player.load_lyrics(&content));
            Ok(())
        })
        .resolve::<LogErrorAndDefault>()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetCurrentLyric<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
) -> JString<'local> {
    unowned_env
        .with_env(|env| -> jni::errors::Result<_> {
            let text = with_player(handle, None, |player| {
                player.current_lyric().map(|line| line.text.clone())
            });
            match text {
                Some(text) => JString::from_str(env, text),
                None => Ok(JString::default()),
            }
        })
        .resolve::<LogErrorAndDefault>()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeGetLyricLineAt<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
    time_ms: jlong,
) -> JString<'local> {
    unowned_env
        .with_env(|env| -> jni::errors::Result<_> {
            if time_ms < 0 {
                report_error(handle);
                return Ok(JString::default());
            }
            let text = with_player(handle, None, |player| {
                player
                    .lyric_line_at(time_ms as u64)
                    .map(|line| line.text.clone())
            });
            match text {
                Some(text) => JString::from_str(env, text),
                None => Ok(JString::default()),
            }
        })
        .resolve::<LogErrorAndDefault>()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSetRepeatMode<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
    mode: jint,
) {
    unowned_env
        .with_env(|_| -> jni::errors::Result<_> {
            match RepeatMode::try_from(mode) {
                Ok(mode) => with_player(handle, (), |player| player.set_repeat_mode(mode)),
                Err(_) => report_error(handle),
            }
            Ok(())
        })
        .resolve::<LogErrorAndDefault>()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativeSetShuffle<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
    enabled: jboolean,
) {
    unowned_env
        .with_env(|_| -> jni::errors::Result<_> {
            with_player(handle, (), |player| player.set_shuffle(enabled));
            Ok(())
        })
        .resolve::<LogErrorAndDefault>()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_me_zhenxin_zmusic_ZMusicPlayer_nativePollEvent<'local>(
    mut unowned_env: EnvUnowned<'local>,
    _this: JObject<'local>,
    handle: jlong,
) -> jint {
    unowned_env
        .with_env(|_| -> jni::errors::Result<_> {
            Ok(with_player(handle, Event::None as jint, |player| {
                player.poll_event() as jint
            }))
        })
        .resolve::<LogErrorAndDefault>()
}
