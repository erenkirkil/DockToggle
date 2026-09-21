#!/bin/bash
# DockToggle için sabit (kararlı) self-signed kod imzalama sertifikası oluşturur.
# Amaç: TCC/Erişilebilirlik izni cdhash yerine sabit sertifika kimliğine bağlansın,
# böylece her yeniden derlemede izin kaybolmasın.
set -e

CERTNAME="DockToggle Self-Signed"
# Script nerede duruyorsa .signing onun yanındadır (sabit $HOME yolu bayatlıyordu).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$SRC/.signing"
KC="$HOME/Library/Keychains/docktoggle-signing.keychain-db"
# Keychain parolası: ortam değişkeninden alınır. Tanımlı değilse rastgele üretilip
# $WORK/keychain-pass dosyasına (0600, .signing/ gitignore'da) yazılır. Depoya
# sabit parola yazılmaz — build.sh aynı dosyadan okur.
KCPASS="${DOCKTOGGLE_KEYCHAIN_PASS:-}"

mkdir -p "$WORK"
cd "$WORK"

if [ -z "$KCPASS" ]; then
  if [ -f "$WORK/keychain-pass" ]; then
    KCPASS=$(cat "$WORK/keychain-pass")
  else
    KCPASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    (umask 077; printf '%s' "$KCPASS" > "$WORK/keychain-pass")
    echo "== Yeni keychain parolası üretildi: $WORK/keychain-pass (0600) =="
  fi
fi

# Zaten varsa tekrar oluşturma
if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "$CERTNAME"; then
  echo "Sertifika zaten mevcut:"
  security find-identity -v -p codesigning "$KC"
  exit 0
fi

echo "== OpenSSL config =="
cat > cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = DockToggle Self-Signed
O  = DockToggle
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "== Anahtar + sertifika üretiliyor =="
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -sha256 -config cert.cnf
openssl x509 -in cert.pem -noout -text | grep -A1 "Extended Key Usage" || true

echo "== PKCS#12 paketi =="
openssl pkcs12 -export -inkey key.pem -in cert.pem -out cert.p12 -name "$CERTNAME" -passout pass:$KCPASS

echo "== Özel keychain oluşturuluyor =="
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"          # otomatik kilitlenmesin
security unlock-keychain -p "$KCPASS" "$KC"

echo "== İçe aktarılıyor =="
security import cert.p12 -k "$KC" -P "$KCPASS" -A -T /usr/bin/codesign

echo "== codesign'ın anahtarı parolasız kullanabilmesi için yetki =="
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1

echo "== Sonuç =="
security find-identity -v -p codesigning "$KC"

# Hassas dosyaları temizle (anahtar artık keychain'de)
rm -f key.pem cert.pem cert.p12 cert.cnf
echo "OK: '$CERTNAME' hazır ($KC)"
