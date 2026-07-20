import Cocoa

// İkonun üstünde beliren, aktivasyon çalmayan (non-activating) yüzen panel.
// Her satır: uygulama ikonu + pencere başlığı + sağda kapat (×) düğmesi.
final class PreviewPanel: NSPanel {
    private let stack = NSStackView()
    private var onSelect: ((DockWindow) -> Void)?
    private var onClose: ((DockWindow) -> Void)?

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
        visual.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            stack.topAnchor.constraint(equalTo: visual.topAnchor),
            stack.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
        ])
        contentView = visual
    }

    // İmleç panelin çerçevesi içinde mi? (gizleme gecikmesinde "panele geçti mi" kontrolü için)
    var isMouseInside: Bool {
        return frame.contains(NSEvent.mouseLocation)
    }

    // Pencereleri gösterir ve paneli Dock yönüne göre ikonun (anchor) yanında/üstünde konumlar.
    // orientation: "left" (Dock solda → panel sağda), "right" (Dock sağda → panel solda),
    // diğer/"bottom" (Dock altta → panel üstte).
    func show(windows: [DockWindow], appIcon: NSImage?, anchor: NSRect, on screen: NSScreen,
              orientation: String,
              onSelect: @escaping (DockWindow) -> Void,
              onClose: @escaping (DockWindow) -> Void) {
        self.onSelect = onSelect
        self.onClose = onClose
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for w in windows {
            let row = makeRow(window: w, icon: appIcon)
            stack.addArrangedSubview(row)
            // Her satır panel genişliğini (insetler hariç) doldursun → × hep en sağa yaslı kalır.
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        }
        layoutIfNeeded()
        let width: CGFloat = 250   // tüm paneller için sabit genişlik (uzun başlıklar sonda kırpılır)
        let size = stack.fittingSize
        setContentSize(NSSize(width: width, height: size.height))

        // Dock yönüne göre konumla; ardından ekran içine sıkıştır.
        let vf = screen.visibleFrame
        let gap: CGFloat = 8
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
        x = min(max(x, vf.minX + 4), vf.maxX - width - 4)
        y = min(max(y, vf.minY + 4), vf.maxY - h - 4)
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }

    // Satır = iki AYRI buton: sol hücre (ikon + başlık) uygulamayı öne getirir,
    // sağ hücre (×) yalnızca pencereyi kapatır. Her hücrenin kendi hover vurgusu vardır.
    private func makeRow(window: DockWindow, icon: NSImage?) -> NSView {
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
        h.spacing = 4   // iki buton arasında görünür boşluk
        h.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            h.topAnchor.constraint(equalTo: row.topAnchor),
            h.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }
}

// Tek tıklanabilir hücre: hover'da arka planı vurgulanır, tıklanınca onClick çalışır.
// hitTest tüm iç alanı tek hedef yapar → alt görünümler (etiket) tıklamayı yutmaz.
final class HoverCell: NSView {
    private let onClick: () -> Void
    private let highlightColor: NSColor

    init(highlight: NSColor, onClick: @escaping () -> Void) {
        self.highlightColor = highlight
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick() }

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
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = highlightColor.withAlphaComponent(0.28).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}
