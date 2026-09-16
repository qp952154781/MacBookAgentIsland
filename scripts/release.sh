#!/bin/bash
set -euo pipefail
if [[ $# -eq 1 && "$1" == --help ]]; then
    cat <<'HELP'
用法：scripts/release.sh
离线构建 macOS 14+ 的 Apple Silicon / Intel 通用发布包。
版本号读取 scripts/bundle.sh；复用其组装及 ad-hoc 签名逻辑。
输出：dist/AgentIsland-<版本>-macOS-universal.zip 及 .zip.sha256。
不会安装应用、申请管理员权限或发布到 GitHub。
HELP
    exit 0
fi
if [[ $# -ne 0 ]]; then
    echo "不支持的参数；使用 --help 查看说明。" >&2
    exit 2
fi
cd "$(dirname "$0")/.."
VERSION="$(scripts/bundle.sh --version)"
SCRATCH="${AI_SCRATCH:-$PWD/.build}"
mkdir -p dist
RELEASE_WORK="$(mktemp -d "$PWD/dist/.release.XXXXXX")"
trap 'rm -rf "$RELEASE_WORK"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

scripts/build.sh release --triple arm64-apple-macosx14.0
scripts/build.sh release --triple x86_64-apple-macosx14.0
lipo -create \
    "$SCRATCH/arm64-apple-macosx/release/AgentIsland" \
    "$SCRATCH/x86_64-apple-macosx/release/AgentIsland" \
    -output "$RELEASE_WORK/AgentIsland"
ARCHS="$(lipo -archs "$RELEASE_WORK/AgentIsland")"
case "$ARCHS" in
    "x86_64 arm64"|"arm64 x86_64") ;;
    *) echo "通用二进制架构不符合要求：$ARCHS" >&2; exit 1 ;;
esac

scripts/bundle.sh --binary "$RELEASE_WORK/AgentIsland"
APP="$PWD/dist/AgentIsland.app"
codesign --verify --deep --strict "$APP"
ARCHIVE_NAME="AgentIsland-$VERSION-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE_WORK/$ARCHIVE_NAME"
(
    # Store only the basename so the checksum works in the download directory.
    cd "$RELEASE_WORK"
    shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)
mv "$RELEASE_WORK/$ARCHIVE_NAME" "$PWD/dist/$ARCHIVE_NAME"
mv "$RELEASE_WORK/$ARCHIVE_NAME.sha256" "$PWD/dist/$ARCHIVE_NAME.sha256"
ARCHIVE="$PWD/dist/$ARCHIVE_NAME"
echo "发布包：$ARCHIVE"
echo "体积：$(stat -f '%z' "$ARCHIVE") 字节"
echo "SHA-256：$(awk '{print $1}' "$ARCHIVE.sha256")"
echo "架构：$ARCHS"
echo "校验文件：$ARCHIVE.sha256"
