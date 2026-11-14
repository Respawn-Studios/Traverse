#if DEBUG
import Foundation

/// Generated native integration only. It has no OS password implementation,
/// path, enumeration or secret-inspection API and is absent from Release.
@_spi(Qualification) public final class SFTPInMemoryPasswordQualification: @unchecked Sendable {
    public struct Facts: Sendable {
        public let stored: Int, reads: Int, writes: Int, removals: Int
        public let usedMainThread: Bool
    }
    private final class Backend: SFTPPasswordBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID: Data] = [:]
        private var reads = 0, writes = 0, removals = 0, main = false
        var facts: Facts { lock.withLock { .init(stored: values.count, reads: reads, writes: writes, removals: removals, usedMainThread: main) } }
        func read(service: String, reference: SFTPCredentialReference) throws -> Data {
            try lock.withLock {
                reads += 1; main = main || Thread.isMainThread
                guard let bytes = values[reference.id] else { throw SFTPPasswordFailure.missing }; return bytes
            }
        }
        func save(service: String, reference: SFTPCredentialReference, bytes: Data) throws {
            try lock.withLock {
                guard bytes.count <= 4161, values[reference.id] != nil || values.count < 128 else { throw SFTPPasswordFailure.unavailable }
                writes += 1; main = main || Thread.isMainThread; values[reference.id] = bytes
            }
        }
        func remove(service: String, reference: SFTPCredentialReference) throws {
            lock.withLock { removals += 1; main = main || Thread.isMainThread; values.removeValue(forKey: reference.id) }
        }
    }
    private let backend: Backend
    public let vault: SFTPPasswordVault
    public init() {
        let backend = Backend(); self.backend = backend
        vault = .init(service: "Traverse.Generated.InMemory.NoKeychain", backend: backend)
    }
    public var facts: Facts { backend.facts }
}
#endif
