#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_WORK="$PWD/.build/icon"
mkdir -p "$ICON_WORK/module-cache" "$PWD/Resources"
swiftc -module-cache-path "$ICON_WORK/module-cache" scripts/make-icon.swift -o "$ICON_WORK/make-icon"
"$ICON_WORK/make-icon" "$ICON_WORK/AppIcon.iconset"
if ! iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$PWD/Resources/AppIcon.icns" 2> "$ICON_WORK/iconutil.log"; then
    echo "iconutil 编码失败（详见 .build/icon/iconutil.log）；使用同一组 PNG 的原生 ICNS 容器。" >&2
    cp "$ICON_WORK/AppIcon-fallback.icns" "$PWD/Resources/AppIcon.icns"
fi
echo "已生成 Resources/AppIcon.icns"
