#!/bin/sh
# Builds build/Lemon.app (arm64, sandboxed, ad-hoc signed for local use).
set -eu
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)
APP=build/Lemon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# SwiftPM records the deployment target as the SDK version; AppKit then keeps native controls in their
# pre-26 look. Stamp the real SDK so sliders, segmented controls and menus get Liquid Glass.
xcrun vtool -set-build-version macos 14.0 "$(xcrun --sdk macosx --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/Lemon" "$BIN/Lemon"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Bundled helper (scripts/build-ffmpeg.sh); runs inside Lemon's sandbox.
if [ -x Support/bin/ffmpeg ]; then
  cp Support/bin/ffmpeg "$APP/Contents/MacOS/ffmpeg"
  cp -R Support/licenses "$APP/Contents/Resources/Licenses"
  codesign --force --sign - --options runtime --entitlements Support/ffmpeg.entitlements "$APP/Contents/MacOS/ffmpeg"
else
  echo "warning: Support/bin/ffmpeg missing; run scripts/build-ffmpeg.sh" >&2
fi
codesign --force --sign - --options runtime --entitlements Support/Lemon.entitlements "$APP"
echo "$APP"
