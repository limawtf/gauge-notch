#!/bin/bash
# Publica uma release do Gauge no canal de auto-update.
#
# A VERSAO VEM DO Info.plist (CFBundleShortVersionString): bump ela ANTES de rodar este
# script (nao ha bump automatico aqui).
#
# O que este script faz, em ordem:
#   1. le a versao de Resources/Info.plist
#   2. gera o .dmg via scripts/make-dmg.sh (dist/Gauge-<versao>.dmg)
#   3. calcula o sha256 do .dmg
#   4. cria/atualiza o GitHub Release "v<versao>" no repo PUBLICO limawtf/gauge-notch,
#      com o .dmg como asset (via `gh`, autenticado por GH_TOKEN)
#   5. gera latest.json ({version, notes, dmg, sha256, minMacOS}) e commita+pusha ele no
#      repo publico (clone/update numa pasta tmp)
#
# Contrato com o app (Sources/ClaudeNotch/Data/UpdateChecker.swift):
#   manifesto em https://raw.githubusercontent.com/limawtf/gauge-notch/main/latest.json
#   {"version":"X.Y.Z","notes":"...","dmg":"<url https>","sha256":"<hex 64>","minMacOS":"13.0"}
#
# Requer:
#   - GH_TOKEN no ambiente (permissao de push no repo publico + criar release)
#   - `gh` (GitHub CLI) instalado
#
# Uso:
#   GH_TOKEN=... scripts/publish-release.sh ["notas da release"]
# Sem notas, usa uma mensagem generica (padrao do projeto: nunca vaza detalhe de feature
# nas notas publicas).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

RELEASES_REPO="limawtf/gauge-notch"
MIN_MACOS="13.0"
NOTES="${1:-Melhorias de performance, estabilidade e correcoes de bugs.}"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "erro: GH_TOKEN nao setado no ambiente" >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "erro: gh (GitHub CLI) nao encontrado no PATH" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_DIR/Resources/Info.plist")"
TAG="v$VERSION"
echo "==> versao (Info.plist): $VERSION"

echo "==> scripts/make-dmg.sh"
bash "$REPO_DIR/scripts/make-dmg.sh"

DMG="$REPO_DIR/dist/Gauge-$VERSION.dmg"
[ -f "$DMG" ] || { echo "erro: dmg nao foi gerado em $DMG" >&2; exit 1; }
DMG_NAME="$(basename "$DMG")"

echo "==> sha256"
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$SHA256"

echo "==> release $TAG em $RELEASES_REPO"
if GH_TOKEN="$GH_TOKEN" gh release view "$TAG" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  echo "    ja existe, atualizando asset + notas"
  GH_TOKEN="$GH_TOKEN" gh release upload "$TAG" "$DMG" --repo "$RELEASES_REPO" --clobber
  GH_TOKEN="$GH_TOKEN" gh release edit "$TAG" --repo "$RELEASES_REPO" --notes "$NOTES"
else
  GH_TOKEN="$GH_TOKEN" gh release create "$TAG" "$DMG" \
    --repo "$RELEASES_REPO" --title "$TAG" --notes "$NOTES"
fi

DMG_URL="https://github.com/$RELEASES_REPO/releases/download/$TAG/$DMG_NAME"
echo "==> asset: $DMG_URL"

echo "==> atualizando latest.json no repo publico"
CLONE_DIR="$(mktemp -d)"
trap 'rm -rf "$CLONE_DIR"' EXIT
git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/${RELEASES_REPO}.git" "$CLONE_DIR" >/dev/null 2>&1

# JSON escrito com printf (sem depender de jq): campos vem so daqui, nunca de dado externo.
cat > "$CLONE_DIR/latest.json" <<JSON
{
  "version": "$VERSION",
  "notes": "$NOTES",
  "dmg": "$DMG_URL",
  "sha256": "$SHA256",
  "minMacOS": "$MIN_MACOS"
}
JSON

cd "$CLONE_DIR"
if git diff --quiet -- latest.json 2>/dev/null && git ls-files --error-unmatch latest.json >/dev/null 2>&1; then
  echo "    latest.json sem mudanca, nada pra commitar"
else
  git add latest.json
  git -c user.name="gauge-release-bot" -c user.email="gauge-release-bot@users.noreply.github.com" -c user.commit.gpgsign=false \
    commit -m "release: v$VERSION"
  git push origin HEAD
fi
cd "$REPO_DIR"

echo "==> pronto: $TAG publicado, latest.json aponta pra $VERSION"
