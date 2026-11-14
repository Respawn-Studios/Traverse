import AppKit
import ExplorerCore

/// An explicit projection, never a dump of preferences, environment, logs or
/// live sessions. Its only free-form inputs are bounded numeric version fields.
struct SupportDetailsSnapshot {
    enum Channel: String {
        case development = "Development"
        case preview = "Local Preview"
        case qualification = "Local qualification"
        case candidate = "App Store candidate"
        case appStore = "App Store / TestFlight"
        case developerID = "Direct download (Developer ID)"
        case unknown = "Unknown"
    }
    enum Storage: String {
        case development = "Development profile"
        case portable = "Portable profile"
        case direct = "Local direct profile"
        case unavailable = "Unavailable"
    }
    enum Architecture: String {
        case arm64, x86_64
        case unknown = "Unknown"
    }
    let version: String?
    let build: String?
    let os: OperatingSystemVersion
    let architecture: Architecture
    let channel: Channel
    let storage: Storage
    let appearance: BrowserAppearance
    let style: NavigationStyle
    let translucentFiles: Bool
    let motion: BrowserMotionMode
    let systemReduceMotion: Bool
    let systemReduceTransparency: Bool
    let systemIncreaseContrast: Bool
    let bottomAddress: Bool
    let viewMode: DirectoryViewMode
    let interfaceSize: InterfaceSize
    let keyboardPreset: BrowserKeyboardPreset
    let controlAliases: Bool

    var text: String {
        let system = [os.majorVersion, os.minorVersion, os.patchVersion]
        let versionText =
            system.allSatisfy { (0...999).contains($0) }
            ? system.map(String.init).joined(separator: ".") : "Unavailable"
        let layout = bottomAddress ? "Bottom address" : "Top address"
        return """
            Traverse · Support Details v2
            App version: \(Self.numericVersion(version))
            Build: \(Self.numericVersion(build))
            macOS: \(versionText)
            Architecture: \(architecture.rawValue)
            Build channel: \(channel.rawValue)
            Storage: \(storage.rawValue)
            Interface size: \(interfaceSize.percent)%
            Keyboard preset: \(keyboardPreset.rawValue)
            Explorer Control shortcuts: \(Self.onOff(controlAliases))
            Appearance: \(appearance.displayName)
            Surface: \(style.rawValue)
            Translucent file content: \(Self.onOff(translucentFiles))
            Animation mode: \(motion.title)
            System Reduce Motion: \(Self.onOff(systemReduceMotion))
            System Reduce Transparency: \(Self.onOff(systemReduceTransparency))
            System Increase Contrast: \(Self.onOff(systemIncreaseContrast))
            Navigation: \(layout)
            File view: \(viewMode.rawValue)

            User-created descriptions and file, server and account details are excluded.
            This report is generated locally. Sharing is your choice.
            """
    }

    private static func onOff(_ value: Bool) -> String { value ? "On" : "Off" }
    static func numericVersion(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.utf8.count <= 32 else { return "Unavailable" }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count),
            components.allSatisfy({
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
            })
        else { return "Unavailable" }
        return value
    }

    static func channel(_ raw: String?) -> Channel {
        switch raw {
        case nil, "", "development": .development
        case "development-preview": .preview
        case "qualification": .qualification
        case "candidate", "app-store-candidate": .candidate
        case "app-store": .appStore
        case "developer-id": .developerID
        default: .unknown
        }
    }

    @MainActor static func current(settings: BrowserSettings) -> Self {
        #if arch(arm64)
            let architecture = Architecture.arm64
        #elseif arch(x86_64)
            let architecture = Architecture.x86_64
        #else
            let architecture = Architecture.unknown
        #endif
        let storage: Storage
        switch AppStorageLocations.layout?.channel {
        case .portable: storage = AppFeatureAvailability.policy.edition == .directPublic ? .direct : .portable
        case .development: storage = .development
        case nil: storage = .unavailable
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let system = NSWorkspace.shared
        return .init(
            version: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String,
            os: ProcessInfo.processInfo.operatingSystemVersion, architecture: architecture,
            channel: channel(info["MacExplorerDistributionChannel"] as? String), storage: storage,
            appearance: settings.appearance, style: settings.navigationStyle,
            translucentFiles: settings.glassFileContent,
            motion: settings.motion.mode, systemReduceMotion: system.accessibilityDisplayShouldReduceMotion,
            systemReduceTransparency: system.accessibilityDisplayShouldReduceTransparency,
            systemIncreaseContrast: system.accessibilityDisplayShouldIncreaseContrast,
            bottomAddress: settings.showsPathBar, viewMode: settings.viewMode,
            interfaceSize: settings.interfaceSize, keyboardPreset: settings.keyboardProfile,
            controlAliases: settings.behavior.controlAliasesEnabled)
    }
}

@MainActor private final class SupportDetailsWindow: ToolMotionWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "w"
        {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class ApplicationSupportDetails: NSObject, NSWindowDelegate {
    static let shared = ApplicationSupportDetails()
    private var controller: NSWindowController?
    private var textView: NSTextView?
    private var copyButton: NSButton?
    private var status: NSTextField?
    private var snapshot: (() -> SupportDetailsSnapshot?)?
    private var document = ""
    private let clipboard: (String) -> Bool
    var window: NSWindow? { controller?.window }

    init(
        clipboard: @escaping (String) -> Bool = { text in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
    ) {
        self.clipboard = clipboard
        super.init()
    }

    func show(settings: BrowserSettings, offscreen: Bool = false) {
        let presentationOwner = NSApplication.shared.keyWindow
        snapshot = { [weak settings] in settings.map { SupportDetailsSnapshot.current(settings: $0) } }
        if let window {
            ToolWindowChrome.install(in: window, settings: settings)
            refresh(nil)
            if !offscreen { window.makeKeyAndOrderFront(nil) }
            return
        }
        let host = NSViewController()
        host.view = NSView(frame: .init(x: 0, y: 0, width: 700, height: 560))
        let heading = NSTextField(labelWithString: "Support Details")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let note = NSTextField(
            wrappingLabelWithString:
                "Review these app and display settings before copying them into feedback. No file names, paths, saved names, server addresses or passwords are included."
        )
        note.textColor = .secondaryLabelColor
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refresh(_:)))
        let copy = NSButton(title: "Copy Details", target: self, action: #selector(copyDetails(_:)))
        copy.keyEquivalent = "\r"
        copy.setAccessibilityLabel("Copy the displayed support details")
        let controls = NSStackView(views: [refresh, NSView(), copy])
        controls.spacing = 10
        let result = NSTextField(labelWithString: "")
        result.textColor = .secondaryLabelColor
        result.setAccessibilityRole(.staticText)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let text = NSTextView(frame: .init(x: 0, y: 0, width: 650, height: 360))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = false
        text.drawsBackground = false
        InterfaceMetrics.setFont(text, base: .monospacedSystemFont(ofSize: 12, weight: .regular))
        text.textColor = .labelColor
        text.textContainerInset = .init(width: 10, height: 10)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.setAccessibilityLabel("Reviewable support report")
        scroll.documentView = text
        let stack = NSStackView(views: [heading, note, scroll, result, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: host.view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: host.view.bottomAnchor, constant: -18),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        let window = SupportDetailsWindow(contentViewController: host)
        window.title = "Support Details"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(.init(width: 700, height: 560))
        window.contentMinSize = .init(width: 560, height: 440)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        controller = NSWindowController(window: window)
        textView = text
        copyButton = copy
        status = result
        ToolWindowChrome.install(in: window, settings: settings)
        self.refresh(nil)
        if offscreen {
            window.setFrameOrigin(.init(x: -12000, y: -12000))
        } else {
            ToolWindowChrome.position(window, relativeTo: presentationOwner)
            window.makeKeyAndOrderFront(nil)
            ToolContentMotion.reveal(host.view, effect: .windows)
        }
    }

    @objc func refresh(_ sender: Any?) {
        guard let next = snapshot?() else {
            status?.stringValue = "The source window closed. Reopen Support Details from Explorer."
            return
        }
        document = next.text
        textView?.string = document
        status?.stringValue = "Generated locally · copied only when you choose Copy Details"
    }
    @objc private func copyDetails(_ sender: Any?) {
        guard !document.isEmpty else { return }
        status?.stringValue =
            clipboard(document)
            ? "Copied. Paste into feedback when you are ready."
            : "Could not copy. You can select and copy the displayed text."
    }
    func windowWillClose(_ notification: Notification) {
        textView?.string = ""
        textView = nil
        copyButton = nil
        status = nil
        snapshot = nil
        document = ""
        controller = nil
    }
    #if DEBUG
        var documentForVerification: String { document }
        var statusForVerification: String? { status?.stringValue }
        var reportFontSizeForVerification: CGFloat? { textView?.font?.pointSize }
        func copyForVerification() { copyButton?.performClick(nil) }
    #endif
}

@MainActor extension BrowserViewController {
    @objc func showSupportDetails(_ sender: Any?) { ApplicationSupportDetails.shared.show(settings: settings) }
}
