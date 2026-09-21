#!/bin/bash
# DockToggle'ı derler, .app paketine koyar ve SABİT sertifikayla imzalar.
# Sabit imza sayesinde Erişilebilirlik izni her yeniden derlemede korunur.
set -e

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPDIR="/Applications"
APP="$APPDIR/DockToggle.app"
USER_APP="$HOME/Applications/DockToggle.app"
KC="$HOME/Library/Keychains/docktoggle-signing.keychain-db"
CERT="DockToggle Self-Signed"

echo "== Derleniyor =="
swiftc -O -swift-version 6 "$SRC"/*.swift -o "$SRC/DockToggle" \
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
# Keychain parolası: ortam değişkeni, yoksa make-cert.sh'in ürettiği .signing/keychain-pass.
KCPASS="${DOCKTOGGLE_KEYCHAIN_PASS:-}"
if [ -z "$KCPASS" ] && [ -f "$SRC/.signing/keychain-pass" ]; then
  KCPASS=$(cat "$SRC/.signing/keychain-pass")
fi
if [ -n "$KCPASS" ]; then
  security unlock-keychain -p "$KCPASS" "$KC" >/dev/null 2>&1 || true
else
  # Parola bilinmiyorsa kullanıcıdan iste (Keychain Access diyaloğu çıkar).
  security unlock-keychain "$KC" >/dev/null 2>&1 || true
fi
# --options runtime: yerel derleme de dağıtılan artefaktla aynı sertleştirmeyi taşısın,
# böylece "bende çalışıyordu" farkı oluşmaz (release.sh zaten bunu yapıyor).
# --deep kullanılmaz: Apple bunu önermiyor, iç bileşenler içten dışa ayrı imzalanmalı.
# Bu pakette gömülü framework/helper yok, tek Mach-O var.
codesign --force --options runtime --sign "$CERT" "$APP"
codesign --verify --strict "$APP" || { echo "İMZA DOĞRULAMASI BAŞARISIZ"; exit 1; }

echo "== Designated requirement (cdhash yerine sertifika kimliği olmalı) =="
codesign -d -r- "$APP" 2>&1 | tail -3

mkdir -p "$HOME/Applications"
rm -rf "$USER_APP"
cp -R "$APP" "$USER_APP"

echo "OK: $APP ve $USER_APP güncellendi"
