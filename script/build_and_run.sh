#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WorkLight.app"

cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/WorkLight"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/WorkLight"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--run" ]]; then
  open "$APP"
fi
