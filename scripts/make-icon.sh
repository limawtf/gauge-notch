#!/bin/bash
# Gera Resources/AppIcon.icns a partir do icon-gen.swift (reproduzivel, sem deps externas).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> render master 1024"
swift scripts/icon-gen.swift "$TMP/icon-1024.png"

echo "==> montar iconset"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  px="${spec%% *}"; name="${spec##* }"
  sips -z "$px" "$px" "$TMP/icon-1024.png" --out "$ICONSET/icon_${name}.png" >/dev/null
done

echo "==> iconutil -> Resources/AppIcon.icns"
mkdir -p "$REPO_DIR/Resources"
iconutil -c icns "$ICONSET" -o "$REPO_DIR/Resources/AppIcon.icns"

echo "==> pronto: Resources/AppIcon.icns"
