<!--suppress HtmlDeprecatedAttribute -->
<div align="center">

![][banner]

![][language]
![][last-commit]

![][license]

[文档][docs-link] | [QQ 群][qq-group-link] | [Discord][discord-link]

</div>

## 简介

ZMusic Player 是一个跨平台音频播放器核心引擎，使用 Rust 实现，通过 JNI 为 [ZMusic](https://github.com/starhui-dev/zmusic-server) 提供底层播放能力。迁移观察期内保留 Zig 实现作为回归基线。

* 网络音频流式播放（边下边播）
* 本地文件播放
* LRC 歌词解析（支持翻译歌词配对）
* 播放队列管理（循环模式、随机播放）
* 延迟初始化音频引擎（避免空占设备）
* 跨平台支持（Linux / Windows / macOS）

## 构建

项目运行时版本由 `mise.toml` 固定。安装 [mise](https://mise.jdx.dev/) 后执行：

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

Zig 回归构建仍可使用 `zig build` 和 `zig build test`；它不是当前发布产物来源。

## 架构

```
rust/src/
├── player.rs          # Player API 和播放会话
├── audio.rs           # miniaudio 安全封装
├── stream.rs          # HTTP 有界流式缓冲
├── jni_bridge.rs      # JNI 适配和受控句柄表
├── queue.rs           # 播放队列
├── lyrics.rs          # LRC 歌词
└── bin/               # CLI

examples/              # Java 侧 JNI 接口示例
native/                # 最小 miniaudio C shim
vendor/miniaudio/      # C 音频引擎（vendored）
src/                   # 迁移观察期保留的 Zig 实现
```

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
* [Zig](https://ziglang.org/) - 迁移回归基线
* [miniaudio](https://github.com/mackron/miniaudio) - 跨平台音频引擎

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
