# ZMusic Player

## 项目概述

跨平台音频播放器核心引擎，Zig 0.16.0，通过 JNI 桥接供 Java 调用。唯一外部依赖：miniaudio（vendored）。

构建产物：`zig-out/lib/libzmusic.so`（JNI 共享库）+ `zig-out/bin/zmusic-player`（桌面可执行文件）。

## 构建 & 验证

```sh
zig build                          # 构建所有
zig build test                     # 运行测试
zig fmt src/ tests/ examples/      # 格式化（禁止提交未格式化的代码）
```

交叉编译验证（修改 `.zig` 后必须至少验证一个非本地目标）：
```sh
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=aarch64-macos
```

## 架构

`src/player.zig` 是唯一的公共入口，整合所有子系统。状态机：`stopped → loading → playing ⇄ paused`，`loading → error`。

新增测试文件需同步修改 `build.zig`（`addModuleTest` 辅助函数注册，需传入 import 映射）。

## 编码规范

### 跨平台（硬性）

- 平台差异统一收口到 `src/platform.zig`，业务代码禁止直接使用平台特定 API
- 条件编译使用 `builtin.os.tag`，平台专用函数（`std.os.linux.*` 等）必须在分支内

### Zig 风格

- 注释用中文；模块 `//!`，公开函数 `///`
- 命名：类型/常量 PascalCase，函数/变量 camelCase
- 错误定义集中在 `state/player_state.zig`；动态分配提供 `init`/`deinit`，分配链用 `errdefer`
- `PlaybackState.@"error"`：`error` 是保留字，必须用 `@"error"` 语法

### Java 风格

- JNI 命名：`Java_me_zhenxin_zmusic_ZMusicPlayer_{method}`

## CI 脚本

脚本在 `scripts/` 目录，禁止在 workflow YAML 中写内联逻辑。规则：bash + `set -euo pipefail`，参数通过环境变量，脚本顶部含用途说明和环境变量文档。

Actions 版本：`actions/checkout@v6`、`jdx/mise-action@v4`、`actions/upload-artifact@v7`、`actions/download-artifact@v8`、`softprops/action-gh-release@v3`。

分支：**dev** 开发，**main** 禁止直接推送，通过合并 dev 更新。

## 注意事项

- HttpClient 必须堆分配：`std.Io.Threaded.io()` 捕获结构体指针，栈分配会悬空
