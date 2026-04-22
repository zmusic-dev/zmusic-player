#!/usr/bin/env bash
# 将各平台的构建产物打包为发布归档文件
#
# 读取 artifacts/ 下各平台目录（zmusic-*），
# Windows 平台打包为 zip，其他平台打包为 tar.gz。
#
# 环境变量:
#   GITHUB_REF_NAME - 版本号，如 v1.0.0-alpha.1

set -euo pipefail

version="${GITHUB_REF_NAME:?缺少环境变量: GITHUB_REF_NAME}"

for dir in artifacts/zmusic-*; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")

  # 归档文件名格式: zmusic-<target>-<version>.<ext>
  if [[ "$name" == *windows* ]]; then
    # Windows 使用 zip 格式
    (cd "$dir" && zip -r "../../${name}-${version}.zip" .)
  else
    # Linux/macOS 使用 tar.gz 格式
    tar czf "${name}-${version}.tar.gz" -C "$dir" .
  fi
done
