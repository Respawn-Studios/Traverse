import AppKit

/// Source-list group buttons normally fade away. Keep AppKit's own expansion
/// action/state while using a persistent chevron in the same native frame.
@MainActor
final class SidebarCategoryDisclosureButton: NSButton {
    private var drawnExpansion: Bool?
    private let collapsedImage = symbol("chevron.right", "Expand category")
    private let expandedImage = symbol("chevron.down", "Collapse category")
    override var alphaValue: CGFloat {
        get { super.alphaValue }
        set { super.alphaValue = 1 }
    }
    init(native: NSButton) {
        super.init(frame: native.frame)
        identifier = native.identifier
        target = native.target; action = native.action
        setButtonType(.onOff)
        image = collapsedImage
        alternateImage = collapsedImage
        imagePosition = .imageOnly; isBordered = false
        contentTintColor = .secondaryLabelColor
        state = native.state
        refusesFirstResponder = native.refusesFirstResponder
        setAccessibilityLabel(native.accessibilityLabel())
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        var ancestor = superview
        while let view = ancestor, !(view is NSOutlineView) { ancestor = view.superview }
        if let outline = ancestor as? NSOutlineView {
            let row = outline.row(for: self)
            if row >= 0, let item = outline.item(atRow: row) {
                let expanded = outline.isItemExpanded(item)
                if drawnExpansion != expanded {
                    drawnExpansion = expanded
                    image = expanded ? expandedImage : collapsedImage
                    alternateImage = image
                }
            }
        }
        super.draw(dirtyRect)
    }
}

@MainActor
final class SidebarLocationCell: NSTableCellView {
    let eject = SidebarEjectButton(frame: .zero)
    private let activity = NSProgressIndicator()
    private var trailing: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(), text = label("")
        for child in [icon, text, eject, activity] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        activity.style = .spinning; activity.controlSize = .small; activity.isDisplayedWhenStopped = false
        activity.setAccessibilityElement(false)
        imageView = icon; textField = text
        eject.image = symbol("eject", "Eject drive")
        eject.isBordered = false; eject.bezelStyle = .recessed; eject.refusesFirstResponder = true
        eject.setAccessibilityLabel("Eject drive")
        trailing = text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17).interfaceScaled, icon.heightAnchor.constraint(equalToConstant: 17).interfaceScaled,
            activity.centerXAnchor.constraint(equalTo: icon.centerXAnchor), activity.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            activity.widthAnchor.constraint(equalToConstant: 14).interfaceScaled, activity.heightAnchor.constraint(equalToConstant: 14).interfaceScaled,
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), text.centerYAnchor.constraint(equalTo: centerYAnchor), trailing,
            eject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2), eject.centerYAnchor.constraint(equalTo: centerYAnchor),
            eject.widthAnchor.constraint(equalToConstant: 22).interfaceScaled, eject.heightAnchor.constraint(equalToConstant: 22).interfaceScaled
        ])
        configureEject(visible: false, enabled: false, action: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configureEject(visible: Bool, enabled: Bool, action: (() -> Void)?) {
        eject.isHidden = !visible; eject.isEnabled = enabled; eject.handler = action
        trailing.constant = visible ? -28 : -4
    }
    func configureConnecting(_ connecting: Bool, animated: Bool) {
        let spin = connecting && animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        imageView?.isHidden = spin; activity.isHidden = !spin
        if spin { activity.startAnimation(nil) } else { activity.stopAnimation(nil) }
    }
}

@MainActor
final class SidebarEjectButton: NSButton {
    var handler: (() -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(invoke(_:)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke(_ sender: Any?) { handler?() }
}
