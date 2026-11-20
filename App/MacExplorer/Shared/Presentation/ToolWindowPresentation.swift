import AppKit
import Combine
import SwiftUI

/// One connected material behind a tool's existing controller. This owns no
/// model, file access, actions, window delegate or outgoing-content pictures.
@MainActor
final class ToolWindowChrome: NSViewController {
    let surface: NavigationGlassSurface
    let contentHost: NSView
    private weak var toolWindow: NSWindow?
    private var preferenceObservation: AnyCancellable?
    private var style = NavigationStyle.glass
    private(set) var motion = BrowserMotionPreferences()
    private var appliedMotion: BrowserMotionPreferences?
    private var appliedAppearance: BrowserAppearance?

    private init(content: NSViewController) {
        let host = NSView(); contentHost = host
        host.wantsLayer = true
        surface = NavigationGlassSurface(contentView: host, embedsContentInGlass: false,
                                         opaqueColor: .windowBackgroundColor)
        super.init(nibName: nil, bundle: nil)
        addChild(content)
        view = surface
        content.view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: contentHost.safeAreaLayoutGuide.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    /// Common native allocation. Feature controllers still own their content,
    /// delegates, work and close behavior; styling never owns file operations.
    static func makeWindow(title: String, size: NSSize, minimumSize: NSSize,
                           content: NSViewController? = nil,
                           styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]) -> NSWindow {
        let window = ToolMotionWindow(contentRect: .init(origin: .zero, size: size),
                              styleMask: styleMask, backing: .buffered, defer: false)
        configure(window, title: title, size: size, minimumSize: minimumSize, content: content)
        return window
    }

    /// Preserve NSPanel's sheet/focus behavior while sharing ordinary allocation
    /// policy. Feature controllers keep their own continuation and close owner.
    static func makePanel(title: String, size: NSSize, minimumSize: NSSize,
                          content: NSViewController? = nil,
                          styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable]) -> NSPanel {
        let panel = ToolMotionPanel(contentRect: .init(origin: .zero, size: size),
                            styleMask: styleMask, backing: .buffered, defer: false)
        configure(panel, title: title, size: size, minimumSize: minimumSize, content: content)
        return panel
    }

    private static func configure(_ window: NSWindow, title: String, size: NSSize,
                                  minimumSize: NSSize, content: NSViewController?) {
        window.title = title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.minSize = minimumSize
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        if let content { window.contentViewController = content }
        window.setContentSize(size)
    }

    /// Call for a new presentation only. Returning to an existing window must
    /// preserve its user-selected frame, including when Stage Manager is used.
    static func initialViewport(size: NSSize, minimum: NSSize, scale: CGFloat,
                                screen: NSScreen? = nil) -> (size: NSSize, minimum: NSSize) {
        let factor = min(1.5, max(1, scale))
        let proposed = NSSize(width: size.width * factor, height: size.height * factor)
        let maximum: NSSize
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            maximum = NSWindow.contentRect(forFrameRect: visible.insetBy(dx: 24, dy: 24),
                styleMask: [.titled, .closable, .resizable]).size
        } else { maximum = proposed }
        let floor = NSSize(width: min(minimum.width * factor, max(320, maximum.width)),
                           height: min(minimum.height * factor, max(240, maximum.height)))
        return (.init(width: max(floor.width, min(proposed.width, maximum.width)),
                      height: max(floor.height, min(proposed.height, maximum.height))), floor)
    }

    /// Position a new window without changing a retained user-selected frame.
    static func position(_ window: NSWindow, relativeTo owner: NSWindow? = nil) {
        let parent = owner === window ? nil : owner
        let screen = parent?.screen ?? window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { window.center(); return }
        let anchor = parent?.frame ?? visible
        let x = max(visible.minX, min(anchor.midX - window.frame.width / 2, visible.maxX - window.frame.width))
        let y = max(visible.minY, min(anchor.midY - window.frame.height / 2, visible.maxY - window.frame.height))
        window.setFrameOrigin(.init(x: x, y: y))
    }

    @discardableResult
    static func install(in window: NSWindow, settings: BrowserSettings? = nil,
                        initialContentSize: NSSize? = nil,
                        minimumContentSize: NSSize? = nil) -> ToolWindowChrome {
        let chrome: ToolWindowChrome
        let newlyInstalled: Bool
        if let existing = window.contentViewController as? ToolWindowChrome { chrome = existing; newlyInstalled = false }
        else {
            newlyInstalled = true
            let frame = window.frame
            window.styleMask.insert(.fullSizeContentView)
            window.setFrame(frame, display: false)
            let size = window.contentView?.bounds.size ?? window.contentLayoutRect.size
            let content = window.contentViewController ?? {
                let controller = NSViewController()
                controller.view = window.contentView ?? NSView(frame: .init(origin: .zero, size: size))
                return controller
            }()
            window.contentViewController = nil
            chrome = ToolWindowChrome(content: content)
            chrome.view.frame = .init(origin: .zero, size: size)
            window.contentViewController = chrome
        }
        chrome.toolWindow = window
        // A later layout-only install must not reset a previously bound theme.
        // Recovery windows without an explicit owner use the app's same owner.
        if let settings {
            chrome.bind(settings)
        } else if chrome.preferenceObservation == nil {
            if let settings = InterfacePresentation.shared.settings { chrome.bind(settings) }
            else { chrome.apply() }
        }
        InterfacePresentation.shared.register(chrome.view)
        // AppKit can adopt an embedded controller's fitting size while the
        // content is installed. An explicit first viewport never resets a
        // window that is merely being brought forward or restyled.
        if newlyInstalled {
            // Installing an NSHostingController can replace an earlier window
            // minimum with its initial fitting size. Apply the feature's
            // explicit floor after both content controllers are embedded.
            if let minimumContentSize { window.contentMinSize = minimumContentSize }
            if let initialContentSize { window.setContentSize(initialContentSize) }
        }
        return chrome
    }

    private func bind(_ settings: BrowserSettings?) {
        preferenceObservation?.cancel()
        style = settings?.navigationStyle ?? .glass
        motion = settings?.motion ?? .init()
        apply(appearance: settings?.appearance)
        if let settings {
            preferenceObservation = Publishers.CombineLatest3(settings.$navigationStyle, settings.$appearance, settings.$motion)
                .dropFirst().receive(on: RunLoop.main).sink { [weak self] style, appearance, motion in
                    self?.style = style; self?.motion = motion; self?.apply(appearance: appearance)
                }
        }
    }

    private func apply(appearance: BrowserAppearance? = nil) {
        let workspace = NSWorkspace.shared
        // Embedded tools can bind the same chrome again while their first
        // observations arrive. Styling alone must not cut an entrance short.
        if let toolWindow, workspace.accessibilityDisplayShouldReduceMotion
            || appliedMotion.map({ $0 != motion }) == true {
            ToolContentMotion.finish(in: toolWindow)
        }
        appliedMotion = motion
        if let appearance {
            if let appliedAppearance, appliedAppearance != appearance, let toolWindow {
                ToolContentMotion.finishContentMotion(in: toolWindow)
            }
            appliedAppearance = appearance
        }
        ToolContentMotion.finishCrossfade(in: contentHost, kind: .page)
        let glass = BrowserMaterialPolicy.glassEnabled(style: style, enabled: true,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
        surface.isGlassEnabled = glass
        // Extend our material behind native chrome, while the child controller
        // stays below the safe area. The window itself always keeps its opaque
        // background/hit region; glass must never create a click-through hole.
        toolWindow?.titlebarAppearsTransparent = glass
        toolWindow?.backgroundColor = .windowBackgroundColor
        toolWindow?.isOpaque = true
        toolWindow?.animationBehavior = workspace.accessibilityDisplayShouldReduceMotion || !motion.allows(.windows) || motion.mode != .full ? .none : .utilityWindow
        if let toolWindow { ToolWindowCloseMotion.finishIfDisabled(toolWindow, motion: motion) }
        if let appearance {
            switch appearance {
            case .system: toolWindow?.appearance = nil
            case .light: toolWindow?.appearance = NSAppearance(named: .aqua)
            case .dark: toolWindow?.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }
    @objc nonisolated private func accessibilityChanged() {
        Task { @MainActor [weak self] in self?.apply() }
    }
}

@MainActor
enum ToolPageMotionPolicy {
    static var crossfadeTiming: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }

    static func crossfadeDuration(_ motion: BrowserMotionPreferences) -> TimeInterval {
        guard motion.allows(.pages), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return 0 }
        return 0.22 * motion.mode.durationScale
    }

    static func initialOpacity(_ mode: BrowserMotionMode) -> Double {
        mode == .off ? 1 : mode.initialOpacity(0.72)
    }
}

/// Reveals only the current live detail or form after its identity changes.
private struct ToolPageEntrance<ID: Equatable & Sendable>: ViewModifier {
    let identity: ID
    let enabled: Bool
    let mode: BrowserMotionMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = true

    init(identity: ID, enabled: Bool, mode: BrowserMotionMode, initiallyRevealed: Bool) {
        self.identity = identity; self.enabled = enabled; self.mode = mode
        _revealed = State(initialValue: initiallyRevealed)
    }

    func body(content: Content) -> some View {
        content
            .opacity(revealed || reduceMotion || !enabled || mode == .off ? 1 : ToolPageMotionPolicy.initialOpacity(mode))
            .offset(y: revealed || reduceMotion || !enabled || mode == .off ? 0 : 4 * mode.distanceScale)
            .animation(reduceMotion || !enabled || mode == .off ? nil : .easeOut(duration: mode.toolWindowDuration), value: revealed)
            .task(id: identity) {
                guard !reduceMotion, enabled, mode != .off else { revealed = true; return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { revealed = false }
                // Allow the first presentation to reach the display.
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                revealed = true
            }
    }
}

extension View {
    func toolPageEntrance<ID: Equatable & Sendable>(_ identity: ID, enabled: Bool = true, mode: BrowserMotionMode = .full, initiallyRevealed: Bool = true) -> some View {
        modifier(ToolPageEntrance(identity: identity, enabled: enabled, mode: mode, initiallyRevealed: initiallyRevealed))
    }

    func toolPageCrossfade<ID: Equatable & Sendable>(_ identity: ID, motion: BrowserMotionPreferences) -> some View {
        background(ToolPageCrossfadeTrigger(identity: identity, motion: motion).frame(width: 0, height: 0))
    }
}

/// The native compositor blends the already-rendered page into its replacement.
/// No model, editor, screenshot or outgoing description is copied by this owner.
private struct ToolPageCrossfadeTrigger<ID: Equatable & Sendable>: NSViewRepresentable {
    let identity: ID
    let motion: BrowserMotionPreferences
    final class Coordinator { var identity: ID? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        defer { context.coordinator.identity = identity }
        guard let previous = context.coordinator.identity, previous != identity,
              let chrome = view.window?.contentViewController as? ToolWindowChrome else { return }
        ToolContentMotion.crossfadePage(chrome.contentHost, motion: motion)
    }
}

@MainActor
enum ToolContentMotion {
    enum CrossfadeKind: Equatable, Sendable { case content, page }
    private final class CrossfadeOwner: NSObject, CAAnimationDelegate {
        let kind: CrossfadeKind
        init(_ kind: CrossfadeKind) { self.kind = kind }
    }
    // Weak bookkeeping only: this never keeps a view/private description alive.
    private static let views = NSHashTable<NSView>.weakObjects()
    private static let pageViewports = NSHashTable<NativeToolPageViewport>.weakObjects()
    private static let entranceKey = "tool-content-entrance"
    private static let entrances = NSMapTable<NSWindow, DisplayLinkedTransition>(keyOptions: .weakMemory,
                                                                               valueOptions: .strongMemory)

    static func registerPageViewport(_ viewport: NativeToolPageViewport) {
        pageViewports.add(viewport)
    }
    /// A retained window can be shown repeatedly. Bringing it forward, or
    /// cancelling an accepted close, must not replay its entrance.
    private static func windowEntranceMotion(_ window: NSWindow) -> BrowserMotionPreferences? {
        guard !window.isMiniaturized, window.sheetParent == nil,
              let chrome = window.contentViewController as? ToolWindowChrome,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              chrome.motion.allows(.windows) else { return nil }
        return chrome.motion
    }
    static func prepareWindowEntrance(_ window: NSWindow, wasVisible: Bool) -> BrowserMotionPreferences? {
        guard !wasVisible else { return nil }
        cancelWindowEntrance(in: window)
        guard let motion = windowEntranceMotion(window) else {
            if !ToolWindowCloseMotion.isClosing(window) { window.alphaValue = 1 }
            return nil
        }
        window.alphaValue = 0
        return motion
    }
    static func revealWindow(_ window: NSWindow, motion: BrowserMotionPreferences?) {
        guard let motion else {
            // Bringing an eligible live window forward keeps its entrance.
            // Becoming a sheet or disabling motion instead settles it now.
            if windowEntranceMotion(window) == nil {
                cancelWindowEntrance(in: window)
                if !ToolWindowCloseMotion.isClosing(window) { window.alphaValue = 1 }
            }
            return
        }
        cancelWindowEntrance(in: window)
        let transition = DisplayLinkedTransition()
        entrances.setObject(transition, forKey: window)
        transition.animate(in: window, duration: motion.mode.toolWindowDuration, startsOnFirstFrame: true,
            update: { [weak window] progress in window?.alphaValue = progress },
            completion: { [weak window, weak transition] in
                guard let window, entrances.object(forKey: window) === transition else { return }
                entrances.removeObject(forKey: window)
                window.alphaValue = 1
            })
    }
    static func cancelWindowEntrance(in window: NSWindow) {
        entrances.object(forKey: window)?.cancel()
        entrances.removeObject(forKey: window)
    }
    static func finish(in window:NSWindow) {
        cancelWindowEntrance(in: window)
        if !ToolWindowCloseMotion.isClosing(window), window.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0; window.animator().alphaValue = 1
            }
        }
        finishContentMotion(in: window)
    }
    static func hasCrossfade(in view: NSView, kind: CrossfadeKind? = nil) -> Bool {
        guard let owner = view.layer?.animation(forKey: kCATransition)?.delegate as? CrossfadeOwner else { return false }
        return kind == nil || owner.kind == kind
    }
    static func finishCrossfade(in view: NSView, kind: CrossfadeKind? = nil) {
        // Core Animation stores CATransition at kCATransition, regardless of
        // our requested name. The copied animation retains this private marker;
        // never cancel an unrelated transition or a property animation.
        guard hasCrossfade(in: view, kind: kind) else { return }
        view.layer?.removeAnimation(forKey: kCATransition)
    }
    static func finishContentMotion(in window: NSWindow) {
        for viewport in pageViewports.allObjects where viewport.window === window {
            viewport.finishPageTransition?()
        }
        if let content = (window.contentViewController as? ToolWindowChrome)?.contentHost ?? window.contentView {
            finishCrossfade(in: content)
        }
        for view in views.allObjects where view.window === window || view.window == nil {
            finishCrossfade(in: view)
            view.layer?.removeAnimation(forKey: entranceKey)
            views.remove(view)
        }
    }
    #if DEBUG
    static func hasContentEntrance(in view: NSView) -> Bool {
        view.layer?.animation(forKey: entranceKey) != nil
    }
    #endif
    static func crossfade(_ view: NSView) {
        finishCrossfade(in: view)
        let motion = (view.window?.contentViewController as? ToolWindowChrome)?.motion ?? InterfacePresentation.shared.motion
        let duration = ToolPageMotionPolicy.crossfadeDuration(motion)
        guard duration > 0,
              view.window?.isVisible == true, views.allObjects.count < 128 else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        addCrossfade(to: layer, kind: .content, duration: duration)
        views.add(view)
    }
    static func crossfadePage(_ view: NSView, motion: BrowserMotionPreferences) {
        let duration = ToolPageMotionPolicy.crossfadeDuration(motion)
        guard duration > 0, let layer = view.layer else {
            finishCrossfade(in: view, kind: .page); return
        }
        finishCrossfade(in: view)
        addCrossfade(to: layer, kind: .page, duration: duration)
    }
    private static func addCrossfade(to layer: CALayer, kind: CrossfadeKind, duration: TimeInterval) {
        let transition = CATransition(); transition.type = .fade
        transition.delegate = CrossfadeOwner(kind)
        transition.duration = duration
        transition.timingFunction = ToolPageMotionPolicy.crossfadeTiming
        layer.add(transition, forKey: kCATransition)
    }
    static func reveal(_ view: NSView, effect: BrowserMotionEffect = .pages, movesContent: Bool = true) {
        finishCrossfade(in: view)
        view.layer?.removeAnimation(forKey: entranceKey)
        views.remove(view)
        let motion = (view.window?.contentViewController as? ToolWindowChrome)?.motion ?? InterfacePresentation.shared.motion
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              motion.allows(effect),
              view.window?.isVisible == true, views.allObjects.count<128 else { return }
        view.wantsLayer = true
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = ToolPageMotionPolicy.initialOpacity(motion.mode); opacity.toValue = 1
        let group = CAAnimationGroup()
        if movesContent {
            let position = CABasicAnimation(keyPath: "transform.translation.y")
            position.fromValue = -4 * motion.mode.distanceScale; position.toValue = 0
            group.animations = [opacity, position]
        } else { group.animations = [opacity] }
        group.duration = motion.mode.toolWindowDuration; group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer?.add(group, forKey: entranceKey)
        views.add(view)
    }
}
