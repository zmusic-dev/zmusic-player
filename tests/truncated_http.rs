use std::io::{Read, Write};
use std::net::TcpListener;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use zmusic::Player;
use zmusic::state::{PlaybackState, PlayerError};

struct TruncatedServer {
    url: String,
    body_sent: Receiver<()>,
    disconnect: Sender<()>,
    worker: JoinHandle<()>,
}

impl TruncatedServer {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (body_sent_tx, body_sent) = mpsc::channel();
        let (disconnect, disconnect_rx) = mpsc::channel();
        let worker = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut request = [0_u8; 2_048];
            let _ = socket.read(&mut request);

            let body = truncated_wav_body();
            let declared_size = body.len() * 4;
            write!(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {declared_size}\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
            socket.write_all(&body).unwrap();
            socket.flush().unwrap();
            body_sent_tx.send(()).unwrap();

            let _ = disconnect_rx.recv_timeout(Duration::from_secs(5));
        });

        Self {
            url: format!("http://{address}/truncated.wav"),
            body_sent,
            disconnect,
            worker,
        }
    }

    fn wait_until_body_sent(&self) {
        self.body_sent
            .recv_timeout(Duration::from_secs(2))
            .expect("本地 HTTP 服务器未及时发送测试音频");
    }

    fn close(self) {
        let _ = self.disconnect.send(());
        self.worker.join().unwrap();
    }
}

fn truncated_wav_body() -> Vec<u8> {
    wav_body(256 * 1024, 8_000 * 2 * 60)
}

fn wav_body(actual_data_size: usize, declared_data_size: u32) -> Vec<u8> {
    let sample_rate = 8_000_u32;
    let mut body = Vec::with_capacity(44 + actual_data_size);
    body.extend_from_slice(b"RIFF");
    body.extend_from_slice(&(36 + declared_data_size).to_le_bytes());
    body.extend_from_slice(b"WAVEfmt ");
    body.extend_from_slice(&16_u32.to_le_bytes());
    body.extend_from_slice(&1_u16.to_le_bytes());
    body.extend_from_slice(&1_u16.to_le_bytes());
    body.extend_from_slice(&sample_rate.to_le_bytes());
    body.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    body.extend_from_slice(&2_u16.to_le_bytes());
    body.extend_from_slice(&16_u16.to_le_bytes());
    body.extend_from_slice(b"data");
    body.extend_from_slice(&declared_data_size.to_le_bytes());
    body.resize(44 + actual_data_size, 0);
    body
}

#[test]
fn local_http_wav_supports_playback_lifecycle() {
    let body = wav_body(64 * 1024, 64 * 1024);
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut request = [0_u8; 2_048];
        let _ = socket.read(&mut request);
        write!(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .unwrap();
        socket.write_all(&body).unwrap();
    });

    let mut player = Player::new();
    player.play(&format!("http://{address}/audio.wav")).unwrap();
    assert_eq!(player.state(), PlaybackState::Playing);
    assert!(player.duration_ms() > 3_000);

    let progress_deadline = Instant::now() + Duration::from_secs(2);
    while player.position_ms() <= 100 && Instant::now() < progress_deadline {
        player.tick();
        thread::sleep(Duration::from_millis(20));
    }
    assert!(
        player.position_ms() > 100,
        "HTTP WAV 进度未推进: state={:?}, error={:?}",
        player.state(),
        player.error()
    );
    player.pause().unwrap();
    let paused_at = player.position_ms();
    thread::sleep(Duration::from_millis(100));
    assert!(player.position_ms().abs_diff(paused_at) < 50);
    player.resume().unwrap();
    player.seek(1_000).unwrap();
    thread::sleep(Duration::from_millis(100));
    assert!(player.position_ms() >= 950);
    player.stop();
    assert_eq!(player.state(), PlaybackState::Stopped);
    server.join().unwrap();
}

#[test]
fn truncated_http_body_moves_player_to_error_state() {
    let server = TruncatedServer::start();
    let mut player = Player::new();

    player.play(&server.url).unwrap();
    assert_eq!(player.state(), PlaybackState::Playing);
    server.wait_until_body_sent();
    server.close();

    let deadline = Instant::now() + Duration::from_secs(2);
    while player.state() != PlaybackState::Error && Instant::now() < deadline {
        player.tick();
        thread::sleep(Duration::from_millis(10));
    }

    assert_eq!(player.state(), PlaybackState::Error);
    assert_eq!(player.error(), Some(PlayerError::HttpError));
}

#[test]
fn truncated_http_body_moves_paused_player_to_error_state() {
    let server = TruncatedServer::start();
    let mut player = Player::new();

    player.play(&server.url).unwrap();
    player.pause().unwrap();
    assert_eq!(player.state(), PlaybackState::Paused);
    server.wait_until_body_sent();
    server.close();

    let deadline = Instant::now() + Duration::from_secs(2);
    while player.state() != PlaybackState::Error && Instant::now() < deadline {
        player.tick();
        thread::sleep(Duration::from_millis(10));
    }

    assert_eq!(player.state(), PlaybackState::Error);
    assert_eq!(player.error(), Some(PlayerError::HttpError));
}

#[test]
fn cli_exits_with_an_error_when_http_body_is_truncated() {
    let server = TruncatedServer::start();
    let mut child = Command::new(env!("CARGO_BIN_EXE_zmusic-player"))
        .args(["play", &server.url])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    server.wait_until_body_sent();
    thread::sleep(Duration::from_millis(250));
    server.close();

    let deadline = Instant::now() + Duration::from_secs(3);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            let _ = child.wait();
            panic!("CLI 未在 HTTP 正文截断后及时退出");
        }
        thread::sleep(Duration::from_millis(20));
    };
    let output = child.wait_with_output().unwrap();

    assert!(!status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("HttpError"),
        "CLI 错误输出: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}
