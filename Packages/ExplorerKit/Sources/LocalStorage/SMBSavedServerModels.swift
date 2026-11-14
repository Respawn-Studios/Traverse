import CoreFoundation
import Foundation

@_spi(Qualification) public typealias SMBServerStoreFailure = RemoteSettingsFailure

/// UI metadata only. Constructing this value performs no lookup or authentication.
@_spi(Qualification) public struct SMBServerDraft: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let name: String
    public let address: SMBConnectionAddress
    public let account: String
    public let domain: String
    public let security: SMBWorkerSecurityPolicy
    /// Nil is the exact legacy saved shape and grants read-only access.
    public let transferPreference: SFTPTransferPreference?
    public var effectiveTransferPreference: SFTPTransferPreference { transferPreference ?? .readOnly }
    public var description: String { "<SMB server description>" }
    public var debugDescription: String { description }
    public init(name: String, address: SMBConnectionAddress, account: String, domain: String, security: SMBWorkerSecurityPolicy,
                transferPreference: SFTPTransferPreference? = nil) throws {
        guard !name.isEmpty, name.utf8.count <= 128, !account.isEmpty, account.utf8.count <= 256,
              domain.utf8.count <= 256, !["guest", "anonymous"].contains(account.lowercased()),
              !(name + account + domain).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SMBServerStoreFailure.invalidRecord
        }
        self.name = name; self.address = address; self.account = account; self.domain = domain; self.security = security
        self.transferPreference = transferPreference
    }
    public func credentialBinding() throws -> SMBCredentialBinding {
        try SMBCredentialBinding(host: address.host, port: address.port, share: address.share.displayName,
            account: account, domain: domain, interfaceScope: address.scopeID)
    }
    func validate() throws {
        _ = try Self(name: name, address: address, account: account, domain: domain, security: security, transferPreference: transferPreference)
    }
    private enum CodingKeys: String, CodingKey { case name, address, account, domain, security, transferPreference }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: c.decode(String.self, forKey: .name), address: c.decode(SMBConnectionAddress.self, forKey: .address),
            account: c.decode(String.self, forKey: .account), domain: c.decode(String.self, forKey: .domain),
            security: c.decode(SMBWorkerSecurityPolicy.self, forKey: .security),
            transferPreference: c.decodeIfPresent(SFTPTransferPreference.self, forKey: .transferPreference))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(address, forKey: .address)
        try c.encode(account, forKey: .account); try c.encode(domain, forKey: .domain)
        try c.encode(security, forKey: .security)
        try c.encodeIfPresent(transferPreference, forKey: .transferPreference)
    }
}

@_spi(Qualification) public struct SMBSavedServer: Sendable, Equatable, Codable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public internal(set) var details: SMBServerDraft
    public internal(set) var credentialID: UUID?
    public internal(set) var removalPending: Bool
    public var description: String { "<Saved SMB server>" }
    public var debugDescription: String { description }
}

@_spi(Qualification) public struct SMBOwnedCredential: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable { case preparing, ready, deleting }
    public let reference: SMBCredentialReference
    public internal(set) var state: State
}

/// Includes pending cleanup authority, but never a password. Use visibleServers
/// for ordinary display; hidden rows must not reappear after interrupted Forget.
@_spi(Qualification) public struct SMBServerSnapshot: RemoteSettingsDocument, Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    var format: Int = 1
    public internal(set) var revision: UInt64 = 0
    public internal(set) var servers: [SMBSavedServer] = []
    public internal(set) var credentials: [SMBOwnedCredential] = []
    public var visibleServers: [SMBSavedServer] { servers.filter { !$0.removalPending } }
    public var description: String { "<SMB server snapshot>" }
    public var debugDescription: String { description }
    func validate() throws {
        guard format == 1 || format == 2 else { throw SMBServerStoreFailure.incompatibleVersion }
        guard format == 2 || servers.allSatisfy({ $0.details.transferPreference == nil }) else { throw SMBServerStoreFailure.incompatibleVersion }
        guard servers.count <= 64, credentials.count <= 128,
              Set(servers.map(\.id)).count == servers.count,
              Set(credentials.map { $0.reference.id }).count == credentials.count else { throw SMBServerStoreFailure.capacity }
        let claims = Dictionary(uniqueKeysWithValues: credentials.map { ($0.reference.id, $0) })
        var linked = Set<UUID>()
        for credential in credentials {
            guard credential.reference.bindingDigest.count == 32 else { throw SMBServerStoreFailure.invalidRecord }
        }
        for server in servers {
            try server.details.validate()
            if let id = server.credentialID {
                guard linked.insert(id).inserted, let claim = claims[id],
                      claim.state == .ready || server.removalPending && claim.state == .deleting,
                      claim.reference.bindingDigest == (try server.details.credentialBinding()).digest else {
                    throw SMBServerStoreFailure.invalidRecord
                }
            }
        }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self); data.append(10)
        guard data.count <= SMBServerFile.maximumBytes else { throw SMBServerStoreFailure.capacity }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        do {
            // Look at the version before decoding a possibly incompatible shape.
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let number = object?["format"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { throw SMBServerStoreFailure.invalidRecord }
            guard number.intValue == 1 || number.intValue == 2 else { throw SMBServerStoreFailure.incompatibleVersion }
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard try value.encoded() == data else { throw SMBServerStoreFailure.invalidRecord }
            return value
        } catch let error as SMBServerStoreFailure { throw error }
        catch { throw SMBServerStoreFailure.invalidRecord }
    }
}

@_spi(Qualification) public enum SMBServerChange: Sendable {
    case updatePresentation(UUID, label: String, components: [SMBRemoteName])
    case saveServer(SMBServerDraft, id: UUID?, credentialID: UUID?)
    case beginPassword(SMBCredentialBinding)
    case confirmPassword(UUID)
    case beginForgetPassword(UUID)
    case finishForgetPassword(UUID)
    case beginForgetServer(UUID, removePassword: Bool)
    case beginForgetExpectedServer(SMBSavedServer, removePassword: Bool)
    case finishForgetServer(UUID)
}

@_spi(Qualification) public struct SMBServerMutation: Sendable {
    public let snapshot: SMBServerSnapshot
    public let serverID: UUID?
    public let credentialReference: SMBCredentialReference?
    /// A cancellation arriving after admission cannot undo a committed change.
    public let completedAfterCancellation: Bool
}
