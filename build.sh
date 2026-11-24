#!/bin/bash
# Builds build/Equalizer.app and build/Equalizer.dmg (runs on macOS, e.g. GitHub Actions).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Equalizer.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -parse-as-library \
    -target "$ARCH-apple-macos14.2" \
    Sources/*.swift -o "build/Equalizer-$ARCH"
done
lipo -create build/Equalizer-arm64 build/Equalizer-x86_64 -output "$APP/Contents/MacOS/Equalizer"
cp Info.plist "$APP/Contents/Info.plist"

# App icon from icon.png (optional)
if [ -f icon.png ]; then
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  for S in 16 32 128 256 512; do
    sips -z $S $S icon.png --out "$ICONSET/icon_${S}x${S}.png" >/dev/null
    D=$((S * 2))
    sips -z $D $D icon.png --out "$ICONSET/icon_${S}x${S}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "icon skipped"
fi

# Ad-hoc signature (required to run on Apple Silicon)
codesign --force --deep --sign - "$APP"

# Disk image with a shortcut to Applications for drag-and-drop install
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Equalizer" -srcfolder build/dmg -ov -format UDZO build/Equalizer.dmg

echo "Done: build/Equalizer.dmg"
