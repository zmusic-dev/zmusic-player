//! Zig 构建系统配置文件
//!
//! 定义项目的构建流程，包括：
//! - 共享库（JNI 桥接）：编译为动态链接库供 Java 层通过 JNI 加载
//! - 可执行文件：独立运行的播放器程序（用于桌面测试）
//! - 测试：各模块的单元测试
//!
//! 构建依赖：
//! - miniaudio：跨平台音频引擎（C 库，通过 @cImport 引入）
//! - 平台特定的系统库（见 linkPlatformLibs）

const std = @import("std");

/// 项目构建入口。
///
/// 整体流程：
/// 1. 解析目标平台和优化选项
/// 2. 创建 miniaudio 模块（C 头文件翻译）
/// 3. 构建共享库（JNI 桥接）
/// 4. 构建可执行文件
/// 5. 配置运行步骤
/// 6. 配置测试步骤
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const miniaudio_mod = createMiniaudioModule(b, target, optimize);

    // 平台工具模块（跨平台休眠、时间戳等）
    const platform_mod = b.createModule(.{
        .root_source_file = b.path("src/platform.zig"),
    });

    // 歌词类型模块（共享库和测试共享）
    const lyrics_types_mod = b.createModule(.{
        .root_source_file = b.path("src/lyrics/types.zig"),
    });

    // 共享库（JNI 桥接）
    // 编译为动态链接库（libzmusic.so / zmusic.dll），供 Java 层通过 System.loadLibrary 加载
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zmusic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/jni/bridge.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureModule(b, shared_lib.root_module, target, miniaudio_mod, platform_mod);
    // callback 模块作为独立 import，供 bridge.zig 导入事件回调机制
    shared_lib.root_module.addImport("callback", b.createModule(.{
        .root_source_file = b.path("src/jni/callback.zig"),
    }));
    // Player 模块（bridge.zig 通过 @import("player") 引入）
    //
    // 由于共享库根模块路径为 src/jni/，无法通过 ../player.zig 相对导入，
    // 因此将 player.zig 作为独立命名模块引入，并配置其依赖的命名导入。
    //
    // player.zig 已修改为通过 @import("lyrics_types") 命名导入获取歌词类型定义，
    // 而非相对导入 lyrics/types.zig，避免 types.zig 同时属于 player 模块和
    // lyrics_types 模块（Zig 不允许同一文件属于多个模块）。
    const player_mod_for_lib = b.createModule(.{
        .root_source_file = b.path("src/player.zig"),
    });
    player_mod_for_lib.addImport("miniaudio", miniaudio_mod);
    player_mod_for_lib.addImport("platform", platform_mod);
    player_mod_for_lib.addImport("lyrics_types", lyrics_types_mod);
    shared_lib.root_module.addImport("player", player_mod_for_lib);
    b.installArtifact(shared_lib);

    // 可执行文件
    // 独立运行的播放器程序，用于桌面环境下的开发测试
    const exe = b.addExecutable(.{
        .name = "zmusic-player",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureModule(b, exe.root_module, target, miniaudio_mod, platform_mod);
    // player.zig 使用 @import("lyrics_types")，exe 通过 main.zig 相对导入 player.zig，
    // 因此 exe 模块也需要 lyrics_types 命名导入
    exe.root_module.addImport("lyrics_types", lyrics_types_mod);

    b.installArtifact(exe);

    // 运行
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "运行应用");
    run_step.dependOn(&run_cmd.step);

    // 测试
    const test_step = b.step("test", "运行单元测试");

    // 主模块单元测试
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureModule(b, main_tests.root_module, target, miniaudio_mod, platform_mod);
    main_tests.root_module.addImport("lyrics_types", lyrics_types_mod);
    test_step.dependOn(&b.addRunArtifact(main_tests).step);

    // 歌词模块（应用和测试共享）
    // 歌词解析器模块
    // 解析器依赖类型定义模块（lyrics_types_mod 已在共享库部分创建）
    const lyrics_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/lyrics/parser.zig"),
    });
    // 解析器依赖类型定义模块
    lyrics_parser_mod.addImport("lyrics_types", lyrics_types_mod);

    addModuleTest(b, test_step, target, optimize, miniaudio_mod, platform_mod, "tests/test_lyrics.zig", &.{
        .{ "lyrics_parser", lyrics_parser_mod },
        .{ "lyrics", lyrics_types_mod },
    });

    const queue_mod = b.createModule(.{
        .root_source_file = b.path("src/queue/playlist.zig"),
    });
    queue_mod.addImport("platform", platform_mod);
    addModuleTest(b, test_step, target, optimize, miniaudio_mod, platform_mod, "tests/test_queue.zig", &.{
        .{ "queue", queue_mod },
    });
}

/// 创建 miniaudio 绑定模块。
///
/// 通过 Zig 的 @cImport 机制自动翻译 C 头文件，生成可在 Zig 中直接调用的
/// 类型安全绑定，无需手写 FFI 桥接代码。
fn createMiniaudioModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/miniaudio/miniaudio.h"),
        .target = target,
        .optimize = optimize,
    });
    return translate.createModule();
}

/// 为构建模块应用通用配置。
///
/// 所有需要音频能力的模块（共享库、可执行文件、测试）都通过此函数统一配置，
/// 确保 miniaudio 导入、C 源文件和平台链接库的一致性。
fn configureModule(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    miniaudio_mod: *std.Build.Module,
    platform_mod: *std.Build.Module,
) void {
    mod.addImport("miniaudio", miniaudio_mod);
    mod.addImport("platform", platform_mod);
    addMiniaudioCSources(b, mod);
    linkPlatformLibs(b, mod, target);
}

/// 创建并注册模块级测试。
///
/// 封装测试创建的通用逻辑：创建测试可执行文件、添加依赖模块、
/// 链接平台库，最后挂载到总测试步骤下。
fn addModuleTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    miniaudio_mod: *std.Build.Module,
    platform_mod: *std.Build.Module,
    test_path: []const u8,
    imports: []const struct { []const u8, *std.Build.Module },
) void {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(test_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    t.root_module.addImport("miniaudio", miniaudio_mod);
    t.root_module.addImport("platform", platform_mod);
    for (imports) |imp| {
        t.root_module.addImport(imp[0], imp[1]);
    }
    linkPlatformLibs(b, t.root_module, target);
    test_step.dependOn(&b.addRunArtifact(t).step);
}

/// 添加 miniaudio 的 C 源文件。
///
/// miniaudio 是纯 C 库，虽然通过 @cImport 翻译了头文件获得了类型定义和函数声明，
/// 但实际的实现代码（miniaudio.c）仍需作为 C 源文件参与编译和链接。
fn addMiniaudioCSources(b: *std.Build, mod: *std.Build.Module) void {
    mod.addCSourceFile(.{
        .file = b.path("vendor/miniaudio/miniaudio.c"),
        .flags = &.{},
    });
    mod.addIncludePath(b.path("vendor/miniaudio"));
}

/// 链接各平台所需的系统库。
///
/// miniaudio 在不同操作系统上依赖不同的底层音频 API，需要链接对应的系统库：
///
/// - Linux：
///   - pthread：POSIX 线程库，用于异步音频回调
///   - m：数学库，音频处理中的数学运算
///   - dl：动态链接库，用于运行时加载音频驱动
///
/// - Windows：
///   - winmm：Windows 多媒体 API
///   - ole32：COM 基础库，部分音频接口依赖 COM
///   - uuid：UUID 生成，COM 组件标识
///
/// - macOS：
///   - CoreAudio：核心音频服务
///   - AudioToolbox：高级音频工具箱（编解码、格式转换等）
///   - CoreFoundation：基础框架，提供数据类型和运行时支持
fn linkPlatformLibs(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .linux => {
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("dl", .{});
        },
        .windows => {
            mod.linkSystemLibrary("winmm", .{});
            mod.linkSystemLibrary("ole32", .{});
            mod.linkSystemLibrary("uuid", .{});
        },
        .macos => {
            // 显式添加 macOS SDK 框架搜索路径。
            // Zig 的 linkFramework 在某些环境（如 CI）下无法自动定位 SDK，
            // 需要通过 getSdk 获取路径后手动添加搜索路径。
            if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
                mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
                mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
                mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
            }
            mod.linkFramework("CoreAudio", .{});
            mod.linkFramework("AudioToolbox", .{});
            mod.linkFramework("CoreFoundation", .{});
        },
        else => {},
    }
}
