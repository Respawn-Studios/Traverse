import AppKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

/// One serial server owner supplies a sealed tree. The existing local engine
/// publishes it and owns the one-operation Undo.
@MainActor final class BrowserRemoteFolderDownload {
    private weak var browser: BrowserViewController?
    private let kind: RemoteFolderDownloadSource.Kind
    private var work: Task<Void, Never>?
    #if TRAVERSE_SFTP_EDITOR_QA
    var qualificationWork: Task<Void, Never>? {
        switch kind {
        case .sftp: GeneratedSandboxReview.sftpPublicSelectionDownloadAdmitted ? work : nil
        case .smb: GeneratedSandboxReview.smbPublicSelectionDownloadAdmitted ? work : nil
        }
    }
    #endif
    #if DEBUG
    var chooseForVerification: ((NSSavePanel) async -> URL?)?
    var reviewForVerification: SFTPFolderDownloadPreview.Reviewer?
    var destinationCheckedForVerification: (() async -> Void)?
    var receivedForVerification: (() async throws -> Void)?
    var didReceiveBytesForVerification: (@Sendable (UInt64) -> Void)?
    private(set) var bodyRequestsForVerification = 0
    private(set) var lastOutcome: RecoverableOperationResult?, lastNotice = ""
    #endif
    init(browser: BrowserViewController, kind: RemoteFolderDownloadSource.Kind) {
        self.browser = browser
        self.kind = kind
    }

    func canRequest(from owner: SFTPTabController, toPane: Bool = false) -> Bool {
        canRequest(source: RemoteFolderDownloadSource(owner), toPane: toPane)
    }
    func canRequest(from owner: SMBTabController, toPane: Bool = false) -> Bool {
        canRequest(source: RemoteFolderDownloadSource(owner), toPane: toPane)
    }
    private func canRequest(source: RemoteFolderDownloadSource?, toPane: Bool) -> Bool {
        guard let source, source.kind == kind, work == nil, let browser, !browser.isBrowserSuspended,
              browser.canRunExclusiveFileCommand, browser.view.window?.attachedSheet == nil,
              source.isCurrent(in: browser), browser.recoverableFileOperations != nil else { return false }
        return !toPane || source.name != nil && !LocalPaneDestination.available(from: browser).isEmpty
    }
    func request(from owner: SFTPTabController, toPane: Bool) {
        _ = request(source: RemoteFolderDownloadSource(owner), toPane: toPane, dropped: nil)
    }
    func request(from owner: SMBTabController, toPane: Bool) {
        _ = request(source: RemoteFolderDownloadSource(owner), toPane: toPane, dropped: nil)
    }
    @discardableResult func requestDropped(from owner: SFTPTabController,
        expected: SFTPFolderDownloadSelection, destination: ArchiveExtractionDestination,
        current: @escaping @MainActor () -> Bool) -> Bool {
        guard SFTPFilePromiseFeature.internalAvailable, destination.matchesObservedDirectory,
              expected.proposedLocalName != nil, current(),
              RemoteDownloadDragOffer.matchesFolder(expected, owner.rows.selectedFolderDownload) else { return false }
        return request(source: RemoteFolderDownloadSource(owner), toPane: false, dropped: destination)
    }
    @discardableResult func requestDropped(from owner: SMBTabController,
        expected: SMBFolderDownloadSelection, destination: ArchiveExtractionDestination,
        current: @escaping @MainActor () -> Bool) -> Bool {
        guard RemoteDownloadDrag.smbAvailable, destination.matchesObservedDirectory,
              expected.proposedLocalName != nil, current(),
              RemoteDownloadDragOffer.matchesFolder(expected, owner.selectedFolderDownload) else { return false }
        return request(source: RemoteFolderDownloadSource(owner), toPane: false, dropped: destination)
    }
    @discardableResult private func request(source: RemoteFolderDownloadSource?, toPane: Bool,
        dropped: ArchiveExtractionDestination?) -> Bool {
        let diagnostic = RemoteTransferDiagnostics(.download)
        guard canRequest(source: source, toPane: toPane), let browser, let source,
              let engine = browser.recoverableFileOperations else { diagnostic.finish(.blocked); return false }
        diagnostic.stage(.destination)
        var peer: LocalPaneDestination?
        if toPane {
            let values = LocalPaneDestination.available(from: browser)
            peer = LocalPaneDestination.choose(values, from: browser, in: source.rows, title: "Download Folder to Pane")
            guard peer != nil else { diagnostic.finish(.cancelled); return false }
        }
        let tab = browser.activeID, visit = browser.sessionID, preparation = UUID(), coordinator = browser.operationCoordinator, capturedPeer = peer
        guard coordinator.beginPreparation(owner: preparation) else { diagnostic.finish(.blocked); return false }; browser.operationPreparationID = preparation
        work = Task { [self, browser, engine] in
            var prepared: RemotePreparedFolderDownload?, received: RemoteReceivedFolderDownload?, started = false
            var progressTask: Task<Void, Never>?
            let updates = AsyncStream.makeStream(of: RemoteFolderDownloadProgress.self, bufferingPolicy: .bufferingNewest(1))
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
                if let dropped, let name = source.name { destination = dropped.directory.appendingPathComponent(name) }
                else if let capturedPeer, let name = source.name { destination = capturedPeer.directory.appendingPathComponent(name) }
                else {
                    diagnostic.stage(.chooseDestination)
                    let panel = NSSavePanel(); panel.title = "Download Folder"; panel.prompt = "Review Folder"
                    panel.message = "Choose a new local folder. Next, review its contents and size before downloading. Existing items are preserved."
                    panel.nameFieldStringValue = source.name ?? "Downloaded folder"; panel.canCreateDirectories = false
                    #if DEBUG
                    if let chooseForVerification { guard let url = await chooseForVerification(panel) else { return }; destination = url }
                    else { guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }; destination = url }
                    #else
                    guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }; destination = url
                    #endif
                }
                let receiver: BrowserViewController
                if let capturedPeer {
                    guard let peer = capturedPeer.currentBrowser(from: browser) else { throw kind.stale }
                    receiver = peer
                }
                else { receiver = browser }
                @MainActor func requireCurrent() throws {
                    try Task.checkCancellation()
                    guard !browser.isBrowserSuspended, browser.activeID == tab, browser.sessionID == visit,
                          source.isCurrent(in: browser), !source.failed,
                          browser.recoverableFileOperations === engine, destination.isFileURL else { throw kind.stale }
                    if let capturedPeer, capturedPeer.currentBrowser(from: browser) !== receiver { throw kind.stale }
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
                guard browser.startOperationPresentation("Checking selected folder…", preparation: preparation,
                    diagnosticTrace: diagnostic.trace) else { throw kind.busy }
                started = true; browser.operationPreparationID = nil; browser.operationPreparationTask = nil; browser.operationTask = work
                progressTask = Task { [weak browser] in
                    for await value in updates.stream {
                        let phase: String, completed: String
                        switch value {
                        case .checkingFolders(let entries):
                            diagnostic.stage(.metadata, count: UInt64(entries))
                            phase = "Checking folders"; completed = ""
                        case .receiving(let bytes):
                            diagnostic.stage(.receive, count: bytes)
                            phase = "Receiving files"; completed = "\(FileSizeText.string(Int64(bytes))) received"
                        case .checkingCopy(let bytes):
                            diagnostic.stage(.verify, count: bytes)
                            phase = "Checking copy"; completed = ""
                        }
                        guard let browser, !browser.operationStopRequested else { continue }
                        browser.operationPresentation = .init(phaseTitle: phase, percentage: nil,
                            summary: "The complete folder is checked before it appears. Stop closes this connection.", destinationPath: destination.path,
                            currentItem: destination.lastPathComponent, completedText: completed)
                        browser.updateOperationProgressControls()
                    }
                }
                var chosenName: String?
                while chosenName == nil {
                    try requireCurrent()
                    diagnostic.stage(.metadata)
                    let value = try await source.prepare { updates.continuation.yield($0) }
                    prepared = value
                    try requireCurrent()
                    _ = try await engine.checkReceivedDirectoryDestination(parent: parent, name: destination.lastPathComponent,
                        observing: observed, longestPathBytes: value.longestPathBytes)
                    #if DEBUG
                    let reviewer = reviewForVerification
                    #else
                    let reviewer: SFTPFolderDownloadPreview.Reviewer? = nil
                    #endif
                    let choice = await SFTPFolderDownloadPreview.chooseIfNeeded(summary: value.summary,
                        parentPath: parent.path, name: destination.lastPathComponent, settings: browser.settings,
                        in: window, requiresReview: source.requiresReview, review: reviewer) {
                        diagnostic.stage(.review, count: UInt64(value.summary.files))
                    }
                    switch choice {
                    case .cancel:
                        diagnostic.stage(.clean)
                        try await value.release(); prepared = nil
                        browser.status.stringValue = "Folder download cancelled. No files were downloaded."; diagnostic.finish(.cancelled); return
                    case .reviewAgain:
                        diagnostic.stage(.clean)
                        try await value.release(); prepared = nil
                    case .download(let name): chosenName = name
                    }
                }
                guard let preparedValue = prepared, let name = chosenName else { throw kind.stale }
                destination = parent.appendingPathComponent(name); try requireCurrent()
                _ = try await engine.checkReceivedDirectoryDestination(parent: parent, name: name, observing: observed, longestPathBytes: preparedValue.longestPathBytes)
                #if DEBUG
                if let destinationCheckedForVerification { await destinationCheckedForVerification() }
                #endif
                try requireCurrent()
                diagnostic.stage(.receive, count: 0)
                #if DEBUG
                bodyRequestsForVerification += 1
                let observer = didReceiveBytesForVerification
                let copy = try await preparedValue.receive { value in
                    updates.continuation.yield(value)
                    if case .receiving(let bytes) = value { observer?(bytes) }
                }
                #else
                let copy = try await preparedValue.receive { updates.continuation.yield($0) }
                #endif
                received = copy; prepared = nil
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
                    do { try await prepared.release() }
                    catch { diagnostic.cleanupFailure(error) }
                }
                if received != nil { diagnostic.stage(.retain) }
                await received?.retainForReview()
                if Task.isCancelled || source.failed {
                    diagnostic.stage(.drain); await source.drain(diagnostic: diagnostic)
                }
                diagnostic.fail(error, stopped: Task.isCancelled)
                let message: String
                if Task.isCancelled || error is CancellationError { message = "Folder download stopped. Review any retained work in Connection Storage or View Results." }
                else if error as? SFTPSessionFailure == .sourceChanged || error as? SMBDirectoryFailure == .stale {
                    message = "The remote folder changed. No unverified folder was published. Choose Download again after reconnecting."
                }
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
}
