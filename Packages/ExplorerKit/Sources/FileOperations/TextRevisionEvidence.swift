import CryptoKit
import Foundation

// Reused qualified evidence values. V2 native authority also requires real
// independent retained copies, a durable head chain and live pinned proofs.
enum TextRevisionValueFailure: Error, Equatable { case malformed, changedWitness, invalidTransition, quota }

struct RevisionDigest: Codable, Hashable, Sendable {
    let hex: String
    init(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw TextRevisionValueFailure.malformed
        }
        hex = value
    }
    init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: any Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(hex) }
    static func bytes(_ data: Data) -> Self {
        // SHA256's formatter always produces the validated fixed lowercase form.
        try! Self(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
struct RevisionTime: Codable, Equatable, Sendable {
    let seconds: Int64, nanos: Int
    func validate() throws {
        guard seconds >= 0, (0..<1_000_000_000).contains(nanos) else { throw TextRevisionValueFailure.malformed }
    }
}
struct RevisionWitness: Codable, Equatable, Sendable {
    let volume: UUID, device: UInt64, inode: UInt64
    let birth: RevisionTime, modified: RevisionTime, changed: RevisionTime
    let links: UInt8, bytes: UInt64
    let body: RevisionDigest, metadata: RevisionDigest, security: RevisionDigest
    let flags: UInt32, document: UInt32
    func validate() throws {
        try birth.validate(); try modified.validate(); try changed.validate()
        guard device != 0, inode != 0, links <= 1, bytes <= 1_048_576, flags == 0 || flags == 64,
              (flags == 0 ? document == 0 : document != 0) else { throw TextRevisionValueFailure.malformed }
    }
    func sameObject(_ other: Self) -> Bool {
        volume == other.volume && device == other.device && inode == other.inode && birth == other.birth
    }

    /// Persisted observations may cross a remount. This comparison is only
    /// usable after the current file's held descriptor qualifies the volume.
    func samePersistentObservation(_ other: Self, qualifiedVolume: UUID) -> Bool {
        volume == qualifiedVolume && other.volume == qualifiedVolume &&
            inode == other.inode && birth == other.birth &&
            modified == other.modified && changed == other.changed &&
            links == other.links && bytes == other.bytes && body == other.body &&
            metadata == other.metadata && security == other.security &&
            flags == other.flags && document == other.document
    }
}
enum RevisionNativeProfile: String, Codable, Sendable { case apfsNewMetadataPrivateBirthV1 }
struct RevisionCopySeal: Codable, Equatable, Sendable {
    let profile: RevisionNativeProfile
    let source: RevisionWitness, copy: RevisionWitness
    let metadataBytes: UInt64
    func validate() throws {
        try source.validate(); try copy.validate()
        guard metadataBytes <= 262_144 else { throw TextRevisionValueFailure.quota }
        guard source.links == 1, copy.links == 1, source.volume == copy.volume, source.device == copy.device,
              !source.sameObject(copy), source.birth == copy.birth, source.modified == copy.modified,
              source.bytes == copy.bytes, source.body == copy.body, source.metadata == copy.metadata,
              source.flags == copy.flags,
              (source.flags == 0 ? copy.document == 0 : copy.document != source.document) else {
            throw TextRevisionValueFailure.changedWitness
        }
        // Security fingerprints retain the independently verified private-copy
        // baseline. Equality here cannot replace the real NativeCopyReceipt gate.
    }
}
struct RevisionStagedEdit: Codable, Equatable, Sendable {
    let origin: RevisionCopySeal, edited: RevisionWitness
    func validate() throws {
        try origin.validate(); try edited.validate()
        guard edited.links == 1, edited.sameObject(origin.copy), edited.flags == origin.copy.flags,
              edited.document == origin.copy.document, edited.metadata == origin.copy.metadata,
              edited.security == origin.copy.security else { throw TextRevisionValueFailure.changedWitness }
    }
}
public enum LocalTextRevisionDirection: String, Codable, Sendable { case forward, inverse }
internal typealias RevisionDirection = LocalTextRevisionDirection
