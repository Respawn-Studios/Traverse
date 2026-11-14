import Foundation

/// Generated-control-only observations. The actual descriptor read still runs;
/// these bytes affect only the DEBUG after-walk comparison, never an xattr.
internal struct NativeTrashSyntheticRootMetadata: Sendable {
    #if DEBUG
    private let quarantine: Data?
    private let provenance: Data?
    private let osAccess: Data?
    private let other: Data?

    init(quarantine: Data? = nil, provenance: Data? = nil, osAccess: Data? = nil, other: Data? = nil) throws {
        guard [quarantine, provenance, osAccess, other].allSatisfy({ ($0?.count ?? 0) <= 4096 }) else {
            throw FileOperationFailure.invalidRequest
        }
        self.quarantine = quarantine
        self.provenance = provenance
        self.osAccess = osAccess
        self.other = other
    }

    var names: [String] {
        [(quarantine, CopySecurity.quarantineName), (provenance, CopySecurity.provenanceName), (osAccess, "com.apple.macl"),
         (other, "com.traverse.generated-negative")].compactMap { $0.0 == nil ? nil : $0.1 }
    }

    func replacement(for name: String) -> Data? {
        switch name {
        case CopySecurity.quarantineName: quarantine
        case CopySecurity.provenanceName: provenance
        case "com.apple.macl": osAccess
        case "com.traverse.generated-negative": other
        default: nil
        }
    }
    #endif
}

/// Exact generated pre-mutation walk charge; no path, body or attribute value.
internal final class NativeTrashWalkMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = 0
    private var bodyBytes: Int64 = 0
    private var overflow = false

    func visit() {
        lock.withLock {
            if entries == Int.max { overflow = true } else { entries += 1 }
        }
    }

    func read(_ count: Int) {
        lock.withLock {
            guard count >= 0, bodyBytes <= Int64.max - Int64(count) else {
                overflow = true; return
            }
            bodyBytes += Int64(count)
        }
    }

    var snapshot: (entries: Int, bodyBytes: Int64, valid: Bool) {
        lock.withLock { (entries, bodyBytes, !overflow) }
    }
}
