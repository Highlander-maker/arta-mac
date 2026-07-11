#!/bin/bash
# Builds ArtaApp in release mode and wraps it into build/Arta.app so macOS
# treats it as a real application (own microphone permission, Dock icon,
# double-clickable). Ad-hoc signed so TCC grants stick between rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product ArtaApp

APP=build/Arta.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/ArtaApp "$APP/Contents/MacOS/Arta"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Arta</string>
    <key>CFBundleIdentifier</key>
    <string>com.highlanderaudio.arta</string>
    <key>CFBundleName</key>
    <string>Arta</string>
    <key>CFBundleDisplayName</key>
    <string>Arta</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Arta records the measurement input while playing the excitation signal. Without microphone access no measurement is possible.</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"

echo ""
echo "Built $APP"
echo "Launch with:  open $APP"
