import AppKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

enum SFTPFolderDownloadFeature {
    static let enabled = true
    #if DEBUG
    @MainActor static var qualifying = false
    @MainActor static var available: Bool {
        if GeneratedSandboxReview.publicSelectionDownloadAdmitted {
            return GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted
        }
        return RemoteDownloadPublicationFeature.folderAvailable && (qualifying || enabled)
    }
    #else
    static var available: Bool {
        enabled && (GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted
            || RemoteDownloadPublicationFeature.folderAvailable)
    }
    #endif
}

/// Native capture/review only. One serial SFTP owner supplies a sealed tree;
/// the existing local engine publishes and owns the one-operation Undo.
@MainActor final class BrowserSFTPFolderDownload: NSObject {
    private weak var browser: BrowserViewController?
    private var work: Task<Void, Never>?, menu: NSMenu?, chosenPeer: UUID?
    #if TRAVERSE_SFTP_EDITOR_QA
    var qualificationWork: Task<Void, Never>? {
        GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted ? work : nil
    }
    #endif
    #if DEBUG
    var chooseForVerification: ((NSSavePanel) async -> URL?)?
    var reviewForVerification: SFTPFolderDownloadPreview.Reviewer?
    var destinationCheckedForVerification: (() async -> Void)?
    var receivedForVerification: (() async throws -> Void)?
    private(set) var bodyRequestsForVerification = 0
    private(set) var lastOutcome: RecoverableOperationResult?, lastNotice = ""
    #endif
    init(browser: BrowserViewController) { self.browser = browser }
    func canRequest(from owner: SFTPTabController, toPane: Bool = false) -> Bool {
        guard SFTPFolderDownloadFeature.available, work == nil, let browser, !browser.isBrowserSuspended,
              browser.canRunExclusiveFileCommand, browser.view.window?.attachedSheet == nil,
              browser.sftpTabs[browser.activeID] === owner, !owner.isClosing, !owner.hasPendingPages,
              owner.session.allowsRequestedFolderDownloads, owner.downloads != nil,
              let selected = owner.rows.selectedFolderDownload, browser.recoverableFileOperations != nil else { return false }
        return !toPane || selected.proposedLocalName != nil && !LocalPaneDestination.available(from: browser).isEmpty
    }
    func request(from owner: SFTPTabController, toPane: Bool) {
        _ = request(from: owner, toPane: toPane, dropped: nil)
    }
    @discardableResult func requestDropped(from owner: SFTPTabController,
        expected: SFTPFolderDownloadSelection, destination: ArchiveExtractionDestination,
        current: @escaping @MainActor () -> Bool) -> Bool {
        guard SFTPFilePromiseFeature.internalAvailable, destination.matchesObservedDirectory,
              expected.proposedLocalName != nil, current(),
              RemoteDownloadDragOffer.matchesFolder(expected, owner.rows.selectedFolderDownload) else { return false }
        return request(from: owner, toPane: false, dropped: destination)
    }
    @discardableResult private func request(from owner: SFTPTabController, toPane: Bool,
        dropped: ArchiveExtractionDestination?) -> Bool {
        let diagnostic = RemoteTransferDiagnostics(.download)
        guard canRequest(from: owner, toPane: toPane), let browser, let selected = owner.rows.selectedFolderDownload,
              let storage = owner.downloads, let engine = browser.recoverableFileOperations else { diagnostic.finish(.blocked); return false }
        diagnostic.stage(.destination)
        var peer: LocalPaneDestination?
        if toPane {
            let values = LocalPaneDestination.available(from: browser)
            if values.count == 1 { peer = values[0] }
            else {
                let offered = NSMenu(title: "Download Folder to Pane"); offered.autoenablesItems = false
                for value in values { let item = offered.addItem(withTitle: value.title, action: #selector(selectPeer(_:)), keyEquivalent: ""); item.target = self; item.representedObject = value.pane }
                menu = offered; chosenPeer = nil; offered.popUp(positioning: nil, at: .init(x: 24, y: 24), in: owner.rows)
                peer = values.first { $0.pane == chosenPeer }; menu = nil; chosenPeer = nil
                guard peer != nil else { diagnostic.finish(.cancelled); return false }
            }
        }
        let tab = browser.activeID, visit = browser.sessionID, preparation = UUID(), coordinator = browser.operationCoordinator, capturedPeer = peer
        guard coordinator.beginPreparation(owner: preparation) else { diagnostic.finish(.blocked); return false }; browser.operationPreparationID = preparation
        work = Task { [self, browser, owner, engine] in
            var prepared: SFTPPreparedFolderDownload?, received: SFTPReceivedFolderDownload?, started = false
            var progressTask: Task<Void, Never>?
            let updates = AsyncStream.makeStream(of: SFTPFolderDownloadProgress.self, bufferingPolicy: .bufferingNewest(1))
            defer {
                updates.continuation.finish(); progressTask?.cancel()
                if started { browser.finishOperationPresentation() }
                else { coordinator.finishPreparation(owner: preparation); browser.operationPreparationTask = nil; browser.operationPreparationID = nil }
                work = nil
                diagnostic.finish(.cancelled)
            }
            do {
                guard let window = browser.view.window else { throw CancellationError() }
                var destination: URL
                if let dropped, let name = selected.proposedLocalName { destination = dropped.directory.appendingPathComponent(name) }
                else if let capturedPeer, let name = selected.proposedLocalName { destination = capturedPeer.directory.appendingPathComponent(name) }
                else {
                    diagnostic.stage(.chooseDestination)
                    let panel = NSSavePanel(); panel.title = "Download Folder"; panel.prompt = "Review Folder"
                    panel.message = "Choose a new local folder. Next, review its contents and size before downloading. Existing items are preserved."
                    panel.nameFieldStringValue = selected.proposedLocalName ?? "Downloaded folder"; panel.canCreateDirectories = false
                    #if DEBUG
                    if let chooseForVerification { guard let url = await chooseForVerification(panel) else { return }; destination = url }
                    else { guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }; destination = url }
                    #else
                    guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }; destination = url
                    #endif
                }
                let receiver: BrowserViewController
                if let capturedPeer { guard let peer = capturedPeer.currentBrowser(from: browser) else { throw SFTPBrowserFailure.stale }; receiver = peer }
                else { receiver = browser }
                @MainActor func requireCurrent() throws {
                    try Task.checkCancellation()
                    guard !browser.isBrowserSuspended, browser.activeID == tab, browser.sessionID == visit,
                          browser.sftpTabs[tab] === owner, !owner.isClosing, owner.session.latest.failure == nil,
                          owner.rows.selectedFolderDownload?.generation == selected.generation,
                          owner.rows.selectedFolderDownload?.read == selected.read,
                          owner.rows.selectedFolderDownload?.row == selected.row,
                          owner.rows.selectedFolderDownload?.revision == selected.revision,
                          browser.recoverableFileOperations === engine, destination.isFileURL else { throw SFTPBrowserFailure.stale }
                    if let capturedPeer, capturedPeer.currentBrowser(from: browser) !== receiver { throw SFTPBrowserFailure.stale }
                }
                try requireCurrent()
                diagnostic.stage(.access)
                let parent = destination.deletingLastPathComponent()
                let lifetime: FileAccessLifetimes
                if let dropped { lifetime = dropped.access }
                else { lifetime = await receiver.accessLifetime(for: [parent]) }
                defer { withExtendedLifetime(lifetime) {} }
                try requireCurrent()
                diagnostic.stage(.destination)
                let observed = try await engine.checkReceivedDirectoryDestination(parent: parent,
                    name: destination.lastPathComponent, observing: dropped?.observation)
                guard browser.startOperationPresentation("Checking selected SFTP folder…", preparation: preparation, diagnosticTrace: diagnostic.trace) else { throw SFTPBrowserFailure.busy }
                started = true; browser.operationPreparationID = nil; browser.operationPreparationTask = nil; browser.operationTask = work
                progressTask = Task { [weak browser] in
                    for await value in updates.stream {
                        switch value.phase {
                        case .checkingFolders: diagnostic.stage(.metadata, count: UInt64(value.checkedEntries))
                        case .receiving: diagnostic.stage(.receive, count: value.receivedBytes)
                        case .checkingCopy: diagnostic.stage(.verify, count: value.receivedBytes)
                        }
                        guard let browser, !browser.operationStopRequested else { continue }
                        let phase: String
                        switch value.phase { case .checkingFolders: phase = "Checking folders"; case .receiving: phase = "Receiving files"; case .checkingCopy: phase = "Checking copy" }
                        browser.operationPresentation = .init(phaseTitle: phase, percentage: nil,
                            summary: "The complete folder is checked before it appears. Stop closes this connection.", destinationPath: destination.path,
                            currentItem: destination.lastPathComponent, completedText: value.phase == .receiving ? "\(FileSizeText.string(Int64(value.receivedBytes))) received" : "")
                        browser.updateOperationProgressControls()
                    }
                }
                var chosenName: String?
                while chosenName == nil {
                    try requireCurrent()
                    diagnostic.stage(.metadata)
                    let value = try await owner.session.prepareFolderDownload(selected, progress: { updates.continuation.yield($0) }); prepared = value
                    try requireCurrent()
                    _ = try await engine.checkReceivedDirectoryDestination(parent: parent, name: destination.lastPathComponent,
                        observing: observed, longestPathBytes: value.longestPathBytes)
                    #if DEBUG
                    let reviewer = reviewForVerification
                    #else
                    let reviewer: SFTPFolderDownloadPreview.Reviewer? = nil
                    #endif
                    let choice = await SFTPFolderDownloadPreview.chooseIfNeeded(summary: .init(prepared: value),
                        parentPath: parent.path, name: destination.lastPathComponent, settings: browser.settings,
                        in: window, requiresReview: owner.reviewsUploads, review: reviewer) {
                        diagnostic.stage(.review, count: UInt64(value.files))
                    }
                    switch choice {
                    case .cancel:
                        diagnostic.stage(.clean)
                        try await owner.session.releaseFolderDownload(value); prepared = nil
                        browser.status.stringValue = "Folder download cancelled. No files were downloaded."; diagnostic.finish(.cancelled); return
                    case .reviewAgain:
                        diagnostic.stage(.clean)
                        try await owner.session.releaseFolderDownload(value); prepared = nil
                    case .download(let name): chosenName = name
                    }
                }
                guard let preparedValue = prepared, let name = chosenName else { throw SFTPBrowserFailure.stale }
                destination = parent.appendingPathComponent(name); try requireCurrent()
                _ = try await engine.checkReceivedDirectoryDestination(parent: parent, name: name, observing: observed, longestPathBytes: preparedValue.longestPathBytes)
                #if DEBUG
                if let destinationCheckedForVerification { await destinationCheckedForVerification() }
                #endif
                try requireCurrent()
                diagnostic.stage(.receive, count: 0)
                #if DEBUG
                bodyRequestsForVerification += 1
                #endif
                let copy = try await owner.session.downloadFolder(preparedValue, storage: storage, progress: { updates.continuation.yield($0) }); received = copy; prepared = nil
                #if DEBUG
                if let receivedForVerification { try await receivedForVerification() }
                #endif
                updates.continuation.finish(); await progressTask?.value; progressTask = nil; try Task.checkCancellation()
                diagnostic.stage(.prepareHistory)
                try await coordinator.prepareOperationState(for: engine); try Task.checkCancellation()
                diagnostic.stage(.verify)
                let plan = try await copy.preparePublication(using: engine, parent: parent, name: name, observing: observed,
                    publicQuarantineTreeV16: RemoteDownloadPublicationFeature.qualifiesPublicQuarantineFolderDownload)
                diagnostic.stage(.publish)
                let result = await engine.performReceivedDirectory(plan, progress: browser.operationProgressSink)
                let removed = await copy.finishPublication(result); received = nil
                diagnostic.publication(result.result, stagingRemoved: removed)
                browser.lastOperationResult = result.result; browser.lastRecoveryRecordID = result.recordID; browser.lastRecoveryAction = nil
                browser.lastTransferContinuation = nil; browser.continuationMoveClipboard = nil; browser.operationResultsButton.isHidden = false
                browser.status.stringValue = RemoteDownloadPublicationFeature.folderCompletionMessage(
                    succeeded: result.result.disposition == .succeeded, stagingRemoved: removed)
                #if DEBUG
                lastOutcome = result; lastNotice = browser.status.stringValue
                #endif
                coordinator.reloadLocalDirectory(parent)
                browser.inspectOperationRecovery()
            } catch {
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                if let prepared, !Task.isCancelled {
                    diagnostic.stage(.clean)
                    do { try await owner.session.releaseFolderDownload(prepared) }
                    catch { diagnostic.cleanupFailure(error) }
                }
                if received != nil { diagnostic.stage(.retain) }
                await received?.retainForReview()
                if Task.isCancelled || owner.session.latest.failure != nil {
                    diagnostic.stage(.drain); diagnostic.drained(await owner.close().value)
                }
                diagnostic.fail(error, stopped: Task.isCancelled)
                let message: String
                if Task.isCancelled || error is CancellationError { message = "Folder download stopped. Review any retained work in Connection Storage or View Results." }
                else if error as? SFTPSessionFailure == .sourceChanged { message = "The remote folder changed. No unverified folder was published. Choose Download again after reconnecting." }
                else if let failure = error as? FileOperationFailure { message = "Folder download could not be published: \(failure.userMessage)" }
                else { message = "This folder could not be downloaded completely. Existing items are preserved. Review Connection Storage, or reconnect and try again." }
                browser.status.stringValue = message
                #if DEBUG
                lastNotice = message
                #endif
            }
        }
        browser.operationPreparationTask = work
        return true
    }
    @objc private func selectPeer(_ item: NSMenuItem) { if menu?.items.contains(where: { $0 === item }) == true { chosenPeer = item.representedObject as? UUID } }
}
