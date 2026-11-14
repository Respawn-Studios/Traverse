import AppKit
import ExplorerCore
@_spi(ArchiveProduction) import FileOperations
@_spi(ArchiveProduction) @_spi(Qualification) import LocalStorage
import UniformTypeIdentifiers

/// Internal pane delivery and external receivers have distinct acceptance.
/// Neither enables the separately held distribution publication policy.
enum SFTPFilePromiseFeature {
    static let externalEnabled = false
    #if DEBUG
    @MainActor static var qualifying = false
    @MainActor static var externalForVerification: Bool?
    @MainActor static var requiresParentGrantForVerification = false
    #endif
    @MainActor static var available: Bool { internalAvailable || externalAvailable }
    @MainActor static var internalAvailable: Bool {
        guard RemoteDownloadPublicationFeature.singleFileAvailable && SFTPDownloadFeature.available else { return false }
        if RemoteDownloadPublicationFeature.qualifiesPublicQuarantineDownload { return true }
        #if DEBUG
        if qualifying { return true }
        #endif
        return AppFeatureAvailability.allows(.serverDownloads)
    }
    @MainActor static var externalAvailable: Bool {
        guard RemoteDownloadPublicationFeature.available && SFTPDownloadFeature.available else { return false }
        #if DEBUG
        if qualifying { return externalForVerification == true }
        #endif
        return externalEnabled && AppFeatureAvailability.allows(.serverDownloads)
    }
}

/// A drag offer contains only the selected metadata observation. The body is
/// requested later, by the existing selected Download session owner.
struct SFTPFilePromiseCandidate: Sendable {
    let selection: SFTPDownloadSelection
    let name: String
    let fileType: String

    init?(_ selection: SFTPDownloadSelection) {
        guard let name = selection.proposedLocalName,
              Data(name.utf8) == selection.row.entry.name.wireUTF8 else { return nil }
        self.selection = selection; self.name = name
        let inferred = UTType(filenameExtension: (name as NSString).pathExtension)
        fileType = inferred?.conforms(to: .data) == true ? inferred!.identifier : UTType.data.identifier
    }
    func matches(_ current: SFTPDownloadSelection?) -> Bool {
        current?.generation == selection.generation && current?.row == selection.row
    }
    /// AppKit may choose a collision-free leaf. It supplies a URL, not a scope
    /// grant or overwrite permission; the engine repeats both namespace checks.
    func destinationName(at url: URL) -> String? {
        let name = url.lastPathComponent
        guard url.isFileURL, url.baseURL == nil, url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/"),
              url.path.utf8.count <= 8_192, url.standardizedFileURL.path.utf8.elementsEqual(url.path.utf8),
              !name.isEmpty, name != ".", name != "..", !name.contains(":"),
              let safe = try? SFTPRemoteName(Data(name.utf8)), safe.isSafeForSingleLineEntry,
              safe.wireUTF8.count <= 255 else { return nil }
        return name
    }
}

@MainActor final class ApplicationSFTPFilePromises {
    static let shared = ApplicationSFTPFilePromises()
    private var jobs: [UUID: SFTPFilePromiseExport] = [:]
    private var closing = false
    var canOffer: Bool { !closing && jobs.count < 8 }
    func retain(_ job: SFTPFilePromiseExport) -> Bool {
        guard canOffer, jobs[job.id] == nil else { return false }
        jobs[job.id] = job; return true
    }
    func release(_ job: SFTPFilePromiseExport) { if jobs[job.id] === job { jobs[job.id] = nil } }
    /// Called before SFTPBrowserLifetimes closes connections at normal Quit.
    /// An uncooperative file presenter defers Quit with the job still retained.
    func closeAndDrain(maximumWait: Duration = .seconds(2)) async -> Bool {
        closing = true
        defer { closing = false }
        Array(jobs.values).forEach { $0.stop() }
        let deadline = ContinuousClock.now.advanced(by: maximumWait)
        while !jobs.isEmpty {
            if Task.isCancelled || ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
    #if DEBUG
    var countForVerification: Int { jobs.count }
    #endif
}

/// The provider retains its delegate; the delegate retains the job. The job
/// has only a weak provider reference, so a receiver can outlive the source tab.
final class SFTPFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let name: String, job: SFTPFilePromiseExport, queue: OperationQueue
    private let dispatch: ArchivePromiseDispatch
    private let lock = NSLock()
    private var requested = false
    @MainActor init(name: String, job: SFTPFilePromiseExport, queue: OperationQueue) {
        self.name = name; self.job = job; self.queue = queue; dispatch = job.callbackDispatch
    }
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType type: String) -> String { name }
    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void) {
        let completion = ArchivePromiseCompletion(completionHandler)
        guard lock.withLock({ if requested { return false }; requested = true; return true }) else {
            completion.finish(CocoaError(.fileWriteUnknown)); return
        }
        guard dispatch.begin() else { completion.finish(CocoaError(.userCancelled)); return }
        Task { @MainActor [job, url, completion, dispatch] in
            guard SFTPFilePromiseFeature.externalAvailable else {
                completion.finish(CocoaError(.fileWriteUnknown))
                dispatch.finish(); job.callbackDidDispatch(); return
            }
            job.request(url: url, completion: completion)
            dispatch.finish(); job.callbackDidDispatch()
        }
    }
}

/// AppKit owns the native file-promise flavors. This extra type only lets a
/// Traverse destination negotiate an in-process drag; its value is never used
/// as authority to receive a file.
@MainActor final class SFTPFilePromiseProvider: NSFilePromiseProvider {
    private let marker: String
    init(type: String, delegate: SFTPFilePromiseDelegate, marker: UUID) {
        self.marker = marker.uuidString
        super.init()
        fileType = type; self.delegate = delegate; userInfo = delegate
    }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [RemoteDownloadDrag.pasteboardType]
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == RemoteDownloadDrag.pasteboardType ? marker : super.pasteboardPropertyList(forType: type)
    }
}

/// A single offer and one callback. Selection/route/access are checked again
/// at consumption; no network body or destination mutation starts in writer().
@MainActor final class SFTPFilePromiseExport {
    let id = UUID(), candidate: SFTPFilePromiseCandidate
    let callbackDispatch = ArchivePromiseDispatch()
    private weak var browser: BrowserViewController?, owner: SFTPTabController?
    private weak var offeredProvider: NSFilePromiseProvider?
    private var providerWasOffered = false
    private let engine: RecoverableFileOperations, storage: SFTPDownloadStorage
    private let tab: UUID, visit: UUID
    private let queue = OperationQueue()
    private let chooser = FolderAccessController(stateDirectory: nil)
    private var destinationAccess: FileAccessLifetimes?
    private var internalDestination: (value: ArchiveExtractionDestination, current: @MainActor () -> Bool)?
    private var handed = false, retired = false, stopped = false, requested = false
    private var work: Task<Void, Never>?, expiry: Task<Void, Never>?
    #if DEBUG
    var receivedForVerification: (() async throws -> Void)?
    var settledForVerification: ((UUID?) -> Void)?
    private(set) var externalCallbackURLForVerification: URL?
    private(set) var parentChoicesForVerification = 0
    #endif

    init(candidate: SFTPFilePromiseCandidate, browser: BrowserViewController, owner: SFTPTabController,
         engine: RecoverableFileOperations, storage: SFTPDownloadStorage) {
        self.candidate = candidate; self.browser = browser; self.owner = owner
        self.engine = engine; self.storage = storage; tab = browser.activeID; visit = browser.sessionID
        queue.maxConcurrentOperationCount = 1; queue.name = "Traverse.SFTPFilePromise"
    }
    var canHandOff: Bool { !handed && !retired && ApplicationSFTPFilePromises.shared.canOffer }
    var canReceiveInternal: Bool { handed && !retired && !stopped && !requested && current() }
    var hasPreparedWriter: Bool { providerWasOffered }
    func writer() -> NSFilePromiseProvider? {
        guard canHandOff else { return nil }
        if let offeredProvider { providerWasOffered = true; return offeredProvider }
        let delegate = SFTPFilePromiseDelegate(name: candidate.name, job: self, queue: queue)
        let provider = SFTPFilePromiseProvider(type: candidate.fileType, delegate: delegate, marker: id)
        offeredProvider = provider; providerWasOffered = true
        return provider
    }
    @discardableResult func handOff() -> Bool {
        guard canHandOff, current(), ApplicationSFTPFilePromises.shared.retain(self) else { retireUncalled(); return false }
        handed = true
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            self?.retireUncalled()
        }
        return true
    }
    func retireUnlessHanded() { if !handed { retireUncalled() } }
    func retireUncalled() {
        guard !requested else { return }
        retired = true; callbackDispatch.close(); releaseIfDone()
    }
    func stop() {
        retired = true; stopped = true; callbackDispatch.close(); chooser.invalidatePendingRequests()
        work?.cancel(); releaseIfDone()
    }
    func drain() async {
        await callbackDispatch.drain()
        if let work { await work.value }
    }
    func callbackDidDispatch() { releaseIfDone() }
    private func releaseIfDone() {
        guard work == nil, callbackDispatch.isIdle, retired || requested else { return }
        expiry?.cancel(); expiry = nil; destinationAccess = nil
        ApplicationSFTPFilePromises.shared.release(self)
    }
    private func current() -> Bool {
        guard let browser, let owner else { return false }
        return !browser.isBrowserSuspended && browser.activeID == tab && browser.sessionID == visit
            && browser.sftpTabs[tab] === owner && !owner.isClosing && owner.session.latest.failure == nil
            && candidate.matches(owner.rows.selectedDownload) && browser.recoverableFileOperations === engine
            && !ApplicationFileActivity.gate.isClosed
    }
    /// Internal drops keep the same sealed receiver job and publication path.
    /// The receiving browser supplies its captured directory identity and live
    /// access; a pasteboard string cannot choose a destination or a source.
    @discardableResult func requestInternal(to destination: ArchiveExtractionDestination,
        current destinationIsCurrent: @escaping @MainActor () -> Bool) -> Bool {
        guard SFTPFilePromiseFeature.internalAvailable, canReceiveInternal, destination.matchesObservedDirectory,
              destinationIsCurrent() else { return false }
        let url = destination.directory.appendingPathComponent(candidate.name)
        guard candidate.destinationName(at: url) != nil else { return false }
        internalDestination = (destination, destinationIsCurrent)
        request(url: url, completion: ArchivePromiseCompletion { _ in })
        return requested
    }
    func request(url: URL, completion: ArchivePromiseCompletion) {
        if stopped { completion.finish(CocoaError(.userCancelled)); return }
        // The native callback may be invoked directly, independently of the
        // source mask. Refusing it must not consume this drag's internal offer.
        guard internalDestination != nil || SFTPFilePromiseFeature.externalAvailable else {
            completion.finish(CocoaError(.fileWriteUnknown)); return
        }
        guard handed, !retired, !requested, current(), candidate.destinationName(at: url) != nil else {
            completion.finish(CocoaError(.fileWriteUnknown)); retireUncalled(); return
        }
        #if DEBUG
        if internalDestination == nil { externalCallbackURLForVerification = url }
        #endif
        requested = true; expiry?.cancel(); expiry = nil
        work = Task { [self] in await run(url: url, completion: completion) }
    }
    private func acquireParent(_ requested: URL, browser: BrowserViewController) async throws -> (URL, FolderAccessChoice?) {
        var access = await browser.accessLifetime(for: [requested])
        try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
        var parent = requested
        var selected: FolderAccessChoice?
        #if DEBUG
        let requiresSelection = FolderAccessController.requiresAnalysisSelection
            || (SFTPFilePromiseFeature.qualifying && SFTPFilePromiseFeature.requiresParentGrantForVerification)
        #else
        let requiresSelection = FolderAccessController.requiresAnalysisSelection
        #endif
        if access.leases.isEmpty && requiresSelection {
            guard let window = browser.view.window, window.attachedSheet == nil,
                  let choice = await chooser.chooseFolder(in: window, initialDirectory: requested, purpose: .fileOperation) else {
                throw FileOperationFailure.accessDenied
            }
            #if DEBUG
            parentChoicesForVerification += 1
            #endif
            guard Data(choice.selection.url.standardizedFileURL.path.utf8) == Data(requested.standardizedFileURL.path.utf8) else {
                throw FileOperationFailure.destinationChanged
            }
            parent = choice.selection.url; access = .init(leases: [choice.lease])
            selected = choice
        }
        try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
        destinationAccess = access
        return (parent, selected)
    }
    private func run(url: URL, completion: ArchivePromiseCompletion) async {
        let diagnostic = RemoteTransferDiagnostics(.download)
        var received: SFTPReceivedDownload?, presented = false, downloaded = false
        #if DEBUG
        var confirmedRecord: UUID?
        #endif
        let capturedDestination = internalDestination
        defer {
            if presented { browser?.finishOperationPresentation() }
            internalDestination = nil; destinationAccess = nil; work = nil; releaseIfDone()
            diagnostic.finish(.cancelled)
            #if DEBUG
            settledForVerification?(confirmedRecord)
            #endif
        }
        do {
            try Task.checkCancellation()
            guard capturedDestination != nil ? SFTPFilePromiseFeature.internalAvailable
                : SFTPFilePromiseFeature.externalAvailable else { throw SFTPBrowserFailure.unavailable }
            guard current(), let browser, let owner, let name = candidate.destinationName(at: url) else { throw SFTPBrowserFailure.stale }
            let requestedParent = url.deletingLastPathComponent()
            diagnostic.stage(.access)
            let parent: URL
            var selectedParent: FolderAccessChoice?
            if let capturedDestination {
                guard capturedDestination.current(),
                      capturedDestination.value.directory.path.utf8.elementsEqual(requestedParent.path.utf8) else {
                    throw FileOperationFailure.destinationChanged
                }
                destinationAccess = capturedDestination.value.access
                parent = requestedParent
            } else {
                let acquired = try await acquireParent(requestedParent, browser: browser)
                parent = acquired.0; selectedParent = acquired.1
            }
            guard Data(parent.path.utf8) == Data(requestedParent.path.utf8),
                  Data(parent.appendingPathComponent(name).path.utf8) == Data(url.path.utf8) else {
                throw FileOperationFailure.destinationChanged
            }
            diagnostic.stage(.destination)
            let observation = try await engine.checkReceivedFileDestination(parent: parent, name: name,
                observing: capturedDestination?.value.observation)
            try Task.checkCancellation(); guard current(), browser.canRunExclusiveFileCommand else { throw SFTPBrowserFailure.stale }
            if let selectedParent {
                let retained = browser.folderAccess.acceptOpenedFolder(selectedParent.selection.url, retaining: selectedParent.lease)
                ApplicationDiagnostics.shared.event(.folderAccess, retained ? .completed : .partial,
                    trace: id, context: .init(.folderAccessPublication))
            }
            if let capturedDestination, !capturedDestination.current() { throw FileOperationFailure.destinationChanged }
            guard browser.startOperationPresentation("Receiving selected SFTP file…", diagnosticTrace: diagnostic.trace) else {
                throw SFTPBrowserFailure.busy
            }
            presented = true; browser.operationTask = work
            diagnostic.stage(.receive, count: 0)
            downloaded = true
            let copy = try await owner.session.download(candidate.selection, storage: storage, progress: nil)
            received = copy
            #if DEBUG
            if let receivedForVerification { try await receivedForVerification() }
            #endif
            try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
            diagnostic.stage(.prepareHistory)
            try await browser.operationCoordinator.prepareOperationState(for: engine)
            try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
            diagnostic.stage(.publish)
            // NSFilePromiseReceiver already coordinates this callback until
            // completion. Keep publication inside that lifetime without asking
            // a second coordinator to acquire its still-held destination.
            try Task.checkCancellation(); guard current() else { throw SFTPBrowserFailure.stale }
            let (outcome, removed) = try await RemoteReceivedFile.sftp(copy).publishSingleFile(using: engine,
                parent: parent, name: name, observing: observation,
                progress: browser.operationProgressSink, expectedDestination: url,
                revalidating: { guard current() else { throw SFTPBrowserFailure.stale } })
            received = nil
            diagnostic.publication(outcome.result, stagingRemoved: removed)
            browser.lastOperationResult = outcome.result; browser.lastRecoveryRecordID = outcome.recordID
            browser.lastRecoveryAction = nil; browser.lastTransferContinuation = nil; browser.continuationMoveClipboard = nil
            browser.operationResultsButton.isHidden = false; browser.inspectOperationRecovery()
            browser.operationCoordinator.reloadLocalDirectory(parent)
            let success = outcome.result.disposition == .succeeded && outcome.recordID != nil
            #if DEBUG
            if success { confirmedRecord = outcome.recordID }
            #endif
            let message = success
                ? "Downloaded “\(name)”. Remote file unchanged. Open Results for Undo and details."
                : "Download publication needs review. Open Results before trying again."
            if current() { owner.showTransferOutcome(message, needsAttention: !success || !removed, showsUploadHistory: false) }
            if success { diagnostic.finish(.completed, count: candidate.selection.logicalBytes); completion.finish(nil) }
            else { diagnostic.fail(FileOperationFailure.unavailable, stopped: false); completion.finish(CocoaError(.fileWriteUnknown)) }
        } catch {
            if received != nil { diagnostic.stage(.retain) }
            await received?.retainForReview()
            if downloaded, let owner, owner.session.latest.failure != nil || Task.isCancelled {
                diagnostic.stage(.drain); diagnostic.drained(await owner.close().value)
            }
            diagnostic.fail(error, stopped: Task.isCancelled)
            if current(), let owner {
                let message = !downloaded && error as? FileOperationFailure == .conflict
                    ? "That name already exists at the destination. The existing file was kept."
                    : "Download could not be delivered. Review Connection Activity and Results before trying again."
                owner.showTransferOutcome(message, needsAttention: true, showsUploadHistory: false)
            }
            completion.finish(ArchivePromiseExport.callbackFailure(error))
        }
    }
}
