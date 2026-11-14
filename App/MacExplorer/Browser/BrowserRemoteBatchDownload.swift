import AppKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

/// One explicit selection and one chosen local parent. Network receipt remains
/// one reserved session job; publication uses the existing one-file engine.
@MainActor final class BrowserRemoteBatchDownload: NSObject {
    private weak var browser: BrowserViewController?
    private(set) var work: Task<Void, Never>?
    private var menu: NSMenu?, chosenPeer: UUID?
    #if DEBUG
    var chooseForVerification: ((NSOpenPanel) async -> URL?)?
    var beforePublicationForVerification: ((Int) async -> Void)?
    var receiveProgressForVerification: (@Sendable (RemoteBatchDownloadProgress) -> Void)?
    private(set) var lastNotice = ""
    #endif
    init(browser: BrowserViewController) { self.browser = browser }

    func canRequest(from owner: SFTPTabController, toPane: Bool = false) -> Bool {
        guard let source = RemoteBatchDownloadSource(owner) else { return false }
        return canRequest(source: source, toPane: toPane)
    }
    func canRequest(from owner: SMBTabController, toPane: Bool = false) -> Bool {
        guard let source = RemoteBatchDownloadSource(owner) else { return false }
        return canRequest(source: source, toPane: toPane)
    }
    private func canRequest(source: RemoteBatchDownloadSource, toPane: Bool) -> Bool {
        guard work == nil, let browser, !browser.isBrowserSuspended, browser.canRunExclusiveFileCommand,
              browser.view.window?.attachedSheet == nil, source.isCurrent(in: browser),
              browser.recoverableFileOperations != nil else { return false }
        return !toPane || !LocalPaneDestination.available(from: browser).isEmpty
    }
    func request(from owner: SFTPTabController, toPane: Bool) {
        guard let source = RemoteBatchDownloadSource(owner) else { return }
        _ = request(source: source, toPane: toPane)
    }
    func request(from owner: SMBTabController, toPane: Bool) {
        guard let source = RemoteBatchDownloadSource(owner) else { return }
        _ = request(source: source, toPane: toPane)
    }
    /// A native in-process SFTP drop supplies the exact browser-observed parent
    /// and its access lifetime. The existing batch receiver and publication
    /// continue to own every body, Results entry, and Undo record.
    @discardableResult func requestDropped(from owner: SFTPTabController, expected: SFTPDownloadBatchPlan,
        destination: ArchiveExtractionDestination, current: @escaping @MainActor () -> Bool) -> Bool {
        guard SFTPFilePromiseFeature.internalAvailable,
              let source = RemoteBatchDownloadSource(owner), source.matchesSFTP(expected),
              destination.matchesObservedDirectory, current() else { return false }
        return request(source: source, toPane: false, drop: (destination, current))
    }
    @discardableResult func requestDropped(from owner: SMBTabController, expected: SMBDownloadBatchPlan,
        destination: ArchiveExtractionDestination, current: @escaping @MainActor () -> Bool) -> Bool {
        guard RemoteDownloadDrag.smbAvailable,
              let source = RemoteBatchDownloadSource(owner), source.matchesSMB(expected),
              destination.matchesObservedDirectory, current() else { return false }
        return request(source: source, toPane: false, drop: (destination, current))
    }
    @discardableResult private func request(source: RemoteBatchDownloadSource, toPane: Bool,
        drop: (destination: ArchiveExtractionDestination, current: @MainActor () -> Bool)? = nil) -> Bool {
        let diagnostic = RemoteTransferDiagnostics(.download)
        guard canRequest(source: source, toPane: toPane), let browser,
              let engine = browser.recoverableFileOperations,
              drop?.current() != false else { diagnostic.finish(.blocked); return false }
        let files = source.files, logicalBytes = source.logicalBytes, publicQuarantine = source.usesPublicQuarantine
        var peer: LocalPaneDestination?
        if toPane {
            let peers = LocalPaneDestination.available(from: browser)
            if peers.count == 1 { peer = peers[0] }
            else {
                let offered = NSMenu(title: "Download Files to Pane"); offered.autoenablesItems = false
                for value in peers {
                    let item = offered.addItem(withTitle: value.title, action: #selector(selectPeer(_:)), keyEquivalent: "")
                    item.target = self; item.representedObject = value.pane
                }
                menu = offered; chosenPeer = nil
                offered.popUp(positioning: nil, at: .init(x: 24, y: 24), in: source.rows)
                peer = peers.first { $0.pane == chosenPeer }; menu = nil; chosenPeer = nil
                guard peer != nil else { diagnostic.finish(.cancelled); return false }
            }
        }
        let preparation = UUID(), coordinator = browser.operationCoordinator
        guard coordinator.beginPreparation(owner: preparation) else { diagnostic.finish(.blocked); return false }
        browser.operationPreparationID = preparation
        let tab = browser.activeID, visit = browser.sessionID, capturedPeer = peer, capturedDrop = drop
        work = Task { [self, browser, engine] in
            var started = false, pending: [RemoteReceivedFile] = [], progressTask: Task<Void, Never>?
            var presentation: RemoteDownloadBatchPresentation?
            let updates = AsyncStream.makeStream(of: RemoteBatchDownloadProgress.self, bufferingPolicy: .bufferingNewest(1))
            defer {
                updates.continuation.finish(); progressTask?.cancel(); work = nil
                if started { browser.finishOperationPresentation() }
                else {
                    coordinator.finishPreparation(owner: preparation)
                    browser.operationPreparationTask = nil; browser.operationPreparationID = nil
                }
                diagnostic.finish(.cancelled)
            }
            do {
                let parent: URL
                if let capturedDrop { parent = capturedDrop.destination.directory }
                else if let capturedPeer { parent = capturedPeer.directory }
                else {
                    diagnostic.stage(.chooseDestination)
                    guard let window = browser.view.window else { throw CancellationError() }
                    let panel = NSOpenPanel(); panel.title = "Download Selected Files"; panel.prompt = "Download Here"
                    panel.message = "Choose where to download \(files.count) files (\(FileSizeText.string(Int64(logicalBytes)))). Existing items are kept."
                    panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = false; panel.resolvesAliases = false
                    #if DEBUG
                    if let chooseForVerification { guard let value = await chooseForVerification(panel) else { return }; parent = value }
                    else { guard await panel.beginSheetModal(for: window) == .OK, let value = panel.url else { return }; parent = value }
                    #else
                    guard await panel.beginSheetModal(for: window) == .OK, let value = panel.url else { return }; parent = value
                    #endif
                }
                let receiver: BrowserViewController
                if capturedDrop != nil { receiver = browser }
                else if let capturedPeer {
                    guard let value = capturedPeer.currentBrowser(from: browser) else { throw RemoteBatchSelectionFailure.stale }; receiver = value
                } else { receiver = browser }
                @MainActor func requireCurrent() throws {
                    try Task.checkCancellation()
                    guard !browser.isBrowserSuspended, browser.activeID == tab, browser.sessionID == visit,
                          source.isCurrent(in: browser), !source.failed,
                          browser.recoverableFileOperations === engine, parent.isFileURL else { throw RemoteBatchSelectionFailure.stale }
                    if let capturedPeer, capturedPeer.currentBrowser(from: browser) !== receiver { throw RemoteBatchSelectionFailure.stale }
                }
                try requireCurrent(); diagnostic.stage(.access)
                let access: FileAccessLifetimes
                if let capturedDrop { access = capturedDrop.destination.access }
                else if capturedPeer != nil { access = await receiver.accessLifetime(for: [parent]) }
                else {
                    // Preserve the actual panel URL in the common access owner.
                    // Rebuilding a path or dropping its lease here loses warm
                    // authority and makes immediate Undo ask for access again.
                    guard let choice = await receiver.folderAccess.acceptChosenFolder(parent) else {
                        throw FileOperationFailure.accessDenied
                    }
                    access = .init(leases: [choice.lease])
                }
                defer { withExtendedLifetime(access) {} }
                try requireCurrent(); diagnostic.stage(.destination)
                let observed = try await engine.checkReceivedFileDestinations(parent: parent,
                    names: files.map(\.name), observing: capturedDrop?.destination.observation)
                try requireCurrent()
                guard browser.startOperationPresentation("Receiving \(files.count) \(source.protocolName) files…", preparation: preparation,
                    diagnosticTrace: diagnostic.trace) else { throw RemoteBatchSelectionFailure.busy }
                started = true; browser.operationPreparationID = nil; browser.operationPreparationTask = nil; browser.operationTask = work
                var value = RemoteDownloadBatchPresentation(files: files, parent: parent, engine: engine)
                presentation = value
                progressTask = Task { [weak browser] in
                    for await progress in updates.stream {
                        diagnostic.stage(.receive, count: progress.receivedBytes)
                        guard let browser, !browser.operationStopRequested else { continue }
                        browser.operationPresentation = .init(phaseTitle: "Receive",
                            percentage: logicalBytes == 0 ? nil : min(1, Double(progress.receivedBytes) / Double(logicalBytes)),
                            summary: "\(progress.completedFiles) of \(progress.totalFiles) received · files appear after verification. Stop closes this connection.",
                            destinationPath: parent.path, completedText: "\(FileSizeText.string(Int64(progress.receivedBytes))) received")
                        browser.updateOperationProgressControls()
                    }
                }
                diagnostic.stage(.receive, count: 0)
                #if DEBUG
                let receiveObserver = receiveProgressForVerification
                let received = try await source.receive(progress: { receiveObserver?($0); updates.continuation.yield($0) })
                #else
                let received = try await source.receive(progress: { updates.continuation.yield($0) })
                #endif
                pending = received
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                try Task.checkCancellation(); diagnostic.stage(.prepareHistory)
                try await coordinator.prepareOperationState(for: engine)
                for (index, item) in received.enumerated() {
                    try Task.checkCancellation()
                    #if DEBUG
                    if let beforePublicationForVerification { await beforePublicationForVerification(index) }
                    #endif
                    diagnostic.stage(.verify, count: UInt64(index))
                    let plan = try await item.preparePublication(using: engine, parent: parent, name: files[index].name,
                        observing: observed, publicQuarantine: publicQuarantine)
                    diagnostic.stage(.publish, count: UInt64(index))
                    let outcome = await engine.performReceivedFile(plan, progress: browser.operationProgressSink)
                    let removed = await item.finishPublication(outcome)
                    pending.removeFirst(); value.record(outcome, index: index, stagingRemoved: removed)
                    presentation = value
                    if outcome.result.disposition != .succeeded { break }
                }
                value.retainedStaging = value.retainedStaging || !pending.isEmpty
                for copy in pending { await copy.retainForReview() }; pending = []
                value.stopped = Task.isCancelled; presentation = value
                diagnostic.publication(value.result, stagingRemoved: !value.retainedStaging)
                finish(value, browser: browser)
            } catch {
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                let retained = !pending.isEmpty || (error as? SFTPDownloadBatchInterruption)?.retainedFileIDs.isEmpty == false
                    || (error as? SMBDownloadBatchInterruption)?.retainedFileIDs.isEmpty == false
                for copy in pending { await copy.retainForReview() }; pending = []
                if source.failed || started && Task.isCancelled {
                    diagnostic.stage(.drain); await source.drain(diagnostic: diagnostic)
                }
                diagnostic.fail(error, stopped: Task.isCancelled)
                let message = Self.message(error, stopped: Task.isCancelled)
                if var presentation {
                    presentation.retainedStaging = presentation.retainedStaging || retained
                    presentation.stopped = Task.isCancelled; presentation.notice = message
                    finish(presentation, browser: browser)
                } else { browser.status.stringValue = message }
                #if DEBUG
                lastNotice = message
                #endif
            }
        }
        browser.operationPreparationTask = work
        return true
    }
    private func finish(_ value: RemoteDownloadBatchPresentation, browser: BrowserViewController) {
        browser.lastOperationResult = value.result; browser.operationHistory.downloadBatch = value
        browser.lastRecoveryRecordID = nil; browser.lastRecoveryAction = nil
        browser.lastTransferContinuation = nil; browser.continuationMoveClipboard = nil
        browser.operationResultsButton.isHidden = false; browser.status.stringValue = value.summary
        browser.operationCoordinator.reloadLocalDirectory(value.parent)
        browser.inspectOperationRecovery()
        #if DEBUG
        lastNotice = value.summary
        #endif
    }
    @objc private func selectPeer(_ sender: NSMenuItem) {
        guard menu?.items.contains(where: { $0 === sender }) == true else { return }; chosenPeer = sender.representedObject as? UUID
    }
    private static func message(_ error: Error, stopped: Bool) -> String {
        if let batch = error as? SFTPDownloadBatchInterruption {
            return "\(batch.completedFiles) of \(batch.totalFiles) files received before interruption. "
                + message(batch.cause, stopped: stopped)
        }
        if let batch = error as? SMBDownloadBatchInterruption {
            return "\(batch.completedFiles) of \(batch.totalFiles) files received before interruption. "
                + message(batch.cause, stopped: stopped)
        }
        if error is SMBDownloadBatchIssue {
            return "Select 2–16 ordinary files with distinct destination names, up to 1 GiB in total. Download folders separately."
        }
        if let issue = error as? SMBDownloadStorageIssue {
            switch issue {
            case .full: return "Transfer storage is full. Review inactive copies in Connection Storage, then download again."
            case .busy: return "Another transfer is using this storage. Wait for it to finish, then download again."
            case .changed: return "Transfer storage changed and needs review. Existing copies are kept in Connection Storage."
            case .unavailable: return "Transfer storage is unavailable. Review disk access and Connection Storage before downloading again."
            }
        }
        if let issue = error as? SFTPDownloadBatchIssue {
            switch issue {
            case .invalidSelection: return "Select 2–16 ordinary files from the loaded folder. Download folders separately."
            case .duplicateSelection, .duplicateName: return "Choose each file once with a different destination name."
            case .tooLarge: return "Choose a smaller group, up to 1 GiB in total."
            }
        }
        if let issue = error as? SFTPDownloadStorageIssue {
            switch issue {
            case .full: return "Transfer storage is full. Review inactive copies in Connection Storage, then download again."
            case .busy: return "Another transfer is using this storage. Wait for it to finish, then download again."
            case .changed: return "Transfer storage changed and needs review. Existing copies are kept in Connection Storage."
            case .unavailable: return "Transfer storage is unavailable. Review disk access and Connection Storage before downloading again."
            }
        }
        if stopped || error is CancellationError || error as? SFTPBrowserFailure == .stopped
            || error as? SMBDirectoryFailure == .stopped || error as? SMBBrowserFailure == .stopped {
            return "Download stopped. Completed local files stay available; any remaining copies are kept in Connection Storage for review."
        }
        if error as? FileOperationFailure == .conflict {
            return "A selected name already exists or conflicts with another selected name in this folder. Nothing was replaced. Choose another folder or download separately."
        }
        if let failure = error as? FileOperationFailure { return "Download could not finish: \(failure.userMessage) Existing items stay protected." }
        if error as? SFTPBrowserFailure == .stale || error as? SMBDirectoryFailure == .stale
            || error as? RemoteBatchSelectionFailure == .stale { return "The selection or destination changed. Choose Download again. Nothing was replaced." }
        if error as? SFTPSessionFailure == .sourceChanged { return "A selected server file changed while reading. Nothing was replaced; retained copies are in Connection Storage." }
        return "Download could not finish. Existing items stay protected. View Results for local files; retained copies, if any, are in Connection Storage."
    }
}

private enum RemoteBatchSelectionFailure: Error, Equatable { case stale, busy }
