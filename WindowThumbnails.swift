import Cocoa
import ScreenCaptureKit

// Pencere küçük resimleri (Windows görev çubuğu önizlemesi benzeri).
//
// Kaynak: ScreenCaptureKit (macOS 14+). Eski CGWindowListCreateImage yolu macOS 14'te
// kullanımdan kaldırıldı ve yeni sürümlerde izinsiz boş görüntü döndürüyor; bu yüzden
// yalnızca SCK kullanılır, 14 öncesinde küçük resim gösterilmez (satırlar yalnızca metin).
//
// İZİN: Ekran Kaydı (TCC). Erişilebilirlikten AYRI bir izindir ve verilene kadar yakalama
// başarısız olur — bu durumda panel sessizce metin görünümüne düşer, hata kutusu çıkmaz.
//
// Maliyet: yakalama tamamen asenkrondur ve ana thread'i bloklamaz. Sonuçlar kısa ömürlü bir
// önbellekte tutulur; aynı pencereye tekrar hover edildiğinde küçük resim anında görünür.
final class WindowThumbnails {
    static let shared = WindowThumbnails()

    // Yalnızca ana thread'den erişilir. CGImage tutulur: katman (CALayer) doğrudan onu
    // "resizeAspectFill" ile çizebiliyor.
    private var cache: [CGWindowID: (image: CGImage, at: TimeInterval)] = [:]
    private var inFlight: Set<CGWindowID> = []
    private let ttl: TimeInterval = 3.0
    private let maxCacheEntries = 60

    // Panel KÜÇÜK BİR KARE'dir: önizleme kutusu kare, görüntü kutuyu "cover" ile doldurur
    // (oran korunur, taşan kısım kırpılır) → pencerenin oranı ne olursa olsun kutunun
    // etrafında hiç boşluk kalmaz.
    static let panelWidth: CGFloat = 200
    static let targetWidth: CGFloat = 176     // yakalama çözünürlüğü hedefi (kutu genişliği)

    var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    // Ekran Kaydı izni verilmiş mi? (prompt göstermez)
    var hasPermission: Bool { return CGPreflightScreenCaptureAccess() }

    // Sistem iznini bir kez ister. İzin verilmesi uygulamanın yeniden başlatılmasını gerektirebilir
    // (macOS TCC davranışı); bu yüzden çağıran taraf kullanıcıyı bilgilendirir.
    @discardableResult
    func requestPermission() -> Bool { return CGRequestScreenCaptureAccess() }

    func cachedImage(for id: CGWindowID) -> CGImage? {
        guard let entry = cache[id] else { return nil }
        guard ProcessInfo.processInfo.systemUptime - entry.at < ttl else { return nil }
        return entry.image
    }

    // Bir panelin TÜM pencereleri için küçük resimleri ister (ANA THREAD'den çağrılır).
    // Pencere listesi bir KEZ çekilir (pencere başına ayrı çekim pahalıydı); her görüntü hazır
    // oldukça completion ana thread'de, o pencerenin kimliğiyle çağrılır.
    func thumbnails(for ids: [CGWindowID], completion: @escaping (CGWindowID, CGImage) -> Void) {
        guard isSupported, hasPermission else { return }
        var needed: [CGWindowID] = []
        for id in ids {
            if let cached = cachedImage(for: id) { completion(id, cached); continue }
            guard !inFlight.contains(id) else { continue }
            inFlight.insert(id)
            needed.append(id)
        }
        guard !needed.isEmpty else { return }
        guard #available(macOS 14.0, *) else { needed.forEach { inFlight.remove($0) }; return }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
            [weak self] content, error in
            guard let self = self else { return }
            guard let content = content, error == nil else {
                DispatchQueue.main.async { needed.forEach { self.inFlight.remove($0) } }
                return
            }
            let wanted = Set(needed)
            let targets = content.windows.filter { wanted.contains($0.windowID) }
            let missing = wanted.subtracting(targets.map { $0.windowID })
            if !missing.isEmpty {
                DispatchQueue.main.async { missing.forEach { self.inFlight.remove($0) } }
            }
            for window in targets {
                let id = window.windowID
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                // Yakalama çözünürlüğü: panel genişliğinin 2 katı (Retina) ile sınırlı.
                let scale = min(1.0, (WindowThumbnails.targetWidth * 2) / max(window.frame.width, 1))
                config.width = max(1, Int(window.frame.width * scale))
                config.height = max(1, Int(window.frame.height * scale))
                config.showsCursor = false
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                    DispatchQueue.main.async {
                        self.inFlight.remove(id)
                        guard let cg = image else { return }
                        self.store(cg, for: id)
                        completion(id, cg)
                    }
                }
            }
        }
    }

    private func store(_ image: CGImage, for id: CGWindowID) {
        cache[id] = (image, ProcessInfo.processInfo.systemUptime)
        guard cache.count > maxCacheEntries else { return }
        // Basit budama: en eski yarıyı at.
        let sorted = cache.sorted { $0.value.at < $1.value.at }
        for (key, _) in sorted.prefix(cache.count / 2) { cache.removeValue(forKey: key) }
    }

    func clearCache() { cache.removeAll() }
}
