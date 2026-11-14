import AppKit
import ExplorerCore
@_spi(ArchiveProduction) import FileOperations
@_spi(ArchiveProduction) @_spi(Qualification) import LocalStorage

/// The common product policy and independent publication owner must both
/// permit selected-file reception. A product switch cannot lift a backend hold.
@MainActor enum SMBDownloadFeature {
    #if DEBUG
    static var qualifying = false
    #endif
    static var available: Bool {
        if GeneratedSandboxReview.publicSelectionDownloadAdmitted {
            return GeneratedSandboxReview.smbPublicSelectionDownloadAdmitted
        }
        // The generated v7 gate is an SFTP-only signed experiment.
        if GeneratedSandboxReview.v7DownloadAdmitted { return false }
        // The qualified route exposes one regular file. Group and folder
        // requests still pass through their own capability checks.
        if RemoteDownloadPublicationFeature.qualifiesSMBPublicQuarantineDownload { return true }
        guard RemoteDownloadPublicationFeature.smbSingleFileAvailable else { return false }
        if RemoteDownloadPublicationFeature.singleFileReviewAdmitted { return true }
        #if DEBUG
        if qualifying { return true }
        #endif
        return AppFeatureAvailability.allows(.serverDownloads)
    }
}

/// Captures one explicit remote observation and a local destination. The SMB
/// pump owns reading; LocalStorage owns bodies; the existing engine owns writes.
@MainActor final class BrowserSMBDownload: NSObject {
    private weak var browser: BrowserViewController?
    private var work: Task<Void, Never>?, menu: NSMenu?, chosenPeer: UUID?
    private var dragDraft: RemoteDownloadDragOffer?, activeDrag: RemoteDownloadDragOffer?
    private var dragSequence: Int?
    #if DEBUG
    var chooseForVerification: ((NSSavePanel) async -> URL?)?
    private(set) var lastOutcome: RecoverableOperationResult?
    private(set) var lastNotice = ""
    private(set) var lastFailureCodeForVerification = ""
    private(set) var lastTimings: (receive: Double, publication: Double, complete: Double)?
    var destinationAccessForQualification: ((FileAccessLifetimes) async -> Void)?
    var destinationCheckedForQualification: (() async -> Void)?
    var receivedForQualification: (() async throws -> Void)?
    private(set) var bodyRequestsForQualification = 0
    var didReceiveBytesForQualification: (@Sendable (UInt64) -> Void)?
    #endif
    private typealias Peer = LocalPaneDestination
    init(browser: BrowserViewController) { self.browser = browser }
    func dragWriter(from owner: SMBTabController, row: Int) -> (any NSPasteboardWriting)? {
        guard RemoteDownloadDrag.smbAvailable, let browser, owner.rows.table.selectedRowIndexes.contains(row),
              canRequest(from: owner) else { return nil }
        if let dragDraft, dragDraft.isCurrent() { return dragDraft.markerWriter(for: row) }
        let selection: RemoteDownloadDragOffer.Selection
        if let plan = owner.sealedBatchDownload { selection = .smbFiles(plan) }
        else if let folder = owner.selectedFolderDownload { selection = .smbFolder(folder) }
        else if let file = owner.selectedDownload { selection = .smbFile(file) }
        else { return nil }
        let draft = RemoteDownloadDragOffer(browser: browser, owner: owner,
            rows: owner.rows.table.selectedRowIndexes, selection: selection)
        dragDraft = draft
        return draft.markerWriter(for: row)
    }
    func dragBegan(from owner: SMBTabController, session: NSDraggingSession, rows: IndexSet) {
        guard let dragDraft, dragDraft.table === owner.rows.table, dragDraft.rows == rows,
              RemoteDownloadDrag.begin(dragDraft, session: session) else { self.dragDraft = nil; return }
        activeDrag = dragDraft; self.dragDraft = nil; dragSequence = session.draggingSequenceNumber
    }
    func dragEnded(session: NSDraggingSession) {
        guard dragSequence == session.draggingSequenceNumber else { dragDraft = nil; return }
        if let table = activeDrag?.table { RemoteDownloadDrag.end(table: table, sequence: session.draggingSequenceNumber) }
        dragDraft = nil; activeDrag = nil; dragSequence = nil
    }
    func canRequest(from owner: SMBTabController, toPane: Bool = false) -> Bool {
        if owner.sealedBatchDownload != nil, let browser { return browser.remoteBatchDownload.canRequest(from: owner, toPane: toPane) }
        if owner.selectedFolderDownload != nil, let browser { return browser.smbFolderDownload.canRequest(from: owner, toPane: toPane) }
        guard SMBDownloadFeature.available, work == nil, let browser, !browser.isBrowserSuspended,
              browser.canRunExclusiveFileCommand, browser.view.window?.attachedSheet == nil,
              browser.smbTabs[browser.activeID] === owner, !owner.isClosing, owner.downloads != nil,
              let selection = owner.selectedDownload, browser.recoverableFileOperations != nil else { return false }
        return !toPane || (selection.proposedLocalName != nil && !peers(browser).isEmpty)
    }
    private func peers(_ browser: BrowserViewController) -> [Peer] {
        LocalPaneDestination.available(from: browser)
    }
    func request(from owner: SMBTabController, toPane: Bool) {
        if owner.sealedBatchDownload != nil, let browser { browser.remoteBatchDownload.request(from: owner, toPane: toPane); return }
        if owner.selectedFolderDownload != nil, let browser { browser.smbFolderDownload.request(from: owner, toPane: toPane); return }
        _ = request(from: owner, toPane: toPane, dropped: nil)
    }
    @discardableResult func requestDropped(from owner: SMBTabController, expected: SMBDownloadSelection,
        destination: ArchiveExtractionDestination, current: @escaping @MainActor () -> Bool) -> Bool {
        guard RemoteDownloadDrag.smbAvailable, destination.matchesObservedDirectory, current(),
              expected.proposedLocalName != nil, RemoteDownloadDragOffer.matchesFile(expected, owner.selectedDownload) else { return false }
        return request(from: owner, toPane: false, dropped: destination)
    }
    @discardableResult private func request(from owner: SMBTabController, toPane: Bool,
        dropped: ArchiveExtractionDestination?) -> Bool {
        let diagnostic = RemoteTransferDiagnostics(.download)
        guard SMBDownloadFeature.available, work == nil, let browser, !browser.isBrowserSuspended,
              browser.canRunExclusiveFileCommand, browser.view.window?.attachedSheet == nil,
              browser.smbTabs[browser.activeID] === owner, !owner.isClosing, let storage = owner.downloads,
              let selection = owner.selectedDownload, let engine = browser.recoverableFileOperations else { diagnostic.finish(.blocked); return false }
        diagnostic.stage(.destination)
        let tab = browser.activeID, visit = browser.sessionID
        if toPane, selection.proposedLocalName == nil { browser.status.stringValue = "This item needs a local filename. Use Download… to choose one."; diagnostic.finish(.blocked); return false }
        var peer: Peer?
        if toPane {
            let values = peers(browser)
            guard let first = values.first else { browser.status.stringValue = "Open a writable local folder in another pane first."; diagnostic.finish(.blocked); return false }
            if values.count == 1 { peer = first }
            else {
                let offered = NSMenu(title: "Download to Pane"); offered.autoenablesItems = false
                for value in values { let item = offered.addItem(withTitle: value.title, action: #selector(selectPeer(_:)), keyEquivalent: ""); item.target = self; item.representedObject = value.pane }
                menu = offered; chosenPeer = nil; offered.popUp(positioning: nil, at: .init(x: 24, y: 24), in: owner.rows)
                peer = values.first { $0.pane == chosenPeer }; menu = nil; chosenPeer = nil
                guard peer != nil else { diagnostic.finish(.cancelled); return false }
            }
        }
        let preparation = UUID(), coordinator = browser.operationCoordinator
        guard coordinator.beginPreparation(owner: preparation) else { diagnostic.finish(.blocked); return false }
        browser.operationPreparationID = preparation
        let capturedPeer = peer
        work = Task { [self, browser, owner, engine] in
            let began = ProcessInfo.processInfo.systemUptime
            var received: SMBReceivedDownload?, progressTask: Task<Void, Never>?
            let updates = AsyncStream.makeStream(of: UInt64.self, bufferingPolicy: .bufferingNewest(1))
            var started = false
            defer {
                updates.continuation.finish(); progressTask?.cancel()
                if started { browser.finishOperationPresentation() }
                else { coordinator.finishPreparation(owner: preparation); browser.operationPreparationTask = nil; browser.operationPreparationID = nil }
                work = nil
                diagnostic.finish(.cancelled)
            }
            do {
                let destination: URL
                if let dropped, let name = selection.proposedLocalName { destination = dropped.directory.appendingPathComponent(name) }
                else if let capturedPeer, let name = selection.proposedLocalName { destination = capturedPeer.directory.appendingPathComponent(name) }
                else {
                    diagnostic.stage(.chooseDestination)
                    guard let window = browser.view.window else { throw CancellationError() }
                    let panel = NSSavePanel(); panel.title = "Download File"; panel.prompt = "Download"
                    panel.message = "Download this selected file (up to 1 GiB). Existing files will be preserved. The remote file stays unchanged."
                    panel.nameFieldStringValue = selection.proposedLocalName ?? "Downloaded file"; panel.canCreateDirectories = false; panel.isExtensionHidden = false
                    #if DEBUG
                    if let chooseForVerification { guard let selected = await chooseForVerification(panel) else { return }; destination = selected }
                    else { guard await panel.beginSheetModal(for: window) == .OK, let selected = panel.url else { return }; destination = selected }
                    #else
                    guard await panel.beginSheetModal(for: window) == .OK, let selected = panel.url else { return }; destination = selected
                    #endif
                }
                let receiver: BrowserViewController
                if let capturedPeer {
                    guard let peer = capturedPeer.currentBrowser(from: browser) else { throw SMBDirectoryFailure.stale }
                    receiver = peer
                } else { receiver = browser }
                @MainActor func requireCurrentSelection() throws {
                    try Task.checkCancellation()
                    guard !browser.isBrowserSuspended, browser.activeID == tab, browser.sessionID == visit,
                          browser.smbTabs[tab] === owner, !owner.isClosing, owner.session.latest.failure == nil,
                          owner.selectedDownload?.snapshot == selection.snapshot,
                          owner.selectedDownload?.observation == selection.observation, browser.recoverableFileOperations === engine,
                          destination.isFileURL else { throw SMBDirectoryFailure.stale }
                    if let capturedPeer, capturedPeer.currentBrowser(from: browser) !== receiver { throw SMBDirectoryFailure.stale }
                }
                try requireCurrentSelection()
                diagnostic.stage(.access)
                let parent = destination.deletingLastPathComponent()
                let lifetime: FileAccessLifetimes
                if let dropped { lifetime = dropped.access }
                else { lifetime = await receiver.accessLifetime(for: [parent]) }
                defer { withExtendedLifetime(lifetime) {} }
                #if DEBUG
                if let destinationAccessForQualification { await destinationAccessForQualification(lifetime) }
                #endif
                try requireCurrentSelection()
                diagnostic.stage(.destination)
                let destinationObservation: FileOperationSelection
                if RemoteDownloadPublicationFeature.qualifiesSingleFileAdoption {
                    destinationObservation = try await storage.checkAdoptionDestination(using: engine,
                        parent: parent, name: destination.lastPathComponent)
                } else {
                    destinationObservation = try await engine.checkReceivedFileDestination(parent: parent,
                        name: destination.lastPathComponent, observing: dropped?.observation)
                }
                #if DEBUG
                if let destinationCheckedForQualification { await destinationCheckedForQualification() }
                #endif
                try requireCurrentSelection()
                guard browser.startOperationPresentation("Downloading selected file…", preparation: preparation, diagnosticTrace: diagnostic.trace) else { throw SMBDirectoryFailure.busy }
                started = true; browser.operationPreparationID = nil; browser.operationPreparationTask = nil; browser.operationTask = work
                browser.status.stringValue = "Downloading “\(destination.lastPathComponent)”… Traverse will check and save it locally."
                progressTask = Task { [weak browser] in
                    for await bytes in updates.stream {
                        diagnostic.stage(.receive, count: bytes)
                        guard let browser, !browser.operationStopRequested else { continue }
                        browser.operationPresentation = .init(phaseTitle: "Download", percentage: selection.logicalBytes == 0 ? nil : min(1, Double(bytes) / Double(selection.logicalBytes)),
                            summary: "Downloading and checking this file. Stop closes the connection.", destinationPath: destination.path,
                            currentItem: destination.lastPathComponent, completedText: "\(FileSizeText.string(Int64(bytes))) received")
                        browser.updateOperationProgressControls()
                    }
                }
                updates.continuation.yield(0)
                diagnostic.stage(.receive, count: 0)
                let receiving = ProcessInfo.processInfo.systemUptime
                #if DEBUG
                bodyRequestsForQualification += 1
                #endif
                #if DEBUG
                let generatedObserver = didReceiveBytesForQualification
                let copy = try await owner.session.download(selection, storage: storage, progress: { updates.continuation.yield($0); generatedObserver?($0) })
                #else
                let copy = try await owner.session.download(selection, storage: storage, progress: { updates.continuation.yield($0) })
                #endif
                received = copy
                #if DEBUG
                if let receivedForQualification { try await receivedForQualification() }
                #endif
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                try Task.checkCancellation()
                let publishing = ProcessInfo.processInfo.systemUptime
                diagnostic.stage(.prepareHistory)
                try await coordinator.prepareOperationState(for: engine); try Task.checkCancellation()
                diagnostic.stage(.verify)
                diagnostic.stage(.publish)
                let (outcome, removed) = try await RemoteReceivedFile.smb(copy).publishSingleFile(using: engine,
                    parent: parent, name: destination.lastPathComponent, observing: destinationObservation,
                    progress: browser.operationProgressSink, expectedDestination: destination,
                    revalidating: requireCurrentSelection)
                received = nil
                diagnostic.publication(outcome.result, stagingRemoved: removed)
                browser.lastOperationResult = outcome.result; browser.lastRecoveryRecordID = outcome.recordID; browser.lastRecoveryAction = nil
                browser.lastTransferContinuation = nil; browser.continuationMoveClipboard = nil; browser.operationResultsButton.isHidden = false
                let message = outcome.result.disposition == .succeeded
                    ? "Downloaded “\(destination.lastPathComponent)”. Remote file unchanged. Open Results for details." + (removed ? "" : " Temporary staging needs review in Connection Activity.")
                    : "This download needs review. Open Results for details; existing files are preserved."
                if browser.activeID == tab, browser.sessionID == visit, browser.smbTabs[tab] === owner {
                    owner.showTransferOutcome(message, needsAttention: outcome.result.disposition != .succeeded || !removed,
                                              showsUploadHistory: false)
                }
                #if DEBUG
                lastOutcome = outcome; lastNotice = message
                lastTimings = (publishing - receiving, ProcessInfo.processInfo.systemUptime - publishing, ProcessInfo.processInfo.systemUptime - began)
                #endif
                coordinator.reloadLocalDirectory(parent)
                browser.inspectOperationRecovery()
            } catch {
                #if DEBUG
                if let failure = error as? SMBBrowserFailure { lastFailureCodeForVerification = String(describing: failure) }
                else if let failure = error as? SMBDirectoryFailure { lastFailureCodeForVerification = String(describing: failure) }
                else { lastFailureCodeForVerification = String(reflecting: type(of: error)) }
                #endif
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                if received != nil { diagnostic.stage(.retain) }
                await received?.retainForReview()
                let message = Self.message(error, stopped: Task.isCancelled)
                if browser.activeID == tab, browser.sessionID == visit, browser.smbTabs[tab] === owner {
                    owner.showTransferOutcome(message, needsAttention: true, showsUploadHistory: false)
                }
                if owner.session.latest.failure != nil || Task.isCancelled && started {
                    diagnostic.stage(.drain); diagnostic.drained(await owner.close().value)
                }
                diagnostic.fail(error, stopped: Task.isCancelled)
                #if DEBUG
                lastNotice = message
                #endif
            }
        }
        browser.operationPreparationTask = work
        return true
    }
    @objc private func selectPeer(_ item: NSMenuItem) { if menu?.items.contains(where: { $0 === item }) == true { chosenPeer = item.representedObject as? UUID } }
    private static func message(_ error: Error, stopped: Bool) -> String {
        if stopped || error is CancellationError || error as? SMBDirectoryFailure == .stopped || error as? SMBBrowserFailure == .stopped {
            return "Download stopped. No unverified file was published. Connection closure and any retained staging can be reviewed."
        }
        if error as? SMBDirectoryFailure == .stale { return "The selection or destination changed. Choose Download again; nothing was published." }
        if let issue = error as? SMBDownloadStorageIssue {
            switch issue {
            case .full: return "Download staging is full or its limit was reached. Review inactive files in Connection Storage, then choose Download again."
            case .busy: return "Download staging is busy. Wait for its current users to finish."
            case .changed: return "Download staging changed or could not be safely verified. Nothing was published; existing data is preserved."
            case .unavailable: return "Download staging is unavailable. Review Connection Storage and disk access; nothing was published."
            }
        }
        if let failure = error as? FileOperationFailure { return "Download was not published: \(failure.userMessage) Choose another destination or review access." }
        return "Download could not finish. Existing files are preserved; retained staging, if any, is in Connection Storage. Reconnect explicitly if needed."
    }
}
