import CryptoKit
import Darwin
import Foundation

/// The observed FAT driver lacks the metadata and exclusive publication
/// guarantees required by staged Copy and cross-volume Move. Read the filesystem
/// through the already opened parent: a path or displayed drive name cannot
/// authorize staging. Test refusal can only narrow production admission.
internal enum CopyDestinationFilesystem {
    static func requiresStaging(move: Bool, sourceDevice: dev_t, destinationDevice: dev_t,
                                forceCrossVolumeForTest: Bool = false) -> Bool {
        !move || sourceDevice != destinationDevice || forceCrossVolumeForTest
    }

    static func requireVerifiedStagingDestination(in parent: DirectoryAnchor,
                                    forceFATRefusal: (@Sendable () -> Bool)? = nil) throws {
        var filesystem = statfs()
        guard fstatfs(parent.fd, &filesystem) == 0 else { throw posixFailure() }
        let isFAT = withUnsafeBytes(of: filesystem.f_fstypename) { bytes in
            bytes.prefix(while: { $0 != 0 }).elementsEqual("msdos".utf8)
        }
        guard !isFAT, forceFATRefusal?() != true else {
            throw FileOperationFailure.fatTransferDestinationUnsupported
        }
    }
}

/// Transient, bounded observations. No security attribute bodies enter the journal.
internal struct SecurityAttribute: Equatable, Sendable {
    let length: Int
    let digest: Data
    init(_ data: Data) { length = data.count; digest = Data(SHA256.hash(data: data)) }
}
internal struct CopySecurity: Equatable, Sendable {
    static let quarantineName = "com.apple.quarantine"
    static let provenanceName = "com.apple.provenance"
    var quarantine: SecurityAttribute?
    var provenance: SecurityAttribute?
    static func read(_ fd: Int32) throws -> Self {
        func attribute(_ name: String) throws -> SecurityAttribute? {
            let length = fgetxattr(fd, name, nil, 0, 0, 0)
            if length < 0 {
                if errno == ENOATTR { return nil }
                throw posixFailure()
            }
            guard length <= 16_777_216 else { throw FileOperationFailure.unsupported }
            var bytes = Data(count: length)
            let count = bytes.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, length, 0, 0) }
            guard count >= 0 else { throw errno == ERANGE || errno == ENOATTR ? FileOperationFailure.sourceChanged : posixFailure() }
            guard count == length else { throw FileOperationFailure.sourceChanged }
            return SecurityAttribute(bytes)
        }
        return try Self(quarantine: attribute(quarantineName), provenance: attribute(provenanceName))
    }
}
internal struct CopyOwnership: Equatable, Sendable {
    let uid: uid_t
    let gid: gid_t
    static func read(_ fd: Int32) throws -> Self {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw posixFailure() }
        return Self(uid: value.st_uid, gid: value.st_gid)
    }
}
internal struct NativeCopyReceipt: Sendable {
    let relative: String
    let source: EntrySnapshot
    let destination: EntrySnapshot
    let destinationBeforeIdentity: EntrySnapshot
    let destinationOwnership: CopyOwnership
    let sourceBefore: CopySecurity
    let destinationBefore: CopySecurity
    let sourceAfter: CopySecurity
    let destinationAfter: CopySecurity

    /// This validates observed native propagation, not raw quarantine flag strength
    /// or exclusive OS authorship: another writer can mutate attributes on an open FD.
    func permitsSecurityTransition() -> Bool {
        guard sourceBefore == sourceAfter,
              destinationBeforeIdentity.device == destination.device,
              destinationBeforeIdentity.inode == destination.inode,
              destinationBeforeIdentity.type == destination.type else { return false }
        if sourceBefore.quarantine != nil {
            guard let copied = destinationAfter.quarantine, copied.length > 0 else { return false }
        } else if let created = destinationBefore.quarantine {
            // A newly created staging object may already carry a native
            // quarantine mark. Preserve that observed baseline exactly; do not
            // strip it or admit an unobserved/changed addition after copying.
            guard created.length > 0, destinationAfter.quarantine == created else { return false }
        } else if destinationAfter.quarantine != nil { return false }
        if let original = sourceBefore.provenance {
            // A new object may retain its own native creator origin. Never
            // force another object's tracking mark onto it or strip either one.
            let created = destinationBefore.provenance
            guard destinationAfter.provenance == original
                || (created?.length ?? 0) > 0 && destinationAfter.provenance == created else { return false }
        } else if let created = destinationBefore.provenance {
            guard destinationAfter.provenance == created else { return false }
        }
        return true
    }
}
internal final class NativeCopyReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: NativeCopyReceipt] = [:]
    func append(_ receipt: NativeCopyReceipt) throws {
        try lock.withLock {
            guard values.count < OperationLimits.maximumNodes, values[receipt.relative] == nil else { throw FileOperationFailure.copyMetadataMismatch }
            values[receipt.relative] = receipt
        }
    }
    func validate(source: CopyComparison, destination: CopyComparison, policy: TransferMetadataPolicy) throws {
        guard source.contentDigest == destination.contentDigest else { throw FileOperationFailure.copyContentMismatch }
        guard source.metadataDigest == destination.metadataDigest else { throw Self.mismatch(.copyMetadataComparison) }
        try lock.withLock {
            guard source.nodes.count == destination.nodes.count, values.count == source.nodes.count else {
                throw Self.mismatch(.copyReceiptCardinality)
            }
            for (path, original) in source.nodes {
                guard let copied = destination.nodes[path], let receipt = values[path],
                      receipt.source.sameObject(as: original.identity), receipt.destination.sameObject(as: copied.identity),
                      receipt.sourceBefore == original.security, receipt.destinationAfter == copied.security,
                      receipt.destinationOwnership == copied.ownership,
                      receipt.permitsSecurityTransition() else { throw Self.mismatch(.copyReceiptValidation) }
            }
        }
        guard policy == .destinationOwnership || source.ownershipDigest == destination.ownershipDigest else { throw FileOperationFailure.copyOwnershipMismatch }
    }
    private static func mismatch(_ checkpoint: OperationDiagnosticCheckpoint) -> FileOperationFailure {
        FileOperationDiagnostics.caughtFailure(checkpoint, FileOperationFailure.copyMetadataMismatch)
        return .copyMetadataMismatch
    }
}

/// Closed, transient categories for generated copy diagnosis. The values and
/// names of attributes never leave the comparison, and these hashes are not
/// stored in the operation journal or emitted through diagnostics.
internal enum CopyOrdinaryMetadataFamily: String, CaseIterable, Sendable {
    case mode, flags, modificationTime, resourceFork, otherExtendedAttributes, acl
}

/// Additional transient comparison projections; VerifiedTree's persisted full digest
/// and its historical byte encoding stay unchanged.
internal final class CopyComparison {
    struct Node { let identity: EntrySnapshot; let security: CopySecurity; let ownership: CopyOwnership }
    let diagnoseMetadataFamilies: Bool
    private var content = SHA256()
    private var metadata = SHA256()
    private var ownership = SHA256()
    private var modeMetadata = SHA256()
    private var flagsMetadata = SHA256()
    private var modificationTimeMetadata = SHA256()
    private var resourceForkMetadata = SHA256()
    private var otherExtendedAttributesMetadata = SHA256()
    private var aclMetadata = SHA256()
    private(set) var nodes: [String: Node] = [:]
    init(diagnoseMetadataFamilies: Bool = false) {
        self.diagnoseMetadataFamilies = diagnoseMetadataFamilies
    }
    var contentDigest: Data { Data(content.finalize()) }
    var metadataDigest: Data { Data(metadata.finalize()) }
    var ownershipDigest: Data { Data(ownership.finalize()) }
    private func append(_ data: Data, to hash: inout SHA256) {
        hash.update(data: Data("\(data.count):".utf8)); hash.update(data: data)
    }
    func appendContent(_ data: Data) { append(data, to: &content) }
    func appendMetadata(_ data: Data) { append(data, to: &metadata) }
    func appendOwnership(_ data: Data) { append(data, to: &ownership) }
    func beginMetadataNode(_ relative: String) {
        let path = Data(relative.utf8)
        appendMetadata(path)
        if diagnoseMetadataFamilies {
            for family in CopyOrdinaryMetadataFamily.allCases { appendMetadata(path, family: family) }
        }
    }
    func appendMetadata(_ data: Data, family: CopyOrdinaryMetadataFamily) {
        guard diagnoseMetadataFamilies else { return }
        switch family {
        case .mode: append(data, to: &modeMetadata)
        case .flags: append(data, to: &flagsMetadata)
        case .modificationTime: append(data, to: &modificationTimeMetadata)
        case .resourceFork: append(data, to: &resourceForkMetadata)
        case .otherExtendedAttributes: append(data, to: &otherExtendedAttributesMetadata)
        case .acl: append(data, to: &aclMetadata)
        }
    }
    private func metadataDigest(for family: CopyOrdinaryMetadataFamily) -> Data {
        switch family {
        case .mode: Data(modeMetadata.finalize())
        case .flags: Data(flagsMetadata.finalize())
        case .modificationTime: Data(modificationTimeMetadata.finalize())
        case .resourceFork: Data(resourceForkMetadata.finalize())
        case .otherExtendedAttributes: Data(otherExtendedAttributesMetadata.finalize())
        case .acl: Data(aclMetadata.finalize())
        }
    }
    /// Compare fixed families without exposing any path or attribute value.
    /// A changed aggregate with no listed family means this projection missed a
    /// component; it is never permission to admit a copy.
    func differingMetadataFamilies(from other: CopyComparison) throws -> [CopyOrdinaryMetadataFamily] {
        guard diagnoseMetadataFamilies, other.diagnoseMetadataFamilies else { throw FileOperationFailure.invalidRequest }
        return CopyOrdinaryMetadataFamily.allCases.filter { metadataDigest(for: $0) != other.metadataDigest(for: $0) }
    }
    func record(_ relative: String, identity: EntrySnapshot, security: CopySecurity, ownership: CopyOwnership) throws {
        let key = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        guard nodes.count < OperationLimits.maximumNodes, nodes[key] == nil else { throw FileOperationFailure.copyMetadataMismatch }
        nodes[key] = Node(identity: identity, security: security, ownership: ownership)
    }
}
