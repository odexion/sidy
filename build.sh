#!/bin/zsh
# Builds Sidy.app into ./build. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Sidy
swift build -c release --product MediaBridge
APP=build/Sidy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Sidy "$APP/Contents/MacOS/Sidy"
cp .build/release/libMediaBridge.dylib "$APP/Contents/Frameworks/"
cp Resources/Doto.ttf Resources/*.svg "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.zaf4.sidy</string>
    <key>CFBundleName</key><string>Sidy</string>
    <key>CFBundleExecutable</key><string>Sidy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP/Contents/Frameworks/libMediaBridge.dylib"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Sidy || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Sidy.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Sidy.app
    echo "Installed to ~/Applications/Sidy.app"
fi
