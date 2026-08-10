# ZMusic Player

## 项目概述

跨平台音频播放器核心引擎，Rust 1.97.1，通过 JNI 桥接供 Java 调用。音频后端使用 Rodio 0.22.2、CPAL 和 Symphonia。

发布产物：`target/release/libzmusic.so`（JNI 共享库）+ `target/release/zmusic-player`（CLI）；扩展名按目标平台变化。

## 构建 & 验证

```sh
cargo build --release              # 构建 Rust 共享库和 CLI
cargo test --all-targets           # Rust 常规测试
cargo fmt --all --check            # Rust 格式检查
cargo test --test online_playback -- --ignored  # 需要公网
```

## 架构

`rust/src/player.rs` 是 Rust 公共入口；`PlaybackSession` 管理 Sound 与 HTTP 下载线程的释放顺序。`rust/src/jni_bridge.rs` 使用受控句柄表，`rust/src/audio.rs` 收口 Rodio/CPAL 音频输出和 Symphonia 解码。

状态机：`stopped → loading → playing ⇄ paused`，加载或播放失败进入 `error`。

Rust 集成测试直接放在 `tests/`。

## 编码规范

### Rust 风格

- `unsafe` 只用于 JNI 边界，并写清调用方必须保证的生命周期条件
- HTTP 流读取只消费下载线程写入的有界缓冲，缓冲上限保持为 4 MiB
- `PlaybackSession` 析构顺序固定为取消下载、销毁 Sound；Sound 中的 Decoder 释放 HttpStream 并 join 下载线程
- JNI 导出必须使用 `EnvUnowned::with_env`，禁止 panic 穿过 FFI
- Windows MSVC 产物通过 `.cargo/config.toml` 静态链接 CRT，保持便携包不依赖 `VCRUNTIME140.dll`

### Java 风格

- JNI 命名：`Java_me_zhenxin_zmusic_ZMusicPlayer_{method}`

## CI

Actions 版本：`actions/checkout@v6`、`jdx/mise-action@v4`、`actions/upload-artifact@v7`、`actions/download-artifact@v8`、`softprops/action-gh-release@v3`。

分支：**dev** 开发，**main** 禁止直接推送，通过合并 dev 更新。

## 注意事项

- Rust 在线测试依赖外部网络，常规 CI 不执行；Java JNI 烟雾测试在 Linux CI 执行
- Linux 构建 CPAL 需要 ALSA 开发库；Ubuntu CI 安装 `libasound2-dev`
