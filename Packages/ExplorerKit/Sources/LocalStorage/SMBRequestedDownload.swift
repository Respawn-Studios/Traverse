import Foundation
@_spi(ArchiveProduction) import FileOperations
import Darwin

@_spi(Qualification) public enum SMBDownloadStorageIssue: String, Error, Sendable {
    case full, busy, unavailable, changed
    init(_ value: RemoteDownloadStorageFailure) {
        switch value {
        case .capacity, .io(ENOSPC), .io(EDQUOT): self = .full
        case .busy: self = .busy
        case .changed, .unsafe: self = .changed
        default: self = .unavailable
        }
    }
}

@_spi(Qualification) public final class SMBDownloadStorage: Sendable {
    let store: RemoteDownloadStore
    private let publicQuarantineCandidate: Bool
    let publicQuarantineSelectedGroupCandidate: Bool
    public init(directory: URL) throws {
        store = try .init(directory: directory); publicQuarantineCandidate = false
        publicQuarantineSelectedGroupCandidate = false
    }
    /// Source-only bridge; private text and folder routes remain on v1/v2.
    @_spi(ArchiveProduction) public init(directory: URL,
        publicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy) throws {
        guard publicQuarantinePolicy == .sourceQualification else { throw SMBDownloadStorageIssue.changed }
        store = try .init(directory: directory); publicQuarantineCandidate = true
        publicQuarantineSelectedGroupCandidate = false
    }
    /// Opt in only the selected-file group. The folder/tree owner remains v2.
    @_spi(ArchiveProduction) public init(directory: URL,
        publicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy,
        selectedGroupPublicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy) throws {
        guard publicQuarantinePolicy == .sourceQualification,
              selectedGroupPublicQuarantinePolicy == .sourceQualification else {
            throw SMBDownloadStorageIssue.changed
        }
        store = try .init(directory: directory); publicQuarantineCandidate = true
        publicQuarantineSelectedGroupCandidate = true
    }
    func reserveSelected(_ selection: SMBDownloadSelection) async throws -> SMBDownloadedFile {
        if publicQuarantineCandidate { return try await store.reservePublicQuarantineCandidate(selection) }
        return try await store.reserve(selection)
    }
    public func inspect() async throws -> [SMBDownloadStorageSummary] {
        try await store.inspect().map { .init(id: $0.id, expectedBytes: $0.expectedBytes,
            observedBytes: $0.observedBytes, active: $0.active, isFolder: $0.isFolder,
            publicationProtected: $0.publicationProtected) }
    }
    @_spi(ArchiveProduction) public func checkAdoptionDestination(using operations: RecoverableFileOperations,
        parent: URL, name: String, observing destination: FileOperationSelection? = nil) async throws -> FileOperationSelection {
        try await operations.checkReceivedFileAdoptionDestination(parent: parent, name: name,
            stagingDirectory: store.directory, observing: destination)
    }
    public func discardIncomplete(_ id: UUID) async throws { try await store.discardIncomplete(id) }
}
@_spi(Qualification) public struct SMBDownloadStorageSummary: Sendable, Equatable {
    public let id: UUID, expectedBytes: UInt64, observedBytes: UInt64, active: Bool
    public let isFolder: Bool
    public let publicationProtected: Bool
}

/// Only a sealed received file enters the existing Download/Results/Undo engine.
@_spi(Qualification) public final class SMBReceivedDownload: Sendable {
    private let file: SMBDownloadedFile
    public var id: UUID { file.id }
    public var logicalBytes: UInt64 { file.selection.logicalBytes }
    init(_ file: SMBDownloadedFile) { self.file = file }
    public func preparePublication(using operations: RecoverableFileOperations, parent: URL, name: String,
        observing destination: FileOperationSelection) async throws -> ReceivedFilePlan {
        try await file.preparePublication(using: operations, parent: parent, name: name, observing: destination)
    }
    @_spi(ArchiveProduction) public func preparePublicQuarantineCandidate(using operations: RecoverableFileOperations,
        parent: URL, name: String, observing destination: FileOperationSelection) async throws -> ReceivedFilePlan {
        try await file.preparePublicQuarantineCandidate(using: operations, parent: parent, name: name,
            observing: destination)
    }
    @_spi(ArchiveProduction) public func prepareAdoption(using operations: RecoverableFileOperations,
        parent: URL, name: String, observing destination: FileOperationSelection) async throws -> AdoptedReceivedFilePlan {
        try await file.prepareAdoption(using: operations, parent: parent, name: name, observing: destination)
    }
    /// FileOperations owns the adopted inode. This only releases the received
    /// lease and reports whether its committed empty shell was retired.
    @_spi(ArchiveProduction) public func finishAdoption(_ result: RecoverableOperationResult) async -> Bool {
        let retired = file.adoptionShellRetired(for: result.recordID)
        if !retired { _ = await file.abandon() }
        return retired && result.recordID != nil && result.result.disposition == .succeeded
    }
    public func finishPublication(_ result: RecoverableOperationResult) async -> Bool {
        if result.recordID != nil, result.result.disposition == .succeeded {
            do { try await file.removeAfterDrain(); return true } catch {}
        }
        _ = await file.abandon(); return false
    }
    public func retainForReview() async { _ = await file.abandon() }
}

/// Cancellation cannot be lost between the handler and queue admission. A
/// caller cannot release staging while an uncertain owner still retains it.
final class SMBDownloadAttempt: @unchecked Sendable {
    let selection: SMBDownloadSelection, file: SMBDownloadedFile
    let progress: (@Sendable (UInt64) -> Void)?
    let retainingEditSource: Bool
    private let lock = NSLock()
    private var cancelled = false, safeToAbandon = true
    init(selection: SMBDownloadSelection, file: SMBDownloadedFile, progress: (@Sendable (UInt64) -> Void)?,
         retainingEditSource: Bool = false) {
        self.selection = selection; self.file = file; self.progress = progress
        self.retainingEditSource = retainingEditSource
    }
    func admit() -> Bool { lock.withLock { guard !cancelled else { return false }; safeToAbandon = false; return true } }
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var mayAbandon: Bool { lock.withLock { safeToAbandon } }
    func drained() { lock.withLock { safeToAbandon = true } }
}
