import CoreFoundation
import CryptoKit
import Foundation

@_spi(Qualification) public typealias SFTPSettingsFailure = RemoteSettingsFailure

/// Canonical logical SSH identity. Paths/accounts/aliases never share host trust.
@_spi(Qualification) public struct SFTPHostIdentity: Sendable, Hashable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let host: String
    public let port: UInt16
    public let interfaceScope: UInt32
    public init(address: SFTPConnectionAddress) {
        host = address.host; port = address.port; interfaceScope = address.scopeID
    }
    init(canonicalHost: String, port: UInt16, interfaceScope: UInt32) throws {
        host = canonicalHost; self.port = port; self.interfaceScope = interfaceScope; try validate()
    }
    public var description: String { "<SFTP host identity>" }
    public var debugDescription: String { description }
    func validate() throws {
        let authority = host.contains(":") ? "[\(host)\(interfaceScope == 0 ? "" : "%25\(interfaceScope)")]:\(port)" : "\(host):\(port)"
        guard let parsed = try? RemoteNetworkAuthority(authority, defaultPort: 22), parsed.host == host,
              parsed.port == port, parsed.scopeID == interfaceScope else { throw SFTPSettingsFailure.invalidRecord }
    }
}

extension SFTPHostKey: Codable {
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(Data.self)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(bytes) }
}

@_spi(Qualification) public struct SFTPKnownHost: Sendable, Equatable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let identity: SFTPHostIdentity
    public let key: SFTPHostKey
    public var description: String { "<Remembered SFTP host>" }
    public var debugDescription: String { description }
}

@_spi(Qualification) public struct SFTPServerDraft: Sendable, Equatable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let name: String
    public let address: SFTPConnectionAddress
    public let account: String
    public init(name: String, address: SFTPConnectionAddress, account: String) throws {
        guard !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SFTPSettingsFailure.invalidRecord }
        _ = try SFTPConnectionRequest(address: address, account: account)
        self.name = name; self.address = address; self.account = account
    }
    public var request: SFTPConnectionRequest { get throws { try SFTPConnectionRequest(address: address, account: account) } }
    public var description: String { "<SFTP server description>" }
    public var debugDescription: String { description }
    func validate() throws { _ = try Self(name: name, address: address, account: account) }
}

/// This digest identifies an exact credential claim, not permission to read it.
/// Only an active session's verified host can admit an actual password lookup.
@_spi(Qualification) public struct SFTPCredentialBinding: Sendable {
    let digest: Data
    let hostKeyDigest: Data
    init(request: SFTPConnectionRequest, key: SFTPHostKey) throws {
        try self.init(request: request, keyDigest: Data(SHA256.hash(data: key.bytes)))
    }
    init(request: SFTPConnectionRequest, keyDigest: Data) throws {
        guard keyDigest.count == 32 else { throw SFTPSettingsFailure.invalidRecord }
        let identity = SFTPHostIdentity(address: request.address); try identity.validate()
        var bytes = Data("MacExplorer.SFTP.password.v1\0".utf8)
        for data in [Data(identity.host.utf8), Data(String(identity.port).utf8), Data(String(identity.interfaceScope).utf8), Data(request.account.utf8), keyDigest] {
            var count = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }; bytes.append(data)
        }
        digest = Data(SHA256.hash(data: bytes)); hostKeyDigest = keyDigest
    }
    init(routedTag: Data, keyDigest: Data) throws {
        guard routedTag.count == 32, keyDigest.count == 32 else { throw SFTPSettingsFailure.invalidRecord }
        var bytes = Data("Traverse.SFTP.password.route.v1\0".utf8)
        bytes.append(routedTag); bytes.append(keyDigest)
        digest = Data(SHA256.hash(data: bytes)); hostKeyDigest = keyDigest
    }
}

@_spi(Qualification) public struct SFTPCredentialReference: Sendable, Equatable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    let bindingDigest: Data
    let hostKeyDigest: Data
    init(binding: SFTPCredentialBinding) { id = UUID(); bindingDigest = binding.digest; hostKeyDigest = binding.hostKeyDigest }
    public var description: String { "<SFTP credential reference>" }
    public var debugDescription: String { description }
}

@_spi(Qualification) public struct SFTPSavedServer: Sendable, Equatable, Codable, Identifiable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public internal(set) var details: SFTPServerDraft
    public internal(set) var credentialID: UUID?
    public internal(set) var removalPending: Bool
    public internal(set) var keyAuthentication: SFTPServerKeyAuthentication? = nil
    public internal(set) var defaultDirectory: SFTPDefaultDirectory? = nil
    public internal(set) var transferPreference: SFTPTransferPreference? = nil
    public var effectiveTransferPreference: SFTPTransferPreference { transferPreference ?? .readOnly }
    public var effectiveDefaultDirectory: SFTPDefaultDirectory { get throws { try defaultDirectory ?? .init(legacy: details.address) } }
    var interactiveSignIn: Bool? = nil
    public var usesServerPrompts: Bool { interactiveSignIn == true }
    public var description: String { "<Saved SFTP server>" }
    public var debugDescription: String { description }
}

@_spi(Qualification) public struct SFTPOwnedCredential: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable { case preparing, ready, deleting }
    public let reference: SFTPCredentialReference
    public internal(set) var state: State
}

@_spi(Qualification) public struct SFTPSettingsSnapshot: RemoteSettingsDocument, Sendable, Equatable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    var format = 1
    var protocolIdentity = "sftp-private-state"
    public internal(set) var revision: UInt64 = 0
    public internal(set) var hosts: [SFTPKnownHost] = []
    public internal(set) var servers: [SFTPSavedServer] = []
    public internal(set) var credentials: [SFTPOwnedCredential] = []
    public internal(set) var routes: [SFTPSavedRoute]? = nil
    public internal(set) var forgetAllPending = false
    public var visibleServers: [SFTPSavedServer] { forgetAllPending ? [] : servers.filter { !$0.removalPending } }
    public var visibleHosts: [SFTPKnownHost] { forgetAllPending ? [] : hosts }
    public var visibleRoutes: [SFTPSavedRoute] { forgetAllPending ? [] : (routes ?? []).filter { !$0.removalPending } }
    public var description: String { "<SFTP private settings>" }
    public var debugDescription: String { description }
    func validate() throws {
        guard (1...8).contains(format), protocolIdentity == "sftp-private-state" else { throw SFTPSettingsFailure.incompatibleVersion }
        guard format >= 8 || servers.allSatisfy({ $0.keyAuthentication?.requiresCertificate != true }) else {
            throw SFTPSettingsFailure.incompatibleVersion
        }
        guard format >= 6 || servers.allSatisfy({ $0.transferPreference == nil }) && (routes ?? []).allSatisfy({ $0.transferPreference == nil }) else { throw SFTPSettingsFailure.incompatibleVersion }
        guard format >= 5 || servers.allSatisfy({ $0.defaultDirectory == nil }) && (routes ?? []).allSatisfy({ $0.defaultDirectory == nil }) else { throw SFTPSettingsFailure.incompatibleVersion }
        guard routes == nil || format >= 4 && routes?.isEmpty == false else { throw SFTPSettingsFailure.incompatibleVersion }
        guard format >= 2 || hosts.allSatisfy({ $0.key.algorithm == "ssh-ed25519" }) && servers.allSatisfy({ $0.keyAuthentication == nil }) else {
            throw SFTPSettingsFailure.incompatibleVersion
        }
        guard format >= 3 || servers.allSatisfy({ !$0.usesServerPrompts && $0.keyAuthentication?.requiresServerPrompts != true }) else {
            throw SFTPSettingsFailure.incompatibleVersion
        }
        let routed = routes ?? []
        guard hosts.count + routed.count * 2 <= 128, servers.count + routed.count <= 64, credentials.count <= 128,
              Set(hosts.map(\.identity)).count == hosts.count, Set(servers.map(\.id) + routed.map(\.id)).count == servers.count + routed.count,
              Set(credentials.map { $0.reference.id }).count == credentials.count else { throw SFTPSettingsFailure.capacity }
        for host in hosts { try host.identity.validate(); _ = try SFTPHostKey(host.key.bytes) }
        let claims = Dictionary(uniqueKeysWithValues: credentials.map { ($0.reference.id, $0) }); var linked = Set<UUID>()
        for claim in credentials {
            guard claim.reference.bindingDigest.count == 32, claim.reference.hostKeyDigest.count == 32,
                  !forgetAllPending || claim.state == .deleting else { throw SFTPSettingsFailure.invalidRecord }
        }
        for server in servers {
            if let directory = server.defaultDirectory {
                try directory.validate()
                // Formats 1–6 bind the saved default to the Connect address root.
                // Format 7 permits a separate navigation preference without
                // changing the immutable address or any authentication binding.
                guard format >= 7 || (directory.root == .home) == (server.details.address.components == nil) else {
                    throw SFTPSettingsFailure.invalidRecord
                }
            }
            guard server.interactiveSignIn != false,
                  !server.usesServerPrompts || server.keyAuthentication == nil && server.credentialID == nil else { throw SFTPSettingsFailure.invalidRecord }
            try server.keyAuthentication?.validate()
            if let method = server.keyAuthentication {
                guard server.credentialID == nil else { throw SFTPSettingsFailure.invalidRecord }
                if let reference = method.reference {
                    guard reference.routeBindingDigest == nil,
                          reference.bindingDigest == (try SFTPKeyAccessReference.binding(server.details.request, hostDigest: reference.hostKeyDigest)) else {
                        throw SFTPSettingsFailure.invalidRecord
                    }
                }
                if let certificate = method.certificate {
                    guard certificate.bindingDigest == (try SFTPCertificateAccessReference.binding(server.details.request,
                        hostDigest: certificate.hostKeyDigest, identity: certificate.identity, leafName: certificate.leafName,
                        directoryBookmark: certificate.directoryBookmark)) else { throw SFTPSettingsFailure.invalidRecord }
                }
            }
        }
        for route in routed {
            try route.validate(); guard !forgetAllPending || route.removalPending else { throw SFTPSettingsFailure.invalidRecord }
            if let directory = route.defaultDirectory {
                guard format >= 7 || (directory.root == .home) == (route.details.destination.address.components == nil) else {
                    throw SFTPSettingsFailure.invalidRecord
                }
            }
            for role in [SFTPRouteRole.jump, .destination] {
                guard let id = route.endpoint(role).credentialID else { continue }
                let binding = try route.binding(role)
                guard linked.insert(id).inserted, let claim = claims[id], claim.state == .ready || route.removalPending && claim.state == .deleting,
                      claim.reference.bindingDigest == binding.digest, claim.reference.hostKeyDigest == binding.hostKeyDigest else { throw SFTPSettingsFailure.invalidRecord }
            }
        }
        for server in servers {
            try server.details.validate()
            guard !forgetAllPending || server.removalPending else { throw SFTPSettingsFailure.invalidRecord }
            if let id = server.credentialID {
                guard linked.insert(id).inserted, let claim = claims[id], claim.state == .ready || server.removalPending && claim.state == .deleting,
                      claim.reference.bindingDigest == (try SFTPCredentialBinding(request: server.details.request, keyDigest: claim.reference.hostKeyDigest)).digest else {
                    throw SFTPSettingsFailure.invalidRecord
                }
            }
        }
        guard !forgetAllPending || hosts.isEmpty else { throw SFTPSettingsFailure.invalidRecord }
    }
    func encoded() throws -> Data {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= RemoteSettingsFile<Self>.maximumBytes else { throw SFTPSettingsFailure.capacity }; return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let format = object?["format"] as? NSNumber, CFGetTypeID(format) != CFBooleanGetTypeID() else { throw SFTPSettingsFailure.invalidRecord }
            guard (1...8).contains(format.intValue), object?["protocolIdentity"] as? String == "sftp-private-state" else { throw SFTPSettingsFailure.incompatibleVersion }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard try value.encoded() == bytes else { throw SFTPSettingsFailure.invalidRecord }; return value
        } catch let failure as SFTPSettingsFailure { throw failure }
        catch { throw SFTPSettingsFailure.invalidRecord }
    }
}

enum SFTPSettingsChange: Sendable {
    case updatePresentation(UUID, label: String, directory: SFTPDefaultDirectory, route: Bool,
        transferPreference: SFTPTransferPreference? = nil, expectedBinding: SFTPConnectionPreferenceBinding? = nil)
    case saveMetadata(SFTPServerDraft, directory: SFTPDefaultDirectory, signIn: SFTPRouteSignIn = .password,
        transferPreference: SFTPTransferPreference? = nil, requiresCertificate: Bool = false)
    case saveHost(SFTPKnownHost, replacing: SFTPHostKey?)
    case forgetHost(SFTPHostIdentity)
    case saveServer(SFTPServerDraft, id: UUID?, credentialID: UUID?, keyAuthentication: SFTPServerKeyAuthentication? = nil, serverPrompts: Bool = false)
    case beginPassword(SFTPCredentialBinding), confirmPassword(UUID)
    case beginForgetPassword(UUID), finishForgetPassword(UUID)
    case beginForgetServer(UUID, removePassword: Bool), finishForgetServer(UUID)
    case beginForgetExpectedServer(SFTPSavedServer, removePassword: Bool)
    case beginForgetAll, finishForgetAll
    case saveRoute(SFTPRouteDescription, jump: SFTPSavedRouteEndpoint, destination: SFTPSavedRouteEndpoint, id: UUID?)
    case beginForgetRoute(UUID, removePasswords: Bool), finishForgetRoute(UUID)
    case beginForgetExpectedRoute(SFTPSavedRoute, removePasswords: Bool)
}

@_spi(Qualification) public struct SFTPSettingsMutation: Sendable {
    public let snapshot: SFTPSettingsSnapshot
    public internal(set) var serverID: UUID?
    public internal(set) var routeID: UUID?
    public internal(set) var credential: SFTPCredentialReference?
    public internal(set) var completedAfterCancellation = false
}
