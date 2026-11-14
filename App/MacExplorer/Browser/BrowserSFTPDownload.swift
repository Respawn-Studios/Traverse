import AppKit
import Darwin
import ExplorerCore
@_spi(ArchiveProduction) import FileOperations
@_spi(ArchiveProduction) @_spi(Qualification) import LocalStorage

enum SFTPDownloadFeature {
    static let enabled = true
    #if DEBUG
    @MainActor static var qualifying = false
    @MainActor static var available: Bool {
        if GeneratedSandboxReview.publicSelectionDownloadAdmitted {
            return GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted
        }
        guard RemoteDownloadPublicationFeature.singleFileAvailable else { return false }
        if RemoteDownloadPublicationFeature.singleFileReviewAdmitted { return true }
        if qualifying { return true }
        return Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") == nil && enabled
    }
    #else
    static var available: Bool { enabled && RemoteDownloadPublicationFeature.singleFileAvailable }
    #endif
}

/// Captures one explicit remote observation and a local destination. The SFTP
/// pump owns reading; LocalStorage owns bodies; the existing engine owns writes.
@MainActor final class BrowserSFTPDownload: NSObject {
    private weak var browser: BrowserViewController?
    private var work: Task<Void, Never>?, menu: NSMenu?, chosenPeer: UUID?
    private var promiseDraft: SFTPFilePromiseExport?, activePromise: SFTPFilePromiseExport?
    private var internalDragDraft: RemoteDownloadDragOffer?, activeDragOffer: RemoteDownloadDragOffer?
    private var activeDragSequence: Int?
    #if DEBUG
    var activePromiseForVerification: SFTPFilePromiseExport? { activePromise }
    var promiseHandoffForVerification: ((SFTPFilePromiseExport) -> Void)?
    var chooseForVerification: ((NSSavePanel) async -> URL?)?
    private(set) var lastOutcome: RecoverableOperationResult?
    private(set) var lastNotice = ""
    private(set) var lastFailureCodeForVerification = ""
    private(set) var lastTimings: (receive: Double, publication: Double, complete: Double)?
    var destinationAccessForQualification: ((FileAccessLifetimes) async -> Void)?
    var destinationCheckedForQualification: (() async -> Void)?
    var receivedForQualification: (() async throws -> Void)?
    private(set) var bodyRequestsForQualification = 0
    #endif
    private typealias Peer = LocalPaneDestination
    init(browser: BrowserViewController) { self.browser = browser }
    func promiseWriter(from owner: SFTPTabController, row: Int) -> (any NSPasteboardWriting)? {
        if let selected = owner.rows.selectedFolderDownload {
            guard SFTPFilePromiseFeature.internalAvailable, row == owner.rows.table.selectedRow,
                  let browser, browser.sftpFolderDownload.canRequest(from: owner) else { return nil }
            promiseDraft?.retireUnlessHanded(); promiseDraft = nil
            if let internalDragDraft, internalDragDraft.isCurrent() { return internalDragDraft.markerWriter(for: row) }
            let draft = RemoteDownloadDragOffer(browser: browser, owner: owner,
                rows: owner.rows.table.selectedRowIndexes, selection: .folder(selected))
            internalDragDraft = draft
            return draft.markerWriter(for: row)
        }
        if let plan = owner.rows.selectedDownloadBatch {
            guard SFTPFilePromiseFeature.internalAvailable, owner.rows.table.selectedRowIndexes.contains(row),
                  let browser, browser.remoteBatchDownload.canRequest(from: owner) else { return nil }
            promiseDraft?.retireUnlessHanded(); promiseDraft = nil
            if let internalDragDraft, internalDragDraft.isCurrent() { return internalDragDraft.markerWriter(for: row) }
            let draft = RemoteDownloadDragOffer(browser: browser, owner: owner,
                rows: owner.rows.table.selectedRowIndexes, selection: .batch(plan))
            internalDragDraft = draft
            return draft.markerWriter(for: row)
        }
        guard SFTPFilePromiseFeature.available, row == owner.rows.table.selectedRow,
              canRequest(from: owner), let browser, let engine = browser.recoverableFileOperations,
              let storage = owner.downloads, let selection = owner.rows.selectedDownload,
              let candidate = SFTPFilePromiseCandidate(selection) else { return nil }
        internalDragDraft = nil
        if let promiseDraft, promiseDraft.candidate.matches(selection), promiseDraft.canHandOff {
            return promiseDraft.writer()
        }
        promiseDraft?.retireUnlessHanded()
        let draft = SFTPFilePromiseExport(candidate: candidate, browser: browser, owner: owner, engine: engine, storage: storage)
        promiseDraft = draft
        return draft.writer()
    }
    func promiseBegan(from owner: SFTPTabController, rows: IndexSet) {
        let selectedRow = owner.rows.table.selectedRow
        guard selectedRow >= 0, rows.count == 1, rows.contains(selectedRow),
              let promiseDraft, promiseDraft.candidate.matches(owner.rows.selectedDownload),
              promiseDraft.handOff() else { self.promiseDraft?.retireUnlessHanded(); self.promiseDraft = nil; return }
        activePromise = promiseDraft; self.promiseDraft = nil
        #if DEBUG
        promiseHandoffForVerification?(promiseDraft)
        #endif
    }
    func promiseBegan(from owner: SFTPTabController, session: NSDraggingSession, rows: IndexSet) {
        guard let browser else { return }
        let offer: RemoteDownloadDragOffer
        if let internalDragDraft, internalDragDraft.rows == rows, internalDragDraft.isCurrent() {
            offer = internalDragDraft; self.internalDragDraft = nil
        } else if rows.count == 1 {
            promiseBegan(from: owner, rows: rows)
            guard let activePromise else { return }
            offer = RemoteDownloadDragOffer(browser: browser, owner: owner,
                rows: rows, selection: .single(activePromise), token: activePromise.id)
        } else {
            self.internalDragDraft = nil; return
        }
        guard RemoteDownloadDrag.begin(offer, session: session) else {
            activePromise?.retireUncalled(); activePromise = nil; return
        }
        activeDragOffer = offer; activeDragSequence = session.draggingSequenceNumber
    }
    func promiseEnded(session: NSDraggingSession, operation: NSDragOperation) {
        guard activeDragSequence == session.draggingSequenceNumber else { return }
        if let table = activeDragOffer?.table {
            RemoteDownloadDrag.end(table: table, sequence: session.draggingSequenceNumber)
        }
        activeDragOffer = nil; activeDragSequence = nil
        promiseEnded(operation: operation)
    }
    func promiseEnded(operation: NSDragOperation) {
        if operation.isEmpty { activePromise?.retireUncalled() }
        activePromise = nil
        promiseDraft?.retireUnlessHanded(); promiseDraft = nil
        internalDragDraft = nil
    }
    func canRequest(from owner: SFTPTabController, toPane: Bool = false) -> Bool {
        guard SFTPDownloadFeature.available, work == nil, let browser, !browser.isBrowserSuspended,
              browser.canRunExclusiveFileCommand, browser.view.window?.attachedSheet == nil,
              browser.sftpTabs[browser.activeID] === owner, !owner.isClosing, owner.downloads != nil,
              let selection = owner.rows.selectedDownload, browser.recoverableFileOperations != nil else { return false }
        return !toPane || (selection.proposedLocalName != nil && !peers(browser).isEmpty)
    }
    private func peers(_ browser: BrowserViewController) -> [Peer] {
        LocalPaneDestination.available(from: browser)
    }
    func request(from owner: SFTPTabController, toPane: Bool) {
        let diagnostic = RemoteTransferDiagnostics(.download)
        guard SFTPDownloadFeature.available, work == nil, let browser, !browser.isBrowserSuspended,
              browser.canRunExclusiveFileCommand, browser.view.window?.attachedSheet == nil,
              browser.sftpTabs[browser.activeID] === owner, !owner.isClosing, let storage = owner.downloads,
              let selection = owner.rows.selectedDownload, let engine = browser.recoverableFileOperations else { diagnostic.finish(.blocked); return }
        diagnostic.stage(.destination)
        let tab = browser.activeID, visit = browser.sessionID
        if toPane, selection.proposedLocalName == nil { browser.status.stringValue = "This item needs a local filename. Use Download… to choose one."; diagnostic.finish(.blocked); return }
        var peer: Peer?
        if toPane {
            let values = peers(browser)
            guard let first = values.first else { browser.status.stringValue = "Open a writable local folder in another pane first."; diagnostic.finish(.blocked); return }
            if values.count == 1 { peer = first }
            else {
                let offered = NSMenu(title: "Download to Pane"); offered.autoenablesItems = false
                for value in values { let item = offered.addItem(withTitle: value.title, action: #selector(selectPeer(_:)), keyEquivalent: ""); item.target = self; item.representedObject = value.pane }
                menu = offered; chosenPeer = nil; offered.popUp(positioning: nil, at: .init(x: 24, y: 24), in: owner.rows)
                peer = values.first { $0.pane == chosenPeer }; menu = nil; chosenPeer = nil
                guard peer != nil else { diagnostic.finish(.cancelled); return }
            }
        }
        let preparation = UUID(), coordinator = browser.operationCoordinator
        guard coordinator.beginPreparation(owner: preparation) else { diagnostic.finish(.blocked); return }
        browser.operationPreparationID = preparation
        let capturedPeer = peer
        work = Task { [self, browser, owner, engine] in
            let began = ProcessInfo.processInfo.systemUptime
            var received: SFTPReceivedDownload?, progressTask: Task<Void, Never>?
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
                if let capturedPeer, let name = selection.proposedLocalName { destination = capturedPeer.directory.appendingPathComponent(name) }
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
                    guard let peer = capturedPeer.currentBrowser(from: browser) else { throw SFTPBrowserFailure.stale }
                    receiver = peer
                } else { receiver = browser }
                @MainActor func requireCurrentSelection() throws {
                    try Task.checkCancellation()
                    guard !browser.isBrowserSuspended, browser.activeID == tab, browser.sessionID == visit,
                          browser.sftpTabs[tab] === owner, !owner.isClosing, owner.session.latest.failure == nil,
                          owner.rows.selectedDownload?.generation == selection.generation,
                          owner.rows.selectedDownload?.row == selection.row, browser.recoverableFileOperations === engine,
                          destination.isFileURL else { throw SFTPBrowserFailure.stale }
                    if let capturedPeer, capturedPeer.currentBrowser(from: browser) !== receiver { throw SFTPBrowserFailure.stale }
                }
                try requireCurrentSelection()
                if RemoteDownloadPublicationFeature.qualifiesSingleFileAdoption {
                    guard selection.logicalBytes <= 1_048_576 else { throw FileOperationFailure.unsupported }
                    guard await GeneratedSandboxReview.accountV7Container(phase: "before") else {
                        throw FileOperationFailure.unavailable
                    }
                }
                diagnostic.stage(.access)
                let parent = destination.deletingLastPathComponent(), lifetime = await receiver.accessLifetime(for: [parent])
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
                    destinationObservation = try await engine.checkReceivedFileDestination(parent: parent, name: destination.lastPathComponent)
                }
                #if DEBUG
                if let destinationCheckedForQualification { await destinationCheckedForQualification() }
                #endif
                try requireCurrentSelection()
                guard browser.startOperationPresentation("Receiving selected SFTP file…", preparation: preparation, diagnosticTrace: diagnostic.trace) else { throw SFTPBrowserFailure.busy }
                started = true; browser.operationPreparationID = nil; browser.operationPreparationTask = nil; browser.operationTask = work
                browser.status.stringValue = "Receiving “\(destination.lastPathComponent)”… Verification and publication follow; the remote file stays unchanged."
                progressTask = Task { [weak browser] in
                    for await bytes in updates.stream {
                        diagnostic.stage(.receive, count: bytes)
                        guard let browser, !browser.operationStopRequested else { continue }
                        browser.operationPresentation = .init(phaseTitle: "Receive", percentage: selection.logicalBytes == 0 ? nil : min(1, Double(bytes) / Double(selection.logicalBytes)),
                            summary: "Receiving only · verification and publication follow. Stop closes this connection.", destinationPath: destination.path,
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
                #if TRAVERSE_SFTP_EDITOR_QA
                if GeneratedSandboxReview.v7DownloadAdmitted { try GeneratedV7Checkpoint.shared.recordBodyRequest() }
                #endif
                let copy = try await owner.session.download(selection, storage: storage, progress: { updates.continuation.yield($0) }); received = copy
                if RemoteDownloadPublicationFeature.qualifiesSingleFileAdoption {
                    let expectedMark = try await copy.hasExpectedV7NativeMark()
                    #if TRAVERSE_SFTP_EDITOR_QA
                    fputs("TRAVERSE_V7_SOURCE_MARK expected=\(expectedMark)\n", stderr)
                    #endif
                    guard expectedMark else { throw FileOperationFailure.copyMetadataMismatch }
                }
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
                let (outcome, removed) = try await RemoteReceivedFile.sftp(copy).publishSingleFile(using: engine,
                    parent: parent, name: destination.lastPathComponent, observing: destinationObservation,
                    progress: browser.operationProgressSink, expectedDestination: destination,
                    revalidating: requireCurrentSelection)
                received = nil
                diagnostic.publication(outcome.result, stagingRemoved: removed)
                browser.lastOperationResult = outcome.result; browser.lastRecoveryRecordID = outcome.recordID; browser.lastRecoveryAction = nil
                browser.lastTransferContinuation = nil; browser.continuationMoveClipboard = nil; browser.operationResultsButton.isHidden = false
                let message = outcome.result.disposition == .succeeded
                    ? "Downloaded “\(destination.lastPathComponent)”. Remote file unchanged. Open Results for details." + (removed ? "" : " Temporary staging needs review in Connection Activity.")
                    : "Download publication needs review. Results shows its recorded outcome; retained work has not been retried."
                if browser.activeID == tab, browser.sessionID == visit, browser.sftpTabs[tab] === owner {
                    owner.showTransferOutcome(message, needsAttention: outcome.result.disposition != .succeeded || !removed,
                                              showsUploadHistory: false)
                }
                #if DEBUG
                lastOutcome = outcome; lastNotice = message
                lastTimings = (publishing - receiving, ProcessInfo.processInfo.systemUptime - publishing, ProcessInfo.processInfo.systemUptime - began)
                #endif
                coordinator.reloadLocalDirectory(parent)
                browser.inspectOperationRecovery()
                if RemoteDownloadPublicationFeature.qualifiesSingleFileAdoption,
                   !(await GeneratedSandboxReview.accountV7Container(phase: "after")) {
                    browser.status.stringValue = "QA container accounting is incomplete. Stop this qualification and review the recorded result."
                }
            } catch {
                #if DEBUG
                if let failure = error as? SFTPSessionFailure { lastFailureCodeForVerification = String(describing: failure) }
                else if let failure = error as? SFTPBrowserFailure { lastFailureCodeForVerification = failure.rawValue }
                else { lastFailureCodeForVerification = String(reflecting: type(of: error)) }
                #endif
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                if received != nil { diagnostic.stage(.retain) }
                await received?.retainForReview()
                let message = Self.message(error, stopped: Task.isCancelled)
                if browser.activeID == tab, browser.sessionID == visit, browser.sftpTabs[tab] === owner {
                    owner.showTransferOutcome(message, needsAttention: true, showsUploadHistory: false)
                }
                if owner.session.latest.failure != nil || Task.isCancelled && started {
                    diagnostic.stage(.drain); diagnostic.drained(await owner.close().value)
                }
                diagnostic.fail(error, stopped: Task.isCancelled)
                if RemoteDownloadPublicationFeature.qualifiesSingleFileAdoption,
                   !(await GeneratedSandboxReview.accountV7Container(phase: "after")) {
                    browser.status.stringValue = "QA container accounting is incomplete. Stop this qualification and review retained work."
                }
                #if DEBUG
                lastNotice = message
                #endif
            }
        }
        browser.operationPreparationTask = work
    }
    @objc private func selectPeer(_ item: NSMenuItem) { if menu?.items.contains(where: { $0 === item }) == true { chosenPeer = item.representedObject as? UUID } }
    private static func message(_ error: Error, stopped: Bool) -> String {
        if stopped || error is CancellationError || error as? SFTPBrowserFailure == .stopped || error as? SFTPSessionFailure == .stopped {
            return "Download stopped. No unverified file was published. Connection closure and any retained staging can be reviewed."
        }
        if error as? SFTPBrowserFailure == .stale { return "The selection or destination changed. Choose Download again; nothing was published." }
        if let issue = error as? SFTPDownloadStorageIssue {
            switch issue {
            case .full: return "Download staging is full or its limit was reached. Review inactive files in Connection Storage, then choose Download again."
            case .busy: return "Download staging is busy. Wait for its current users to finish."
            case .changed: return "Download staging changed or could not be safely verified. Nothing was published; existing data is preserved."
            case .unavailable: return "Download staging is unavailable. Review Connection Storage and disk access; nothing was published."
            }
        }
        if error as? SFTPSessionFailure == .sourceChanged { return "The remote file changed during reading. Nothing was published; retained staging is in Connection Storage." }
        if let failure = error as? FileOperationFailure { return "Download was not published: \(failure.userMessage) Choose another destination or review access." }
        return "Download could not finish. Existing files are preserved; retained staging, if any, is in Connection Storage. Reconnect explicitly if needed."
    }
}
