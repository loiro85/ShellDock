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

# ---------- DMG: ventana con la app, el acceso directo a Aplicaciones y una flecha "arrastra aquí" ----------
mkdir -p "$STAGE/dmg/.background"
ditto --noextattr --noqtn "$APP" "$STAGE/dmg/ShellDock.app"
ln -s /Applications "$STAGE/dmg/Applications"
tiffutil -cathidpicheck scripts/dmg/background.png scripts/dmg/background@2x.png -out "$STAGE/dmg/.background/background.tiff" 2>/dev/null
cp scripts/AppIcon.icns "$STAGE/dmg/.VolumeIcon.icns"
DMG="dist/ShellDock-$VER.dmg"; rm -f "$DMG"
RW="$STAGE/rw.dmg"; VOL="ShellDock $VER"
hdiutil create -volname "$VOL" -srcfolder "$STAGE/dmg" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MNT=$(hdiutil attach "$RW" -noautoopen -readwrite | sed -n 's#.*\(/Volumes/.*\)#\1#p' | head -1)
SetFile -a C "$MNT" 2>/dev/null || true
# posiciones de los iconos y fondo (si Finder no responde, el .dmg sigue funcionando, solo sin la maqueta)
osascript <<OSA >/dev/null || echo "AVISO: no se pudo maquetar la ventana del .dmg (permiso de Automatización de Finder)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 112
    set text size of vo to 13
    set background picture of vo to file ".background:background.tiff"
    set position of item "ShellDock.app" of container window to {170, 200}
    set position of item "Applications" of container window to {490, 200}
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
sync; sleep 1
hdiutil detach "$MNT" >/dev/null || { sleep 2; hdiutil detach -force "$MNT" >/dev/null; }
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
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
