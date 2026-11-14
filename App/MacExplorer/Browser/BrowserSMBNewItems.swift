import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// New Item is a name prompt over the existing exclusive upload. A typed empty
/// request has no local file; the authenticated session/history own all IO.
@MainActor final class BrowserSMBNewItems {
    private weak var browser: BrowserViewController?
    private var work: Task<Void, Never>?
    init(browser: BrowserViewController) { self.browser = browser }

    func canRequest(_ kind: SMBNewItemKind, from owner: SMBTabController) -> Bool {
        guard SMBUploadFeature.newItemsAvailable, work == nil, let browser,
              !browser.isBrowserSuspended, browser.canRunExclusiveFileCommand,
              browser.hasFileCommandFocus, browser.view.window?.attachedSheet == nil,
              browser.smbTabs[browser.activeID] === owner, !owner.isClosing,
              owner.uploads != nil, owner.uploadDestination != nil else { return false }
        switch kind {
        case .textFile: return owner.session.allowsSelectedUploads
        case .folder: return SMBFolderUploadFeature.available && owner.session.allowsFolderUploads
        }
    }

    func request(_ kind: SMBNewItemKind, from owner: SMBTabController) {
        guard canRequest(kind, from: owner), let browser,
              let uploads = owner.uploads, let captured = owner.uploadDestination else { return }
        let tab = browser.activeID, visit = browser.sessionID, location = browser.location
        let coordinator = browser.operationCoordinator, preparation = UUID()
        guard coordinator.beginPreparation(owner: preparation) else { return }
        browser.operationPreparationID = preparation
        let diagnostic = RemoteTransferDiagnostics(.upload)
        work = Task { [self, browser, owner] in
            var started = false
            defer {
                work = nil
                if started { browser.finishOperationPresentation() }
                else if browser.operationPreparationID == preparation {
                    coordinator.finishPreparation(owner: preparation)
                    browser.operationPreparationTask = nil; browser.operationPreparationID = nil
                }
                diagnostic.finish(.cancelled)
            }
            @MainActor func sameLocation() -> Bool {
                !Task.isCancelled && !browser.isBrowserSuspended && browser.activeID == tab
                    && browser.sessionID == visit && browser.location == location
                    && browser.smbTabs[tab] === owner && !owner.isClosing
                    && owner.session.latest.failure == nil
            }
            @MainActor func currentDestination() -> Bool {
                guard sameLocation(), let current = owner.uploadDestination else { return false }
                return current.snapshot == captured.snapshot && current.components == captured.components
            }
            @MainActor func show(_ message: String) {
                owner.uploadNotice = message
                if browser.smbTabs[browser.activeID] === owner { browser.status.stringValue = message }
            }
            do {
                let title: String, initial: String, progress: String, message: String
                switch kind {
                case .textFile:
                    title = FilenamePrompt.newFileTitle; initial = FilenamePrompt.newFileDefaultName; progress = "Creating server file…"
                    message = FilenamePrompt.newFileInstructions
                case .folder:
                    title = "New Folder"; initial = "New folder"; progress = "Creating server folder…"
                    message = "Create an empty folder here. Existing folders will be kept."
                }
                diagnostic.stage(.review)
                guard let name = await browser.promptForName(title: title,
                    initial: owner.rows.suggestedNewName(initial, in: captured.snapshot),
                    message: message,
                    lengthLimit: .utf16Units(255),
                    validating: { candidate in
                        guard currentDestination() else { return "This folder changed. Cancel and try again." }
                        guard SMBRequestedUpload.isSupportedName(candidate) else { return "Choose a valid server name." }
                        return owner.hasObservedUploadName(candidate, in: captured.snapshot, directory: captured.components)
                            ? "That name already exists. Choose another name." : nil
                    }) else { return }
                try Task.checkCancellation()
                guard currentDestination() else { throw SMBUploadFailure.unavailable }
                if owner.hasObservedUploadName(name, in: captured.snapshot, directory: captured.components) {
                    diagnostic.finish(.blocked)
                    show("That name already exists. Nothing was created; choose another name.")
                    return
                }
                diagnostic.stage(.source)
                let request = try SMBRequestedNewItem(connection: owner.connectionID, snapshot: captured.snapshot,
                    directory: captured.components, kind: kind, name: name)
                try Task.checkCancellation()
                guard currentDestination() else { throw SMBUploadFailure.unavailable }
                guard browser.startOperationPresentation(progress, preparation: preparation,
                    diagnosticTrace: diagnostic.trace) else { throw SMBUploadFailure.busy }
                started = true; browser.operationPreparationTask = nil; browser.operationPreparationID = nil
                browser.operationTask = work
                diagnostic.stage(.receive, count: 0)
                _ = try await owner.session.createEmptyItem(request, storage: uploads)
                diagnostic.finish(.completed, count: 0)
                show("Created “\(name)”.")
                if sameLocation() { owner.refreshAfterUpload() }
            } catch {
                if owner.session.latest.failure != nil {
                    diagnostic.stage(.drain)
                    let result = await owner.close().value
                    diagnostic.drained(result, commandCounts: owner.session.commandCounts)
                }
                diagnostic.fail(error, stopped: Task.isCancelled)
                let notice = Self.message(error, stopped: Task.isCancelled)
                show(notice)
                if owner.drain != nil {
                    browser.recordClosedSMBUpload(tab, message: notice, showHistory: owner.showUploadHistory)
                }
            }
        }
        browser.operationPreparationTask = work
    }

    private static func message(_ error: Error, stopped: Bool) -> String {
        if let issue = error as? SMBUploadFailure {
            switch issue {
            case .finalCollision: return "That server name already exists. It was kept; Connection Activity shows any retained working copy."
            case .stageCollision: return "A temporary server name is already occupied. It was kept; nothing new was created."
            case .busy: return "This connection is already working. Wait for it to finish."
            case .invalidInput: return "Choose a valid new name in the current server folder."
            case .storage: return "Creation could not be recorded safely. Review Connection Storage before trying again."
            case .unavailable: return "The connection or folder changed. Check Connection Activity before trying again."
            case .sourceChanged: return "The creation request could not be verified. Check Connection Activity before trying again."
            case .stopped, .reviewRequired: break
            }
        }
        return stopped || error is CancellationError
            ? "Creation stopped. Check Connection Activity before retrying; an item or working copy may remain."
            : "Creation could not be confirmed. Check Connection Activity before retrying; existing server items were kept."
    }
}
