import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

enum SFTPDropUploadFeature {
    // Reuse the same native input owner across product editions.
    private static var productAvailable: Bool { AppFeatureAvailability.allows(.serverDropUpload) }
    #if DEBUG
    @MainActor static var qualifying = false
    @MainActor static var available: Bool { qualifying || productAvailable && SFTPUploadFeature.available }
    #else
    static var available: Bool { productAvailable && SFTPUploadFeature.available }
    #endif
}

/// Native drop and pane-selection admission share the same reviewed group.
/// The existing session pump owns network commands and all work must drain.
@MainActor final class BrowserSFTPDropUpload {
    private enum SourceKey: Hashable { case drop(LocalFileDropKey), pane(UUID), clipboard(UUID) }
    private struct Source {
        let key: SourceKey, urls: [URL], access: FileAccessLifetimes
        let isCurrent: () -> Bool
        let acquireAccess: () async -> FileAccessLifetimes
        let accepts: (SFTPUploadBatchPlan) -> Bool
    }
    private weak var browser: BrowserViewController?
    private(set) var work: Task<Void, Never>?
    private var accepted: [SourceKey] = []
    #if DEBUG
    var reviewForVerification: ((SFTPUploadBatchPlan, String) async -> Bool)?
    private(set) var lastCompleted: SFTPUploadBatchResult?, lastInterruption: SFTPUploadBatchInterruption?
    private(set) var lastNotice = "", acceptedCount = 0
    #endif
    init(browser: BrowserViewController) { self.browser = browser }
    func canRequest(from owner: SFTPTabController) -> Bool {
        guard SFTPDropUploadFeature.available, work == nil, let browser, !browser.isBrowserSuspended, browser.isSFTPLocation,
              browser.canRunExclusiveFileCommand, browser.view.window?.attachedSheet == nil,
              browser.sftpTabs[browser.activeID] === owner, !owner.isClosing, owner.uploads != nil,
              owner.session.allowsFreshUploads, owner.session.latest.failure == nil,
              owner.rows.cache.generation == owner.session.latest.generation,
              owner.rows.cache.snapshot == owner.session.latest.snapshot, owner.rows.cache.snapshot?.state == .complete else { return false }
        return true
    }
    func preview(_ info: NSDraggingInfo, owner: SFTPTabController) -> Int? {
        guard canRequest(from: owner), let source = BrowserDragDropController.captureLocalFileDropSource(info), !accepted.contains(.drop(source.key)) else { return nil }
        return source.urls.count
    }
    @discardableResult func accept(_ info: NSDraggingInfo, owner: SFTPTabController) -> Bool {
        guard canRequest(from: owner), let source = BrowserDragDropController.captureLocalFileDropSource(info) else { return false }
        return request(source, owner: owner)
    }
    @discardableResult func request(_ source: LocalFileDropSource, owner: SFTPTabController) -> Bool {
        request(.init(key: .drop(source.key), urls: source.urls, access: source.access,
            isCurrent: { true }, acquireAccess: { [weak browser] in
                await browser?.accessLifetime(for: source.urls) ?? .init(leases: [])
            }, accepts: { _ in true }), owner: owner)
    }
    @discardableResult func request(_ selection: LocalPaneUploadSelection, owner: SFTPTabController) -> Bool {
        guard selection.isCurrent else { return false }
        return request(.init(key: .pane(selection.id), urls: selection.urls, access: .init(leases: []),
            isCurrent: { selection.isCurrent }, acquireAccess: { await selection.acquireAccess() },
            accepts: { selection.accepts($0) }), owner: owner)
    }
    func canPasteClipboard(to owner: SFTPTabController) -> Bool {
        canRequest(from: owner) && browser?.canPasteLocalCopies == true
    }
    /// Paste is an explicit Copy intent. Native file representations supply URLs;
    /// the existing group planner still observes and validates every source.
    @discardableResult func pasteClipboard(to owner: SFTPTabController) -> Bool {
        guard canPasteClipboard(to: owner), let browser else { return false }
        let state = browser.clipboardState, board = browser.transferPasteboard, revision = state.revision
        // Use the native reader here so cross-app file access travels with its
        // actual pasteboard representation, rather than a reconstructed path.
        guard let captured = state.readFiles(allowOwnedCopy: false), !captured.urls.isEmpty,
              captured.urls.allSatisfy(\.isFileURL), captured.isCurrent(on: board), state.pendingCut == nil else {
            browser.status.stringValue = "The copied files could not be read. Copy them again before pasting."
            return false
        }
        guard captured.urls.count <= 128 else {
            browser.status.stringValue = "Choose up to 128 local files or folders to paste into this server folder."
            ApplicationDiagnostics.shared.event(.remoteUpload, .blocked, error: DiagnosticErrors.project(SFTPUploadBatchIssue.tooLarge))
            return false
        }
        return request(.init(key: .clipboard(UUID()), urls: captured.urls, access: .init(leases: []),
            isCurrent: { [weak browser] in
                guard let browser, browser.clipboardState === state, browser.transferPasteboard === board,
                      state.revision == revision, state.pendingCut == nil, state.cutPreparation == nil else { return false }
                return captured.isCurrent(on: board)
            }, acquireAccess: { [weak browser] in
                await browser?.accessLifetime(for: captured.urls) ?? .init(leases: [])
            }, accepts: { _ in true }), owner: owner)
    }
    @discardableResult private func request(_ source: Source, owner: SFTPTabController) -> Bool {
        let diagnostic = RemoteTransferDiagnostics(.upload)
        guard canRequest(from: owner), source.isCurrent(), !accepted.contains(source.key), let browser, let storage = owner.uploads,
              let generation = owner.rows.cache.generation, let snapshot = owner.rows.cache.snapshot,
              case .sftp(let location) = browser.location else { diagnostic.finish(.blocked); return false }
        let tab = browser.activeID, visit = browser.sessionID, preparation = UUID(), coordinator = browser.operationCoordinator
        guard coordinator.beginPreparation(owner: preparation) else { diagnostic.finish(.blocked); return false }
        let destination = owner.breadcrumbs(for: location).map(\.0).joined(separator: " › ")
        accepted.append(source.key); if accepted.count > 64 { accepted.removeFirst(accepted.count - 64) }
        browser.operationPreparationID = preparation
        #if DEBUG
        acceptedCount += 1; lastCompleted = nil; lastInterruption = nil; lastNotice = ""
        #endif
        work = Task { [self, browser, owner] in
            var access = source.access, started = false, progressTask: Task<Void, Never>?
            let updates = AsyncStream.makeStream(of: SFTPUploadBatchProgress.self, bufferingPolicy: .bufferingNewest(1))
            defer {
                withExtendedLifetime(access) {}; withExtendedLifetime(source) {}
                updates.continuation.finish(); progressTask?.cancel(); work = nil
                if started { browser.finishOperationPresentation() }
                else { coordinator.finishPreparation(owner: preparation); browser.operationPreparationTask = nil; browser.operationPreparationID = nil }
                diagnostic.finish(.cancelled)
            }
            @MainActor func current() -> Bool {
                source.isCurrent() && !browser.isBrowserSuspended && browser.activeID == tab && browser.sessionID == visit && browser.location == .sftp(location)
                    && browser.sftpTabs[tab] === owner && !owner.isClosing && owner.session.latest.failure == nil
                    && owner.session.latest.generation == generation && owner.session.latest.snapshot == snapshot
            }
            do {
                diagnostic.stage(.source)
                let acquired = await source.acquireAccess()
                access = .init(leases: access.leases + acquired.leases)
                try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
                let exclusions = coordinator.protectedStorageLocations + [Bundle.main.bundleURL]
                let plan = try await SFTPUploadBatchPlan.inspect(source.urls, excluding: exclusions,
                    allowsFolders: SFTPFolderUploadFeature.available && owner.session.allowsFreshFolderUploads)
                guard source.accepts(plan) else { throw SFTPBrowserFailure.stale }
                try await plan.checkHistory(storage)
                try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
                if owner.reviewsUploads {
                    diagnostic.stage(.review, count: plan.logicalBytes)
                    let approved: Bool
                    #if DEBUG
                    if let reviewForVerification { approved = await reviewForVerification(plan, destination) }
                    else { approved = await review(plan, destination: destination, in: browser.view.window) }
                    #else
                    approved = await review(plan, destination: destination, in: browser.view.window)
                    #endif
                    guard approved else { return }
                }
                try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
                guard browser.startOperationPresentation("Uploading \(plan.items.count) items…", preparation: preparation, diagnosticTrace: diagnostic.trace) else { throw SFTPBrowserFailure.busy }
                started = true; browser.operationPreparationTask = nil; browser.operationPreparationID = nil; browser.operationTask = work
                progressTask = Task { [weak browser] in for await value in updates.stream {
                    diagnostic.stage(.receive, count: value.sentBytes)
                    guard let browser, !browser.operationStopRequested else { continue }
                    browser.operationPresentation = .init(phaseTitle: "Upload", percentage: plan.logicalBytes == 0 ? nil : min(1, Double(value.sentBytes) / Double(plan.logicalBytes)),
                        summary: "\(value.completedRoots) of \(value.totalRoots) items verified · \(destination)",
                        currentItem: plan.items[value.index].name, completedText: "\(FileSizeText.string(Int64(value.sentBytes))) sent")
                    browser.updateOperationProgressControls()
                } }
                diagnostic.stage(.receive, count: 0)
                let result = try await owner.session.uploadBatch(plan, generation: generation, storage: storage, excluding: exclusions,
                    progress: { updates.continuation.yield($0) })
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                diagnostic.finish(.completed, count: plan.logicalBytes)
                let message = "Uploaded \(result.completed.count) \(result.completed.count == 1 ? "item" : "items") and verified the server copies."
                notice(message, browser: browser, owner: owner)
                owner.refreshAfterUpload(at: location)
                #if DEBUG
                lastCompleted = result
                #endif
            } catch {
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                if owner.session.latest.failure != nil || started && Task.isCancelled { diagnostic.stage(.drain); diagnostic.drained(await owner.close().value) }
                diagnostic.fail(error, stopped: Task.isCancelled)
                let message = Self.message(error, stopped: Task.isCancelled)
                if owner.drain?.localResourcesEnded == true { browser.recordClosedSFTPUpload(tab, message: message, showHistory: owner.showUploadHistory) }
                notice(message, browser: browser, owner: owner)
                // A purely local later admission refusal may leave verified
                // roots on a live connection. Refresh once after this prefix.
                if let partial = error as? SFTPUploadBatchInterruption, !partial.completed.isEmpty,
                   owner.session.latest.failure == nil, !owner.isClosing { owner.refreshAfterUpload(at: location) }
                #if DEBUG
                lastInterruption = error as? SFTPUploadBatchInterruption
                #endif
            }
        }
        browser.operationPreparationTask = work
        return true
    }
    private func notice(_ text: String, browser: BrowserViewController, owner: SFTPTabController) {
        owner.showTransferOutcome(text)
        if browser.sftpTabs[browser.activeID] === owner { browser.status.stringValue = text }
        #if DEBUG
        lastNotice = text
        #endif
    }
    private func review(_ plan: SFTPUploadBatchPlan, destination: String, in window: NSWindow?) async -> Bool {
        await FileUploadGroupReview.choose(names: plan.items.map(\.name), bytes: plan.logicalBytes,
            destination: destination, in: window)
    }
    static func message(_ error: Error, stopped: Bool) -> String {
        if let partial = error as? SFTPUploadBatchInterruption {
            let prefix = "\(partial.completed.count) \(partial.completed.count == 1 ? "item" : "items") verified. "
            let current = partial.currentMayHaveStarted ? "The current item needs review in Upload Outcomes. " : ""
            let tail = partial.notSubmitted > 0 ? "\(partial.notSubmitted) not uploaded. " : ""
            return prefix + current + tail + detail(partial.cause, stopped: stopped)
        }
        return detail(error, stopped: stopped)
    }
    private static func detail(_ error: Error, stopped: Bool) -> String {
        switch error as? SFTPUploadBatchIssue {
        case .duplicateNames: return "Two selected items have the same destination name. Choose them separately or rename a local item first."
        case .overlappingSources: return "Choose each source once; a selected folder already includes its children."
        case .tooLarge: return "Choose a smaller group: up to 1 GiB, 1,024 files and 2,048 files/folders in total."
        case .historyFull: return "Upload Outcomes is full. Forget an inactive local record in Connection Storage before trying again."
        case .invalidSelection: return "Choose local files or folders to upload into the open server folder."
        default: return BrowserSFTPFolderUpload.message(error, stopped: stopped)
        }
    }
}
