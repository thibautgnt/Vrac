#!/bin/sh
# Debug capture of one room: tools/snap.sh <room> <out.png> [delay] [derived-data]
set -e
APP="${4:-.build/xcode-derived-data}/Build/Products/Debug/Vrac.app"
pkill -x Vrac 2>/dev/null || true
rm -f "$2"
open -n -W "$APP" --args -didCompleteOnboarding YES -VracRoom "$1" -VracSnapshot "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")" -VracSnapshotDelay "${3:-5}"
test -f "$2" && echo "$2"
