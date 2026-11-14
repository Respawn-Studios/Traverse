import CoreServices
import CryptoKit
import Darwin
import Foundation

/// Off by default. Source qualification does not authorize app wiring or a
/// signed-sandbox publication claim.
public enum DownloadAdoptionPolicy: Sendable {
    case held
    case sourceQualification
}

/// One fixed pool-side fence. The same exact bytes are checked by cold journal
/// inspection; an unrecognized or orphaned fence never permits cleanup.
@_spi(ArchiveProduction) public struct DownloadAdoptionMarker: Sendable, Equatable {
    public let job: UUID
    public let spool: UUID
    public let area: UUID
    public init(job: UUID, spool: UUID, area: UUID) { self.job = job; self.spool = spool; self.area = area }
    public var bytes: Data { Data("MEX-DOWNLOAD-ADOPTION1\n\(job.uuidString)\n\(spool.uuidString)\n\(area.uuidString)\n".utf8) }
    public init(bytes: Data) throws {
        guard bytes.count <= 160, let value = String(data: bytes, encoding: .utf8) else { throw FileOperationFailure.recoveryUncertain }
        let parts = value.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "MEX-DOWNLOAD-ADOPTION1",
              let job = UUID(uuidString: String(parts[1])), let spool = UUID(uuidString: String(parts[2])),
              let area = UUID(uuidString: String(parts[3])) else { throw FileOperationFailure.recoveryUncertain }
        self.init(job: job, spool: spool, area: area)
        guard self.bytes == bytes else { throw FileOperationFailure.recoveryUncertain }
    }
}

/// Only LocalStorage's sealed single-file owner supplies this capability.
/// The qualification engine alone can perform the two renames.
@_spi(ArchiveProduction) public protocol SealedDownloadAdoptionSource: Sendable {
    var spoolID: UUID { get }
    var logicalBytes: UInt64 { get }
    var digest: Data { get }
    func adoptionPin() throws -> DownloadAdoptionPin
    func armAdoption(job: UUID, area: UUID) throws
    func noteAdopted(job: UUID)
    func retireCommittedShell(receipt: DownloadAdoptionCommitReceipt) throws
    func finished()
}

/// Minted only after FileOperations has saved a committed v7 journal head.
/// The download pool may retire its empty shell for this exact job and spool.
@_spi(ArchiveProduction) public struct DownloadAdoptionCommitReceipt: Sendable {
    public let job: UUID
    public let spool: UUID
    internal init(job: UUID, spool: UUID) { self.job = job; self.spool = spool }
}

@_spi(ArchiveProduction) public final class DownloadAdoptionPin: @unchecked Sendable {
    public let descriptor: Int32
    public let url: URL
    public init(duplicating descriptor: Int32, url: URL) throws {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        guard duplicate >= 0 else { throw FileOperationFailure.unavailable }
        self.descriptor = duplicate; self.url = url
    }
    deinit { close(descriptor) }
}

/// The one local sandbox mark carried by a sealed requested-file spool. These
/// values are deliberately narrower than arbitrary quarantine dictionaries.
internal struct DownloadAdoptionPublicMark: Codable, Equatable, Sendable {
    let agent: String
    let kind: String
    let timestamp: Date
    let currentUser: Bool?
    let bundle: String?
    let eventIdentifier: String?

    init(_ values: [String: Any]?) throws {
        guard let values, !values.isEmpty, values.count <= 6 else { throw FileOperationFailure.copyMetadataMismatch }
        let agentKey = kLSQuarantineAgentNameKey as String
        let kindKey = kLSQuarantineTypeKey as String
        let timestampKey = kLSQuarantineTimeStampKey as String
        let bundleKey = kLSQuarantineAgentBundleIdentifierKey as String
        let currentUserKey = "LSQuarantineIsOwnedByCurrentUser"
        let eventKey = "LSQuarantineEventIdentifier"
        guard Set(values.keys).isSubset(of: [agentKey, kindKey, timestampKey, bundleKey, currentUserKey, eventKey]),
              let agent = values[agentKey] as? String, !agent.isEmpty, agent.utf8.count <= 128,
              let kind = values[kindKey] as? String, !kind.isEmpty, kind.utf8.count <= 128,
              let timestamp = values[timestampKey] as? Date, timestamp.timeIntervalSince1970.isFinite,
              values[currentUserKey] == nil || values[currentUserKey] is Bool,
              values[bundleKey] == nil || values[bundleKey] is String,
              values[eventKey] == nil || values[eventKey] is String else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        let bundle = values[bundleKey] as? String
        let event = values[eventKey] as? String
        guard bundle == nil || (!bundle!.isEmpty && bundle!.utf8.count <= 256),
              event == nil || UUID(uuidString: event!) != nil else { throw FileOperationFailure.copyMetadataMismatch }
        self.agent = agent; self.kind = kind; self.timestamp = timestamp
        currentUser = values[currentUserKey] as? Bool; self.bundle = bundle
        eventIdentifier = event
    }

    func validate() throws {
        guard !agent.isEmpty, agent.utf8.count <= 128, !kind.isEmpty, kind.utf8.count <= 128,
              timestamp.timeIntervalSince1970.isFinite,
              bundle == nil || (!bundle!.isEmpty && bundle!.utf8.count <= 256),
              eventIdentifier == nil || UUID(uuidString: eventIdentifier!) != nil else {
            throw FileOperationFailure.recoveryUncertain
        }
    }
}

internal struct DownloadAdoptionSecurity: Codable, Equatable, Sendable {
    let quarantineDigest: Data
    let provenanceDigest: Data?
    let publicMark: DownloadAdoptionPublicMark

    static func observe(descriptor: Int32, url: URL) throws -> Self {
        try diagnosing(.downloadAdoptionPathBinding) { try requireBoundPath(descriptor, url) }
        let mark = try diagnosing(.downloadAdoptionRawQuarantine) {
            try attribute(descriptor, "com.apple.quarantine")
        }
        guard let mark, !mark.isEmpty else { throw mismatch(.downloadAdoptionRawQuarantine) }
        let provenance = try diagnosing(.downloadAdoptionProvenance) {
            try attribute(descriptor, "com.apple.provenance")
        }
        let witness = try diagnosing(.downloadAdoptionPublicProperties) {
            let properties = try URL(fileURLWithPath: url.path).resourceValues(
                forKeys: [.quarantinePropertiesKey]).quarantineProperties
            return try DownloadAdoptionPublicMark(properties)
        }
        let finalMark = try diagnosing(.downloadAdoptionRawQuarantine) {
            try attribute(descriptor, "com.apple.quarantine")
        }
        guard finalMark == mark else { throw mismatch(.downloadAdoptionRawQuarantine) }
        let finalProvenance = try diagnosing(.downloadAdoptionProvenance) {
            try attribute(descriptor, "com.apple.provenance")
        }
        guard finalProvenance == provenance else { throw mismatch(.downloadAdoptionProvenance) }
        try diagnosing(.downloadAdoptionPathBinding) { try requireBoundPath(descriptor, url) }
        return .init(quarantineDigest: Data(SHA256.hash(data: mark)),
                     provenanceDigest: provenance.map { Data(SHA256.hash(data: $0)) }, publicMark: witness)
    }

    func require(_ descriptor: Int32, at url: URL) throws {
        let current = try Self.observe(descriptor: descriptor, url: url)
        guard current == self else {
            if current.quarantineDigest != quarantineDigest {
                throw Self.mismatch(.downloadAdoptionRawQuarantine)
            }
            if current.provenanceDigest != provenanceDigest {
                throw Self.mismatch(.downloadAdoptionProvenance)
            }
            throw Self.mismatch(.downloadAdoptionPublicProperties)
        }
    }

    #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
    /// Keep the complete native mark in memory only for one generated private
    /// same-inode probe. The journal continues to persist only its digest.
    func capturedNativeMark(_ descriptor: Int32, at url: URL) throws -> Data {
        try Self.requireBoundPath(descriptor, url)
        guard let mark = try Self.attribute(descriptor, "com.apple.quarantine"),
              mark.starts(with: Data("0086;".utf8)),
              Data(SHA256.hash(data: mark)) == quarantineDigest else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        try require(descriptor, at: url)
        return mark
    }

    /// This observation can never authorize publication. It attempts exactly
    /// one descriptor-bound replacement only for the complete 0086 -> 0082
    /// transition on the already-pinned private inode.
    func probePrivateSameInodeRestoration(_ descriptor: Int32, at url: URL,
                                          original: Data) -> DownloadPrivateMarkProbeResult {
        do {
            try Self.requireBoundPath(descriptor, url)
            var facts = stat()
            guard fstat(descriptor, &facts) == 0, facts.st_mode & 0o7777 == 0o600,
                  original.starts(with: Data("0086;".utf8)),
                  Data(SHA256.hash(data: original)) == quarantineDigest,
                  let current = try Self.attribute(descriptor, "com.apple.quarantine") else {
                return .preconditionFailed
            }
            if current == original { return .unchanged }
            var weakened = Data("0082;".utf8)
            weakened.append(original.dropFirst(5))
            guard current == weakened else { return .unexpectedMark }
            let observed = try Self.observe(descriptor: descriptor, url: url)
            guard observed.provenanceDigest == provenanceDigest,
                  observed.publicMark == publicMark else { return .preconditionFailed }
            let replaced = original.withUnsafeBytes {
                fsetxattr(descriptor, "com.apple.quarantine", $0.baseAddress,
                          original.count, 0, XATTR_REPLACE)
            }
            if replaced != 0 { return .replaceDenied(errno) }
            do {
                try require(descriptor, at: url)
                return .restored
            } catch { return .postcheckFailed }
        } catch { return .preconditionFailed }
    }
    #endif

    func validate() throws {
        guard quarantineDigest.count == 32, provenanceDigest == nil || provenanceDigest!.count == 32 else {
            throw FileOperationFailure.recoveryUncertain
        }
        try publicMark.validate()
    }

    private static func requireBoundPath(_ descriptor: Int32, _ url: URL) throws {
        var pinned = stat(), linked = stat()
        guard fstat(descriptor, &pinned) == 0, lstat(url.path, &linked) == 0,
              pinned.st_mode & S_IFMT == S_IFREG, linked.st_mode & S_IFMT == S_IFREG,
              pinned.st_uid == geteuid(), linked.st_uid == geteuid(),
              pinned.st_nlink == 1, linked.st_nlink == 1,
              pinned.st_dev == linked.st_dev, pinned.st_ino == linked.st_ino,
              pinned.st_birthtimespec.tv_sec == linked.st_birthtimespec.tv_sec,
              pinned.st_birthtimespec.tv_nsec == linked.st_birthtimespec.tv_nsec else {
            throw FileOperationFailure.copyMetadataMismatch
        }
    }

    private static func attribute(_ fd: Int32, _ name: String) throws -> Data? {
        let size = fgetxattr(fd, name, nil, 0, 0, 0)
        if size < 0, errno == ENOATTR { return nil }
        guard size > 0, size <= 4096 else { throw FileOperationFailure.copyMetadataMismatch }
        var data = Data(count: size)
        guard data.withUnsafeMutableBytes({ fgetxattr(fd, name, $0.baseAddress, size, 0, 0) }) == size else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        return data
    }

    /// Only a fixed component is reported. Values, hashes and locations remain
    /// inside the witness; diagnostics cannot authorize a retry or publication.
    private static func diagnosing<T>(_ checkpoint: OperationDiagnosticCheckpoint,
                                      _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch {
            FileOperationDiagnostics.caughtFailure(checkpoint, error)
            throw error
        }
    }

    private static func mismatch(_ checkpoint: OperationDiagnosticCheckpoint) -> FileOperationFailure {
        FileOperationDiagnostics.caughtFailure(checkpoint, FileOperationFailure.copyMetadataMismatch)
        return .copyMetadataMismatch
    }
}

#if DEBUG || TRAVERSE_SFTP_EDITOR_QA
/// Closed QA observation. No mark bytes, provenance, path or file contents
/// leave FileOperations through this callback.
@_spi(ArchiveProduction) public enum DownloadPrivateMarkProbeResult: Sendable {
    case unchanged, unexpectedMark, preconditionFailed, replaceDenied(Int32), restored, postcheckFailed
}
#endif

/// Version 7 owns only the one adopted spool inode; the single JournalStep is
/// recovery-area publication. No raw user body, mark or credential is stored.
internal struct JournalDownloadAdoption: Codable, Sendable {
    let spoolID: UUID
    let volume: NativeRenameVolume
    let source: URL
    let sourceParent: EntrySnapshot
    let sourceIdentity: EntrySnapshot
    let markerIdentity: EntrySnapshot
    let area: URL
    let areaIdentity: EntrySnapshot
    let destination: URL
    let destinationParent: EntrySnapshot
    let length: UInt64
    let bodyDigest: Data
    let security: DownloadAdoptionSecurity
    var adoptedStage: VerifiedTree?

    func validate() throws {
        try security.validate()
        try volume.validateRepresentation()
        guard source.isFileURL, area.isFileURL, destination.isFileURL,
              source.lastPathComponent == "payload", area.lastPathComponent.hasPrefix(".mac-explorer-recovery-"),
              destination.lastPathComponent != "payload", sourceIdentity.type == S_IFREG,
              markerIdentity.type == S_IFREG, areaIdentity.type == S_IFDIR,
              sourceIdentity.device == volume.device, sourceIdentity.device == areaIdentity.device,
              areaIdentity.device == destinationParent.device,
              sourceIdentity.size >= 0, UInt64(sourceIdentity.size) == length, length <= 1 << 30,
              bodyDigest.count == 32,
              source.deletingLastPathComponent().lastPathComponent == "download-" + spoolID.uuidString,
              sourceParent.type == S_IFDIR, sourceParent.device == sourceIdentity.device,
              destination.deletingLastPathComponent() == area.deletingLastPathComponent() else {
            throw FileOperationFailure.recoveryUncertain
        }
        if let adoptedStage {
            guard adoptedStage.identity.sameObject(as: sourceIdentity), adoptedStage.identity.mode & 0o7777 == 0o644,
                  adoptedStage.identity.size == sourceIdentity.size else { throw FileOperationFailure.recoveryUncertain }
        }
    }
}
