use std::process::Command;

fn run(arguments: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_zmusic-player"))
        .args(arguments)
        .output()
        .unwrap()
}

#[test]
fn no_arguments_prints_the_zig_usage_and_succeeds() {
    let output = run(&[]);
    assert!(output.status.success());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("用法: zmusic-player <命令> [参数...]"));
    assert!(stderr.contains("play <URL或路径>  播放 URL 或本地音频文件"));
}

#[test]
fn unknown_command_and_missing_source_match_the_zig_cli() {
    let unknown = run(&["unknown"]);
    assert!(unknown.status.success());
    assert_eq!(
        String::from_utf8(unknown.stderr).unwrap().trim(),
        "未知命令: unknown"
    );

    let missing = run(&["play"]);
    assert!(missing.status.success());
    assert_eq!(
        String::from_utf8(missing.stderr).unwrap().trim(),
        "错误: play 命令需要一个 URL 或文件路径"
    );
}

#[test]
fn malformed_options_match_the_zig_cli_and_succeed() {
    for (arguments, message) in [
        (
            &["play", "song.mp3", "--lyrics"][..],
            "错误: --lyrics 需要指定歌词文件路径",
        ),
        (
            &["play", "song.mp3", "--volume"][..],
            "错误: --volume 需要指定音量 (0-100)",
        ),
        (
            &["play", "song.mp3", "--volume", "invalid"][..],
            "错误: --volume 参数无效 (需要 0-100 整数)",
        ),
    ] {
        let output = run(arguments);
        assert!(output.status.success());
        assert_eq!(String::from_utf8(output.stderr).unwrap().trim(), message);
    }
}
