#!/usr/bin/env bash
# Packages the app into a drag-to-Applications .dmg in macos/build/.
#
#   scripts/build-dmg.sh
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=stc-notary scripts/build-dmg.sh
#
# With SIGN_IDENTITY and NOTARY_PROFILE set, the app and the dmg are both
# signed, notarized and stapled, ready to distribute.
#
# The window layout is set through Finder with AppleScript, so run this from a
# logged-in desktop session (the first run may ask to let your terminal control Finder).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HERE/build/Space Time Continuum.app"
VOLNAME="Space Time Continuum"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HERE/Resources/Info.plist")"
DMG="$HERE/build/SpaceTimeContinuum-$VERSION.dmg"

# Always rebuild so the dmg matches the current sources and signing settings.
"$HERE/scripts/build-app.sh"

WORK="$(mktemp -d)"
# Keep our own copy, in case the app in build/ is moved while notarization runs.
ICNS="$WORK/AppIcon.icns"
cp "$APP/Contents/Resources/AppIcon.icns" "$ICNS"
MOUNT="/Volumes/$VOLNAME"
cleanup() {
  hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true

# A blank image with headroom: one made from a folder is sized to fit exactly,
# leaving no room for the volume icon or Finder's .DS_Store.
APP_MB=$(du -sm "$APP" | cut -f1)
RW="$WORK/rw.sparsebundle"
diskutil image create blank --format UDSB --fs APFS --size "$((APP_MB + 50))m" --volumeName "$VOLNAME" "$RW" >/dev/null
diskutil image attach --mountPoint "$MOUNT" "$RW" >/dev/null

ditto "$APP" "$MOUNT/$(basename "$APP")"
ln -s /Applications "$MOUNT/Applications"
mkdir -p "$MOUNT/.background"
swift "$HERE/scripts/dmg-background.swift" "$MOUNT/.background/background.png"

# Window is 660x400 of content; Finder bounds include ~28pt of title bar.
osascript <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.png"
    set position of item "Space Time Continuum.app" of container window to {170, 200}
    set position of item "Applications" of container window to {490, 200}
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

# After the Finder step, which otherwise removes the icon and clears the flag.
cp "$ICNS" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"   # use .VolumeIcon.icns as the volume's icon

sync
hdiutil detach "$MOUNT" -quiet
rm -f "$DMG"
diskutil image create from --format UDZO "$RW" "$DMG" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

# Applied last; it's a Finder-side custom icon, so it shows on this Mac and
# isn't carried through uploads or zips.
swift "$HERE/scripts/set-file-icon.swift" "$ICNS" "$DMG"

echo "Built $DMG"
