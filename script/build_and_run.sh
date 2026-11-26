#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/WorkLight.app"
GIT_SHA="${WORKLIGHT_GIT_SHA:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"

cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/WorkLight"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/WorkLight"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace GitCommitSHA -string "$GIT_SHA" "$APP/Contents/Info.plist"
xattr -cr "$APP" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--run" ]]; then
  open "$APP"
fi
