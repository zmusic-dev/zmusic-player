use std::io::Read;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use zmusic::Player;
use zmusic::state::PlaybackState;
use zmusic::stream::HttpStream;

const TEST_MP3: &str = "https://cdn.zhenxin.me/%E6%88%91%E7%9A%84%E6%82%B2%E4%BC%A4%E6%98%AF%E6%B0%B4%E5%81%9A%E7%9A%84.mp3";
const TEST_MP3_BYTES: usize = 3_844_855;
static ONLINE_TEST_LOCK: Mutex<()> = Mutex::new(());

#[test]
#[ignore = "需要访问公网"]
fn online_mp3_stream_downloads_to_eof() {
    let _guard = ONLINE_TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut stream = HttpStream::start(TEST_MP3).unwrap();
    let mut buffer = [0_u8; 64 * 1024];
    let mut total = 0;
    loop {
        let bytes_read = stream
            .read(&mut buffer)
            .unwrap_or_else(|error| panic!("在线流在 {total} 字节后失败: {error}"));
        total += bytes_read;
        if bytes_read == 0 {
            break;
        }
    }
    assert_eq!(total, TEST_MP3_BYTES);
}

#[test]
#[ignore = "需要访问公网和实时音频时钟"]
fn online_mp3_supports_the_full_playback_lifecycle() {
    let _guard = ONLINE_TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut player = Player::new();
    player.play(TEST_MP3).unwrap();
    assert_eq!(player.state(), PlaybackState::Playing);
    assert!(player.duration_ms() > 10_000);

    let progress_deadline = Instant::now() + Duration::from_secs(5);
    while player.position_ms() <= 500 && Instant::now() < progress_deadline {
        thread::sleep(Duration::from_millis(50));
    }
    assert!(player.position_ms() > 500);

    player.pause().unwrap();
    let paused_at = player.position_ms();
    thread::sleep(Duration::from_millis(300));
    assert!(player.position_ms().abs_diff(paused_at) < 100);

    player.resume().unwrap();
    thread::sleep(Duration::from_millis(300));
    assert!(player.position_ms() > paused_at);

    player.seek(5_000).unwrap();
    thread::sleep(Duration::from_millis(200));
    assert!(player.position_ms() >= 4_900);

    player.stop();
    assert_eq!(player.state(), PlaybackState::Stopped);
    assert_eq!(player.position_ms(), 0);
}
