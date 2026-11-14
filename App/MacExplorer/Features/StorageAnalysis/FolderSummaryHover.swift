import AppKit
import Combine
import ExplorerCore
import LocalStorage
import StorageAnalysis

@MainActor
final class BrowserFolderSummaryController {
    private weak var browser: BrowserViewController?
    private let owner = UUID()
    private var target: FileEntry?
    private var dwell: Task<Void, Never>?
    private var fade: Task<Void, Never>?
    private var card: FolderSummaryCard?
    private var fadingCard: FolderSummaryCard?
    private var subscriptions: Set<AnyCancellable> = []
    private var observations: [BrowserNotificationObservation] = []
    private var revision = UUID()
    private var lastDiagnosticTarget: FileEntry?
    var isVisible: Bool { card?.superview != nil }
    #if DEBUG
    var summaryTextsForVerification: (size: String, counts: String)? { card?.valueTextsForVerification }
    var summaryStateForVerification: String { card?.stateForVerification ?? "no card" }
    var summaryPresentationForVerification: (fontSizes: [CGFloat], labelsFit: Bool)? {
        card?.presentationForVerification
    }
    private(set) var checkpointForVerification: DiagnosticContext?
    #endif

    init(browser: BrowserViewController) {
        self.browser = browser
        browser.table.onSummaryPointer = { [weak self, weak browser] point in
            guard let self, let browser, !browser.usesFileIcons else { return }
            let row = point.map(browser.table.row(at:)) ?? -1
            let entry = browser.displayedEntries.indices.contains(row) ? browser.displayedEntries[row] : nil
            self.pointer(entry: entry, point: point, source: browser.table)
        }
        browser.iconBrowser.collectionView.onSummaryPointer = { [weak self, weak browser] point in
            guard let self, let browser, browser.usesFileIcons else { return }
            self.pointer(entry: point.flatMap(browser.iconBrowser.summaryEntry(at:)), point: point,
                         source: browser.iconBrowser.collectionView)
        }
        browser.settings.$folderSummariesEnabled.combineLatest(browser.settings.$folderSummaryDelay)
            .dropFirst().sink { [weak self, weak browser] enabled, _ in
                self?.cancel()
                browser?.iconBrowser.showsFolderSummaries = enabled
                if !enabled { ApplicationStorageAnalysis.shared.clearCachedSummaries() }
            }.store(in: &subscriptions)
        browser.iconBrowser.showsFolderSummaries = browser.settings.folderSummariesEnabled
        browser.settings.$interfaceSize.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.cancel()
        }.store(in: &subscriptions)
        for scroll in [browser.folderScroll, browser.iconBrowser.scrollView] {
            observations.append(BrowserNotificationObservation(name: NSView.boundsDidChangeNotification,
                object: scroll.contentView) { [weak self] _ in MainActor.assumeIsolated { self?.cancel(reason: .scrolled) } })
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observations.append(BrowserNotificationObservation(name: name) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel(reason: .windowDeactivated) }
            })
        }
    }

    private func pointer(entry: FileEntry?, point: NSPoint?, source: NSView) {
        if entry == nil { lastDiagnosticTarget = nil }
        if let browser, let entry, entry.kind == .directory, entry != lastDiagnosticTarget {
            lastDiagnosticTarget = entry
            let flags = conditions(browser: browser, source: source)
            record(.hoverAdmission, phase: flags.isEmpty ? .requested : .blocked, flags: flags)
        }
        guard let browser, browser.settings.folderSummariesEnabled, !browser.isBrowserSuspended,
              !browser.isArchiveLocation, !browser.isRemoteLocation,
              !browser.isLoading, !browser.metadataSearch.isShowingResults, !browser.showsComputerVolumes,
              source.window?.isKeyWindow == true, NSEvent.pressedMouseButtons == 0,
              let entry, entry.kind == .directory, let point else { cancel(); return }
        guard target != entry else { return }
        cancel()
        target = entry
        let token = revision, visit = browser.sessionID, presentation = browser.filePresentationID
        record(.hoverDwell, phase: .waiting)
        let rawDelay = browser.settings.folderSummaryDelay
        let delay = rawDelay.isFinite ? min(5, max(0.3, rawDelay)) : 1
        dwell = Task { @MainActor [weak self, weak browser, weak source] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, let browser, let source, self.revision == token,
                  browser.sessionID == visit, browser.filePresentationID == presentation,
                  browser.settings.folderSummariesEnabled, !browser.isBrowserSuspended,
                  source.window?.isKeyWindow == true, NSEvent.pressedMouseButtons == 0 else {
                if let self, let browser, let source {
                    var flags = self.conditions(browser: browser, source: source)
                    if browser.sessionID != visit { flags.append(.visitChanged) }
                    if browser.filePresentationID != presentation { flags.append(.presentationChanged) }
                    self.record(.hoverDwell, phase: .blocked, flags: flags)
                }
                return
            }
            self.record(.hoverScan, phase: .presenting)
            self.show(entry: entry, at: point, source: source, browser: browser)
            ApplicationStorageAnalysis.shared.beginHover(owner: self.owner, entry: entry, browser: browser) { [weak self] value in
                guard let self, self.revision == token else { return }
                self.card?.render(value)
            }
        }
    }

    private func conditions(browser: BrowserViewController, source: NSView) -> [DiagnosticStateFlag] {
        var flags: [DiagnosticStateFlag] = []
        if !browser.settings.folderSummariesEnabled { flags.append(.summariesDisabled) }
        if browser.isBrowserSuspended { flags.append(.browserSuspended) }
        if browser.isLoading { flags.append(.browserLoading) }
        if browser.metadataSearch.isShowingResults { flags.append(.searchResults) }
        if browser.showsComputerVolumes { flags.append(.computerView) }
        if source.window?.isKeyWindow != true { flags.append(.windowNotKey) }
        if NSEvent.pressedMouseButtons != 0 { flags.append(.mouseButtonDown) }
        return flags
    }
    private func record(_ checkpoint: DiagnosticCheckpoint, phase: DiagnosticPhase, flags: [DiagnosticStateFlag] = []) {
        let context = DiagnosticContext(checkpoint, flags: flags)
        #if DEBUG
        checkpointForVerification = context
        #endif
        ApplicationDiagnostics.shared.event(.analysis, phase, trace: revision, context: context)
    }

    private func show(entry: FileEntry, at point: NSPoint, source: NSView, browser: BrowserViewController) {
        fade?.cancel(); fadingCard?.removeFromSuperview(); fadingCard = nil
        let host = browser.view
        let card = FolderSummaryCard(name: entry.name)
        InterfacePresentation.shared.register(card)
        let scale = InterfaceMetrics.scale
        let width = min(330 * scale, max(0, host.bounds.width - 16)), height = 136 * scale
        let anchor = source.convert(point, to: host)
        let x = min(max(host.bounds.minX + 8, anchor.x + 18), host.bounds.maxX - width - 8)
        let preferredY = host.isFlipped ? anchor.y + 18 : anchor.y - height - 18
        let y = min(max(host.bounds.minY + 8, preferredY), host.bounds.maxY - height - 8)
        card.frame = NSRect(x: x, y: y, width: width, height: height)
        host.addSubview(card, positioned: .above, relativeTo: nil)
        self.card = card
        if browser.settings.motion.allows(.pages), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            card.alphaValue = browser.settings.motion.mode.initialOpacity(0)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14 * browser.settings.motion.mode.durationScale
                card.animator().alphaValue = 1
            }
        }
    }

    func cancel(reason: DiagnosticStateFlag? = nil) {
        guard target != nil || dwell != nil || card != nil else { return }
        record(.hoverCancel, phase: .cancelled, flags: reason.map { [$0] } ?? [])
        revision = UUID(); target = nil
        dwell?.cancel(); dwell = nil
        ApplicationStorageAnalysis.shared.endHover(owner: owner)
        guard let old = card else { return }
        card = nil
        fade?.cancel(); fadingCard?.removeFromSuperview(); fadingCard = old
        let motion = browser?.settings.motion ?? .init()
        if !motion.allows(.pages) || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            old.removeFromSuperview(); fadingCard = nil
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12 * motion.mode.durationScale; old.animator().alphaValue = 0
            }
            fade = Task { @MainActor [weak self, weak old] in
                do { try await Task.sleep(for: .seconds(0.12 * motion.mode.durationScale + 0.01)) } catch { return }
                old?.removeFromSuperview()
                if self?.fadingCard === old { self?.fadingCard = nil }
            }
        }
    }
}

/// Informational overlay; pointer/selection stay with the native file view.
@MainActor
final class FolderSummaryCard: NSVisualEffectView {
    private let title = label("", size: 13, weight: .semibold)
    private let sizeLabel = label("Calculating…", size: 12)
    private let countsLabel = label("Reading folder metadata", size: 11, color: .secondaryLabelColor)
    private let stateLabel = NSTextField(wrappingLabelWithString: "Values update while you hover")
    private let spinner = NSProgressIndicator()
    #if DEBUG
    var valueTextsForVerification: (size: String, counts: String) {
        (sizeLabel.stringValue, countsLabel.stringValue)
    }
    var stateForVerification: String { stateLabel.stringValue }
    var presentationForVerification: (fontSizes: [CGFloat], labelsFit: Bool) {
        layoutSubtreeIfNeeded()
        let fit = [title, sizeLabel, countsLabel, stateLabel].allSatisfy {
            bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.convert($0.bounds, to: self))
                && $0.bounds.height + 0.5 >= $0.intrinsicContentSize.height
        }
        return ([title, sizeLabel, countsLabel, stateLabel].map { $0.font?.pointSize ?? 0 }, fit)
    }
    #endif

    init(name: String) {
        super.init(frame: .zero)
        material = .popover; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 10
        layer?.borderColor = NSColor.separatorColor.cgColor; layer?.borderWidth = 1
        title.stringValue = name; title.lineBreakMode = .byTruncatingMiddle
        InterfaceMetrics.setFont(sizeLabel, base: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 14).interfaceScaled.isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 14).interfaceScaled.isActive = true
        spinner.startAnimation(nil)
        InterfaceMetrics.setFont(stateLabel, base: .systemFont(ofSize: 11)); stateLabel.textColor = .secondaryLabelColor
        stateLabel.maximumNumberOfLines = 2
        let header = stack([title, spinner], orientation: .horizontal)
        let content = stack([header, sizeLabel, countsLabel, stateLabel], orientation: .vertical, spacing: 6)
        pin(content, inside: self, inset: 12)
        for row in [header, sizeLabel, countsLabel, stateLabel] { row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        setAccessibilityLabel("Folder summary for " + name)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func render(_ value: FolderSummaryValue) {
        if let counts = value.counts {
            countsLabel.stringValue = "\(counts.regularFiles) files · \(counts.directories) folders · \(counts.symbolicLinks) links"
        } else {
            countsLabel.stringValue = value.isRunning ? "Reading folder metadata" : "No counts available"
        }
        if let bytes = value.bytes {
            let count = value.counts?.regularFiles ?? 0
            sizeLabel.stringValue = metric(bytes.allForkLogical, files: count) + " · " + metric(bytes.allForkAllocated, files: count) + " allocated"
        } else {
            sizeLabel.stringValue = value.isRunning ? "Calculating…" : "Size not calculated"
        }
        stateLabel.stringValue = value.message
        if value.isRunning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        stateLabel.preferredMaxLayoutWidth = max(220, bounds.width - 24)
        stateLabel.invalidateIntrinsicContentSize()
    }

    private func metric(_ value: AnalysisMetricSubtotal, files: UInt64) -> String {
        guard !value.overflowed, let bytes = value.knownBytes, let signed = Int64(exactly: bytes) else { return "Unavailable" }
        let missing = value.notReturnedCount + value.failedCount
        if files > 0, missing >= files { return "Unknown" }
        return (missing > 0 ? "Known " : "") + FileSizeText.string(signed)
    }
}
