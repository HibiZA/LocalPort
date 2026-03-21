#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="DevSpace"
APP_DIR="build/${APP_NAME}.app"
RUST_RELEASE="target/release"
SWIFT_RELEASE="macos/.build/release"

echo "=== Building DevSpace ==="

# 1. Build Rust binaries
echo "  Building Rust (daemon + CLI)..."
cargo build --release --quiet

# 2. Build Swift app
echo "  Building Swift (macOS app)..."
(cd macos && swift build -c release --quiet)

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

echo ""
echo "  Built: $APP_DIR"
echo ""
echo "  To install:"
echo "    cp -r $APP_DIR /Applications/"
echo ""
echo "  To install the CLI:"
echo "    ln -sf /Applications/DevSpace.app/Contents/Helpers/devspace /usr/local/bin/devspace"
