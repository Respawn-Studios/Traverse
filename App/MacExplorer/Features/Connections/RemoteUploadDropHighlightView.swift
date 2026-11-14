import AppKit

/// Current-folder affordance only. It cannot intercept the actual native drop.
@MainActor final class RemoteUploadDropHighlightView: NSView {
    private let label = NSTextField(labelWithString: "")
    var caption: String = "" { didSet { label.stringValue = caption } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13, weight: .medium); label.textColor = .labelColor
        label.maximumNumberOfLines = 2; label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40)])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0.2 : 0.07).setFill(); path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke(); path.lineWidth = 2; path.stroke()
    }
}
