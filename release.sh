#!/bin/bash
set -e

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="DockToggle"
SIGN_ID="Developer ID Application: EREN KIRKIL (992XYS9346)"
NOTARY_PROFILE="DOCKTOGGLE_PROFILE" # Kullanıcı bunu ayarlamış olmalı

echo "1. Uygulama derleniyor..."
swiftc -O -swift-version 5 "$SRC"/*.swift -o "$SRC/DockToggle" \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement \
  -framework ScreenCaptureKit

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

echo "4. DMG oluşturuluyor..."
DMG_NAME="$SRC/${APP_NAME}_Release.dmg"
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

echo "✅ İşlem tamamlandı! $DMG_NAME dosyası dağıtıma hazırdır."
