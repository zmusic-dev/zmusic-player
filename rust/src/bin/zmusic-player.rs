use std::fs;
use std::io::{self, IsTerminal, Write};
use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use crossterm::cursor::{Hide, MoveToColumn, MoveToNextLine, MoveUp, Show};
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use crossterm::style::Print;
use crossterm::terminal::{Clear, ClearType, disable_raw_mode, enable_raw_mode};
use crossterm::{execute, queue};
use encoding_rs::GBK;
use zmusic::Player;
use zmusic::state::PlaybackState;

const FRAME_INTERVAL: Duration = Duration::from_millis(200);

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("错误: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    if arguments.is_empty() {
        print_usage();
        return Ok(());
    }
    if matches!(arguments[0].as_str(), "--help" | "-h") {
        print_help();
        return Ok(());
    }
    if arguments[0] != "play" {
        eprintln!("未知命令: {}", arguments[0]);
        return Ok(());
    }
    if arguments.len() < 2 {
        eprintln!("错误: play 命令需要一个 URL 或文件路径");
        return Ok(());
    }
    let options = match Options::parse(arguments.into_iter()) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("{message}");
            return Ok(());
        }
    };

    let source = options
        .source
        .as_deref()
        .ok_or_else(|| "play 命令需要一个 URL 或文件路径".to_owned())?;
    let mut player = Player::new();
    player
        .set_volume(options.volume)
        .map_err(|error| error.to_string())?;
    let lyrics_source = options.lyrics.as_deref();
    if let Some(lyrics_source) = lyrics_source {
        let lyrics = load_lyrics(lyrics_source)?;
        player.load_lyrics(&lyrics);
    }
    println!("正在播放: {source}");
    if let Some(lyrics_source) = lyrics_source {
        println!("歌词已加载: {lyrics_source}");
    }
    player.play(source).map_err(|error| error.to_string())?;

    let interactive = io::stdin().is_terminal() && io::stdout().is_terminal();
    let mut stdout = io::stdout();
    let terminal = interactive
        .then(|| TerminalSession::start(&mut stdout))
        .transpose()?;
    let mut display_started = false;
    let mut quit = false;

    while !quit {
        if interactive {
            while let Some(control) = read_control()? {
                quit = apply_control(&mut player, control);
                if quit {
                    break;
                }
            }
        }

        let ended = player.tick();
        let state = player.state();
        let error = player.error();
        if interactive {
            render(&mut stdout, &player, display_started)?;
            display_started = true;
        }
        if ended {
            break;
        }
        if state == PlaybackState::Error {
            return Err(error.map_or_else(|| "播放失败".to_owned(), |error| error.to_string()));
        }
        if state == PlaybackState::Stopped {
            break;
        }
        thread::sleep(FRAME_INTERVAL);
    }

    player.stop();
    drop(terminal);
    if display_started {
        writeln!(stdout).map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Control {
    Toggle,
    Quit,
    SeekBack,
    SeekForward,
    VolumeUp,
    VolumeDown,
}

impl Control {
    fn from_key_code(code: KeyCode) -> Option<Self> {
        match code {
            KeyCode::Char(' ') => Some(Self::Toggle),
            KeyCode::Char('q') => Some(Self::Quit),
            KeyCode::Left => Some(Self::SeekBack),
            KeyCode::Right => Some(Self::SeekForward),
            KeyCode::Up => Some(Self::VolumeUp),
            KeyCode::Down => Some(Self::VolumeDown),
            _ => None,
        }
    }
}

fn read_control() -> Result<Option<Control>, String> {
    while event::poll(Duration::ZERO).map_err(|error| error.to_string())? {
        let event = event::read().map_err(|error| error.to_string())?;
        if let Event::Key(key) = event
            && matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat)
            && let Some(control) = Control::from_key_code(key.code)
        {
            return Ok(Some(control));
        }
    }
    Ok(None)
}

fn apply_control(player: &mut Player, control: Control) -> bool {
    match control {
        Control::Toggle => match player.state() {
            PlaybackState::Playing => {
                let _ = player.pause();
            }
            PlaybackState::Paused => {
                let _ = player.resume();
            }
            _ => {}
        },
        Control::Quit => return true,
        Control::SeekBack => {
            let _ = player.seek(player.position_ms().saturating_sub(5_000));
        }
        Control::SeekForward => {
            let target = player.position_ms().saturating_add(5_000);
            if target < player.duration_ms() {
                let _ = player.seek(target);
            }
        }
        Control::VolumeUp => {
            let _ = player.set_volume(player.volume() + 0.1);
        }
        Control::VolumeDown => {
            let _ = player.set_volume(player.volume() - 0.1);
        }
    }
    false
}

struct TerminalSession;

impl TerminalSession {
    fn start(stdout: &mut io::Stdout) -> Result<Self, String> {
        enable_raw_mode().map_err(|error| error.to_string())?;
        if let Err(error) = execute!(stdout, Hide) {
            let _ = disable_raw_mode();
            return Err(error.to_string());
        }
        Ok(Self)
    }
}

impl Drop for TerminalSession {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), Show);
    }
}

fn render(stdout: &mut io::Stdout, player: &Player, started: bool) -> Result<(), String> {
    if started {
        queue!(stdout, MoveUp(3)).map_err(|error| error.to_string())?;
    }

    let position = player.position_ms();
    let duration = player.duration_ms();
    let icon = match player.state() {
        PlaybackState::Playing => "▶",
        PlaybackState::Paused => "⏸",
        _ => "■",
    };
    let mut status = format!("{icon} {}/{}", format_time(position), format_time(duration));
    let volume = (player.volume() * 100.0).round() as u32;
    if volume != 100 {
        status.push_str(&format!(" vol:{volume:02}%"));
    }
    if let Some(lyric) = player.current_lyric() {
        status.push_str("  ");
        status.push_str(&lyric.text);
    }

    queue!(
        stdout,
        MoveToColumn(0),
        Clear(ClearType::CurrentLine),
        Print(format!("进度：[{}]", progress_bar(position, duration, 40))),
        MoveToNextLine(1),
        Clear(ClearType::CurrentLine),
        Print(status),
        MoveToNextLine(1),
        Clear(ClearType::CurrentLine),
        Print("Space:暂停/播放  q:退出  ←→:快退/快进  ↑↓:音量"),
        MoveToNextLine(1)
    )
    .map_err(|error| error.to_string())?;
    stdout.flush().map_err(|error| error.to_string())
}

fn progress_bar(position: u64, duration: u64, width: usize) -> String {
    const SUB_BLOCKS: [char; 8] = ['▏', '▎', '▍', '▌', '▋', '▊', '▉', '█'];

    let fraction = if duration == 0 {
        0.0
    } else {
        (position as f64 / duration as f64).clamp(0.0, 1.0)
    };
    let total_sub_blocks = (fraction * (width * 8) as f64) as usize;
    let mut bar = String::with_capacity(width * 3);
    for index in 0..width {
        let sub_blocks = total_sub_blocks.saturating_sub(index * 8).min(8);
        if sub_blocks == 0 {
            bar.push(' ');
        } else {
            bar.push(SUB_BLOCKS[sub_blocks - 1]);
        }
    }
    bar
}

fn load_lyrics(source: &str) -> Result<String, String> {
    let bytes = if source.starts_with("http://") || source.starts_with("https://") {
        download_lyrics(source)?
    } else {
        fs::read(source).map_err(|error| format!("无法加载歌词文件 '{source}': {error}"))?
    };
    if let Ok(text) = std::str::from_utf8(&bytes) {
        return Ok(text.to_owned());
    }
    let (text, _, had_errors) = GBK.decode(&bytes);
    if had_errors {
        return Err(format!("歌词文件 '{source}' 不是有效的 UTF-8 或 GBK"));
    }
    Ok(text.into_owned())
}

fn download_lyrics(url: &str) -> Result<Vec<u8>, String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|error| format!("无法创建歌词下载客户端: {error}"))?;
    client
        .get(url)
        .send()
        .and_then(reqwest::blocking::Response::error_for_status)
        .and_then(reqwest::blocking::Response::bytes)
        .map(|bytes| bytes.to_vec())
        .map_err(|error| format!("无法下载歌词 '{url}': {error}"))
}

fn format_time(milliseconds: u64) -> String {
    let seconds = milliseconds / 1_000;
    format!("{:02}:{:02}", seconds / 60, seconds % 60)
}

struct Options {
    source: Option<String>,
    lyrics: Option<String>,
    volume: f32,
}

impl Options {
    fn parse(args: impl Iterator<Item = String>) -> Result<Self, String> {
        let mut args = args.peekable();
        if args.next().as_deref() != Some("play") {
            return Err("只支持 play 命令".to_owned());
        }

        let source = args.next();
        let mut lyrics = None;
        let mut volume = 0.2;
        while let Some(argument) = args.next() {
            match argument.as_str() {
                "--lyrics" => {
                    lyrics = Some(
                        args.next()
                            .ok_or_else(|| "错误: --lyrics 需要指定歌词文件路径".to_owned())?,
                    );
                }
                "--volume" => {
                    let percent: u8 = args
                        .next()
                        .ok_or_else(|| "错误: --volume 需要指定音量 (0-100)".to_owned())?
                        .parse()
                        .map_err(|_| "错误: --volume 参数无效 (需要 0-100 整数)".to_owned())?;
                    volume = (f32::from(percent) / 100.0).clamp(0.0, 1.0);
                }
                _ => {}
            }
        }
        Ok(Self {
            source,
            lyrics,
            volume,
        })
    }
}

fn print_usage() {
    eprintln!("用法: zmusic-player <命令> [参数...]");
    eprintln!("命令:");
    eprintln!("  play <URL或路径>  播放 URL 或本地音频文件");
    eprintln!("  --help            显示帮助信息");
}

fn print_help() {
    eprintln!(
        "ZMusic Player - 网络音频播放器\n\n用法: zmusic-player play <URL或路径> [--lyrics <LRC文件路径>] [--volume <0-100>]\n\n选项:\n  --lyrics <路径>      加载 LRC 格式歌词文件\n  --volume <0-100>     设置初始音量百分比，默认 20\n\n播放控制:\n  Space   播放 / 暂停\n  q       停止并退出\n  ←/→     快退/快进 5 秒\n  ↑/↓     音量增减 10%"
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_play_options() {
        let options = Options::parse(
            [
                "play",
                "song.mp3",
                "--lyrics",
                "lyrics.lrc",
                "--volume",
                "25",
            ]
            .into_iter()
            .map(str::to_owned),
        )
        .unwrap();
        assert_eq!(options.source.as_deref(), Some("song.mp3"));
        assert_eq!(options.lyrics.as_deref(), Some("lyrics.lrc"));
        assert_eq!(options.volume, 0.25);
    }

    #[test]
    fn default_volume_is_one_hundred_percent() {
        let options = Options::parse(["play", "song.mp3"].into_iter().map(str::to_owned)).unwrap();
        assert_eq!(options.volume, 0.2);
    }

    #[test]
    fn playback_keys_map_to_controls() {
        use crossterm::event::KeyCode;

        assert_eq!(
            Control::from_key_code(KeyCode::Char(' ')),
            Some(Control::Toggle)
        );
        assert_eq!(
            Control::from_key_code(KeyCode::Char('q')),
            Some(Control::Quit)
        );
        assert_eq!(
            Control::from_key_code(KeyCode::Left),
            Some(Control::SeekBack)
        );
        assert_eq!(
            Control::from_key_code(KeyCode::Right),
            Some(Control::SeekForward)
        );
        assert_eq!(Control::from_key_code(KeyCode::Up), Some(Control::VolumeUp));
        assert_eq!(
            Control::from_key_code(KeyCode::Down),
            Some(Control::VolumeDown)
        );
        assert_eq!(Control::from_key_code(KeyCode::Enter), None);
    }

    #[test]
    fn volume_above_one_hundred_is_clamped() {
        let options = Options::parse(
            ["play", "song.mp3", "--volume", "101"]
                .into_iter()
                .map(str::to_owned),
        )
        .unwrap();
        assert_eq!(options.volume, 1.0);
    }

    #[test]
    fn unknown_trailing_arguments_are_ignored() {
        let options = Options::parse(
            ["play", "song.mp3", "--unknown"]
                .into_iter()
                .map(str::to_owned),
        )
        .unwrap();
        assert_eq!(options.source.as_deref(), Some("song.mp3"));
    }
}
