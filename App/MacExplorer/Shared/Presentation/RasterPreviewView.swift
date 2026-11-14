import AppKit

/// Presentation only: a caller supplies an already-decoded, bounded image.
/// Fit, native pinch magnification and scrolling never read a file or decode
/// another frame. Percentages describe this preview, not original-file pixels.
@MainActor final class RasterPreviewView: NSView {
    private let scroll = NSScrollView()
    private let picture = NSImageView()
    private let scale = NSTextField(labelWithString: "")
    private let zoomOutButton = NSButton(title: "−", target: nil, action: nil)
    private let zoomInButton = NSButton(title: "+", target: nil, action: nil)
    private let fitButton = NSButton(title: "Fit", target: nil, action: nil)
    private var buttons: [NSButton] { [zoomOutButton, zoomInButton, fitButton] }
    private var fitting = false
    private(set) var fitsWindow = true

    var image: NSImage? {
        get { picture.image }
        set {
            picture.image = newValue
            picture.frame = NSRect(origin: .zero, size: newValue?.size ?? .init(width: 1, height: 1))
            buttons.forEach { $0.isEnabled = newValue != nil }
            fitsWindow = true
            needsLayout = true
            fitImage(nil)
        }
    }
    var magnification: CGFloat { scroll.magnification }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let clip = CenteredRasterClipView()
        clip.drawsBackground = false
        clip.clipsToBounds = true
        clip.postsBoundsChangedNotifications = true
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        picture.imageScaling = .scaleNone
        picture.imageAlignment = .alignCenter
        picture.setAccessibilityLabel("Selected archive image")
        scroll.documentView = picture

        zoomOutButton.action = #selector(zoomOut(_:))
        zoomInButton.action = #selector(zoomIn(_:))
        fitButton.action = #selector(fitImage(_:))
        for (button, title, identifier) in [
            (zoomOutButton, "Zoom Out", "raster-preview-zoom-out"),
            (zoomInButton, "Zoom In", "raster-preview-zoom-in"),
            (fitButton, "Fit Image", "raster-preview-fit"),
        ] {
            button.target = self
            button.setAccessibilityLabel(title)
            button.setAccessibilityIdentifier(identifier)
            button.toolTip = title
            button.isEnabled = false
            InterfaceMetrics.setFont(button, base: .systemFont(ofSize: 12))
        }
        fitButton.toolTip = "Fit the preview to this window (Command-0). Pinch on a trackpad or use Command-Plus and Command-Minus to zoom."
        InterfaceMetrics.setFont(scale, base: .systemFont(ofSize: 11))
        scale.textColor = .secondaryLabelColor
        scale.toolTip = "Scale relative to the decoded preview. Large images may use a reduced preview."
        let bar = NSStackView(views: [NSView(), scale, zoomOutButton, zoomInButton, fitButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.setHuggingPriority(.required, for: .vertical)
        for view in [scroll, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(magnificationBegan),
            name: NSScrollView.willStartLiveMagnifyNotification, object: scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(updateScale),
            name: NSView.boundsDidChangeNotification, object: clip)
    }
    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        if fitsWindow { fitImage(nil) }
    }

    @objc func fitImage(_ sender: Any?) {
        fitsWindow = true
        guard !fitting, let image, image.size.width > 0, image.size.height > 0 else {
            updateScale(); return
        }
        let viewport = scroll.contentView.frame.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        fitting = true
        defer { fitting = false }
        // A fitted image cannot scroll. Remove legacy scroller gutters before
        // measuring, rather than fitting to the smaller zoomed viewport and
        // then changing the available area when auto-hidden scrollers vanish.
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.tile()
        let available = scroll.contentView.frame.size
        let amount = min(available.width / image.size.width, available.height / image.size.height)
        scroll.setMagnification(max(scroll.minMagnification, min(scroll.maxMagnification, amount)),
            centeredAt: NSPoint(x: picture.frame.midX, y: picture.frame.midY))
        updateScale()
    }

    @objc func zoomIn(_ sender: Any? = nil) { zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any? = nil) { zoom(by: 0.8) }

    private func zoom(by factor: CGFloat) {
        guard image != nil else { return }
        fitsWindow = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.tile()
        let visible = scroll.contentView.bounds
        scroll.setMagnification(max(scroll.minMagnification, min(scroll.maxMagnification,
            scroll.magnification * factor)), centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        updateScale()
    }
    @objc private func magnificationBegan() {
        fitsWindow = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        updateScale()
    }
    @objc private func updateScale() {
        scale.stringValue = image == nil || fitsWindow ? "" : "\(Int((magnification * 100).rounded()))%"
    }
}

/// Keep a small or zoomed-out document centred without allowing its paint to
/// escape the native clip view into the tool's controls or footer.
@MainActor private final class CenteredRasterClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return bounds }
        if document.frame.width < bounds.width {
            bounds.origin.x = document.frame.midX - bounds.width / 2
        }
        if document.frame.height < bounds.height {
            bounds.origin.y = document.frame.midY - bounds.height / 2
        }
        return bounds
    }
}
