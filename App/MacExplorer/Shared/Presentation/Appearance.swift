import AppKit

enum BrowserAppearance: String, CaseIterable, Codable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Pure policy; verification can cover accessibility priority without changing
/// machine preferences. Each area opt-in is subordinate to the master style.
enum BrowserMaterialPolicy {
    static func glassEnabled(style: NavigationStyle, enabled: Bool,
                             reduceTransparency: Bool, increaseContrast: Bool) -> Bool {
        style == .glass && enabled && !reduceTransparency && !increaseContrast
    }
}

struct PaneFocusPreferences: Codable, Equatable {
    enum Style: String, Codable, CaseIterable { case accent = "System accent", highContrast = "High contrast", custom = "Custom color" }
    var style = Style.accent
    var thickness = 2
    var caption = false
    var red = 0.25, green = 0.57, blue = 1.0
    var isValid: Bool {
        (1...3).contains(thickness) && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    var color: NSColor {
        switch style {
        case .accent: .controlAccentColor
        case .highContrast: .labelColor
        case .custom: NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }
}

@MainActor
enum BrowserAppearanceController {
    /// Changes this application's appearance only. A nil override tracks the system.
    static func apply(_ appearance: BrowserAppearance) {
        switch appearance {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// A native material host. File content is opaque unless explicitly opted in.
/// The same content view survives preference and accessibility changes.
@MainActor
final class NavigationGlassSurface: NSView {
    let contentView: NSView
    var isGlassEnabled: Bool {
        didSet { if oldValue != isGlassEnabled { rebuildMaterial() } }
    }
    /// The navigation occupies its own strip above opaque file rows, so there
    /// is no scrolling content underneath it. Use a public standard material
    /// to supply a genuine behind-window backdrop for the glass to sample.
    /// Disable only in the generated in-window material comparison probe.
    var usesWindowBackdrop: Bool {
        didSet { if oldValue != usesWindowBackdrop { rebuildMaterial() } }
    }

    private let radius: CGFloat
    private let opaqueColor: NSColor
    private let notifications: NotificationCenter
    private var materialView: NSView?
    private var backdropView: NSVisualEffectView?
    private var contentConstraints: [NSLayoutConstraint] = []
    private(set) var isUsingOpaqueSurface = false

    init(contentView: NSView, cornerRadius: CGFloat = 0, isGlassEnabled: Bool = true, usesWindowBackdrop: Bool = true,
         opaqueColor: NSColor = .controlBackgroundColor) {
        self.contentView = contentView
        self.radius = max(0, cornerRadius)
        self.isGlassEnabled = isGlassEnabled
        self.usesWindowBackdrop = usesWindowBackdrop
        self.opaqueColor = opaqueColor
        notifications = NSWorkspace.shared.notificationCenter
        super.init(frame: .zero)
        rebuildMaterial()
        notifications.addObserver(self, selector: #selector(accessibilityOptionsChanged(_:)),
                                  name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit { notifications.removeObserver(self) }

    @objc nonisolated private func accessibilityOptionsChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.rebuildMaterial() }
    }

    private func rebuildMaterial() {
        // Preserve keyboard focus if a field editor or a control belongs to this content.
        let responder = window?.firstResponder
        let focusedView = responder as? NSView
        let editorOwner = responder.flatMap { owner(of: $0, in: contentView) }
        let editorSelection = (responder as? NSTextView)?.selectedRange()
        let restoreFocus = editorOwner != nil || (focusedView.map { $0 === contentView || $0.isDescendant(of: contentView) } ?? false)
        NSLayoutConstraint.deactivate(contentConstraints)
        contentConstraints = []
        if #available(macOS 26.0, *), let glass = materialView as? NSGlassEffectView {
            glass.contentView = nil
        }
        contentView.removeFromSuperview()
        materialView?.removeFromSuperview()
        backdropView?.removeFromSuperview()
        backdropView = nil

        isUsingOpaqueSurface = !BrowserMaterialPolicy.glassEnabled(style: .glass, enabled: isGlassEnabled,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let material: NSView
        var nativeContentLayout = false
        if isUsingOpaqueSurface {
            material = OpaqueNavigationMaterial(color: opaqueColor)
        } else if #available(macOS 26.0, *) {
            if usesWindowBackdrop {
                let backdrop = NSVisualEffectView()
                backdrop.material = .underWindowBackground
                backdrop.blendingMode = .behindWindow
                backdrop.state = .followsWindowActiveState
                backdrop.translatesAutoresizingMaskIntoConstraints = false
                addSubview(backdrop)
                NSLayoutConstraint.activate([
                    backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
                    backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
                    backdrop.topAnchor.constraint(equalTo: topAnchor),
                    backdrop.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
                backdropView = backdrop
            }
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = radius
            contentView.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = contentView
            material = glass
            nativeContentLayout = true
        } else {
            let visual = NSVisualEffectView()
            visual.material = .headerView
            visual.blendingMode = usesWindowBackdrop ? .behindWindow : .withinWindow
            visual.state = .followsWindowActiveState
            material = visual
        }

        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // NSGlassEffectView owns both the embedding and its Auto Layout geometry.
        // Never move its content into an arbitrary sibling/subview hierarchy.
        if !nativeContentLayout {
            material.addSubview(contentView)
            contentView.translatesAutoresizingMaskIntoConstraints = false
            contentConstraints = [
                contentView.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: material.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: material.bottomAnchor)
            ]
            NSLayoutConstraint.activate(contentConstraints)
        }
        materialView = material
        if let editorOwner {
            window?.makeFirstResponder(editorOwner)
            if let editorSelection { (editorOwner.currentEditor() as? NSTextView)?.setSelectedRange(editorSelection) }
        } else if restoreFocus, let responder { window?.makeFirstResponder(responder) }
    }

    private func owner(of editor: NSResponder, in view: NSView) -> NSControl? {
        if let control = view as? NSControl, control.currentEditor() === editor { return control }
        for child in view.subviews {
            if let control = owner(of: editor, in: child) { return control }
        }
        return nil
    }
}

@MainActor
private final class OpaqueNavigationMaterial: NSView {
    let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}
