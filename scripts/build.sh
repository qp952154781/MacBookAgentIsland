#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${AI_SCRATCH:-$PWD/.build}"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/module-cache"
BUILD_CONFIGURATION="${1:-debug}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ "$BUILD_CONFIGURATION" == release ]]; then
    # Release binaries must not carry the builder's absolute source/object paths.
    # Keep normal debug builds unchanged for local debugging.
    set -- -debug-info-format none -Xswiftc -file-prefix-map -Xswiftc "$PWD=." \
        -Xswiftc -file-prefix-map -Xswiftc "$SCRATCH=./.build" \
        -Xswiftc -file-compilation-dir -Xswiftc . -Xlinker -S "$@"
fi
swift build -c "$BUILD_CONFIGURATION" --disable-sandbox --scratch-path "$SCRATCH" --cache-path "$SCRATCH/spm-cache" --config-path "$SCRATCH/spm-config" --security-path "$SCRATCH/spm-security" "$@"
