import Cocoa
import ApplicationServices

// Dock ikonlarında hover'ı algılayıp önizleme panelini yöneten denetleyici (yalnızca ana thread).
// Yaklaşım A: Ağır bir CGEventTap DEĞİL; hafif global monitör yalnızca imleci kabaca izler,
// AX/poll işi yalnızca imleç Dock'a yakınken çalışır → boştayken sıfır maliyet.
final class HoverPreviewController {
    private let panel = PreviewPanel()
    private var moveMonitor: Any?
    private var pollTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?

    private var hoveredBundlePath: String?     // panelin şu an gösterdiği uygulama
    private var dwellDeadline: Date?           // aynı ikon üstünde bekleme başlangıcı
    private var pendingBundlePath: String?     // dwell'i bekleyen aday uygulama
    private var lastAnchor: NSRect?
    private var lastScreen: NSScreen?

    var enabled: Bool = false {
        didSet {
            guard enabled != oldValue else { return }
            enabled ? start() : stop()
        }
    }

    // Hafif global izleyici: yalnızca imleç hareketini kabaca yakalar, Dock'a yakınsa poll başlatır.
    func start() {
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.maybeStartPolling()
        }
        maybeStartPolling()
    }

    func stop() {
        if let m = moveMonitor { NSEvent.removeMonitor(m); moveMonitor = nil }
        pollTimer?.invalidate(); pollTimer = nil
        cancelPendingHide()
        panel.dismiss()
        hoveredBundlePath = nil; pendingBundlePath = nil; dwellDeadline = nil
    }

    // İmleç Dock şeridine yakınsa 15 Hz poll'u başlat (zaten çalışıyorsa dokunma).
    private func maybeStartPolling() {
        guard pollTimer == nil else { return }
        guard nearDock() else { return }
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    // İmlecin Quartz konumunu mevcut clickMightBeOnDock mantığıyla değerlendir.
    private func nearDock() -> Bool {
        let env = currentEnv()
        let appKit = NSEvent.mouseLocation
        // AppKit (alt-orijin) -> Quartz (üst-orijin) çevrimi clickMightBeOnDock beklentisine uygun.
        let quartz = CGPoint(x: appKit.x, y: env.primaryHeight - appKit.y)
        return clickMightBeOnDock(quartz, env)
    }

    // 15 Hz: Dock'tan uzaklaşınca poll'u durdur; ikon üstündeyse dwell/panel yönet.
    private func poll() {
        let env = currentEnv()
        let appKit = NSEvent.mouseLocation
        let quartz = CGPoint(x: appKit.x, y: env.primaryHeight - appKit.y)

        if !clickMightBeOnDock(quartz, env) {
            // Dock dışında: imleç panelin üstündeyse gizlemeyi iptal et (panel kalsın);
            // ne dock'ta ne panelde ise hızlı gizle; panel kapalıysa poll'u durdur.
            if panel.isVisible && panel.isMouseInside { cancelPendingHide() }
            else if panel.isVisible { scheduleHide() }
            else { pollTimer?.invalidate(); pollTimer = nil }
            pendingBundlePath = nil; dwellDeadline = nil
            return
        }

        cancelPendingHide()
        guard let item = dockAppItem(at: quartz), let path = item.bundlePath else {
            pendingBundlePath = nil; dwellDeadline = nil
            return
        }
        if path == hoveredBundlePath { return }             // zaten bu uygulamanın paneli açık

        if path != pendingBundlePath {                       // yeni aday → dwell sayacını başlat
            pendingBundlePath = path
            dwellDeadline = Date().addingTimeInterval(0.35)
            return
        }
        if let dl = dwellDeadline, Date() >= dl {            // dwell doldu → paneli göster
            presentPanel(forBundlePath: path)
        }
    }

    private func presentPanel(forBundlePath path: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL.path == path
        }) else { return }
        let windows = listWindows(pid: app.processIdentifier)
        guard !windows.isEmpty else {                        // penceresiz/tam ekran → panel yok
            panel.dismiss()
            hoveredBundlePath = nil
            return
        }
        guard let anchor = dockIconFrame(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        else { return }

        lastAnchor = anchor
        lastScreen = screen

        panel.show(windows: windows, appIcon: app.icon, anchor: anchor, on: screen,
                   orientation: currentEnv().orientation,
                   onSelect: { [weak self] w in raiseWindow(w, app: app); self?.panel.dismiss(); self?.hoveredBundlePath = nil },
                   onClose: { [weak self] w in closeWindow(w); self?.refreshOrDismiss(app: app) })
        hoveredBundlePath = path
    }

    // × sonrası: kalan pencere varsa paneli tazele, yoksa kapat.
    private func refreshOrDismiss(app: NSRunningApplication) {
        let windows = listWindows(pid: app.processIdentifier)
        if windows.isEmpty { panel.dismiss(); hoveredBundlePath = nil; return }
        guard let anchor = lastAnchor, let screen = lastScreen else { return }
        panel.show(windows: windows, appIcon: app.icon, anchor: anchor, on: screen,
                   orientation: currentEnv().orientation,
                   onSelect: { [weak self] w in raiseWindow(w, app: app); self?.panel.dismiss(); self?.hoveredBundlePath = nil },
                   onClose: { [weak self] w in closeWindow(w); self?.refreshOrDismiss(app: app) })
    }

    private func scheduleHide() {
        guard hideWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if !self.panel.isMouseInside {
                self.panel.dismiss(); self.hoveredBundlePath = nil
                self.pollTimer?.invalidate(); self.pollTimer = nil
            }
            self.hideWorkItem = nil
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
    private func cancelPendingHide() { hideWorkItem?.cancel(); hideWorkItem = nil }

    // İkonun ekran çerçevesini AX ile bulur (panel konumu için). Bulunamazsa nil.
    private func dockIconFrame() -> NSRect? {
        let appKit = NSEvent.mouseLocation
        let quartz = CGPoint(x: appKit.x, y: currentEnv().primaryHeight - appKit.y)
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.05)
        var elRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(quartz.x), Float(quartz.y), &elRef) == .success,
              var el = elRef else { return nil }
        for _ in 0..<4 {
            var subRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subRef) == .success,
               let sub = subRef as? String, sub == "AXApplicationDockItem" {
                var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
                var pos = CGPoint.zero; var size = CGSize.zero
                if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
                   let pr = posRef, CFGetTypeID(pr) == AXValueGetTypeID(),
                   AXValueGetValue(pr as! AXValue, .cgPoint, &pos),
                   AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
                   let sr = sizeRef, CFGetTypeID(sr) == AXValueGetTypeID(),
                   AXValueGetValue(sr as! AXValue, .cgSize, &size) {
                    // AX konumu üst-orijin (Quartz). AppKit alt-orijine çevir.
                    let h = currentEnv().primaryHeight
                    return NSRect(x: pos.x, y: h - pos.y - size.height, width: size.width, height: size.height)
                }
                return nil
            }
            var parRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parRef) == .success,
               let par = parRef, CFGetTypeID(par) == AXUIElementGetTypeID() {
                el = par as! AXUIElement
            } else { break }
        }
        return nil
    }
}
