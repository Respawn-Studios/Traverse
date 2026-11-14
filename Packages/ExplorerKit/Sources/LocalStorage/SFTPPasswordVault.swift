import Foundation

@_spi(Qualification) public typealias SFTPPasswordFailure = RemotePasswordFailure
struct SFTPPasswordMutation: Sendable { let completedAfterCancellation: Bool }

protocol SFTPPasswordBackend: Sendable {
    func read(service: String, reference: SFTPCredentialReference) throws -> Data
    func save(service: String, reference: SFTPCredentialReference, bytes: Data) throws
    func remove(service: String, reference: SFTPCredentialReference) throws
}
private struct SFTPLoginKeychainBackend: SFTPPasswordBackend {
    private let backend = LoginKeychainBackend()
    private func item(_ reference: SFTPCredentialReference) -> LoginKeychainItem { .init(id: reference.id, bindingDigest: reference.bindingDigest) }
    func read(service: String, reference: SFTPCredentialReference) throws -> Data { try backend.read(service: service, reference: item(reference)) }
    func save(service: String, reference: SFTPCredentialReference, bytes: Data) throws {
        try backend.save(service: service, reference: item(reference), bytes: bytes, label: "Mac Explorer SFTP password")
    }
    func remove(service: String, reference: SFTPCredentialReference) throws { try backend.remove(service: service, reference: item(reference)) }
}

/// A refusing backend, so generated key tests can prove they never query or
/// mutate the login Keychain. It cannot return or store a credential.
private struct SFTPRefusingQualificationBackend: SFTPPasswordBackend {
    let observed: @Sendable () -> Void
    func read(service: String, reference: SFTPCredentialReference) throws -> Data { observed(); throw SFTPPasswordFailure.unavailable }
    func save(service: String, reference: SFTPCredentialReference, bytes: Data) throws { observed(); throw SFTPPasswordFailure.unavailable }
    func remove(service: String, reference: SFTPCredentialReference) throws { observed(); throw SFTPPasswordFailure.unavailable }
}

/// Exact login-Keychain namespace, one bounded off-main owner. There is no
/// system key/config/agent search or fallback. Only verified-session code can
/// construct a binding and request a password; inspection performs no OS call.
@_spi(Qualification) public final class SFTPPasswordVault: @unchecked Sendable {
    private let service: String
    private let backend: any SFTPPasswordBackend
    private let queue = DispatchQueue(label: "MacExplorer.SFTP.Passwords", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0
    public static func loginKeychain() -> SFTPPasswordVault {
        .init(service: "local.macexplorer.sftp.password.v1", backend: SFTPLoginKeychainBackend())
    }
    public static func directLoginKeychain() -> SFTPPasswordVault {
        .init(service: "com.respawnstudios.traverse.direct.sftp.password.v1",
              backend: SFTPLoginKeychainBackend())
    }
    public static func generatedQualification(namespace: UUID) -> SFTPPasswordVault {
        .init(service: "MacExplorer.B11.Qualification.\(namespace.uuidString)", backend: SFTPLoginKeychainBackend())
    }
    public static func refusingQualification(observed: @escaping @Sendable () -> Void) -> SFTPPasswordVault {
        .init(service: "Traverse.Generated.Refusing.NoKeychain", backend: SFTPRefusingQualificationBackend(observed: observed))
    }
    init(service: String, backend: any SFTPPasswordBackend) { self.service = service; self.backend = backend }
    func password(_ reference: SFTPCredentialReference, binding: SFTPCredentialBinding) async throws -> SFTPPassword {
        try validate(reference, binding)
        let (value, _) = try await perform(read: true) { [self] in
            var bytes = try backend.read(service: service, reference: reference)
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            guard bytes.count > 65, bytes.count <= 4161, bytes.first == 1,
                  bytes.subdata(in: 1..<33) == reference.bindingDigest,
                  bytes.subdata(in: 33..<65) == reference.hostKeyDigest,
                  let text = String(data: bytes.dropFirst(65), encoding: .utf8) else { throw SFTPPasswordFailure.invalidRecord }
            return try SFTPPassword(text)
        }
        if Task.isCancelled { throw SFTPPasswordFailure.cancelled }; return value
    }
    func save(_ password: SFTPPassword, reference: SFTPCredentialReference, binding: SFTPCredentialBinding) async throws -> SFTPPasswordMutation {
        try validate(reference, binding)
        let (_, late) = try await perform(read: false) { [self] in
            var bytes = Data([1]); bytes.append(reference.bindingDigest); bytes.append(reference.hostKeyDigest); bytes.append(password.bytes)
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            try backend.save(service: service, reference: reference, bytes: bytes)
        }; return .init(completedAfterCancellation: late)
    }
    func removeOwned(_ reference: SFTPCredentialReference) async throws -> SFTPPasswordMutation {
        guard reference.bindingDigest.count == 32, reference.hostKeyDigest.count == 32 else { throw SFTPPasswordFailure.invalidRecord }
        let (_, late) = try await perform(read: false) { [self] in try backend.remove(service: service, reference: reference) }
        return .init(completedAfterCancellation: late)
    }
    public func drain() async {
        await withCheckedContinuation { continuation in lock.withLock { queue.async { continuation.resume() } } }
    }
    private func validate(_ reference: SFTPCredentialReference, _ binding: SFTPCredentialBinding) throws {
        guard reference.bindingDigest.count == 32, reference.bindingDigest == binding.digest,
              reference.hostKeyDigest == binding.hostKeyDigest else { throw SFTPPasswordFailure.bindingMismatch }
    }
    private final class Request: @unchecked Sendable {
        private let lock = NSLock(); private var stopped = false
        var cancelled: Bool { lock.withLock { stopped } }
        func cancel() { lock.withLock { stopped = true } }
    }
    private func perform<T: Sendable>(read: Bool, body: @escaping @Sendable () throws -> T) async throws -> (T, Bool) {
        let request = Request()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { request.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard pending < 8 else { lock.unlock(); continuation.resume(throwing: SFTPPasswordFailure.busy); return }; pending += 1
                queue.async { [self] in
                    let result: Result<T, Error> = request.cancelled ? .failure(SFTPPasswordFailure.cancelled) : Result { try body() }
                    let cancelled = request.cancelled; lock.withLock { pending -= 1 }
                    if read && cancelled { continuation.resume(throwing: SFTPPasswordFailure.cancelled) }
                    else { continuation.resume(with: result.map { ($0, cancelled) }) }
                }; lock.unlock()
            }
        } onCancel: { request.cancel() }
    }
}
