<div align="center">

![][banner]

![][rust]
![][license]

</div>

# ZMusic Player

一个基于 Rust 和 Java JNI 的跨平台音乐播放器，支持网络流媒体播放。

## 特性

- 🎵 支持 MP3 和 FLAC 格式
- 🌐 支持 HTTP/HTTPS 网络流媒体
- 🔄 跨平台支持 (Windows, Linux, macOS)
- 🎛️ 完整的播放控制 (播放、暂停、恢复、停止)
- 🔊 音量控制
- 📊 实时播放状态监控

## 技术栈

- **Rust**: 核心播放器实现，使用 Symphonia 音频解码
- **Java JNI**: 通过 ez_jni 提供 Java 接口
- **CPAL**: 跨平台音频输出
- **Ureq**: HTTP 客户端

## 构建

### 前置要求

- Rust 1.70+
- Java 17+
- Cargo

### 构建步骤

```bash
# 克隆项目
git clone https://github.com/zhenxin/zmusic-player
cd zmusic-player

# 构建 Rust 库
cargo build
```

## 开源协议

本项目使用 [GPL-3.0](LICENSE) 协议开放源代码

```text
ZMusic Player
Copyright (C) 2025 ZhenXin
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
```

## 鸣谢

- [Symphonia](https://github.com/pdeljanov/Symphonia) - 音频解码库
- [CPAL](https://github.com/RustAudio/cpal) - 跨平台音频库
- [ez_jni](https://github.com/martinxyz/ez_jni) - JNI 绑定库


[banner]: https://socialify.git.ci/zmusic-dev/zmusic-player/image?description=1&forks=1&issues=1&language=1&name=1&owner=1&pulls=1&stargazers=1&theme=Auto

[rust]: https://img.shields.io/badge/rust-2024-blue?style=for-the-badge

[license]: https://img.shields.io/github/license/zmusic-dev/zmusic-player?style=for-the-badge
