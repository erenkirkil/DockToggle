# DockToggle

Dock'ta **öndeki uygulamanın** ikonuna tıklayınca o uygulamayı gizler. macOS'un varsayılan
davranışında bu tıklama hiçbir şey yapmaz (uygulama zaten öndedir); DockToggle bunu bir
aç/kapa hareketine dönüştürür.

Menü-çubuğu uygulaması (Dock'ta ikonu yoktur). Sabit bir self-signed sertifikayla
imzalanır; imza kimliği değişmediği için Erişilebilirlik izni her yeniden derlemede korunur.

## Nasıl çalışır

- **Yöntem:** `CGEventTap` ile sol tık yakalanır. Tıklama Dock şeridindeyse ve altındaki
  ikon öndeki uygulamaya aitse `NSRunningApplication.hide()` çağrılır, tıklama yutulur.
- **Neden CGEventTap:** Kardeş proje CloseToQuit bu yöntemi bilinçli olarak *reddeder* ve
  `AXObserver` kullanır. Buradaki fark: DockToggle'ın tıklamayı **yutması** gerekir
  (yutmazsa Dock uygulamayı tekrar öne getirir ve gizleme anında geri alınır). `AXObserver`
  olayları yalnızca gözlemler, yutamaz — bu yüzden burada tap kaçınılmazdır.
- Tap **ayrı bir iş parçacığında** çalışır; ana UI thread'iyle çekişmez. Callback hiçbir
  zaman AppKit çağırmaz: ekran geometrisi, Dock durumu ve öndeki uygulama ana thread'de
  toplanıp kilitli bir anlık görüntü (`EnvSnapshot`) olarak yayımlanır.

## Bozmadığı şeyler

- **Menü çubuğu hariç:** yalnızca yapılandırılmış Dock kenarı dikkate alınır.
- **Değiştirici tuşlu tıklamalar Dock'a bırakılır:** Ctrl-tık bağlam menüsü, Cmd-tık
  "Finder'da göster" vb. normal çalışır.
- **Mission Control / App Exposé açıkken devre dışı:** o sırada tıklama uygulamayı öne
  getirmelidir. Durum, Dock'a takılan bir `AXObserver` ile izlenir — Ekran Kaydı izni
  gerektirmez (bkz. `MissionControlWatcher.swift`).
- **Ölü tık üretmez:** gizlemenin görünür etkisi olmayacaksa (tam ekran Space ya da
  penceresiz uygulama) tıklama Dock'a bırakılır.
- Belirsizlik durumlarında **fail-open** davranır: emin olunamayan her durumda eski
  (müdahalesiz) davranışa düşülür, özellik sessizce kapanmaz.

## Menü

- **Etkin** — özelliği aç/kapat.
- **Girişte Otomatik Başlat** — login öğesi olarak ekler.

## Kurulum

```bash
open ~/Applications/DockToggle.app
```

İlk açılışta **Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik**'te DockToggle'ı
etkinleştir. Tap bu izin olmadan kurulamaz.

## Derleme

İlk seferde imzalama sertifikasını oluştur (bir kez):

```bash
./make-cert.sh
```

Bu, `.signing/` altında rastgele bir keychain parolası üretir (`0600`, depoya girmez) ve
sabit bir self-signed sertifika oluşturur. Kendi parolanı kullanmak istersen:

```bash
export DOCKTOGGLE_KEYCHAIN_PASS="…"
```

Sonra derle ve kur:

```bash
./build.sh
```

Notarize edilmiş DMG üretmek için:

```bash
./release.sh
```

## Teşhis

```bash
log show --last 5m --predicate 'process == "DockToggle"' --info
```

Erişilebilirlik izni bozulursa (imza değişirse TCC kaydı düşer):

```bash
tccutil reset Accessibility com.erenkirkil.docktoggle
```
