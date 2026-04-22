#!/usr/bin/env bash
# 生成发布清单文件 manifest.json
#
# 扫描当前目录下所有 .tar.gz 和 .zip 文件，
# 为每个文件计算 SHA-256、提取 target 平台标识，
# 生成 manifest.json 并将 is_prerelease 写入 GITHUB_OUTPUT。
#
# 环境变量:
#   GITHUB_REF_NAME   - 版本号，如 v1.0.0-alpha.1
#   GITHUB_SERVER_URL - GitHub 服务器地址，如 https://github.com
#   GITHUB_REPOSITORY - 仓库全称，如 zmusic-dev/zmusic-player

set -euo pipefail

version="${GITHUB_REF_NAME:?缺少环境变量: GITHUB_REF_NAME}"
server_url="${GITHUB_SERVER_URL:-https://github.com}"
repo="${GITHUB_REPOSITORY:?缺少环境变量: GITHUB_REPOSITORY}"
base_url="${server_url}/${repo}/releases/download/${version}"

# 判断是否为预发布版本（alpha/beta/rc/pre）
is_prerelease="false"
[[ "${version}" =~ -(alpha|beta|rc|pre)\. ]] && is_prerelease="true"

# 从文件名提取 target 平台标识
# 例: zmusic-x86_64-linux-v1.0.0.tar.gz -> x86_64-linux
extract_target() {
  local parts=(${1//-/ })
  echo "${parts[1]}-${parts[2]}"
}

# 收集各文件条目
entries=""
for f in *.tar.gz *.zip; do
  [ -f "$f" ] || continue
  [ -n "$entries" ] && entries+=","
  sha256=$(sha256sum "$f" | cut -d' ' -f1)
  size=$(stat -c%s "$f")
  target=$(extract_target "$f")
  entries+=$(cat <<ENTRY
{
  "name": "$f",
  "target": "$target",
  "sha256": "$sha256",
  "size": $size,
  "url": "${base_url}/${f}"
}
ENTRY
  )
done

# 生成并格式化 manifest.json
cat <<EOF | jq '.' > manifest.json
{
  "version": "$version",
  "prerelease": $is_prerelease,
  "files": [$entries]
}
EOF

echo "is_prerelease=${is_prerelease}" >> "${GITHUB_OUTPUT:-/dev/stdout}"
