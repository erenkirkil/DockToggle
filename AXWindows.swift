import Cocoa
import ApplicationServices

// Bir Dock önizleme satırını temsil eden pencere. AX C-API'leri iş parçacığı-güvenlidir.
struct DockWindow {
    let title: String
    let element: AXUIElement
    let isMinimized: Bool
    // Pencere geçerli Space'te ekranda mı? Başka Space'teki bir pencereyi öne getirmek Space'i
    // kaydırır ve peek bitince geri gelmez → o pencereler peek dışı bırakılır.
    let isOnCurrentSpace: Bool
    // Ekranda eşleşen CGWindowID (küçük resim yakalaması için). Simge durumundaki ya da
    // eşleştirilemeyen pencerelerde nil.
    let windowID: CGWindowID?
    // Pencerenin en/boy oranı. Panel genişliği küçük resmin genişliğine göre belirlendiğinden
    // GÖRÜNTÜ GELMEDEN önce bilinmesi gerekir; AX çerçevesinden okunur.
    let aspectRatio: CGFloat?
}

// Arka plan kuyruğunda koşan pencere işleri için timeout: ana thread'i bloklamadığından cömert
// olabilir (eski 0.05 s meşgul uygulamaların pencerelerini listeden sessizce düşürüyordu).
let axMessageTimeout: Float = 0.25
// ANA THREAD ve tap iş parçacığındaki Dock sorguları için kısa timeout (donma yaratmasın).
// Bu değer aynı zamanda süreç-global varsayılan olarak uygulama açılışında bir kez set edilir.
let axQuickTimeout: Float = 0.05

// Verilen uygulamanın (pid) AX pencerelerini listeler. Başlık okuması TIMEOUT'a düşerse pencere
// listeden düşürülmez, "(başlıksız)" olarak işaretlenir; yalnızca gerçekten boş başlıklı pencereler
// atlanır (ör. Finder'ın her zaman var olan masaüstü penceresi).
// appIsHidden: ⌘H ile gizlenmiş uygulamanın pencereleri CGWindowList'te EKRANDA görünmez; bu
// durumda Space testi anlamsızdır ve peek'i sessizce ölü bırakırdı → gizliyse test atlanır.
// Dönüş: nil = AX SORGUSU BAŞARISIZ (timeout/erişilemez) — geçici sayılmalı;
//        [] = uygulamanın gerçekten (gösterilebilir) penceresi yok — kalıcı sayılmalı.
func listWindows(pid: pid_t, appIsHidden: Bool) -> [DockWindow]? {
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, axMessageTimeout)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else { return nil }

    // Eşleşen her ekran kaydı TÜKETİLİR: aynı uygulamanın farklı Space'lerdeki eş boyutlu
    // (ör. ikisi de zoom'lanmış) pencerelerinden yalnızca biri "bu Space'te" sayılabilsin.
    var onScreen = onScreenWindowFrames(pid: pid)

    var result: [DockWindow] = []
    for win in windows {
        // Timeout'u çocuk elemana AÇIKÇA uygula: axApp'e verilen değer ondan kopyalanan
        // elemanlara miras kalmaz (aksi halde süreç-global 6 s varsayılanına düşülür).
        AXUIElementSetMessagingTimeout(win, axMessageTimeout)

        var titleRef: CFTypeRef?
        let titleErr = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        let title: String
        if titleErr == .success {
            guard let t = titleRef as? String, !t.isEmpty else { continue }  // gerçekten başlıksız -> gösterme
            title = t
        } else {
            title = "(başlıksız)"   // timeout/hata -> pencereyi kaybetme
        }

        var minRef: CFTypeRef?
        var minimized = false
        if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
           let m = minRef as? Bool {
            minimized = m
        }

        // Space testi yalnızca ekranda olabilecek pencereler için anlamlı; minimize olan zaten değil.
        let frame = minimized ? nil : windowFrame(win)
        var aspect: CGFloat?
        if let f = frame, f.width > 0, f.height > 0 { aspect = f.width / f.height }

        var onCurrentSpace = false
        var windowID: CGWindowID?
        if !minimized {
            if let f = frame,
               let idx = onScreen.firstIndex(where: { rectsRoughlyEqual($0.frame, f) }) {
                windowID = onScreen[idx].id        // küçük resim yakalaması için kesin kimlik
                onScreen.remove(at: idx)           // tüket: ikinci eş pencere aynı kaydı kullanamasın
                onCurrentSpace = true
            } else if appIsHidden {
                onCurrentSpace = true              // gizli uygulamada test yapılamaz; peek'i engelleme
            }
        }

        result.append(DockWindow(title: title, element: win, isMinimized: minimized,
                                 isOnCurrentSpace: onCurrentSpace, windowID: windowID,
                                 aspectRatio: aspect))
    }
    return result
}

// Pencerenin AX çerçevesi (Quartz üst-orijin). Space eşleştirmesi için kullanılır.
private func windowFrame(_ win: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
    var pos = CGPoint.zero; var size = CGSize.zero
    guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
          let pr = posRef, CFGetTypeID(pr) == AXValueGetTypeID(),
          AXValueGetValue(pr as! AXValue, .cgPoint, &pos),
          AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let sr = sizeRef, CFGetTypeID(sr) == AXValueGetTypeID(),
          AXValueGetValue(sr as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: pos, size: size)
}

// Geçerli Space'te EKRANDA olan pencerelerin (kimlik, çerçeve) listesi. Yalnızca pid + geometri
// okur — pencere BAŞLIĞI okunmadığı için Ekran Kaydı izni GEREKTİRMEZ.
private func onScreenWindowFrames(pid: pid_t) -> [(id: CGWindowID, frame: CGRect)] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return [] }
    var frames: [(id: CGWindowID, frame: CGRect)] = []
    for info in list {
        guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
              let number = info[kCGWindowNumber as String] as? CGWindowID,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
        frames.append((id: number, frame: rect))
    }
    return frames
}

// AX ve CGWindowList çerçeveleri aynı pencerede birkaç noktaya kadar ayrışabilir.
private func rectsRoughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
    let t: CGFloat = 4
    return abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t
        && abs(a.width - b.width) <= t && abs(a.height - b.height) <= t
}

// MARK: - Öne getirme

// Yalnızca AX raise (uygulama aktivasyonu YOK) — arka plan kuyruğundan çağrılabilir.
// Peek ve peek sonrası Z-sırası onarımı bunu kullanır; minimize durumuna ASLA dokunmaz.
func raiseElement(_ element: AXUIElement) {
    AXUIElementSetMessagingTimeout(element, axMessageTimeout)
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
}

// Simge durumundan geri açar. Peek yolunda da kullanılır; peek biterken minimizeElement ile
// geri alınır, böylece hover kalıcı bir düzen değişikliği bırakmaz.
func unminimizeElement(_ element: AXUIElement) {
    AXUIElementSetMessagingTimeout(element, axMessageTimeout)
    AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
}

// Pencereyi yeniden simge durumuna alır (peek sonrası geri yükleme).
func minimizeElement(_ element: AXUIElement) {
    AXUIElementSetMessagingTimeout(element, axMessageTimeout)
    AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
}

// Uygulamayı öne getirir (ANA THREAD). macOS 14+ "işbirlikçi aktivasyon" altında activate()
// isteği sessizce reddedilebildiğinden AX üzerinden kAXFrontmost da set edilir; AX yolu bu
// kısıtlamadan etkilenmez. (activateIgnoringOtherApps macOS 14+'ta etkisiz olduğu için kullanılmaz.)
func activateApp(_ app: NSRunningApplication) {
    app.activate()
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, axQuickTimeout)   // ana thread: kısa timeout
    AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
}

// Uygulamanın o anki odaklı penceresi — peek öncesi Z-sırasını saklamak için.
func focusedWindow(pid: pid_t) -> AXUIElement? {
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, axMessageTimeout)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
          let r = ref, CFGetTypeID(r) == AXUIElementGetTypeID() else { return nil }
    return (r as! AXUIElement)
}

// Pencerenin kapat düğmesini (kAXCloseButton) bulup AXPress uygular.
func closeWindow(_ window: DockWindow) {
    AXUIElementSetMessagingTimeout(window.element, axMessageTimeout)
    var btnRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(window.element, kAXCloseButtonAttribute as CFString, &btnRef) == .success,
       let btn = btnRef, CFGetTypeID(btn) == AXUIElementGetTypeID() {
        let button = btn as! AXUIElement
        AXUIElementSetMessagingTimeout(button, axMessageTimeout)
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }
}

// MARK: - Dock ikonu geometrisi

// İmlecin altındaki Dock ikonunun ekran çerçevesini AX ile bulur (panel konumu için).
// Saf AX + değişmez parametreler kullanır -> arka plan kuyruğundan çağrılabilir.
// Dönen dikdörtgen AppKit (alt-orijin) koordinatlarındadır.
func dockIconFrame(atQuartz point: CGPoint, primaryHeight: CGFloat) -> NSRect? {
    // system-wide elemana timeout YAZILMAZ: süreç-global varsayılanı değiştirir (bkz. main.swift).
    // Bu ilk çağrı kısa global varsayılanı kullandığından Dock anlık meşgulse zaman aşımına
    // düşebilir; panel gereksiz yere kapanmasın diye bir kez yeniden denenir.
    let systemWide = AXUIElementCreateSystemWide()
    var elRef: AXUIElement?
    var hit = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elRef)
    if hit != .success {
        hit = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elRef)
    }
    guard hit == .success, var el = elRef else { return nil }
    for _ in 0..<4 {
        AXUIElementSetMessagingTimeout(el, axMessageTimeout)
        var subRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subRef) == .success,
           let sub = subRef as? String, sub == "AXApplicationDockItem" {
            guard let frame = windowFrame(el) else { return nil }   // AX pos/size okuması ortak
            // AX konumu üst-orijin (Quartz). AppKit alt-orijine çevir.
            return NSRect(x: frame.minX, y: primaryHeight - frame.minY - frame.height,
                          width: frame.width, height: frame.height)
        }
        var parRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parRef) == .success,
           let par = parRef, CFGetTypeID(par) == AXUIElementGetTypeID() {
            el = par as! AXUIElement
        } else { break }
    }
    return nil
}
