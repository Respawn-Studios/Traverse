import AppKit
import FileOperations
import LocalStorage
import UniformTypeIdentifiers

enum ArchivePromiseExportFeature {
    static let enabled = true
    #if DEBUG
    @MainActor static var qualifying = false
    /// Ordinary browsing follows the qualified external-promise capability.
    /// Explicit generated checks can still exercise the frozen legacy path.
    @MainActor static var qualifyingPublications = false
    @MainActor static var publicFilePublication: Bool {
        qualifying ? qualifyingPublications : AppFeatureAvailability.allows(.archiveExternalPromises)
    }
    @MainActor static var publicTreePublication: Bool {
        qualifying ? qualifyingPublications : AppFeatureAvailability.allows(.archiveExternalPromises)
    }
    @MainActor static var requiresParentGrantForVerification = false
    @MainActor static var expectedParentForGestureVerification: URL?
    @MainActor static var available: Bool {
        AppFeatureAvailability.allows(.archiveExternalPromises) && (enabled || qualifying)
    }
    #elseif TRAVERSE_SFTP_EDITOR_QA
    static var publicFilePublication: Bool { GeneratedSandboxReview.archivePromiseAdmitted }
    static var publicTreePublication: Bool { GeneratedSandboxReview.archivePromiseAdmitted }
    static var available: Bool { GeneratedSandboxReview.archivePromiseAdmitted && enabled }
    #else
    static var publicFilePublication: Bool { AppFeatureAvailability.allows(.archiveExternalPromises) }
    static var publicTreePublication: Bool { AppFeatureAvailability.allows(.archiveExternalPromises) }
    static var available: Bool {
        AppFeatureAvailability.allows(.archiveExternalPromises) && enabled
    }
    #endif
}

/// Retains handed-off offers independently of archive windows. A provider may
/// never be consumed: only uncalled offers expire, never a running filesystem
/// worker. The existing operation coordinator still owns all actual mutations.
@MainActor final class ApplicationArchiveExports {
    static let shared = ApplicationArchiveExports()
    private var jobs: [UUID: ArchivePromiseExport] = [:]
    private var closing = false
    var canOffer: Bool { !closing && jobs.count < 8 }
    func retain(_ job: ArchivePromiseExport) -> Bool {
        guard canOffer, jobs[job.id] == nil else { return false }
        jobs[job.id] = job; return true
    }
    func release(_ job: ArchivePromiseExport) { if jobs[job.id] === job { jobs[job.id] = nil } }
    func closeAndDrain() async {
        closing = true
        let current = Array(jobs.values)
        current.forEach { $0.stop() }
        for job in current { await job.drain() }
        current.forEach { $0.retireUncalled() }
        closing = false
    }
    #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
    var countForVerification: Int { jobs.count }
    #endif
}

/// Exactly-once native completion, also safe for a replay rejected on AppKit's
/// callback queue. Never invokes client code while holding its lock.
final class ArchivePromiseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Error?) -> Void)?
    init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }
    func finish(_ error: Error?) {
        let callback = lock.withLock { let old = self.callback; self.callback = nil; return old }
        callback?(error)
    }
}

/// Accounts for callbacks before their MainActor admission Task can run. Normal
/// close/quit can seal and await this boundary instead of exiting between the
/// native callback and the registration of its actual filesystem owner.
final class ArchivePromiseDispatch: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0, closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isIdle: Bool { lock.withLock { pending == 0 } }
    func begin() -> Bool {
        lock.withLock {
            guard !closed, pending < 128 else { return false }
            pending += 1; return true
        }
    }
    func finish() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            precondition(pending > 0)
            pending -= 1
            guard pending == 0 else { return [] }
            let ready = waiters; waiters = []; return ready
        }
        ready.forEach { $0.resume() }
    }
    func close() { lock.withLock { closed = true } }
    func drain() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                if pending == 0 { return true }
                waiters.append(continuation); return false
            }
            if immediate { continuation.resume() }
        }
    }
}

/// A provider retains this delegate through userInfo. The job never retains the
/// provider, and a duplicate native callback cannot enqueue another Task/write.
final class ArchivePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let name: String
    private let index: Int, job: ArchivePromiseExport, queue: OperationQueue, dispatch: ArchivePromiseDispatch
    private let lock = NSLock()
    private var requested = false
    @MainActor init(index: Int, name: String, job: ArchivePromiseExport, queue: OperationQueue) {
        self.index = index; self.name = name; self.job = job; self.queue = queue
        dispatch = job.callbackDispatch
    }
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType type: String) -> String { name }
    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void) {
        let completion = ArchivePromiseCompletion(completionHandler)
        guard lock.withLock({ if requested { return false }; requested = true; return true }) else {
            completion.finish(CocoaError(.fileWriteUnknown)); return
        }
        guard dispatch.begin() else { completion.finish(CocoaError(.fileWriteUnknown)); return }
        Task { @MainActor [job, index, url, completion, dispatch] in
            job.request(index, url: url, completion: completion)
            dispatch.finish(); job.callbackDidDispatch()
        }
    }
}

/// Public native promise flavors are supplied by AppKit. Only Traverse's own
/// opaque marker is added; do not hand-construct Apple's private pasteboard data.
@MainActor final class ArchiveFilePromiseProvider: NSFilePromiseProvider {
    private let marker: String
    init(type: String, delegate: ArchivePromiseDelegate, marker: UUID) {
        self.marker = marker.uuidString
        // AppKit's fileType initializer is a convenience initializer which
        // dynamically calls init(). Use the designated superclass initializer
        // for this subclass, then configure its documented writable properties.
        super.init()
        fileType = type; self.delegate = delegate
        userInfo = delegate
    }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [ArchiveMemberDragSource.pasteboardType]
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == ArchiveMemberDragSource.pasteboardType ? marker : super.pasteboardPropertyList(forType: type)
    }
}

/// One concrete selected-ZIP handoff. Selection preparation is metadata-only;
/// payload production begins solely after an actual promise write request.
@MainActor final class ArchivePromiseExport {
    let id = UUID()
    let roots: [ZIPRootExportSelection], names: [String]
    let callbackDispatch = ArchivePromiseDispatch()
    private(set) var handed = false
    private var state: ZIPExportBatchState
    private var sourceAccess: FileAccessLifetimes?
    private var destinationAccess: FileAccessLifetimes?
    private let browser: BrowserViewController, engine: RecoverableFileOperations
    private let publicFilePublication: Bool, publicTreePublication: Bool
    private weak var archiveWindow: NSWindow?
    private let notice: @MainActor (String) -> Void
    private let chooser = FolderAccessController(stateDirectory: nil)
    private let queue: OperationQueue
    private struct Request { let url: URL; let completion: ArchivePromiseCompletion }
    private var requests: [Int: Request] = [:]
    private var parent: URL?, parentObservation: FileOperationSelection?
    private var parentKey: Data?
    private var work: Task<Void, Never>?, expiry: Task<Void, Never>?
    private var latestRecord: UUID?
    private var retired = false
    #if DEBUG
    var beforeRootForVerification: ((Int) async -> Void)?
    var chooseParentForVerification: ((URL) async -> FolderAccessChoice?)?
    var onSettledForVerification: (@MainActor () -> Void)?
    #endif
    #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
    private(set) var outcomesForVerification: [RecoverableOperationResult] = []
    private(set) var parentChoicesForVerification = 0
    var drainedForVerification: Bool { work == nil && state.isDrained && requests.isEmpty && callbackDispatch.isIdle }
    var terminalForVerification: Bool { state.isTerminal && sourceAccess == nil && destinationAccess == nil }
    var completedForVerification: Int { state.completedCount }
    #endif

    init(roots: [ZIPRootExportSelection], sourceAccess: FileAccessLifetimes,
        browser: BrowserViewController, window: NSWindow?, notice: @escaping @MainActor (String) -> Void) throws {
        guard let engine = browser.recoverableFileOperations else { throw FileOperationFailure.unavailable }
        self.roots = roots; names = try ZIPRootExportNames.offered(roots); state = try .init(count: roots.count)
        self.sourceAccess = sourceAccess; self.browser = browser; self.engine = engine
        // An offer keeps its admitted producer choices through asynchronous
        // callbacks; direct extraction switches cannot change an active offer.
        publicFilePublication = ArchivePromiseExportFeature.publicFilePublication
        publicTreePublication = ArchivePromiseExportFeature.publicTreePublication
        archiveWindow = window; self.notice = notice
        queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.name = "Traverse.ZIPPromiseRequests"
    }
    var canHandOff: Bool { !handed && !retired && ApplicationArchiveExports.shared.canOffer }
    var isTerminal: Bool { state.isTerminal && work == nil && callbackDispatch.isIdle && sourceAccess == nil }
    func provider(for item: ZIPArchiveItem, marker: UUID) -> NSFilePromiseProvider? {
        guard canHandOff, let index = roots.firstIndex(where: { $0.archivePath.utf8.elementsEqual(item.path.utf8) }) else { return nil }
        let inferred = UTType(filenameExtension: (names[index] as NSString).pathExtension)
        let type = roots[index].kind == .directory ? UTType.folder : (inferred?.conforms(to: .data) == true ? inferred! : .data)
        let delegate = ArchivePromiseDelegate(index: index, name: names[index], job: self, queue: queue)
        return ArchiveFilePromiseProvider(type: type.identifier, delegate: delegate, marker: marker)
    }
    @discardableResult func handOff(diagnosticTrace: UUID? = nil) -> Bool {
        guard canHandOff, ApplicationArchiveExports.shared.retain(self) else { retireUncalled(); return false }
        handed = true
        ApplicationDiagnostics.shared.event(.archiveExtract, .requested, trace: id, count: UInt64(roots.count),
            context: .init(.dragSession, flags: [.sourceObserved]), relatedTrace: diagnosticTrace)
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            self?.retireUncalled()
        }
        return true
    }
    func retireUnlessHanded() { if !handed { retireUncalled() } }
    func retireUncalled() {
        retired = true; callbackDispatch.close(); state.retireUnrequested(); releaseIfTerminal(); notifySettledForVerification()
    }
    func stop() {
        retired = true
        callbackDispatch.close()
        failPending(state.stop(), error: CocoaError(.userCancelled))
        chooser.invalidatePendingRequests(); work?.cancel(); releaseIfTerminal(); notifySettledForVerification()
    }
    func drain() async {
        await callbackDispatch.drain()
        if let work { await work.value }
    }
    func callbackDidDispatch() { releaseIfTerminal(); notifySettledForVerification() }

    func request(_ index: Int, url: URL, completion: ArchivePromiseCompletion) {
        guard handed, !retired, state.entry(index) == .offered else {
            completion.finish(CocoaError(.fileWriteUnknown)); return
        }
        guard url.isFileURL, url.baseURL == nil,
              url.path.utf8.count <= 8_192, url.lastPathComponent.utf8.count <= 255,
              !url.lastPathComponent.isEmpty, url.lastPathComponent != ".", url.lastPathComponent != "..",
              !url.lastPathComponent.contains("\0"), url.query == nil, url.fragment == nil,
              url.standardizedFileURL.path.utf8.elementsEqual(url.path.utf8) else {
            completion.finish(CocoaError(.fileWriteUnknown))
            failPending(state.stop(), error: CocoaError(.fileWriteUnknown)); releaseIfTerminal(); return
        }
        #if DEBUG
        if let expected = ArchivePromiseExportFeature.expectedParentForGestureVerification,
           !url.deletingLastPathComponent().standardizedFileURL.path.utf8.elementsEqual(expected.standardizedFileURL.path.utf8) {
            completion.finish(CocoaError(.fileWriteUnknown))
            failPending(state.stop(), error: CocoaError(.fileWriteUnknown)); releaseIfTerminal(); return
        }
        #endif
        #if TRAVERSE_SFTP_EDITOR_QA
        if GeneratedSandboxReview.archivePromiseAdmitted {
            guard let expected = GeneratedSandboxReview.reviewFixtureRoot?.appendingPathComponent("source/Destination", isDirectory: true),
                  url.deletingLastPathComponent().path.utf8.elementsEqual(expected.path.utf8) else {
                completion.finish(CocoaError(.fileWriteUnknown))
                failPending(state.stop(), error: CocoaError(.fileWriteUnknown)); releaseIfTerminal(); return
            }
        }
        #endif
        guard state.request(index) else { completion.finish(CocoaError(.fileWriteUnknown)); return }
        let key = Data(url.deletingLastPathComponent().path.utf8)
        guard parentKey == nil || parentKey == key else {
            // The newly queued request still gets its own terminal callback.
            requests[index] = .init(url: url, completion: completion)
            failPending(state.stop(), error: CocoaError(.fileWriteUnknown)); releaseIfTerminal(); return
        }
        parentKey = key; requests[index] = .init(url: url, completion: completion)
        if work == nil { start() }
    }
    private func start() {
        guard !browser.isBrowserSuspended, browser.operationTask == nil,
              !ApplicationFileActivity.gate.isClosed, browser.recoverableFileOperations === engine,
              browser.startOperationPresentation("Exporting selected archive items…", diagnosticTrace: id) else {
            failPending(state.stop(), error: CocoaError(.fileWriteUnknown)); releaseIfTerminal(); return
        }
        let task = Task { [self] in await run() }
        work = task; browser.operationTask = task
    }
    private func run() async {
        defer {
            work = nil; browser.finishOperationPresentation()
            destinationAccess = nil
            // The identity observation survives an idle gap; a delayed root
            // reacquires actual access before comparing that observation.
            releaseIfTerminal()
            notifySettledForVerification()
        }
        while let index = state.next() {
            guard let request = requests[index] else {
                failPending(state.stop(), error: CocoaError(.fileWriteUnknown)); break
            }
            let trace = ApplicationDiagnostics.shared.begin(.archiveExtract)
            let diagnostics = ApplicationDiagnostics.shared
            diagnostics.event(.archiveExtract, .admitted, trace: trace, count: UInt64(index + 1), relatedTrace: id)
            let binding = diagnostics.operationBinding(trace: trace), progress = browser.operationProgressSink
            do {
                try Task.checkCancellation()
                diagnostics.event(.archiveExtract, .preparing, trace: trace, context: .init(.queueStatePreparation))
                try await browser.operationCoordinator.prepareOperationState(for: engine)
                try Task.checkCancellation()
                diagnostics.event(.archiveExtract, .resolving, trace: trace, context: .init(.folderScope))
                try await acquireParent(for: request.url)
                diagnostics.event(.archiveExtract, .admitted, trace: trace, context: .init(.queueDestination, flags: [.destinationObserved]))
                #if DEBUG
                if let beforeRootForVerification { await beforeRootForVerification(index) }
                #endif
                try Task.checkCancellation()
                guard !state.stopped, let parent, let parentObservation else { throw CancellationError() }
                browser.operationProgressState = OperationProgressState()
                let callbackURL = request.url
                // AppKit coordinates the actual promise callback through its
                // completion. A second coordinator here can wait on that same
                // claim forever. The engine still rechecks the granted parent
                // and publishes only the exact receiver-supplied absent leaf.
                try Task.checkCancellation()
                guard !state.stopped else { throw CancellationError() }
                let plan = try await ZIPRootExtractionPreparation.prepare(roots[index], engine: engine, parent: parent,
                    name: callbackURL.lastPathComponent, observing: parentObservation,
                    publicFile: publicFilePublication, publicTree: publicTreePublication)
                guard plan.destination.path.utf8.elementsEqual(callbackURL.path.utf8) else {
                    throw FileOperationFailure.destinationChanged
                }
                try Task.checkCancellation()
                let result = await engine.performZIPRootExport(plan, progress: { binding.receive($0.jobID); progress?($0) })
                #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
                outcomesForVerification.append(result)
                #endif
                let succeeded = result.result.disposition == .succeeded && result.recordID != nil
                let failure = result.result.items.compactMap { item -> FileOperationFailure? in
                    if case let .failed(value) = item.status { return value }; return nil
                }.first
                if let record = result.recordID { latestRecord = record; publish(result) }
                let discarded = try state.finish(index, succeeded: succeeded)
                requests[index] = nil
                request.completion.finish(succeeded ? nil : Self.callbackFailure(result.result.disposition == .cancelled ? CancellationError() : failure ?? FileOperationFailure.unavailable))
                failPending(discarded, error: CocoaError(.fileWriteUnknown))
                let phase: DiagnosticPhase = succeeded ? .completed : result.result.disposition == .cancelled ? .cancelled : state.completedCount > 0 ? .partial : .failed
                diagnostics.event(.archiveExtract, phase, trace: trace, count: UInt64(state.completedCount),
                    error: failure.map { DiagnosticErrors.operation($0) })
                if Task.isCancelled { failPending(state.stop(), error: CocoaError(.userCancelled)) }
                notice(summary(failed: !succeeded || state.stopped))
            } catch {
                let discarded = (try? state.finish(index, succeeded: false)) ?? state.stop()
                requests[index] = nil
                request.completion.finish(Self.callbackFailure(error))
                failPending(discarded, error: CocoaError(.userCancelled))
                ApplicationDiagnostics.shared.event(.archiveExtract, error is CancellationError ? .cancelled : .failed,
                    trace: trace, error: DiagnosticErrors.project(error))
                notice(summary(failed: true))
            }
        }
        if latestRecord != nil { browser.inspectOperationRecovery() }
    }
    /// Construct only a closed Cocoa error, never carry private userInfo or the
    /// original source/destination into the receiving app's failure callback.
    static func callbackFailure(_ error: Error) -> CocoaError {
        if error is CancellationError || (error as? CocoaError)?.code == .userCancelled { return CocoaError(.userCancelled) }
        switch error as? FileOperationFailure {
        case .accessDenied: return CocoaError(.fileWriteNoPermission)
        case .outOfSpace, .quotaExceeded: return CocoaError(.fileWriteOutOfSpace)
        case .conflict: return CocoaError(.fileWriteFileExists)
        case .notFound: return CocoaError(.fileNoSuchFile)
        default: return CocoaError(.fileWriteUnknown)
        }
    }
    private func acquireParent(for leaf: URL) async throws {
        let requested = leaf.deletingLastPathComponent()
        guard parentKey == Data(requested.path.utf8) else { throw FileOperationFailure.destinationChanged }
        var selectedParent: FolderAccessChoice?
        if destinationAccess == nil {
            var access = await browser.accessLifetime(for: [requested])
            if access.leases.isEmpty, let lease = await chooser.acquireAccess(to: requested) {
                access = .init(leases: [lease])
            }
            try Task.checkCancellation()
            var chosen = requested
            #if DEBUG
            let requiresSelection = FolderAccessController.requiresAnalysisSelection
                || (ArchivePromiseExportFeature.qualifying && ArchivePromiseExportFeature.requiresParentGrantForVerification)
            #else
            let requiresSelection = FolderAccessController.requiresAnalysisSelection
            #endif
            if requiresSelection && access.leases.isEmpty {
                guard let window = (archiveWindow?.isVisible == true ? archiveWindow : browser.view.window), window.attachedSheet == nil else {
                    throw FileOperationFailure.accessDenied
                }
                let choice: FolderAccessChoice?
                #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
                parentChoicesForVerification += 1
                #endif
                #if DEBUG
                if let chooseParentForVerification { choice = await chooseParentForVerification(requested) }
                else { choice = await chooser.chooseFolder(in: window, initialDirectory: requested, purpose: .archiveExport) }
                #else
                choice = await chooser.chooseFolder(in: window, initialDirectory: requested, purpose: .archiveExport)
                #endif
                try Task.checkCancellation()
                guard let choice, Data(choice.selection.url.standardizedFileURL.path.utf8) == parentKey else { throw CocoaError(.userCancelled) }
                chosen = choice.selection.url; access = .init(leases: [choice.lease])
                selectedParent = choice
            }
            // The scope-bearing chosen URL is retained; never rebuild it from
            // a display string or mistake the callback leaf for a parent grant.
            parent = chosen; destinationAccess = access
        }
        guard let parent else { throw FileOperationFailure.accessDenied }
        parentObservation = try await engine.checkReceivedFileDestination(parent: parent, name: leaf.lastPathComponent,
            observing: parentObservation)
        try Task.checkCancellation()
        if let selectedParent {
            // Keep the actual chosen URL for later drops in this browser
            // session. This job still owns its lease through worker drain;
            // another drop must acquire a fresh lease and recheck its target.
            let retained = browser.folderAccess.acceptOpenedFolder(selectedParent.selection.url, retaining: selectedParent.lease)
            ApplicationDiagnostics.shared.event(.folderAccess, retained ? .completed : .partial,
                trace: id, context: .init(.folderAccessPublication))
        }
    }
    private func failPending(_ indices: [Int], error: Error) {
        for index in indices { requests.removeValue(forKey: index)?.completion.finish(error) }
    }
    private func releaseIfTerminal() {
        guard state.isTerminal, work == nil else { return }
        callbackDispatch.close()
        guard callbackDispatch.isIdle else { return }
        sourceAccess = nil; destinationAccess = nil; expiry?.cancel(); expiry = nil
        ApplicationArchiveExports.shared.release(self)
    }
    private func notifySettledForVerification() {
        #if DEBUG
        if drainedForVerification && state.isTerminal { onSettledForVerification?() }
        #endif
    }
    private func summary(failed: Bool) -> String {
        let count = state.completedCount
        let text = failed ? "Export stopped after \(count) of \(roots.count) items. Completed exports remain; inspect Results for any retained work."
            : count == roots.count ? "Exported \(count) item\(count == 1 ? "" : "s"). The archive is unchanged."
            : "Exported \(count) of \(roots.count) items requested by the receiving app. The archive is unchanged."
        browser.status.stringValue = text; return text
    }
    private func publish(_ result: RecoverableOperationResult) {
        browser.lastOperationResult = result.result; browser.lastRecoveryRecordID = result.recordID
        browser.lastRecoveryAction = nil; browser.lastTransferContinuation = nil; browser.continuationMoveClipboard = nil
        browser.operationResultsButton.isHidden = false
        for current in browser.operationCoordinator.liveBrowsers where !current.isBrowserSuspended && current.location.directoryURL?.path == parent?.path {
            current.loadLocation()
        }
    }
}
