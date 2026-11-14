import Darwin
import ExplorerCore
import FileOperations
import Foundation

@_spi(Qualification) public enum SMBBrowserFailure: String, Error, Sendable {
    case invalidInput, invalidOutput, busy, stopped, unavailable, authentication, denied, security, storage, quota, deadline, containment, remote, preflightRefused
}
@_spi(Qualification) public struct SMBBrowserUpdate: Sendable {
    public let security: SMBWorkerSecurity?
    public let snapshot: SMBDirectorySnapshot?
    public let idle: Bool
    public let failure: SMBBrowserFailure?
    public let directoryRejection: SMBDirectoryRejection?
    public let folderUploadDiagnostic: SMBFolderUploadDiagnostic?
    init(security: SMBWorkerSecurity?, snapshot: SMBDirectorySnapshot?, idle: Bool, failure: SMBBrowserFailure?,
         directoryRejection: SMBDirectoryRejection? = nil, folderUploadDiagnostic: SMBFolderUploadDiagnostic? = nil) {
        self.security = security; self.snapshot = snapshot; self.idle = idle; self.failure = failure
        self.directoryRejection = directoryRejection; self.folderUploadDiagnostic = folderUploadDiagnostic
    }
}
@_spi(Qualification) public struct SMBBrowserDrainResult: Sendable {
    public let actualExit: Bool
    public let pipeDrained: Bool
    public let socketAndCatalogDrained: Bool
    public let forcedContainment: Bool
    public let ownerReleased: Bool
    /// Nil for preserved generated evidence; false retains an incomplete runtime catalog.
    public let temporaryCatalogRemoved: Bool?
    /// Darwin's actual child high-water RSS, available after this owner reaps it.
    public let peakResidentBytes: UInt64?
}

/// Signed-parent qualification of the real multi-read interface. Its only
/// entry point still admits the approved generated loopback server. Ordinary
/// connection settings, runtime-pool disposal and activation have separate gates.
@_spi(Qualification) public final class SMBBrowserSession: Sendable {
    let owner: SMBBrowserOwner
    public let id: UUID
    public let updates: AsyncStream<SMBBrowserUpdate>
    private let exposedSelectedDownloads: Bool
    private let exposedTextReads: Bool
    private let exposedInPlaceTextEdits: Bool
    private let exposedFolderDownloads: Bool
    private let exposedSelectedUploads: Bool
    private let exposedFolderUploads: Bool
    private let exposedSelectedActions: Bool
    public var latest: SMBBrowserUpdate { owner.latest }
    public var commandCounts: [UInt64]? { owner.commandCounts }
    /// Fixed action boundary only; 1...6 are worker Move/Copy commit checks,
    /// 7 means actionComplete arrived, 8 means its local journal confirmed.
    public func actionDiagnosticCheckpoint(for request: UUID) -> UInt8? { owner.actionDiagnosticCheckpoint(for: request) }
    /// Save boundary entered: 3 write, 4 EOF, 5 flush, 6 first metadata,
    /// 7 digest, 8 second metadata, 9 close, 10 reopen, 11 final readback,
    /// 12 policy finish, 13 worker completion, 14 verified journal commit.
    /// First postwrite detail: 15 Basic query, 16 Standard, 17 Internal,
    /// 18 Volume, 19 Basic layout, 20 Standard layout, 21 Internal layout,
    /// 22 Volume layout, 23 Standard flags, 24 Volume flags/label,
    /// 25 identity, 26 attributes, 27 links, 28 size, 29 eligibility.
    /// A checkpoint alone never proves the named step completed.
    public func editDiagnosticCheckpoint(for request: UUID) -> UInt8? { owner.editDiagnosticCheckpoint(for: request) }
    public var folderUploadDiagnostic: SMBFolderUploadDiagnostic? { owner.latest.folderUploadDiagnostic }
    public var actionPreflightCode: SMBActionPreflightCode? { owner.actionPreflightCode }
    public var allowsSelectedDownloads: Bool { exposedSelectedDownloads && owner.mode != .metadata }
    /// Private selected text reads do not expose received-file publication.
    public var allowsTextRead: Bool { exposedTextReads && owner.mode != .metadata }
    public var allowsInPlaceTextEdit: Bool {
        exposedInPlaceTextEdits && owner.mode == .selectedUpload
            && owner.request?.security == .encrypted
            && owner.request?.effectiveTransferPreference != .readOnly
    }
    public var allowsFolderDownloads: Bool { exposedFolderDownloads && owner.mode.allowsFolderDownload }
    public var allowsSelectedUploads: Bool { exposedSelectedUploads && owner.mode == .selectedUpload }
    public var allowsFolderUploads: Bool { exposedFolderUploads && owner.mode == .selectedUpload }
    public var allowsSelectedActions: Bool {
        exposedSelectedActions && owner.mode == .selectedUpload && owner.request?.effectiveTransferPreference != .readOnly
    }
    public var allowsFolderSizeSummary: Bool { owner.mode.allowsFolderSizeSummary }
    init(_ owner: SMBBrowserOwner, exposedSelectedDownloads: Bool, exposedFolderDownloads: Bool,
         exposedTextReads: Bool = false, exposedInPlaceTextEdits: Bool = false,
         exposedSelectedUploads: Bool = false, exposedFolderUploads: Bool = false,
         exposedSelectedActions: Bool = true) {
        self.owner = owner; id = owner.id; updates = owner.events.stream
        self.exposedSelectedDownloads = exposedSelectedDownloads
        self.exposedTextReads = exposedTextReads
        self.exposedInPlaceTextEdits = exposedInPlaceTextEdits
        self.exposedFolderDownloads = exposedFolderDownloads
        self.exposedSelectedUploads = exposedSelectedUploads
        self.exposedFolderUploads = exposedFolderUploads
        self.exposedSelectedActions = exposedSelectedActions
    }
    public static func connectGenerated(bundleURL: URL, generatedCase: URL, activity: FileActivityGate, password: SMBPassword,
        policy: SMBWorkerSecurityPolicy = .encrypted, share: SMBGeneratedShare = .standard) async throws -> SMBBrowserSession {
        let owner = try SMBBrowserOwner(bundle: bundleURL, root: generatedCase, activity: activity, password: password, policy: policy, share: share)
        return try await connect(owner, exposedSelectedDownloads: false, exposedFolderDownloads: false,
                                 exposedTextReads: false, exposedInPlaceTextEdits: false,
                                 exposedSelectedUploads: false, exposedFolderUploads: false,
                                 exposedSelectedActions: false)
    }
    /// Qualification entry point for real form/runtime integration. Ordinary UI
    /// activation stays gated until native setup, scale and packaging pass.
    public static func connectPrepared(bundleURL: URL, request: SMBServerDraft, endpoint: SMBPreparedConnection,
        storage: SMBTemporaryStorage, activity: FileActivityGate, password: SMBPassword, selectedDownloads: Bool = false, textReads: Bool = false,
        folderDownloads: Bool = false,
        freshUploads: Bool = false, folderUploads: Bool = false,
        inPlaceTextEdits: Bool = false) async throws -> SMBBrowserSession {
        try endpoint.validate(for: request)
        guard !inPlaceTextEdits || request.security == .encrypted
            && request.effectiveTransferPreference != .readOnly else { throw SMBBrowserFailure.unavailable }
        let owner = try SMBBrowserOwner(bundle: bundleURL, request: request, endpoint: endpoint, storage: storage, activity: activity,
            password: password, selectedDownloads: selectedDownloads, textReads: textReads || inPlaceTextEdits,
            folderDownloads: folderDownloads, freshUploads: freshUploads || folderUploads || inPlaceTextEdits)
        return try await connect(owner, exposedSelectedDownloads: selectedDownloads, exposedFolderDownloads: folderDownloads,
                                 exposedTextReads: textReads || inPlaceTextEdits, exposedInPlaceTextEdits: inPlaceTextEdits,
                                 exposedSelectedUploads: freshUploads, exposedFolderUploads: folderUploads,
                                 exposedSelectedActions: freshUploads || folderUploads)
    }
    private static func connect(_ owner: SMBBrowserOwner, exposedSelectedDownloads: Bool,
                                exposedFolderDownloads: Bool, exposedTextReads: Bool, exposedInPlaceTextEdits: Bool,
                                exposedSelectedUploads: Bool,
                                exposedFolderUploads: Bool, exposedSelectedActions: Bool) async throws -> SMBBrowserSession {
        try SMBBrowserAdmission.shared.admit(owner)
        let session = SMBBrowserSession(owner, exposedSelectedDownloads: exposedSelectedDownloads,
                                        exposedFolderDownloads: exposedFolderDownloads,
                                        exposedTextReads: exposedTextReads, exposedInPlaceTextEdits: exposedInPlaceTextEdits,
                                        exposedSelectedUploads: exposedSelectedUploads, exposedFolderUploads: exposedFolderUploads,
                                        exposedSelectedActions: exposedSelectedActions)
        try await withTaskCancellationHandler {
            if Task.isCancelled { owner.stop() }
            try await withCheckedThrowingContinuation { owner.start($0) }
        } onCancel: { owner.stop() }
        if Task.isCancelled { _ = await session.close(); throw SMBBrowserFailure.stopped }
        return session
    }
    /// Returns after the new generation is admitted. Prefix and final snapshots
    /// arrive independently; a large folder does not block its first native page.
    @discardableResult public func navigate(components: [SMBRemoteName]) async throws -> UUID {
        try await withTaskCancellationHandler {
            if Task.isCancelled { throw SMBBrowserFailure.stopped }
            return try await withCheckedThrowingContinuation { owner.navigate(components, continuation: $0) }
        } onCancel: { owner.cancelRead() }
    }
    public func find(_ query: RemoteDirectoryFindQuery) async throws -> SMBDirectoryFindResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { owner.find(query, continuation: $0) }
        } onCancel: { owner.cancelRead() }
    }
    /// Metadata-only, independent of binary Download/Upload exposure. A caller
    /// may discard the result, but the owner keeps the scan until cleanup ends.
    public func summarizeSelectedFolder(_ selection: SMBFolderSizeSelection) async throws -> RemoteFolderSizeSummary {
        guard allowsFolderSizeSummary else { throw RemoteFolderSizeFailure.unsupported }
        try Task.checkCancellation()
        let result = try await withCheckedThrowingContinuation { owner.summarizeSelectedFolder(selection, continuation: $0) }
        try Task.checkCancellation(); return result
    }
    public func page(offset: Int64, sort: SMBDirectorySort = .name, descending: Bool = false,
                     find: SMBDirectoryFindResult? = nil) async throws -> SMBDirectoryPage {
        try await withTaskCancellationHandler {
            if Task.isCancelled { throw SMBBrowserFailure.stopped }
            return try await withCheckedThrowingContinuation { owner.page(offset: offset, sort: sort, descending: descending, find: find, continuation: $0) }
        } onCancel: { owner.cancelRead() }
    }
    public func stopReading() { owner.cancelRead() }
    public func upload(_ request: SMBRequestedUpload, storage: SMBUploadStorage, excluding roots: [URL],
        progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> SMBCompletedUpload {
        guard allowsSelectedUploads, request.connection == id else { throw SMBUploadFailure.invalidInput }
        guard let server = owner.request, server.security == .encrypted,
              server.effectiveTransferPreference != .readOnly else { throw SMBUploadFailure.unavailable }
        let attempt = try await SMBUploadAttempt.prepare(request, server: server, storage: storage, excluding: roots, progress: progress)
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { owner.upload(attempt, continuation: $0) }
            } onCancel: { attempt.stop(); owner.cancelUpload(attempt) }
            return result
        } catch {
            if attempt.finished { throw error }
            attempt.stop()
            if attempt.admitted {
                let drained = await close()
                guard drained.ownerReleased else { throw SMBUploadFailure.reviewRequired }
            }
            do { try await attempt.finishAfterDrain(noRemoteMutation: !attempt.remoteMayHaveStarted) }
            catch { throw SMBUploadFailure.reviewRequired }
            throw error
        }
    }
    public func uploadFolder(_ request: SMBRequestedFolderUpload, storage: SMBUploadStorage, excluding roots: [URL],
        progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> SMBCompletedFolderUpload {
        guard allowsFolderUploads, request.connection == id else { throw SMBUploadFailure.invalidInput }
        guard let server = owner.request, server.security == .encrypted,
              server.effectiveTransferPreference != .readOnly else { throw SMBUploadFailure.unavailable }
        let attempt = try await SMBFolderUploadAttempt.prepare(request, server: server, storage: storage, excluding: roots, progress: progress)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { owner.uploadFolder(attempt, continuation: $0) }
            } onCancel: { attempt.stop(); owner.cancelFolderUpload(attempt) }
        } catch {
            if attempt.finished { throw error }
            attempt.stop()
            if attempt.admitted {
                let drained = await close()
                guard drained.ownerReleased else { throw SMBUploadFailure.reviewRequired }
            }
            do { try await attempt.finishAfterDrain(noRemoteMutation: !attempt.remoteMayHaveStarted) }
            catch { throw SMBUploadFailure.reviewRequired }
            throw error
        }
    }
    public func perform(_ request: SMBSelectedActionRequest, storage: SMBActionStorage,
                        progress: (@Sendable (UInt64, UInt64) -> Void)? = nil) async throws -> SMBCompletedAction {
        guard allowsSelectedActions, request.connection == id, let server = owner.request,
              server.security == .encrypted, server.effectiveTransferPreference != .readOnly,
              let object = request.observation.objectID, let parent = request.observation.parentID else {
            throw SMBActionFailure.unavailable
        }
        let record = SMBActionRecord(id: request.request, server: server.address, account: server.account, createdAt: Date(),
            directory: request.directory, source: request.observation.name, target: request.target,
            operation: request.operation, object: object, parent: parent, outcome: .prepared,
            destinationDirectory: request.destinationDirectory)
        try await storage.ledger.prepare(record)
        let attempt = SMBActionAttempt(request: request, record: record, ledger: storage.ledger, progress: progress)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { owner.action(attempt, continuation: $0) }
            } onCancel: { attempt.cancel(); owner.cancelAction(attempt) }
        } catch {
            if attempt.finished { throw error }
            attempt.cancel()
            if attempt.admitted {
                let drained = await close()
                guard drained.ownerReleased else { throw SMBActionFailure.reviewRequired }
            }
            do { try await storage.ledger.endAfterDrain(record.id, noMutation: !attempt.mutationRequested) }
            catch { throw SMBActionFailure.reviewRequired }
            if attempt.mutationRequested { throw SMBActionFailure.reviewRequired }
            if error as? SMBBrowserFailure == .preflightRefused, let code = owner.actionPreflightCode {
                throw SMBActionFailure.preflightRefused(code)
            }
            throw error
        }
    }
    public func download(_ selection: SMBDownloadSelection, storage: SMBDownloadStorage,
        progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> SMBReceivedDownload {
        guard allowsSelectedDownloads, selection.connection == id else { throw SMBBrowserFailure.invalidInput }
        let file: SMBDownloadedFile
        do { file = try await storage.reserveSelected(selection) }
        catch let issue as RemoteDownloadStorageFailure { throw SMBDownloadStorageIssue(issue) }
        let attempt = SMBDownloadAttempt(selection: selection, file: file, progress: progress)
        do {
            let receipt = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { owner.download(attempt, continuation: $0) }
            } onCancel: { attempt.cancel(); owner.cancelDownload(attempt) }
            try Task.checkCancellation(); _ = try await file.seal(receipt)
            return SMBReceivedDownload(file)
        } catch {
            if attempt.mayAbandon { _ = await file.abandon() }
            if let issue = error as? RemoteDownloadStorageFailure { throw SMBDownloadStorageIssue(issue) }
            throw error
        }
    }
    /// Explicit private Open/View only. The checked worker receipt and sealed
    /// body stay in the shared pool; no received Download object escapes.
    public func openText(selected selection: SMBDownloadSelection, storage: SMBTextReadStorage) async throws -> SMBTextReadLease {
        try await openText(selected: selection, storage: storage, retainingEditSource: false)
    }
    private func openText(selected selection: SMBDownloadSelection, storage: SMBTextReadStorage,
                          retainingEditSource: Bool) async throws -> SMBTextReadLease {
        guard allowsTextRead else { throw SMBBrowserFailure.unavailable }
        if retainingEditSource { guard allowsInPlaceTextEdit else { throw SMBTextFailure.unavailable } }
        guard selection.connection == id else { throw SMBBrowserFailure.invalidInput }
        guard selection.logicalBytes <= UInt64(TextDocumentValue.maximumBytes) else { throw SMBTextFailure.unsupported }
        let current = latest
        guard current.snapshot == selection.snapshot, current.directoryRejection == nil else { throw SMBDirectoryFailure.stale }
        guard current.idle, current.failure == nil else { throw SMBBrowserFailure.busy }
        let file: SMBDownloadedFile
        do { file = try await storage.downloads.store.reserve(selection) }
        catch let issue as RemoteDownloadStorageFailure { throw SMBTextFailure(issue) }
        let attempt = SMBDownloadAttempt(selection: selection, file: file, progress: nil,
                                         retainingEditSource: retainingEditSource)
        var openedLease: SMBTextReadLease?
        var capturedEditSource = false
        do {
            let checked = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { owner.download(attempt, continuation: $0) }
            } onCancel: { attempt.cancel(); owner.cancelDownload(attempt) }
            capturedEditSource = checked.editSourceRetained
            guard capturedEditSource == retainingEditSource else { throw SMBBrowserFailure.invalidOutput }
            try Task.checkCancellation()
            let digest = try await file.seal(checked)
            let lease = try await SMBTextReadLease.mint(file, checked: checked, digest: digest)
            openedLease = lease
            if Task.isCancelled { throw SMBTextFailure.stopped }
            return lease
        } catch {
            var cleanupNeedsReview = false
            if let openedLease {
                if case .retainedForReview = await openedLease.closeForViewer() { cleanupNeedsReview = true }
            } else if attempt.mayAbandon {
                do { try await file.removeAfterDrain() }
                catch { _ = await file.abandon(); cleanupNeedsReview = true }
            } else { cleanupNeedsReview = true }
            if capturedEditSource {
                do { try await releaseEditSource(selection.request) }
                catch { _ = await close(); throw SMBTextFailure.reviewRequired }
            }
            if cleanupNeedsReview { throw SMBTextFailure.reviewRequired }
            if let issue = error as? RemoteDownloadStorageFailure { throw SMBTextFailure(issue) }
            if error is CancellationError { throw SMBTextFailure.stopped }
            throw error
        }
    }
    /// A private checked text read establishes the first remote baseline. Its
    /// temporary receive body is drained before the native buffer is handed
    /// out. The dedicated Edit store alone owns later durable recovery bodies.
    public func openInPlaceText(selected selection: SMBDownloadSelection,
                                storage: SMBInPlaceWorkingCopyStorage) async throws -> SMBInPlaceDocumentSession {
        guard allowsInPlaceTextEdit, selection.connection == id, let server = owner.request,
              let runtime = owner.runtimeStorage, runtime.directory == storage.layout.storage.directory,
              let liveWitness = runtime.workspaceWitness,
              let storageWitness = storage.layout.storage.workspaceWitness,
              liveWitness.access == .connection, storageWitness.access == .connection,
              liveWitness.paths == storageWitness.paths,
              liveWitness.identity == storageWitness.identity else {
            throw SMBTextFailure.unavailable
        }
        let pin = SMBInPlaceOpenWitness(runtime)
        try await pin.hold()
        do {
            let view = try await openText(selected: selection, storage: storage.textReads,
                                          retainingEditSource: true)
            do {
            guard let source = view.receipt.sourceSnapshot, source.editEligible,
                  source.size == view.receipt.receivedBytes else { throw SMBTextFailure.unsupported }
            let contents = try await view.read()
            guard await view.closeForViewer() == .removed else { throw SMBTextFailure.reviewRequired }
            await pin.release()
            return SMBInPlaceDocumentSession(browser: self, storage: storage, selection: selection,
                                             server: server, initialContents: contents, baseline: source)
            } catch {
                let removed = await view.closeForViewer() == .removed
                do { try await releaseEditSource(selection.request) }
                catch { _ = await close(); throw SMBTextFailure.reviewRequired }
                guard removed else { throw SMBTextFailure.reviewRequired }
                throw error
            }
        } catch {
            await pin.release()
            throw error
        }
    }
    func releaseEditSource(_ token: UUID) async throws {
        try await withCheckedThrowingContinuation { owner.releaseEditSource(token, continuation: $0) }
    }
    public func downloadBatch(_ plan: SMBDownloadBatchPlan, storage: SMBDownloadStorage,
        progress: (@Sendable (SMBDownloadBatchProgress) -> Void)? = nil) async throws -> SMBDownloadBatchReceived {
        guard allowsSelectedDownloads, plan.connection == id else { throw SMBBrowserFailure.invalidInput }
        let files: [SMBDownloadedFile]
        do { files = try await storage.store.reserveBatch(plan,
            publicQuarantineV1: storage.publicQuarantineSelectedGroupCandidate) }
        catch {
            let reservation = error as? RemoteDownloadBatchReservationFailure
            let cause = reservation?.cause ?? error
            throw SMBDownloadBatchInterruption(completedFiles: 0, totalFiles: plan.items.count,
                completedBytes: 0, retainedFileIDs: reservation?.retainedFileIDs ?? [],
                currentMayHaveStarted: false, cause: Self.batchCause(cause), connectionFailed: false)
        }
        let control = SMBDownloadBatchControl()
        var before: UInt64 = 0
        let attempts = zip(plan.items, files).enumerated().map { index, pair -> SMBDownloadAttempt in
            let start = before; before += pair.0.selection.logicalBytes
            return SMBDownloadAttempt(selection: pair.0.selection, file: pair.1, progress: { bytes in
                progress?(.init(index: index, completedFiles: index, totalFiles: plan.items.count,
                                receivedBytes: start + min(bytes, pair.0.selection.logicalBytes), logicalBytes: plan.logicalBytes))
            })
        }
        var batchReleased = false
        do {
            let receipts = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { owner.downloadBatch(plan, attempts: attempts,
                    control: control, progress: progress, continuation: $0) }
            } onCancel: { control.cancel(); owner.cancelBatch(control) }
            guard receipts.count == files.count else { throw SMBBrowserFailure.invalidOutput }
            var received: [SMBDownloadBatchReceivedItem] = []
            for (index, receipt) in receipts.enumerated() {
                try Task.checkCancellation()
                guard receipt.selection == plan.items[index].selection else { throw SMBBrowserFailure.invalidOutput }
                _ = try await files[index].seal(receipt)
                received.append(.init(selection: receipt.selection, localName: plan.items[index].localName,
                                      download: SMBReceivedDownload(files[index])))
            }
            try Task.checkCancellation()
            try owner.finishBatch(control)
            batchReleased = true
            try Task.checkCancellation()
            return .init(items: received, logicalBytes: plan.logicalBytes)
        } catch {
            var drained = true
            if control.started && !batchReleased { drained = await close().ownerReleased }
            if drained { for file in files { _ = await file.abandon() } }
            let state = control.progress
            throw SMBDownloadBatchInterruption(completedFiles: state.completedFiles, totalFiles: plan.items.count,
                completedBytes: state.completedBytes, retainedFileIDs: files.map(\.id),
                currentMayHaveStarted: state.currentMayHaveStarted,
                cause: Self.batchCause(error), connectionFailed: control.started && !batchReleased)
        }
    }
    private static func batchCause(_ error: any Error) -> any Error {
        if let issue = error as? RemoteDownloadStorageFailure { return SMBDownloadStorageIssue(issue) }
        return error
    }
    public func close() async -> SMBBrowserDrainResult {
        owner.stop(); return await withCheckedContinuation { owner.wait($0) }
    }
    deinit { owner.stop() }
}

private final class SMBBrowserAdmission: @unchecked Sendable {
    static let shared = SMBBrowserAdmission()
    private let lock = NSLock()
    private var owners: [UUID: SMBBrowserOwner] = [:]
    func admit(_ value: SMBBrowserOwner) throws {
        try lock.withLock {
            let maximum = value.runtimeStorage == nil ? 1 : 2
            guard owners.count < maximum, owners.values.allSatisfy({ $0.runtimeStorage != nil }) || owners.isEmpty else { throw SMBBrowserFailure.busy }
            owners[value.id] = value
        }
    }
    func release(_ value: SMBBrowserOwner) { lock.withLock { if owners[value.id] === value { owners.removeValue(forKey: value.id) } } }
}

/// One serial IPC executor. UI locks protect only short control/publication
/// state; no filesystem, signature check, waitpid or poll runs on the main actor.
final class SMBBrowserOwner: @unchecked Sendable {
    let id = UUID()
    let events = AsyncStream.makeStream(of: SMBBrowserUpdate.self, bufferingPolicy: .bufferingNewest(1))
    private let lock = NSLock(), queue = DispatchQueue(label: "MacExplorer.SMB.BrowserQualification", qos: .userInitiated)
    let bundle: URL, root: URL, activity: FileActivityGate, policy: SMBWorkerSecurityPolicy, share: SMBRemoteName
    let runtimeStorage: SMBTemporaryStorage?
    let mode: SMBBrowserMode
    let prepared: SMBPreparedConnection?
    let request: SMBServerDraft?
    var runtimeFiles: SMBCatalogFiles?
    var credentialInput: Data?
    var descriptor: Int32 = -1, directory: Int32 = -1, database: Int32 = -1, leaseFD: Int32 = -1
    var child: pid_t = 0
    private var peakResidentBytes: UInt64?
    var helloSent = false
    private var lease: FileActivityGate.Lease?
    private var status: Int32?, stopAt: TimeInterval?, contained = false, eof = false, buffer = Data()
    private var ready: CheckedContinuation<Void, Error>?
    private var waiters: [CheckedContinuation<SMBBrowserDrainResult, Never>] = []
    private var result: SMBBrowserDrainResult?
    private var problem: SMBBrowserFailure?
    private var folderDiagnostic: SMBFolderUploadDiagnostic?
    private var preflightCode: SMBActionPreflightCode?
    private var actionDiagnostic: (request: UUID, checkpoint: UInt8)?
    private var editDiagnostic: (request: UUID, checkpoint: UInt8)?
    private var counts: [UInt64]?
    private var current = SMBBrowserUpdate(security: nil, snapshot: nil, idle: true, failure: nil)
    private var decoder: SMBBrowserDecoder
    private var frames = SMBDownloadFrames()
    private typealias DownloadWork = (attempt: SMBDownloadAttempt, continuation: CheckedContinuation<SMBDownloadReceipt, Error>?)
    private var queuedDownload: DownloadWork?, activeDownload: DownloadWork?
    private var retainedEditSources = Set<UUID>()
    private typealias EditSourceReleaseWork = (token: UUID, continuation: CheckedContinuation<Void, Error>)
    private var queuedEditSourceReleases: [EditSourceReleaseWork] = []
    private var pendingEditSourceRelease: EditSourceReleaseWork?
    private struct DownloadBatchWork {
        let plan: SMBDownloadBatchPlan
        let attempts: [SMBDownloadAttempt]
        let control: SMBDownloadBatchControl
        let progress: (@Sendable (SMBDownloadBatchProgress) -> Void)?
        var receipts: [SMBDownloadReceipt] = []
        var continuation: CheckedContinuation<[SMBDownloadReceipt], Error>?
    }
    private var queuedBatch: DownloadBatchWork?, activeBatch: DownloadBatchWork?
    private enum FolderDecision { case none, begin, release }
    private struct FolderWork {
        let attempt: SMBFolderPreparationAttempt
        var preparation: CheckedContinuation<SMBPreparedFolderDownload, Error>?
        var prepared: SMBPreparedFolderDownload?
        var receiver: SMBFolderReceiveAttempt?
        var reception: CheckedContinuation<Void, Error>?
        var release: CheckedContinuation<Void, Error>?
        var decision: FolderDecision = .none
    }
    private var queuedFolder: FolderWork?, activeFolder: FolderWork?
    private typealias UploadWork = (attempt: SMBUploadAttempt, continuation: CheckedContinuation<SMBCompletedUpload, Error>?)
    private var queuedUpload: UploadWork?, activeUpload: UploadWork?
    private typealias FolderUploadWork = (attempt: SMBFolderUploadAttempt, continuation: CheckedContinuation<SMBCompletedFolderUpload, Error>?)
    private var queuedFolderUpload: FolderUploadWork?, activeFolderUpload: FolderUploadWork?
    private var folderUploadBusy: Bool { queuedFolderUpload != nil || activeFolderUpload != nil }
    private typealias ActionWork = (attempt: SMBActionAttempt, continuation: CheckedContinuation<SMBCompletedAction, Error>?)
    private var queuedAction: ActionWork?, activeAction: ActionWork?
    private var actionBusy: Bool { queuedAction != nil || activeAction != nil }
    private typealias EditWork = (attempt: SMBInPlaceEditAttempt, continuation: CheckedContinuation<SMBOriginalEditOutcome, Error>?)
    private var queuedEdit: EditWork?, activeEdit: EditWork?
    private var editBusy: Bool { queuedEdit != nil || activeEdit != nil }

    private var queuedNavigation: ([SMBRemoteName], CheckedContinuation<UUID, Error>)?
    private var navigation: (SMBBrowserReadRequest, CheckedContinuation<UUID, Error>)?
    private var queuedPage: (SMBDirectoryPageRequest, CheckedContinuation<SMBDirectoryPage, Error>)?
    private var pendingPage: CheckedContinuation<SMBDirectoryPage, Error>?
    private var queuedFind: (SMBDirectoryFindRequest, CheckedContinuation<SMBDirectoryFindResult, Error>)?
    private var pendingFind: CheckedContinuation<SMBDirectoryFindResult, Error>?
    private var queuedFolderSize: (SMBFolderSizeSelection, CheckedContinuation<RemoteFolderSizeSummary, Error>)?
    private var pendingFolderSize: CheckedContinuation<RemoteFolderSizeSummary, Error>?
    private var folderSizeBegan: TimeInterval?
    private var folderSizeBusy: Bool { queuedFolderSize != nil || pendingFolderSize != nil }
    private var cancelQueued = false
    var latest: SMBBrowserUpdate { lock.withLock { current } }
    var commandCounts: [UInt64]? { lock.withLock { counts } }
    var actionPreflightCode: SMBActionPreflightCode? { lock.withLock { preflightCode } }
    func actionDiagnosticCheckpoint(for request: UUID) -> UInt8? {
        lock.withLock { actionDiagnostic?.request == request && actionDiagnostic?.checkpoint != 0
            ? actionDiagnostic?.checkpoint : nil }
    }
    func editDiagnosticCheckpoint(for request: UUID) -> UInt8? {
        lock.withLock { editDiagnostic?.request == request && editDiagnostic?.checkpoint != 0
            ? editDiagnostic?.checkpoint : nil }
    }

    init(bundle: URL, root: URL, activity: FileActivityGate, password: SMBPassword, policy: SMBWorkerSecurityPolicy, share: SMBGeneratedShare) throws {
        self.bundle = bundle; self.root = root; self.activity = activity; self.policy = policy; self.share = try SMBRemoteName(share.rawValue)
        runtimeStorage = nil; prepared = nil; request = nil; mode = .metadata
        decoder = SMBBrowserDecoder(session: id, requireEncryption: policy == .encrypted)
        credentialInput = SMBPreparedConnection.credentials(account: "nobody", domain: "", password: password)
    }
    init(bundle: URL, request: SMBServerDraft, endpoint: SMBPreparedConnection, storage: SMBTemporaryStorage,
         activity: FileActivityGate, password: SMBPassword, selectedDownloads: Bool = false, textReads: Bool = false,
         folderDownloads: Bool = false,
         freshUploads: Bool = false) throws {
        try endpoint.validate(for: request)
        self.bundle = bundle; root = storage.directory; self.activity = activity; policy = request.security; share = request.address.share
        prepared = endpoint; self.request = request; runtimeStorage = storage
        mode = freshUploads && request.security == .encrypted && request.effectiveTransferPreference != .readOnly
            ? .selectedUpload : folderDownloads ? .folderDownload : selectedDownloads || textReads ? .selectedDownload : .metadata
        frames = SMBDownloadFrames(maximumFrameBytes: mode.allowsFolderDownload ? SMBFolderDownloadConversation.maximumFrameBytes : SMBDownloadConversation.maximumFrameBytes)
        decoder = SMBBrowserDecoder(session: id, requireEncryption: request.security == .encrypted, mode: mode)
        credentialInput = SMBPreparedConnection.credentials(account: request.account, domain: request.domain, password: password)
    }
    func start(_ continuation: CheckedContinuation<Void, Error>) { ready = continuation; queue.async { self.run() } }
    func stop(_ failure: SMBBrowserFailure = .stopped) {
        lock.withLock {
            if stopAt == nil { stopAt = ProcessInfo.processInfo.systemUptime; problem = failure }
            if descriptor >= 0, helloSent { var byte: UInt8 = 1; _ = Darwin.send(descriptor, &byte, 1, MSG_DONTWAIT) }
        }
    }
    func cancelRead() {
        let unadmitted = lock.withLock {
            cancelQueued = true; let value = queuedNavigation; queuedNavigation = nil; return value
        }
        unadmitted?.1.resume(throwing: SMBBrowserFailure.stopped)
    }
    func navigate(_ components: [SMBRemoteName], continuation: CheckedContinuation<UUID, Error>) {
        do { try lock.withLock {
            guard stopAt == nil, result == nil else { throw SMBBrowserFailure.stopped }
            guard queuedNavigation == nil, navigation == nil, queuedDownload == nil, activeDownload == nil,
                  queuedBatch == nil, activeBatch == nil, queuedFolder == nil, activeFolder == nil,
                  queuedUpload == nil, activeUpload == nil, !folderUploadBusy, !actionBusy, !editBusy else { throw SMBBrowserFailure.busy }
            queuedNavigation = (components, continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func find(_ query: RemoteDirectoryFindQuery, continuation: CheckedContinuation<SMBDirectoryFindResult, Error>) {
        do { try lock.withLock {
            guard stopAt == nil, result == nil else { throw SMBBrowserFailure.stopped }
            guard queuedPage == nil, pendingPage == nil, queuedFind == nil, pendingFind == nil,
                  queuedDownload == nil, activeDownload == nil, queuedBatch == nil, activeBatch == nil,
                  queuedFolder == nil, activeFolder == nil, queuedUpload == nil, activeUpload == nil,
                  !folderUploadBusy, !actionBusy, !editBusy, !folderSizeBusy else { throw SMBBrowserFailure.busy }
            guard let snapshot = current.snapshot, current.directoryRejection == nil else { throw RemoteDirectoryFindFailure.stale }
            queuedFind = (.init(query: query, snapshot: snapshot), continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func summarizeSelectedFolder(_ selection: SMBFolderSizeSelection, continuation: CheckedContinuation<RemoteFolderSizeSummary, Error>) {
        do { try lock.withLock {
            guard mode.allowsFolderSizeSummary else { throw RemoteFolderSizeFailure.unsupported }
            guard stopAt == nil, result == nil, current.failure == nil else { throw RemoteFolderSizeFailure.connectionLost }
            guard !folderSizeBusy, queuedNavigation == nil, navigation == nil, queuedPage == nil, pendingPage == nil,
                  queuedFind == nil, pendingFind == nil, queuedDownload == nil, activeDownload == nil,
                  queuedBatch == nil, activeBatch == nil, queuedFolder == nil, activeFolder == nil,
                  queuedUpload == nil, activeUpload == nil, !folderUploadBusy, !actionBusy, !editBusy,
                  current.idle else { throw SMBBrowserFailure.busy }
            guard selection.connection == id, selection.snapshot == current.snapshot,
                  current.directoryRejection == nil else { throw RemoteFolderSizeFailure.stale }
            queuedFolderSize = (selection, continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func page(offset: Int64, sort: SMBDirectorySort, descending: Bool, find: SMBDirectoryFindResult?, continuation: CheckedContinuation<SMBDirectoryPage, Error>) {
        do { try lock.withLock {
            guard stopAt == nil, result == nil else { throw SMBBrowserFailure.stopped }
            guard queuedPage == nil, pendingPage == nil, queuedFind == nil, pendingFind == nil, queuedDownload == nil, activeDownload == nil,
                  queuedBatch == nil, activeBatch == nil, queuedFolder == nil, activeFolder == nil,
                  queuedUpload == nil, activeUpload == nil, !folderUploadBusy, !actionBusy, !editBusy, !folderSizeBusy else { throw SMBBrowserFailure.busy }
            guard let snapshot = current.snapshot, current.directoryRejection == nil else { throw SMBBrowserFailure.unavailable }
            queuedPage = (try SMBDirectoryPageRequest(snapshot: snapshot, offset: offset, sort: sort, descending: descending, find: find), continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func download(_ attempt: SMBDownloadAttempt, continuation: CheckedContinuation<SMBDownloadReceipt, Error>) {
        do { try lock.withLock {
            guard mode != .metadata, stopAt == nil, result == nil, current.failure == nil else { throw SMBBrowserFailure.unavailable }
            if attempt.retainingEditSource {
                guard mode == .selectedUpload, policy == .encrypted else { throw SMBBrowserFailure.unavailable }
                guard retainedEditSources.count < 2 else { throw SMBTextFailure.busy }
            }
            guard queuedNavigation == nil, navigation == nil, queuedPage == nil, pendingPage == nil, queuedFind == nil, pendingFind == nil,
                  queuedDownload == nil, activeDownload == nil, queuedBatch == nil, activeBatch == nil,
                  queuedFolder == nil, activeFolder == nil, queuedUpload == nil, activeUpload == nil, !folderUploadBusy, !actionBusy, !editBusy, !folderSizeBusy,
                  current.idle, current.directoryRejection == nil,
                  current.snapshot == attempt.selection.snapshot, attempt.selection.connection == id else { throw SMBBrowserFailure.busy }
            guard attempt.admit() else { throw SMBBrowserFailure.stopped }
            queuedDownload = (attempt, continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func releaseEditSource(_ token: UUID, continuation: CheckedContinuation<Void, Error>) {
        let done = lock.withLock { () -> Result<Void, Error>? in
            guard stopAt == nil, result == nil else { return .failure(SMBBrowserFailure.stopped) }
            guard retainedEditSources.contains(token) else { return .success(()) }
            // One release command is sent at a time. A repeated request waits
            // for the same ACK without removing another editor's source.
            queuedEditSourceReleases.append((token, continuation))
            return nil
        }
        if let done { continuation.resume(with: done) }
    }
    func cancelDownload(_ attempt: SMBDownloadAttempt) {
        let admitted = lock.withLock { queuedDownload?.attempt === attempt || activeDownload?.attempt === attempt }
        if admitted { stop() }
    }
    func downloadBatch(_ plan: SMBDownloadBatchPlan, attempts: [SMBDownloadAttempt], control: SMBDownloadBatchControl,
        progress: (@Sendable (SMBDownloadBatchProgress) -> Void)?,
        continuation: CheckedContinuation<[SMBDownloadReceipt], Error>) {
        do { try lock.withLock {
            guard mode != .metadata, stopAt == nil, result == nil, current.failure == nil else { throw SMBBrowserFailure.unavailable }
            guard !control.cancelled, attempts.count == plan.items.count, queuedNavigation == nil, navigation == nil,
                  queuedPage == nil, pendingPage == nil, queuedFind == nil, pendingFind == nil, queuedDownload == nil, activeDownload == nil,
                  queuedBatch == nil, activeBatch == nil, queuedFolder == nil, activeFolder == nil,
                  queuedUpload == nil, activeUpload == nil, !folderUploadBusy, !actionBusy, !editBusy, !folderSizeBusy,
                  current.idle, current.directoryRejection == nil,
                  current.snapshot == plan.snapshot, plan.connection == id else { throw SMBBrowserFailure.busy }
            queuedBatch = .init(plan: plan, attempts: attempts, control: control, progress: progress,
                                continuation: continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func cancelBatch(_ control: SMBDownloadBatchControl) {
        let (queued, active) = lock.withLock { () -> (DownloadBatchWork?, Bool) in
            if queuedBatch?.control === control { let value = queuedBatch; queuedBatch = nil; return (value, false) }
            return (nil, activeBatch?.control === control)
        }
        queued?.continuation?.resume(throwing: SMBBrowserFailure.stopped)
        if active { stop() }
    }
    func finishBatch(_ control: SMBDownloadBatchControl) throws {
        try lock.withLock {
            guard stopAt == nil, var batch = activeBatch, batch.control === control,
                  batch.receipts.count == batch.attempts.count, activeDownload == nil,
                  queuedDownload == nil else { throw SMBBrowserFailure.stopped }
            batch.continuation = nil; activeBatch = nil
        }
        publish(snapshot: latest.snapshot, idle: true)
    }
    func prepareFolder(_ attempt: SMBFolderPreparationAttempt, continuation: CheckedContinuation<SMBPreparedFolderDownload, Error>) {
        do { try lock.withLock {
            guard mode.allowsFolderDownload, stopAt == nil, result == nil, current.failure == nil else { throw SMBBrowserFailure.unavailable }
            guard queuedNavigation == nil, navigation == nil, queuedPage == nil, pendingPage == nil, queuedFind == nil, pendingFind == nil,
                  queuedDownload == nil, activeDownload == nil, queuedBatch == nil, activeBatch == nil,
                  queuedFolder == nil, activeFolder == nil, queuedUpload == nil, activeUpload == nil, !folderUploadBusy, !actionBusy, !editBusy, !folderSizeBusy,
                  current.idle, current.directoryRejection == nil, current.snapshot == attempt.selection.snapshot,
                  attempt.selection.connection == id else { throw SMBBrowserFailure.busy }
            guard attempt.admit() else { throw SMBBrowserFailure.stopped }
            queuedFolder = .init(attempt: attempt, preparation: continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func beginFolder(_ attempt: SMBFolderReceiveAttempt, continuation: CheckedContinuation<Void, Error>) {
        do { try lock.withLock {
            guard stopAt == nil, result == nil, var value = activeFolder, let prepared = value.prepared,
                  value.preparation == nil, value.receiver == nil, value.release == nil, value.decision == .none,
                  prepared.selection == attempt.prepared.selection, prepared.manifest == attempt.prepared.manifest,
                  attempt.tree.matches(prepared) else { throw SMBDirectoryFailure.stale }
            guard attempt.admit() else { throw SMBBrowserFailure.stopped }
            value.receiver = attempt; value.reception = continuation; value.decision = .begin; activeFolder = value
        } } catch { continuation.resume(throwing: error) }
    }
    func releaseFolder(_ prepared: SMBPreparedFolderDownload, continuation: CheckedContinuation<Void, Error>) {
        do { try lock.withLock {
            guard stopAt == nil, result == nil, var value = activeFolder, let original = value.prepared,
                  value.preparation == nil, value.receiver == nil, value.release == nil, value.decision == .none,
                  original.selection == prepared.selection, original.manifest == prepared.manifest else { throw SMBDirectoryFailure.stale }
            value.release = continuation; value.decision = .release; activeFolder = value
        } } catch { continuation.resume(throwing: error) }
    }
    func cancelFolderPreparation(_ attempt: SMBFolderPreparationAttempt) {
        let admitted = lock.withLock { queuedFolder?.attempt === attempt || activeFolder?.attempt === attempt }; if admitted { stop() }
    }
    func cancelFolderReceive(_ attempt: SMBFolderReceiveAttempt) {
        let admitted = lock.withLock { activeFolder?.receiver === attempt }; if admitted { stop() }
    }
    func upload(_ attempt: SMBUploadAttempt, continuation: CheckedContinuation<SMBCompletedUpload, Error>) {
        do { try lock.withLock {
            guard mode == .selectedUpload, stopAt == nil, result == nil, current.failure == nil,
                  policy == .encrypted else { throw SMBBrowserFailure.unavailable }
            guard queuedNavigation == nil, navigation == nil, queuedPage == nil, pendingPage == nil, queuedFind == nil, pendingFind == nil,
                  queuedDownload == nil, activeDownload == nil, queuedBatch == nil, activeBatch == nil,
                  queuedFolder == nil, activeFolder == nil, queuedUpload == nil, activeUpload == nil, !folderUploadBusy, !actionBusy, !editBusy, !folderSizeBusy,
                  current.idle, current.directoryRejection == nil,
                  current.snapshot == attempt.request.snapshot, attempt.request.connection == id else { throw SMBBrowserFailure.busy }
            guard attempt.admit() else { throw SMBBrowserFailure.stopped }
            queuedUpload = (attempt, continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func cancelUpload(_ attempt: SMBUploadAttempt) {
        let admitted = lock.withLock { queuedUpload?.attempt === attempt || activeUpload?.attempt === attempt }
        if admitted { stop() }
    }
    func uploadFolder(_ attempt: SMBFolderUploadAttempt, continuation: CheckedContinuation<SMBCompletedFolderUpload, Error>) {
        do { try lock.withLock {
            guard mode == .selectedUpload, stopAt == nil, result == nil, current.failure == nil,
                  policy == .encrypted else { throw SMBBrowserFailure.unavailable }
            guard queuedNavigation == nil, navigation == nil, queuedPage == nil, pendingPage == nil, queuedFind == nil, pendingFind == nil,
                  queuedDownload == nil, activeDownload == nil, queuedBatch == nil, activeBatch == nil,
                  queuedFolder == nil, activeFolder == nil, queuedUpload == nil, activeUpload == nil, !folderUploadBusy, !actionBusy, !editBusy, !folderSizeBusy,
                  current.idle, current.directoryRejection == nil,
                  current.snapshot == attempt.request.snapshot, attempt.request.connection == id else { throw SMBBrowserFailure.busy }
            guard attempt.admit() else { throw SMBBrowserFailure.stopped }
            queuedFolderUpload = (attempt, continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func cancelFolderUpload(_ attempt: SMBFolderUploadAttempt) {
        let admitted = lock.withLock { queuedFolderUpload?.attempt === attempt || activeFolderUpload?.attempt === attempt }
        if admitted { stop() }
    }
    func action(_ attempt: SMBActionAttempt, continuation: CheckedContinuation<SMBCompletedAction, Error>) {
        do { try lock.withLock {
            guard mode == .selectedUpload, stopAt == nil, result == nil, current.failure == nil,
                  policy == .encrypted else { throw SMBBrowserFailure.unavailable }
            guard queuedNavigation == nil, navigation == nil, queuedPage == nil, pendingPage == nil, queuedFind == nil, pendingFind == nil,
                  queuedDownload == nil, activeDownload == nil, queuedBatch == nil, activeBatch == nil,
                  queuedFolder == nil, activeFolder == nil, queuedUpload == nil, activeUpload == nil,
                  !folderUploadBusy, !actionBusy, !editBusy, !folderSizeBusy, current.idle, current.directoryRejection == nil,
                  current.snapshot == attempt.request.snapshot, attempt.request.connection == id else { throw SMBBrowserFailure.busy }
            guard attempt.admit() else { throw SMBActionFailure.stopped }
            queuedAction = (attempt, continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func cancelAction(_ attempt: SMBActionAttempt) {
        let admitted = lock.withLock { queuedAction?.attempt === attempt || activeAction?.attempt === attempt }
        if admitted { stop() }
    }
    func edit(_ attempt: SMBInPlaceEditAttempt, continuation: CheckedContinuation<SMBOriginalEditOutcome, Error>) {
        do { try lock.withLock {
            guard mode == .selectedUpload, policy == .encrypted, stopAt == nil, result == nil,
                  current.failure == nil else { throw SMBBrowserFailure.unavailable }
            guard queuedNavigation == nil, navigation == nil, queuedPage == nil, pendingPage == nil, queuedFind == nil, pendingFind == nil,
                  queuedDownload == nil, activeDownload == nil, queuedBatch == nil, activeBatch == nil,
                  queuedFolder == nil, activeFolder == nil, queuedUpload == nil, activeUpload == nil,
                  !folderUploadBusy, !actionBusy, !editBusy, !folderSizeBusy, current.idle,
                  (attempt.request.sourceToken != nil || current.directoryRejection == nil),
                  queuedEditSourceReleases.isEmpty, pendingEditSourceRelease == nil,
                  (attempt.request.sourceToken == nil && current.snapshot == attempt.request.selection.snapshot
                    || attempt.request.sourceToken == attempt.request.selection.request
                        && retainedEditSources.contains(attempt.request.selection.request)),
                  attempt.request.selection.connection == id else { throw SMBBrowserFailure.busy }
            guard attempt.admit() else { throw SMBBrowserFailure.stopped }
            queuedEdit = (attempt, continuation)
        } } catch { continuation.resume(throwing: error) }
    }
    func cancelEdit(_ attempt: SMBInPlaceEditAttempt) {
        let admitted = lock.withLock { queuedEdit?.attempt === attempt || activeEdit?.attempt === attempt }
        if admitted { stop() }
    }
    func wait(_ continuation: CheckedContinuation<SMBBrowserDrainResult, Never>) {
        let done: SMBBrowserDrainResult? = lock.withLock { if let result { return result }; waiters.append(continuation); return nil }
        if let done { continuation.resume(returning: done) }
    }
    private func publish(snapshot: SMBDirectorySnapshot?, idle: Bool, security: SMBWorkerSecurity? = nil, rejection: SMBDirectoryRejection? = nil) {
        let value = lock.withLock {
            current = SMBBrowserUpdate(security: security ?? current.security, snapshot: snapshot, idle: idle,
                failure: problem, directoryRejection: rejection, folderUploadDiagnostic: folderDiagnostic)
            return current
        }
        events.continuation.yield(value)
    }
    private func run() {
        do { lease = try activity.begin(); try launch() }
        catch { stop(error as? SMBBrowserFailure ?? .unavailable); lock.withLock { if descriptor >= 0, !helloSent { _ = shutdown(descriptor, SHUT_WR) } } }
        while child > 0, status == nil || !eof {
            let now = ProcessInfo.processInfo.systemUptime
            if let began = lock.withLock({ folderSizeBegan }), now - began > 105 { stop(.deadline) }
            if let at = lock.withLock({ stopAt }) {
                if now - at > 3, status == nil, !contained { contained = true; _ = kill(child, SIGTERM) }
                if now - at > 5, status == nil { _ = kill(child, SIGKILL) }
                if now - at > 8 { contained = true; break }
            }
            if status == nil {
                var value: Int32 = 0, metrics = rusage()
                let found = wait4(child, &value, WNOHANG, &metrics)
                if found == child { status = value; peakResidentBytes = UInt64(max(0, metrics.ru_maxrss)) }
                else if found < 0, errno != EINTR { stop(.containment); contained = true; break }
            }
            do { try sendQueued(); if !eof { try receive() } else if status == nil { _ = poll(nil, 0, 10) } }
            catch { stop(error as? SMBBrowserFailure ?? .invalidOutput) }
        }
        let actualDrain = child == 0 || status != nil && eof
        let cleanDrain = decoder.closed && status == 0 && !contained && (mode == .metadata ? buffer.isEmpty : frames.isEmpty)
        let abandoned = lock.withLock {
            let values = (queuedNavigation, navigation, queuedPage, pendingPage, queuedFind, pendingFind, queuedFolderSize, pendingFolderSize)
            queuedNavigation = nil; navigation = nil; queuedPage = nil; pendingPage = nil; queuedFind = nil; pendingFind = nil
            queuedFolderSize = nil; pendingFolderSize = nil; folderSizeBegan = nil
            if stopAt == nil { stopAt = ProcessInfo.processInfo.systemUptime; problem = .unavailable }
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
            return values
        }
        credentialInput = nil
        var removed: Bool?
        if actualDrain {
            if let files = runtimeFiles {
                removed = files.finish(clean: child == 0 || cleanDrain); runtimeFiles = nil
            } else { for fd in [directory, database, leaseFD] where fd >= 0 { Darwin.close(fd) } }
            directory = -1; database = -1; leaseFD = -1; lease = nil; SMBBrowserAdmission.shared.release(self)
        }
        let outcome = SMBBrowserDrainResult(actualExit: child > 0 && status != nil, pipeDrained: eof,
            socketAndCatalogDrained: cleanDrain, forcedContainment: contained, ownerReleased: actualDrain,
            temporaryCatalogRemoved: removed, peakResidentBytes: peakResidentBytes)
        let failure = lock.withLock { problem } ?? .unavailable
        let downloads = lock.withLock { () -> [DownloadWork] in
            let values = [queuedDownload, activeDownload].compactMap { $0 }
            if actualDrain { queuedDownload = nil; activeDownload = nil }
            else { queuedDownload?.continuation = nil; activeDownload?.continuation = nil }
            return values
        }
        for value in downloads {
            if actualDrain { value.attempt.drained() }
            value.continuation?.resume(throwing: failure)
        }
        let releases = lock.withLock { () -> [EditSourceReleaseWork] in
            let values = queuedEditSourceReleases + [pendingEditSourceRelease].compactMap { $0 }
            queuedEditSourceReleases = []; pendingEditSourceRelease = nil
            if actualDrain { retainedEditSources.removeAll() }
            return values
        }
        releases.forEach { $0.continuation.resume(throwing: failure) }
        let batches = lock.withLock { () -> [DownloadBatchWork] in
            let values = [queuedBatch, activeBatch].compactMap { $0 }
            if actualDrain { queuedBatch = nil; activeBatch = nil }
            else { queuedBatch?.continuation = nil; activeBatch?.continuation = nil }
            return values
        }
        for value in batches {
            if actualDrain { value.attempts.forEach { $0.drained() } }
            value.continuation?.resume(throwing: failure)
        }
        let folders = lock.withLock { () -> [FolderWork] in
            let values = [queuedFolder, activeFolder].compactMap { $0 }
            if actualDrain { queuedFolder = nil; activeFolder = nil }
            else {
                queuedFolder?.preparation = nil; queuedFolder?.reception = nil; queuedFolder?.release = nil
                activeFolder?.preparation = nil; activeFolder?.reception = nil; activeFolder?.release = nil
            }
            return values
        }
        for value in folders {
            if actualDrain { value.receiver?.drained() }
            value.preparation?.resume(throwing: failure); value.reception?.resume(throwing: failure); value.release?.resume(throwing: failure)
        }
        let uploads = lock.withLock { () -> [UploadWork] in
            let values = [queuedUpload, activeUpload].compactMap { $0 }
            queuedUpload = nil; activeUpload = nil
            return values
        }
        for value in uploads { value.continuation?.resume(throwing: failure) }
        let folderUploads = lock.withLock { () -> [FolderUploadWork] in
            let values = [queuedFolderUpload, activeFolderUpload].compactMap { $0 }
            queuedFolderUpload = nil; activeFolderUpload = nil
            return values
        }
        for value in folderUploads { value.continuation?.resume(throwing: failure) }
        let actions = lock.withLock { () -> [ActionWork] in
            let values = [queuedAction, activeAction].compactMap { $0 }
            queuedAction = nil; activeAction = nil
            return values
        }
        for value in actions { value.continuation?.resume(throwing: failure) }
        let edits = lock.withLock { () -> [EditWork] in
            let values = [queuedEdit, activeEdit].compactMap { $0 }
            queuedEdit = nil; activeEdit = nil
            return values
        }
        for value in edits { value.continuation?.resume(throwing: failure) }
        ready?.resume(throwing: failure); ready = nil
        abandoned.0?.1.resume(throwing: failure); abandoned.1?.1.resume(throwing: failure)
        abandoned.2?.1.resume(throwing: failure); abandoned.3?.resume(throwing: failure)
        abandoned.4?.1.resume(throwing: failure); abandoned.5?.resume(throwing: failure)
        abandoned.6?.1.resume(throwing: RemoteFolderSizeFailure.connectionLost)
        abandoned.7?.resume(throwing: RemoteFolderSizeFailure.connectionLost)
        publish(snapshot: latest.snapshot, idle: true); events.continuation.finish()
        let waiting = lock.withLock { result = outcome; let values = waiters; waiters = []; return values }
        waiting.forEach { $0.resume(returning: outcome) }
    }
    private func sendQueued() throws {
        guard lock.withLock({ stopAt == nil }) else { return }
        // One folder summary owns the wire until its acknowledged terminal.
        // Keep newer navigation queued rather than interrupting that cleanup.
        if lock.withLock({ pendingFolderSize != nil }) { return }
        if lock.withLock({ pendingEditSourceRelease != nil }) { return }
        let size = lock.withLock { () -> (SMBFolderSizeSelection, CheckedContinuation<RemoteFolderSizeSummary, Error>)? in
            guard let queuedFolderSize else { return nil }
            self.queuedFolderSize = nil; pendingFolderSize = queuedFolderSize.1
            folderSizeBegan = ProcessInfo.processInfo.systemUptime; return queuedFolderSize
        }
        if let size {
            do {
                let command = try decoder.request(size.0)
                publish(snapshot: latest.snapshot, idle: false)
                try write(command)
            }
            catch {
                lock.withLock { pendingFolderSize = nil; folderSizeBegan = nil }
                size.1.resume(throwing: error)
                if !(error is SMBDirectoryFailure) && !(error is RemoteFolderSizeFailure) { throw error }
            }
            return
        }
        let sourceRelease = lock.withLock { () -> EditSourceReleaseWork? in
            guard current.idle, queuedDownload == nil, activeDownload == nil,
                  queuedBatch == nil, activeBatch == nil, queuedFolder == nil, activeFolder == nil,
                  queuedUpload == nil, activeUpload == nil, queuedAction == nil, activeAction == nil,
                  queuedEdit == nil, activeEdit == nil, navigation == nil,
                  queuedPage == nil, pendingPage == nil, queuedFind == nil, pendingFind == nil,
                  let first = queuedEditSourceReleases.first else { return nil }
            queuedEditSourceReleases.removeFirst(); pendingEditSourceRelease = first
            return first
        }
        if let sourceRelease {
            do { try write(decoder.releaseEditSource(sourceRelease.token)) }
            catch {
                lock.withLock { pendingEditSourceRelease = nil }
                sourceRelease.continuation.resume(throwing: error)
                stop(error as? SMBBrowserFailure ?? .invalidOutput)
            }
            return
        }
        let edit = lock.withLock { () -> EditWork? in
            guard let value = queuedEdit, activeEdit == nil else { return nil }
            queuedEdit = nil; activeEdit = value
            editDiagnostic = (value.attempt.request.id, 0)
            return value
        }
        if let edit {
            do {
                let command = try decoder.prepareEdit(edit.attempt.request)
                publish(snapshot: latest.snapshot, idle: false); try write(command)
            } catch {
                lock.withLock { activeEdit = nil }
                edit.continuation?.resume(throwing: error)
                return
            }
        }
        let action = lock.withLock { () -> ActionWork? in
            guard let value = queuedAction, activeAction == nil else { return nil }
            queuedAction = nil; activeAction = value
            actionDiagnostic = (value.attempt.request.request, 0)
            return value
        }
        if let action {
            let command: String
            do { command = try decoder.prepareAction(action.attempt.request) }
            catch {
                lock.withLock { activeAction = nil }
                action.continuation?.resume(throwing: error)
                return
            }
            publish(snapshot: latest.snapshot, idle: false); try write(command)
        }
        let upload = lock.withLock { () -> UploadWork? in
            guard let value = queuedUpload, activeUpload == nil else { return nil }
            queuedUpload = nil; activeUpload = value; return value
        }
        if let upload {
            let command: String
            do { command = try decoder.prepareUpload(upload.attempt.request) }
            catch {
                lock.withLock { activeUpload = nil }
                upload.continuation?.resume(throwing: error)
                return
            }
            publish(snapshot: latest.snapshot, idle: false); try write(command)
        }
        let folderUpload = lock.withLock { () -> FolderUploadWork? in
            guard let value = queuedFolderUpload, activeFolderUpload == nil else { return nil }
            queuedFolderUpload = nil; activeFolderUpload = value; return value
        }
        if let folderUpload {
            let command: String
            do { command = try decoder.prepareFolderUpload(folderUpload.attempt.request) }
            catch {
                lock.withLock { activeFolderUpload = nil }
                folderUpload.continuation?.resume(throwing: error)
                return
            }
            publish(snapshot: latest.snapshot, idle: false); try write(command)
        }
        let folder = lock.withLock { () -> FolderWork? in
            guard let value = queuedFolder, activeFolder == nil else { return nil }
            queuedFolder = nil; activeFolder = value; return value
        }
        if let folder {
            let command: String
            do { command = try decoder.prepareFolder(folder.attempt.selection) }
            catch { lock.withLock { activeFolder = nil }; folder.preparation?.resume(throwing: error); return }
            publish(snapshot: latest.snapshot, idle: false); try write(command)
        }
        let decision = lock.withLock { () -> (FolderDecision, UUID)? in
            guard var value = activeFolder, value.decision != .none else { return nil }
            let result = (value.decision, value.attempt.selection.request); value.decision = .none; activeFolder = value; return result
        }
        if let (kind, request) = decision {
            switch kind { case .begin: try write(decoder.beginFolder(request)); case .release: try write(decoder.releaseFolder(request)); case .none: break }
        }
        let batch = lock.withLock { () -> DownloadBatchWork? in
            guard let value = queuedBatch, activeBatch == nil, queuedDownload == nil, activeDownload == nil else { return nil }
            queuedBatch = nil; activeBatch = value; return value
        }
        if let batch {
            guard batch.control.begin(), let first = batch.attempts.first, first.admit() else {
                lock.withLock { activeBatch = nil }
                batch.continuation?.resume(throwing: SMBBrowserFailure.stopped)
                return
            }
            batch.control.startingFile()
            batch.progress?(.init(index: 0, completedFiles: 0, totalFiles: batch.attempts.count,
                                  receivedBytes: 0, logicalBytes: batch.plan.logicalBytes))
            lock.withLock { queuedDownload = (first, nil) }
        }
        let download = lock.withLock { () -> DownloadWork? in
            guard let value = queuedDownload, activeDownload == nil else { return nil }
            queuedDownload = nil; activeDownload = value; return value
        }
        if let download {
            let command: String
            do { command = try decoder.prepareDownload(download.attempt.selection,
                                                       retainingEditSource: download.attempt.retainingEditSource) }
            catch {
                let grouped = lock.withLock { activeDownload = nil; return activeBatch != nil }
                download.attempt.drained()
                if grouped { stop(error as? SMBBrowserFailure ?? .invalidInput) }
                else { download.continuation?.resume(throwing: error) }
                return
            }
            publish(snapshot: latest.snapshot, idle: false)
            try write(command)
        }
        let cancel = lock.withLock { let value = cancelQueued; cancelQueued = false; return value }
        if cancel, let number = lock.withLock({ navigation?.0.number }) ?? decoder.readNumber { try write("CANCEL \(number)\n") }
        let next = lock.withLock { let value = queuedNavigation; queuedNavigation = nil; return value }
        if let next {
            do {
                let request = try decoder.navigate(components: next.0)
                lock.withLock { navigation = (request, next.1); current = .init(security: current.security, snapshot: nil, idle: false, failure: nil) }
                try write(request.command)
            } catch {
                let pending = lock.withLock { let value = navigation; navigation = nil; return value }
                (pending?.1 ?? next.1).resume(throwing: error)
                if !(error is SMBDirectoryFailure) { throw error }
            }
        }
        let find = lock.withLock { () -> (SMBDirectoryFindRequest, CheckedContinuation<SMBDirectoryFindResult, Error>)? in
            guard pendingPage == nil, pendingFind == nil, let queuedFind else { return nil }
            self.queuedFind = nil; pendingFind = queuedFind.1; return queuedFind
        }
        if let find {
            do { try write(decoder.request(find.0)) }
            catch {
                lock.withLock { pendingFind = nil }; find.1.resume(throwing: error)
                if !(error is SMBDirectoryFailure) && !(error is RemoteDirectoryFindFailure) { throw error }
            }
        }
        let page = lock.withLock { () -> (SMBDirectoryPageRequest, CheckedContinuation<SMBDirectoryPage, Error>)? in
            guard pendingPage == nil, pendingFind == nil, let queuedPage else { return nil }; self.queuedPage = nil; pendingPage = queuedPage.1; return queuedPage
        }
        if let page {
            do { try write(decoder.request(page.0)) }
            catch {
                lock.withLock { pendingPage = nil }; page.1.resume(throwing: error)
                if !(error is SMBDirectoryFailure) && !(error is RemoteDirectoryFindFailure) { throw error }
            }
        }
    }
    private func receive() throws {
        var fd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let available = poll(&fd, 1, 10)
        if available < 0 { if errno == EINTR { return }; throw SMBBrowserFailure.unavailable }
        guard available > 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 32768)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count == 0 { eof = true; return }
        if count < 0 { if errno == EAGAIN || errno == EINTR { return }; throw SMBBrowserFailure.unavailable }
        #if DEBUG
        SFTPGeneratedBackendObservation.shared.protocolTransferred()
        #endif
        if mode != .metadata {
            // The same private executor consumes each frame and writes the
            // spool before ACK. No data is published through `updates`.
            var pending = frames
            defer { frames = pending }
            try pending.append(Data(bytes.prefix(count))) { payload in
                let event = try payload.first == 0 || payload.first == 1 ? decoder.consumeBinary(payload) : decoder.consume(payload)
                try consume(event)
            }
            return
        }
        for byte in bytes.prefix(count) {
            if byte == 10 {
                let event = try decoder.consume(buffer); buffer.removeAll(keepingCapacity: true)
                try consume(event)
            } else { guard buffer.count < 16512 else { throw SMBBrowserFailure.invalidOutput }; buffer.append(byte) }
        }
    }
    private func consume(_ event: SMBBrowserEvent?) throws {
        switch event {
                case .action(let event): try consumeAction(event)
                case .edit(let event): try consumeEdit(event)
                case .editSourceReleased(let token):
                    let released = lock.withLock { () -> EditSourceReleaseWork? in
                        guard pendingEditSourceRelease?.token == token else { return nil }
                        retainedEditSources.remove(token)
                        let value = pendingEditSourceRelease; pendingEditSourceRelease = nil
                        return value
                    }
                    guard let released else { throw SMBBrowserFailure.invalidOutput }
                    released.continuation.resume()
                case .upload(let event): try consumeUpload(event)
                case .folderUpload(let event): try consumeFolderUpload(event)
                case .download(let event): try consumeDownload(event)
                case .folder(let event): try consumeFolder(event)
                case .connected(let encrypted):
                    publish(snapshot: nil, idle: true, security: encrypted ? .encrypted : .signed)
                    if let ready { self.ready = nil; ready.resume() }
                case .began(_, let id):
                    let pending = lock.withLock { let value = navigation; navigation = nil; return value }
                    guard pending?.0.id == id else { throw SMBBrowserFailure.invalidOutput }; pending?.1.resume(returning: id)
                case .snapshot(_, let value): publish(snapshot: value, idle: false)
                case .idle: publish(snapshot: latest.snapshot, idle: true)
                case .rejected(_, let reason): publish(snapshot: latest.snapshot, idle: true, rejection: reason)
                case .page(_, let page):
                    let pending = lock.withLock { let value = pendingPage; pendingPage = nil; return value }
                    if lock.withLock({ stopAt == nil }) { pending?.resume(returning: page) }
                    else { pending?.resume(throwing: SMBBrowserFailure.stopped) }
                case .found(_, let result):
                    let pending = lock.withLock { let value = pendingFind; pendingFind = nil; return value }
                    if lock.withLock({ stopAt == nil }) { pending?.resume(returning: result) }
                    else { pending?.resume(throwing: SMBBrowserFailure.stopped) }
                case .folderSize(_, let value):
                    let pending = lock.withLock {
                        let value = pendingFolderSize; pendingFolderSize = nil; folderSizeBegan = nil; return value
                    }
                    if lock.withLock({ stopAt == nil }) {
                        publish(snapshot: latest.snapshot, idle: true); pending?.resume(returning: value)
                    }
                    else { pending?.resume(throwing: RemoteFolderSizeFailure.connectionLost) }
                case .folderSizeUnavailable(_, let reason):
                    let pending = lock.withLock {
                        let value = pendingFolderSize; pendingFolderSize = nil; folderSizeBegan = nil; return value
                    }
                    if lock.withLock({ stopAt == nil }) { publish(snapshot: latest.snapshot, idle: true) }
                    pending?.resume(throwing: reason)
                case .stale:
                    let pending = lock.withLock { let value = (pendingPage, pendingFind); pendingPage = nil; pendingFind = nil; return value }
                    pending.0?.resume(throwing: SMBDirectoryFailure.stale)
                    pending.1?.resume(throwing: RemoteDirectoryFindFailure.stale)
                case .queryUnavailable:
                    let pending = lock.withLock { let value = (pendingPage, pendingFind); pendingPage = nil; pendingFind = nil; return value }
                    pending.0?.resume(throwing: RemoteDirectoryFindFailure.unavailable)
                    pending.1?.resume(throwing: RemoteDirectoryFindFailure.unavailable)
                case .closed(let reason): if reason != "stopped" { stop(Self.failure(reason)) }
                case .networkDrained, nil: break
                case .profile(let value): lock.withLock { counts = value }
        }
    }
    private func consumeAction(_ event: SMBActionEvent) throws {
        guard let value = lock.withLock({ activeAction }) else { throw SMBBrowserFailure.invalidOutput }
        switch event {
        case .ready(let id):
            guard id == value.attempt.request.request else { throw SMBBrowserFailure.invalidOutput }
            try value.attempt.readyOnExecutor()
            try write(decoder.beginAction(id))
        case .complete(let id), .collision(let id), .notEmpty(let id),
             .stageCollision(let id), .finalCollision(let id):
            guard id == value.attempt.request.request else { throw SMBBrowserFailure.invalidOutput }
            if case .complete = event { lock.withLock { actionDiagnostic = (id, 7) } }
            let outcome: SMBActionOutcome
            switch event {
            case .complete: outcome = .confirmed
            case .collision: outcome = .collision
            case .notEmpty: outcome = .notEmpty
            case .stageCollision: outcome = .stageCollision
            case .finalCollision: outcome = .finalCollision
            default: throw SMBBrowserFailure.invalidOutput
            }
            let result = try value.attempt.completeOnExecutor(outcome: outcome)
            if outcome == .confirmed { lock.withLock { actionDiagnostic = (id, 8) } }
            lock.withLock { activeAction = nil }
            value.continuation?.resume(returning: result)
            publish(snapshot: latest.snapshot, idle: true)
        case .progress(let id, let copied, let total):
            guard id == value.attempt.request.request, value.attempt.mutationRequested,
                  value.attempt.request.operation.isCopy else { throw SMBBrowserFailure.invalidOutput }
            value.attempt.progress?(copied, total)
        case .destinationUnavailable(let id):
            guard id == value.attempt.request.request, !value.attempt.mutationRequested else { throw SMBBrowserFailure.invalidOutput }
            try value.attempt.destinationUnavailableOnExecutor()
            lock.withLock { activeAction = nil }
            value.continuation?.resume(throwing: SMBActionFailure.destinationUnavailable)
            publish(snapshot: latest.snapshot, idle: true)
        case .refused(let id, let code):
            guard id == value.attempt.request.request, !value.attempt.mutationRequested else { throw SMBBrowserFailure.invalidOutput }
            lock.withLock { preflightCode = code }
        case .fault(let id, let checkpoint):
            guard id == value.attempt.request.request, value.attempt.mutationRequested else { throw SMBBrowserFailure.invalidOutput }
            lock.withLock { actionDiagnostic = (id, checkpoint) }
        }
    }
    private func consumeEdit(_ event: SMBOriginalEditEvent) throws {
        guard let value = lock.withLock({ activeEdit }) else { throw SMBBrowserFailure.invalidOutput }
        let attempt = value.attempt, id = attempt.request.id
        if lock.withLock({ stopAt != nil }) { return }
        do {
            switch event {
            case .need(let actual, let sequence, let offset, let count):
                guard actual == id else { throw SMBBrowserFailure.invalidOutput }
                let bytes = try attempt.bytesOnSessionExecutor(offset: offset, count: count)
                try write(decoder.editData(id, sequence: sequence, offset: offset, bytes: bytes))
            case .ready(let actual):
                guard actual == id else { throw SMBBrowserFailure.invalidOutput }
                // The durable mutation-intent record precedes any worker
                // authorization. A failed record commit never sends AUTH.
                try attempt.authorizeOnSessionExecutor()
                try write(decoder.authorizeEdit(id))
            case .changed(let actual):
                guard actual == id, !attempt.mutationRequested else { throw SMBBrowserFailure.invalidOutput }
                try attempt.changedOnSessionExecutor()
                lock.withLock { activeEdit = nil }
                publish(snapshot: latest.snapshot, idle: true)
                value.continuation?.resume(returning: .changed)
            case .complete(let actual, let after):
                guard actual == id, attempt.mutationRequested else { throw SMBBrowserFailure.invalidOutput }
                lock.withLock { editDiagnostic = (id, 13) }
                do { try attempt.verifiedOnSessionExecutor(after) }
                catch {
                    lock.withLock { activeEdit = nil }
                    stop(.storage)
                    value.continuation?.resume(returning: .verifiedRecoveryNeedsAttention)
                    return
                }
                lock.withLock { editDiagnostic = (id, 14) }
                lock.withLock { activeEdit = nil }
                publish(snapshot: latest.snapshot, idle: true)
                value.continuation?.resume(returning: .verified(after))
            case .fault(let actual, let checkpoint):
                guard actual == id, attempt.mutationRequested else { throw SMBBrowserFailure.invalidOutput }
                lock.withLock { editDiagnostic = (id, checkpoint) }
            }
        } catch {
            lock.withLock { activeEdit?.continuation = nil }
            stop(.storage)
            value.continuation?.resume(throwing: error)
        }
    }
    private func consumeUpload(_ event: SMBUploadEvent) throws {
        guard let value = lock.withLock({ activeUpload }) else { throw SMBBrowserFailure.invalidOutput }
        let attempt = value.attempt
        let request = attempt.request.request
        if attempt.isCancelled || lock.withLock({ stopAt != nil }) { return }
        do {
            switch event {
            case .ready:
                try attempt.requestStageOnExecutor()
                try write(decoder.beginUpload(request))
            case .need(let sequence, let offset, let count):
                try attempt.confirmStageOnExecutor()
                let bytes = try attempt.readOnExecutor(offset: offset, count: count)
                guard bytes.count == count else { throw SMBUploadFailure.sourceChanged }
                try write(decoder.uploadData(request, sequence: sequence, offset: offset, bytes: bytes))
            case .written(let end): attempt.progress?(end)
            case .sourceDigest:
                try attempt.confirmStageOnExecutor()
                try write(decoder.uploadDigest(request, value: attempt.digestOnExecutor()))
            case .stageVerified(let digest):
                try attempt.requestPublicationOnExecutor(digest)
                try write(decoder.commitUpload(request))
            case .complete(let digest):
                let completed = try attempt.completeOnExecutor(digest)
                lock.withLock { activeUpload = nil }
                publish(snapshot: latest.snapshot, idle: true)
                value.continuation?.resume(returning: completed)
            case .stageCollision:
                try attempt.collisionOnExecutor(stage: true)
                lock.withLock { activeUpload = nil }
                publish(snapshot: latest.snapshot, idle: true)
                value.continuation?.resume(throwing: SMBUploadFailure.stageCollision)
            case .finalCollision:
                try attempt.collisionOnExecutor(stage: false)
                lock.withLock { activeUpload = nil }
                publish(snapshot: latest.snapshot, idle: true)
                value.continuation?.resume(throwing: SMBUploadFailure.finalCollision)
            }
        } catch {
            lock.withLock { activeUpload?.continuation = nil }
            stop(error is SMBUploadFailure ? .stopped : .storage)
            value.continuation?.resume(throwing: error)
        }
    }
    private func consumeFolderUpload(_ event: SMBFolderUploadEvent) throws {
        guard let value = lock.withLock({ activeFolderUpload }) else { throw SMBBrowserFailure.invalidOutput }
        let attempt = value.attempt, request = attempt.request.request
        if attempt.isCancelled || lock.withLock({ stopAt != nil }) { return }
        do {
            switch event {
            case .manifestNeed(let offset, let count):
                let bytes = try attempt.manifestOnExecutor(offset: offset, count: count)
                try write(decoder.folderUploadManifest(request, offset: offset, bytes: bytes))
            case .ready:
                try attempt.requestStageOnExecutor()
                try write(decoder.beginFolderUpload(request))
            case .rootCreated:
                try attempt.acknowledgeRootOnExecutor()
                try write(decoder.acknowledgeFolderUploadRoot(request))
            case .need(let node, let sequence, let offset, let count):
                let bytes = try attempt.readOnExecutor(node: node, offset: offset, count: count)
                try write(decoder.folderUploadData(request, node: node, sequence: sequence, offset: offset, bytes: bytes))
            case .sourceDigest(let node):
                try write(decoder.folderUploadDigest(request, node: node, value: attempt.fileDigestOnExecutor(node: node)))
            case .fileVerified(let node, let files, let bytes):
                try attempt.checkpointOnExecutor(node: node, files: files, bytes: bytes)
                try write(decoder.acknowledgeFolderUploadFile(request, node: node, files: files, bytes: bytes))
            case .stageVerified(let digest):
                try attempt.requestPublicationOnExecutor(digest)
                try write(decoder.commitFolderUpload(request, digest: digest))
            case .complete(let digest):
                let completed = try attempt.completeOnExecutor(digest)
                lock.withLock { activeFolderUpload = nil }
                publish(snapshot: latest.snapshot, idle: true)
                value.continuation?.resume(returning: completed)
            case .stageCollision:
                try attempt.collisionOnExecutor(stage: true)
                lock.withLock { activeFolderUpload = nil }
                publish(snapshot: latest.snapshot, idle: true)
                value.continuation?.resume(throwing: SMBUploadFailure.stageCollision)
            case .finalCollision:
                try attempt.collisionOnExecutor(stage: false)
                lock.withLock { activeFolderUpload = nil }
                publish(snapshot: latest.snapshot, idle: true)
                value.continuation?.resume(throwing: SMBUploadFailure.finalCollision)
            case .failure(let diagnostic):
                lock.withLock { folderDiagnostic = diagnostic }
                publish(snapshot: latest.snapshot, idle: false)
            }
        } catch {
            lock.withLock { activeFolderUpload?.continuation = nil }
            stop(error is SMBUploadFailure ? .stopped : .storage)
            value.continuation?.resume(throwing: error)
        }
    }
    private func consumeFolder(_ event: SMBFolderDownloadEvent) throws {
        guard let value = lock.withLock({ activeFolder }) else { throw SMBBrowserFailure.invalidOutput }
        if value.attempt.isCancelled || value.receiver?.isCancelled == true || lock.withLock({ stopAt != nil }) { return }
        switch event {
        case .prepared(let prepared):
            guard prepared.selection == value.attempt.selection, value.prepared == nil, let continuation = value.preparation else { throw SMBBrowserFailure.invalidOutput }
            lock.withLock { activeFolder?.prepared = prepared; activeFolder?.preparation = nil }; continuation.resume(returning: prepared)
        case .released(let request):
            guard request == value.attempt.selection.request, value.receiver == nil, let continuation = value.release else { throw SMBBrowserFailure.invalidOutput }
            lock.withLock { activeFolder = nil }; publish(snapshot: latest.snapshot, idle: true); continuation.resume()
        default:
            guard let receiver = value.receiver, let continuation = value.reception else { throw SMBBrowserFailure.invalidOutput }
            do {
                switch event {
                case .memberBegin(let request, let ordinal): try receiver.tree.beginMember(request: request, ordinal: ordinal)
                case .bytes(let request, let ordinal, let offset, let bytes):
                    try receiver.tree.appendOnSessionExecutor(request: request, ordinal: ordinal, offset: offset, bytes: bytes)
                    try write(decoder.appendedFolder(request, member: ordinal, end: offset + UInt64(bytes.count)))
                    receiver.progress?(receiver.tree.receivedBytes)
                case .memberEnd(let request, let ordinal, let bytes): try receiver.tree.endMember(request: request, ordinal: ordinal, receivedBytes: bytes)
                case .complete(let prepared):
                    guard receiver.prepared.selection == prepared.selection, receiver.prepared.manifest == prepared.manifest else { throw SMBBrowserFailure.invalidOutput }
                    lock.withLock { activeFolder = nil }; receiver.drained(); publish(snapshot: latest.snapshot, idle: true); continuation.resume()
                case .prepared, .released: throw SMBBrowserFailure.invalidOutput
                }
            } catch RemoteDownloadStorageFailure.capacity { stop(.quota) }
            catch RemoteDownloadStorageFailure.io(ENOSPC) { stop(.quota) }
            catch RemoteDownloadStorageFailure.io(EDQUOT) { stop(.quota) }
            catch let failure as RemoteDownloadStorageFailure { _ = failure; stop(.storage) }
        }
    }
    private func consumeDownload(_ event: SMBDownloadEvent) throws {
        guard let value = lock.withLock({ activeDownload }) else { throw SMBBrowserFailure.invalidOutput }
        // The decoder still validates a queued frame after Stop, but cancellation
        // never appends/ACKs it or releases a completed source to the caller.
        if value.attempt.isCancelled || lock.withLock({ stopAt != nil }) { return }
        switch event {
        case .prepared(let selection):
            guard selection == value.attempt.selection else { throw SMBBrowserFailure.invalidOutput }
            try write(decoder.beginDownload(selection.request))
        case .bytes(let request, let offset, let bytes):
            guard request == value.attempt.selection.request else { throw SMBBrowserFailure.invalidOutput }
            do { try value.attempt.file.appendOnSessionExecutor(request: request, offset: offset, bytes: bytes) }
            catch RemoteDownloadStorageFailure.capacity { stop(.quota); return }
            catch RemoteDownloadStorageFailure.io(ENOSPC) { stop(.quota); return }
            catch RemoteDownloadStorageFailure.io(EDQUOT) { stop(.quota); return }
            catch { stop(.storage); return }
            let end = offset + UInt64(bytes.count)
            try write(decoder.appendedDownload(request, end: end)); value.attempt.progress?(end)
        case .complete(let receipt):
            guard receipt.selection == value.attempt.selection,
                  receipt.editSourceRetained == value.attempt.retainingEditSource else { throw SMBBrowserFailure.invalidOutput }
            if receipt.editSourceRetained {
                guard receipt.sourceSnapshot?.editEligible == true else { throw SMBBrowserFailure.invalidOutput }
                try lock.withLock {
                    guard retainedEditSources.count < 2,
                          retainedEditSources.insert(receipt.selection.request).inserted else {
                        throw SMBBrowserFailure.invalidOutput
                    }
                }
            }
            let (batch, next) = try lock.withLock { () throws -> (DownloadBatchWork?, SMBDownloadAttempt?) in
                activeDownload = nil
                guard var batch = activeBatch else { return (nil, nil) }
                guard batch.attempts.indices.contains(batch.receipts.count),
                      batch.attempts[batch.receipts.count] === value.attempt else { throw SMBBrowserFailure.invalidOutput }
                batch.receipts.append(receipt)
                if batch.receipts.count < batch.attempts.count {
                    let next = batch.attempts[batch.receipts.count]
                    activeBatch = batch; return (batch, next)
                }
                let finished = batch
                batch.continuation = nil; activeBatch = batch; return (finished, nil)
            }
            value.attempt.drained()
            if let batch {
                batch.control.completedFile(bytes: receipt.receivedBytes)
                let state = batch.control.progress
                batch.progress?(.init(index: state.completedFiles - 1, completedFiles: state.completedFiles,
                                      totalFiles: batch.attempts.count, receivedBytes: state.completedBytes,
                                      logicalBytes: batch.plan.logicalBytes))
                if let next {
                    guard !batch.control.cancelled, next.admit() else { stop(); return }
                    batch.control.startingFile()
                    batch.progress?(.init(index: state.completedFiles, completedFiles: state.completedFiles,
                                          totalFiles: batch.attempts.count, receivedBytes: state.completedBytes,
                                          logicalBytes: batch.plan.logicalBytes))
                    lock.withLock { queuedDownload = (next, nil) }
                } else {
                    batch.continuation?.resume(returning: batch.receipts)
                }
            } else {
                publish(snapshot: latest.snapshot, idle: true)
                value.continuation?.resume(returning: receipt)
            }
        case .released: throw SMBBrowserFailure.invalidOutput
        case .sourceFull(let token):
            guard value.attempt.retainingEditSource, token == value.attempt.selection.request,
                  lock.withLock({ activeBatch == nil }) else { throw SMBBrowserFailure.invalidOutput }
            lock.withLock { activeDownload = nil }
            value.attempt.drained()
            publish(snapshot: latest.snapshot, idle: true)
            value.continuation?.resume(throwing: SMBTextFailure.busy)
        case .sourceUnavailable(let token):
            guard value.attempt.retainingEditSource, token == value.attempt.selection.request,
                  lock.withLock({ activeBatch == nil }) else { throw SMBBrowserFailure.invalidOutput }
            lock.withLock { activeDownload = nil }
            value.attempt.drained()
            publish(snapshot: latest.snapshot, idle: true)
            value.continuation?.resume(throwing: SMBTextFailure.unsupported)
        }
    }
    func write(_ text: String) throws { try write(Data(text.utf8)) }
    func write(_ data: Data) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5; var sent = 0
        defer { if sent != data.count, descriptor >= 0 { _ = shutdown(descriptor, SHUT_WR) } }
        while sent < data.count {
            guard lock.withLock({ stopAt == nil }), ProcessInfo.processInfo.systemUptime < deadline else { throw SMBBrowserFailure.stopped }
            let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: sent), $0.count - sent, MSG_DONTWAIT) }
            if count > 0 {
                sent += count
                #if DEBUG
                SFTPGeneratedBackendObservation.shared.protocolTransferred()
                #endif
            }
            else if count < 0, errno == EAGAIN || errno == EINTR { var fd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0); _ = poll(&fd, 1, 10) }
            else { throw SMBBrowserFailure.unavailable }
        }
    }
    func installChannel(_ fd: Int32) { lock.withLock { descriptor = fd } }
    func markHelloSent() {
        let stopped = lock.withLock { helloSent = true; return stopAt != nil }
        if stopped { stop() }
    }
    func admissionIsOpen() -> Bool { lock.withLock { stopAt == nil } }
    private static func failure(_ reason: String) -> SMBBrowserFailure {
        switch reason {
        case "authentication": .authentication; case "denied": .denied; case "security": .security
        case "quota": .quota; case "storage": .storage; case "deadline": .deadline
        case "invalid": .invalidOutput; case "remote": .remote; case "actionRefused": .preflightRefused; default: .unavailable
        }
    }
}
