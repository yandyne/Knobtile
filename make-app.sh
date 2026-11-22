#!/bin/sh
# Builds a release binary and wraps it in a minimal .app bundle.
set -e
cd "$(dirname "$0")"
mkdir -p .build build # a fresh checkout has neither
# Universal (arm64 + x86_64) so Intel iMacs on macOS 14+ run the same bundle; artifacts land in .build/out/Products/Release
swift build -c release --arch arm64 --arch x86_64 > .build/make-app.log 2>&1 || { grep -m5 "error:" .build/make-app.log; echo "BUILD FAILED"; exit 1; } # a pipe to tail hid compile errors and shipped the old binary
tail -1 .build/make-app.log
OUT=.build/out/Products/Release
APP=build/Knobtile.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$OUT/Knobtile" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources"
cp -R "$OUT/Knobtile_Engine.bundle" "$APP/Contents/Resources/" # the bundled plugins (Bundle.module)
[ -f build/AppIcon.icns ] || { swift make-icon.swift build/icon.iconset && iconutil -c icns build/icon.iconset -o build/AppIcon.icns; }
cp build/AppIcon.icns "$APP/Contents/Resources/"
cp -R Localization/*.lproj "$APP/Contents/Resources/" # ko (the text in the source) and en; see Sources/Engine/Localize.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Knobtile</string>
<key>CFBundleIdentifier</key><string>io.github.yandyne.knobtile</string>
<key>CFBundleName</key><string>Knobtile</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>ko</string><string>en</string></array>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>LSUIElement</key><false/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>A Knobtile plugin controls this app with AppleScript.</string>
</dict></plist>
PLIST
# A stable identity keeps the Accessibility grant across rebuilds (ad-hoc signatures change every build and TCC forgets the app).
ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
# "./make-app.sh dist": the build to hand out. Ad hoc, because a personal certificate would put its owner's Apple ID into every copy.
[ "$1" = dist ] && ID=-
# The debug symbols name every source file by its full path on the build machine: a build to hand out goes without them.
if [ "$1" = dist ]; then
  strip -S -x "$APP/Contents/MacOS/Knobtile" 2>/dev/null
  if LC_ALL=C grep -aq "$(pwd)" "$APP/Contents/MacOS/Knobtile"; then echo "DIST FAILED: the binary still names this folder"; exit 1; fi
fi
codesign --force --sign "${ID:--}" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1 || true
if [ "$1" = dist ]; then
  V=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
  rm -f "build/Knobtile-$V.zip"; ditto -c -k --keepParent "$APP" "build/Knobtile-$V.zip"; echo "packed build/Knobtile-$V.zip"
fi
echo "built $APP"
