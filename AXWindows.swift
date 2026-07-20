import Cocoa
import ApplicationServices

// Bir Dock önizleme satırını temsil eden pencere. AX C-API'leri iş parçacığı-güvenlidir.
struct DockWindow {
    let title: String
    let element: AXUIElement
    let isMinimized: Bool
}

// Verilen uygulamanın (pid) AX pencerelerini listeler. Takılan uygulama donmasın diye
// mesaj timeout'u uygulanır. Başlıksız pencere "(başlıksız)" olarak işaretlenir.
func listWindows(pid: pid_t) -> [DockWindow] {
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, 0.05)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else { return [] }

    var result: [DockWindow] = []
    for win in windows {
        // Başlıksız pencereleri listeleme (ör. Finder her zaman açık olduğundan başlıksız bir
        // masaüstü/gizli pencere döndürebilir — kullanıcı gerçek pencere açmadıysa gösterme).
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { continue }
        var minRef: CFTypeRef?
        var minimized = false
        if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
           let m = minRef as? Bool {
            minimized = m
        }
        result.append(DockWindow(title: title, element: win, isMinimized: minimized))
    }
    return result
}

// Pencereyi öne getirir: minimize ise geri açar, AXRaise uygular ve uygulamayı aktive eder.
func raiseWindow(_ window: DockWindow, app: NSRunningApplication) {
    AXUIElementSetMessagingTimeout(window.element, 0.05)
    if window.isMinimized {
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    app.activate(options: [.activateIgnoringOtherApps])
}

// Pencerenin kapat düğmesini (kAXCloseButton) bulup AXPress uygular.
func closeWindow(_ window: DockWindow) {
    AXUIElementSetMessagingTimeout(window.element, 0.05)
    var btnRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(window.element, kAXCloseButtonAttribute as CFString, &btnRef) == .success,
       let btn = btnRef, CFGetTypeID(btn) == AXUIElementGetTypeID() {
        AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
    }
}
