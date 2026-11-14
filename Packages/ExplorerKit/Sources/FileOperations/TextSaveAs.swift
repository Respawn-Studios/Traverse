import CryptoKit
import Darwin
import Foundation

// The shared one-file core retains the exact produced object across its return.
// Public adapters receive ordinary results; only the text wrapper can retoken.
internal final class OneFileMaterializationReceipt {
    let fd: Int32, destination: URL, parent: EntrySnapshot, after: EntrySnapshot
    init(descriptor: Int32, record: JournalRecord) throws {
        guard record.state == "committed", record.steps.count == 1,
              let step = record.steps.first, let after = step.after, !step.undone,
              try EntrySnapshot(fd: descriptor) == after.identity,
              after.identity.sameObject(as: step.before.identity) else { throw FileOperationFailure.recoveryUncertain }
        let pin = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        guard pin >= 0 else { throw posixFailure() }
        fd = pin; destination = step.destination; parent = step.destinationParent; self.after = after.identity
    }
    deinit { close(fd) }
    func validate(_ file: TextPinnedFileV2, bytes: Data, cancellation: OperationCancellation) throws {
        guard file.url == destination, file.parent.identity.sameObject(as: parent), file.bytes == bytes,
              try EntrySnapshot(fd: fd) == after, try EntrySnapshot(fd: file.fd) == after,
              try textProjection(fd, volume: file.volume, cancellation: cancellation) == file.witness else {
            throw FileOperationFailure.sourceChanged
        }
        try file.validate(cancellation: cancellation)
    }
}
internal struct OneFileProductionExecution {
    let result: RecoverableOperationResult
    let materialization: OneFileMaterializationReceipt?
    let publicationAttempted: Bool
}

internal struct BoundedTextFileProducer: ArchiveFileProducer {
    let contents: TextDocumentValue
    var preview: ArchiveProductionPreview { .init(files: 1, folders: 0, logicalBytes: UInt64(contents.encoded.count), longestPathBytes: 0) }
    func validate(check: @Sendable () throws -> Void) throws {
        try check(); guard try TextDocumentValue.original(contents.encoded) == contents else { throw FileOperationFailure.invalidRequest }
    }
    func produce(into descriptor: Int32, check: @Sendable () throws -> Void,
                 progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        try validate(check: check)
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard path.withUnsafeMutableBufferPointer({ fcntl(descriptor, F_GETPATH, UnsafeMutableRawPointer($0.baseAddress!)) }) == 0 else { throw posixFailure() }
        let string = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let url = URL(fileURLWithPath: string)
        let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
        try textRequirePrivateDirectory(parent)
        var facts = stat()
        guard url.lastPathComponent == "payload", parent.url.lastPathComponent.hasPrefix(".mac-explorer-recovery-"),
              fstat(descriptor, &facts) == 0, facts.st_uid == geteuid(), facts.st_nlink == 1,
              facts.st_size == 0, facts.st_mode & S_IFMT == S_IFREG,
              try EntrySnapshot(fd: descriptor) == EntrySnapshot(parent: parent.fd, name: url.lastPathComponent) else {
            throw FileOperationFailure.recoveryUncertain
        }
        try contents.encoded.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try check(); try textRequirePrivateDirectory(parent)
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), min(16_384, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixFailure() }; offset += count; progress(UInt64(count), 0)
            }
        }
        guard fchmod(descriptor, 0o644) == 0 else { throw posixFailure() }
        try textSync(descriptor); try check(); try textRequirePrivateDirectory(parent)
        let observed = try EntrySnapshot(fd: descriptor)
        guard observed.size == Int64(contents.encoded.count),
              observed == (try EntrySnapshot(parent: parent.fd, name: url.lastPathComponent)) else { throw FileOperationFailure.sourceChanged }
        progress(0, 1)
        return ArchiveProducedNode(relative: "", device: observed.device, inode: observed.inode, kind: observed.type,
            birthSeconds: observed.birthSeconds, birthNanoseconds: observed.birthNanos,
            changedSeconds: observed.changedSeconds, changedNanoseconds: observed.changedNanos,
            size: observed.size, contentSHA256: Data(SHA256.hash(data: contents.encoded)))
    }
}

public struct LocalTextSaveAsPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let generation: UUID, destination: URL
    internal let production: ArchiveCreationPlan, contents: TextDocumentValue
    public var description: String { "Local text Save As plan (private snapshot omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextSaveAsReceipt: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let generation: UUID, recordID: UUID
    public let document: LocalTextDocumentRead
    public var token: LocalTextReadToken { document.token }
    public var description: String { "Local text Save As receipt (private observations omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextSaveAsPublication: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let generation: UUID, recordID: UUID?, intendedURL: URL
    public let status: FileOperationStatus
    public var description: String { "Local text publication (private destination omitted)" }
    public var debugDescription: String { description }
}
public enum LocalTextSaveAsResult: Sendable {
    case saved(LocalTextSaveAsReceipt)
    case publishedNeedsReload(LocalTextSaveAsPublication)
    case refused(LocalTextSaveAsPublication)
    case uncertain(LocalTextSaveAsPublication)
}

extension RecoverableFileOperations {
    public func prepareLocalTextSaveAs(contents: TextDocumentValue, generation: UUID,
        destinationDirectory: URL, name: String) async throws -> LocalTextSaveAsPlan {
        try await worker {cancellation in try self.textRequireHistory10(cancellation:cancellation)}
        let received = try await prepareReceivedFile(parent: destinationDirectory, name: name, origin: .textSaveAs,
            makeProducer: { check in let producer = BoundedTextFileProducer(contents: contents); try producer.validate(check: check); return producer })
        return LocalTextSaveAsPlan(generation: generation, destination: received.destination,
            production: received.production, contents: contents)
    }
    public func performLocalTextSaveAs(_ plan: LocalTextSaveAsPlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> LocalTextSaveAsResult {
        let reporter = OperationProgressReporter(callback: progress)
        let result: LocalTextSaveAsResult
        do {
            result = try await worker(progress: reporter) { cancellation in
                try withoutMaterialization {
                    try self.textRequireHistory10(cancellation:cancellation)
                    guard plan.production.consume(by: self.continuationSession) else { throw FileOperationFailure.invalidRequest }
                    defer { plan.production.producer.finished() }
                    try self.validateCopyExecutionSession(locations: [plan.destination], directories: [plan.production.parent])
                    try self.validateArchiveCreation(plan.production, cancellation: cancellation)
                    let execution = self.createArchive(plan.production, cancellation: cancellation)
                    let generic = execution.result
                    let publication = LocalTextSaveAsPublication(generation: plan.generation, recordID: generic.recordID,
                        intendedURL: plan.destination, status: generic.result.items.first?.status ?? .failed(.recoveryUncertain))
                    guard generic.result.disposition == .succeeded, let id = generic.recordID else {
                        if execution.publicationAttempted {
                            return .uncertain(LocalTextSaveAsPublication(generation: plan.generation, recordID: generic.recordID,
                                intendedURL: plan.destination, status: .failed(.recoveryUncertain)))
                        }
                        return .refused(publication)
                    }
                    do {
                        guard let receipt = execution.materialization else { throw FileOperationFailure.sourceChanged }
                        let file = try TextPinnedFileV2(plan.destination, cancellation: cancellation.draining())
                        try receipt.validate(file, bytes: plan.contents.encoded, cancellation: cancellation.draining())
                        return .saved(LocalTextSaveAsReceipt(generation: plan.generation, recordID: id,
                            document: LocalTextDocumentRead(contents: plan.contents, token: self.textToken(file))))
                    } catch { return .publishedNeedsReload(publication) }
                }
            }
        } catch {
            result = .refused(LocalTextSaveAsPublication(generation: plan.generation, recordID: nil,
                intendedURL: plan.destination, status: operationStatus(error)))
        }
        let succeeded: Bool
        switch result { case .saved, .publishedNeedsReload: succeeded = true; default: succeeded = false }
        reporter.finish(success: succeeded); return result
    }
}
