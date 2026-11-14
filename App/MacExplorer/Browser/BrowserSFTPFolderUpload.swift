import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor final class BrowserSFTPFolderUpload {
    private weak var browser: BrowserViewController?
    private(set) var work: Task<Void, Never>?
    private var preview: SFTPFolderUploadPreview?
    #if DEBUG
    var chooseForVerification: ((NSOpenPanel) async -> URL?)?
    var reviewForVerification: ((SFTPFolderUploadPreview) async -> String?)?
    private(set) var lastCompleted: SFTPCompletedFolderUpload?, lastNotice: String?, lastSeconds: TimeInterval?
    #endif
    init(browser: BrowserViewController) { self.browser = browser }
    func canRequest(from owner: SFTPTabController) -> Bool {
        guard SFTPFolderUploadFeature.available, work == nil, let browser, !browser.isBrowserSuspended, browser.isSFTPLocation,
              browser.canRunExclusiveFileCommand, browser.view.window?.attachedSheet == nil,
              browser.sftpTabs[browser.activeID] === owner, !owner.isClosing, owner.uploads != nil,
              owner.session.allowsFreshFolderUploads, owner.session.latest.failure == nil,
              owner.rows.cache.generation == owner.session.latest.generation, owner.rows.cache.snapshot?.state == .complete else { return false }
        return true
    }
    func request(from owner: SFTPTabController, selectedSource: LocalPaneFileSelection? = nil, reviewName: Bool = false) {
        let diagnostic = RemoteTransferDiagnostics(.upload)
        guard canRequest(from: owner), let browser, let storage = owner.uploads, let generation = owner.rows.cache.generation else { diagnostic.finish(.blocked); return }
        let tab = browser.activeID, visit = browser.sessionID, preparation = UUID(), coordinator = browser.operationCoordinator
        guard coordinator.beginPreparation(owner: preparation) else { diagnostic.finish(.blocked); return }
        browser.operationPreparationID = preparation
        work = Task { [self, browser, owner] in
            let began = ProcessInfo.processInfo.systemUptime
            var started = false, progressTask: Task<Void, Never>?
            let updates = AsyncStream.makeStream(of: (UInt64, Int).self, bufferingPolicy: .bufferingNewest(1))
            defer {
                updates.continuation.finish(); progressTask?.cancel(); preview = nil; work = nil
                if started { browser.finishOperationPresentation() }
                else { coordinator.finishPreparation(owner: preparation); browser.operationPreparationTask = nil; browser.operationPreparationID = nil }
                diagnostic.finish(.cancelled)
            }
            @MainActor func current() -> Bool {
                !browser.isBrowserSuspended && browser.activeID == tab && browser.sessionID == visit && browser.sftpTabs[tab] === owner
                    && !owner.isClosing && owner.session.latest.failure == nil && owner.session.latest.generation == generation && (selectedSource?.isCurrent ?? true)
            }
            do {
                diagnostic.stage(.chooseSource); guard let window = browser.view.window else { return }
                let panel = NSOpenPanel(); panel.title = "Choose Folder to Upload"; panel.prompt = owner.reviewsUploads || reviewName ? "Review Upload" : "Upload"
                panel.message = "Choose one local folder to copy into this server folder. Existing items are kept."
                panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.resolvesAliases = false
                let selected: URL?
                if let selectedSource { guard selectedSource.isCurrent else { throw SFTPBrowserFailure.stale }; selected = selectedSource.url }
                else {
                    #if DEBUG
                    if let chooseForVerification { selected = await chooseForVerification(panel) }
                    else { selected = await choose(panel, in: window) }
                    #else
                    selected = await choose(panel, in: window)
                    #endif
                }
                guard let selected else { return }; try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
                diagnostic.stage(.source)
                let excluded = coordinator.protectedStorageLocations + [Bundle.main.bundleURL]
                let source = try await SFTPFolderUploadSourceReview.inspect(selected, excluding: excluded)
                try Task.checkCancellation(); guard current(), case .sftp(let folder) = browser.location else { throw SFTPBrowserFailure.stale }
                var chosen: String? = source.name
                if owner.reviewsUploads || reviewName {
                    let destination = owner.transferDestination(for: folder)
                    let review = SFTPFolderUploadPreview(source: source, destination: destination, settings: browser.settings); preview = review
                    diagnostic.stage(.review, count: source.logicalBytes)
                    #if DEBUG
                    if let reviewForVerification { chosen = await reviewForVerification(review) }
                    else { chosen = await review.choose(in: window) }
                    #else
                    chosen = await review.choose(in: window)
                    #endif
                }
                guard let chosen else { return }; try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
                let request = try SFTPRequestedFolderUpload(generation: generation, reviewed: source, name: chosen)
                guard browser.startOperationPresentation("Uploading selected SFTP folder…", preparation: preparation, diagnosticTrace: diagnostic.trace) else { throw SFTPBrowserFailure.busy }
                started = true; browser.operationPreparationTask = nil; browser.operationPreparationID = nil; browser.operationTask = work
                progressTask = Task { [weak browser] in for await (bytes, files) in updates.stream {
                    let finalChecks = files == source.files
                    diagnostic.stage(finalChecks ? .verify : .receive, count: bytes)
                    guard let browser, !browser.operationStopRequested else { continue }
                    browser.operationPresentation = .init(phaseTitle: finalChecks ? "Checking uploaded folder" : "Upload Folder", percentage: source.logicalBytes == 0 || finalChecks ? nil : min(1, Double(bytes) / Double(source.logicalBytes)),
                        summary: finalChecks ? "Final checks are running. Your local folder is kept." : "\(files) of \(source.files) files verified. Stop closes this connection.", currentItem: request.name.displayName,
                        completedText: "\(FileSizeText.string(Int64(bytes))) sent")
                    browser.updateOperationProgressControls()
                } }
                diagnostic.stage(.receive, count: 0)
                let result = try await owner.session.uploadFolder(request, storage: storage, excluding: excluded, progress: { updates.continuation.yield(($0, $1)) })
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                diagnostic.finish(.completed, count: result.logicalBytes)
                let message = "Uploaded “\(request.name.displayName)” · \(result.files) files verified."
                owner.showTransferOutcome(message); owner.refreshAfterUpload()
                #if DEBUG
                lastCompleted = result; lastNotice = message; lastSeconds = ProcessInfo.processInfo.systemUptime - began
                #endif
            } catch {
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                if owner.session.latest.failure != nil || started && Task.isCancelled { diagnostic.stage(.drain); diagnostic.drained(await owner.close().value) }
                diagnostic.fail(error, stopped: Task.isCancelled); let message = Self.message(error, stopped: Task.isCancelled)
                if owner.drain?.localResourcesEnded == true { browser.recordClosedSFTPUpload(tab, message: message, showHistory: owner.showUploadHistory) }
                owner.showTransferOutcome(message)
                #if DEBUG
                lastNotice = message; lastSeconds = ProcessInfo.processInfo.systemUptime - began
                #endif
            }
        }
        browser.operationPreparationTask = work
    }
    private func choose(_ panel: NSOpenPanel, in window: NSWindow) async -> URL? {
        await withTaskCancellationHandler { await panel.beginSheetModal(for: window) == .OK ? panel.url : nil }
            onCancel: { Task { @MainActor in panel.cancel(nil) } }
    }
    static func message(_ error: Error, stopped: Bool) -> String {
        if let remote = error as? SFTPFolderUploadInterruption {
            if remote.cause == .status && remote.status == 3 {
                return remote.rootMayExist
                    ? "The server denied permission during folder upload. The connection closed; a partial folder may remain. Review Upload Outcomes before trying again."
                    : "The server denied permission during folder upload. The connection closed; review Upload Outcomes before trying again."
            }
            if remote.rootMayExist { return "The folder upload did not finish. Review the partial folder on the server and its local Upload Outcome before trying again." }
            if remote.cause == .conflict { return "That folder name already exists. Choose a new name; the existing item was kept." }
            if remote.cause == .unsupportedSync { return "This server cannot provide the verification needed for folder uploads. No folder was created." }
        }
        switch error as? SFTPUploadLocalIssue {
        case .unsupportedSource: return "Choose a locally available APFS folder within this beta’s limits. The whole selection must be supported; links and cloud-only items aren’t skipped silently."
        case .additionalFork: return "A member has extra Mac resource data that SFTP cannot copy in this mode. Package the folder into a ZIP or choose a different folder."
        case .sourceChanged: return "The selected folder changed. Review it again; check Upload Outcomes if copying had begun."
        default: break
        }
        return BrowserSFTPUpload.message(error, stopped: stopped)
    }
}
