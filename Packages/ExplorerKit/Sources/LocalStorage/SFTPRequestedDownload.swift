import Foundation
@_spi(ArchiveProduction) import FileOperations
import Darwin

@_spi(Qualification) public enum SFTPDownloadStorageIssue: String, Error, Sendable {
    case full, busy, unavailable, changed
    init(_ failure: RemoteDownloadStorageFailure) {
        switch failure {
        case .capacity, .io(ENOSPC), .io(EDQUOT): self = .full
        case .busy: self = .busy
        case .changed, .unsafe: self = .changed
        default: self = .unavailable
        }
    }
    init(_ failure: SMBTemporaryStorageFailure) {
        switch failure {
        case .capacity: self = .full
        case .busy: self = .busy
        case .unsafe, .changed: self = .changed
        default: self = .unavailable
        }
    }
}

/// Private requested bodies, separate from metadata catalogs and remembrance.
/// Construction/inspection are read-only; no raw payload path reaches a view.
@_spi(Qualification) public final class SFTPDownloadStorage: Sendable {
    let store: RemoteDownloadStore
    private let publicQuarantineCandidate: Bool
    let publicQuarantineSelectedGroupCandidate: Bool
    public init(directory: URL) throws {
        store = try .init(directory: directory); publicQuarantineCandidate = false
        publicQuarantineSelectedGroupCandidate = false
    }
    /// Source-only bridge for a separately admitted single-file Download.
    @_spi(ArchiveProduction) public init(directory: URL,
        publicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy) throws {
        guard publicQuarantinePolicy == .sourceQualification else { throw SFTPDownloadStorageIssue.changed }
        store = try .init(directory: directory); publicQuarantineCandidate = true
        publicQuarantineSelectedGroupCandidate = false
    }
    /// Selected file groups remain separate from the one-file admission. Each
    /// received member still requires its own v14 publication and Undo record.
    @_spi(ArchiveProduction) public init(directory: URL,
        publicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy,
        selectedGroupPublicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy) throws {
        guard publicQuarantinePolicy == .sourceQualification,
              selectedGroupPublicQuarantinePolicy == .sourceQualification else {
            throw SFTPDownloadStorageIssue.changed
        }
        store = try .init(directory: directory); publicQuarantineCandidate = true
        publicQuarantineSelectedGroupCandidate = true
    }
    #if DEBUG
    init(directory: URL, hooks: DownloadIOHooks) throws {
        store = try .init(directory: directory, hooks: hooks); publicQuarantineCandidate = false
        publicQuarantineSelectedGroupCandidate = false
    }
    #endif
    func reserveSelected(_ selection: SFTPDownloadSelection) async throws -> RemoteDownloadedFile {
        if publicQuarantineCandidate { return try await store.reservePublicQuarantineCandidate(selection) }
        return try await store.reserve(selection)
    }
    public func inspect() async throws -> [SFTPDownloadStorageSummary] {
        try await store.inspect().map { .init(id: $0.id, expectedBytes: $0.expectedBytes,
            observedBytes: $0.observedBytes, active: $0.active, isFolder: $0.isFolder,
            publicationProtected: $0.publicationProtected) }
    }
    @_spi(ArchiveProduction) public func checkAdoptionDestination(using operations: RecoverableFileOperations,
        parent: URL, name: String, observing destination: FileOperationSelection? = nil) async throws -> FileOperationSelection {
        try await operations.checkReceivedFileAdoptionDestination(parent: parent, name: name,
            stagingDirectory: store.directory, observing: destination)
    }
    #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
    /// One fixed generated seven-byte body for the signed private mark probe.
    /// It uses the same reserve/write/seal path as selected SFTP Download, but
    /// makes no session, network request or arbitrary-file read.
    @_spi(ArchiveProduction) public func makeGeneratedPrivateMarkProbeSource() async throws -> SFTPReceivedDownload {
        let body = Data("PROBEv1".utf8)
        let selection = try SFTPDownloadSelection(generation: UUID(), row: .init(observation: 1,
            entry: .init(name: SFTPRemoteName(Data("Generated.bin".utf8)),
                         logicalBytes: UInt64(body.count), modifiedSeconds: 1,
                         permissions: 0o100600)))
        let file = try await store.reserve(selection)
        do {
            try await file.append(request: selection.request, offset: 0, bytes: body)
            _ = try await file.seal(.init(selection: selection, receivedBytes: UInt64(body.count)))
            return SFTPReceivedDownload(file)
        } catch {
            _ = await file.abandon()
            throw error
        }
    }
    #endif
    /// An explicit user cleanup request, never automatic startup recovery.
    public func discardIncomplete(_ id: UUID) async throws { try await store.discardIncomplete(id) }
}
@_spi(Qualification) public struct SFTPDownloadStorageSummary: Sendable, Equatable {
    public let id: UUID, expectedBytes: UInt64, observedBytes: UInt64, active: Bool
    public let isFolder: Bool
    public let publicationProtected: Bool
}

/// A checked received copy, not a remote snapshot or authority to delete it.
@_spi(Qualification) public final class SFTPReceivedDownload: Sendable {
    private let file: RemoteDownloadedFile
    public var id: UUID { file.id }
    public var logicalBytes: UInt64 { file.selection.logicalBytes }
    @_spi(ArchiveProduction) public func hasExpectedV7NativeMark() async throws -> Bool {
        try await file.hasExpectedV7NativeMark()
    }
    func makeTextLease(origin: SFTPTextOrigin) async throws -> SFTPTextReadLease {
        try await SFTPTextReadLease.mint(file, origin: origin)
    }
    init(_ file: RemoteDownloadedFile) { self.file = file }
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
    /// Call only after the publishing engine has actually returned. Failure
    /// retains its owned staging for explicit review instead of retry/resume.
    public func finishPublication(_ result: RecoverableOperationResult) async -> Bool {
        if result.recordID != nil, result.result.disposition == .succeeded {
            do { try await file.removeAfterDrain(); return true } catch {}
        }
        _ = await file.abandon(); return false
    }
    public func retainForReview() async { _ = await file.abandon() }
}
