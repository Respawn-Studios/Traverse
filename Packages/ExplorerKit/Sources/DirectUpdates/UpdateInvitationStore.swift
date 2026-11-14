import Foundation
import Security

/// Exact app-owned login-Keychain entry only. No account discovery or broad
/// credential query; optional persistence is separate from in-memory use.
public final class UpdateInvitationStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Traverse.UpdateInvitation", qos: .utility)
    private let service: String
    private let account = "invitation"
    private let lock = NSLock()
    private var pending = 0
    public init() { service = "com.respawnstudios.traverse.beta-updates.v1" }
    init(qualification: UUID) { service = "com.respawnstudios.traverse.beta-updates.qualification." + qualification.uuidString }
    public func read() async throws -> PrivateUpdateInvitation? {
        let result: PrivateUpdateInvitation? = try await run {
            var query = self.query
            query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data, data.count <= 512,
                  let value = String(data: data, encoding: .utf8) else { throw Self.failure(status) }
            return try PrivateUpdateInvitation(value)
        }
        try Task.checkCancellation()
        return result
    }
    public func save(_ value: PrivateUpdateInvitation) async throws {
        try await run {
            let update = SecItemUpdate(self.query as CFDictionary, [kSecValueData: value.data] as CFDictionary)
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else { throw Self.failure(update) }
            var query = self.query
            query[kSecValueData as String] = value.data
            query[kSecAttrLabel as String] = "Traverse private beta updates"
            query[kSecAttrSynchronizable as String] = false
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else { throw Self.failure(status) }
        }
    }
    public func forget() async throws {
        try await run {
            let status = SecItemDelete(self.query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
        }
    }
    private var query: [String: Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
         kSecAttrAccount as String:account,kSecUseDataProtectionKeychain as String:false]
    }
    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard lock.withLock({ if pending >= 8 { return false }; pending += 1; return true }) else { throw PrivateUpdateFailure.busy }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                defer { lock.withLock { pending -= 1 } }
                continuation.resume(with: Result { try body() })
            }
        }
    }
    private static func failure(_ value: OSStatus) -> PrivateUpdateFailure {
        switch value { case errSecUserCanceled: .cancelled; case errSecAuthFailed,errSecInteractionNotAllowed: .denied; default: .unavailable }
    }
}
