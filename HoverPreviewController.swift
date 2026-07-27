import Cocoa
import ApplicationServices

// Arka planda başlamış bir peek'i iptal etmek için iş parçacığı-güvenli bayrak.
// (axQueue seri olduğundan iş, kuyrukta beklerken peek çoktan iptal edilmiş olabilir; o zaman
// pencere ÖNE ÇEKİLMEMELİDİR — aksi halde geri alınamayan kalıcı bir Z-sırası değişimi kalır.)
private final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

// Dock ikonlarında hover'ı algılayıp önizleme panelini yöneten denetleyici (yalnızca ana thread).
// Yaklaşım A: Ağır bir CGEventTap DEĞİL; hafif global monitör yalnızca imleci kabaca izler,
// AX/poll işi yalnızca imleç Dock'a yakınken çalışır → boştayken sıfır maliyet.
//
// Zamanlama tasarımı: dwell poll tikine bağlı DEĞİL (tek atımlık iş öğesi) ve panelin pencere
// listesi ile ikon çerçevesi ARKA PLAN kuyruğunda toplanır → ana thread bloklanmaz.
final class HoverPreviewController {
    private let panel = PreviewPanel()
    private var moveMonitor: Any?
    private var pollTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?
    private var observerTokens: [NSObjectProtocol] = []

    // AX C-API'leri iş parçacığı-güvenlidir → pahalı listeleme/geometri işleri buraya taşındı.
    private let axQueue = DispatchQueue(label: "DockToggle.hover.ax", qos: .userInitiated)

    // MARK: Zamanlama sabitleri
    private let dwellFirst: TimeInterval = 0.20      // ilk açılış (endüstri normu ~0.2 s)
    private let dwellFast: TimeInterval = 0.06       // panel zaten açıkken ikonlar arası geçiş
    private let peekIntent: TimeInterval = 0.13      // satırda "niyet" beklemesi → raise fırtınası yok
    private let peekRestoreDelay: TimeInterval = 0.08 // satırdan çıkışta geri dönüş
    private let hideDelay: TimeInterval = 0.25       // ikon→panel koridorunda kaybolmasın
    private let hardFailCooldown: TimeInterval = 1.5 // penceresiz/çalışmayan uygulama
    private let softFailCooldown: TimeInterval = 0.3 // geçici AX hatası
    private let refreshInterval: TimeInterval = 0.75 // açık panelin içerik tazeleme aralığı
    private let iconCacheTTL: TimeInterval = 0.4     // ikon çerçevesi önbelleğinin ömrü

    // MARK: Hover durumu
    private var hoveredBundlePath: String?           // panelin şu an gösterdiği uygulama
    private var hoveredApp: NSRunningApplication?
    private var shownWindows: [DockWindow] = []
    private var pendingBundlePath: String?           // dwell'i bekleyen aday
    private var inFlightPath: String?                // AX işi arka planda süren aday
    private var dwellWorkItem: DispatchWorkItem?
    private var presentToken = 0                     // uçuştaki present sonuçlarını geçersiz kılar
    private var missCount = 0                        // ardışık başarısız AX hit-test (debounce)
    private var lastAnchor: NSRect?
    private var lastScreen: NSScreen?
    private var lastIconQuartzFrame: CGRect?         // aynı ikondayken AX hit-test'i atla
    private var lastIconCachedAt: TimeInterval = 0
    private var lastWindowSignature: [String] = []
    private var lastRefreshCheck: TimeInterval = 0
    private var failedPath: String?
    private var failedAt: TimeInterval = 0
    private var failedCooldown: TimeInterval = 0

    // MARK: Peek durumu
    // Origin, peek AKTİF DEĞİLKEN tazelenir (panel açıkken Cmd+Tab yapılırsa bayatlamasın), ancak
    // geri dönüş aktivasyonu havadayken yeniden okunmaz — frontmost asenkron güncellendiği için
    // o anda okumak peek'lenen uygulamayı origin sanmaya yol açardı.
    private var peekOriginApp: NSRunningApplication?
    private var peekOriginWindow: AXUIElement?
    private var lastRestoreAt: TimeInterval = 0      // son geri dönüş isteğinin zamanı
    private let restoreSettleWindow: TimeInterval = 1.0
    private var peekedApp: NSRunningApplication?     // peek ile öne getirilen uygulama
    private var peekedPrevWindow: AXUIElement?       // ...onun peek öncesi ön penceresi
    private var peekReminimizeElement: AXUIElement?  // peek için geri açılan simge pencere
    private var peekStartWorkItem: DispatchWorkItem?
    private var peekRestoreWorkItem: DispatchWorkItem?
    private var peekAXToken: CancelToken?
    private var peekActive = false
    private var peekRaiseApplied = false             // raise gerçekten uygulandı mı (yoksa onarma)

    var enabled: Bool = false {
        didSet {
            guard enabled != oldValue else { return }
            enabled ? start() : stop()
        }
    }

    // Pencere küçük resimleri (Ekran Kaydı izni gerektirir); menüden açılıp kapatılır.
    var thumbnailsEnabled: Bool = false

    // Hafif global izleyici: yalnızca imleç hareketini kabaca yakalar, Dock'a yakınsa poll başlatır.
    // Sürükleme sırasında macOS .mouseMoved DEĞİL .leftMouseDragged üretir → o da dinlenir.
    func start() {
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.maybeStartPolling()
        }
        installWorkspaceObservers()
        maybeStartPolling()
    }

    func stop() {
        if let m = moveMonitor { NSEvent.removeMonitor(m); moveMonitor = nil }
        let nc = NSWorkspace.shared.notificationCenter
        observerTokens.forEach { nc.removeObserver($0) }
        observerTokens.removeAll()
        stopPolling()
        cancelPendingHide()
        clearPending()
        hidePanel()
    }

    // Panelin gösterdiği uygulama gizlenir/sonlanırsa panel bayat kalmasın (Dock ikonuna tıklayıp
    // uygulamayı gizleme yolu dahil).
    private func installWorkspaceObservers() {
        guard observerTokens.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self = self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier == self.hoveredApp?.processIdentifier else { return }
                self.hidePanel()
            }
            observerTokens.append(token)
        }
    }

    // İmleç Dock şeridine yakınsa 15 Hz poll'u başlat (zaten çalışıyorsa dokunma).
    private func maybeStartPolling() {
        guard pollTimer == nil else { return }
        guard nearDock() else { return }
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        poll()   // ilk tik bir tam periyot sonra gelirdi; beklemeden bir kez çalıştır
    }

    private func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    // İmlecin Quartz konumunu mevcut clickMightBeOnDock mantığıyla değerlendir.
    private func nearDock() -> Bool {
        let env = currentEnv()
        let appKit = NSEvent.mouseLocation
        // AppKit (alt-orijin) -> Quartz (üst-orijin) çevrimi clickMightBeOnDock beklentisine uygun.
        let quartz = CGPoint(x: appKit.x, y: env.primaryHeight - appKit.y)
        return clickMightBeOnDock(quartz, env)
    }

    // 15 Hz: yalnızca ADAY tespiti ve Dock'tan çıkış kontrolü yapar; dwell ve AX işi buradan ayrıldı.
    private func poll() {
        // Mission Control / App Exposé açıkken panel belirmemeli. Peek geri yüklemesi de burada
        // ÇALIŞTIRILMAZ: MC ekranındayken raise+activate sistem jestini bozardı.
        if missionControlActive() {
            clearPending()
            if panel.isVisible { hidePanel(restorePeek: false) }
            stopPolling()
            return
        }

        let env = currentEnv()
        let appKit = NSEvent.mouseLocation
        let quartz = CGPoint(x: appKit.x, y: env.primaryHeight - appKit.y)

        if !clickMightBeOnDock(quartz, env) {
            // Dock dışında: imleç panelde veya ikon→panel koridorundaysa gizlemeyi iptal et;
            // değilse gizlemeyi planla; panel kapalıysa poll'u durdur.
            if panel.isVisible && panel.mouseIsInsideOrOnPath { cancelPendingHide() }
            else if panel.isVisible { scheduleHide() }
            else { stopPolling() }
            clearPending()   // uçuştaki present'i de geçersiz kılar (hayalet panel açılmasın)
            return
        }

        cancelPendingHide()

        // Ucuz yol: imleç hâlâ aynı ikon dikdörtgeninde → pahalı AX hit-test'e hiç gitme.
        // Önbellek yaşlanır (Dock yeniden yerleşebilir) ve büyütme açıkken hiç kullanılmaz:
        // büyütülmüş çerçeve komşu ikonların üstünü örter, yanlış uygulamayı gösterirdi.
        if !env.magnification, let f = lastIconQuartzFrame, hoveredBundlePath != nil,
           ProcessInfo.processInfo.systemUptime - lastIconCachedAt < iconCacheTTL, f.contains(quartz) {
            missCount = 0
            maybeRefreshOpenPanel()
            return
        }

        guard let item = dockAppItem(at: quartz), let path = item.bundlePath else {
            // Geçici AX hatası (Dock meşgul, büyütme animasyonu) dwell'i sıfırlamasın: 3 tik tolere et.
            missCount += 1
            if missCount >= 3 {
                clearPending()
                // Çöp Sepeti/klasör/ayırıcı gibi uygulama-olmayan öğede bayat panel asılı kalmasın.
                if panel.isVisible && !panel.mouseIsInsideOrOnPath { scheduleHide() }
            }
            return
        }
        missCount = 0

        if path == hoveredBundlePath {                  // paneli açık olan uygulama
            // AX hit-test aynı ikonu doğruladı → önbelleğin yaşını tazele (bir sonraki doğrulama
            // iconCacheTTL sonra). Böylece doğruluk korunurken 15 Hz AX yükü ortadan kalkar.
            lastIconCachedAt = ProcessInfo.processInfo.systemUptime
            maybeRefreshOpenPanel()
            return
        }
        if path == pendingBundlePath || path == inFlightPath { return }   // zaten işleniyor
        if path == failedPath,
           ProcessInfo.processInfo.systemUptime - failedAt < failedCooldown { return }

        scheduleDwell(for: path)
    }

    // Dwell tek atımlık iş öğesidir (poll tikine kuantize DEĞİL). Panel açıkken kısa tutulur →
    // ikonlar arasında gezinme neredeyse anlık.
    private func scheduleDwell(for path: String) {
        dwellWorkItem?.cancel()
        pendingBundlePath = path
        let delay = (hoveredBundlePath != nil) ? dwellFast : dwellFirst
        let work = DispatchWorkItem { [weak self] in self?.attemptPresent(path: path) }
        dwellWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Bekleyen dwell'i VE arka planda süren present'i iptal eder.
    private func clearPending() {
        dwellWorkItem?.cancel(); dwellWorkItem = nil
        pendingBundlePath = nil
        invalidateInFlight()
    }

    private func invalidateInFlight() {
        presentToken &+= 1
        inFlightPath = nil
    }

    // Dwell doldu: pahalı AX işini ARKA PLANDA yap, sonucu ana thread'de göster.
    private func attemptPresent(path: String) {
        dwellWorkItem = nil
        pendingBundlePath = nil
        guard let app = runningApp(forBundlePath: path) else { markFailed(path, transient: false); return }

        presentToken &+= 1
        let token = presentToken
        inFlightPath = path                                      // poll aynı işi tekrar kuyruğa atmasın
        let pid = app.processIdentifier
        let hidden = app.isHidden
        let env = currentEnv()
        let appKit = NSEvent.mouseLocation                       // AppKit okumaları ana thread'de
        let quartz = CGPoint(x: appKit.x, y: env.primaryHeight - appKit.y)
        let icon = app.icon
        let primaryHeight = env.primaryHeight
        let autohide = env.autohide

        axQueue.async { [weak self] in
            guard let self = self else { return }
            let windows = listWindows(pid: pid, appIsHidden: hidden)
            let first = dockIconFrame(atQuartz: quartz, primaryHeight: primaryHeight)
            // token yalnızca ANA THREAD'de okunur (veri yarışı olmasın); arka planda kontrol yok.
            let deliver: (NSRect?) -> Void = { anchor in
                DispatchQueue.main.async {
                    guard token == self.presentToken else { return }   // bayat/iptal edilmiş sonuç
                    self.finishPresent(path: path, app: app, icon: icon, windows: windows, anchor: anchor)
                }
            }
            guard autohide else { deliver(first); return }
            // Auto-hide'da Dock kayarak girerken ikon çerçevesi oynar; ikinci ölçüm farklıysa
            // animasyon sürüyordur → panel yanlış konuma çakılmasın diye ikinciyi kullan.
            // (Kuyrukta uyumak yerine asyncAfter: bu arada tıklama/peek işleri geçebilsin.)
            self.axQueue.asyncAfter(deadline: .now() + 0.07) {
                let second = dockIconFrame(atQuartz: quartz, primaryHeight: primaryHeight)
                deliver(second ?? first)
            }
        }
    }

    // Dock öğesinin bundle yolundan çalışan uygulamayı bulur. Yol eşleşmezse (uygulama farklı bir
    // kopyadan başlatılmışsa) bundle kimliğine düşer.
    private func runningApp(forBundlePath path: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let exact = apps.first(where: { $0.bundleURL?.standardizedFileURL.path == path }) { return exact }
        guard let bid = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier else { return nil }
        return apps.first(where: { $0.bundleIdentifier == bid })
    }

    private func finishPresent(path: String, app: NSRunningApplication, icon: NSImage?,
                               windows: [DockWindow]?, anchor: NSRect?) {
        inFlightPath = nil
        // AX sorgusu başarısız (meşgul/askıda uygulama): geçici → kısa cooldown, hemen tekrar denenir.
        guard let windows = windows else { markFailed(path, transient: true); return }
        // Penceresiz/tam ekran uygulama: panel yok (kalıcı durum → uzun cooldown).
        guard !windows.isEmpty else { markFailed(path, transient: false); return }
        // İkon çerçevesi okunamadı: genelde geçici (Dock animasyonu, imleç kenara kaydı) → kısa cooldown.
        guard let anchor = anchor,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        else { markFailed(path, transient: true); return }

        refreshPeekOriginIfIdle()     // peek'ten ÖNCE, hiçbir aktivasyon yapılmamışken yakalanır

        lastAnchor = anchor
        lastScreen = screen
        lastIconQuartzFrame = CGRect(x: anchor.minX,
                                     y: currentEnv().primaryHeight - anchor.maxY,
                                     width: anchor.width, height: anchor.height)
        lastIconCachedAt = ProcessInfo.processInfo.systemUptime
        hoveredBundlePath = path
        hoveredApp = app
        lastRefreshCheck = ProcessInfo.processInfo.systemUptime
        failedPath = nil
        redraw(with: windows, app: app, icon: icon, anchor: anchor, screen: screen)
    }

    // Başarısız deneme: durumu temizle, kısa süre aynı ikonda yeniden deneme (AX spam'i önlenir).
    private func markFailed(_ path: String, transient: Bool) {
        inFlightPath = nil
        failedPath = path
        failedAt = ProcessInfo.processInfo.systemUptime
        failedCooldown = transient ? softFailCooldown : hardFailCooldown
        hidePanel()
    }

    private func redraw(with windows: [DockWindow], app: NSRunningApplication, icon: NSImage?,
                        anchor: NSRect, screen: NSScreen) {
        shownWindows = windows
        lastWindowSignature = signature(of: windows)
        panel.show(windows: windows, appIcon: icon, anchor: anchor, on: screen,
                   orientation: currentEnv().orientation,
                   showThumbnails: thumbnailsActive,
                   onSelect: { [weak self] w in self?.select(w, app: app) },
                   onClose:  { [weak self] w in self?.close(w, app: app) },
                   onPeek:   { [weak self] w in self?.peek(w, app: app) },
                   onPeekEnd: { [weak self] in self?.peekEnded() })
        requestThumbnails(for: windows)
    }

    // Küçük resimler yalnızca özellik açıkken, desteklenen sürümde ve Ekran Kaydı izni varken.
    private var thumbnailsActive: Bool {
        return thumbnailsEnabled && WindowThumbnails.shared.isSupported && WindowThumbnails.shared.hasPermission
    }

    // Yakalama tamamen asenkron: panel hemen metinle açılır, görüntüler hazır oldukça yerleşir.
    private func requestThumbnails(for windows: [DockWindow]) {
        guard thumbnailsActive else { return }
        let ids = windows.compactMap { $0.windowID }
        guard !ids.isEmpty else { return }
        WindowThumbnails.shared.thumbnails(for: ids) { [weak self] id, image in
            self?.panel.setThumbnail(image, forWindowID: id)
        }
    }

    private func redraw(with windows: [DockWindow], app: NSRunningApplication) {
        guard let anchor = lastAnchor, let screen = lastScreen else { return }
        redraw(with: windows, app: app, icon: app.icon, anchor: anchor, screen: screen)
    }

    // Başlık + simge durumu + peek edilebilirlik: yalnızca başlığa bakmak, minimize/Space değişimini
    // kaçırıp peek korumasının bayat veriyle çalışmasına yol açıyordu.
    private func signature(of windows: [DockWindow]) -> [String] {
        return windows.map { "\($0.title)|\($0.isMinimized)|\($0.isOnCurrentSpace)" }
    }

    // Panel açıkken uygulamanın pencere listesi değişebilir (⌘W/⌘N). Aynı ikonda beklerken
    // seyrek aralıkla arka planda tazele; liste değiştiyse paneli yeniden çiz.
    private func maybeRefreshOpenPanel() {
        guard panel.isVisible, let app = hoveredApp else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRefreshCheck >= refreshInterval else { return }
        lastRefreshCheck = now
        let pid = app.processIdentifier
        let hidden = app.isHidden
        axQueue.async { [weak self] in
            let windows = listWindows(pid: pid, appIsHidden: hidden)
            DispatchQueue.main.async {
                guard let self = self, self.panel.isVisible,
                      self.hoveredApp?.processIdentifier == pid else { return }   // panel kimliği doğrula
                // AX sorgusu başarısızsa (nil) paneli OLDUĞU GİBİ bırak: tek bir zaman aşımı,
                // kullanıcı panelin üstündeyken paneli kapatmamalı.
                guard let windows = windows else { return }
                guard self.signature(of: windows) != self.lastWindowSignature else { return }
                if windows.isEmpty { self.hidePanel() } else { self.redraw(with: windows, app: app) }
            }
        }
    }

    // MARK: - Satır eylemleri

    private func select(_ window: DockWindow, app: NSRunningApplication) {
        clearPeekTransient()              // seçim kalıcı: geri dönme
        let element = window.element
        let minimized = window.isMinimized
        // Kullanıcının bilinçli seçimi yeni "origin"dir; bekleyen geri dönüş penceresi de geçersiz.
        peekOriginApp = app
        peekOriginWindow = element
        lastRestoreAt = 0
        axQueue.async {
            // Tıklama yolu minimize pencereyi geri AÇAR (kasıtlı ve kullanıcı isteğiyle).
            if minimized { unminimizeElement(element) }
            raiseElement(element)
            DispatchQueue.main.async { activateApp(app) }
        }
        hidePanel()
    }

    private func close(_ window: DockWindow, app: NSRunningApplication) {
        axQueue.async { closeWindow(window) }
        // AXPress hedef uygulamada asenkron işlenir; hemen listelemek kapanan pencereyi geri getirirdi.
        // İyimser güncelle, gerçek durumu kısa gecikmeyle doğrula.
        let remaining = shownWindows.filter { !CFEqual($0.element, window.element) }
        if remaining.isEmpty { hidePanel() } else { redraw(with: remaining, app: app) }

        guard panel.isVisible else { return }
        let pid = app.processIdentifier
        let hidden = app.isHidden
        axQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            let windows = listWindows(pid: pid, appIsHidden: hidden)
            DispatchQueue.main.async {
                guard let self = self, self.panel.isVisible,
                      self.hoveredApp?.processIdentifier == pid else { return }
                guard let windows = windows else { return }   // AX hatası → paneli kapatma
                if windows.isEmpty { self.hidePanel() } else { self.redraw(with: windows, app: app) }
            }
        }
    }

    // MARK: - Peek: satırda beklerken gerçek pencereyi öne getir; çıkınca ESKİ DÜZENİ geri yükle.

    // Satıra girildi: peek HEMEN başlamaz. Kısa bir "niyet" beklemesi, satırlar arasında hızlı
    // gezinirken art arda aktivasyon (pencere fırlaması/titreme) oluşmasını engeller.
    private func peek(_ window: DockWindow, app: NSRunningApplication) {
        peekStartWorkItem?.cancel(); peekStartWorkItem = nil
        // Simge durumundaki pencereler de peek edilir (kullanıcı tercihi): peek sırasında geri
        // açılır, peek bitince YENİDEN SİMGEYE ALINIR — yani kalıcı iz bırakmaz.
        // Başka Space'teki (simge olmayan) pencere hâlâ peek dışıdır: peek Space'i kaydırır ve
        // geri dönüşte geri gelmez. O satır yalnızca vurgulanır; tıklama hâlâ çalışır.
        guard window.isMinimized || window.isOnCurrentSpace else { peekEnded(); return }
        peekRestoreWorkItem?.cancel(); peekRestoreWorkItem = nil   // başka satıra geçiş → geri dönüşü iptal
        refreshPeekOriginIfIdle()   // bu peek dizisinden HEMEN ÖNCEKİ ön plan durumu origin olsun
        let work = DispatchWorkItem { [weak self] in self?.beginPeek(window, app: app) }
        peekStartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + peekIntent, execute: work)
    }

    private func beginPeek(_ window: DockWindow, app: NSRunningApplication) {
        peekStartWorkItem = nil
        let pid = app.processIdentifier
        let needPrev = (peekedApp?.processIdentifier != pid)
        peekedApp = app
        peekActive = true
        let element = window.element
        let wasMinimized = window.isMinimized
        let token = CancelToken()
        peekAXToken?.cancel()
        peekAXToken = token
        axQueue.async { [weak self] in
            // Peek'lenen uygulamanın KENDİ Z-sırasını da onarabilmek için ilk peek'ten önceki
            // ön penceresini sakla (aynı-uygulama peek'inde geri dönüşün tek dayanağı budur).
            let prev = needPrev ? focusedWindow(pid: pid) : nil
            // Kuyrukta beklerken peek iptal edilmiş olabilir: o durumda pencereye DOKUNMA,
            // yoksa geri alınamayan kalıcı bir öne-çekme kalır.
            guard !token.isCancelled else { return }
            // prev, raise'den ÖNCE ve iptalden BAĞIMSIZ olarak saklanır: raise uygulandıktan sonra
            // gelen bir iptal, geri alma bilgisini çöpe atmamalı.
            if needPrev {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.peekedPrevWindow == nil else { return }
                    self.peekedPrevWindow = prev
                }
            }
            // Simge durumundaysa geri aç ve geri dönüşte yeniden simgeye alınmak üzere işaretle.
            if wasMinimized {
                unminimizeElement(element)
                DispatchQueue.main.async { [weak self] in self?.peekReminimizeElement = element }
            }
            raiseElement(element)
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Oturum bu arada tamamen temizlendiyse (panel kapandı) bayrağı yazma: temizlenmiş
                // duruma "geri yüklenecek değişiklik var" demek, sonraki peek'te sahte onarım yapardı.
                guard self.peekAXToken === token else { return }
                self.peekRaiseApplied = true      // artık geri yüklenecek gerçek bir değişiklik var
                guard !token.isCancelled, self.peekActive else { return }
                activateApp(app)                  // AppKit aktivasyonu ana thread'de
            }
        }
    }

    // Origin'i (peek'ten önce önde olan uygulama + penceresi) tazeler. Peek AKTİFKEN dokunmaz;
    // ayrıca yakın geçmişte geri dönüş isteği gönderildiyse okumaz — NSWorkspace.frontmostApplication
    // aktivasyondan hemen sonra güncellenmediği için o anda okumak peek'lenen uygulamayı origin
    // sanmaya yol açardı.
    private func refreshPeekOriginIfIdle() {
        guard !peekActive else { return }
        guard ProcessInfo.processInfo.systemUptime - lastRestoreAt >= restoreSettleWindow else { return }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        guard front.processIdentifier != peekOriginApp?.processIdentifier else { return }
        peekOriginApp = front
        peekOriginWindow = nil
        let pid = front.processIdentifier
        axQueue.async { [weak self] in
            let win = focusedWindow(pid: pid)
            DispatchQueue.main.async {
                guard let self = self, self.peekOriginWindow == nil,
                      self.peekOriginApp?.processIdentifier == pid else { return }
                self.peekOriginWindow = win
            }
        }
    }

    // Satırdan çıkıldı: kısa gecikmeyle eskiye dön (bu arada başka satıra girilirse peek() iptal eder).
    private func peekEnded() {
        peekStartWorkItem?.cancel(); peekStartWorkItem = nil   // henüz başlamadıysa hiç başlatma
        peekAXToken?.cancel()                                   // kuyrukta bekleyen raise'i iptal et
        guard peekActive else { return }
        peekRestoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endPeekRestoring() }
        peekRestoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + peekRestoreDelay, execute: work)
    }

    // Eski düzeni geri yükle: önce peek'lenen uygulamanın kendi ön penceresi, sonra origin
    // uygulamanın penceresi raise edilir, en sonda origin uygulama aktive edilir.
    private func endPeekRestoring() {
        peekRestoreWorkItem?.cancel(); peekRestoreWorkItem = nil
        peekStartWorkItem?.cancel(); peekStartWorkItem = nil
        guard peekActive else { clearPeekTransient(); return }
        // Peek iptal edildiği için raise HİÇ uygulanmadıysa ortada onarılacak bir şey yok:
        // "geri yükleme" yapmak, kullanıcının kendi pencere sırasını gereksizce değiştirirdi.
        guard peekRaiseApplied else { clearPeekTransient(); return }

        // Kullanıcı bu arada bilinçli olarak ÜÇÜNCÜ bir uygulamaya geçtiyse seçimini ezme.
        // (Frontmost'un hâlâ origin olması normaldir: kendi aktivasyonumuz henüz inmemiş olabilir —
        // bu durumda da geri yükleme yapılmalı, çünkü AX raise çoktan uygulanmıştır.)
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let peekedPid = peekedApp?.processIdentifier
        let originPid = peekOriginApp?.processIdentifier
        if let f = frontPid, f != peekedPid, f != originPid { clearPeekTransient(); return }

        let prevWindow = peekedPrevWindow
        let originWindow = peekOriginWindow
        let originApp = peekOriginApp
        let reminimize = peekReminimizeElement
        lastRestoreAt = ProcessInfo.processInfo.systemUptime   // origin, aktivasyon inene dek okunmasın
        clearPeekTransient()          // origin bir sonraki peek'e kadar korunur

        axQueue.async {
            if let m = reminimize { minimizeElement(m) }     // peek için açılan simge pencereyi geri al
            if let p = prevWindow { raiseElement(p) }        // peek'lenen uygulamanın iç sırası
            if let o = originWindow { raiseElement(o) }      // origin pencere (aynı-uygulama durumu dahil)
            DispatchQueue.main.async {
                if let app = originApp { activateApp(app) }
            }
        }
    }

    // Peek'in geçici durumu. Origin BİLEREK silinmez: bir sonraki peek'ten hemen önce
    // refreshPeekOriginIfIdle() tazeler; burada silmek, geri dönüş aktivasyonu havadayken
    // yeniden okuma yapılmasına ve peek'lenen uygulamanın origin sanılmasına yol açardı.
    private func clearPeekTransient() {
        peekStartWorkItem?.cancel(); peekStartWorkItem = nil
        peekRestoreWorkItem?.cancel(); peekRestoreWorkItem = nil
        peekAXToken?.cancel(); peekAXToken = nil
        peekActive = false
        peekRaiseApplied = false
        peekedApp = nil
        peekedPrevWindow = nil
        peekReminimizeElement = nil
    }

    // MARK: - Gizleme

    private func scheduleHide() {
        guard hideWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.hideWorkItem = nil
            if self.panel.isVisible && self.panel.mouseIsInsideOrOnPath { return }
            self.hidePanel()
            self.stopPolling()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    private func cancelPendingHide() { hideWorkItem?.cancel(); hideWorkItem = nil }

    // restorePeek: Mission Control açıldığında false — o anda raise/activate yapmak sistem
    // jestinin üstüne çıkardı.
    private func hidePanel(restorePeek: Bool = true) {
        if restorePeek { endPeekRestoring() }
        clearPeekTransient()
        panel.dismiss()
        invalidateInFlight()          // uçuştaki async sonuçlar bu paneli diriltmesin
        hoveredBundlePath = nil
        hoveredApp = nil
        shownWindows = []
        lastWindowSignature = []
        lastIconQuartzFrame = nil
    }
}
