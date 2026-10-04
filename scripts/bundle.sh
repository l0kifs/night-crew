#!/bin/bash
# Builds NightCrew.app from source and ad-hoc signs it (SPEC §3, §9 step 3).
# Progress goes to stderr; the last line on stdout is the path of the .app.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

swift build -c release --quiet --product nightcrew >&2
BIN="$(swift build -c release --show-bin-path)/nightcrew"
APP="$ROOT/.build/bundle/NightCrew.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/nightcrew"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - --identifier dev.l0kifs.nightcrew "$APP" >&2
codesign --verify --strict "$APP" >&2

echo "$APP"
