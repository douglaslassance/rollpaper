#!/usr/bin/env bash
# Build Rollpaper in release mode, bundle it as Rollpaper.app, install to
# /Applications, and (optionally) launch it.
#
# Usage:
#   scripts/install.sh            # build + install
#   scripts/install.sh --launch   # build + install + launch

set -euo pipefail

APP_NAME="Rollpaper"
BUNDLE_ID="me.douglaslassance.Rollpaper"
INSTALL_DIR="/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"

cd "$(dirname "$0")/.."

echo "==> Building release"
swift build -c release

BIN_SRC=".build/release/$APP_NAME"
if [[ ! -x "$BIN_SRC" ]]; then
    echo "Build output not found: $BIN_SRC" >&2
    exit 1
fi

VERSION="$(git describe --tags --always 2>/dev/null || echo 0.0.0)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Stopping any running instance"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3

echo "==> Staging app bundle"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_SRC" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

ICON_SRC="assets/Rollpaper.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP/Contents/Resources/Rollpaper.icns"
else
    echo "Warning: $ICON_SRC missing; run scripts/make-icon.swift to regenerate" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>Rollpaper</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesigning"
codesign --force --sign - "$APP"

echo "==> Installing to $APP_PATH"
if [[ -d "$APP_PATH" ]]; then
    rm -rf "$APP_PATH"
fi
mv "$APP" "$APP_PATH"

echo "==> Installed $APP_PATH (version $VERSION, build $BUILD_NUMBER)"

if [[ "${1:-}" == "--launch" ]]; then
    echo "==> Launching"
    open "$APP_PATH"
fi
