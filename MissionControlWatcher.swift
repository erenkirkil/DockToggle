import Cocoa
import ApplicationServices

// MARK: - Mission Control / App Exposé durumu
// Dock'a bir AXObserver takıp Dock.app'in yayımladığı belgesiz "Exposé" bildirimlerini
// dinleriz. Yalnızca ERİŞİLEBİLİRLİK izni kullanır — Ekran Kaydı GEREKTİRMEZ. Bayrak,
// tap iş parçacığı tarafından yalnızca okunur; MC geçişlerinde (ana runloop) yazılır.
// (Aynı teknik yabai ve AltTab tarafından da kullanılır.)

private let mcLock = NSLock()
private var _mcActive = false

// Tap iş parçacığından çağrılır: yalnızca kilitli bir Bool okur (hızlı, bloklamaz).
func missionControlActive() -> Bool { mcLock.lock(); defer { mcLock.unlock() }; return _mcActive }
private func setMissionControlActive(_ v: Bool) { mcLock.lock(); _mcActive = v; mcLock.unlock() }

// Dock.app'in yayımladığı belgesiz bildirim adları — tek belgesiz kısım bunlar (SPI değil, düz string).
private let kAXExposeShowAllWindows   = "AXExposeShowAllWindows"    // Mission Control (F3)
private let kAXExposeShowFrontWindows = "AXExposeShowFrontWindows"  // App Exposé
private let kAXExposeShowDesktop      = "AXExposeShowDesktop"       // Masaüstünü Göster
private let kAXExposeExit             = "AXExposeExit"              // kapandı → normal
private let mcNotificationNames = [kAXExposeShowAllWindows, kAXExposeShowFrontWindows,
                                   kAXExposeShowDesktop, kAXExposeExit]

// @convention(c) callback: yalnızca globalleri kullanır (bağlam yakalamaz).
private let mcObserverCallback: AXObserverCallback = { _, _, notification, _ in
    switch notification as String {
    case kAXExposeShowAllWindows, kAXExposeShowFrontWindows, kAXExposeShowDesktop:
        // Mission Control / App Exposé / Masaüstünü Göster → tıklama gizlemesin, uygulamayı
        // öne getirsin (kullanıcı tercihi: üçünde de öne-getir davranışı).
        setMissionControlActive(true)
    default:
        // AXExposeExit → normal masaüstü; gizleme davranışı yeniden etkin.
        setMissionControlActive(false)
    }
}

// Mission Control / App Exposé durumunu Dock'a AXObserver takarak izler (yalnızca ana thread).
// Bildirimler ileride yeniden adlandırılırsa bayrak false kalır (fail-open) → gizleme bugünkü
// gibi çalışmaya devam eder; "takılı-true" yanlış-pozitifi oluşmaz.
final class MissionControlWatcher {
    static let shared = MissionControlWatcher()

    private var observer: AXObserver?
    private var element: AXUIElement?          // AXUIElement'i canlı tut (bildirimler bağlı)
    private var relaunchObserverInstalled = false

    var isRunning: Bool { observer != nil }

    // Ana thread'de, Erişilebilirlik izni verildikten sonra çağrılır. Idempotent değildir:
    // her çağrı önce mevcut observer'ı söker, sonra güncel Dock pid'iyle yeniden kurar.
    func start() {
        guard AXIsProcessTrusted() else { return }
        teardownObserver()
        guard let dock = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let pid = dock.processIdentifier
        let el = AXUIElementCreateApplication(pid)
        var obs: AXObserver?
        guard AXObserverCreate(pid, mcObserverCallback, &obs) == .success, let observer = obs else { return }
        for name in mcNotificationNames {
            _ = AXObserverAddNotification(observer, el, name as CFString, nil)  // adı yoksa sessizce atlanır
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = observer
        self.element = el
        setMissionControlActive(false)   // başlangıçta pasif varsay; observer geçişleri yakalar

        // Dock yeniden başlarsa (yeni pid) observer bayatlar → yeniden kur (bir kez kaydet).
        if !relaunchObserverInstalled {
            relaunchObserverInstalled = true
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == "com.apple.dock" { self?.start() }
            }
        }
    }

    func stop() {
        teardownObserver()
        setMissionControlActive(false)
    }

    private func teardownObserver() {
        if let observer = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        element = nil
    }
}
