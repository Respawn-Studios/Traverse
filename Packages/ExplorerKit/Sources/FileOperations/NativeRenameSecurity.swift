import CryptoKit
import Foundation

/// Transient projection for one native rename boundary. Persisted full digests
/// stay unchanged; no attribute is rewritten, logged or exempted from Undo.
internal final class NativeRenameSecurityProjection {
    private var hash = SHA256()
    private(set) var rootQuarantine: SecurityAttribute?
    private(set) var rootProvenance: SecurityAttribute?
    func append(_ bytes: Data) {
        hash.update(data: Data("\(bytes.count):".utf8)); hash.update(data: bytes)
    }
    func observeRootQuarantine(_ bytes: Data) { rootQuarantine = SecurityAttribute(bytes) }
    func observeRootProvenance(_ bytes: Data) { rootProvenance = SecurityAttribute(bytes) }

    /// Native origin may follow the current process's exact creation baseline.
    /// Existing quarantine, child marks, ACLs and macl stay exact. This proves a
    /// bounded observed transition, never exclusive authorship of an attribute.
    func permitsNativeTransition(to other: NativeRenameSecurityProjection, before: VerifiedTree, after: VerifiedTree,
                                 origin: SecurityAttribute?) -> Bool {
        let quarantine = rootQuarantine == other.rootQuarantine
            || rootQuarantine == nil && (other.rootQuarantine?.length ?? 0) > 0
        let provenance = rootProvenance == other.rootProvenance
            || (origin?.length ?? 0) > 0 && other.rootProvenance == origin
        return before.identity.sameObject(as: after.identity)
            && quarantine && provenance
            && Data(hash.finalize()) == Data(other.hash.finalize())
    }
}
