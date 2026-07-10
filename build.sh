#!/bin/bash
# DockToggle'ı derler, .app paketine koyar ve SABİT sertifikayla imzalar.
# Sabit imza sayesinde Erişilebilirlik izni her yeniden derlemede korunur.
set -e

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPDIR="$HOME/Applications"
APP="$APPDIR/DockToggle.app"
KC="$HOME/Library/Keychains/docktoggle-signing.keychain-db"
CERT="DockToggle Self-Signed"

echo "== Derleniyor =="
swiftc -O -swift-version 5 "$SRC/main.swift" -o "$SRC/DockToggle" \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement

echo "== .app paketi oluşturuluyor =="
mkdir -p "$APPDIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/DockToggle" "$APP/Contents/MacOS/DockToggle"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$SRC/AppIcon.icns" ]; then
    cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/DockToggle"

echo "== Sabit sertifikayla imzalanıyor =="
# Özel keychain arama listesinde değilse, mevcutleri koruyarak ekle (codesign'ın kimliği bulması için)
EXISTING=$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')
if ! echo "$EXISTING" | grep -q "docktoggle-signing"; then
  security list-keychains -d user -s "$KC" $EXISTING
fi
security unlock-keychain -p docktoggle "$KC" >/dev/null 2>&1 || true
codesign --force --deep --sign "$CERT" "$APP"

echo "== Designated requirement (cdhash yerine sertifika kimliği olmalı) =="
codesign -d -r- "$APP" 2>&1 | tail -3
echo "OK: $APP"
