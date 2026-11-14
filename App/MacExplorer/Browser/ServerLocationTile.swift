import AppKit
import ExplorerCore

/// A navigation tile, never a local URL or a file-operation source/destination.
@MainActor final class ServerLocationTile: NSCollectionViewItem, NSGestureRecognizerDelegate {
    enum Source {
        case connected(BrowserConnectedLocation)
        case saved(WorkspaceConnectionBookmark, progress: String?)
    }
    var onOpen: (() -> Bool)?
    var motion = BrowserMotionPreferences() { didSet {
        (view as? BrowserLocationTileBackground)?.motion = motion
        refreshActivity()
    } }
    private var source: Source?
    private var busy = false
    private let icon = NSImageView()
    private let name = label("", size: 13, weight: .medium)
    private let detail = label("", size: 11, color: .secondaryLabelColor)
    private let activity = NSProgressIndicator()
    override var isSelected: Bool { didSet { refreshAppearance() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { refreshAppearance() } }

    override func loadView() {
        let background = BrowserLocationTileBackground(); view = background
        for child in [icon, name, detail, activity] {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.setAccessibilityElement(false); background.addSubview(child)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.lineBreakMode = .byTruncatingMiddle; detail.lineBreakMode = .byTruncatingTail
        activity.style = .spinning; activity.controlSize = .small
        activity.isDisplayedWhenStopped = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 40).interfaceScaled,
            icon.heightAnchor.constraint(equalToConstant: 40).interfaceScaled,
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            name.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            name.topAnchor.constraint(equalTo: background.topAnchor, constant: 11),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
            activity.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            activity.widthAnchor.constraint(equalToConstant: 18).interfaceScaled,
            activity.heightAnchor.constraint(equalToConstant: 18).interfaceScaled
        ])
        background.setAccessibilityElement(true); background.setAccessibilityRole(.cell)
        background.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Open", target: self, selector: #selector(performAccessibleOpen(_:)))
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        click.numberOfClicksRequired = 1; click.buttonMask = 1
        click.delaysPrimaryMouseButtonEvents = false; click.delegate = self
        background.addGestureRecognizer(click)
    }

    func configure(_ source: Source, motion: BrowserMotionPreferences) {
        _ = view; self.source = source; self.motion = motion
        let title: String, kind: String, status: String, help: String
        switch source {
        case .connected(let value):
            title = value.name; kind = value.id.kind.rawValue; status = value.status; busy = false
            help = "Open this connection’s existing tab."
        case .saved(let value, let progress):
            title = value.title; kind = value.isSFTP ? "SFTP" : "SMB"
            status = progress ?? "Not connected"; busy = progress != nil
            help = busy ? "Connecting. Use the context menu to cancel."
                : "Connect to this saved server. Traverse asks only for missing sign-in details."
        }
        name.stringValue = title; detail.stringValue = kind + " · " + status
        view.setAccessibilityLabel(title + ", " + kind + ", " + status)
        view.setAccessibilityHelp(help); view.toolTip = help
        refreshActivity(); refreshAppearance()
    }

    private func refreshActivity() {
        guard isViewLoaded else { return }
        let animated = busy && motion.allows(.pages) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        icon.isHidden = animated; activity.isHidden = !animated
        icon.image = symbol(busy && !animated ? "clock" : "server.rack", "Server")
        if animated { activity.startAnimation(nil) } else { activity.stopAnimation(nil) }
    }
    func refreshAppearance() {
        guard isViewLoaded, let background = view as? BrowserLocationTileBackground else { return }
        let selected = isSelected || highlightState == .forSelection
        let emphasized = view.window?.isKeyWindow == true
        background.selected = selected; background.emphasized = emphasized
        background.setAccessibilitySelected(isSelected)
        let color: NSColor = selected && emphasized ? .alternateSelectedControlTextColor
            : selected ? .unemphasizedSelectedTextColor : .labelColor
        name.textColor = color; detail.textColor = selected ? color : .secondaryLabelColor
        icon.contentTintColor = selected ? color : .secondaryLabelColor
        background.needsDisplay = true
    }
    @objc private func clicked(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended, !busy else { return }
        _ = onOpen?()
    }
    @objc func performAccessibleOpen(_ action: NSAccessibilityCustomAction) -> Bool {
        guard source != nil, !busy, NativeAccessibleAction.canInvoke(view),
              NativeAccessibleAction.activateWindow(view) else { return false }
        return onOpen?() ?? false
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
}
