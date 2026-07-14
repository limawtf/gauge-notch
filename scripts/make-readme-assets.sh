#!/bin/bash
# Regenera TODOS os assets do README a partir do build release (dados mock, sem nada pessoal).
# Requer: swift toolchain + ffmpeg.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
BIN=".build/release/ClaudeNotch"
OUT="docs/assets"
mkdir -p "$OUT"

echo "==> swift build -c release"
swift build -c release >/dev/null

echo "==> screenshots (fixtures mock)"
"$BIN" --snapshot "$OUT/uso.png"           --state ok      --appearance dark >/dev/null
"$BIN" --snapshot "$OUT/uso-opus.png"      --state opus    --appearance dark >/dev/null
"$BIN" --snapshot "$OUT/consumo.png"       --state agents  --appearance dark >/dev/null
"$BIN" --snapshot "$OUT/notch-compact.png" --state compact --appearance dark >/dev/null

echo "==> banner"
swift scripts/make-readme-assets.swift banner Resources/AppIcon.icns "$OUT/banner.png" >/dev/null

echo "==> gif (frames alta-res -> ffmpeg palettegen/paletteuse)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swift scripts/make-readme-assets.swift frames "$TMP" \
    "$OUT/uso.png" "$OUT/uso-opus.png" "$OUT/consumo.png" >/dev/null
ffmpeg -y -framerate 12 -i "$TMP/frame_%04d.png" \
    -vf "scale=460:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=3" \
    -loop 0 "$OUT/demo.gif" -hide_banner -loglevel error

echo "==> pronto:"
ls -la "$OUT"
