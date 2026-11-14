import CryptoKit
import Darwin
import Foundation

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
        guard source.metadataDigest == destination.metadataDigest else { throw FileOperationFailure.copyMetadataMismatch }
        try lock.withLock {
            guard source.nodes.count == destination.nodes.count, values.count == source.nodes.count else { throw FileOperationFailure.copyMetadataMismatch }
            for (path, original) in source.nodes {
                guard let copied = destination.nodes[path], let receipt = values[path],
                      receipt.source.sameObject(as: original.identity), receipt.destination.sameObject(as: copied.identity),
                      receipt.sourceBefore == original.security, receipt.destinationAfter == copied.security,
                      receipt.destinationOwnership == copied.ownership,
                      receipt.permitsSecurityTransition() else { throw FileOperationFailure.copyMetadataMismatch }
            }
        }
        guard policy == .destinationOwnership || source.ownershipDigest == destination.ownershipDigest else { throw FileOperationFailure.copyOwnershipMismatch }
    }
}

/// Additional transient comparison projections; VerifiedTree's persisted full digest
/// and its historical byte encoding stay unchanged.
internal final class CopyComparison {
    struct Node { let identity: EntrySnapshot; let security: CopySecurity; let ownership: CopyOwnership }
    private var content = SHA256()
    private var metadata = SHA256()
    private var ownership = SHA256()
    private(set) var nodes: [String: Node] = [:]
    var contentDigest: Data { Data(content.finalize()) }
    var metadataDigest: Data { Data(metadata.finalize()) }
    var ownershipDigest: Data { Data(ownership.finalize()) }
    private func append(_ data: Data, to hash: inout SHA256) {
        hash.update(data: Data("\(data.count):".utf8)); hash.update(data: data)
    }
    func appendContent(_ data: Data) { append(data, to: &content) }
    func appendMetadata(_ data: Data) { append(data, to: &metadata) }
    func appendOwnership(_ data: Data) { append(data, to: &ownership) }
    func record(_ relative: String, identity: EntrySnapshot, security: CopySecurity, ownership: CopyOwnership) throws {
        let key = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        guard nodes.count < OperationLimits.maximumNodes, nodes[key] == nil else { throw FileOperationFailure.copyMetadataMismatch }
        nodes[key] = Node(identity: identity, security: security, ownership: ownership)
    }
}
