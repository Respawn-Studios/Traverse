import Foundation

@_spi(Qualification) public enum SFTPBrowserFailure: String, Error, Sendable { case invalidInput, busy, stopped, stale, unavailable, remote, storage, denied, deadline, security }
@_spi(Qualification) public struct SFTPBrowserUpdate: Sendable {
    public let generation: UUID?
    public let snapshot: SFTPStoredSnapshot?
    public let paused: Bool
    public let reading: Bool
    public let failure: SFTPBrowserFailure?
    public var directoryRejection: SFTPDirectoryRejection? = nil
    /// Client-observed server-backed directory read, including worker/catalog
    /// processing. This is not a network ping or a cached row-page timing.
    public var lastDirectoryReadMilliseconds: Double? = nil
    public var lastDirectoryResponseAt: Date? = nil
}

protocol SFTPDirectoryTransport: Sendable {
    var allowsFolderSizeSummary: Bool { get }
    var allowsRemoteActions: Bool { get }
    var allowsServerCopy: Bool { get }
    func observedActionDirectory(for intent: SFTPRemoteActionIntent) async throws -> SFTPDefaultDirectory
    func performRemoteAction(_ intent: SFTPRemoteActionIntent, store: SFTPRemoteActionStore) async throws -> SFTPRemoteActionResult
    var allowsInPlaceEditing: Bool { get }
    func readInPlace(_ selection: SFTPDownloadSelection, snapshot: SFTPStoredSnapshot, storage: SFTPInPlaceWorkingCopyStorage) async throws -> SFTPInPlaceBaseline
    func saveInPlace(_ baseline: SFTPInPlaceBaseline, snapshot: SFTPEditedTextSnapshot, journal: SFTPInPlaceJournal) async throws -> SFTPInPlaceSaveCompletion
    func releaseInPlace(_ release: SFTPInPlaceRelease) async throws -> SFTPInPlaceCloseResult
    var allowsOriginalEditing: Bool { get }
    func readOriginal(_ selection: SFTPDownloadSelection, snapshot: SFTPStoredSnapshot,
        storage: SFTPOriginalWorkingCopyStorage) async throws -> SFTPOriginalBaseline
    func saveOriginal(_ baseline: SFTPOriginalBaseline, snapshot: SFTPEditedTextSnapshot,
        journal: SFTPOriginalJournal) async throws -> SFTPOriginalSaveCompletion
    func releaseOriginal(_ close: SFTPOriginalBaselineClose) async throws -> SFTPOriginalBaselineCloseCompletion
    var allowsRequestedDownloads: Bool { get }
    var allowsRequestedFolderDownloads: Bool { get }
    var allowsFreshUploads: Bool { get }
    var allowsFreshFolderUploads: Bool { get }
    func openStoredDirectory(_ path: String) async throws -> (UUID, SFTPStoredSnapshot)
    func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot
    func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort, descending: Bool) async throws -> SFTPStoredPage?
    func find(_ generation: UUID, snapshot: SFTPStoredSnapshot, query: RemoteDirectoryFindQuery) async throws -> SFTPDirectoryFindResult
    func summarizeSelectedFolder(_ selection: SFTPFolderSizeSelection) async throws -> RemoteFolderSizeSummary
    func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort,
              descending: Bool, find: SFTPDirectoryFindResult?) async throws -> SFTPStoredPage?
    func checkIdle() async throws
    func textOrigin(_ selection: SFTPDownloadSelection) async throws -> SFTPTextOrigin
    func uploadEditedText(_ request: SFTPRequestedEditedTextUpload, snapshot: SFTPStoredSnapshot,
        storage: SFTPUploadStorage, progress: (@Sendable (UInt64) -> Void)?) async throws -> SFTPTextFreshCopyReceipt
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
    func prepareFolderDownload(_ selection: SFTPFolderDownloadSelection, progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPPreparedFolderDownload
    func releaseFolderDownload(_ prepared: SFTPPreparedFolderDownload) async throws
    func receiveFolderDownload(_ prepared: SFTPPreparedFolderDownload, into tree: RemoteDownloadedTree,
        progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPFolderDownloadReceipt
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
    func download(_ selection: SFTPDownloadSelection, into file: RemoteDownloadedFile,
                  progress: (@Sendable (UInt64) -> Void)?) async throws -> SFTPDownloadReceipt
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
    func upload(_ request: SFTPRequestedUpload, snapshot: SFTPStoredSnapshot, storage: SFTPUploadStorage,
                excluding roots: [URL], progress: (@Sendable (UInt64) -> Void)?) async throws -> SFTPCompletedUpload
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
    func uploadFolder(_ request: SFTPRequestedFolderUpload, snapshot: SFTPStoredSnapshot, storage: SFTPUploadStorage,
                      excluding roots: [URL], progress: (@Sendable (UInt64, Int) -> Void)?) async throws -> SFTPCompletedFolderUpload
    #endif
    func close() async -> SFTPWorkerClose
}
extension SFTPDirectoryTransport {
    var allowsFolderSizeSummary: Bool { false }
    func summarizeSelectedFolder(_ selection: SFTPFolderSizeSelection) async throws -> RemoteFolderSizeSummary {
        throw RemoteFolderSizeFailure.unavailable
    }
    func find(_ generation: UUID, snapshot: SFTPStoredSnapshot, query: RemoteDirectoryFindQuery) async throws -> SFTPDirectoryFindResult {
        throw RemoteDirectoryFindFailure.unavailable
    }
    func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort,
              descending: Bool, find: SFTPDirectoryFindResult?) async throws -> SFTPStoredPage? {
        guard find == nil else { throw RemoteDirectoryFindFailure.unavailable }
        return try await page(generation, snapshot: snapshot, offset: offset, sort: sort, descending: descending)
    }
    var allowsRemoteActions: Bool { false }
    var allowsServerCopy: Bool { false }
    func observedActionDirectory(for intent: SFTPRemoteActionIntent) async throws -> SFTPDefaultDirectory { throw SFTPBrowserFailure.unavailable }
    func performRemoteAction(_ intent: SFTPRemoteActionIntent, store: SFTPRemoteActionStore) async throws -> SFTPRemoteActionResult { throw SFTPBrowserFailure.unavailable }
    var allowsInPlaceEditing: Bool { false }
    func readInPlace(_ selection: SFTPDownloadSelection, snapshot: SFTPStoredSnapshot, storage: SFTPInPlaceWorkingCopyStorage) async throws -> SFTPInPlaceBaseline { throw SFTPBrowserFailure.unavailable }
    func saveInPlace(_ baseline: SFTPInPlaceBaseline, snapshot: SFTPEditedTextSnapshot, journal: SFTPInPlaceJournal) async throws -> SFTPInPlaceSaveCompletion { throw SFTPBrowserFailure.unavailable }
    func releaseInPlace(_ release: SFTPInPlaceRelease) async throws -> SFTPInPlaceCloseResult { throw SFTPBrowserFailure.unavailable }
    var allowsOriginalEditing: Bool { false }
    func readOriginal(_ selection: SFTPDownloadSelection, snapshot: SFTPStoredSnapshot,
        storage: SFTPOriginalWorkingCopyStorage) async throws -> SFTPOriginalBaseline { throw SFTPBrowserFailure.unavailable }
    func saveOriginal(_ baseline: SFTPOriginalBaseline, snapshot: SFTPEditedTextSnapshot,
        journal: SFTPOriginalJournal) async throws -> SFTPOriginalSaveCompletion { throw SFTPBrowserFailure.unavailable }
    func releaseOriginal(_ close: SFTPOriginalBaselineClose) async throws -> SFTPOriginalBaselineCloseCompletion { throw SFTPBrowserFailure.unavailable }
    var allowsRequestedDownloads: Bool { false }
    var allowsRequestedFolderDownloads: Bool { false }
    var allowsFreshUploads: Bool { false }
    var allowsFreshFolderUploads: Bool { false }
    func checkIdle() async throws {}
    func textOrigin(_ selection: SFTPDownloadSelection) async throws -> SFTPTextOrigin { throw SFTPBrowserFailure.unavailable }
    func uploadEditedText(_ request: SFTPRequestedEditedTextUpload, snapshot: SFTPStoredSnapshot,
        storage: SFTPUploadStorage, progress: (@Sendable (UInt64) -> Void)?) async throws -> SFTPTextFreshCopyReceipt { throw SFTPBrowserFailure.unavailable }
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
    func prepareFolderDownload(_ selection: SFTPFolderDownloadSelection, progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPPreparedFolderDownload { throw SFTPBrowserFailure.unavailable }
    func releaseFolderDownload(_ prepared: SFTPPreparedFolderDownload) async throws { throw SFTPBrowserFailure.unavailable }
    func receiveFolderDownload(_ prepared: SFTPPreparedFolderDownload, into tree: RemoteDownloadedTree,
        progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPFolderDownloadReceipt { throw SFTPBrowserFailure.unavailable }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
    func download(_ selection: SFTPDownloadSelection, into file: RemoteDownloadedFile,
                  progress: (@Sendable (UInt64) -> Void)?) async throws -> SFTPDownloadReceipt { throw SFTPBrowserFailure.unavailable }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
    func upload(_ request: SFTPRequestedUpload, snapshot: SFTPStoredSnapshot, storage: SFTPUploadStorage,
                excluding roots: [URL], progress: (@Sendable (UInt64) -> Void)?) async throws -> SFTPCompletedUpload { throw SFTPBrowserFailure.unavailable }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
    func uploadFolder(_ request: SFTPRequestedFolderUpload, snapshot: SFTPStoredSnapshot, storage: SFTPUploadStorage,
                      excluding roots: [URL], progress: (@Sendable (UInt64, Int) -> Void)?) async throws -> SFTPCompletedFolderUpload { throw SFTPBrowserFailure.unavailable }
    #endif

}
extension SFTPWorkerSession: SFTPDirectoryTransport {}

/// Bounded metadata browse orchestration, not a provider/file-operation adapter.
/// One retained pump owns real transport work; caller cancellation cannot detach
/// it or install stale results. Views receive only bounded snapshots/pages.
@_spi(Qualification) public final class SFTPBrowserSession: Sendable {
    public let id: UUID
    public let allowsRequestedDownloads: Bool
    public let allowsTextRead: Bool
    public let allowsRequestedFolderDownloads: Bool
    public let allowsFolderSizeSummary: Bool
    public let allowsFreshUploads: Bool
    public let allowsFreshFolderUploads: Bool
    public let allowsInPlaceEditing: Bool
    public let allowsOriginalEditing: Bool
    public let allowsRemoteActions: Bool
    public let allowsServerCopy: Bool
    public let updates: AsyncStream<SFTPBrowserUpdate>
    private let owner: SFTPDirectoryPump
    private let publication: SFTPBrowserPublication
    private let inPlaceDocuments = SFTPInPlaceDocumentRegistry()
    public var managedInPlaceDocuments: [SFTPInPlaceDocumentSession] { inPlaceDocuments.values }
    private let originalDocuments = SFTPOriginalDocumentRegistry()
    public var managedOriginalDocuments: [SFTPOriginalDocumentSession] { originalDocuments.values }
    public var latest: SFTPBrowserUpdate { publication.latest }
    public static func adoptAuthenticated(_ worker: SFTPWorkerSession) async throws -> SFTPBrowserSession {
        try await adoptAuthenticated(worker, exposedDownloads: worker.allowsRequestedDownloads,
                                     exposedFolderDownloads: worker.allowsRequestedFolderDownloads)
    }
    static func adoptAuthenticated(_ worker: SFTPWorkerSession, exposedDownloads: Bool,
                                   exposedFolderDownloads: Bool, exposedTextReads: Bool = false) async throws -> SFTPBrowserSession {
        _ = try await worker.memoryContext(requireAuthenticated: true)
        try await worker.enableDirectoryRecovery()
        return .init(id: worker.review.session, transport: worker, exposedDownloads: exposedDownloads,
                     exposedFolderDownloads: exposedFolderDownloads, exposedTextReads: exposedTextReads)
    }
    init(id: UUID, transport: any SFTPDirectoryTransport, exposedDownloads: Bool = true,
         exposedFolderDownloads: Bool = true, exposedTextReads: Bool = false) {
        self.id = id; allowsFreshUploads = transport.allowsFreshUploads; allowsFreshFolderUploads = transport.allowsFreshFolderUploads
        allowsFolderSizeSummary = transport.allowsFolderSizeSummary
        // Upload/editor worker modes retain private transfer framing. Browser
        // Download entry points use only the separately exposed capability.
        allowsRequestedDownloads = exposedDownloads && transport.allowsRequestedDownloads
        // The worker's transfer framing is broader than this typed parent API.
        // A private Open never turns on binary Download or publication.
        allowsTextRead = exposedTextReads && transport.allowsRequestedDownloads
        allowsRequestedFolderDownloads = exposedFolderDownloads && allowsRequestedDownloads && transport.allowsRequestedFolderDownloads
        allowsOriginalEditing = transport.allowsOriginalEditing; allowsInPlaceEditing = transport.allowsInPlaceEditing
        allowsRemoteActions = transport.allowsRemoteActions
        allowsServerCopy = allowsRemoteActions && transport.allowsServerCopy
        let publication = SFTPBrowserPublication(); self.publication = publication
        updates = publication.events.stream; owner = SFTPDirectoryPump(transport: transport, publication: publication)
    }
    @discardableResult public func navigate(pathUTF8: Data) async throws -> UUID {
        let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
            let result = try await pump.navigate(pathUTF8, request: request)
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }; return result
        } onCancel: { Task { await pump.cancel(request) } }
    }
    public func find(_ query: RemoteDirectoryFindQuery) async throws -> SFTPDirectoryFindResult {
        let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await pump.find(query, request: request)
            try Task.checkCancellation(); return result
        } onCancel: { Task { await pump.cancel(request) } }
    }
    /// Dismissing Properties does not cancel an admitted remote request. The
    /// pump retains ownership through acknowledged cleanup before returning.
    public func summarizeSelectedFolder(_ selection: SFTPFolderSizeSelection) async throws -> RemoteFolderSizeSummary {
        guard allowsFolderSizeSummary else { throw RemoteFolderSizeFailure.unavailable }
        try Task.checkCancellation()
        let result: RemoteFolderSizeSummary
        do { result = try await owner.summarizeSelectedFolder(selection) }
        catch let error as RemoteFolderSizeFailure { throw error }
        catch let error as SFTPBrowserFailure {
            switch error {
            case .busy: throw RemoteFolderSizeFailure.unavailable
            case .stale: throw RemoteFolderSizeFailure.stale
            case .invalidInput: throw RemoteFolderSizeFailure.invalidInput
            default: throw RemoteFolderSizeFailure.connectionLost
            }
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw RemoteFolderSizeFailure.connectionLost }
        try Task.checkCancellation(); return result
    }
    public func page(offset: UInt64, sort: SFTPStoredSort = .name, descending: Bool = false,
                     find: SFTPDirectoryFindResult? = nil) async throws -> SFTPStoredPage {
        let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
            let result = try await pump.page(offset: offset, sort: sort, descending: descending, find: find, request: request)
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }; return result
        } onCancel: { Task { await pump.cancel(request) } }
    }
    public func stopReading() { let pump = owner; Task { await pump.pause() } }
    public func performRemoteAction(_ intent: SFTPRemoteActionIntent,
                                    store: SFTPRemoteActionStore) async throws -> SFTPRemoteActionResult {
        let pump = owner
        return try await withTaskCancellationHandler {
            try await pump.remoteAction(intent, store: store)
        } onCancel: { Task { await pump.cancel(intent.request) } }
    }
    /// Read-only canonical parent observation. It grants no selected-row or
    /// mutation authority; the eventual action is rechecked independently.
    public func observedActionDirectory(for intent: SFTPRemoteActionIntent) async throws -> SFTPDefaultDirectory {
        try await owner.observedActionDirectory(for: intent)
    }
    /// Explicit Edit in the connection's already-selected M/N capability.
    public func openInPlaceText(_ selection: SFTPDownloadSelection, storage: SFTPInPlaceWorkingCopyStorage) async throws -> SFTPInPlaceDocumentSession {
        guard allowsInPlaceEditing, selection.logicalBytes <= 1 << 20 else { throw SFTPTextFailure.unsupported }
        guard case .baseline(let baseline) = try await inPlace(.read(selection, storage)) else { throw SFTPSessionFailure.output }
        if Task.isCancelled { _ = await close(); throw SFTPTextFailure.stopped }
        let document = SFTPInPlaceDocumentSession(browser: self, baseline: baseline, storage: storage)
        do { try inPlaceDocuments.insert(document) } catch { _ = await close(); throw error }; return document
    }
    func inPlaceDocumentDidClose(_ id: UUID) { inPlaceDocuments.remove(id) }
    func saveInPlace(_ baseline: SFTPInPlaceBaseline, snapshot: SFTPEditedTextSnapshot, journal: SFTPInPlaceJournal) async throws -> SFTPInPlaceSaveCompletion {
        guard case .saved(let value) = try await inPlace(.save(baseline, snapshot, journal)) else { throw SFTPSessionFailure.output }; return value
    }
    func releaseInPlace(_ release: SFTPInPlaceRelease) async throws -> SFTPInPlaceCloseResult {
        guard case .closed(let value) = try await inPlace(.release(release)) else { throw SFTPSessionFailure.output }; return value
    }
    private func inPlace(_ operation: SFTPInPlaceBrowserOperation) async throws -> SFTPInPlaceBrowserReply {
        guard allowsInPlaceEditing else { throw SFTPBrowserFailure.unavailable }; let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); return try await pump.inPlace(operation, request: request)
        } onCancel: { Task { await pump.cancel(request) } }
    }
    /// Explicit Edit only. A row selection or ordinary open does not call it.
    /// K/L admission and shared-budget qualification remain separate gates.
    public func openOriginalText(_ selection: SFTPDownloadSelection,
                                 storage: SFTPOriginalWorkingCopyStorage) async throws -> SFTPOriginalDocumentSession {
        guard allowsOriginalEditing, selection.logicalBytes <= 1 << 20 else { throw SFTPTextFailure.unsupported }
        guard case .baseline(let baseline) = try await original(.read(selection, storage)) else { throw SFTPSessionFailure.output }
        if Task.isCancelled { _ = await close(); throw SFTPTextFailure.stopped }
        let document = SFTPOriginalDocumentSession(browser: self, baseline: baseline, storage: storage)
        do { try originalDocuments.insert(document) }
        catch { _ = await close(); throw error }
        return document
    }
    func originalDocumentDidClose(_ id: UUID) { originalDocuments.remove(id) }
    func saveOriginal(_ baseline: SFTPOriginalBaseline, snapshot: SFTPEditedTextSnapshot,
                      journal: SFTPOriginalJournal) async throws -> SFTPOriginalSaveCompletion {
        guard case .saved(let completion) = try await original(.save(baseline, snapshot, journal)) else { throw SFTPSessionFailure.output }
        return completion
    }
    func releaseOriginal(_ close: SFTPOriginalBaselineClose) async throws -> SFTPOriginalBaselineCloseCompletion {
        guard case .closed(let completion) = try await original(.release(close)) else { throw SFTPSessionFailure.output }
        return completion
    }
    private func original(_ operation: SFTPOriginalBrowserOperation) async throws -> SFTPOriginalBrowserReply {
        guard allowsOriginalEditing else { throw SFTPBrowserFailure.unavailable }
        let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await pump.original(operation, request: request)
        } onCancel: { Task { await pump.cancel(request) } }
    }
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
    public func prepareFolderDownload(_ selection: SFTPFolderDownloadSelection,
        progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)? = nil) async throws -> SFTPPreparedFolderDownload {
        guard allowsRequestedFolderDownloads else { throw SFTPBrowserFailure.unavailable }
        let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
            do {
                let value = try await pump.prepareFolder(selection, request: request, progress: progress)
                guard !Task.isCancelled else { _ = await pump.close(); throw SFTPBrowserFailure.stopped }; return value
            } catch {
                if Task.isCancelled { await pump.cancel(request); _ = await pump.close() }; throw error
            }
        } onCancel: { Task { await pump.cancel(request) } }
    }
    public func releaseFolderDownload(_ prepared: SFTPPreparedFolderDownload) async throws {
        let request = UUID(), pump = owner
        try await withTaskCancellationHandler {
            try await pump.releaseFolder(prepared, request: request)
        } onCancel: { Task { await pump.cancel(request) } }
    }
    public func downloadFolder(_ prepared: SFTPPreparedFolderDownload, storage: SFTPDownloadStorage,
        progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)? = nil) async throws -> SFTPReceivedFolderDownload {
        guard allowsRequestedFolderDownloads else { throw SFTPBrowserFailure.unavailable }
        let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
            do {
                let value = try await pump.receiveFolder(prepared, storage: storage, request: request, progress: progress)
                if Task.isCancelled { _ = await pump.close(); await value.retainForReview(); throw SFTPBrowserFailure.stopped }
                return value
            } catch {
                if Task.isCancelled { await pump.cancel(request); _ = await pump.close() }
                if let local = error as? RemoteDownloadStorageFailure { throw SFTPDownloadStorageIssue(local) }
                throw error
            }
        } onCancel: { Task { await pump.cancel(request) } }
    }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
    public func download(_ selection: SFTPDownloadSelection, storage: SFTPDownloadStorage,
                         progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> SFTPReceivedDownload {
        guard allowsRequestedDownloads else { throw SFTPBrowserFailure.unavailable }
        let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
            do {
                let value = try await pump.download(selection, storage: storage, progress: progress, request: request)
                if Task.isCancelled {
                    _ = await pump.close(); await value.retainForReview(); throw SFTPBrowserFailure.stopped
                }
                return value
            } catch {
                if Task.isCancelled { await pump.cancel(request); await pump.drainCancelledDownload() }
                if let local = error as? RemoteDownloadStorageFailure { throw SFTPDownloadStorageIssue(local) }
                if let pool = error as? SMBTemporaryStorageFailure { throw SFTPDownloadStorageIssue(pool) }
                throw error
            }
        } onCancel: { Task { await pump.cancel(request) } }
    }
    public func downloadBatch(_ plan: SFTPDownloadBatchPlan, storage: SFTPDownloadStorage,
                              progress: (@Sendable (SFTPDownloadBatchProgress) -> Void)? = nil) async throws -> SFTPDownloadBatchReceived {
        guard allowsRequestedDownloads else { throw SFTPBrowserFailure.unavailable }
        let request = UUID(), pump = owner, control = SFTPDownloadBatchControl()
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
            do {
                let result = try await pump.downloadBatch(plan, storage: storage, control: control, progress: progress, request: request)
                if Task.isCancelled {
                    _ = await pump.close(); await result.retainForReview()
                    throw SFTPDownloadBatchInterruption(completedFiles: result.items.count, totalFiles: result.items.count,
                        completedBytes: result.logicalBytes, retainedFileIDs: result.items.map { $0.download.id },
                        currentMayHaveStarted: false, cause: SFTPBrowserFailure.stopped, connectionFailed: false)
                }
                return result
            } catch {
                if Task.isCancelled {
                    await pump.cancel(request)
                    if control.started { _ = await pump.close() } else { await pump.drainCancelledDownload() }
                }
                if let interruption = error as? SFTPDownloadBatchInterruption {
                    if let local = interruption.cause as? RemoteDownloadStorageFailure {
                        throw interruption.replacingCause(SFTPDownloadStorageIssue(local))
                    }
                    if let pool = interruption.cause as? SMBTemporaryStorageFailure {
                        throw interruption.replacingCause(SFTPDownloadStorageIssue(pool))
                    }
                }
                throw error
            }
        } onCancel: { control.cancel(); Task { await pump.cancel(request) } }
    }
    var downloadState: (queued: Bool, active: Bool) { get async { await owner.downloadState } }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
    public func upload(_ selection: SFTPRequestedUpload, storage: SFTPUploadStorage, excluding roots: [URL],
                       progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> SFTPCompletedUpload {
        guard allowsFreshUploads else { throw SFTPBrowserFailure.unavailable }
        let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
            do {
                let result = try await pump.upload(selection, storage: storage, roots: roots, progress: progress, request: request)
                guard !Task.isCancelled else { _ = await pump.close(); throw SFTPBrowserFailure.stopped }; return result
            } catch {
                if Task.isCancelled { await pump.cancel(request); await pump.drainCancelledUpload() }
                if let local = error as? SFTPUploadSourceFailure { throw SFTPUploadLocalIssue(local) }
                if let local = error as? RemoteSettingsFailure { throw SFTPUploadLocalIssue(local) }
                throw error
            }
        } onCancel: { Task { await pump.cancel(request) } }
    }
    var uploadState: (queued: Bool, active: Bool) { get async { await owner.uploadState } }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
    public func uploadFolder(_ selection: SFTPRequestedFolderUpload, storage: SFTPUploadStorage, excluding roots: [URL],
                             progress: (@Sendable (UInt64, Int) -> Void)? = nil) async throws -> SFTPCompletedFolderUpload {
        guard allowsFreshFolderUploads else { throw SFTPBrowserFailure.unavailable }
        let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
            do {
                let result = try await pump.uploadFolder(selection, storage: storage, roots: roots, progress: progress, request: request)
                guard !Task.isCancelled else { _ = await pump.close(); throw SFTPBrowserFailure.stopped }; return result
            } catch {
                if Task.isCancelled { await pump.cancel(request); await pump.drainCancelledUpload() }
                if let local = error as? SFTPUploadSourceFailure { throw SFTPUploadLocalIssue(local) }
                if let local = error as? RemoteSettingsFailure { throw SFTPUploadLocalIssue(local) }; throw error
            }
        } onCancel: { Task { await pump.cancel(request) } }
    }
    #endif
    #if !SFTP_PARENT_STANDALONE
    public func uploadBatch(_ plan: SFTPUploadBatchPlan, generation: UUID, storage: SFTPUploadStorage, excluding roots: [URL],
                            progress: (@Sendable (SFTPUploadBatchProgress) -> Void)? = nil) async throws -> SFTPUploadBatchResult {
        guard plan.items.allSatisfy({ $0.kind == .folder ? allowsFreshFolderUploads : allowsFreshUploads }) else { throw SFTPBrowserFailure.unavailable }
        let request = UUID(), pump = owner, control = SFTPUploadBatchControl()
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
            do {
                let result = try await pump.uploadBatch(plan, generation: generation, storage: storage, roots: roots, control: control, progress: progress, request: request)
                if Task.isCancelled {
                    _ = await pump.close()
                    throw SFTPUploadBatchRunner.interrupted(SFTPBrowserFailure.stopped, completed: result.completed, total: plan.items.count, attempted: false, failed: false)
                }
                return result
            } catch {
                if Task.isCancelled {
                    await pump.cancel(request)
                    if control.started { _ = await pump.close() } else { await pump.drainCancelledUpload() }
                }
                throw error
            }
        } onCancel: { control.cancel(); Task { await pump.cancel(request) } }
    }
    #endif
    public func openText(selected: SFTPDownloadSelection, storage: SFTPTextReadStorage) async throws -> SFTPTextReadLease {
        guard allowsTextRead else { throw SFTPBrowserFailure.unavailable }
        return try await readSelectedText(selected, store: storage.downloads.store)
    }
    /// Existing binary-Download callers keep their original exposure gate.
    public func openText(selected: SFTPDownloadSelection, storage: SFTPDownloadStorage) async throws -> SFTPTextReadLease {
        guard allowsRequestedDownloads else { throw SFTPBrowserFailure.unavailable }
        return try await readSelectedText(selected, store: storage.store)
    }
    private func readSelectedText(_ selected: SFTPDownloadSelection, store: RemoteDownloadStore) async throws -> SFTPTextReadLease {
        guard selected.logicalBytes <= 1 << 20 else { throw SFTPTextFailure.unsupported }
        let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
            do {
                let lease = try await pump.openText(selected, store: store, session: id, request: request)
                if Task.isCancelled { _ = await pump.close(); await lease.closeAndDrain(); throw SFTPBrowserFailure.stopped }
                return lease
            }
            catch {
                if Task.isCancelled { await pump.cancel(request); await pump.drainCancelledDownload() }
                if let issue = error as? RemoteDownloadStorageFailure { throw SFTPDownloadStorageIssue(issue) }
                if let issue = error as? SMBTemporaryStorageFailure { throw SFTPDownloadStorageIssue(issue) }
                throw error
            }
        } onCancel: { Task { await pump.cancel(request) } }
    }
    public func uploadEditedText(_ selection: SFTPRequestedEditedTextUpload, storage: SFTPUploadStorage,
        progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> SFTPTextFreshCopyReceipt {
        guard allowsFreshUploads else { throw SFTPBrowserFailure.unavailable }
        let request = UUID(), pump = owner
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
            do {
                let result = try await pump.uploadEditedText(selection, storage: storage, progress: progress, request: request)
                guard !Task.isCancelled else { _ = await pump.close(); throw SFTPBrowserFailure.stopped }; return result
            }
            catch {
                if Task.isCancelled { await pump.cancel(request); await pump.drainCancelledUpload() }
                throw error
            }
        } onCancel: { Task { await pump.cancel(request) } }
    }
    public func close() async -> SFTPWorkerClose { await owner.close() }
    var queueState: (navigation: Bool, pages: Int, active: Bool) { get async { await owner.queueState } }
    deinit { let pump = owner; Task { _ = await pump.close() } }
}

private final class SFTPBrowserPublication: @unchecked Sendable {
    let events = AsyncStream.makeStream(of: SFTPBrowserUpdate.self, bufferingPolicy: .bufferingNewest(1))
    private let lock = NSLock()
    private var value = SFTPBrowserUpdate(generation: nil, snapshot: nil, paused: false, reading: false, failure: nil)
    var latest: SFTPBrowserUpdate { lock.withLock { value } }
    func publish(_ update: SFTPBrowserUpdate, notify: Bool) { lock.withLock { value = update }; if notify { events.continuation.yield(update) } }
}

private enum SFTPInPlaceBrowserOperation: Sendable {
    case read(SFTPDownloadSelection, SFTPInPlaceWorkingCopyStorage), save(SFTPInPlaceBaseline, SFTPEditedTextSnapshot, SFTPInPlaceJournal), release(SFTPInPlaceRelease)
}
private enum SFTPInPlaceBrowserReply: Sendable {
    case baseline(SFTPInPlaceBaseline), saved(SFTPInPlaceSaveCompletion), closed(SFTPInPlaceCloseResult)
}
private enum SFTPOriginalBrowserOperation: Sendable {
    case read(SFTPDownloadSelection, SFTPOriginalWorkingCopyStorage)
    case save(SFTPOriginalBaseline, SFTPEditedTextSnapshot, SFTPOriginalJournal)
    case release(SFTPOriginalBaselineClose)
}
private enum SFTPOriginalBrowserReply: Sendable {
    case baseline(SFTPOriginalBaseline), saved(SFTPOriginalSaveCompletion), closed(SFTPOriginalBaselineCloseCompletion)
}
private actor SFTPDirectoryPump {
    private enum Job {
        case inPlace(UUID, SFTPInPlaceBrowserOperation, CheckedContinuation<SFTPInPlaceBrowserReply, Error>)
        case original(UUID, SFTPOriginalBrowserOperation, CheckedContinuation<SFTPOriginalBrowserReply, Error>)
        case navigation(UUID, String, CheckedContinuation<UUID, Error>)
        case find(UUID, RemoteDirectoryFindQuery, CheckedContinuation<SFTPDirectoryFindResult, Error>)
        case folderSize(SFTPFolderSizeSelection, CheckedContinuation<RemoteFolderSizeSummary, Error>)
        case page(UUID, UInt64, SFTPStoredSort, Bool, SFTPDirectoryFindResult?, CheckedContinuation<SFTPStoredPage, Error>)
        case remoteAction(SFTPRemoteActionIntent, SFTPRemoteActionStore, CheckedContinuation<SFTPRemoteActionResult, Error>)
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
        case prepareFolder(UUID, SFTPFolderDownloadSelection, (@Sendable (SFTPFolderDownloadProgress) -> Void)?, CheckedContinuation<SFTPPreparedFolderDownload, Error>)
        case releaseFolder(UUID, SFTPPreparedFolderDownload, CheckedContinuation<Void, Error>)
        case receiveFolder(UUID, SFTPPreparedFolderDownload, SFTPDownloadStorage, (@Sendable (SFTPFolderDownloadProgress) -> Void)?, CheckedContinuation<SFTPReceivedFolderDownload, Error>)
        #endif
        #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
        case download(UUID, SFTPDownloadSelection, SFTPDownloadStorage, (@Sendable (UInt64) -> Void)?, CheckedContinuation<SFTPReceivedDownload, Error>)
        case downloadBatch(UUID, SFTPDownloadBatchPlan, SFTPDownloadStorage, SFTPDownloadBatchControl, (@Sendable (SFTPDownloadBatchProgress) -> Void)?, CheckedContinuation<SFTPDownloadBatchReceived, Error>)
        case textRead(UUID, UUID, SFTPDownloadSelection, RemoteDownloadStore, CheckedContinuation<SFTPTextReadLease, Error>)
        #endif
        #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
        case upload(UUID, SFTPRequestedUpload, SFTPUploadStorage, [URL], (@Sendable (UInt64) -> Void)?, CheckedContinuation<SFTPCompletedUpload, Error>)
        case editedUpload(UUID, SFTPRequestedEditedTextUpload, SFTPUploadStorage, (@Sendable (UInt64) -> Void)?, CheckedContinuation<SFTPTextFreshCopyReceipt, Error>)
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
        case folderUpload(UUID, SFTPRequestedFolderUpload, SFTPUploadStorage, [URL], (@Sendable (UInt64, Int) -> Void)?, CheckedContinuation<SFTPCompletedFolderUpload, Error>)
        #endif
        #endif
        #if !SFTP_PARENT_STANDALONE
        case uploadBatch(UUID, SFTPUploadBatchPlan, UUID, SFTPUploadStorage, [URL], SFTPUploadBatchControl, (@Sendable (SFTPUploadBatchProgress) -> Void)?, CheckedContinuation<SFTPUploadBatchResult, Error>)
        #endif
        var id: UUID { switch self {
        case .inPlace(let id, _, _): id
        case .original(let id, _, _): id
        case let .navigation(id, _, _), let .find(id, _, _), let .page(id, _, _, _, _, _): id
        case .folderSize(let selection, _): selection.request
        case let .remoteAction(intent, _, _): intent.request
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
        case let .prepareFolder(id, _, _, _), let .releaseFolder(id, _, _), let .receiveFolder(id, _, _, _, _): id
        #endif
        #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
        case let .download(id, _, _, _, _): id
        case let .downloadBatch(id, _, _, _, _, _): id
        case let .textRead(id, _, _, _, _): id
        #endif
        #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
        case let .upload(id, _, _, _, _, _): id
        case let .editedUpload(id, _, _, _, _): id
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
        case let .folderUpload(id, _, _, _, _, _): id
        #endif
        #endif
        #if !SFTP_PARENT_STANDALONE
        case let .uploadBatch(id, _, _, _, _, _, _, _): id
        #endif
        } }
        var isCatalogQuery: Bool {
            switch self { case .find, .page, .folderSize: true; default: false }
        }
        func fail(_ error: Error) {
            switch self {
            case .inPlace(_, _, let continuation): continuation.resume(throwing: error)
            case .original(_, _, let continuation): continuation.resume(throwing: error)
            case let .navigation(_, _, continuation): continuation.resume(throwing: error)
            case let .find(_, _, continuation): continuation.resume(throwing: error)
            case .folderSize(_, let continuation): continuation.resume(throwing: error)
            case let .page(_, _, _, _, _, continuation): continuation.resume(throwing: error)
            case let .remoteAction(_, _, continuation): continuation.resume(throwing: error)
            #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
            case let .prepareFolder(_, _, _, continuation): continuation.resume(throwing: error)
            case let .releaseFolder(_, _, continuation): continuation.resume(throwing: error)
            case let .receiveFolder(_, _, _, _, continuation): continuation.resume(throwing: error)
            #endif
            #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
            case let .download(_, _, _, _, continuation): continuation.resume(throwing: error)
            case let .downloadBatch(_, _, _, _, _, continuation): continuation.resume(throwing: error)
            case let .textRead(_, _, _, _, continuation): continuation.resume(throwing: error)
            #endif
            #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
            case let .upload(_, _, _, _, _, continuation): continuation.resume(throwing: error)
            case let .editedUpload(_, _, _, _, continuation): continuation.resume(throwing: error)
            #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
            case let .folderUpload(_, _, _, _, _, continuation): continuation.resume(throwing: error)
            #endif
            #endif
            #if !SFTP_PARENT_STANDALONE
            case let .uploadBatch(_, _, _, _, _, _, _, continuation): continuation.resume(throwing: error)
            #endif
            }
        }
    }
    private let transport: any SFTPDirectoryTransport
    private let publication: SFTPBrowserPublication
    private var queuedNavigation: Job?, pages: [Job] = [], active: Job?
    private var queuedInPlace: Job?
    private var queuedOriginal: Job?
    private var queuedRemoteAction: Job?
    private var hasRemoteAction: Bool {
        if queuedRemoteAction != nil { return true }
        if case .remoteAction = active { return true }
        return false
    }
    func observedActionDirectory(for intent: SFTPRemoteActionIntent) async throws -> SFTPDefaultDirectory {
        guard transport.allowsRemoteActions,
              intent.kind != .copyFile || transport.allowsServerCopy else { throw SFTPBrowserFailure.unavailable }
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard generation == intent.generation, snapshot == intent.snapshot,
              intent.snapshot.state == .complete else { throw SFTPBrowserFailure.stale }
        guard !reading, active == nil, pages.isEmpty, queuedNavigation == nil, !hasRemoteAction,
              !hasOriginal, !hasFolder, !hasDownload, !hasUpload else { throw SFTPBrowserFailure.busy }
        let observed: SFTPDefaultDirectory
        do { observed = try await transport.observedActionDirectory(for: intent) }
        catch SFTPProtocolFailure.stale { throw SFTPBrowserFailure.stale }
        catch SFTPProtocolFailure.phase { throw SFTPBrowserFailure.busy }
        catch SFTPSessionFailure.busy { throw SFTPBrowserFailure.busy }
        catch SFTPSessionFailure.stopped { throw SFTPBrowserFailure.stopped }
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard generation == intent.generation, snapshot == intent.snapshot,
              !reading, active == nil, pages.isEmpty, queuedNavigation == nil, !hasRemoteAction,
              !hasOriginal, !hasFolder, !hasDownload, !hasUpload else {
            throw SFTPBrowserFailure.stale
        }
        guard observed.root == .server else { throw SFTPBrowserFailure.security }
        return observed
    }
    func remoteAction(_ intent: SFTPRemoteActionIntent, store: SFTPRemoteActionStore) async throws -> SFTPRemoteActionResult {
        guard transport.allowsRemoteActions else { throw SFTPBrowserFailure.unavailable }
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard generation == intent.generation, snapshot == intent.snapshot,
              intent.snapshot.state == .complete else { throw SFTPBrowserFailure.stale }
        guard !hasRemoteAction, queuedNavigation == nil, !hasOriginal, !hasFolder,
              !hasDownload, !hasUpload else { throw SFTPBrowserFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queuedRemoteAction = .remoteAction(intent, store, continuation); start()
        }
    }
    private var hasOriginal: Bool {
        if queuedOriginal != nil || queuedInPlace != nil { return true }
        if case .inPlace = active { return true }
        if case .original = active { return true }
        return false
    }
    func inPlace(_ operation: SFTPInPlaceBrowserOperation, request: UUID) async throws -> SFTPInPlaceBrowserReply {
        guard transport.allowsInPlaceEditing else { throw SFTPBrowserFailure.unavailable }
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard !hasOriginal else { throw SFTPInPlaceAdmissionFailure(reason: .browserEditorBusy) }
        guard !hasFolder else { throw SFTPInPlaceAdmissionFailure(reason: .browserFolderBusy) }
        guard !hasDownload else { throw SFTPInPlaceAdmissionFailure(reason: .browserDownloadBusy) }
        guard !hasUpload else { throw SFTPInPlaceAdmissionFailure(reason: .browserUploadBusy) }
        guard queuedNavigation == nil else { throw SFTPInPlaceAdmissionFailure(reason: .browserNavigationBusy) }
        if case .read(let selection, _) = operation {
            guard selection.generation == generation, snapshot?.state == .complete else { throw SFTPBrowserFailure.stale }
        }
        return try await withCheckedThrowingContinuation { continuation in queuedInPlace = .inPlace(request, operation, continuation); start() }
    }
    func original(_ operation: SFTPOriginalBrowserOperation, request: UUID) async throws -> SFTPOriginalBrowserReply {
        guard transport.allowsOriginalEditing else { throw SFTPBrowserFailure.unavailable }
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard !hasOriginal, !hasFolder, !hasDownload, !hasUpload, queuedNavigation == nil else { throw SFTPBrowserFailure.busy }
        if case .read(let selection, _) = operation {
            guard selection.generation == generation, snapshot?.state == .complete else { throw SFTPBrowserFailure.stale }
        }
        return try await withCheckedThrowingContinuation { continuation in
            queuedOriginal = .original(request, operation, continuation); start()
        }
    }
    private var hasFolder: Bool {
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
        if reservedFolder != nil || queuedFolder != nil { return true }
        switch active { case .prepareFolder, .receiveFolder, .releaseFolder: return true; default: return false }
        #else
        false
        #endif
    }
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
    private var queuedFolder: Job?, reservedFolder: SFTPPreparedFolderDownload?
    private var undrainedTrees: [RemoteDownloadedTree] = []
    func prepareFolder(_ selection: SFTPFolderDownloadSelection, request: UUID,
        progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPPreparedFolderDownload {
        guard transport.allowsRequestedFolderDownloads else { throw SFTPBrowserFailure.unavailable }
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard selection.generation == generation, selection.read == snapshot?.read, selection.revision == snapshot?.revision,
              snapshot?.state == .complete else { throw SFTPBrowserFailure.stale }
        guard !hasFolder, !hasDownload, !hasUpload, active == nil, pages.isEmpty, queuedNavigation == nil else { throw SFTPBrowserFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queuedFolder = .prepareFolder(request, selection, progress, continuation); start()
        }
    }
    func releaseFolder(_ prepared: SFTPPreparedFolderDownload, request: UUID) async throws {
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard reservedFolder?.selection == prepared.selection, reservedFolder?.manifest == prepared.manifest,
              queuedFolder == nil, active == nil else { throw SFTPBrowserFailure.stale }
        try await withCheckedThrowingContinuation { continuation in queuedFolder = .releaseFolder(request, prepared, continuation); start() }
    }
    func receiveFolder(_ prepared: SFTPPreparedFolderDownload, storage: SFTPDownloadStorage, request: UUID,
        progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPReceivedFolderDownload {
        guard transport.allowsRequestedFolderDownloads else { throw SFTPBrowserFailure.unavailable }
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard reservedFolder?.selection == prepared.selection, reservedFolder?.manifest == prepared.manifest,
              queuedFolder == nil, active == nil else { throw SFTPBrowserFailure.stale }
        return try await withCheckedThrowingContinuation { continuation in queuedFolder = .receiveFolder(request, prepared, storage, progress, continuation); start() }
    }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
    private var queuedDownload: Job?
    var downloadState: (queued: Bool, active: Bool) {
        if case .download = active { return (queuedDownload != nil, true) }
        if case .downloadBatch = active { return (queuedDownload != nil, true) }
        if case .textRead = active { return (queuedDownload != nil, true) }
        return (queuedDownload != nil, false)
    }
    private var hasDownloadBatch: Bool {
        if case .downloadBatch = queuedDownload { return true }
        if case .downloadBatch = active { return true }
        return false
    }
    func drainCancelledDownload() async { if closed { _ = await close() } }
    func openText(_ selection: SFTPDownloadSelection, store: RemoteDownloadStore, session: UUID, request: UUID) async throws -> SFTPTextReadLease {
        guard selection.logicalBytes <= 1 << 20 else { throw SFTPTextFailure.unsupported }
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard transport.allowsRequestedDownloads else { throw SFTPBrowserFailure.unavailable }
        guard selection.generation == generation, snapshot?.state == .complete else { throw SFTPBrowserFailure.stale }
        guard queuedNavigation == nil, !hasDownload, !hasUpload, !hasFolder else { throw SFTPBrowserFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queuedDownload = .textRead(request, session, selection, store, continuation); start()
        }
    }
    func download(_ selection: SFTPDownloadSelection, storage: SFTPDownloadStorage,
                  progress: (@Sendable (UInt64) -> Void)?, request: UUID) async throws -> SFTPReceivedDownload {
        guard transport.allowsRequestedDownloads else { throw SFTPBrowserFailure.unavailable }
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard selection.generation == generation, snapshot?.state == .complete else { throw SFTPBrowserFailure.stale }
        guard queuedNavigation == nil, !downloadState.queued, !downloadState.active, !hasUpload, !hasFolder else { throw SFTPBrowserFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queuedDownload = .download(request, selection, storage, progress, continuation); start()
        }
    }
    func downloadBatch(_ plan: SFTPDownloadBatchPlan, storage: SFTPDownloadStorage, control: SFTPDownloadBatchControl,
                       progress: (@Sendable (SFTPDownloadBatchProgress) -> Void)?, request: UUID) async throws -> SFTPDownloadBatchReceived {
        guard transport.allowsRequestedDownloads else { throw SFTPBrowserFailure.unavailable }
        guard !closed, !failed, !Task.isCancelled, !control.cancelled else { throw SFTPBrowserFailure.stopped }
        guard plan.generation == generation, snapshot == plan.snapshot, plan.snapshot.state == .complete else { throw SFTPBrowserFailure.stale }
        guard queuedNavigation == nil, !hasDownload, !hasUpload, !hasFolder, !hasOriginal else { throw SFTPBrowserFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queuedDownload = .downloadBatch(request, plan, storage, control, progress, continuation); start()
        }
    }
    private func requireDownloadBatchCurrent(_ plan: SFTPDownloadBatchPlan, request: UUID,
                                             control: SFTPDownloadBatchControl) throws {
        guard !closed, !cancelled.contains(request), !control.cancelled else { throw SFTPBrowserFailure.stopped }
        guard generation == plan.generation, snapshot == plan.snapshot, plan.snapshot.state == .complete else { throw SFTPBrowserFailure.stale }
    }
    #endif
    private var hasUpload: Bool {
        #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
        return uploadState.queued || uploadState.active
        #else
        return false
        #endif
    }
    private var hasDownload: Bool {
        #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
        return downloadState.queued || downloadState.active
        #else
        return false
        #endif
    }
    #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
    private var queuedUpload: Job?
    var uploadState: (queued: Bool, active: Bool) {
        if case .upload = active { return (queuedUpload != nil, true) }
        if case .editedUpload = active { return (queuedUpload != nil, true) }
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
        if case .folderUpload = active { return (queuedUpload != nil, true) }
        #endif
        #if !SFTP_PARENT_STANDALONE
        if case .uploadBatch = active { return (queuedUpload != nil, true) }
        #endif
        return (queuedUpload != nil, false)
    }
    func drainCancelledUpload() async { if closed { _ = await close() } }
    func uploadEditedText(_ selection: SFTPRequestedEditedTextUpload, storage: SFTPUploadStorage,
        progress: (@Sendable (UInt64) -> Void)?, request: UUID) async throws -> SFTPTextFreshCopyReceipt {
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard transport.allowsFreshUploads else { throw SFTPBrowserFailure.unavailable }
        guard selection.destinationGeneration == generation, snapshot?.state == .complete else { throw SFTPBrowserFailure.stale }
        guard queuedNavigation == nil, !hasUpload, !hasDownload, !hasFolder else { throw SFTPBrowserFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queuedUpload = .editedUpload(request, selection, storage, progress, continuation); start()
        }
    }
    func upload(_ selection: SFTPRequestedUpload, storage: SFTPUploadStorage, roots: [URL],
                progress: (@Sendable (UInt64) -> Void)?, request: UUID) async throws -> SFTPCompletedUpload {
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard transport.allowsFreshUploads else { throw SFTPBrowserFailure.unavailable }
        guard selection.generation == generation, snapshot?.state == .complete else { throw SFTPBrowserFailure.stale }
        guard queuedNavigation == nil, !hasUpload, !hasDownload, !hasFolder else { throw SFTPBrowserFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queuedUpload = .upload(request, selection, storage, roots, progress, continuation); start()
        }
    }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
    func uploadFolder(_ selection: SFTPRequestedFolderUpload, storage: SFTPUploadStorage, roots: [URL],
                      progress: (@Sendable (UInt64, Int) -> Void)?, request: UUID) async throws -> SFTPCompletedFolderUpload {
        guard !closed, !failed, !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard transport.allowsFreshFolderUploads else { throw SFTPBrowserFailure.unavailable }
        guard selection.generation == generation, snapshot?.state == .complete else { throw SFTPBrowserFailure.stale }
        guard queuedNavigation == nil, !hasUpload, !hasDownload, !hasFolder else { throw SFTPBrowserFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queuedUpload = .folderUpload(request, selection, storage, roots, progress, continuation); start()
        }
    }
    #endif
    #if !SFTP_PARENT_STANDALONE
    func uploadBatch(_ plan: SFTPUploadBatchPlan, generation requested: UUID, storage: SFTPUploadStorage, roots: [URL],
                     control: SFTPUploadBatchControl, progress: (@Sendable (SFTPUploadBatchProgress) -> Void)?, request: UUID) async throws -> SFTPUploadBatchResult {
        guard !closed, !failed, !Task.isCancelled, !control.cancelled else { throw SFTPBrowserFailure.stopped }
        guard plan.items.allSatisfy({ $0.kind == .folder ? transport.allowsFreshFolderUploads : transport.allowsFreshUploads }) else { throw SFTPBrowserFailure.unavailable }
        guard requested == generation, snapshot?.state == .complete else { throw SFTPBrowserFailure.stale }
        guard queuedNavigation == nil, !hasUpload, !hasDownload, !hasFolder else { throw SFTPBrowserFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queuedUpload = .uploadBatch(request, plan, requested, storage, roots, control, progress, continuation); start()
        }
    }
    private func requireBatchCurrent(_ requested: UUID, snapshot observed: SFTPStoredSnapshot, request: UUID, control: SFTPUploadBatchControl) throws {
        guard !closed, !cancelled.contains(request), !control.cancelled else { throw SFTPBrowserFailure.stopped }
        guard requested == generation, snapshot == observed, observed.state == .complete else { throw SFTPBrowserFailure.stale }
    }
    #endif
    private var cancelled = Set<UUID>(), generation: UUID?, snapshot: SFTPStoredSnapshot?
    private var paused = false, closed = false, failed = false, reading = false
    private var lastNotification = ContinuousClock.now, lastPublishedGeneration: UUID?
    private var lastPublishedCount: UInt64 = 0
    private var lastDirectoryReadMilliseconds: Double?
    private var lastDirectoryResponseAt: Date?
    private var task: Task<Void, Never>?, closing: Task<SFTPWorkerClose, Never>?
    private var wake: CheckedContinuation<Bool, Never>?, idleClock: Task<Void, Never>?
    init(transport: any SFTPDirectoryTransport, publication: SFTPBrowserPublication) { self.transport = transport; self.publication = publication }
    var queueState: (navigation: Bool, pages: Int, active: Bool) { (queuedNavigation != nil, pages.count, active != nil) }
    func navigate(_ path: Data, request: UUID) async throws -> UUID {
        guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard !closed, !failed else { throw SFTPBrowserFailure.stopped }
        guard !path.isEmpty, path.count <= 8192, !path.contains(0), let text = String(data: path, encoding: .utf8), Data(text.utf8) == path else { throw SFTPBrowserFailure.invalidInput }
        if text != "." && text != "/" {
            let remainder: Substring
            if text.hasPrefix("./") { remainder = text.dropFirst(2) }
            else if text.hasPrefix("/") { remainder = text.dropFirst() }
            else { throw SFTPBrowserFailure.invalidInput }
            let parts = remainder.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count <= 128 else { throw SFTPBrowserFailure.invalidInput }
            for part in parts { guard (try? SFTPRemoteName(Data(part.utf8))) != nil else { throw SFTPBrowserFailure.invalidInput } }
        }
        #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
        guard !hasDownloadBatch else { throw SFTPBrowserFailure.busy }
        #endif
        guard queuedNavigation == nil, !hasFolder else { throw SFTPBrowserFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queuedNavigation = .navigation(request, text, continuation); start()
        }
    }
    func find(_ query: RemoteDirectoryFindQuery, request: UUID) async throws -> SFTPDirectoryFindResult {
        guard !Task.isCancelled, !closed, !failed else { throw SFTPBrowserFailure.stopped }
        guard generation != nil, snapshot != nil else { throw RemoteDirectoryFindFailure.stale }
        let anotherSize = ([active].compactMap { $0 } + pages).contains { job in
            if case .folderSize = job { return true }; return false
        }
        guard pages.count < 4, !hasFolder, !anotherSize else { throw SFTPBrowserFailure.busy }
        #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
        guard !hasDownloadBatch else { throw SFTPBrowserFailure.busy }
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            pages.append(.find(request, query, continuation)); start()
        }
    }
    func summarizeSelectedFolder(_ selection: SFTPFolderSizeSelection) async throws -> RemoteFolderSizeSummary {
        guard !Task.isCancelled, !closed, !failed else { throw RemoteFolderSizeFailure.connectionLost }
        guard selection.generation == generation, selection.snapshot == snapshot else { throw RemoteFolderSizeFailure.stale }
        guard pages.count < 4, !hasFolder else { throw SFTPBrowserFailure.busy }
        #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
        guard !hasDownloadBatch else { throw SFTPBrowserFailure.busy }
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            pages.append(.folderSize(selection, continuation)); start()
        }
    }
    func page(offset: UInt64, sort: SFTPStoredSort, descending: Bool, find: SFTPDirectoryFindResult?, request: UUID) async throws -> SFTPStoredPage {
        guard !Task.isCancelled else { throw SFTPBrowserFailure.stopped }
        guard !closed, !failed else { throw SFTPBrowserFailure.stopped }
        guard generation != nil, let snapshot else { throw SFTPBrowserFailure.unavailable }
        guard find == nil || find?.snapshot == snapshot && find?.generation == generation else { throw RemoteDirectoryFindFailure.stale }
        guard offset < (find?.count ?? snapshot.count) else { throw SFTPBrowserFailure.invalidInput }
        #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
        guard !hasDownloadBatch else { throw SFTPBrowserFailure.busy }
        #endif
        guard pages.count < 4, !hasFolder else { throw SFTPBrowserFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in pages.append(.page(request, offset, sort, descending, find, continuation)); start() }
    }
    func cancel(_ id: UUID) {
        if let job = queuedRemoteAction, job.id == id {
            queuedRemoteAction = nil; job.fail(SFTPBrowserFailure.stopped); return
        }
        if active?.id == id, case .remoteAction = active {
            cancelled.insert(id); closed = true; Task { _ = await close() }; return
        }
        if let job = queuedInPlace, job.id == id { queuedInPlace = nil; job.fail(SFTPBrowserFailure.stopped); return }
        if active?.id == id, case .inPlace = active { cancelled.insert(id); closed = true; Task { _ = await close() }; return }
        if let job = queuedOriginal, job.id == id { queuedOriginal = nil; job.fail(SFTPBrowserFailure.stopped); return }
        if active?.id == id, case .original = active {
            cancelled.insert(id); closed = true; Task { _ = await close() }; return
        }
        if let job = queuedNavigation, job.id == id { queuedNavigation = nil; job.fail(SFTPBrowserFailure.stopped); return }
        if let index = pages.firstIndex(where: { $0.id == id }) { let job = pages.remove(at: index); job.fail(SFTPBrowserFailure.stopped); return }
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
        if let job = queuedFolder, job.id == id { queuedFolder = nil; job.fail(SFTPBrowserFailure.stopped); return }
        if active?.id == id, hasFolder { cancelled.insert(id); closed = true; Task { _ = await close() }; return }
        #endif
        #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
        if let job = queuedDownload, job.id == id { queuedDownload = nil; job.fail(SFTPBrowserFailure.stopped); return }
        if active?.id == id, case .download = active {
            cancelled.insert(id); closed = true
            // close() owns the actual transport Stop and waits for this pump;
            // the current request continuation is completed by run(), once.
            Task { _ = await close() }; return
        }
        if active?.id == id, case .downloadBatch = active {
            cancelled.insert(id); closed = true; Task { _ = await close() }; return
        }
        if active?.id == id, case .textRead = active {
            cancelled.insert(id); closed = true; Task { _ = await close() }; return
        }
        #endif
        #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
        if let job = queuedUpload, job.id == id { queuedUpload = nil; job.fail(SFTPBrowserFailure.stopped); return }
        if active?.id == id, case .upload = active {
            cancelled.insert(id); closed = true; Task { _ = await close() }; return
        }
        if active?.id == id, case .editedUpload = active {
            cancelled.insert(id); closed = true; Task { _ = await close() }; return
        }
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
        if active?.id == id, case .folderUpload = active {
            cancelled.insert(id); closed = true; Task { _ = await close() }; return
        }
        #endif
        #endif
        #if !SFTP_PARENT_STANDALONE
        if active?.id == id, case .uploadBatch = active {
            cancelled.insert(id); closed = true; Task { _ = await close() }; return
        }
        #endif
        if active?.id == id { cancelled.insert(id) }
    }
    func pause() { paused = true; publish() }
    private func publish(_ failure: SFTPBrowserFailure? = nil, directoryRejection: SFTPDirectoryRejection? = nil) {
        let now = ContinuousClock.now
        let notify = generation != lastPublishedGeneration || failure != nil || paused || snapshot?.state != .loading
            || (snapshot?.count ?? 0) == 0 || lastPublishedCount == 0 || lastNotification.duration(to: now) >= .milliseconds(250)
        publication.publish(.init(generation: generation, snapshot: snapshot, paused: paused, reading: reading,
            failure: failure, directoryRejection: directoryRejection,
            lastDirectoryReadMilliseconds: lastDirectoryReadMilliseconds,
            lastDirectoryResponseAt: lastDirectoryResponseAt), notify: notify)
        if notify { lastNotification = now; lastPublishedGeneration = generation; lastPublishedCount = snapshot?.count ?? 0 }
    }
    private func start() {
        wakeForWork()
        guard task == nil else { return }; task = Task { await run() }
    }
    private func wakeForWork() {
        let pending = wake; wake = nil; idleClock?.cancel(); idleClock = nil; pending?.resume(returning: false)
    }
    private func idleTick() {
        let pending = wake; wake = nil; idleClock = nil; pending?.resume(returning: true)
    }
    private func waitForWorkOrIdle() async -> Bool {
        var clock: Task<Void, Never>?
        let probe = await withCheckedContinuation { continuation in
            wake = continuation
            let timer = Task { [self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }; idleTick()
            }
            clock = timer; idleClock = timer
        }
        await clock?.value // Actual timer drain, including a cancelled sleep.
        return probe
    }
    private func failure(_ error: Error) -> SFTPBrowserFailure {
        switch error as? SFTPSessionFailure {
        case .storage: .storage; case .denied: .denied; case .deadline: .deadline; case .security: .security
        default: error as? SFTPBrowserFailure ?? .remote
        }
    }
    private func run() async {
        defer { task = nil }
        while !closed, !failed {
            var job = queuedNavigation; queuedNavigation = nil
            if job == nil, let value = queuedInPlace { queuedInPlace = nil; job = value }
            if job == nil, let value = queuedOriginal { queuedOriginal = nil; job = value }
            if job == nil, let value = queuedRemoteAction { queuedRemoteAction = nil; job = value }
            #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
            if job == nil, let value = queuedFolder { queuedFolder = nil; job = value }
            #endif
            #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
            if job == nil, let value = queuedDownload { queuedDownload = nil; job = value }
            #endif
            #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
            if job == nil, let value = queuedUpload { queuedUpload = nil; job = value }
            #endif
            if job == nil, !pages.isEmpty { job = pages.removeFirst() }
            if let job {
                active = job
                do {
                    switch job {
                    case .inPlace(let id, let operation, let continuation):
                        guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }
                        switch operation {
                        case .read(let selection, let storage):
                            guard selection.generation == generation, let snapshot, snapshot.state == .complete else { throw SFTPBrowserFailure.stale }
                            let baseline = try await transport.readInPlace(selection, snapshot: snapshot, storage: storage)
                            guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }; continuation.resume(returning: .baseline(baseline))
                        case .save(let baseline, let edited, let journal):
                            let completion = try await transport.saveInPlace(baseline, snapshot: edited, journal: journal)
                            if closed || cancelled.contains(id), case .continued(_, let record) = completion {
                                continuation.resume(returning: .saved(.verifiedRecoveryNeedsAttention(record)))
                            } else { continuation.resume(returning: .saved(completion)) }
                        case .release(let release): continuation.resume(returning: .closed(try await transport.releaseInPlace(release)))
                        }
                        cancelled.remove(id)
                    case .original(let id, let operation, let continuation):
                        guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }
                        switch operation {
                        case .read(let selection, let storage):
                            guard selection.generation == generation, let snapshot, snapshot.state == .complete else { throw SFTPBrowserFailure.stale }
                            let baseline = try await transport.readOriginal(selection, snapshot: snapshot, storage: storage)
                            guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }
                            continuation.resume(returning: .baseline(baseline))
                        case .save(let baseline, let snapshot, let journal):
                            let completion = try await transport.saveOriginal(baseline, snapshot: snapshot, journal: journal)
                            if closed || cancelled.contains(id), case .continued(_, let record) = completion {
                                continuation.resume(returning: .saved(.verifiedRecoveryNeedsAttention(record)))
                            } else { continuation.resume(returning: .saved(completion)) }
                        case .release(let release):
                            continuation.resume(returning: .closed(try await transport.releaseOriginal(release)))
                        }
                        cancelled.remove(id)
                    case let .navigation(id, path, continuation):
                        // Queued pages refer to the preceding visible directory.
                        let old = pages; pages.removeAll(); old.forEach { $0.fail(SFTPBrowserFailure.stale) }
                        let began = ContinuousClock.now
                        let (next, value) = try await transport.openStoredDirectory(path)
                        recordDirectoryRead(since: began)
                        generation = next; snapshot = value
                        let stopped = closed || cancelled.remove(id) != nil; paused = stopped
                        if stopped { continuation.resume(throwing: SFTPBrowserFailure.stopped) }
                        else { continuation.resume(returning: next) }; publish()
                    case let .find(id, query, continuation):
                        guard let generation, let snapshot else { throw RemoteDirectoryFindFailure.stale }
                        let value = try await transport.find(generation, snapshot: snapshot, query: query)
                        if closed || cancelled.remove(id) != nil { continuation.resume(throwing: SFTPBrowserFailure.stopped) }
                        else { continuation.resume(returning: value) }
                    case .folderSize(let selection, let continuation):
                        guard selection.generation == generation, selection.snapshot == snapshot else { throw RemoteFolderSizeFailure.stale }
                        reading = true; publish()
                        defer { reading = false; publish() }
                        let value = try await transport.summarizeSelectedFolder(selection)
                        if closed { continuation.resume(throwing: RemoteFolderSizeFailure.connectionLost) }
                        else { continuation.resume(returning: value) }
                    case let .page(id, offset, sort, descending, find, continuation):
                        guard let generation, let snapshot else { throw SFTPBrowserFailure.stale }
                        guard find == nil || find?.snapshot == snapshot && find?.generation == generation else { throw RemoteDirectoryFindFailure.stale }
                        let value = try await transport.page(generation, snapshot: snapshot, offset: offset, sort: sort, descending: descending, find: find)
                        if closed || cancelled.remove(id) != nil { continuation.resume(throwing: SFTPBrowserFailure.stopped) }
                        else if let value { continuation.resume(returning: value) }
                        else { continuation.resume(throwing: find == nil ? SFTPBrowserFailure.stale : RemoteDirectoryFindFailure.stale) }
                    case let .remoteAction(intent, store, continuation):
                        guard !closed, !cancelled.contains(intent.request),
                              generation == intent.generation, snapshot == intent.snapshot else { throw SFTPBrowserFailure.stale }
                        let result = try await transport.performRemoteAction(intent, store: store)
                        if result.record.outcome == .confirmed || result.record.outcome == .needsReview {
                            generation = nil; snapshot = nil; paused = true; publish()
                        }
                        if result.record.outcome == .needsReview { closed = true }
                        continuation.resume(returning: result); cancelled.remove(intent.request)
                    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
                    case let .prepareFolder(id, selection, progress, continuation):
                        let value = try await transport.prepareFolderDownload(selection, progress: progress)
                        guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }
                        reservedFolder = value; continuation.resume(returning: value)
                    case let .releaseFolder(_, prepared, continuation):
                        try await transport.releaseFolderDownload(prepared); reservedFolder = nil; continuation.resume()
                    case let .receiveFolder(id, prepared, storage, progress, continuation):
                        var tree: RemoteDownloadedTree?, started = false
                        do {
                            guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }
                            let received = try await storage.store.reserveTree(prepared); tree = received
                            guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }
                            started = true
                            let receipt = try await transport.receiveFolderDownload(prepared, into: received, progress: progress)
                            try await received.seal(request: receipt.request, receivedBytes: receipt.bytes, receivedFiles: receipt.files)
                            reservedFolder = nil
                            guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }
                            continuation.resume(returning: .init(received))
                        } catch {
                            if started {
                                let drain = await transport.close()
                                if let tree { if drain.localResourcesEnded { await tree.abandon() } else { undrainedTrees.append(tree) } }
                                reservedFolder = nil
                                if !closed { failed = true; publish(failure(error)) }
                            } else {
                                await tree?.abandon()
                                do { try await transport.releaseFolderDownload(prepared); reservedFolder = nil }
                                catch { failed = true; publish(failure(error)) }
                            }
                            continuation.resume(throwing: error)
                        }
                        cancelled.remove(id)
                    #endif
                    #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
                    case let .textRead(id, session, selection, store, continuation):
                        var file: RemoteDownloadedFile?, text: SFTPTextReadLease?, started = false
                        do {
                            guard !closed, selection.generation == generation, snapshot?.state == .complete else { throw SFTPBrowserFailure.stale }
                            let origin = try await transport.textOrigin(selection)
                            guard origin.session == session else { throw SFTPSessionFailure.security }
                            let received = try await store.reserve(selection); file = received
                            guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }
                            started = true
                            let receipt = try await transport.download(selection, into: received, progress: nil)
                            _ = try await received.seal(receipt)
                            let after = try await transport.textOrigin(selection)
                            guard after.selection == selection else { throw SFTPBrowserFailure.stale }
                            try origin.validate(session: after.session, context: after.context)
                            let lease = try await SFTPTextReadLease.mint(received, origin: origin); text = lease
                            guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }
                            continuation.resume(returning: lease)
                        } catch {
                            if let text { await text.closeAndDrain() } else { _ = await file?.abandon() }
                            if started, !closed { failed = true; publish(failure(error)) }
                            continuation.resume(throwing: error)
                        }
                        cancelled.remove(id)
                    case let .download(id, selection, storage, progress, continuation):
                        var file: RemoteDownloadedFile?, started = false
                        do {
                            guard selection.generation == generation, snapshot?.state == .complete else { throw SFTPBrowserFailure.stale }
                            let received = try await storage.reserveSelected(selection); file = received
                            guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }
                            started = true
                            let receipt = try await transport.download(selection, into: received, progress: progress)
                            _ = try await received.seal(receipt)
                            guard !closed, !cancelled.contains(id) else { throw SFTPBrowserFailure.stopped }
                            continuation.resume(returning: .init(received))
                        } catch {
                            _ = await file?.abandon()
                            if started, !closed { failed = true; publish(failure(error)) }
                            continuation.resume(throwing: error)
                        }
                        cancelled.remove(id)
                    case let .downloadBatch(id, plan, storage, control, progress, continuation):
                        do {
                            try requireDownloadBatchCurrent(plan, request: id, control: control)
                            try control.begin()
                            let result = try await SFTPDownloadBatchRunner.run(plan, transport: transport, storage: storage,
                                requireCurrent: { try await self.requireDownloadBatchCurrent(plan, request: id, control: control) },
                                progress: progress)
                            continuation.resume(returning: result)
                        } catch {
                            if let interruption = error as? SFTPDownloadBatchInterruption,
                               interruption.connectionFailed, !closed {
                                failed = true; publish(failure(interruption.cause))
                            }
                            continuation.resume(throwing: error)
                        }
                        cancelled.remove(id)
                    #endif
                    #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
                    case let .editedUpload(id, selection, storage, progress, continuation):
                        var started = false
                        do {
                            guard !closed, !cancelled.contains(id), selection.destinationGeneration == generation,
                                  let snapshot, snapshot.state == .complete else { throw SFTPBrowserFailure.stale }
                            started = true
                            let result = try await transport.uploadEditedText(selection, snapshot: snapshot, storage: storage, progress: progress)
                            continuation.resume(returning: result)
                        } catch {
                            if started, !closed, !(error is SFTPUploadAdmissionFailure), !(error is SFTPUploadOpenRefusal) { failed = true; publish(failure(error)) }
                            continuation.resume(throwing: (error as? SFTPUploadAdmissionFailure)?.cause ?? error)
                        }
                        cancelled.remove(id)
                    case let .upload(id, selection, storage, roots, progress, continuation):
                        var started = false
                        do {
                            guard !closed, !cancelled.contains(id), selection.generation == generation, let snapshot, snapshot.state == .complete else { throw SFTPBrowserFailure.stale }
                            started = true
                            let result = try await transport.upload(selection, snapshot: snapshot, storage: storage, excluding: roots, progress: progress)
                            continuation.resume(returning: result)
                        } catch {
                            if started, !closed, !(error is SFTPUploadAdmissionFailure), !(error is SFTPUploadOpenRefusal) { failed = true; publish(failure(error)) }
                            continuation.resume(throwing: (error as? SFTPUploadAdmissionFailure)?.cause ?? error)
                        }
                        cancelled.remove(id)
                    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
                    case let .folderUpload(id, selection, storage, roots, progress, continuation):
                        var started = false
                        do {
                            guard !closed, !cancelled.contains(id), selection.generation == generation, let snapshot, snapshot.state == .complete else { throw SFTPBrowserFailure.stale }
                            started = true
                            let result = try await transport.uploadFolder(selection, snapshot: snapshot, storage: storage, excluding: roots, progress: progress)
                            continuation.resume(returning: result)
                        } catch {
                            if started, !closed, !(error is SFTPUploadAdmissionFailure) { failed = true; publish(failure(error)) }
                            continuation.resume(throwing: (error as? SFTPUploadAdmissionFailure)?.cause ?? error)
                        }
                        cancelled.remove(id)
                    #endif
                    #endif
                    #if !SFTP_PARENT_STANDALONE
                    case let .uploadBatch(id, plan, requested, storage, roots, control, progress, continuation):
                        do {
                            guard let observed = snapshot else { throw SFTPBrowserFailure.stale }
                            try requireBatchCurrent(requested, snapshot: observed, request: id, control: control)
                            try control.begin()
                            let result = try await SFTPUploadBatchRunner.run(plan, generation: requested, snapshot: observed,
                                transport: transport, storage: storage, excluding: roots,
                                requireCurrent: { try await self.requireBatchCurrent(requested, snapshot: observed, request: id, control: control) }, progress: progress)
                            continuation.resume(returning: result)
                        } catch {
                            if let interruption = error as? SFTPUploadBatchInterruption, interruption.connectionFailed, !closed {
                                failed = true; publish(failure(interruption.cause))
                            }
                            continuation.resume(throwing: error)
                        }
                        cancelled.remove(id)
                    #endif
                    }
                    active = nil
                } catch {
                    cancelled.remove(job.id); active = nil; job.fail(error)
                    if !closed {
                        let sizeRefusal = error as? RemoteFolderSizeFailure
                        if job.isCatalogQuery && (error is RemoteDirectoryFindFailure
                            || sizeRefusal != nil && sizeRefusal != .connectionLost) {
                            // Only the acknowledged metadata request was refused.
                            // Navigation, authentication and server operations remain usable.
                            publish()
                        } else if error is SFTPOriginalAdmissionFailure || error is SFTPInPlaceAdmissionFailure || error is SFTPInPlaceEditRefusal {
                            // A before-command two-baseline refusal has no
                            // transport edge and preserves both open editors.
                            publish()
                        } else if case .navigation = job, let rejection = error as? SFTPDirectoryRejection {
                            // The transport has acknowledged a complete request refusal.
                            // No prior generation may remain available for page/transfer.
                            generation = nil; snapshot = nil; paused = true; reading = false
                            publish(directoryRejection: rejection)
                        } else { failed = true; publish(failure(error)) }
                    }
                }
            } else if !paused, let generation, snapshot?.state == .loading {
                reading = true; publish()
                do {
                    let began = ContinuousClock.now
                    snapshot = try await transport.ingestNext(generation)
                    recordDirectoryRead(since: began)
                    reading = false; if !closed { publish() }
                }
                catch { reading = false; if !closed { failed = true; publish(failure(error)) } }
            } else {
                let probe = await waitForWorkOrIdle()
                if probe && !closed && queuedNavigation == nil && pages.isEmpty {
                    do { try await transport.checkIdle() }
                    catch { if !closed { failed = true; publish(failure(error)) } }
                }
            }
        }
        if failed || closed {
            failWaiting()
        }
    }

    private func recordDirectoryRead(since began: ContinuousClock.Instant) {
        let elapsed = began.duration(to: ContinuousClock.now).components
        lastDirectoryReadMilliseconds = max(0, Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000)
        lastDirectoryResponseAt = Date()
    }
    func close() async -> SFTPWorkerClose {
        if let closing { return await closing.value }
        closed = true; paused = true; wakeForWork()
        let pending = task
        let work = Task { [transport, publication] in
            let result = await transport.close(); await pending?.value
            publication.events.continuation.finish(); return result
        }
        closing = work
        failWaiting()
        let result = await work.value
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
        if result.localResourcesEnded {
            reservedFolder = nil; let retained = undrainedTrees; undrainedTrees.removeAll()
            for tree in retained { await tree.abandon() }
        }
        #endif
        if !result.localResourcesEnded { closing = nil }
        return result
    }
    private func failWaiting() {
        var queued = pages + [queuedNavigation, queuedOriginal, queuedInPlace, queuedRemoteAction].compactMap { $0 }
        pages.removeAll(); queuedNavigation = nil; queuedOriginal = nil; queuedInPlace = nil; queuedRemoteAction = nil
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
        queued += [queuedFolder].compactMap { $0 }; queuedFolder = nil
        #endif
        #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
        queued += [queuedDownload].compactMap { $0 }; queuedDownload = nil
        #endif
        #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
        queued += [queuedUpload].compactMap { $0 }; queuedUpload = nil
        #endif
        queued.forEach { $0.fail(SFTPBrowserFailure.stopped) }
    }
}
