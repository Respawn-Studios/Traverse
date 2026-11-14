import CryptoKit
import Foundation
import Security

/// Passwords stay separate from connection preferences, URLs and worker arguments.
@_spi(Qualification) public struct SMBPassword: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let bytes: Data
    public init(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 4096, !bytes.contains(0) else { throw SMBPasswordFailure.invalidInput }
        self.bytes = bytes
    }
    public var description: String { "<SMB password>" }
    public var debugDescription: String { description }
    /// Used only at the private worker-channel boundary; never for diagnostics.
    public func withUTF8Bytes<T>(_ body: (Data) throws -> T) rethrows -> T { try body(bytes) }
}

@_spi(Qualification) public struct SMBCredentialBinding: Sendable {
    let digest: Data
    public init(host: String, port: UInt16, share: String, account: String, domain: String, interfaceScope: UInt32 = 0) throws {
        guard port > 0, !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) }),
              !host.contains(where: { "/\\@%?#".contains($0) }),
              !share.isEmpty, share.utf8.count <= 256, !share.contains(where: { "/\\\0".contains($0) }),
              !account.isEmpty, account.utf8.count <= 256, domain.utf8.count <= 256,
              !account.contains("\0"), !domain.contains("\0"),
              interfaceScope == 0 || host.contains(":") && interfaceScope < 0xffff_fff0 else { throw SMBPasswordFailure.invalidInput }
        // Preserve existing unscoped references exactly; scoped IPv6 additionally
        // binds the interface, preventing reuse on another link-local device.
        var encoded = Data([interfaceScope == 0 ? 1 : 2])
        let fields = [host.lowercased(), String(port), share, account, domain] + (interfaceScope == 0 ? [] : [String(interfaceScope)])
        for field in fields {
            let bytes = Data(field.utf8)
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { encoded.append(contentsOf: $0) }
            encoded.append(bytes)
        }
        digest = Data(SHA256.hash(data: encoded))
    }
}

/// Contains no password. A reference cannot authorize reuse at another endpoint.
@_spi(Qualification) public struct SMBCredentialReference: Sendable, Codable, Equatable {
    public let id: UUID
    let bindingDigest: Data
    public init(binding: SMBCredentialBinding) { id = UUID(); bindingDigest = binding.digest }
}

@_spi(Qualification) public typealias SMBPasswordFailure = RemotePasswordFailure

@_spi(Qualification) public enum RemotePasswordFailure: Error, Sendable, Equatable {
    case invalidInput, bindingMismatch, missing, busy, cancelled, denied, unavailable, invalidRecord
    case keychainStatus(Int32)
}

@_spi(Qualification) public struct SMBPasswordMutation: Sendable {
    /// A cancellation arriving during SecItem cannot undo its completed mutation.
    public let completedAfterCancellation: Bool
}

protocol SMBPasswordBackend: Sendable {
    func read(service: String, reference: SMBCredentialReference) throws -> Data
    func save(service: String, reference: SMBCredentialReference, bytes: Data) throws
    func remove(service: String, reference: SMBCredentialReference) throws
}

/// Deliberately selects the supported file/login Keychain, never a fallback.
struct LoginKeychainItem: Sendable {
    let id: UUID
    let bindingDigest: Data
}

struct LoginKeychainBackend: Sendable {
    private func query(_ service: String, _ reference: LoginKeychainItem) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: reference.id.uuidString,
         kSecAttrGeneric as String: reference.bindingDigest,
         kSecUseDataProtectionKeychain as String: false]
    }
    func read(service: String, reference: LoginKeychainItem) throws -> Data {
        var query = query(service, reference)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let bytes = result as? Data else { throw SMBPasswordFailure.invalidRecord }
        return bytes
    }
    func save(service: String, reference: LoginKeychainItem, bytes: Data, label: String) throws {
        let key = query(service, reference)
        var attributes = key
        attributes[kSecAttrLabel as String] = label
        attributes[kSecValueData as String] = bytes
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // The exact binding remains in the predicate. A coincidentally
            // reused UUID at another endpoint must never update that secret.
            let result = SecItemUpdate(key as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
            if result == errSecItemNotFound { throw SMBPasswordFailure.bindingMismatch }
            try check(result)
        } else { try check(status) }
    }
    func remove(service: String, reference: LoginKeychainItem) throws {
        let result = SecItemDelete(query(service, reference) as CFDictionary)
        if result != errSecItemNotFound { try check(result) }
    }
    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw SMBPasswordFailure.missing
        case errSecUserCanceled: throw SMBPasswordFailure.cancelled
        case errSecAuthFailed, errSecInteractionNotAllowed: throw SMBPasswordFailure.denied
        case errSecNotAvailable: throw SMBPasswordFailure.unavailable
        default: throw SMBPasswordFailure.keychainStatus(status)
        }
    }
}

private struct SMBLoginKeychainBackend: SMBPasswordBackend {
    private let backend = LoginKeychainBackend()
    private func item(_ reference: SMBCredentialReference) -> LoginKeychainItem { .init(id: reference.id, bindingDigest: reference.bindingDigest) }
    func read(service: String, reference: SMBCredentialReference) throws -> Data { try backend.read(service: service, reference: item(reference)) }
    func save(service: String, reference: SMBCredentialReference, bytes: Data) throws {
        try backend.save(service: service, reference: item(reference), bytes: bytes, label: "Mac Explorer SMB password")
    }
    func remove(service: String, reference: SMBCredentialReference) throws { try backend.remove(service: service, reference: item(reference)) }
}

private struct SMBRefusingQualificationBackend: SMBPasswordBackend {
    let observed: @Sendable () -> Void
    func read(service: String, reference: SMBCredentialReference) throws -> Data { observed(); throw SMBPasswordFailure.unavailable }
    func save(service: String, reference: SMBCredentialReference, bytes: Data) throws { observed(); throw SMBPasswordFailure.unavailable }
    func remove(service: String, reference: SMBCredentialReference) throws { observed(); throw SMBPasswordFailure.unavailable }
}
#if DEBUG
@_spi(Qualification) public struct SMBGeneratedMemoryQualificationCounts: Sendable {
    public let reads: Int, saves: Int, removes: Int, retained: Int
}
/// Per-vault generated credentials only. The backend never calls SecItem and
/// never exposes stored bytes through diagnostics or its counters.
private final class SMBGeneratedMemoryQualificationBackend: SMBPasswordBackend, @unchecked Sendable {
    private struct Key: Hashable { let service: String, id: UUID, binding: Data }
    private let lock = NSLock()
    private var entries: [Key: Data] = [:]
    private var reads = 0, saves = 0, removes = 0
    private func key(_ service: String, _ reference: SMBCredentialReference) -> Key {
        .init(service: service, id: reference.id, binding: reference.bindingDigest)
    }
    var counts: SMBGeneratedMemoryQualificationCounts { lock.withLock {
        .init(reads: reads, saves: saves, removes: removes, retained: entries.count)
    } }
    func read(service: String, reference: SMBCredentialReference) throws -> Data {
        try lock.withLock {
            reads += 1
            guard let value = entries[key(service, reference)] else { throw SMBPasswordFailure.missing }
            return value
        }
    }
    func save(service: String, reference: SMBCredentialReference, bytes: Data) throws {
        try lock.withLock {
            saves += 1
            guard bytes.count > 33, bytes.count <= 4129, bytes.first == 1,
                  bytes.subdata(in: 1..<33) == reference.bindingDigest else { throw SMBPasswordFailure.invalidRecord }
            let selected = key(service, reference)
            guard entries[selected] != nil || entries.count < 8 else { throw SMBPasswordFailure.busy }
            entries[selected] = bytes
        }
    }
    func remove(service: String, reference: SMBCredentialReference) throws {
        lock.withLock { removes += 1; _ = entries.removeValue(forKey: key(service, reference)) }
    }
}
#endif

private final class SMBPasswordRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// One serial, off-main Keychain owner with at most eight admitted requests.
/// Cancelled reads never publish a secret. Admitted mutations return their
/// actual result after draining, including a cancellation that arrived late.
@_spi(Qualification) public final class SMBPasswordVault: @unchecked Sendable {
    private let service: String
    private let backend: any SMBPasswordBackend
    #if DEBUG
    private let generatedMemoryBackend: SMBGeneratedMemoryQualificationBackend?
    #endif
    private let queue = DispatchQueue(label: "MacExplorer.SMB.Passwords", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    var admittedRequestCount: Int { lock.withLock { pending } }

    public static func loginKeychain() -> SMBPasswordVault {
        SMBPasswordVault(service: "local.macexplorer.smb.password.v1", backend: SMBLoginKeychainBackend())
    }
    public static func directLoginKeychain() -> SMBPasswordVault {
        SMBPasswordVault(service: "com.respawnstudios.traverse.direct.smb.password.v1",
                         backend: SMBLoginKeychainBackend())
    }
    public static func generatedQualification(namespace: UUID) -> SMBPasswordVault {
        SMBPasswordVault(service: "MacExplorer.B10.Qualification.\(namespace.uuidString)", backend: SMBLoginKeychainBackend())
    }
    #if DEBUG
    public static func generatedMemoryQualification() -> SMBPasswordVault {
        .init(service: "Traverse.Generated.Memory.SMB.NoKeychain", backend: SMBGeneratedMemoryQualificationBackend())
    }
    public var generatedMemoryQualificationCounts: SMBGeneratedMemoryQualificationCounts? { generatedMemoryBackend?.counts }
    #endif
    public static func refusingQualification(observed: @escaping @Sendable () -> Void) -> SMBPasswordVault {
        .init(service: "Traverse.Generated.Refusing.SMB.NoKeychain", backend: SMBRefusingQualificationBackend(observed: observed))
    }
    init(service: String, backend: any SMBPasswordBackend) {
        self.service = service; self.backend = backend
        #if DEBUG
        generatedMemoryBackend = backend as? SMBGeneratedMemoryQualificationBackend
        #endif
    }

    public func password(_ reference: SMBCredentialReference, binding: SMBCredentialBinding) async throws -> SMBPassword {
        try validate(reference, binding)
        let (password, _) = try await perform(read: true) { [self] in
            let bytes = try backend.read(service: service, reference: reference)
            guard bytes.count > 33, bytes.count <= 4129, bytes.first == 1,
                  bytes.subdata(in: 1..<33) == reference.bindingDigest,
                  let value = String(data: bytes.dropFirst(33), encoding: .utf8) else { throw SMBPasswordFailure.invalidRecord }
            return try SMBPassword(value)
        }
        if Task.isCancelled { throw SMBPasswordFailure.cancelled }
        return password
    }
    public func save(_ password: SMBPassword, reference: SMBCredentialReference, binding: SMBCredentialBinding) async throws -> SMBPasswordMutation {
        try validate(reference, binding)
        let (_, cancelled) = try await perform(read: false) { [self] in
            var bytes = Data([1]); bytes.append(reference.bindingDigest); bytes.append(password.bytes)
            try backend.save(service: service, reference: reference, bytes: bytes)
        }
        return SMBPasswordMutation(completedAfterCancellation: cancelled)
    }
    public func remove(_ reference: SMBCredentialReference, binding: SMBCredentialBinding) async throws -> SMBPasswordMutation {
        try validate(reference, binding)
        return try await removeOwned(reference)
    }
    /// Only the durable preferences coordinator uses this for pending/deleting
    /// claims. The exact service, UUID and binding digest remain in the query;
    /// no host/account reconstruction or broad Keychain search is necessary.
    func removeOwned(_ reference: SMBCredentialReference) async throws -> SMBPasswordMutation {
        guard reference.bindingDigest.count == 32 else { throw SMBPasswordFailure.invalidRecord }
        let (_, cancelled) = try await perform(read: false) { [self] in
            try backend.remove(service: service, reference: reference)
        }
        return SMBPasswordMutation(completedAfterCancellation: cancelled)
    }
    /// Drains previously admitted calls; cancellation never releases their owner early.
    public func drain() async {
        await withCheckedContinuation { continuation in
            lock.withLock { queue.async { continuation.resume() } }
        }
    }
    private func validate(_ reference: SMBCredentialReference, _ binding: SMBCredentialBinding) throws {
        guard reference.bindingDigest.count == 32, reference.bindingDigest == binding.digest else { throw SMBPasswordFailure.bindingMismatch }
    }
    private func perform<T: Sendable>(read: Bool, body: @escaping @Sendable () throws -> T) async throws -> (T, Bool) {
        let request = SMBPasswordRequest()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { request.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard pending < 8 else { lock.unlock(); continuation.resume(throwing: SMBPasswordFailure.busy); return }
                pending += 1
                queue.async { [self] in
                    let result: Result<T, Error>
                    if request.isCancelled { result = .failure(SMBPasswordFailure.cancelled) }
                    else { result = Result { try body() } }
                    let cancelled = request.isCancelled
                    lock.withLock { pending -= 1 }
                    if read && cancelled { continuation.resume(throwing: SMBPasswordFailure.cancelled) }
                    else { continuation.resume(with: result.map { ($0, cancelled) }) }
                }
                lock.unlock()
            }
        } onCancel: { request.cancel() }
    }
}
