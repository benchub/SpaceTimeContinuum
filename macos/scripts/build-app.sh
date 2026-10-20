#!/usr/bin/env bash
# Builds "Space Time Continuum.app" into macos/build/.
#
#   scripts/build-app.sh            # release build, ad-hoc signed
#   SIGN_IDENTITY="Apple Development: you@example.com" scripts/build-app.sh
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=stc-notary scripts/build-app.sh
#                                   # also notarizes and staples (profile made via
#                                   # `xcrun notarytool store-credentials`)
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

# Embed Sparkle (auto-updates). SwiftPM drops the framework next to the binary.
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/SpaceTimeContinuum"

# Notarization requires a secure timestamp.
TS="--timestamp=none"; [[ -n "${NOTARY_PROFILE:-}" ]] && TS="--timestamp"
SIGN=(codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime $TS)

# Sign Sparkle inside-out, per https://sparkle-project.org/documentation/sandboxing/#code-signing
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPK/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPK/Autoupdate"
"${SIGN[@]}" "$SPK/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ZIP="$(mktemp -d)/app.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -rf "$(dirname "$ZIP")"
fi
echo "Built $APP"
