#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="LocalPort"
APP_DIR="build/${APP_NAME}.app"
DMG_PATH="build/${APP_NAME}.dmg"
RUST_RELEASE="target/release"
SWIFT_RELEASE="macos/.build/release"

# Derive version from latest git tag (e.g. v0.1.4 -> 0.1.4)
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0")

echo "=== Building LocalPort ==="

# 1. Build Rust binaries
echo "  Building Rust (daemon + CLI)..."
cargo build --release --quiet

# 2. Build Swift app
echo "  Building Swift (macOS app)..."
(cd macos && swift build -c release --quiet 2>&1 | grep -v "warning:" || true)

# 3. Assemble .app bundle
echo "  Assembling app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Helpers"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy main executable
cp "$SWIFT_RELEASE/$APP_NAME" "$APP_DIR/Contents/MacOS/"

# Copy daemon binary
cp "$RUST_RELEASE/localportd" "$APP_DIR/Contents/Helpers/"

# Copy Info.plist and stamp version from git tag
cp macos/Resources/Info.plist "$APP_DIR/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_DIR/Contents/Info.plist"
echo "  Version: $VERSION"
cp scripts/setup.sh "$APP_DIR/Contents/Resources/" 2>/dev/null || true
cp scripts/uninstall.sh "$APP_DIR/Contents/Resources/" 2>/dev/null || true
cp macos/Resources/AppIcon.icns "$APP_DIR/Contents/Resources/" 2>/dev/null || true
cp macos/Resources/MenuBarIcon.png "$APP_DIR/Contents/Resources/" 2>/dev/null || true
cp macos/Resources/MenuBarIcon@2x.png "$APP_DIR/Contents/Resources/" 2>/dev/null || true

# Create minimal PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# 4. Ad-hoc code sign (removes "damaged" Gatekeeper error)
echo "  Signing..."
codesign --force --deep --sign - "$APP_DIR/Contents/Helpers/localportd"
codesign --force --deep --sign - "$APP_DIR"

echo "  Built: $APP_DIR"

# 4. Create .dmg if requested
if [[ "${1:-}" == "--dmg" ]]; then
    echo "  Creating DMG..."
    rm -f "$DMG_PATH"

    DMG_STAGING="build/dmg-staging"
    DMG_TMP="build/${APP_NAME}-tmp.dmg"
    VOL_NAME="$APP_NAME"
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    cp -r "$APP_DIR" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"

    # Create a read-write DMG first so we can style it
    hdiutil create -volname "$VOL_NAME" \
        -srcfolder "$DMG_STAGING" \
        -ov -format UDRW \
        "$DMG_TMP" \
        > /dev/null 2>&1

    # Mount it
    MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_TMP" | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')

    # Use AppleScript to style the Finder window
    osascript <<APPLESCRIPT
    tell application "Finder"
        tell disk "$VOL_NAME"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {200, 200, 720, 500}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set text size of viewOptions to 13
            set position of item "$APP_NAME.app" of container window to {140, 140}
            set position of item "Applications" of container window to {380, 140}
            close
            open
            update without registering applications
            delay 1
            close
        end tell
    end tell
APPLESCRIPT

    # Unmount
    hdiutil detach "$MOUNT_DIR" > /dev/null 2>&1 || true
    sleep 1

    # Convert to compressed read-only DMG
    hdiutil convert "$DMG_TMP" -format UDZO -o "$DMG_PATH" > /dev/null 2>&1
    rm -f "$DMG_TMP"
    rm -rf "$DMG_STAGING"

    echo "  Built: $DMG_PATH"
fi

echo ""
echo "  To install:"
echo "    cp -r $APP_DIR /Applications/"
