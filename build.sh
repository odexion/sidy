#!/bin/zsh
# Builds Sidy.app (Apple silicon) into ./build.
#   --install  replace the installed copy (in /Applications, like the installer) and launch it
#   --release  also zip it as build/Sidy-<version>-arm64.zip
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.5.0
BUILD=11

swift build -c release --arch arm64 --product Sidy
swift build -c release --arch arm64 --product MediaBridge
BIN=$(swift build -c release --arch arm64 --show-bin-path)

APP=build/Sidy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Sidy" "$APP/Contents/MacOS/Sidy"
cp "$BIN/libMediaBridge.dylib" "$APP/Contents/Frameworks/"
cp Resources/Doto.ttf Resources/Doto-OFL.txt Resources/*.svg Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.odexion.sidy</string>
    <key>CFBundleName</key><string>Sidy</string>
    <key>CFBundleDisplayName</key><string>Sidy</string>
    <key>CFBundleExecutable</key><string>Sidy</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Odexion</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP/Contents/Frameworks/libMediaBridge.dylib"
codesign --force --sign - "$APP"
echo "Built $APP"

for arg in "$@"; do
    case "$arg" in
    --release)
        ZIP="build/Sidy-$VERSION-arm64.zip"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        echo "Packaged $ZIP"
        ;;
    --install)
        # Same place as scripts/install.sh, so this replaces the copy macOS actually launches.
        DEST=/Applications
        [ -w "$DEST" ] || DEST=~/Applications
        pkill -x Sidy || true
        mkdir -p "$DEST"
        rm -rf "$DEST/Sidy.app"
        cp -R "$APP" "$DEST/"
        open "$DEST/Sidy.app"
        echo "Installed to $DEST/Sidy.app"
        ;;
    esac
done
