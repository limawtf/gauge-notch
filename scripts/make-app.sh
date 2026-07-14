#!/bin/bash
# Monta "Gauge.app" a partir do build release do SwiftPM.
# (binario interno segue ClaudeNotch; nome de produto = Gauge)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

echo "==> swift build -c release"
swift build -c release

APP_NAME="Gauge.app"
BUILD_DIR="$REPO_DIR/.build/release"
BIN_NAME="ClaudeNotch"
APP_DIR="$REPO_DIR/$APP_NAME"

echo "==> montando $APP_NAME"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$BIN_NAME" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp "$REPO_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$REPO_DIR/Resources/AppIcon.icns" ]; then
  cp "$REPO_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP_DIR"

echo "==> pronto: $APP_DIR"
