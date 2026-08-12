<!--suppress HtmlDeprecatedAttribute -->
<div align="center">

![][banner]

![][language]
![][last-commit]

![][license]

[文档][docs-link] | [QQ 群][qq-group-link] | [Discord][discord-link]

</div>

## 简介

ZMusic Player 是一个跨平台音频播放器核心引擎，使用 Rust 实现，通过 JNI 为 [ZMusic](https://github.com/starhui-dev/zmusic-server) 提供底层播放能力。

* 网络音频流式播放（边下边播）
* 本地文件播放
* LRC 歌词解析（支持翻译歌词配对）
* 播放队列管理（循环模式、随机播放）
* 延迟初始化音频引擎（避免空占设备）
* 跨平台支持（Linux / Windows / macOS / Android，含 ARM64）

## 构建

项目运行时版本由 `mise.toml` 固定。安装 [mise](https://mise.jdx.dev/) 后执行：

Linux 构建依赖 ALSA 开发库：

```sh
# Debian / Ubuntu
sudo apt-get install libasound2-dev

# Arch Linux
sudo pacman -S alsa-lib
```

安装系统依赖后执行：

```sh
mise install
cargo build --release  # 构建 JNI 共享库和 CLI
cargo test --all-targets
```

运行示例：

```sh
cargo run --release -- play https://example.com/audio.mp3
```

需要公网的音频生命周期测试默认忽略，显式运行：

```sh
cargo test --test online_playback -- --ignored
```

Rust 构建产物位于 `target/release/`：Linux 为 `libzmusic.so`，Windows 为 `zmusic.dll`，macOS 为 `libzmusic.dylib`，CLI 名为 `zmusic-player`。Windows MSVC 产物静态链接 CRT，不要求用户另行安装 Visual C++ Redistributable。

ARM64 发布目标包括 Windows `aarch64-pc-windows-msvc`、Linux `aarch64-unknown-linux-gnu` 和 Android `aarch64-linux-android`。

Android ARM64 使用 `aarch64-linux-android` 目标，最低支持 Android 8.0（API 26），发布产物为 JNI 库 `libzmusic.so`，不包含桌面 CLI。Android 端必须在创建第一个播放器前传入 Application 或 Activity Context：

```java
ZMusicPlayer.initializeAndroid(context);
```

Android HTTPS 使用内置的 Mozilla 根证书，不要求宿主应用额外打包证书验证 AAR 或 Kotlin 运行时。

## 架构

```
rust/src/
├── player.rs          # Player API 和播放会话
├── audio.rs           # Rodio 输出、解码和无设备时钟
├── stream.rs          # 4 MiB HTTP 有界流式缓冲
├── jni_bridge.rs      # JNI 适配和受控句柄表
├── queue.rs           # 播放队列
├── lyrics.rs          # LRC 歌词
└── bin/               # CLI

examples/              # Java 侧 JNI 接口示例
```

音频输出由 Rodio 和 CPAL 提供，MP3、WAV、FLAC、Vorbis 解码由 Symphonia 提供。无物理输出设备时使用实时无声时钟，使服务端和 CI 环境仍能执行完整播放生命周期。

## 开源协议

本项目使用 [GPL-3.0](LICENSE) 协议开放源代码

```text
ZMusic Player - Cross-platform Audio Player Engine
Copyright (C) 2026 ZhenXin
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
```

## 鸣谢

* [Rust](https://www.rust-lang.org/) - 播放器核心实现语言
* [Rodio](https://github.com/RustAudio/rodio) - 音频播放与控制
* [CPAL](https://github.com/RustAudio/cpal) - 跨平台音频输出
* [Symphonia](https://github.com/pdeljanov/Symphonia) - 音频格式解码

## 贡献者

[![][contrib]](https://github.com/starhui-dev/zmusic-player/graphs/contributors)

[banner]: https://socialify.git.ci/starhui-dev/zmusic-player/image?description=1&forks=1&issues=1&language=1&name=1&owner=1&pulls=1&stargazers=1&theme=Auto

[language]: https://img.shields.io/github/languages/top/starhui-dev/zmusic-player?style=for-the-badge

[last-commit]: https://img.shields.io/github/last-commit/starhui-dev/zmusic-player?style=for-the-badge

[license]: https://img.shields.io/github/license/starhui-dev/zmusic-player?style=for-the-badge

[contrib]: https://contrib.rocks/image?repo=starhui-dev/zmusic-player

[docs-link]: https://zmusic.zhenxin.me

[qq-group-link]: https://qm.qq.com/q/buxuatfTCo

[discord-link]: https://discord.gg/twQgJNufYn
