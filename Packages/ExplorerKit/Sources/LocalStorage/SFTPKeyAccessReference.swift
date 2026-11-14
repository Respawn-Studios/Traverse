import CryptoKit
import Foundation

/// A private security-scoped reference, not key contents or a saved passphrase.
/// Its use is bound to the exact verified host/account and selected public key.
@_spi(Qualification) public struct SFTPKeyAccessReference: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    let bookmark: Data
    let bindingDigest: Data, hostKeyDigest: Data
    var routeBindingDigest: Data? = nil
    public let identity: SFTPHostKey
    public var description: String { "<remembered SSH key access>" }
    public var debugDescription: String { description }
    init(bookmark: Data, request: SFTPConnectionRequest, host: SFTPHostKey, identity: SFTPHostKey, routeBinding: Data? = nil) throws {
        self.bookmark = bookmark; hostKeyDigest = Data(SHA256.hash(data: host.bytes)); self.identity = identity
        routeBindingDigest = routeBinding
        bindingDigest = try Self.binding(request, hostDigest: hostKeyDigest, routeBinding: routeBinding); try validate()
    }
    func validate() throws {
        guard !bookmark.isEmpty, bookmark.count <= 16384, bindingDigest.count == 32, hostKeyDigest.count == 32,
              routeBindingDigest == nil || routeBindingDigest?.count == 32 else { throw SFTPSettingsFailure.invalidRecord }
        _ = try SFTPHostKey(identity.bytes)
    }
    func matches(_ request: SFTPConnectionRequest, host: SFTPHostKey, routeBinding: Data? = nil) throws -> Bool {
        try validate()
        guard hostKeyDigest == Data(SHA256.hash(data: host.bytes)), routeBindingDigest == routeBinding else { return false }
        return bindingDigest == (try Self.binding(request, hostDigest: hostKeyDigest, routeBinding: routeBinding))
    }
    static func binding(_ request: SFTPConnectionRequest, hostDigest: Data, routeBinding: Data? = nil) throws -> Data {
        guard hostDigest.count == 32, routeBinding == nil || routeBinding?.count == 32 else { throw SFTPSettingsFailure.invalidRecord }
        let identity = SFTPHostIdentity(address: request.address); try identity.validate()
        var bytes = Data((routeBinding == nil ? "Traverse.SFTP.key-access.v1\0" : "Traverse.SFTP.key-access.route.v1\0").utf8)
        if let routeBinding { bytes.append(routeBinding) }
        for data in [Data(identity.host.utf8), Data(String(identity.port).utf8), Data(String(identity.interfaceScope).utf8), Data(request.account.utf8), hostDigest] {
            var count = UInt32(data.count).bigEndian; withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }; bytes.append(data)
        }
        return Data(SHA256.hash(data: bytes))
    }
}

/// Read-only authority for one renewable certificate name in one explicitly
/// granted directory. No certificate body, PIN or passphrase is stored here.
@_spi(Qualification) public struct SFTPCertificateAccessReference: Sendable, Equatable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    let directoryBookmark: Data
    let leafName: String
    let bindingDigest: Data, hostKeyDigest: Data
    public let identity: SFTPHostKey
    public var description: String { "<remembered SSH user certificate access>" }
    public var debugDescription: String { description }
    init(directoryBookmark: Data, leafName: String, request: SFTPConnectionRequest,
         host: SFTPHostKey, identity: SFTPHostKey) throws {
        self.directoryBookmark = directoryBookmark; self.leafName = leafName
        hostKeyDigest = Data(SHA256.hash(data: host.bytes)); self.identity = identity
        bindingDigest = try Self.binding(request, hostDigest: hostKeyDigest, identity: identity,
            leafName: leafName, directoryBookmark: directoryBookmark)
        try validate()
    }
    func validate() throws {
        guard !directoryBookmark.isEmpty, directoryBookmark.count <= 16384,
              SSHSelectedFile.validLeaf(leafName), bindingDigest.count == 32, hostKeyDigest.count == 32 else {
            throw SFTPSettingsFailure.invalidRecord
        }
        _ = try SFTPHostKey(identity.bytes)
    }
    func matches(_ request: SFTPConnectionRequest, host: SFTPHostKey, identity: SFTPHostKey) throws -> Bool {
        try validate()
        guard hostKeyDigest == Data(SHA256.hash(data: host.bytes)), self.identity == identity else { return false }
        return bindingDigest == (try Self.binding(request, hostDigest: hostKeyDigest, identity: identity,
            leafName: leafName, directoryBookmark: directoryBookmark))
    }
    static func binding(_ request: SFTPConnectionRequest, hostDigest: Data, identity: SFTPHostKey,
                        leafName: String, directoryBookmark: Data) throws -> Data {
        guard hostDigest.count == 32, SSHSelectedFile.validLeaf(leafName),
              !directoryBookmark.isEmpty, directoryBookmark.count <= 16384 else { throw SFTPSettingsFailure.invalidRecord }
        let host = SFTPHostIdentity(address: request.address); try host.validate()
        var bytes = Data("Traverse.SFTP.user-certificate-access.v1\0".utf8)
        for value in [Data(host.host.utf8), Data(String(host.port).utf8), Data(String(host.interfaceScope).utf8),
                      Data(request.account.utf8), hostDigest, identity.bytes, Data(leafName.utf8),
                      Data(SHA256.hash(data: directoryBookmark))] {
            var count = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }; bytes.append(value)
        }
        return Data(SHA256.hash(data: bytes))
    }
}

@_spi(Qualification) public struct SFTPServerKeyAuthentication: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let reference: SFTPKeyAccessReference?
    public let certificate: SFTPCertificateAccessReference?
    public let profileAlias: String?
    private let serverPrompts: Bool?
    private let certificateRequired: Bool?
    public var requiresServerPrompts: Bool { serverPrompts == true }
    public var requiresCertificate: Bool { certificateRequired == true }
    public init(reference: SFTPKeyAccessReference? = nil, certificate: SFTPCertificateAccessReference? = nil,
                profileAlias: String? = nil, requiresServerPrompts: Bool = false,
                requiresCertificate: Bool = false) throws {
        self.reference = reference; self.certificate = certificate; self.profileAlias = profileAlias
        self.serverPrompts = requiresServerPrompts ? true : nil
        certificateRequired = requiresCertificate || certificate != nil ? true : nil
        try validate()
    }
    public var description: String { "<saved SSH key method>" }
    public var debugDescription: String { description }
    func validate() throws {
        guard serverPrompts != false, certificateRequired != false else { throw SFTPSettingsFailure.invalidRecord }
        if let alias = profileAlias {
            guard !alias.isEmpty, alias.utf8.count <= 253, !alias.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SFTPSettingsFailure.invalidRecord }
        }
        try reference?.validate()
        try certificate?.validate()
        if requiresCertificate {
            guard (reference == nil) == (certificate == nil) else { throw SFTPSettingsFailure.invalidRecord }
        } else { guard certificate == nil else { throw SFTPSettingsFailure.invalidRecord } }
        if let certificate {
            guard let reference, certificate.identity == reference.identity,
                  certificate.hostKeyDigest == reference.hostKeyDigest else { throw SFTPSettingsFailure.invalidRecord }
        }
    }
}
