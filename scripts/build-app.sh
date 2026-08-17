#!/bin/bash
# Builds HASocketMenuBar in release mode and packages it as a proper .app
# bundle (with LSUIElement set, so it never shows a Dock icon) at
# build/HASocketMenuBar.app. That bundle is what you drag into
# /Applications and add as a Login Item.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="HASocketMenuBar"
BUNDLE_ID="com.paxtonwilloughby.hasocket.menubar"
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/$APP_NAME.app"
ICON_NAME="HASocket-Icon"
ICON_SRC="$ROOT/$ICON_NAME.icon"

echo "Building $APP_NAME and hasocket CLI (release)..."
swift build -c release --product "$APP_NAME"
swift build -c release --product hasocket
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# Bundle the hasocket CLI alongside the app executable so the app can offer
# to symlink it into ~/.local/bin (see MenuBarContentView's "Install CLI"
# button / CLIInstaller.swift) - no separate CLI build/install step needed.
cp "$BIN_DIR/hasocket" "$APP/Contents/MacOS/hasocket"
chmod +x "$APP/Contents/MacOS/hasocket"

echo "Compiling app icon..."
xcrun actool --output-format human-readable-text --notices --warnings \
    --platform macosx --minimum-deployment-target 13.0 \
    --app-icon "$ICON_NAME" \
    --compile "$APP/Contents/Resources" \
    --output-partial-info-plist "$OUT_DIR/icon-partial-info.plist" \
    "$ICON_SRC" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>hasocket</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$ICON_NAME</string>
    <key>CFBundleIconName</key>
    <string>$ICON_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

xattr -rc "$APP"

echo "Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo
echo "Next steps:"
echo "  1. mv \"$APP\" /Applications/"
echo "  2. Open it once from /Applications (or System Settings prompts on first Local Network use)"
echo "  3. System Settings > General > Login Items & Extensions > add HASocketMenuBar"
