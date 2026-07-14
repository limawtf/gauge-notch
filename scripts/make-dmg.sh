#!/bin/bash
# Empacota Gauge.app num .dmg com atalho pra /Applications (drag-to-install).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

APP="Gauge.app"
[ -d "$APP" ] || bash scripts/make-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DIST="$REPO_DIR/dist"
mkdir -p "$DIST"
DMG="$DIST/Gauge-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create -volname "Gauge" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> pronto: $DMG"
du -h "$DMG" | cut -f1
