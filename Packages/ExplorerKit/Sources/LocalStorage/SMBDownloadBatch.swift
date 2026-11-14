import Foundation

@_spi(Qualification) public enum SMBDownloadBatchIssue: String, Error, Sendable {
    case invalidSelection, duplicateSelection, duplicateName, tooLarge
}

@_spi(Qualification) public struct SMBDownloadBatchItem: Sendable {
    public let selection: SMBDownloadSelection
    public let localName: String
}

/// One complete catalog observation and only its selected regular-file IDs.
/// Construction reads metadata only and grants no remote body access.
@_spi(Qualification) public struct SMBDownloadBatchPlan: Sendable, CustomDebugStringConvertible {
    public static let maximumFiles = 16
    public static let maximumBytes: UInt64 = 1 << 30
    public let connection: UUID
    public let snapshot: SMBDirectorySnapshot
    public let items: [SMBDownloadBatchItem]
    public let logicalBytes: UInt64
    public var debugDescription: String { "<SMB selected download group>" }

    public init(connection: UUID, snapshot: SMBDirectorySnapshot, selections: [SMBDownloadSelection]) throws {
        guard connection.uuidString != "00000000-0000-0000-0000-000000000000",
              snapshot.readID.uuidString != "00000000-0000-0000-0000-000000000000",
              snapshot.state == .complete, snapshot.revision > 0, snapshot.revision <= UInt64(Int64.max),
              snapshot.count >= 2, (2...Self.maximumFiles).contains(selections.count),
              Int64(selections.count) <= snapshot.count else { throw SMBDownloadBatchIssue.invalidSelection }
        var observations = Set<Int64>(), requests = Set<UUID>(), names = Set<Data>()
        var items: [SMBDownloadBatchItem] = [], total: UInt64 = 0
        for selection in selections {
            guard selection.connection == connection, selection.snapshot == snapshot,
                  selection.observation.id > 0, !selection.observation.isDirectory,
                  !selection.observation.isReparsePoint,
                  let name = selection.proposedLocalName else { throw SMBDownloadBatchIssue.invalidSelection }
            guard observations.insert(selection.observation.id).inserted,
                  requests.insert(selection.request).inserted else { throw SMBDownloadBatchIssue.duplicateSelection }
            guard names.insert(Data(name.utf8)).inserted else { throw SMBDownloadBatchIssue.duplicateName }
            guard selection.logicalBytes <= Self.maximumBytes - total else { throw SMBDownloadBatchIssue.tooLarge }
            total += selection.logicalBytes
            items.append(.init(selection: selection, localName: name))
        }
        self.connection = connection; self.snapshot = snapshot; self.items = items; logicalBytes = total
    }
}

@_spi(Qualification) public struct SMBDownloadBatchProgress: Sendable {
    public let index: Int, completedFiles: Int, totalFiles: Int
    public let receivedBytes: UInt64, logicalBytes: UInt64
}

@_spi(Qualification) public struct SMBDownloadBatchReceivedItem: Sendable {
    public let selection: SMBDownloadSelection
    public let localName: String
    public let download: SMBReceivedDownload
}

/// No publishable subset leaves this group until every received spool seals.
@_spi(Qualification) public struct SMBDownloadBatchReceived: Sendable, CustomDebugStringConvertible {
    public let items: [SMBDownloadBatchReceivedItem]
    public let logicalBytes: UInt64
    public var debugDescription: String { "<SMB received download group>" }
    public func retainForReview() async {
        for item in items { await item.download.retainForReview() }
    }
}

/// IDs are diagnostic handles for retained or incomplete allocations. An ID
/// alone does not prove that a body is recoverable or safe to publish.
@_spi(Qualification) public struct SMBDownloadBatchInterruption: Error, Sendable, CustomDebugStringConvertible {
    public let completedFiles: Int, totalFiles: Int, completedBytes: UInt64
    public let retainedFileIDs: [UUID]
    public let currentMayHaveStarted: Bool
    public let cause: any Error
    let connectionFailed: Bool
    public var debugDescription: String { "<SMB interrupted download group>" }
}

/// A cancellation is visible before the owner's serial queue can process it.
final class SMBDownloadBatchControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false, began = false, currentStarted = false
    private var completed = 0, bytes: UInt64 = 0
    var cancelled: Bool { lock.withLock { cancelledFlag } }
    var started: Bool { lock.withLock { began } }
    var progress: (completedFiles: Int, completedBytes: UInt64, currentMayHaveStarted: Bool) {
        lock.withLock { (completed, bytes, currentStarted) }
    }
    func cancel() { lock.withLock { cancelledFlag = true } }
    func begin() -> Bool { lock.withLock { guard !cancelledFlag else { return false }; began = true; return true } }
    func startingFile() { lock.withLock { currentStarted = true } }
    func completedFile(bytes count: UInt64) {
        lock.withLock { completed += 1; bytes += count; currentStarted = false }
    }
}
