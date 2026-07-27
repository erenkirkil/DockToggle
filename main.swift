import Cocoa
import ApplicationServices
import ServiceManagement

// MARK: - Global durum (C callback'ten erişildiği için global; -swift-version 5)
var eventTap: CFMachPort?            // yalnızca ana iş parçacığında değiştirilir
var runLoopSource: CFRunLoopSource?  // yalnızca ana iş parçacığında değiştirilir
var suppressNextLeftMouseUp = false  // tap iş parçacığında okunur/yazılır
var isEnabled = true                 // duraklat/devam

// MARK: - Ortam anlık görüntüsü (ana iş parçacığında üretilir, tap iş parçacığında okunur)
// AX/AppKit'i tap iş parçacığından ÇAĞIRMAMAK için ekran geometrisi, Dock durumu ve
// ön plandaki uygulama önceden ana iş parçacığında toplanıp kilitle yayımlanır. Böylece
// callback yalnızca değişmez bir anlık görüntü okur (veri yarışı / off-main AppKit yok).
final class EnvSnapshot {
    let screens: [(frame: CGRect, visible: CGRect)]
    let primaryHeight: CGFloat
    let orientation: String     // "bottom" | "left" | "right"
    let autohide: Bool
    let dockTile: CGFloat       // com.apple.dock tilesize (ikon boyu) — auto-hide bant kalınlığı için
    let magnification: Bool     // büyütme açıkken ikon çerçeveleri sürekli oynar
    let front: NSRunningApplication?
    let frontBundlePath: String?
    let frontName: String?
    let frontIsHidden: Bool
    init(screens: [(frame: CGRect, visible: CGRect)], primaryHeight: CGFloat,
         orientation: String, autohide: Bool, dockTile: CGFloat, magnification: Bool,
         front: NSRunningApplication?,
         frontBundlePath: String?, frontName: String?, frontIsHidden: Bool) {
        self.screens = screens; self.primaryHeight = primaryHeight
        self.orientation = orientation; self.autohide = autohide; self.dockTile = dockTile
        self.magnification = magnification
        self.front = front; self.frontBundlePath = frontBundlePath
        self.frontName = frontName; self.frontIsHidden = frontIsHidden
    }
}
let envLock = NSLock()
var envSnapshot = EnvSnapshot(screens: [], primaryHeight: 0, orientation: "bottom",
                              autohide: false, dockTile: 48, magnification: false,
                              front: nil, frontBundlePath: nil,
                              frontName: nil, frontIsHidden: false)
func currentEnv() -> EnvSnapshot { envLock.lock(); defer { envLock.unlock() }; return envSnapshot }
func publishEnv(_ e: EnvSnapshot) { envLock.lock(); envSnapshot = e; envLock.unlock() }

// Tap iş parçacığının run loop'u (tap iş parçacığı yayımlar, ana iş parçacığı kaynak eklemek için okur)
var tapRunLoop: CFRunLoop?
let tapRunLoopReady = DispatchSemaphore(value: 0)

// MARK: - Yardımcılar

func dockIsAutohide() -> Bool {
    return UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
}

// Tıklamanın Dock şeridinde olma ihtimali var mı? (yalnızca önbellekten okur; AX/AppKit çağırmaz)
// Menü çubuğu (üst şerit) AÇIKÇA hariç tutulur — yalnızca yapılandırılmış Dock kenarı dikkate
// alınır. Auto-hide'da geometri bandı sıfırlandığından imlecin Dock kenarına yakınlığına bakılır.
// Belirsizlik durumunda true (fail-open) — yanlış "true" yalnızca eski (bir AX hit-test) maliyete döner.
func clickMightBeOnDock(_ quartzPoint: CGPoint, _ env: EnvSnapshot) -> Bool {
    let primaryHeight = env.primaryHeight
    guard primaryHeight > 0 else { return true }                        // bilinmiyor -> fail-open
    let p = CGPoint(x: quartzPoint.x, y: primaryHeight - quartzPoint.y) // Quartz -> AppKit
    guard let s = env.screens.first(where: { $0.frame.contains(p) }) else { return true }
    let f = s.frame, v = s.visible
    // Auto-hide'da Dock görünür alanı daraltmaz; açıldığında kapladığı KALINLIK kadar (ikon boyu +
    // boşluk + büyütme payı) bir bant kullan. (Eski 6pt "tetikleme bandı" hatası: kullanıcı kenara
    // değil, açılmış Dock'taki ikona tıklar.) Auto-hide kapalıyken frame/visibleFrame farkı = Dock şeridi.
    let band = max(env.dockTile + 48, 96)
    switch env.orientation {
    case "left":
        if env.autohide { return p.x <= f.minX + band }
        return v.minX > f.minX && p.x < v.minX
    case "right":
        if env.autohide { return p.x >= f.maxX - band }
        return v.maxX < f.maxX && p.x > v.maxX
    default: // bottom — AppKit alt-orijin: Dock altta -> visibleFrame.minY > frame.minY
        if env.autohide { return p.y <= f.minY + band }
        return v.minY > f.minY && p.y < v.minY
    }
}

// İmlecin altındaki Dock uygulama ikonunu çözer: (bundle yolu, başlık). AX C-API'leri iş
// parçacığı-güvenlidir; tap iş parçacığından çağrılması güvenlidir.
func dockAppItem(at point: CGPoint) -> (bundlePath: String?, title: String?)? {
    // Timeout system-wide elemana YAZILMAZ: o çağrı süreç-global varsayılanı değiştirir ve
    // arka plan kuyruğundaki AX işleriyle çakışırdı. Global varsayılan uygulama açılışında bir
    // kez set edilir; burada yalnızca yürünen her elemana açık (kısa) timeout verilir.
    let systemWide = AXUIElementCreateSystemWide()
    var elementRef: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef) == .success,
          var element = elementRef else { return nil }

    for _ in 0..<4 {
        AXUIElementSetMessagingTimeout(element, axQuickTimeout)  // takılan uygulama tıklamayı dondurmasın
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String, subrole == "AXApplicationDockItem" {
            var title: String?
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success {
                title = titleRef as? String
            }
            var path: String?
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlRef) == .success,
               let u = urlRef, CFGetTypeID(u) == CFURLGetTypeID() {
                path = ((u as! CFURL) as URL).standardizedFileURL.path
            }
            return (path, title)
        }
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
           let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID() {
            element = parent as! AXUIElement
        } else {
            break
        }
    }
    return nil
}

// Sadece POZİTİF olarak "gizlemenin görünür etkisi olmaz" (tam ekran ya da penceresiz) ise true.
// Hata/belirsizlik -> false (fail-open: eski davranışla gizle, özelliği sessizce kapatma).
// Yalnızca app.processIdentifier kullanır + AX C-API'leri -> tap iş parçacığından güvenli.
func hideWouldBeNoOp(_ app: NSRunningApplication) -> Bool {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, 0.05)
    var focusedRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
       let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() {
        let win = focused as! AXUIElement
        var fsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsRef) == .success,
           let isFS = fsRef as? Bool, isFS {
            return true   // tam ekran Space -> hide() etkisiz
        }
        return false      // normal odaklı pencere var
    }
    var windowsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
       let windows = windowsRef as? [AXUIElement] {
        return windows.isEmpty  // hiç pencere yoksa gizlenecek bir şey yok
    }
    return false
}

// MARK: - Olay callback'i (ÖZEL tap iş parçacığında çalışır — ana UI iş parçacığıyla çekişmez)
func eventTapCallback(proxy: CGEventTapProxy,
                      type: CGEventType,
                      event: CGEvent,
                      refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        suppressNextLeftMouseUp = false             // yarım kalan jest durumu güvenilmez
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return passthrough

    case .leftMouseUp:
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return nil
        }
        return passthrough

    case .leftMouseDown:
        if !isEnabled { return passthrough }

        // Mission Control / App Exposé açıkken tıklama uygulamayı/pencereyi öne getirmeli, gizlememeli.
        if missionControlActive() { return passthrough }

        // Düz sol tık dışındaki her şeyi (Ctrl/Cmd/Opt/Shift) Dock'a bırak —
        // Ctrl-tık bağlam menüsü, Cmd-tık "Finder'da göster" vb. bozulmasın.
        let mods = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        if !mods.isEmpty { return passthrough }

        let env = currentEnv()
        let loc = event.location
        if !clickMightBeOnDock(loc, env) { return passthrough }

        guard let item = dockAppItem(at: loc) else { return passthrough }

        // NOT: Burada eskiden "çift tıkın 2. tıkını yut" mantığı vardı (az önce gizlenen uygulamayı
        // Dock yeniden açmasın diye). Kullanıcı tercihi: gizledikten HEMEN SONRA aynı ikona basmak
        // uygulamayı geri açmalı. İkinci tık artık Dock'a bırakılır (front artık o uygulama
        // olmadığından aşağıdaki eşleşme zaten başarısız olur ve tık geçer).

        guard let front = env.front, !env.frontIsHidden else { return passthrough }

        // Kimlik (bundle yolu) ile eşleştir — yeniden adlandırmaya/aynı-isme dayanıklı; yoksa isimle.
        let matches: Bool
        if let dp = item.bundlePath, let fp = env.frontBundlePath {
            matches = (dp == fp)
        } else if let dt = item.title, let fn = env.frontName {
            matches = (dt == fn)
        } else {
            matches = false
        }
        guard matches else { return passthrough }

        // Gizlemenin görünür etkisi olmayacaksa (tam ekran / penceresiz) ölü tık yaratma; Dock'a bırak.
        if hideWouldBeNoOp(front) { return passthrough }

        DispatchQueue.main.async { front.hide() }   // AppKit eylemi ana iş parçacığında
        suppressNextLeftMouseUp = true
        return nil

    default:
        return passthrough
    }
}

// MARK: - Uygulama denetleyicisi
class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var healthTimer: Timer?
    var tapFailureAlertShown = false
    let hoverController = HoverPreviewController()
    let hoverMenuItem = NSMenuItem(title: "Pencere Önizlemeleri", action: #selector(toggleHoverPreviews), keyEquivalent: "")
    let thumbMenuItem = NSMenuItem(title: "Küçük Resimler", action: #selector(toggleThumbnails), keyEquivalent: "")

    let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let pauseMenuItem  = NSMenuItem(title: "Etkin", action: #selector(togglePause), keyEquivalent: "")
    let loginMenuItem  = NSMenuItem(title: "Girişte Otomatik Başlat", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Süreç-global AX mesaj timeout'u BİR KEZ burada belirlenir. (System-wide elemana yapılan
        // her SetMessagingTimeout çağrısı bu globali değiştirir; farklı thread'lerden farklı
        // değerlerle yazmak çağrıların birbirinin timeout'unu bozmasına yol açıyordu.)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axQuickTimeout)
        rebuildEnv()
        buildStatusItem()

        // Erişilebilirlik promptu — sadece bir kez (her sağlık kontrolünde değil).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

        startTapThread()   // tap callback'ini ana UI iş parçacığından ayır
        syncState()
        // Varsayılan: kapalı. Kullanıcı bir kez açtıysa kalıcı tercihi uygula.
        let prefs = UserDefaults.standard
        let hoverOn = prefs.object(forKey: "hoverPreviewsEnabled") as? Bool ?? false
        syncHoverController(desired: hoverOn)

        // Küçük resimler açıksa Ekran Kaydı iznini bir kez iste. (Sistem promptu yalnızca ilk
        // seferde çıkar; sonrasında bu çağrı sessizce false döner ve menüde uyarı gösterilir.)
        if hoverOn && thumbnailsPreference && WindowThumbnails.shared.isSupported
            && !WindowThumbnails.shared.hasPermission {
            WindowThumbnails.shared.requestPermission()
        }

        // Yedek sağlık zamanlayıcısı: artık izin/tap durumu çoğunlukla olay-tetikli güncelleniyor,
        // bu yalnızca emniyet ağı -> seyrek aralık + tolerans ile uyandırma birleştirmeye izin ver.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.syncState()
            self?.rebuildEnv()   // Dock boyu/yönü/auto-hide değişimini uygulama geçişi olmadan da yakala
        }
        healthTimer?.tolerance = 5.0

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(envChanged),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(envChanged),
                       name: NSWorkspace.didHideApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(envChanged),
                       name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // AX izin değişimini olay-tetikli yakala (timer yalnızca yedek).
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(axTrustMaybeChanged),
            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
    }

    // Uygulama geçişleri kümelenebilir (hover peek'i her satırda bir aktivasyon üretir).
    // ÖN PLAN bilgisi ASLA geciktirilmez — tap yolu "tıklanan uygulama önde mi" kararını buna
    // dayandırıyor; bayat front, yanlış uygulamanın gizlenmesine yol açardı. Yalnızca pahalı
    // geometri/Dock taraması (ekranlar + UserDefaults) debounce edilir.
    var envRebuildPending = false
    @objc func envChanged() {
        publishFrontOnly()
        guard !envRebuildPending else { return }
        envRebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.envRebuildPending = false
            self?.rebuildEnv()
        }
    }
    @objc func screenChanged() { rebuildEnv() }
    @objc func axTrustMaybeChanged() { DispatchQueue.main.async { [weak self] in self?.syncState() } }

    // Ekran geometrisi + Dock durumu + ön plandaki uygulamayı ana iş parçacığında toplayıp yayımla.
    func rebuildEnv() {
        let screens = NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) }
        let primaryHeight: CGFloat
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            primaryHeight = primary.frame.height
        } else {
            primaryHeight = NSScreen.main?.frame.height ?? 0
        }
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let orientation = dock?.string(forKey: "orientation") ?? "bottom"
        let autohide = dockIsAutohide()
        let tile = CGFloat(dock?.double(forKey: "tilesize") ?? 0)
        let dockTile = tile > 0 ? tile : 48
        let magnification = dock?.bool(forKey: "magnification") ?? false
        let front = NSWorkspace.shared.frontmostApplication
        publishEnv(EnvSnapshot(
            screens: screens, primaryHeight: primaryHeight, orientation: orientation, autohide: autohide,
            dockTile: dockTile, magnification: magnification, front: front,
            frontBundlePath: front?.bundleURL?.standardizedFileURL.path,
            frontName: front?.localizedName,
            frontIsHidden: front?.isHidden ?? false))
    }

    // Yalnızca ön plandaki uygulamayı tazeler: mevcut geometri anlık görüntüsünü olduğu gibi
    // korur, ekran/Dock taraması yapmaz → uygulama geçişlerinde anında ve ucuz çalışır.
    func publishFrontOnly() {
        let e = currentEnv()
        let front = NSWorkspace.shared.frontmostApplication
        publishEnv(EnvSnapshot(
            screens: e.screens, primaryHeight: e.primaryHeight, orientation: e.orientation,
            autohide: e.autohide, dockTile: e.dockTile, magnification: e.magnification, front: front,
            frontBundlePath: front?.bundleURL?.standardizedFileURL.path,
            frontName: front?.localizedName,
            frontIsHidden: front?.isHidden ?? false))
    }

    // Tap callback'inin çalışacağı özel, yüksek öncelikli iş parçacığı. Kendi run loop'una sahiptir;
    // böylece ana iş parçacığı (menü kurma, modal alert) tıklama teslimini gateleyemez ve ana iş
    // parçacığı dolu olsa bile tap watchdog'u (tapDisabledByTimeout) daha az tetiklenir.
    func startTapThread() {
        let t = Thread {
            tapRunLoop = CFRunLoopGetCurrent()
            tapRunLoopReady.signal()
            let keepAlive = NSMachPort()                       // run loop boş kalıp dönmesin diye
            RunLoop.current.add(keepAlive, forMode: .common)
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        t.name = "DockToggle.eventtap"
        t.qualityOfService = .userInteractive
        t.start()
        tapRunLoopReady.wait()   // tapRunLoop yayımlanana kadar bekle (kaynak eklemeden önce)
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "dock.arrow.down.rectangle", accessibilityDescription: "DockToggle") {
                button.image = img
            } else {
                button.title = "⤓"
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        pauseMenuItem.target = self
        menu.addItem(pauseMenuItem)
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        hoverMenuItem.target = self
        menu.addItem(hoverMenuItem)
        thumbMenuItem.target = self
        menu.addItem(thumbMenuItem)
        let axItem = NSMenuItem(title: "Erişilebilirlik Ayarlarını Aç", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Çıkış", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        refreshMenuItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildEnv()
        syncState()
        refreshMenuItems()   // login durumu dahil tam tazeleme menü açılınca
    }

    var tapIsLive: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    // Tap/izin yönetimi + hafif durum güncellemesi. trusted'ı bir kez hesaplayıp paylaş (çift sorgu yok).
    func syncState() {
        let trusted = AXIsProcessTrusted()
        if trusted {
            if eventTap == nil {
                startTap()
            } else if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            if !MissionControlWatcher.shared.isRunning { MissionControlWatcher.shared.start() }
        } else {
            if eventTap != nil {
                teardownTap()       // izin sonradan kaldırıldı -> ölü tap'i bırak, menüyü düzelt
            }
            MissionControlWatcher.shared.stop()
        }
        updateActivationUI(trusted: trusted)
        syncHoverController(desired: UserDefaults.standard.object(forKey: "hoverPreviewsEnabled") as? Bool ?? false)
    }

    func startTap() {
        let mask = (UInt64(1) << UInt64(CGEventType.leftMouseDown.rawValue))
                 | (UInt64(1) << UInt64(CGEventType.leftMouseUp.rawValue))
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: eventTapCallback,
                                          userInfo: nil) else {
            if !tapFailureAlertShown {
                tapFailureAlertShown = true
                NSApp.activate(ignoringOtherApps: true)
                showAlert(title: "İzin Gerekli",
                          text: "DockToggle fare olaylarını dinleyemedi.\n\nSistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik'te DockToggle'ı açın.")
            }
            return
        }
        eventTap = tap
        tapFailureAlertShown = false
        // Kaynağı ÖZEL tap iş parçacığının run loop'una ekle (ana run loop'a değil).
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            runLoopSource = source
            if let rl = tapRunLoop {
                CFRunLoopAddSource(rl, source, .commonModes)
                CFRunLoopWakeUp(rl)
            }
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func teardownTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource, let rl = tapRunLoop {
            CFRunLoopRemoveSource(rl, source, .commonModes)
            CFRunLoopWakeUp(rl)
        }
        if let tap = eventTap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        eventTap = nil
        suppressNextLeftMouseUp = false
    }

    // Hafif: durum metni + ikon soluğu. trusted dışarıdan verilir (çift AXIsProcessTrusted çağrısını önler).
    func updateActivationUI(trusted: Bool = AXIsProcessTrusted()) {
        let live = trusted && tapIsLive
        let statusText: String
        if !trusted { statusText = "Erişilebilirlik izni gerekli" }
        else if !isEnabled { statusText = "Duraklatıldı" }
        else if live { statusText = "Aktif ✓" }
        else { statusText = "Etkin değil" }
        statusMenuItem.title = "DockToggle — \(statusText)"
        statusItem?.button?.appearsDisabled = !(live && isEnabled)
    }

    // Tam tazeleme (menü açılınca / eylemden sonra): login durumu dahil.
    func refreshMenuItems() {
        updateActivationUI()
        pauseMenuItem.state = isEnabled ? .on : .off
        switch SMAppService.mainApp.status {
        case .enabled:
            loginMenuItem.title = "Girişte Otomatik Başlat"
            loginMenuItem.state = .on
        case .requiresApproval:
            loginMenuItem.title = "Girişte Otomatik Başlat (onay bekliyor)"
            loginMenuItem.state = .mixed
        default:
            loginMenuItem.title = "Girişte Otomatik Başlat"
            loginMenuItem.state = .off
        }
        hoverMenuItem.state = (UserDefaults.standard.object(forKey: "hoverPreviewsEnabled") as? Bool ?? false) ? .on : .off
        refreshThumbMenuItem()
    }

    @objc func togglePause() {
        isEnabled.toggle()
        if !isEnabled { suppressNextLeftMouseUp = false }
        syncHoverController(desired: UserDefaults.standard.object(forKey: "hoverPreviewsEnabled") as? Bool ?? false)
        refreshMenuItems()
    }

    @objc func toggleHoverPreviews() {
        let now = !(UserDefaults.standard.object(forKey: "hoverPreviewsEnabled") as? Bool ?? false)
        UserDefaults.standard.set(now, forKey: "hoverPreviewsEnabled")
        syncHoverController(desired: now)
        refreshMenuItems()
    }

    // Controller yalnızca: özellik açık + Erişilebilirlik izni var + duraklatılmamış iken çalışır.
    func syncHoverController(desired: Bool) {
        let live = desired && AXIsProcessTrusted() && isEnabled
        hoverController.enabled = live
        hoverController.thumbnailsEnabled = thumbnailsPreference
        hoverMenuItem.state = desired ? .on : .off
        refreshThumbMenuItem()
    }

    var thumbnailsPreference: Bool {
        return UserDefaults.standard.object(forKey: "thumbnailsEnabled") as? Bool ?? true
    }

    // Küçük resimler ayrı bir izne (Ekran Kaydı) bağlı; menü öğesi durumu bunu yansıtır.
    func refreshThumbMenuItem() {
        let want = thumbnailsPreference
        if !WindowThumbnails.shared.isSupported {
            thumbMenuItem.title = "Küçük Resimler (macOS 14+ gerekli)"
            thumbMenuItem.state = .off
            thumbMenuItem.isEnabled = false
            return
        }
        thumbMenuItem.isEnabled = true
        if want && !WindowThumbnails.shared.hasPermission {
            thumbMenuItem.title = "Küçük Resimler (Ekran Kaydı izni gerekli)"
            thumbMenuItem.state = .mixed
        } else {
            thumbMenuItem.title = "Küçük Resimler"
            thumbMenuItem.state = want ? .on : .off
        }
    }

    @objc func toggleThumbnails() {
        let now = !thumbnailsPreference
        UserDefaults.standard.set(now, forKey: "thumbnailsEnabled")
        hoverController.thumbnailsEnabled = now
        if now && !WindowThumbnails.shared.hasPermission {
            // Sistem izin penceresini bir kez göster. TCC'de izin verildikten sonra yakalamanın
            // etkinleşmesi genellikle uygulamanın yeniden başlatılmasını gerektirir.
            WindowThumbnails.shared.requestPermission()
            showAlert(title: "Ekran Kaydı İzni Gerekli",
                      text: "Küçük resimler için Sistem Ayarları > Gizlilik ve Güvenlik > Ekran Kaydı'nda DockToggle'ı açın.\n\nİzni verdikten sonra DockToggle'ı yeniden başlatın.")
        }
        if !now { WindowThumbnails.shared.clearCache() }
        refreshMenuItems()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    showAlert(title: "Onay Gerekli",
                              text: "Otomatik başlatmayı tamamlamak için Sistem Ayarları > Genel > Giriş Öğeleri'nde DockToggle'ı açın.")
                }
            }
        } catch {
            showAlert(title: "Hata", text: "Giriş öğesi ayarlanamadı:\n\(error.localizedDescription)")
        }
        refreshMenuItems()
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

// MARK: - Giriş noktası

// Tek örnek koruması: aynı bundle ID ile başka kopya çalışıyorsa sessizce çık
// (doğrudan binary çalıştırma dahil — LSMultipleInstancesProhibited bunu yakalamaz).
if let bid = NSRunningApplication.current.bundleIdentifier {
    let mePID = NSRunningApplication.current.processIdentifier
    let dupes = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == bid && $0.processIdentifier != mePID
    }
    if !dupes.isEmpty { exit(0) }
}

ProcessInfo.processInfo.enableSuddenTermination()   // durumsuz ajan -> logout/restart'ı bekletme

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)   // Dock'ta kendi ikonu yok; sadece menü çubuğu
app.run()
