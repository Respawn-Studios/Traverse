import Foundation

#if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
/// Cancellation becomes visible between files even before the pump actor
/// processes its cancellation message. A queued cancellation leaves browsing.
final class SFTPDownloadBatchControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false, began = false
    func cancel() { lock.withLock { stopped = true } }
    var cancelled: Bool { lock.withLock { stopped } }
    var started: Bool { lock.withLock { began } }
    func begin() throws {
        try lock.withLock { guard !stopped else { throw SFTPBrowserFailure.stopped }; began = true }
    }
}

@_spi(Qualification) public enum SFTPDownloadBatchIssue: String, Error, Sendable {
    case invalidSelection, duplicateSelection, duplicateName, tooLarge
}

@_spi(Qualification) public struct SFTPDownloadBatchItem: Sendable {
    public let selection: SFTPDownloadSelection
    public let localName: String
}

/// One complete catalog observation and only its requested regular-file IDs.
/// This is metadata; neither construction nor inspection reads a body.
@_spi(Qualification) public struct SFTPDownloadBatchPlan: Sendable, CustomDebugStringConvertible {
    public static let maximumFiles = 16
    public static let maximumBytes: UInt64 = 1 << 30
    public let generation: UUID
    public let snapshot: SFTPStoredSnapshot
    public let items: [SFTPDownloadBatchItem]
    public let logicalBytes: UInt64
    public var debugDescription: String { "<SFTP selected download group>" }

    public init(generation: UUID, snapshot: SFTPStoredSnapshot, selections: [SFTPDownloadSelection]) throws {
        guard SFTPWire.validToken(generation), snapshot.state == .complete, snapshot.read > 0,
              snapshot.count >= 2, snapshot.count <= UInt64(Int64.max), snapshot.revision <= UInt64(Int64.max),
              (2...Self.maximumFiles).contains(selections.count), UInt64(selections.count) <= snapshot.count else {
            throw SFTPDownloadBatchIssue.invalidSelection
        }
        var observations = Set<UInt64>(), requests = Set<UUID>(), names = Set<Data>()
        var items: [SFTPDownloadBatchItem] = [], total: UInt64 = 0
        for selection in selections {
            guard selection.generation == generation, selection.row.observation <= UInt64(Int64.max),
                  let name = selection.proposedLocalName else { throw SFTPDownloadBatchIssue.invalidSelection }
            guard observations.insert(selection.row.observation).inserted,
                  requests.insert(selection.request).inserted else { throw SFTPDownloadBatchIssue.duplicateSelection }
            guard names.insert(Data(name.utf8)).inserted else { throw SFTPDownloadBatchIssue.duplicateName }
            guard selection.logicalBytes <= Self.maximumBytes - total else { throw SFTPDownloadBatchIssue.tooLarge }
            total += selection.logicalBytes
            items.append(.init(selection: selection, localName: name))
        }
        self.generation = generation; self.snapshot = snapshot; self.items = items; logicalBytes = total
    }
}

@_spi(Qualification) public struct SFTPDownloadBatchProgress: Sendable {
    public let index: Int, completedFiles: Int, totalFiles: Int
    public let receivedBytes: UInt64, logicalBytes: UInt64
}

@_spi(Qualification) public struct SFTPDownloadBatchReceivedItem: Sendable {
    public let selection: SFTPDownloadSelection
    public let localName: String
    public let download: SFTPReceivedDownload
}

/// Publication can start only when every requested file has sealed locally.
@_spi(Qualification) public struct SFTPDownloadBatchReceived: Sendable, CustomDebugStringConvertible {
    public let items: [SFTPDownloadBatchReceivedItem]
    public let logicalBytes: UInt64
    public var debugDescription: String { "<SFTP received download group>" }
    public func retainForReview() async {
        for item in items { await item.download.retainForReview() }
    }
}

/// No publishable subset escapes on failure. IDs identify retained allocations;
/// a constructor failure can leave an incomplete namespace that inspection
/// refuses, so an ID alone is not proof of a recoverable body.
@_spi(Qualification) public struct SFTPDownloadBatchInterruption: Error, Sendable, CustomDebugStringConvertible {
    public let completedFiles: Int, totalFiles: Int, completedBytes: UInt64
    public let retainedFileIDs: [UUID]
    public let currentMayHaveStarted: Bool
    public let cause: any Error
    let connectionFailed: Bool
    public var debugDescription: String { "<SFTP interrupted download group>" }
    func replacingCause(_ replacement: any Error) -> Self {
        .init(completedFiles: completedFiles, totalFiles: totalFiles, completedBytes: completedBytes,
              retainedFileIDs: retainedFileIDs, currentMayHaveStarted: currentMayHaveStarted,
              cause: replacement, connectionFailed: connectionFailed)
    }
}

/// Runs inside one existing pump job. All bounded spools are reserved before
/// the first body; their owner locks remain held through receive/publication.
enum SFTPDownloadBatchRunner {
    static func run(_ plan: SFTPDownloadBatchPlan, transport: any SFTPDirectoryTransport,
                    storage: SFTPDownloadStorage, requireCurrent: @Sendable () async throws -> Void,
                    progress: (@Sendable (SFTPDownloadBatchProgress) -> Void)?) async throws -> SFTPDownloadBatchReceived {
        var staged: [RemoteDownloadedFile] = [], received: [SFTPDownloadBatchReceivedItem] = []
        var completedBytes: UInt64 = 0, currentMayHaveStarted = false
        do {
            staged = try await storage.store.reserveBatch(plan, requireCurrent: requireCurrent,
                publicQuarantineV1: storage.publicQuarantineSelectedGroupCandidate)
            for (index, item) in plan.items.enumerated() {
                currentMayHaveStarted = false
                try await requireCurrent()
                let before = completedBytes
                progress?(.init(index: index, completedFiles: index, totalFiles: plan.items.count,
                                receivedBytes: before, logicalBytes: plan.logicalBytes))
                let file = staged[index]
                currentMayHaveStarted = true
                let receipt = try await transport.download(item.selection, into: file, progress: { bytes in
                    progress?(.init(index: index, completedFiles: index, totalFiles: plan.items.count,
                                    receivedBytes: before + min(bytes, item.selection.logicalBytes), logicalBytes: plan.logicalBytes))
                })
                _ = try await file.seal(receipt)
                try await requireCurrent()
                received.append(.init(selection: item.selection, localName: item.localName, download: .init(file)))
                completedBytes += item.selection.logicalBytes
                progress?(.init(index: index, completedFiles: received.count, totalFiles: plan.items.count,
                                receivedBytes: completedBytes, logicalBytes: plan.logicalBytes))
            }
            try await requireCurrent()
            return .init(items: received, logicalBytes: plan.logicalBytes)
        } catch {
            for file in staged { _ = await file.abandon() }
            let reservation = error as? RemoteDownloadBatchReservationFailure
            throw SFTPDownloadBatchInterruption(completedFiles: received.count, totalFiles: plan.items.count,
                completedBytes: completedBytes, retainedFileIDs: reservation?.retainedFileIDs ?? staged.map(\.id),
                currentMayHaveStarted: currentMayHaveStarted, cause: reservation?.cause ?? error,
                connectionFailed: currentMayHaveStarted)
        }
    }
}
#endif
