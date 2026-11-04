#!/usr/bin/env bash
# Publica una versión nueva: sube la versión, compila instaladores, actualiza la web, hace commit/push y crea la release en GitHub.
#   scripts/release.sh <version> "notas de la versión"
# Requiere el token de GitHub en ~/.shelldock_gh_token (permiso repo) y tests en verde.
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${1:?uso: scripts/release.sh <version> \"notas\"}"; NOTES="${2:-Release $VER}"
REPO="loiro85/ShellDock"; TOKEN_FILE="$HOME/.shelldock_gh_token"
[ -f "$TOKEN_FILE" ] || { echo "Falta $TOKEN_FILE"; exit 1; }
TOKEN=$(tr -d '\n\r ' < "$TOKEN_FILE")
git diff --quiet HEAD -- 2>/dev/null || true
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1 | grep -q "0 failures" || { echo "Los tests fallan"; exit 1; }
echo "$VER" > VERSION
scripts/make_installer.sh --universal
# enlaces estáticos de la web (la web además consulta la última release al cargar)
sed -i '' -E "s#ShellDock-[0-9][0-9.]*\.(dmg|pkg)#ShellDock-$VER.\1#g; s#(<span data-ver>)[0-9][0-9.]*(</span>)#\1$VER\2#g" docs/index.html
git add -A
git commit -qm "Release $VER" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>" || true
git tag -f "v$VER" >/dev/null
AUTH=$(printf "x-access-token:%s" "$TOKEN" | base64)
git -c http.extraheader="Authorization: Basic $AUTH" push origin main
git -c http.extraheader="Authorization: Basic $AUTH" push -f origin "v$VER"
BODY=$(python3 -c 'import json,sys;print(json.dumps({"tag_name":"v"+sys.argv[1],"name":"ShellDock "+sys.argv[1],"body":sys.argv[2],"make_latest":"true"}))' "$VER" "$NOTES")
RESP=$(curl -s -H "Authorization: Bearer $TOKEN" -X POST "https://api.github.com/repos/$REPO/releases" -d "$BODY")
ID=$(printf '%s' "$RESP" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read(),strict=False)["id"])')
for f in "dist/ShellDock-$VER.dmg" "dist/ShellDock-$VER.pkg"; do
  curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/octet-stream" --data-binary @"$f" \
       "https://uploads.github.com/repos/$REPO/releases/$ID/assets?name=$(basename "$f")"
done
echo "Publicado: https://github.com/$REPO/releases/tag/v$VER  ·  web: https://loiro85.github.io/ShellDock/"
