import Foundation
import FileOperations

@_spi(Qualification) public final class SMBReceivedFolderDownload: Sendable {
    private let tree: RemoteDownloadedTree
    public var id: UUID { tree.id }
    public var logicalBytes: UInt64 { tree.manifest.logicalBytes }
    init(_ tree: RemoteDownloadedTree) { self.tree = tree }
    public func preparePublication(using operations: RecoverableFileOperations, parent: URL, name: String,
        observing destination: FileOperationSelection,
        publicQuarantineTreeV16: Bool = false) async throws -> ReceivedDirectoryPlan {
        try await tree.preparePublication(using: operations, parent: parent, name: name,
            observing: destination, publicQuarantineTreeV16: publicQuarantineTreeV16)
    }
    public func finishPublication(_ result: RecoverableOperationResult) async -> Bool {
        if result.recordID != nil, result.result.disposition == .succeeded {
            do { try await tree.removeAfterDrain(); return true } catch {}
        }
        await tree.abandon(); return false
    }
    public func retainForReview() async { await tree.abandon() }
}

final class SMBFolderPreparationAttempt: @unchecked Sendable {
    let selection: SMBFolderDownloadSelection
    private let lock = NSLock()
    private var cancelled = false
    init(_ selection: SMBFolderDownloadSelection) { self.selection = selection }
    func admit() -> Bool { lock.withLock { !cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}
final class SMBFolderReceiveAttempt: @unchecked Sendable {
    let prepared: SMBPreparedFolderDownload, tree: RemoteDownloadedTree
    let progress: (@Sendable (UInt64) -> Void)?
    private let lock = NSLock()
    private var cancelled = false, safeToAbandon = true
    init(_ prepared: SMBPreparedFolderDownload, tree: RemoteDownloadedTree, progress: (@Sendable (UInt64) -> Void)?) {
        self.prepared = prepared; self.tree = tree; self.progress = progress
    }
    func admit() -> Bool { lock.withLock { guard !cancelled else { return false }; safeToAbandon = false; return true } }
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var mayAbandon: Bool { lock.withLock { safeToAbandon } }
    func drained() { lock.withLock { safeToAbandon = true } }
}

extension SMBBrowserSession {
    public func prepareFolderDownload(_ selection: SMBFolderDownloadSelection) async throws -> SMBPreparedFolderDownload {
        guard allowsFolderDownloads, selection.connection == id else { throw SMBBrowserFailure.invalidInput }
        let attempt = SMBFolderPreparationAttempt(selection)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { owner.prepareFolder(attempt, continuation: $0) }
        } onCancel: { attempt.cancel(); owner.cancelFolderPreparation(attempt) }
    }
    public func releaseFolderDownload(_ prepared: SMBPreparedFolderDownload) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { owner.releaseFolder(prepared, continuation: $0) }
        } onCancel: { owner.stop() }
    }
    public func downloadFolder(_ prepared: SMBPreparedFolderDownload, storage: SMBDownloadStorage,
        progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> SMBReceivedFolderDownload {
        guard allowsFolderDownloads, prepared.selection.connection == id else { throw SMBBrowserFailure.invalidInput }
        let tree: RemoteDownloadedTree
        do { tree = try await storage.store.reserveTree(prepared) }
        catch let issue as RemoteDownloadStorageFailure { throw SMBDownloadStorageIssue(issue) }
        let attempt = SMBFolderReceiveAttempt(prepared, tree: tree, progress: progress)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { owner.beginFolder(attempt, continuation: $0) }
            } onCancel: { attempt.cancel(); owner.cancelFolderReceive(attempt) }
            try Task.checkCancellation()
            try await tree.seal(request: prepared.selection.request, receivedBytes: prepared.logicalBytes, receivedFiles: prepared.files)
            return SMBReceivedFolderDownload(tree)
        } catch {
            if attempt.mayAbandon { await tree.abandon() }
            if let issue = error as? RemoteDownloadStorageFailure { throw SMBDownloadStorageIssue(issue) }
            throw error
        }
    }
}
