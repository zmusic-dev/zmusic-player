# ZMusic Player

## 项目概述

跨平台音频播放器核心引擎，Rust 1.97.1，通过 JNI 桥接供 Java 调用。miniaudio 以 vendored C 依赖保留。Zig 0.16.0 实现仅作为迁移观察期的回归基线。

发布产物：`target/release/libzmusic.so`（JNI 共享库）+ `target/release/zmusic-player`（CLI）；扩展名按目标平台变化。

## 构建 & 验证

```sh
cargo build --release              # 构建 Rust 共享库和 CLI
cargo test --all-targets           # Rust 常规测试
cargo fmt --all --check            # Rust 格式检查
cargo test --test online_playback -- --ignored  # 需要公网
```

修改 `.zig` 时仍必须执行 Zig 格式化、测试和至少一个非本地目标构建：
```sh
zig fmt src/ tests/ examples/
zig build test
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=aarch64-macos
```

## 架构

`rust/src/player.rs` 是 Rust 公共入口；`PlaybackSession` 管理 Sound 与 HTTP 下载线程的释放顺序。`rust/src/jni_bridge.rs` 使用受控句柄表，`rust/src/audio.rs` 和 `native/miniaudio_shim.c` 收口 FFI。

状态机：`stopped → loading → playing ⇄ paused`，加载或播放失败进入 `error`。

Rust 集成测试直接放在 `tests/`。新增 Zig 测试文件仍需同步修改 `build.zig`。

## 编码规范

### 跨平台（硬性）

- 平台差异统一收口到 `src/platform.zig`，业务代码禁止直接使用平台特定 API
- 条件编译使用 `builtin.os.tag`，平台专用函数（`std.os.linux.*` 等）必须在分支内

### Zig 风格

- 注释用中文；模块 `//!`，公开函数 `///`
- 命名：类型/常量 PascalCase，函数/变量 camelCase
- 错误定义集中在 `state/player_state.zig`；动态分配提供 `init`/`deinit`，分配链用 `errdefer`
- `PlaybackState.@"error"`：`error` 是保留字，必须用 `@"error"` 语法

### Rust 风格

- `unsafe` 只用于 C/JNI 边界，并写清调用方必须保证的生命周期条件
- 网络回调不得执行网络 I/O；缓冲上限保持为 4 MiB
- `PlaybackSession` 析构顺序固定为取消下载、销毁 Sound、join 下载线程
- JNI 导出必须使用 `EnvUnowned::with_env`，禁止 panic 穿过 FFI
- Windows MSVC 产物通过 `.cargo/config.toml` 静态链接 CRT，保持便携包不依赖 `VCRUNTIME140.dll`

### Java 风格

- JNI 命名：`Java_me_zhenxin_zmusic_ZMusicPlayer_{method}`

## CI

Actions 版本：`actions/checkout@v6`、`jdx/mise-action@v4`、`actions/upload-artifact@v7`、`actions/download-artifact@v8`、`softprops/action-gh-release@v3`。

分支：**dev** 开发，**main** 禁止直接推送，通过合并 dev 更新。

## 注意事项

- Rust 在线测试依赖外部网络，常规 CI 不执行；Java JNI 烟雾测试在 Linux CI 执行
- Zig `HttpClient` 必须堆分配：`std.Io.Threaded.io()` 捕获结构体指针，栈分配会悬空
