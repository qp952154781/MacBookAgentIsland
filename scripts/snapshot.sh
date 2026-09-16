#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh
SCRATCH="${AI_SCRATCH:-$PWD/.build}"
# Fixed display timezone prevents mock timestamps from revealing the host timezone.
TZ=UTC "$SCRATCH/debug/AgentIsland" --snapshot "${1:-out/snapshots}"
