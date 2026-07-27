import Cocoa

// İkonun üstünde beliren, aktivasyon çalmayan (non-activating) yüzen panel.
// Her satır: uygulama ikonu + pencere başlığı + sağda kapat (×) düğmesi.
// Peek izleme SATIR düzeyindedir (PeekRow) → kullanıcı ×'e uzanırken peek bozulmaz;
// vurgu ve tıklama hücre düzeyindedir (HoverCell).
final class PreviewPanel: NSPanel {
    // Kaydırma görünümünün belge görünümü FLIPPED olmalı: aksi halde taşan içerikte panel,
    // ilk satırlar görünür alanın üstünde kalacak şekilde (ortadan) açılıyordu.
    private final class FlippedStackView: NSStackView {
        override var isFlipped: Bool { true }
    }

    private struct RowEntry {
        let row: PeekRow
        let content: HoverCell
        let close: HoverCell
        let thumb: ThumbView
        let window: DockWindow
    }

    private let stack = FlippedStackView()
    private let scroll = NSScrollView()
    private var entries: [RowEntry] = []
    private var anchorRect: NSRect = .zero
    private var showThumbnails = false

    private var onSelect: ((DockWindow) -> Void)?
    private var onClose: ((DockWindow) -> Void)?
    private var onPeek: ((DockWindow) -> Void)?
    private var onPeekEnd: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        // Tam ekran uygulamanın Space'inde ve diğer masaüstlerinde de görünsün.
        // (.stationary kullanılmaz: panel Mission Control açılınca zaten kapatılıyor.)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let visual = NSVisualEffectView()
        visual.material = .menu
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 10
        visual.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading   // satırlar sola hizalansın; genişlik ayrıca sabitlenir
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Çok pencereli uygulamalarda panel ekran dışına taşmasın: yükseklik sınırlanır, taşarsa kaydırılır.
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        visual.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: visual.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            // Dikey kaydırma için: alt kenar bağlanmaz, yükseklik içeriğe göre serbest kalır.
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        contentView = visual
    }

    // İmleç panelde mi, yoksa ikon ile panel arasındaki koridorda mı? Panel ikondan 8pt boşlukla
    // durduğu için yalnızca frame'e bakmak, kullanıcı panele geçerken panelin kaçmasına yol açıyordu.
    var mouseIsInsideOrOnPath: Bool {
        let p = NSEvent.mouseLocation
        if frame.insetBy(dx: -4, dy: -4).contains(p) { return true }
        guard !anchorRect.isEmpty else { return false }
        return anchorRect.union(frame).insetBy(dx: -2, dy: -2).contains(p)
    }

    // Pencereleri gösterir ve paneli Dock yönüne göre ikonun (anchor) yanında/üstünde konumlar.
    // orientation: "left" (Dock solda → panel sağda), "right" (Dock sağda → panel solda),
    // diğer/"bottom" (Dock altta → panel üstte).
    func show(windows: [DockWindow], appIcon: NSImage?, anchor: NSRect, on screen: NSScreen,
              orientation: String, showThumbnails: Bool,
              onSelect: @escaping (DockWindow) -> Void,
              onClose: @escaping (DockWindow) -> Void,
              onPeek: @escaping (DockWindow) -> Void,
              onPeekEnd: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.onPeek = onPeek
        self.onPeekEnd = onPeekEnd
        self.showThumbnails = showThumbnails
        // Aynı ikon için yeniden çizim mi? (× ile satır kapatma, içerik tazeleme)
        let isRedraw = isVisible && anchorRect == anchor
        let previousTop = frame.maxY
        let previousHeight = frame.height
        let previousScrollY = scroll.contentView.bounds.origin.y
        self.anchorRect = anchor

        // Genişlik satırlardan ÖNCE hesaplanır: önizleme kutusunun yüksekliği, doldurduğu
        // genişlikten ve pencerenin oranından türetiliyor.
        let width = panelWidth(for: windows)
        let rowWidth = width - 12          // satır, yığın genişliğinden 12pt dar

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entries.removeAll()
        for w in windows {
            let entry = makeRow(window: w, icon: appIcon, rowWidth: rowWidth)
            stack.addArrangedSubview(entry.row)
            // Her satır panel genişliğini (insetler hariç) doldursun → × hep en sağa yaslı kalır.
            entry.row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
            entries.append(entry)
        }
        layoutIfNeeded()

        let vf = screen.visibleFrame
        let gap: CGFloat = 8
        let maxHeight = max(120, vf.height - 2 * gap)
        let contentHeight = stack.fittingSize.height
        setContentSize(NSSize(width: width, height: min(contentHeight, maxHeight)))
        if isRedraw {
            // Yeniden çizimde kaydırma konumu KORUNUR: başa sarmak, kullanıcı listede aşağıdayken
            // imlecin altındaki satırı bambaşka bir pencereye dönüştürürdü. Yeni içeriğe kırpılır.
            let maxScroll = max(0, contentHeight - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(previousScrollY, maxScroll)))
        } else {
            // Yeni panel: kaydırma konumu önceki gösterimden taşınabiliyor → başa sar.
            scroll.contentView.scroll(to: .zero)
        }
        scroll.reflectScrolledClipView(scroll.contentView)

        // Dock yönüne göre konumla; ardından ekran içine sıkıştır.
        let h = frame.height
        var x: CGFloat
        var y: CGFloat
        switch orientation {
        case "left":   // Dock solda → panel ikonun SAĞINDA, dikeyde ortalı
            x = anchor.maxX + gap
            y = anchor.midY - h / 2
        case "right":  // Dock sağda → panel ikonun SOLUNDA, dikeyde ortalı
            x = anchor.minX - width - gap
            y = anchor.midY - h / 2
        default:       // bottom → panel ikonun ÜSTÜNDE, yatayda ortalı
            x = anchor.midX - width / 2
            y = anchor.maxY + gap
        }
        // Yeniden çizimde ÜST kenar sabit tutulur: satırlar yukarıdan dizildiği için kalan satırlar
        // yerinde kalır ve panel, imlecin altından kaçıp kaybolmaz (× ile arka arkaya kapatma).
        // Yalnızca KÜÇÜLMEDE: içerik büyürse panel aşağı doğru genişleyip Dock ikonunun üstüne inerdi.
        if isRedraw && h <= previousHeight { y = previousTop - h }
        x = min(max(x, vf.minX + 4), vf.maxX - width - 4)
        y = min(max(y, vf.minY + 4), vf.maxY - h - 4)
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
        syncHoverToMouse()
    }

    func dismiss() {
        orderOut(nil)
        // Satırlar da sökülür: aksi halde panel kapalıyken bile AXUIElement referansları tutulurdu.
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entries.removeAll()
        anchorRect = .zero
    }

    // AppKit, imleç ZATEN alanın içindeyken yeni kurulan tracking area için mouseEntered ÜRETMEZ.
    // Panel her show()'da satırları yeniden kurduğundan (ör. × sonrası tazeleme), imlecin altındaki
    // satırın hover/peek durumunu elle tetiklemezsek panel imleç oynatılana kadar "ölü" kalırdı.
    private func syncHoverToMouse() {
        let p = NSEvent.mouseLocation
        if frame.contains(p) {
            for e in entries where e.row.containsScreenPoint(p) {
                e.content.setHovered(e.content.containsScreenPoint(p))
                e.close.setHovered(e.close.containsScreenPoint(p))
                onPeek?(e.window)
                return
            }
        }
        // İmleç hiçbir satırın üstünde değil: sökülen satır mouseExited üretmediği için peek'i
        // burada bitirmezsek önceki pencere kalıcı olarak öne çekilmiş kalırdı.
        onPeekEnd?()
    }

    // Panel genişliği. Küçük resim varken Windows görev çubuğu önizlemesi gibi davranır: panel
    // SABİT ve dar bir genişliktedir, önizleme bu genişliği TAMAMEN doldurur, yüksekliğini
    // pencerenin oranından alır. (Önce yüksekliği sabitleyip genişliği orandan türetmek,
    // görüntünün iki yanında boşluk bırakıyordu.)
    private func panelWidth(for windows: [DockWindow]) -> CGFloat {
        guard showThumbnails, windows.contains(where: { $0.windowID != nil }) else { return 250 }
        return WindowThumbnails.panelWidth
    }

    // Küçük resim geldiğinde ilgili satırı günceller (yakalama asenkron olduğu için sonradan gelir).
    func setThumbnail(_ image: CGImage, forWindowID id: CGWindowID) {
        for e in entries where e.window.windowID == id {
            e.thumb.setImage(image)
            return
        }
    }

    // Satır = peek izleyen kapsayıcı (PeekRow) + başlık satırı (ikon + başlık | ×) ve altında
    // pencerenin küçük resmi. Küçük resme tıklamak da pencereyi öne getirir.
    private func makeRow(window: DockWindow, icon: NSImage?, rowWidth: CGFloat) -> RowEntry {
        // Sol hücre: ikon + başlık → öne getir (mavi vurgu).
        let iconView = NSImageView()
        iconView.image = icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(labelWithString: window.isMinimized ? "\(window.title) (simge)" : window.title)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let contentInner = NSStackView(views: [iconView, label])
        contentInner.orientation = .horizontal
        contentInner.spacing = 6
        contentInner.translatesAutoresizingMaskIntoConstraints = false

        let contentCell = HoverCell(highlight: .selectedContentBackgroundColor,
                                    onClick: { [weak self] in self?.onSelect?(window) })
        contentCell.translatesAutoresizingMaskIntoConstraints = false
        contentCell.addSubview(contentInner)
        NSLayoutConstraint.activate([
            contentInner.leadingAnchor.constraint(equalTo: contentCell.leadingAnchor, constant: 8),
            contentInner.trailingAnchor.constraint(equalTo: contentCell.trailingAnchor, constant: -8),
            contentInner.topAnchor.constraint(equalTo: contentCell.topAnchor, constant: 5),
            contentInner.bottomAnchor.constraint(equalTo: contentCell.bottomAnchor, constant: -5),
        ])

        // Sağ hücre: × → pencereyi kapat (kırmızımsı vurgu), sabit genişlik.
        let closeLabel = NSTextField(labelWithString: "✕")
        closeLabel.alignment = .center
        closeLabel.textColor = .secondaryLabelColor
        closeLabel.translatesAutoresizingMaskIntoConstraints = false

        let closeCell = HoverCell(highlight: .systemRed,
                                  onClick: { [weak self] in self?.onClose?(window) })
        closeCell.translatesAutoresizingMaskIntoConstraints = false
        closeCell.widthAnchor.constraint(equalToConstant: 30).isActive = true
        closeCell.setContentHuggingPriority(.required, for: .horizontal)
        closeCell.setContentCompressionResistancePriority(.required, for: .horizontal)
        closeCell.addSubview(closeLabel)
        NSLayoutConstraint.activate([
            closeLabel.centerXAnchor.constraint(equalTo: closeCell.centerXAnchor),
            closeLabel.centerYAnchor.constraint(equalTo: closeCell.centerYAnchor),
        ])

        let h = NSStackView(views: [contentCell, closeCell])
        h.orientation = .horizontal
        h.distribution = .fill
        h.spacing = 0   // aradaki boşluk hiçbir hücreye ait olmayan "ölü tık" bölgesi yaratıyordu
        h.translatesAutoresizingMaskIntoConstraints = false

        // Küçük resim hücresi: görüntü asenkron geldiği için YER BAŞTAN AYRILIR (panel sonradan
        // zıplamasın). Yakalanamayan pencerelerde (simge durumunda, izin yokken) hiç gösterilmez.
        let thumbView = ThumbView()
        thumbView.translatesAutoresizingMaskIntoConstraints = false

        // Küçük resim hücresinde hover VURGUSU YOK: hücre satır genişliğini kapladığı için vurgu,
        // ortalanmış görüntünün etrafında kocaman renkli bir kutu olarak görünüyordu. Tıklama
        // çalışmaya devam eder; hover geri bildirimi üstteki başlık satırında verilir.
        let thumbCell = HoverCell(highlight: .clear,
                                  onClick: { [weak self] in self?.onSelect?(window) })
        thumbCell.translatesAutoresizingMaskIntoConstraints = false
        // KARE kutu: görüntü "cover" ile doldurduğu için pencerenin oranı ne olursa olsun
        // kutunun etrafında boşluk kalmaz (taşan kenarlar kırpılır).
        let boxSide = max(1, rowWidth - 8)
        thumbCell.addSubview(thumbView)
        NSLayoutConstraint.activate([
            thumbView.leadingAnchor.constraint(equalTo: thumbCell.leadingAnchor, constant: 4),
            thumbView.trailingAnchor.constraint(equalTo: thumbCell.trailingAnchor, constant: -4),
            thumbView.topAnchor.constraint(equalTo: thumbCell.topAnchor, constant: 2),
            thumbView.bottomAnchor.constraint(equalTo: thumbCell.bottomAnchor, constant: -4),
            thumbView.heightAnchor.constraint(equalToConstant: boxSide.rounded()),
        ])
        // Yalnızca ekranda olan (yakalanabilir) pencerelerde alan ayrılır.
        thumbCell.isHidden = !(showThumbnails && window.windowID != nil)

        let v = NSStackView(views: [h, thumbCell])
        v.orientation = .vertical
        v.alignment = .width       // her iki blok da satır genişliğini doldursun
        v.spacing = 0
        v.translatesAutoresizingMaskIntoConstraints = false

        let row = PeekRow(onEnter: { [weak self] in self?.onPeek?(window) },
                          onExit: { [weak self] in self?.onPeekEnd?() })
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            v.topAnchor.constraint(equalTo: row.topAnchor),
            v.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return RowEntry(row: row, content: contentCell, close: closeCell, thumb: thumbView, window: window)
    }
}

// Pencere küçük resmini "cover" (resizeAspectFill) ile çizen görünüm: görüntü kutuyu tamamen
// doldurur, oranı korunur, taşan kenarlar kırpılır → kutunun çevresinde asla boşluk kalmaz.
// NSImageView'da bu davranış yok (yalnızca sığdırma ya da bozma), bu yüzden doğrudan katman
// kullanılıyor.
final class ThumbView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: CGImage) {
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        layer?.contents = image
    }
}

// Satırın TAMAMINI (× hücresi dahil) kapsayan peek izleyicisi. Peek yaşam döngüsü hücre değil
// satır düzeyinde olduğu için, kullanıcı başlıktan ×'e uzanırken peek'lenen pencere arkaya düşmez.
final class PeekRow: NSView {
    private let onEnter: () -> Void
    private let onExit: () -> Void

    init(onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onEnter = onEnter
        self.onExit = onExit
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}

// Tek tıklanabilir hücre: hover'da arka planı vurgulanır, bırakılınca onClick çalışır.
// hitTest tüm iç alanı tek hedef yapar → alt görünümler (etiket) tıklamayı yutmaz.
final class HoverCell: NSView {
    private let onClick: () -> Void
    private let highlightColor: NSColor
    private var hovered = false
    private var pressed = false

    init(highlight: NSColor, onClick: @escaping () -> Void) {
        self.highlightColor = highlight
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
    }
    required init?(coder: NSCoder) { fatalError() }

    // Eylem mouseDown'da DEĞİL mouseUp'ta çalışır (standart düğme davranışı): kullanıcı ×'e
    // yanlışlıkla basarsa imleci hücre dışına çekip bırakarak vazgeçebilir.
    override func mouseDown(with event: NSEvent) { setPressed(true) }

    override func mouseDragged(with event: NSEvent) {
        setPressed(bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        setPressed(false)
        if inside { onClick() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.contains(p) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ on: Bool) { hovered = on; applyBackground() }
    private func setPressed(_ on: Bool) { pressed = on; applyBackground() }

    private func applyBackground() {
        let alpha: CGFloat = pressed ? 0.45 : (hovered ? 0.28 : 0)
        layer?.backgroundColor = alpha > 0 ? highlightColor.withAlphaComponent(alpha).cgColor
                                           : NSColor.clear.cgColor
    }
}

// İmlecin (ekran koordinatı) bu görünümün üstünde olup olmadığı — panel yeniden kurulduğunda
// mouseEntered gelmediği için elle sınamak gerekir.
extension NSView {
    func containsScreenPoint(_ p: NSPoint) -> Bool {
        guard let w = window else { return false }
        return bounds.contains(convert(w.convertPoint(fromScreen: p), from: nil))
    }
}
