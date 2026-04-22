#!/usr/bin/env bash
# 合并 macOS aarch64 和 x86_64 产物为通用二进制
#
# 从 dist/aarch64 和 dist/x86_64 读取各架构的 bin/lib，
# 使用 lipo 合并为通用二进制，输出到 zig-out/bin 和 zig-out/lib。

set -euo pipefail

mkdir -p zig-out/bin zig-out/lib

# 合并可执行文件
for bin in dist/aarch64/bin/*; do
  name=$(basename "$bin")
  lipo -create "dist/aarch64/bin/$name" "dist/x86_64/bin/$name" -output "zig-out/bin/$name"
done

# 合并动态库
for lib in dist/aarch64/lib/*; do
  name=$(basename "$lib")
  lipo -create "dist/aarch64/lib/$name" "dist/x86_64/lib/$name" -output "zig-out/lib/$name"
done
