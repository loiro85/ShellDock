#!/usr/bin/env bash
# Empaqueta ShellDock.app (universal si se pasa --universal). Uso: scripts/build_app.sh [--release] [--universal]
set -euo pipefail
cd "$(dirname "$0")/.."
CONF=debug; ARCHS=()
for a in "$@"; do
  [ "$a" = "--release" ] && CONF=release
  [ "$a" = "--universal" ] && ARCHS=(--arch arm64 --arch x86_64)
done
swift build -c "$CONF" ${ARCHS[@]+"${ARCHS[@]}"} 2>&1 | grep -E "error:|Build complete" | sed -E 's/\x1b\[[0-9;]*m//g' || true
BIN="$(swift build -c "$CONF" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/ShellDock"
FINAL="dist/ShellDock.app"
# se firma en un directorio fuera de carpetas sincronizadas (iCloud/File Provider añade xattrs que invalidan la firma)
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
APP="$WORK/ShellDock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ShellDock"
[ -f scripts/AppIcon.icns ] && cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
VER=$(cat VERSION 2>/dev/null || echo 0.1.0)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ShellDock</string>
  <key>CFBundleDisplayName</key><string>ShellDock</string>
  <key>CFBundleIdentifier</key><string>com.oriolbarrientos.shelldock</string>
  <key>CFBundleExecutable</key><string>ShellDock</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSLocalNetworkUsageDescription</key><string>ShellDock se conecta a servidores de tu red local.</string>
  <key>NSAppleEventsUsageDescription</key><string>ShellDock pide contraseñas con un diálogo del sistema.</string>
  <key>CFBundleURLTypes</key><array>
    <dict><key>CFBundleURLName</key><string>SSH</string><key>CFBundleURLSchemes</key><array><string>ssh</string><string>telnet</string></array></dict>
  </array>
</dict></plist>
PLIST
pkill -f "ShellDock.app/Contents/MacOS" 2>/dev/null || true
xattr -cr "$APP"
codesign --force --sign "${SIGN_IDENTITY:--}" --entitlements scripts/Entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2>&1 | grep -q "com.apple.security.virtualization" || { echo "ERROR: falta el entitlement de virtualización"; exit 1; }
echo "OK → $APP"
rm -rf "$FINAL"; mkdir -p dist; ditto --noextattr --noqtn "$APP" "$FINAL"
xattr -cr "$FINAL" 2>/dev/null || true
echo "App: $FINAL"
