import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum SMBUploadFeature {
    // Product editions share the same command and bounded serial owner. Local
    // source grants, session permissions and publication checks still apply.
    #if DEBUG
    static var qualifying = false
    #endif
    static var available: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return AppFeatureAvailability.allows(.serverDropUpload)
    }
    private static var qualifyingNativeInput: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        if GeneratedSandboxReview.admitted { return available }
        return false
    }
    static var dropAvailable: Bool { available }
    static var newItemsAvailable: Bool {
        #if DEBUG
        if qualifying { return available }
        #endif
        return available && AppFeatureAvailability.allows(.serverActions)
    }
    static var pasteAvailable: Bool {
        return available && (qualifyingNativeInput || AppFeatureAvailability.allows(.serverPasteUpload))
    }
    static var paneCopyAvailable: Bool { available }
    static var groupsAvailable: Bool {
        #if DEBUG
        if qualifying { return available }
        #endif
        return available && AppFeatureAvailability.allows(.serverFolderUpload)
    }
    static var selectionLimit: Int {
        groupsAvailable ? SMBUploadGroupPlan.maximumRoots : 1
    }
    static var selectionDescription: String {
        selectionLimit == 1 ? "one local item" : "up to \(selectionLimit) local items"
    }
    static var commandTitle: String { SMBFolderUploadFeature.available ? "Upload Here…" : "Upload Files Here…" }
}

@MainActor enum SMBFolderUploadFeature {
    #if DEBUG
    static var qualifying = false
    #endif
    static var available: Bool {
        #if DEBUG
        if qualifying { return SMBUploadFeature.available }
        #endif
        return SMBUploadFeature.available && AppFeatureAvailability.allows(.serverFolderUpload)
    }
}

/// Concrete SMB ownership. The shared review supplies presentation only; the
/// authenticated session revalidates the destination and performs every write.
@MainActor final class BrowserSMBUpload {
    private struct SourceOffer {
        let urls: [URL]
        let retainedAccess: FileAccessLifetimes
        let isCurrent: () -> Bool
        let acquireAccess: () async -> FileAccessLifetimes
        let accepts: (SMBUploadGroupPlan) -> Bool
    }
    private enum Prepared {
        case single(SFTPUploadSourceReview, SMBRequestedUpload)
        case group(SMBUploadGroupPlan)
        var names: [String] {
            switch self { case .single(_, let request): [request.name.displayName]; case .group(let plan): plan.items.map(\.name) }
        }
        var bytes: UInt64 {
            switch self { case .single(let source, _): source.logicalBytes; case .group(let plan): plan.logicalBytes }
        }
        var hasFolders: Bool {
            switch self { case .single: false; case .group(let plan): plan.items.contains { $0.kind == .folder } }
        }
    }
    private struct Progress: Sendable {
        let index: Int, completed: Int, sent: UInt64, currentBytes: UInt64, currentTotal: UInt64
    }
    private weak var browser: BrowserViewController?
    private var work: Task<Void, Never>?, review: FileUploadReview?
    private var acceptedDrops: [LocalFileDropKey] = []
    #if DEBUG
    var chooseForVerification: ((NSOpenPanel) async -> URL?)?
    var chooseGroupForVerification: ((NSOpenPanel) async -> [URL]?)?
    var reviewForVerification: ((FileUploadReview) async -> String?)?
    var groupReviewForVerification: ((SMBUploadGroupPlan) async -> Bool)?
    private(set) var lastCompleted: SMBCompletedUpload?
    private(set) var lastGroupCompleted: SMBUploadGroupResult?
    private(set) var lastGroupInterruption: SMBUploadGroupInterruption?
    private(set) var lastNotice = ""
    #endif
    init(browser: BrowserViewController) { self.browser = browser }

    func canRequest(from owner: SMBTabController) -> Bool {
        guard SMBUploadFeature.available, work == nil, let browser,
              !browser.isBrowserSuspended, browser.isSMBLocation,
              browser.canRunExclusiveFileCommand, browser.view.window?.attachedSheet == nil,
              browser.smbTabs[browser.activeID] === owner, owner.uploads != nil,
              owner.uploadDestination != nil else { return false }
        return true
    }
    func request(from owner: SMBTabController, selectedSource: LocalPaneFileSelection? = nil, reviewName: Bool = false) {
        let allowsFolders = acceptsFolders(from: owner)
        let offer = selectedSource.map { selected in
            SourceOffer(urls: [selected.url], retainedAccess: .init(leases: []),
                isCurrent: { (!selected.isFolder || allowsFolders) && selected.isCurrent },
                acquireAccess: { await selected.acquireAccess() }, accepts: {
                    $0.items.count == 1 && ($0.items[0].kind == .folder) == selected.isFolder
                })
        }
        _ = beginRequest(from: owner, sourceOffer: offer, reviewName: reviewName)
    }
    func request(from owner: SMBTabController, selectedGroup: LocalPaneUploadSelection) {
        guard selectedGroup.isCurrent, !selectedGroup.hasFolders || acceptsFolders(from: owner),
              selectedGroup.urls.count <= SMBUploadFeature.selectionLimit else { return }
        _ = beginRequest(from: owner, sourceOffer: .init(urls: selectedGroup.urls, retainedAccess: .init(leases: []),
            isCurrent: { selectedGroup.isCurrent }, acquireAccess: { await selectedGroup.acquireAccess() },
            accepts: { selectedGroup.accepts($0) }))
    }
    func acceptsFolders(from owner: SMBTabController) -> Bool {
        SMBFolderUploadFeature.available && owner.session.allowsFolderUploads
    }
    func previewDrop(_ info: NSDraggingInfo, owner: SMBTabController) -> Bool {
        guard SMBUploadFeature.dropAvailable, canRequest(from: owner),
              let source = BrowserDragDropController.captureLocalFileDropSource(info),
              (1...SMBUploadFeature.selectionLimit).contains(source.urls.count),
              acceptsFolders(from: owner) || source.urls.allSatisfy({ !$0.hasDirectoryPath }),
              !acceptedDrops.contains(source.key) else { return false }
        return true
    }
    @discardableResult func acceptDrop(_ info: NSDraggingInfo, owner: SMBTabController) -> Bool {
        guard previewDrop(info, owner: owner), let source = BrowserDragDropController.captureLocalFileDropSource(info),
              let browser else { return false }
        let offer = SourceOffer(urls: source.urls, retainedAccess: source.access, isCurrent: { true },
            acquireAccess: { [weak browser] in await browser?.accessLifetime(for: source.urls) ?? .init(leases: []) },
            accepts: { _ in true })
        guard beginRequest(from: owner, sourceOffer: offer) else { return false }
        acceptedDrops.append(source.key)
        if acceptedDrops.count > 64 { acceptedDrops.removeFirst(acceptedDrops.count - 64) }
        return true
    }
    func canPasteClipboard(to owner: SMBTabController) -> Bool {
        SMBUploadFeature.pasteAvailable && canRequest(from: owner) && browser?.canPasteLocalCopies == true
    }
    @discardableResult func pasteClipboard(to owner: SMBTabController) -> Bool {
        guard canPasteClipboard(to: owner), let browser else { return false }
        let state = browser.clipboardState, board = browser.transferPasteboard, revision = state.revision
        guard let captured = state.readFiles(allowOwnedCopy: false),
              (1...SMBUploadFeature.selectionLimit).contains(captured.urls.count),
              captured.urls.allSatisfy(\.isFileURL),
              acceptsFolders(from: owner) || captured.urls.allSatisfy({ !$0.hasDirectoryPath }),
              captured.isCurrent(on: board) else {
            browser.status.stringValue = acceptsFolders(from: owner)
                ? "Copy \(SMBUploadFeature.selectionDescription) to upload here."
                : "Copy \(SMBUploadFeature.selectionDescription) to upload here. Folder uploads are not available on this connection."
            return false
        }
        let offer = SourceOffer(urls: captured.urls, retainedAccess: .init(leases: []), isCurrent: { [weak browser] in
            guard let browser, browser.clipboardState === state, browser.transferPasteboard === board,
                  state.revision == revision, state.pendingCut == nil, state.cutPreparation == nil else { return false }
            return captured.isCurrent(on: board)
        }, acquireAccess: { [weak browser] in await browser?.accessLifetime(for: captured.urls) ?? .init(leases: []) },
            accepts: { _ in true })
        return beginRequest(from: owner, sourceOffer: offer)
    }

    @discardableResult private func beginRequest(from owner: SMBTabController, sourceOffer: SourceOffer? = nil,
                                                reviewName: Bool = false) -> Bool {
        let diagnostic = RemoteTransferDiagnostics(.upload)
        guard canRequest(from: owner), let browser, let storage = owner.uploads,
              let destination = owner.uploadDestination, sourceOffer?.isCurrent() != false else { diagnostic.finish(.blocked); return false }
        let tab = browser.activeID, visit = browser.sessionID, preparation = UUID()
        let coordinator = browser.operationCoordinator
        guard coordinator.beginPreparation(owner: preparation) else { diagnostic.finish(.blocked); return false }
        browser.operationPreparationID = preparation
        #if DEBUG
        lastCompleted = nil; lastGroupCompleted = nil; lastGroupInterruption = nil; lastNotice = ""
        #endif
        work = Task { [self, browser, owner] in
            var started = false, requestID: UUID?, progressTask: Task<Void, Never>?
            var access = sourceOffer?.retainedAccess ?? FileAccessLifetimes(leases: [])
            let updates = AsyncStream.makeStream(of: Progress.self, bufferingPolicy: .bufferingNewest(1))
            defer {
                withExtendedLifetime(access) {}; withExtendedLifetime(sourceOffer) {}
                updates.continuation.finish(); progressTask?.cancel(); review = nil; work = nil
                if started { browser.finishOperationPresentation() }
                else {
                    coordinator.finishPreparation(owner: preparation)
                    browser.operationPreparationTask = nil; browser.operationPreparationID = nil
                }
                diagnostic.finish(.cancelled)
            }
            @MainActor func current() -> Bool {
                guard !browser.isBrowserSuspended, browser.activeID == tab, browser.sessionID == visit,
                      browser.smbTabs[tab] === owner, let latest = owner.uploadDestination else { return false }
                return latest.snapshot == destination.snapshot && latest.components == destination.components
                    && (sourceOffer?.isCurrent() ?? true)
            }
            @MainActor func nameWasObserved(_ name: String) -> Bool {
                owner.hasObservedUploadName(name, in: destination.snapshot, directory: destination.components)
            }
            @MainActor func refuseObservedName() {
                diagnostic.finish(.blocked)
                show("A matching name was found in this folder. Nothing was uploaded. Choose another name or destination; refresh if the server has changed.",
                     browser: browser, owner: owner)
            }
            do {
                diagnostic.stage(.chooseSource)
                guard let window = browser.view.window else { return }
                let allowsFolders = acceptsFolders(from: owner)
                let panel = NSOpenPanel(); panel.title = allowsFolders ? "Choose Items to Upload" : "Choose Files to Upload"
                panel.prompt = owner.reviewsUploads || reviewName ? "Review Upload" : "Upload"
                panel.message = "Choose \(SMBUploadFeature.selectionDescription), up to 1 GiB in total. Existing server names are kept."
                panel.canChooseFiles = true; panel.canChooseDirectories = allowsFolders
                panel.allowsMultipleSelection = !reviewName && SMBUploadFeature.groupsAvailable; panel.resolvesAliases = false
                let selected: [URL]?
                if let sourceOffer {
                    guard sourceOffer.isCurrent() else { throw SMBUploadFailure.sourceChanged }
                    let acquired = await sourceOffer.acquireAccess()
                    access = .init(leases: access.leases + acquired.leases)
                    try Task.checkCancellation(); guard current() else { throw SMBUploadFailure.sourceChanged }
                    selected = sourceOffer.urls
                } else {
                    #if DEBUG
                    if let chooseGroupForVerification { selected = await chooseGroupForVerification(panel) }
                    else if let chooseForVerification { selected = await chooseForVerification(panel).map { [$0] } }
                    else { selected = await choose(panel, in: window) }
                    #else
                    selected = await choose(panel, in: window)
                    #endif
                }
                guard let selected, !selected.isEmpty else { return }
                try Task.checkCancellation(); guard current() else { throw SMBUploadFailure.unavailable }
                let excluded = coordinator.protectedStorageLocations + [Bundle.main.bundleURL]
                diagnostic.stage(.source)
                guard selected.count <= SMBUploadFeature.selectionLimit else { throw SMBUploadGroupIssue.invalidSelection }
                // A known group collision needs no source-body inventory or
                // server working copy. Unknown names still reach no-replace
                // publication, which remains authoritative for races/aliases.
                if selected.count > 1, selected.contains(where: { nameWasObserved($0.lastPathComponent) }) {
                    refuseObservedName(); return
                }
                let plan = try await SMBUploadGroupPlan.inspect(selected, excluding: excluded, allowsFolders: allowsFolders)
                guard sourceOffer?.accepts(plan) != false else { throw SMBUploadFailure.sourceChanged }
                try Task.checkCancellation(); guard current() else { throw SMBUploadFailure.unavailable }
                if plan.singleFileReview == nil, plan.items.contains(where: { nameWasObserved($0.name) }) {
                    refuseObservedName(); return
                }
                try await plan.checkHistory(storage)
                let prepared: Prepared
                if let source = plan.singleFileReview {
                    try Task.checkCancellation(); guard current() else { throw SMBUploadFailure.unavailable }
                    var name: String? = source.name
                    if owner.reviewsUploads || reviewName || !SMBRequestedUpload.isSupportedName(source.name) || nameWasObserved(source.name) {
                        let preview = FileUploadReview(source: source, destination: owner.uploadDestinationDescription,
                            settings: browser.settings, policy: .stagedSMB, nameIsValid: SMBRequestedUpload.isSupportedName,
                            nameIsOccupied: { [weak owner] in
                                owner?.hasObservedUploadName($0, in: destination.snapshot, directory: destination.components) == true
                            })
                        review = preview; diagnostic.stage(.review, count: source.logicalBytes)
                        #if DEBUG
                        if let reviewForVerification { name = await reviewForVerification(preview) }
                        else { name = await preview.choose(in: window) }
                        #else
                        name = await preview.choose(in: window)
                        #endif
                    }
                    guard let name else { return }
                    try Task.checkCancellation(); guard current() else { throw SMBUploadFailure.unavailable }
                    if nameWasObserved(name) { refuseObservedName(); return }
                    let request = try SMBRequestedUpload(connection: owner.connectionID, snapshot: destination.snapshot,
                        directory: destination.components, reviewed: source, name: name)
                    requestID = request.request; prepared = .single(source, request)
                } else {
                    try Task.checkCancellation(); guard current() else { throw SMBUploadFailure.unavailable }
                    if owner.reviewsUploads {
                        diagnostic.stage(.review, count: plan.logicalBytes)
                        let approved: Bool
                        #if DEBUG
                        if let groupReviewForVerification { approved = await groupReviewForVerification(plan) }
                        else { approved = await FileUploadGroupReview.choose(names: plan.items.map(\.name), bytes: plan.logicalBytes,
                            destination: owner.uploadDestinationDescription, in: window) }
                        #else
                        approved = await FileUploadGroupReview.choose(names: plan.items.map(\.name), bytes: plan.logicalBytes,
                            destination: owner.uploadDestinationDescription, in: window)
                        #endif
                        guard approved else { return }
                    }
                    prepared = .group(plan)
                }
                try Task.checkCancellation(); guard current() else { throw SMBUploadFailure.unavailable }
                guard browser.startOperationPresentation("Uploading \(prepared.names.count) \(prepared.hasFolders ? "items" : prepared.names.count == 1 ? "file" : "files")…",
                    preparation: preparation, diagnosticTrace: diagnostic.trace) else { throw SMBUploadFailure.busy }
                started = true; browser.operationPreparationTask = nil; browser.operationPreparationID = nil
                browser.operationTask = work
                progressTask = Task { [weak browser] in
                    for await value in updates.stream {
                        diagnostic.stage(.receive, count: value.sent)
                        guard let browser, !browser.operationStopRequested, prepared.names.indices.contains(value.index) else { continue }
                        let verifying = value.completed < prepared.names.count && value.currentBytes >= value.currentTotal
                        browser.operationPresentation = .init(phaseTitle: verifying ? "Verify server copy" : "Upload",
                            percentage: verifying || prepared.bytes == 0 ? nil : min(1, Double(value.sent) / Double(prepared.bytes)),
                            summary: "\(value.completed) of \(prepared.names.count) items verified · Existing names are kept.",
                            currentItem: prepared.names[value.index], completedText: "\(FileSizeText.string(Int64(value.sent))) sent")
                        browser.updateOperationProgressControls()
                    }
                }
                diagnostic.stage(.receive, count: 0)
                switch prepared {
                case .single(let source, let request):
                    let result = try await owner.session.upload(request, storage: storage, excluding: excluded,
                        progress: { updates.continuation.yield(.init(index: 0, completed: 0, sent: $0,
                            currentBytes: $0, currentTotal: source.logicalBytes)) })
                    #if DEBUG
                    lastCompleted = result
                    #else
                    _ = result
                    #endif
                case .group(let plan):
                    let result = try await SMBUploadGroupRunner.run(plan, connection: owner.connectionID,
                        snapshot: destination.snapshot, directory: destination.components, session: owner.session,
                        storage: storage, excluding: excluded, requireCurrent: {
                            try await MainActor.run {
                                // Admission is sealed. UI selection or browsing no longer retargets it.
                                guard !browser.isBrowserSuspended, browser.smbTabs[tab] === owner,
                                      !owner.isClosing, owner.session.latest.failure == nil else { throw SMBUploadFailure.unavailable }
                            }
                        }, progress: { value in
                            guard plan.items.indices.contains(value.index) else { return }
                            let before = plan.items.prefix(value.index).reduce(UInt64(0)) { $0 + $1.logicalBytes }
                            updates.continuation.yield(.init(index: value.index, completed: value.completedRoots,
                                sent: value.sentBytes, currentBytes: value.sentBytes >= before ? value.sentBytes - before : 0,
                                currentTotal: plan.items[value.index].logicalBytes))
                        })
                    #if DEBUG
                    lastGroupCompleted = result
                    #else
                    _ = result
                    #endif
                }
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                diagnostic.finish(.completed, count: prepared.bytes)
                let notice = "Uploaded \(prepared.names.count) \(prepared.hasFolders ? "items" : prepared.names.count == 1 ? "file" : "files") and verified the server copies."
                show(notice, browser: browser, owner: owner)
                owner.refreshAfterUpload()
            } catch {
                updates.continuation.finish(); await progressTask?.value; progressTask = nil
                // The concrete session drains an admitted cancelled attempt.
                // A purely queued/local group refusal must leave its reader usable.
                if owner.session.latest.failure != nil {
                    diagnostic.stage(.drain)
                    let drained = await owner.close().value
                    diagnostic.drained(drained, commandCounts: owner.session.commandCounts)
                }
                diagnostic.fail(error, stopped: Task.isCancelled)
                var outcome: SMBUploadOutcome?
                if !Task.isCancelled, let requestID, let records = try? await storage.inspect() {
                    outcome = records.records.first { $0.id == requestID }?.outcome
                }
                let notice = Self.message(error, stopped: Task.isCancelled, outcome: outcome)
                show(notice, browser: browser, owner: owner)
                if owner.drain != nil {
                    browser.recordClosedSMBUpload(tab, message: notice, showHistory: owner.showUploadHistory)
                }
                if let partial = error as? SMBUploadGroupInterruption, !partial.completed.isEmpty,
                   owner.session.latest.failure == nil, !owner.isClosing { owner.refreshAfterUpload() }
                #if DEBUG
                lastGroupInterruption = error as? SMBUploadGroupInterruption
                #endif
            }
        }
        browser.operationPreparationTask = work
        return true
    }
    private func show(_ text: String, browser: BrowserViewController, owner: SMBTabController) {
        owner.uploadNotice = text
        if browser.smbTabs[browser.activeID] === owner { browser.status.stringValue = text }
        #if DEBUG
        lastNotice = text
        #endif
    }
    private func choose(_ panel: NSOpenPanel, in window: NSWindow) async -> [URL]? {
        await withTaskCancellationHandler {
            await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
        } onCancel: { Task { @MainActor in panel.cancel(nil) } }
    }
    static func message(_ error: Error, stopped: Bool, outcome: SMBUploadOutcome?) -> String {
        if let partial = error as? SMBUploadGroupInterruption {
            let current: String
            switch partial.current {
            case .recorded(_, let outcome): current = message(partial.cause, stopped: stopped, outcome: outcome) + " "
            case .uncertain: current = "The current item needs review in Upload Outcomes. "
            case nil: current = ""
            }
            return "\(partial.completed.count) items verified. " + current
                + (partial.notSubmitted > 0 ? "\(partial.notSubmitted) not sent. " : "")
                + (partial.current == nil ? message(partial.cause, stopped: stopped, outcome: nil) : "")
        }
        if let issue = error as? SMBUploadGroupIssue {
            switch issue {
            case .duplicateNames: return "Some selected items have overlapping server names. Upload them separately or choose different names."
            case .overlappingSources: return "Choose each item once, without also selecting its parent folder."
            case .invalidSelection: return SMBFolderUploadFeature.available
                ? "Choose \(SMBUploadFeature.selectionDescription) with supported server names."
                : "Choose \(SMBUploadFeature.selectionDescription) with supported server names. Folder uploads are not available on this connection."
            case .tooLarge: return "Choose a smaller group, up to 1 GiB in total."
            case .historyFull: return "Upload Outcomes is full. Review inactive local records in Connection Storage."
            case .historyBusy: return "Another upload is using Connection Storage. Wait for it to finish."
            }
        }
        if outcome == .finalCollision {
            return "That server name already exists. It was kept; a verified working copy remains for review in Upload Outcomes."
        }
        if outcome == .reviewPublication || outcome == .publicationRequested {
            return "The new item may have been published, but the upload could not be confirmed. Review Upload Outcomes before retrying."
        }
        if let outcome, [SMBUploadOutcome.stageMayExist, .reviewTemporary, .stageConfirmed, .stageRequested].contains(outcome) {
            return "Upload stopped before it could be confirmed. A working copy may remain; review Upload Outcomes before retrying."
        }
        if let failure = error as? SMBUploadFailure {
            switch failure {
            case .stageCollision: return "The server working name is already occupied. It was kept; no upload was started."
            case .finalCollision: return "That server name already exists. It was kept; review Upload Outcomes for this attempt."
            case .invalidInput: return SMBFolderUploadFeature.available
                ? "Choose a supported file or folder and a valid new server name. Existing names are kept."
                : "Choose a supported regular file and a valid new server name. Existing names are kept."
            case .sourceChanged: return "A selected local item changed. Choose it again; your original stays unchanged."
            case .storage: return "The local upload record could not be safely saved. Review Connection Storage before trying again."
            case .unavailable: return "The connection or destination changed. Refresh the folder before uploading."
            case .busy: return "This connection is already working. Wait for it to finish before uploading."
            case .stopped, .reviewRequired: break
            }
        }
        if SMBFolderUploadFeature.available, let issue = error as? SFTPUploadLocalIssue {
            switch issue {
            case .unsupportedSource: return "Choose a downloaded local file or folder with supported server names. Links and cloud-only items cannot be uploaded."
            case .sourceChanged: return "A selected item or folder’s contents changed. Choose it again; review Upload Outcomes if sending had begun."
            case .sourceUnavailable: return "A selected item is unavailable or excluded from upload. Your local originals stay unchanged."
            default: break
            }
        }
        if error is SFTPUploadLocalIssue { return BrowserSFTPUpload.message(error, stopped: stopped) }
        return stopped || error is CancellationError ? "Upload stopped. Review Upload Outcomes for any retained server work."
            : "Upload did not finish. Review Upload Outcomes before retrying; your local original stays unchanged."
    }
}

@MainActor extension BrowserViewController {
    @objc func uploadFileToSMB(_ sender: Any?) {
        guard let owner = smbTabs[activeID] else { return }
        smbUpload.request(from: owner)
    }
    @objc func showSMBUploadOutcomes(_ sender: Any?) {
        if let action = smbTabs[activeID]?.showUploadHistory { action(settings, view.window) }
        else { smbClosedUploadNotices[activeID]?.showHistory?(settings, view.window) }
    }
}
