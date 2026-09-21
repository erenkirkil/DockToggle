#!/bin/bash
set -e

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="DockToggle"
SIGN_ID="Developer ID Application: EREN KIRKIL (992XYS9346)"
NOTARY_PROFILE="DOCKTOGGLE_PROFILE" # Kullanıcı bunu ayarlamış olmalı
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$SRC/Info.plist" 2>/dev/null || echo "1.1.0")
TAG="v$VERSION"
DMG_NAME="$SRC/${APP_NAME}_Release.dmg"

echo "== Sürüm: $VERSION ($TAG) =="

echo "1. Uygulama derleniyor..."
swiftc -O -swift-version 6 "$SRC"/*.swift -o "$SRC/DockToggle" \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement

echo "2. .app paketi oluşturuluyor..."
rm -rf "/tmp/${APP_NAME}_Release"
mkdir -p "/tmp/${APP_NAME}_Release"
APP_PATH="/tmp/${APP_NAME}_Release/${APP_NAME}.app"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$SRC/DockToggle" "$APP_PATH/Contents/MacOS/DockToggle"
cp "$SRC/Info.plist" "$APP_PATH/Contents/Info.plist"
if [ -f "$SRC/AppIcon.icns" ]; then
    cp "$SRC/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP_PATH/Contents/MacOS/DockToggle"

echo "3. Uygulama imzalanıyor (.app)..."
# Notarization için --options runtime parametresi zorunludur
codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$APP_PATH"
codesign --verify --strict "$APP_PATH" || { echo "İMZA DOĞRULAMASI BAŞARISIZ — dağıtım durduruldu"; exit 1; }

echo "4. DMG oluşturuluyor..."
rm -f "$DMG_NAME"
ln -s /Applications "/tmp/${APP_NAME}_Release/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "/tmp/${APP_NAME}_Release" -ov -format UDZO "$DMG_NAME"

echo "5. DMG dosyası imzalanıyor..."
codesign --force --sign "$SIGN_ID" --timestamp "$DMG_NAME"

echo "6. Apple'a Notarization için gönderiliyor (Bu işlem birkaç dakika sürebilir)..."
# Bu adımın çalışması için kullanıcının parolayı DOCKTOGGLE_PROFILE adıyla kaydetmiş olması gerekir.
xcrun notarytool submit "$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait

echo "7. Onay bileti (Ticket) DMG dosyasına iliştiriliyor (Staple)..."
xcrun stapler staple "$DMG_NAME"

echo "8. GitHub Release oluşturuluyor..."
if command -v gh >/dev/null 2>&1; then
    if gh release view "$TAG" >/dev/null 2>&1; then
        echo "Release $TAG zaten mevcut, DMG güncelleniyor..."
        gh release upload "$TAG" "$DMG_NAME" --clobber
    else
        echo "Yeni release $TAG oluşturuluyor..."
        gh release create "$TAG" "$DMG_NAME" --title "DockToggle $TAG" --generate-notes
    fi
fi

echo "✅ İşlem tamamlandı! $DMG_NAME dosyası dağıtıma hazırdır ve GitHub Release yayınlandı."
