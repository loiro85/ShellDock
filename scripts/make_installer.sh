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

# ---------- DMG: ventana con la app y el acceso directo a Aplicaciones ----------
mkdir -p "$STAGE/dmg"
ditto --noextattr --noqtn "$APP" "$STAGE/dmg/ShellDock.app"
ln -s /Applications "$STAGE/dmg/Applications"
cp scripts/AppIcon.icns "$STAGE/dmg/.VolumeIcon.icns"; SetFile -a C "$STAGE/dmg" 2>/dev/null || true
DMG="dist/ShellDock-$VER.dmg"; rm -f "$DMG"
hdiutil create -volname "ShellDock $VER" -srcfolder "$STAGE/dmg" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
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
