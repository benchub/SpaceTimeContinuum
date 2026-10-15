#!/usr/bin/env bash
# Builds "Space Time Continuum.app" into macos/build/.
#
#   scripts/build-app.sh            # release build, ad-hoc signed
#   SIGN_IDENTITY="Apple Development: you@example.com" scripts/build-app.sh
#
# macOS ties the Input Monitoring permission to the code signature. With ad-hoc
# signing you'll need to re-grant permission after each rebuild; signing with a
# stable identity avoids that.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$HERE/build/Space Time Continuum.app"

cd "$HERE"
swift build -c "$CONFIG" --scratch-path "$HERE/.build"
BIN="$(swift build -c "$CONFIG" --scratch-path "$HERE/.build" --show-bin-path)/SpaceTimeContinuum"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SpaceTimeContinuum"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/shared/units.json" "$ROOT/shared/keyboards.json" "$APP/Contents/Resources/"

# Generate AppIcon.icns from the shared source image.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -s format png -z $s $s "$ROOT/shared/icon.jpg" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -s format png -z $((s*2)) $((s*2)) "$ROOT/shared/icon.jpg" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime --timestamp=none "$APP"
echo "Built $APP"
