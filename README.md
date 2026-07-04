<!--suppress HtmlDeprecatedAttribute -->
<div align="center">

![][banner]

![][language]
![][last-commit]

![][license]

[文档][docs-link] | [QQ 群][qq-group-link] | [Discord][discord-link]

</div>

## 简介

ZMusic Player 是一个跨平台音频播放器核心引擎，使用 Zig 实现，为 [ZMusic](https://github.com/starhui-dev/zmusic-server) 提供底层播放能力。

* 网络音频流式播放（边下边播）
* 本地文件播放
* LRC 歌词解析（支持翻译歌词配对）
* 播放队列管理（循环模式、随机播放）
* 延迟初始化音频引擎（避免空占设备）
* 跨平台支持（Linux / Windows / macOS）

## 构建

需要 [Zig](https://ziglang.org/) 0.16.0 或更高版本。

```sh
zig build              # 构建所有（共享库 + 可执行文件）
zig build run          # 运行桌面可执行文件
zig build test         # 运行所有单元测试
```

运行示例：

```sh
zig build run -- play https://example.com/audio.mp3
```

交叉编译：

```sh
zig build -Dtarget=x86_64-windows-gnu      # Windows
zig build -Dtarget=aarch64-macos           # macOS ARM64
```

## 架构

```
src/
├── main.zig           # CLI 入口（桌面可执行文件）
├── player.zig         # Player API 统一入口
├── state/             # 播放状态机 + 错误类型
├── queue/             # 播放队列管理
├── lyrics/            # LRC 歌词解析器
├── net/               # HTTP 客户端 + 流式播放
└── jni/               # JNI 导出函数 + 事件回调

examples/              # Java 侧 JNI 接口示例
vendor/miniaudio/      # C 音频引擎（vendored）
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

* [Zig](https://ziglang.org/) - 现代化的系统编程语言
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
