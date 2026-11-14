import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

enum SFTPUploadFeature {
    // G preserves existing names; interrupted new files remain reviewable.
    static let enabled = true
    #if DEBUG
    @MainActor static var qualifying = false
    @MainActor static var available: Bool { qualifying || enabled && Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") == nil }
    #else
    static var available: Bool { enabled && !GeneratedSandboxReview.archivePublicAccessAdmitted }
    #endif
}

/// Explicit selected-file workflow. Swift owns UI/access/admission; the serial
/// remote pump and its retained source/history attempt own actual transfer.
@MainActor final class BrowserSFTPUpload {
    private weak var browser: BrowserViewController?
    private var work: Task<Void, Never>?, preview: SFTPUploadPreview?
    #if DEBUG
    var chooseForVerification: ((NSOpenPanel) async -> URL?)?
    var reviewForVerification: ((SFTPUploadPreview) async -> String?)?
    private(set) var lastCompleted: SFTPCompletedUpload?
    private(set) var lastNotice = "", lastSeconds = 0.0
    #endif
    init(browser: BrowserViewController) { self.browser = browser }
    func canRequest(from owner: SFTPTabController) -> Bool {
        guard SFTPUploadFeature.available, work == nil, let browser, !browser.isBrowserSuspended, browser.isSFTPLocation,
              browser.canRunExclusiveFileCommand, browser.view.window?.attachedSheet == nil,
              browser.sftpTabs[browser.activeID] === owner, !owner.isClosing, owner.uploads != nil,
              owner.session.allowsFreshUploads, owner.session.latest.failure == nil,
              owner.rows.cache.generation == owner.session.latest.generation, owner.rows.cache.snapshot?.state == .complete else { return false }
        return true
    }
    func request(from owner: SFTPTabController, selectedSource: LocalPaneFileSelection? = nil, reviewName: Bool = false) {
        let diagnostic = RemoteTransferDiagnostics(.upload)
        guard canRequest(from: owner), let browser, let storage = owner.uploads,
              let generation = owner.rows.cache.generation else { diagnostic.finish(.blocked); return }
        let tab = browser.activeID, visit = browser.sessionID, preparation = UUID(), coordinator = browser.operationCoordinator
        guard coordinator.beginPreparation(owner: preparation) else { diagnostic.finish(.blocked); return }
        browser.operationPreparationID = preparation
        work = Task { [self, browser, owner] in
            let began = ProcessInfo.processInfo.systemUptime
            var started = false, progressTask: Task<Void, Never>?
            let updates = AsyncStream.makeStream(of: UInt64.self, bufferingPolicy: .bufferingNewest(1))
            defer {
                updates.continuation.finish(); progressTask?.cancel(); preview = nil; work = nil
                if started { browser.finishOperationPresentation() }
                else { coordinator.finishPreparation(owner: preparation); browser.operationPreparationTask = nil; browser.operationPreparationID = nil }
                diagnostic.finish(.cancelled)
            }
            @MainActor func current() -> Bool {
                !browser.isBrowserSuspended && browser.activeID == tab && browser.sessionID == visit && browser.sftpTabs[tab] === owner
                    && !owner.isClosing && owner.session.latest.failure == nil && owner.session.latest.generation == generation
                    && (selectedSource?.isCurrent ?? true)
            }
            do {
                diagnostic.stage(.chooseSource)
                guard let window = browser.view.window else { return }
                let panel = NSOpenPanel(); panel.title = "Choose File to Upload"; panel.prompt = owner.reviewsUploads || reviewName ? "Review Upload" : "Upload"
                panel.message = "Select one local file (up to 1 GiB) to copy into this server folder. Existing items are kept."
                panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.resolvesAliases = false
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
                let source = try await SFTPUploadSourceReview.inspect(selected, excluding: excluded)
                try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
                guard case .sftp(let folder) = browser.location else { throw SFTPBrowserFailure.stale }
                var chosen: String? = source.name
                if owner.reviewsUploads || reviewName {
                    let destination = owner.transferDestination(for: folder)
                    let review = SFTPUploadPreview(source: source, destination: destination, settings: browser.settings); preview = review
                    diagnostic.stage(.review, count: source.logicalBytes)
                    #if DEBUG
                    if let reviewForVerification { chosen = await reviewForVerification(review) }
                    else { chosen = await review.choose(in: window) }
                    #else
                    chosen = await review.choose(in: window)
                    #endif
                }
                guard let chosen else { return }; try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
                let request = try SFTPRequestedUpload(generation: generation, reviewed: source, name: chosen)
                guard browser.startOperationPresentation("Uploading selected SFTP file…", preparation: preparation, diagnosticTrace: diagnostic.trace) else { throw SFTPBrowserFailure.busy }
                started = true; browser.operationPreparationTask = nil; browser.operationPreparationID = nil; browser.operationTask = work
                progressTask = Task { [weak browser] in for await bytes in updates.stream {
                    diagnostic.stage(.receive, count: bytes)
                    guard let browser, !browser.operationStopRequested else { continue }
                    browser.operationPresentation = .init(phaseTitle: "Upload", percentage: source.logicalBytes == 0 ? nil : min(1, Double(bytes) / Double(source.logicalBytes)),
                        summary: "Sending · server verification follows. Stop closes this connection.", currentItem: request.name.displayName,
                        completedText: "\(FileSizeText.string(Int64(bytes))) sent")
                    browser.updateOperationProgressControls()
                } }
                diagnostic.stage(.receive, count: 0)
                let result = try await owner.session.upload(request, storage: storage, excluding: coordinator.protectedStorageLocations + [Bundle.main.bundleURL], progress: { updates.continuation.yield($0) })
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                diagnostic.finish(.completed, count: source.logicalBytes)
                let message = "Uploaded “\(request.name.displayName)” and verified the server copy. Local original unchanged."
                owner.showTransferOutcome(message)
                owner.refreshAfterUpload()
                #if DEBUG
                lastCompleted = result; lastNotice = message; lastSeconds = ProcessInfo.processInfo.systemUptime - began
                #else
                _ = result
                #endif
            } catch {
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                if owner.session.latest.failure != nil || started && Task.isCancelled {
                    diagnostic.stage(.drain); diagnostic.drained(await owner.close().value)
                }
                diagnostic.fail(error, stopped: Task.isCancelled)
                let message = Self.message(error, stopped: Task.isCancelled)
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
        await withTaskCancellationHandler {
            await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
        } onCancel: { Task { @MainActor in panel.cancel(nil) } }
    }
    static func message(_ error: Error, stopped: Bool) -> String {
        if (error as? SFTPBrowserFailure) == .stale { return "The selection or destination changed. Review the upload again; no new upload was admitted." }
        if error is SFTPUploadOpenRefusal { return "Your account can’t add files to this server folder. Choose a writable folder and try again. Your connection is still open." }
        if let remote = error as? SFTPUploadInterruption {
            if remote.cause == .status && remote.status == 3 {
                return remote.publicationMayHaveHappened
                    ? "The server denied permission for this upload. The connection closed; a new remote file may exist. Review Upload Outcomes before trying again."
                    : "The server denied permission for this upload. The connection closed; review Upload Outcomes before trying again."
            }
            if remote.publicationMayHaveHappened { return "Upload did not finish. The new remote file may be incomplete or unverified. Review Upload Outcomes before trying again; nothing was replaced or removed." }
            if remote.temporaryMayExist { return "Upload did not finish. A remote temporary file may remain; its local record is in Upload Outcomes. Nothing was retried or removed." }
            if remote.cause == .conflict { return "That remote name already exists. It was preserved. Choose a different name and connect again if needed." }
            if remote.cause == .unsupportedSync { return "This server cannot acknowledge file synchronization required for upload. No remote file was created." }
        }
        switch error as? SFTPUploadLocalIssue {
        case .additionalFork: return "This file has a resource fork. Upload is data-fork-only and won’t silently omit it. Package it into a ZIP first."
        case .unsupportedSource: return "Choose a regular, locally available APFS file up to 1 GiB. Links, cloud-only files and folders are unavailable for this upload."
        case .sourceChanged: return "The local file changed. Review it again before uploading; inspect Upload Outcomes if sending had begun."
        case .historyFull: return "Local upload history is full. Review and Forget an inactive local record in Connection Storage before trying again."
        case .historyUnavailable: return "The local upload record could not be safely saved. Review Connection Storage; do not assume a remote publication succeeded."
        case .sourceUnavailable: return "The selected local file is unavailable or excluded from upload. No broader access was requested."
        default: break
        }
        return stopped || error is CancellationError ? "Upload stopped. Review Upload Outcomes for retained or uncertain remote work."
            : "Upload did not complete. Review Upload Outcomes before retrying; existing files were not replaced."
    }
}
