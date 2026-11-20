import AppKit
import FileOperations
import LocalStorage

@MainActor enum ArchiveTextReview {
    static func show(source: URL, left: String, right: String, from browser: BrowserViewController,
                     relativeTo parent: NSWindow?,
                     read: @escaping @Sendable (FileAccessLifetimes) async throws -> TextComparisonDocuments) {
        guard let parent, let workspace = browser.workspace, !workspace.isClosing else { return }
        let labels = EditorComparisonWindow.Labels(title: "Compare Archive Text", source: source.lastPathComponent,
            left: left, right: right,
            detail: "Compare two members without extracting them. If the archive changes, select the members again to review the new versions.",
            refresh: "Refresh")
        func language(_ name: String) -> TextSyntaxLanguage {
            .inferred(extension: EditorOpeningSupport.key(forFilename: (name as NSString).lastPathComponent) ?? "")
        }
        workspace.presentTextComparison(relativeTo: parent, settings: browser.settings, labels: labels) { [access = browser.folderAccess] in
            let lifetime = try await access.retainComparisonAccess(for: [source])
            do {
                return .init(documents: try await read(lifetime), leftLanguage: language(left), rightLanguage: language(right))
            } catch is CancellationError {
                throw CancellationError()
            } catch is TextDocumentFailure {
                throw EditorComparisonLoadFailure.unavailable("Choose two UTF-8 members with consistent line endings.")
            } catch {
                throw EditorComparisonLoadFailure.unavailable(ArchiveTextPreviewOwner.message(error, mode: .text))
            }
        }
    }
}

enum ZIPTextPreviewFeature {
    static let ordinaryEnabled = true
    static var available: Bool {
        #if DEBUG
            ordinaryEnabled || ProcessInfo.processInfo.arguments.contains("--check-zip-text-preview")
        #else
            ordinaryEnabled
        #endif
    }
}

enum ZIPBytePreviewFeature {
    static let ordinaryEnabled = true
    static var available: Bool {
        #if DEBUG
            ordinaryEnabled || ProcessInfo.processInfo.arguments.contains("--check-archive-byte-preview")
        #else
            ordinaryEnabled
        #endif
    }
}

enum ArchivePreviewMode: Sendable, Equatable {
    case text, hexadecimal, image

    static func preferred(for filename: String?) -> Self {
        filename.map(ArchiveImagePreview.supportsFilename) == true ? .image : .text
    }
    var title: String {
        switch self { case .text: "Text Preview"; case .hexadecimal: "Hex Preview"; case .image: "Image Preview" }
    }
    var commandTitle: String {
        switch self { case .text: "Preview Text"; case .hexadecimal: "Preview as Hex"; case .image: "Preview Image" }
    }
}

enum TARTextPreviewFeature {
    static var available: Bool {
        if AppFeatureAvailability.allows(.archiveTextPreview) { return true }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--check-tar-preview-native")
            || ProcessInfo.processInfo.arguments.contains("--check-tar-archive")
            || ProcessInfo.processInfo.arguments.contains("--check-inline-archives")
            || ProcessInfo.processInfo.arguments.contains("--check-inline-archive-motion")
        #else
        return false
        #endif
    }
}

private enum ArchivePreviewDocument: Sendable {
    case text(ZIPTextPreview), bytes(ZIPBytePreview)
    case tarText(TARTextPreview), tarBytes(TARBytePreview)
    case image(ArchiveImagePreview, checksumVerified: Bool)
}

/// A single actual reader owner, independent of window visibility. New explicit
/// selections replace demand only after the previous native read really ends.
@MainActor final class ArchiveTextPreviewOwner {
    private enum Reader: Sendable { case zip(ZIPArchiveReader), tar(TARArchiveReader) }
    private enum Selection: Sendable {
        case zip(ZIPTextPreviewSelection), tar(TARTextPreviewSelection)
        var displayName: String { switch self { case .zip(let item): item.displayName; case .tar(let item): item.displayName } }
    }
    private struct Request {
        let selection: Selection
        let lifetime: any Sendable
        let generation: UUID
        let mode: ArchivePreviewMode
    }
    private let reader: Reader
    private let settings: BrowserSettings
    private var controller: ArchiveTextPreviewWindowController?
    private var desired: Request?
    private var work: Task<Void, Never>?
    private var reading: Task<ArchivePreviewDocument, Error>?
    private var generation = UUID()
    private var closed = false, suspended = false, stopping = false
    var onBusy: ((Bool) -> Void)?
    var isReading: Bool { work != nil }
    var retainsPresentation: Bool { isReading || controller?.window?.isVisible == true }
    init(reader: ZIPArchiveReader, settings: BrowserSettings) {
        self.reader = .zip(reader)
        self.settings = settings
    }
    init(tarReader: TARArchiveReader, settings: BrowserSettings) {
        self.reader = .tar(tarReader)
        self.settings = settings
    }

    func open(_ selection: ZIPTextPreviewSelection, retaining lifetime: any Sendable, offscreen: Bool = false, mode: ArchivePreviewMode = .text) {
        guard case .zip = reader else { return }
        open(.zip(selection), retaining: lifetime, offscreen: offscreen, mode: mode)
    }
    func open(_ selection: TARTextPreviewSelection, retaining lifetime: any Sendable, offscreen: Bool = false, mode: ArchivePreviewMode = .text) {
        guard case .tar = reader, TARTextPreviewFeature.available else { return }
        open(.tar(selection), retaining: lifetime, offscreen: offscreen, mode: mode)
    }
    private func open(_ selection: Selection, retaining lifetime: any Sendable, offscreen: Bool, mode: ArchivePreviewMode) {
        guard !closed, !suspended, !ApplicationFileActivity.gate.isClosed,
              mode != .hexadecimal || ZIPBytePreviewFeature.available else { return }
        stopping = false
        generation = UUID()
        desired = .init(selection: selection, lifetime: lifetime, generation: generation, mode: mode)
        reading?.cancel()
        if controller == nil {
            let created = ArchiveTextPreviewWindowController(settings: settings)
            created.onStop = { [weak self] in self?.stop() }
            created.onClose = { [weak self] in
                guard let self else { return }
                stop()
                controller?.clear()
                controller = nil
            }
            controller = created
        }
        controller?.begin(name: selection.displayName, mode: mode)
        if let window = controller?.window {
            if offscreen {
                window.setFrameOrigin(.init(x: -12000, y: -12000))
            } else {
                if !window.isVisible { ToolWindowChrome.position(window, relativeTo: NSApplication.shared.keyWindow) }
                window.makeKeyAndOrderFront(nil)
                if let view = (window.contentViewController as? ToolWindowChrome)?.contentHost {
                    ToolContentMotion.reveal(view, effect: .windows)
                }
            }
        }
        if work == nil {
            onBusy?(true)
            work = Task { [self] in await loadLoop() }
        }
    }
    private func loadLoop() async {
        defer {
            reading = nil
            work = nil
            if stopping {
                controller?.fail("Selected read stopped. Choose Preview to try again.")
                stopping = false
            }
            onBusy?(false)
        }
        while !closed, !suspended, let request = desired {
            desired = nil
            let task = Task { [reader] () async throws -> ArchivePreviewDocument in
                switch (reader, request.selection, request.mode) {
                case (.zip(let reader), .zip(let selection), .text): return .text(try await reader.previewText(selection, retaining: request.lifetime))
                case (.zip(let reader), .zip(let selection), .hexadecimal): return .bytes(try await reader.previewBytes(selection, retaining: request.lifetime))
                case (.zip(let reader), .zip(let selection), .image):
                    return .image(try await reader.previewImage(selection, retaining: request.lifetime), checksumVerified: true)
                case (.tar(let reader), .tar(let selection), .text): return .tarText(try await reader.previewText(selection, retaining: request.lifetime))
                case (.tar(let reader), .tar(let selection), .hexadecimal): return .tarBytes(try await reader.previewBytes(selection, retaining: request.lifetime))
                case (.tar(let reader), .tar(let selection), .image):
                    return .image(try await reader.previewImage(selection, retaining: request.lifetime), checksumVerified: false)
                default: throw TARTextPreviewFailure.unsupported
                }
            }
            reading = task
            do {
                let document = try await task.value
                #if DEBUG
                    if let beforePublicationForVerification { await beforePublicationForVerification() }
                #endif
                guard !closed, !suspended, request.generation == generation else { continue }
                controller?.display(document)
            } catch {
                guard !closed, !suspended, request.generation == generation else { continue }
                controller?.fail(Self.message(error, mode: request.mode))
            }
            reading = nil
        }
    }
    func stop(closeWindow: Bool = false) {
        generation = UUID()
        desired = nil
        reading?.cancel()
        stopping = isReading
        controller?.fail(isReading ? "Stopping the selected read…" : "Preview closed.")
        if closeWindow {
            controller?.close()
            controller?.clear()
            controller = nil
        }
    }
    func prepareForVolumeQuiescence() {
        suspended = true
        stop(closeWindow: true)
    }
    func resumeAfterVolumeQuiescence() { suspended = false }
    func drain() async {
        if let work { await work.value }
        switch reader { case .zip(let reader): await reader.drain(); case .tar(let reader): await reader.drain() }
    }
    func closeAndDrain() async {
        closed = true
        stop(closeWindow: true)
        await drain()
    }
    static func message(_ error: Error, mode: ArchivePreviewMode = .text) -> String {
        switch error {
        case ArchiveImagePreviewFailure.invalidImage: "This image could not be read. Its format may not match its name."
        case ArchiveImagePreviewFailure.dimensionsTooLarge: "This image has too many pixels to preview in Traverse."
        case ZIPTextPreviewFailure.notText, TARTextPreviewFailure.notText:
            ZIPBytePreviewFeature.available
                ? "This member is not supported UTF-8 text, or contains unsupported control characters. Choose Preview as Hex for a byte view, or Extract Selected to open it separately."
                : "This member is not supported UTF-8 text, or contains unsupported control characters. Use Extract Selected to open it separately."
        case ZIPTextPreviewFailure.tooLarge, ZIPTextPreviewFailure.limitReached, TARTextPreviewFailure.tooLarge, TARTextPreviewFailure.limitReached:
            mode == .image ? "This image exceeds Traverse’s 16 MiB preview limit or took too long to read."
                : "Selected preview supports complete files up to 256 KiB within its read limits. Use Extract Selected for this member."
        case ZIPTextPreviewFailure.unsupported:
            "Encrypted members, links and this compression method cannot be previewed."
        case TARTextPreviewFailure.unsupported:
            "Only a selected regular file can be previewed. Use Extract Selected for other supported items."
        case ZIPContentFailure.contentMismatch:
            "The selected member failed its length or checksum check. No content was shown."
        case ZIPContentFailure.unsupported, ZIPContentFailure.codecUnavailable:
            "The system decoder could not preview this member. No content was shown."
        case ZIPContentFailure.limitReached:
            "The selected member exceeds the preview expansion limits. Use Extract Selected instead."
        case ZIPArchiveFailure.stopped, TARArchiveFailure.stopped, is CancellationError:
            "Selected read stopped. Choose Preview to try again."
        case is TARArchiveFailure: TARBrowserModel.message(error)
        default: ArchiveBrowserModel.message(error)
        }
    }
    #if DEBUG
        var beforePublicationForVerification: (@MainActor () async -> Void)?
        var windowForVerification: NSWindow? { controller?.window }
        var textForVerification: String? { controller?.textView.string }
        var statusForVerification: String? { controller?.status.stringValue }
        var statusTipForVerification: String? { controller?.status.toolTip }
        var imageSizeForVerification: NSSize? { controller?.displayedImageSize }
        var imageCanvasForVerification: RasterPreviewView? { controller?.imageView }
        var viewportForVerification: NSView? { controller?.textView.enclosingScrollView?.contentView }
        var textFontPointsForVerification: CGFloat? { controller?.textView.font?.pointSize }
        var hexadecimalLayoutForVerification: Bool {
            guard let text = controller?.textView else { return false }
            return text.isHorizontallyResizable && text.textContainer?.widthTracksTextView == false
                && text.enclosingScrollView?.hasHorizontalScroller == true
        }
        var wrappedTextLayoutForVerification: Bool {
            guard let text = controller?.textView else { return false }
            return !text.isHorizontallyResizable && text.textContainer?.widthTracksTextView == true
                && text.enclosingScrollView?.hasHorizontalScroller == false
        }
        var plainTextPolicyForVerification: Bool {
            guard let text = controller?.textView else { return false }
            return !text.isEditable && !text.isRichText && !text.isAutomaticLinkDetectionEnabled
                && !text.isContinuousSpellCheckingEnabled && !text.isAutomaticDataDetectionEnabled
                && !text.allowsUndo && !text.importsGraphics
        }
        var renderedTextFitsViewportForVerification: Bool {
            guard let text = controller?.textView, let container = text.textContainer,
                  let layout = text.layoutManager, let scroll = text.enclosingScrollView,
                  !text.isHorizontallyResizable, container.widthTracksTextView else { return false }
            layout.ensureLayout(for: container)
            return layout.usedRect(for: container).width <= scroll.contentSize.width + 1
        }
        func layoutForVerification() { controller?.window?.contentView?.layoutSubtreeIfNeeded() }
        func findForVerification() { controller?.find(nil) }
    #endif
}

@MainActor private final class ArchivePreviewWindow: ToolMotionWindow {
    weak var preview: ArchiveTextPreviewWindowController?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command || modifiers == [.command, .shift], preview?.showsImage == true {
            switch event.charactersIgnoringModifiers {
            case "+", "=": preview?.imageView.zoomIn(); return true
            case "-": preview?.imageView.zoomOut(); return true
            case "0": preview?.imageView.fitImage(nil); return true
            default: break
            }
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f":
                preview?.find(nil)
                return true
            case "w":
                performClose(nil)
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor private final class ArchiveTextPreviewWindowController: NSWindowController, NSWindowDelegate {
    let textView = NSTextView(frame: .init(x: 0, y: 0, width: 740, height: 450))
    let status = NSTextField(wrappingLabelWithString: "Reading selected text…")
    private let heading = NSTextField(labelWithString: "Text Preview")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let findButton = NSButton(title: "Find…", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let scroll = NSScrollView()
    let imageView = RasterPreviewView()
    private var mode: ArchivePreviewMode = .text
    var showsImage: Bool { mode == .image && imageView.image != nil }
    var displayedImageSize: NSSize? { imageView.image?.size }
    var onStop: (() -> Void)?, onClose: (() -> Void)?
    init(settings: BrowserSettings) {
        let host = NSViewController()
        host.view = NSView(frame: .init(x: 0, y: 0, width: 820, height: 580))
        let window = ArchivePreviewWindow(contentViewController: host)
        super.init(window: window)
        window.preview = self
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Text Preview"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(.init(width: 820, height: 580))
        window.contentMinSize = .init(width: 560, height: 360)
        window.delegate = self
        InterfaceMetrics.setFont(heading, base: .systemFont(ofSize: 18, weight: .semibold))
        heading.lineBreakMode = .byTruncatingMiddle
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.textColor = .secondaryLabelColor
        InterfaceMetrics.setFont(status, base: .systemFont(ofSize: 12))
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        stopButton.target = self
        stopButton.action = #selector(stopRead(_:))
        findButton.target = self; findButton.action = #selector(find(_:))
        for button in [stopButton, findButton] {
            InterfaceMetrics.setFont(button, base: .systemFont(ofSize: 12))
        }
        let top = NSStackView(views: [heading, NSView(), progress, stopButton, findButton])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 10
        top.setHuggingPriority(.required, for: .vertical)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        InterfaceMetrics.setFont(textView, base: .monospacedSystemFont(ofSize: 12, weight: .regular))
        textView.textColor = .labelColor
        textView.textContainerInset = .init(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.setAccessibilityLabel("Read-only selected archive text")
        scroll.documentView = textView
        let viewport = NSView()
        pin(scroll, inside: viewport)
        imageView.setContentHuggingPriority(.init(rawValue: 100), for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.isHidden = true
        pin(imageView, inside: viewport, inset: 4)
        let footer = NSTextField(labelWithString: "Read-only snapshot · selected member only · no archive changes")
        InterfaceMetrics.setFont(footer, base: .systemFont(ofSize: 11))
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = host.view
        for child in [top, status, viewport, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
                child.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            ])
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            status.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            viewport.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            viewport.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            footer.topAnchor.constraint(equalTo: viewport.bottomAnchor, constant: 10),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        ToolWindowChrome.install(in: window, settings: settings)
    }
    required init?(coder: NSCoder) { nil }
    func begin(name: String, mode: ArchivePreviewMode) {
        clear()
        self.mode = mode
        heading.stringValue = name
        window?.title = name + " — " + mode.title
        let showsImage = mode == .image
        scroll.isHidden = showsImage; imageView.isHidden = !showsImage; findButton.isHidden = showsImage
        let hex = mode == .hexadecimal
        scroll.hasHorizontalScroller = hex
        textView.isHorizontallyResizable = hex
        textView.autoresizingMask = hex ? [] : [.width]
        textView.textContainer?.widthTracksTextView = !hex
        if hex {
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        } else if scroll.contentSize.width > 0 {
            textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.setAccessibilityLabel(hex ? "Read-only selected archive bytes" : "Read-only selected archive text")
        status.stringValue = showsImage ? "Opening image…" : "Reading and checking the complete selected member…"
        stopButton.isHidden = false
        progress.startAnimation(nil)
    }
    func display(_ document: ArchivePreviewDocument) {
        switch document {
        case .text(let document):
            textView.string = document.text
            status.stringValue = "\(document.utf8Bytes.formatted()) UTF-8 bytes · complete selected member · length and checksum checked"
        case .bytes(let document):
            textView.string = document.hexadecimalText
            status.stringValue = "\(document.byteCount.formatted()) bytes · hexadecimal offsets · complete selected member · length and checksum checked"
        case .tarText(let document):
            textView.string = document.text
            status.stringValue = "\(document.utf8Bytes.formatted()) UTF-8 bytes · complete selected file · source rechecked"
            status.toolTip = "The source and complete TAR metadata were revalidated. TAR has no per-file content checksum."
        case .tarBytes(let document):
            textView.string = document.hexadecimalText
            status.stringValue = "\(document.byteCount.formatted()) bytes · hexadecimal offsets · complete selected file · source rechecked"
            status.toolTip = "The source and complete TAR metadata were revalidated. TAR has no per-file content checksum."
        case .image(let preview, let checksumVerified):
            let size = NSSize(width: preview.image.width, height: preview.image.height)
            imageView.image = NSImage(cgImage: preview.image, size: size)
            let notes = [preview.showsFirstFrame ? "First image" : nil, preview.isDownsampled ? "Reduced preview" : nil].compactMap { $0 }
            status.stringValue = (["\(preview.width.formatted()) × \(preview.height.formatted()) pixels"] + notes).joined(separator: " · ")
            status.toolTip = checksumVerified ? "The selected ZIP member’s length and checksum were verified."
                : "The source and complete TAR metadata were revalidated. TAR has no per-file content checksum."
        }
        stopButton.isHidden = true
        progress.stopAnimation(nil)
        if mode == .image { ToolContentMotion.reveal(imageView) }
        else { ToolContentMotion.reveal(textView) }
    }
    func fail(_ message: String) {
        clear()
        status.stringValue = message
    }
    func clear() {
        textView.string = ""
        imageView.image = nil
        status.toolTip = nil
        progress.stopAnimation(nil)
        stopButton.isHidden = true
    }
    @objc func stopRead(_ sender: Any?) { onStop?() }
    @objc func find(_ sender: Any?) {
        guard mode != .image else { return }
        window?.makeFirstResponder(textView)
        let command = NSMenuItem()
        command.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performFindPanelAction(command)
    }
    func windowWillClose(_ notification: Notification) {
        clear()
        onClose?()
    }
}
