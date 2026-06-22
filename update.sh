#!/usr/bin/env bash
set -euo pipefail

# Hermes Studio 一键更新脚本
# 用法: ./update.sh <新版本号>
# 示例: ./update.sh 0.6.18
#
# 流程:
#   1. 从 lzc-manifest.yml 注释读取上游镜像模板
#   2. 复制上游镜像到 LazyCat registry
#   3. 更新 package.yml 版本号
#   4. 更新 lzc-manifest.yml 中的镜像地址和注释
#   5. 构建 LPK 包

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PACKAGE_FILE="package.yml"
MANIFEST_FILE="lzc-manifest.yml"
BUILD_FILE="lzc-build.yml"

VERSION="${1:-}"

if [[ -z "$VERSION" || "$VERSION" == "-h" || "$VERSION" == "--help" ]]; then
  cat <<'EOF'
Hermes Studio 一键更新脚本

用法: ./update.sh <新版本号>

示例:
  ./update.sh 0.6.18          # 更新到 v0.6.18，自动构建 LPK

流程:
  1. 读取 lzc-manifest.yml 注释中的上游镜像（如 ekkoye8888/hermes-web-ui:v0.6.17）
  2. 复制 ekkoye8888/hermes-web-ui:<新版本> 到 LazyCat registry
  3. 更新 package.yml 版本号
  4. 更新 lzc-manifest.yml 镜像地址和注释
  5. 构建 LPK 包（输出到当前目录）
EOF
  [[ "$VERSION" == "-h" || "$VERSION" == "--help" ]] && exit 0
  exit 1
fi

[[ "$VERSION" != *[[:space:]]* ]] || { echo "error: 版本号不能包含空格" >&2; exit 1; }

# ── 工具函数 ───────────────────────────────────────────────
die()  { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

# ── 检查依赖 ───────────────────────────────────────────────
need_cmd awk
need_cmd grep
need_cmd mktemp

[[ -f "$PACKAGE_FILE" ]] || die "$PACKAGE_FILE 不存在"
[[ -f "$MANIFEST_FILE" ]] || die "$MANIFEST_FILE 不存在"
[[ -f "$BUILD_FILE" ]]    || die "$BUILD_FILE 不存在"

# ── 从 manifest 注释提取上游镜像 ───────────────────────────
# 注释格式: #  ekkoye8888/hermes-web-ui:v0.6.17
UPSTREAM_IMAGE=$(awk '
  /hermes-webui:[[:space:]]*$/ { in_service = 1; next }
  in_service && /^[[:space:]]*# / {
    img = $0
    sub(/^[[:space:]]*#[[:space:]]*/, "", img)
    gsub(/[[:space:]]*$/, "", img)
    if (img ~ /^[a-zA-Z0-9].*:[a-zA-Z0-9]/) { print img; exit }
  }
  in_service && /^[[:space:]]*image:/ { exit }
' "$MANIFEST_FILE")

[[ -n "$UPSTREAM_IMAGE" ]] || die "无法从 $MANIFEST_FILE 注释中提取上游镜像（格式: # org/repo:tag）"

# 替换版本号
SOURCE_IMAGE="${UPSTREAM_IMAGE%:*}:$VERSION"
note "上游镜像: $SOURCE_IMAGE"

# ── 复制镜像到 LazyCat registry ──────────────────────────
copy_image() {
  local source=$1
  local output=""

  # 优先使用 fish 函数 lzc-copy-image
  if command -v fish >/dev/null 2>&1 && fish -lc 'functions -q lzc-copy-image' 2>/dev/null; then
    note "使用 fish lzc-copy-image 复制镜像"
    output=$(COPY_IMAGE="$source" fish -lc 'lzc-copy-image "$COPY_IMAGE"' 2>&1) || {
      printf '%s\n' "$output" >&2
      die "镜像复制失败"
    }
  else
    need_cmd lzc-cli
    note "使用 lzc-cli appstore copy-image 复制镜像"
    output=$(lzc-cli appstore copy-image "$source" 2>&1) || {
      printf '%s\n' "$output" >&2
      die "镜像复制失败"
    }
  fi

  printf '%s\n' "$output" >&2

  # 从输出中提取 registry.lazycat.cloud 镜像地址
  LAZYCAT_IMAGE=$(printf '%s\n' "$output" \
    | grep -Eo 'registry\.lazycat\.cloud/[A-Za-z0-9._:@/-]+' \
    | tail -n 1)

  [[ -n "$LAZYCAT_IMAGE" ]] || die "无法从 copy-image 输出中解析 registry 地址，原始输出:\n$output"
}

copy_image "$SOURCE_IMAGE"
note "LazyCat 镜像: $LAZYCAT_IMAGE"

# ── 更新 package.yml 版本号 ──────────────────────────────
note "更新 $PACKAGE_FILE 版本号 -> $VERSION"
tmp_pkg=$(mktemp)
awk -v ver="$VERSION" '
  !done && /^version:[[:space:]]*/ { print "version: " ver; done = 1; next }
  { print }
' "$PACKAGE_FILE" >"$tmp_pkg"
mv "$tmp_pkg" "$PACKAGE_FILE"

# ── 更新 lzc-manifest.yml 注释和镜像 ─────────────────────
note "更新 $MANIFEST_FILE 镜像 -> $LAZYCAT_IMAGE"
tmp_mnf=$(mktemp)
awk -v new_comment="#  ${SOURCE_IMAGE}" -v new_image="$LAZYCAT_IMAGE" '
  /hermes-webui:[[:space:]]*$/ { in_service = 1; print; next }
  in_service && /^[[:space:]]*# [a-zA-Z0-9].*:[a-zA-Z0-9]/ {
    print "    " new_comment
    replaced_comment = 1
    next
  }
  in_service && /^[[:space:]]*image:/ {
    print "    image: " new_image
    in_service = 0
    next
  }
  { print }
' "$MANIFEST_FILE" >"$tmp_mnf"
mv "$tmp_mnf" "$MANIFEST_FILE"

# ── 构建 LPK ──────────────────────────────────────────────
LPK_FILE="community.lazycat.app.hermes-studio-v${VERSION}.lpk"

build_lpk() {
  if command -v fish >/dev/null 2>&1 && fish -lc 'functions -q lzc-release' 2>/dev/null; then
    note "使用 fish lzc-release 构建"
    fish -lc 'lzc-release'
  elif command -v lzc-cli >/dev/null 2>&1; then
    note "使用 lzc-cli project release 构建"
    lzc-cli project release -o "$LPK_FILE"
  else
    die "缺少 lzc-cli，请先安装: npm install -g @lazycatcloud/lzc-cli"
  fi
}

build_lpk

[[ -f "$LPK_FILE" ]] || die "构建产物不存在: $LPK_FILE"

# ── 完成 ──────────────────────────────────────────────────
echo ""
echo "✅ 更新完成!"
echo "   版本:     $VERSION"
echo "   上游镜像: $SOURCE_IMAGE"
echo "   注册镜像: $LAZYCAT_IMAGE"
echo "   LPK 文件: $LPK_FILE"
echo ""
echo "如需安装到微服: lzc-cli app install $LPK_FILE"
