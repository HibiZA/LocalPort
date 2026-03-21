#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="DevSpace"
APP_DIR="build/${APP_NAME}.app"
DMG_PATH="build/${APP_NAME}.dmg"
RUST_RELEASE="target/release"
SWIFT_RELEASE="macos/.build/release"

echo "=== Building DevSpace ==="

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

# Copy helper binaries
cp "$RUST_RELEASE/devspaced" "$APP_DIR/Contents/Helpers/"
cp "$RUST_RELEASE/devspace" "$APP_DIR/Contents/Helpers/"

# Copy Info.plist
cp macos/Resources/Info.plist "$APP_DIR/Contents/"

# Create minimal PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "  Built: $APP_DIR"

# 4. Create .dmg if requested
if [[ "${1:-}" == "--dmg" ]]; then
    echo "  Creating DMG..."
    rm -f "$DMG_PATH"

    # Create a temporary directory for DMG contents
    DMG_STAGING="build/dmg-staging"
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    cp -r "$APP_DIR" "$DMG_STAGING/"

    # Create a symlink to /Applications for drag-install
    ln -s /Applications "$DMG_STAGING/Applications"

    # Create DMG
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$DMG_STAGING" \
        -ov -format UDZO \
        "$DMG_PATH" \
        > /dev/null 2>&1

    rm -rf "$DMG_STAGING"
    echo "  Built: $DMG_PATH"
fi

echo ""
echo "  To install:"
echo "    cp -r $APP_DIR /Applications/"
echo ""
echo "  To install the CLI:"
echo "    ln -sf /Applications/DevSpace.app/Contents/Helpers/devspace /usr/local/bin/devspace"
