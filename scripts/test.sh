#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${AI_SCRATCH:-$PWD/.build/tests}"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/module-cache"
if [[ "$(xcode-select -p)" == *Xcode.app* ]]; then
    swift test --disable-sandbox --scratch-path "$SCRATCH" --cache-path "$SCRATCH/spm-cache" --config-path "$SCRATCH/spm-config" --security-path "$SCRATCH/spm-security" "$@"
else
    FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
    swift test --disable-sandbox --scratch-path "$SCRATCH" --cache-path "$SCRATCH/spm-cache" --config-path "$SCRATCH/spm-config" --security-path "$SCRATCH/spm-security" \
        -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
fi
