#!/bin/bash
set -euo pipefail
# Keep release metadata here; release.sh reads the version through --version.
APP_VERSION="0.2.3"
BUILD_NUMBER="5"
BINARY=""
usage() {
    cat <<'HELP'
用法：scripts/bundle.sh [--binary <可执行文件>] | --version | --help
默认构建本机 release；--binary 跳过构建，使用指定二进制。
生成并验证 ad-hoc 签名的 dist/AgentIsland.app。
HELP
}
if [[ $# -eq 1 ]]; then
    case "$1" in
        --help) usage; exit 0 ;;
        --version) echo "$APP_VERSION"; exit 0 ;;
    esac
fi
if [[ $# -gt 0 ]]; then
    if [[ $# -ne 2 || "$1" != --binary || -z "$2" ]]; then
        usage >&2
        exit 2
    fi
    # Resolve relative input paths before changing to the project directory.
    case "$2" in
        /*) BINARY="$2" ;;
        *) BINARY="$PWD/$2" ;;
    esac
    if [[ ! -f "$BINARY" || ! -x "$BINARY" ]]; then
        echo "找不到可执行文件：$BINARY" >&2
        exit 1
    fi
fi
cd "$(dirname "$0")/.."
if [[ -z "$BINARY" ]]; then
    scripts/build.sh release
    SCRATCH="${AI_SCRATCH:-$PWD/.build}"
    BINARY="$SCRATCH/release/AgentIsland"
fi
scripts/make-icon.sh
mkdir -p dist
BUNDLE_WORK="$(mktemp -d "$PWD/dist/.bundle.XXXXXX")"
trap 'rm -rf "$BUNDLE_WORK"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
APP="$BUNDLE_WORK/AgentIsland.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BINARY" "$APP/Contents/MacOS/AgentIsland"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.agentisland.AgentIsland</string>
<key>CFBundleName</key><string>AgentIsland</string>
<key>CFBundleDisplayName</key><string>刘海灵动岛</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleExecutable</key><string>AgentIsland</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
# Replace only after the complete staged bundle has passed verification.
rm -rf "$PWD/dist/AgentIsland.app"
mv "$APP" "$PWD/dist/AgentIsland.app"
echo "$PWD/dist/AgentIsland.app"
