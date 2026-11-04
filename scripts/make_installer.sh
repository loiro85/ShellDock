#!/usr/bin/env bash
# Genera los instaladores de ShellDock: dist/ShellDock-<versión>.dmg (arrastrar a Aplicaciones) y .pkg (asistente).
#
#   scripts/make_installer.sh [--universal]
#
# Firma (opcional, para distribuir fuera de este Mac):
#   SIGN_IDENTITY="Developer ID Application: Tu Nombre (TEAMID)"      firma la app y el .dmg
#   INSTALLER_IDENTITY="Developer ID Installer: Tu Nombre (TEAMID)"   firma el .pkg
#   NOTARY_PROFILE="mi-perfil"   (xcrun notarytool store-credentials) notariza y grapa el .dmg y el .pkg
set -euo pipefail
cd "$(dirname "$0")/.."
VER=$(cat VERSION 2>/dev/null || echo 0.1.0)
ID="com.oriolbarrientos.shelldock"

scripts/build_app.sh "$@"
APP="dist/ShellDock.app"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

# ---------- DMG: ventana con la app, el acceso directo a Aplicaciones, título y flecha (dmgbuild: sin Finder ni permisos) ----------
for v in "/Volumes/ShellDock $VER"*; do [ -d "$v" ] && hdiutil detach "$v" -force >/dev/null 2>&1; done
DMG="dist/ShellDock-$VER.dmg"; rm -f "$DMG"
DMGBUILD="${DMGBUILD:-}"
[ -z "$DMGBUILD" ] && command -v dmgbuild >/dev/null && DMGBUILD=$(command -v dmgbuild)
if [ -z "$DMGBUILD" ]; then
  python3 -m venv "$STAGE/venv" && "$STAGE/venv/bin/pip" install -q dmgbuild && DMGBUILD="$STAGE/venv/bin/dmgbuild"
fi
ditto --noextattr --noqtn "$APP" "$STAGE/ShellDock.app"
for try in 1 2 3; do      # a veces el volumen sigue ocupado (Spotlight/Finder) al reducir la imagen: se reintenta
  DMG_APP="$STAGE/ShellDock.app" DMG_ROOT="$PWD" "$DMGBUILD" -s scripts/dmg/settings.py "ShellDock $VER" "$DMG" >/dev/null 2>&1 && break
  for v in "/Volumes/ShellDock $VER"*; do [ -d "$v" ] && hdiutil detach "$v" -force >/dev/null 2>&1; done
  rm -f "$DMG"; sleep 3
done
[ -f "$DMG" ] || { echo "ERROR: no se pudo crear el .dmg"; exit 1; }
[ -n "${SIGN_IDENTITY:-}" ] && codesign --force --sign "$SIGN_IDENTITY" "$DMG"
echo "DMG: $DMG"

# ---------- PKG: instalador con asistente que copia la app a /Applications ----------
mkdir -p "$STAGE/root/Applications"
ditto --noextattr --noqtn "$APP" "$STAGE/root/Applications/ShellDock.app"
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$STAGE/components.plist"      # siempre en /Applications
pkgbuild --root "$STAGE/root" --component-plist "$STAGE/components.plist" --identifier "$ID" --version "$VER" \
         --install-location / "$STAGE/ShellDock-component.pkg" >/dev/null
cat > "$STAGE/welcome.html" <<HTML
<html><body style="font-family:-apple-system;font-size:13px">
<h2>ShellDock $VER</h2>
<p>Terminal, SSH/SFTP, VNC, Mini Linux y herramientas de administración para macOS.</p>
<p>Se instalará en <b>/Applications</b>.</p></body></html>
HTML
cat > "$STAGE/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>ShellDock</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_anywhere="false" enable_localSystem="true" enable_currentUserHome="false"/>
  <volume-check><allowed-os-versions><os-version min="13.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="default"><line choice="$ID"/></line></choices-outline>
  <choice id="default"/>
  <choice id="$ID" visible="false"><pkg-ref id="$ID"/></choice>
  <pkg-ref id="$ID" version="$VER" onConclusion="none">ShellDock-component.pkg</pkg-ref>
</installer-gui-script>
XML
PKG="dist/ShellDock-$VER.pkg"; rm -f "$PKG"
SIGN=(); [ -n "${INSTALLER_IDENTITY:-}" ] && SIGN=(--sign "$INSTALLER_IDENTITY")
productbuild --distribution "$STAGE/distribution.xml" --resources "$STAGE" --package-path "$STAGE" ${SIGN[@]+"${SIGN[@]}"} "$PKG" >/dev/null
echo "PKG: $PKG"

# ---------- Notarización (solo con credenciales de Apple Developer) ----------
if [ -n "${NOTARY_PROFILE:-}" ]; then
  for f in "$DMG" "$PKG"; do
    xcrun notarytool submit "$f" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$f"
  done
fi
ls -lh "$DMG" "$PKG"
