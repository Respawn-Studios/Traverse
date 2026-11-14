import AppKit
import CryptoKit
import Foundation

struct BundledNotices: Sendable {
    let text: String
    let components: Int
}

/// Only packaged public license text is read. No user document, browser, web
/// renderer, credential store or external application participates.
final class BundledNoticeReader: Sendable {
    enum Failure: Error { case unavailable, changed }
    private let queue = DispatchQueue(label: "MacExplorer.BundledNotices", qos: .utility)
    #if DEBUG
        private let beforeRead: (@Sendable () -> Void)?
        init(beforeRead: (@Sendable () -> Void)? = nil) { self.beforeRead = beforeRead }
    #else
        init() {}
    #endif
    func read(resources: URL, document: BundledLegalDocument = .thirdParty) async throws -> BundledNotices {
        try Task.checkCancellation()
        #if DEBUG
            let beforeRead = self.beforeRead
        #endif
        let result: BundledNotices = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let activity = try ApplicationFileActivity.gate.begin()
                    defer { withExtendedLifetime(activity) {} }
                    #if DEBUG
                        beforeRead?()
                    #endif
                    if case .projectLicense = document {
                        let file = BrowserSnapshotFile(directory: resources, name: "TraverseLicense.txt", maximumBytes: 65_536)
                        guard let bytes = try file.read(), let text = String(data: bytes, encoding: .utf8),
                              text.contains("GNU GENERAL PUBLIC LICENSE"), text.contains("Version 3, 29 June 2007") else {
                            throw Failure.unavailable
                        }
                        continuation.resume(returning: .init(text: text, components: 0))
                        return
                    }
                    let textFile = BrowserSnapshotFile(
                        directory: resources, name: "ThirdPartyNotices.txt", maximumBytes: 4 << 20)
                    let manifestFile = BrowserSnapshotFile(
                        directory: resources, name: "ThirdPartyManifest.json", maximumBytes: 131_072)
                    guard let bytes = try textFile.read(), let data = try manifestFile.read(),
                        let text = String(data: bytes, encoding: .utf8),
                        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let version = manifest["version"] as? NSNumber,
                        CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1 && version.doubleValue == 1,
                        let components = manifest["components"] as? [[String: Any]], components.count <= 512,
                        let digest = manifest["noticeSHA256"] as? String,
                        digest == SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined()
                    else { throw Failure.unavailable }
                    continuation.resume(returning: .init(text: text, components: components.count))
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return result
    }
}

@MainActor private final class NoticesWindow: ToolMotionWindow {
    weak var notices: ApplicationNotices?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "f"
        {
            notices?.find(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class ApplicationNotices: NSObject, NSWindowDelegate {
    static let shared = ApplicationNotices()
    static let projectLicense = ApplicationNotices(document: .projectLicense)
    private let documentType: BundledLegalDocument
    private var controller: NSWindowController?
    private var textView: NSTextView?
    private var loading: Task<Void, Never>?
    private let reader: BundledNoticeReader
    private var pending: (BrowserSettings, Bool)?
    private var draining = false
    private var generation = UUID()
    private(set) var isLoading = false
    private(set) var didLoad = false
    private(set) var displayStatus = ""
    var window: NSWindow? { controller?.window }
    init(reader: BundledNoticeReader = .init(), document: BundledLegalDocument = .thirdParty) {
        self.reader = reader
        documentType = document
        super.init()
    }
    func show(settings: BrowserSettings, offscreen: Bool = false) {
        let presentationOwner = NSApplication.shared.keyWindow
        guard !draining else { return }
        if let window {
            if !offscreen { window.makeKeyAndOrderFront(nil) }
            return
        }
        guard loading == nil else {
            pending = (settings, offscreen)
            return
        }
        let host = NSViewController()
        host.view = NSView(frame: .init(x: 0, y: 0, width: 760, height: 580))
        let header = NSTextField(labelWithString: documentType.title)
        header.font = .systemFont(ofSize: 20, weight: .semibold)
        let status = NSTextField(labelWithString: "Reading bundled notices…")
        status.textColor = .secondaryLabelColor
        let find = NSButton(title: "Find…", target: self, action: #selector(ApplicationNotices.find(_:)))
        let top = NSStackView(views: [header, NSView(), find])
        top.orientation = .horizontal
        top.alignment = .centerY
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let text = NSTextView(frame: .init(x: 0, y: 0, width: 720, height: 460))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .labelColor
        text.textContainerInset = .init(width: 10, height: 10)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.layoutManager?.allowsNonContiguousLayout = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.setAccessibilityLabel(documentType.title)
        scroll.documentView = text
        self.textView = text
        let stack = NSStackView(views: [top, status, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        host.view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: host.view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: host.view.bottomAnchor, constant: -18),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        let window = NoticesWindow(contentViewController: host)
        window.notices = self
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = documentType.title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = .init(width: 600, height: 420)
        window.setContentSize(.init(width: 760, height: 580))
        window.delegate = self
        ToolWindowChrome.install(in: window, settings: settings)
        controller = NSWindowController(window: window)
        if offscreen {
            window.setFrameOrigin(.init(x: -12000, y: -12000))
        } else {
            ToolWindowChrome.position(window, relativeTo: presentationOwner)
            window.makeKeyAndOrderFront(nil)
            ToolContentMotion.reveal(host.view, effect: .windows)
        }
        isLoading = true
        didLoad = false
        displayStatus = "Reading bundled notices…"
        let token = UUID()
        generation = token
        loading = Task { [self] in
            defer {
                isLoading = false
                loading = nil
                if let pending, !draining {
                    self.pending = nil
                    show(settings: pending.0, offscreen: pending.1)
                }
            }
            do {
                guard let resources = Bundle.main.resourceURL else { throw BundledNoticeReader.Failure.unavailable }
                let document = try await reader.read(resources: resources, document: documentType)
                guard !Task.isCancelled, generation == token, controller?.window === window else { return }
                text.string = document.text
                switch documentType {
                case .thirdParty: displayStatus = "\(document.components) dependency components · Rust standard-library notices · bundled locally"
                case .projectLicense: displayStatus = "GNU GPL version 3 · no warranty · bundled locally"
                }
                status.stringValue = displayStatus
                didLoad = true
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                displayStatus = "Bundled notices are unavailable in this build."
                status.stringValue = displayStatus
            }
        }
    }
    @objc func find(_ sender: Any?) {
        guard let textView else { return }
        window?.makeFirstResponder(textView)
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performFindPanelAction(action)
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        generation = UUID()
        loading?.cancel()
        controller = nil
        textView = nil
    }
    func closeAndDrain() async {
        draining = true
        pending = nil
        window?.close()
        while let loading { await loading.value }
        draining = false
    }
    #if DEBUG
        var textForVerification: String { textView?.string ?? "" }
    #endif
}

@MainActor extension BrowserViewController {
    @objc func showBundledNotices(_ sender: Any?) {
        guard !isBrowserSuspended else { return }
        ApplicationNotices.shared.show(settings: settings)
    }
}
