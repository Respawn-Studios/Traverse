import CryptoKit
import Foundation

@_spi(Qualification) public enum SFTPRouteSignIn: String, Sendable, Codable {
    case password, keyFile, serverPrompts, keyFileAndServerPrompts
    public var usesKey: Bool { self == .keyFile || self == .keyFileAndServerPrompts }
    public var usesServerPrompts: Bool { self == .serverPrompts || self == .keyFileAndServerPrompts }
}
@_spi(Qualification) public struct SFTPSavedRouteEndpoint: Sendable, Equatable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let key: SFTPHostKey
    public let signIn: SFTPRouteSignIn
    public internal(set) var credentialID: UUID?
    public let keyAccess: SFTPKeyAccessReference?
    public let profileAlias: String?
    public var description: String { "<saved SFTP route endpoint>" }
    public var debugDescription: String { description }
    init(key: SFTPHostKey, signIn: SFTPRouteSignIn, credentialID: UUID? = nil,
         keyAccess: SFTPKeyAccessReference? = nil, profileAlias: String? = nil) {
        self.key = key; self.signIn = signIn; self.credentialID = credentialID; self.keyAccess = keyAccess; self.profileAlias = profileAlias
    }
    func validate(route: SFTPRouteDescription, role: SFTPRouteRole, jumpKeyDigest: Data) throws {
        _ = try SFTPHostKey(key.bytes)
        guard credentialID == nil || signIn == .password, keyAccess == nil || signIn.usesKey else { throw SFTPSettingsFailure.invalidRecord }
        if let profileAlias {
            guard !profileAlias.isEmpty, profileAlias.utf8.count <= 253,
                  !profileAlias.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SFTPSettingsFailure.invalidRecord }
        }
        if let keyAccess {
            let tag = try route.bindingTag(role: role, verifiedJumpKeyDigest: jumpKeyDigest)
            guard try keyAccess.matches(route.request(for: role), host: key, routeBinding: tag) else { throw SFTPSettingsFailure.invalidRecord }
        }
    }
}
@_spi(Qualification) public struct SFTPSavedRoute: Sendable, Equatable, Codable, Identifiable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let details: SFTPRouteDescription
    public internal(set) var jump: SFTPSavedRouteEndpoint
    public internal(set) var destination: SFTPSavedRouteEndpoint
    public internal(set) var removalPending: Bool
    public internal(set) var defaultDirectory: SFTPDefaultDirectory? = nil
    public internal(set) var transferPreference: SFTPTransferPreference? = nil
    public var effectiveTransferPreference: SFTPTransferPreference { transferPreference ?? .readOnly }
    public var effectiveDefaultDirectory: SFTPDefaultDirectory { get throws { try defaultDirectory ?? .init(legacy: details.destination.address) } }
    public var description: String { "<saved one-jump SFTP connection>" }
    public var debugDescription: String { description }
    var jumpKeyDigest: Data { Data(SHA256.hash(data: jump.key.bytes)) }
    func endpoint(_ role: SFTPRouteRole) -> SFTPSavedRouteEndpoint { role == .jump ? jump : destination }
    func validate() throws {
        try details.validate()
        if let directory = defaultDirectory {
            try directory.validate()
        }
        try jump.validate(route: details, role: .jump, jumpKeyDigest: jumpKeyDigest)
        try destination.validate(route: details, role: .destination, jumpKeyDigest: jumpKeyDigest)
    }
    func binding(_ role: SFTPRouteRole) throws -> SFTPCredentialBinding {
        try details.passwordBinding(role: role, verifiedJumpKeyDigest: jumpKeyDigest,
            peerKeyDigest: Data(SHA256.hash(data: endpoint(role).key.bytes)))
    }
}
