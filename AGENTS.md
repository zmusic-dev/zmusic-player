# AGENTS.md — zmusic-player

## 项目概述

跨平台音频播放器核心引擎，用 Zig 实现，通过 JNI 桥接供 Java 层调用。

- **语言**: Zig 0.16.0
- **构建系统**: `zig build`（`build.zig` + `build.zig.zon`）
- **唯一外部依赖**: miniaudio（C 库，vendored 在 `vendor/miniaudio/`）
- **最终产物**: `libzmusic.so`（共享库，供 Java 通过 JNI 加载）+ `zmusic-player`（桌面可执行文件，用于开发测试）

## 构建命令

```sh
zig build              # 构建所有（共享库 + 可执行文件）
zig build run          # 运行桌面可执行文件
zig build test         # 运行所有单元测试
```

运行示例：
```sh
zig build run -- play https://example.com/audio.mp3
```

交叉编译示例：
```sh
zig build -Dtarget=x86_64-windows-gnu      # Windows
zig build -Dtarget=aarch64-macos           # macOS ARM64
```

## 测试

测试文件位于 `tests/` 目录，每个文件是独立的测试模块：

- `tests/test_lyrics.zig` — LRC 歌词解析（元数据、时间戳、偏移、二分查找、畸形输入容错）
- `tests/test_queue.zig` — 播放队列（增删、导航、循环模式、跳转、清空）

运行所有测试：
```sh
zig build test
```

运行单个测试文件需要通过 `build.zig` 中定义的测试步骤。当前 `build.zig` 将所有测试挂载在统一的 `test` 步骤下，不支持单独运行某个测试文件。

模块测试通过 `addModuleTest` 辅助函数注册，需要显式传入 import 映射。新增测试文件时需要同步修改 `build.zig`。

## 架构

```
src/
├── main.zig           # CLI 入口（桌面可执行文件）
├── player.zig         # Player API 统一入口，整合所有子系统
├── platform.zig       # 跨平台工具函数（休眠等），统一收口平台差异
├── state/
│   └── player_state.zig   # 播放状态枚举 + 错误类型定义
├── queue/
│   └── playlist.zig       # 播放队列/列表管理
├── lyrics/
│   ├── types.zig          # 歌词数据结构（LyricLine, Lyrics, LrcMetadata）
│   └── parser.zig         # LRC 格式解析器
├── net/
│   ├── http_client.zig    # HTTP 客户端（基于 std.http + Threaded I/O）
│   └── streaming.zig      # 边下边播的流式数据源
└── jni/
    ├── bridge.zig         # JNI 导出函数（供 Java 调用的 native 方法）
    └── callback.zig       # 原子事件标志 + 轮询机制

examples/
└── ZMusicPlayer.java  # Java 侧 JNI 接口示例 + 事件轮询

tests/
├── test_lyrics.zig
└── test_queue.zig

vendor/
└── miniaudio/             # C 音频引擎（通过 @cImport 自动绑定）
```

### 关键设计

- **Player（`player.zig`）是唯一的公共入口**：外部只需 `@import("player.zig")` 即可获得完整播放能力。所有子系统类型通过 `pub const` 重导出到 Player 命名空间
- **延迟初始化**：音频引擎在首次 `play()` 时才初始化，避免空占音频设备
- **JNI 事件机制**：采用原子变量 + Java 轮询模式（`nativePollEvent`），避免在音频线程中直接调用 JNI（防死锁）
- **边下边播**：`StreamingSource` 实现生产者-消费者模式，后台线程下载，miniaudio 通过回调读取
- **miniaudio 绑定**：通过 `build.zig` 中 `addTranslateC` 自动翻译 C 头文件，无需手写 FFI

### 状态机

```
stopped → loading → playing ⇄ paused
                ↘ error
playing/paused → stopped（用户停止或列表播完）
```

## 编码规范

### 跨平台要求（硬性）

本项目必须同时支持 Linux、Windows、macOS 三个平台。所有代码必须满足：

- **平台差异统一收口到 `src/platform.zig`**：涉及平台差异的功能（休眠、时间戳等）必须封装在 `platform.zig` 中，业务代码通过 `@import("platform.zig")` 调用，禁止在业务模块中直接使用平台特定 API
- **禁止在条件编译外使用平台专用 API**：`std.os.linux.*`、`std.os.windows.*` 等平台特定函数可以正常使用，但必须在 `builtin.os.tag` 条件编译分支内
- **优先使用 `std` 标准库**：需要平台分支时使用 `builtin.os.tag` 条件编译，参考 `src/platform.zig` 的实现模式
- **新增代码必须交叉编译验证**：修改或新增 `.zig` 代码后，除本地构建外还需验证至少一个非本地目标平台的编译：
  ```sh
  zig build -Dtarget=x86_64-windows-gnu    # Windows
  zig build -Dtarget=aarch64-macos         # macOS ARM64
  ```

### Zig 代码风格

- **模块文档注释**：每个 `.zig` 文件顶部用 `//!` 编写模块级文档，说明模块职责和在架构中的位置
- **函数文档注释**：公开函数用 `///` 注释，包含参数说明、返回值、设计意图
- **中文注释**：所有注释和文档使用中文
- **命名**：类型用 PascalCase，函数/变量用 camelCase，常量用 PascalCase
- **错误处理**：使用 Zig 的 error union 类型，错误定义集中在 `state/player_state.zig`
- **内存管理**：显式分配器模式，所有需要动态分配的结构体提供 `init`/`deinit` 方法对
- **`errdefer`**：在可能失败的分配链中使用 `errdefer` 保证异常安全（见 `lyrics/parser.zig`）

### Java 代码风格

- JNI 函数命名遵循 JNI 规范：`Java_me_zhenxin_zmusic_ZMusicPlayer_{method}`

## 构建产物

- `zig-out/bin/zmusic-player` — 桌面可执行文件
- `zig-out/lib/libzmusic.so`（或对应平台扩展名）— JNI 共享库

## 验证流程

修改或新增 `.zig` 代码后，必须执行：

```sh
zig fmt src/ tests/ examples/    # 格式化
zig build test                   # 运行测试
```

**禁止提交未格式化的代码。**

## CI 脚本规范

### 脚本目录

所有 CI 相关脚本放在 `scripts/` 目录下，禁止在 workflow YAML 中编写内联 shell 逻辑：

- `scripts/package-artifacts.sh` — 将构建产物打包为发布归档
- `scripts/generate-manifest.sh` — 生成 manifest.json 清单文件
- `scripts/create-universal-macos.sh` — macOS aarch64 + x86_64 合并通用二进制

### Workflow 文件

- `.github/workflows/build.yml` — 构建测试（dev 分支触发）
- `.github/workflows/release.yml` — 发布流程（tag 触发）

### 编写规则

- **脚本语言**：bash，使用 `set -euo pipefail`
- **参数传递**：通过环境变量（`GITHUB_REF_NAME`、`GITHUB_SERVER_URL`、`GITHUB_REPOSITORY`），不使用命令行参数
- **调用方式**：`bash scripts/xxx.sh`，不依赖文件执行权限
- **注释**：每个脚本顶部必须包含用途说明和环境变量文档
- **manifest 文件**：命名为 `manifest.json`，通过 heredoc + `jq '.'` 生成，确保 JSON 格式正确
- **Node.js 版本**：两个 workflow 均设置 `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true`

### 分支与发布

- **dev** 是开发分支，所有修改在 dev 上进行
- **main** 禁止直接推送，只能通过合并 dev 更新
- 发布流程：dev 修改 → 推送 dev → 合并到 main → 打 tag → 触发 release workflow

## 注意事项

- **无 linter / type checker 配置**：Zig 编译器本身提供类型检查；格式化使用内置 `zig fmt`（无配置文件，风格固定）
- **CI**：GitHub Actions，Linux / Windows / macOS 三平台构建 + 测试（`.github/workflows/build.yml`）
- **HttpClient 必须堆分配**：`std.Io.Threaded.io()` 捕获结构体指针，栈分配会导致悬空指针
- **`PlaybackState.@"error"`**：`error` 是 Zig 保留字，必须使用 `@"error"` 语法
