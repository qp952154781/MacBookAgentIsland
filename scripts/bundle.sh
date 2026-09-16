#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh release
scripts/make-icon.sh
SCRATCH="${AI_SCRATCH:-$PWD/.build}"
APP="$PWD/dist/AgentIsland.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$SCRATCH/release/AgentIsland" "$APP/Contents/MacOS/AgentIsland"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.agentisland.AgentIsland</string>
<key>CFBundleName</key><string>AgentIsland</string>
<key>CFBundleDisplayName</key><string>刘海灵动岛</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleExecutable</key><string>AgentIsland</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$APP"
echo "$APP"
