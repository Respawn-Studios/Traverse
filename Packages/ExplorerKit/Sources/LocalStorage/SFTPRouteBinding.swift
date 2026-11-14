import CryptoKit
import Foundation

@_spi(Qualification) public enum SFTPRouteRole: UInt8, Codable, Sendable { case jump = 1, destination = 2 }

/// A logical route description. It has no verified key, resolved destination
/// address, credential lookup, socket or authority to execute configuration.
@_spi(Qualification) public struct SFTPRouteDescription: Sendable, Equatable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let destination: SFTPServerDraft
    public let jump: SFTPServerDraft
    public init(destination: SFTPServerDraft, jump: SFTPServerDraft) throws {
        try destination.validate(); try jump.validate()
        // An interface index on this Mac does not identify an interface on the
        // jump server. Remote scoped destinations need a different contract.
        guard destination.address.scopeID == 0 else { throw SFTPSettingsFailure.invalidRecord }
        self.destination = destination; self.jump = jump
    }
    public var description: String { "<SFTP connection route>" }
    public var debugDescription: String { description }
    func validate() throws { _ = try Self(destination: destination, jump: jump) }
    func request(for role: SFTPRouteRole) throws -> SFTPConnectionRequest { try (role == .jump ? jump : destination).request }
    /// Names and initial browse paths are presentation/navigation, not separate
    /// accounts. Endpoint spelling is already canonical; account UTF-8 is exact.
    var authorityDigest: Data {
        var bytes = Data("Traverse.SFTP.route.authority.v1\0".utf8)
        for draft in [jump, destination] {
            for field in [Data(draft.address.host.utf8), Data(String(draft.address.port).utf8),
                Data(String(draft.address.scopeID).utf8), Data(draft.account.utf8)] {
                Self.field(field, into: &bytes)
            }
        }
        return Data(SHA256.hash(data: bytes))
    }
    /// Outer authentication precedes the target handshake, so its reference
    /// binds the target's logical endpoint/account, not an unobserved target key.
    /// The destination reference also binds the actual verified outer key.
    func bindingTag(role: SFTPRouteRole, verifiedJumpKeyDigest: Data) throws -> Data {
        try validate(); guard verifiedJumpKeyDigest.count == 32 else { throw SFTPSettingsFailure.invalidRecord }
        var bytes = Data("Traverse.SFTP.route.role.v1\0".utf8)
        bytes.append(role.rawValue); Self.field(authorityDigest, into: &bytes); Self.field(verifiedJumpKeyDigest, into: &bytes)
        return Data(SHA256.hash(data: bytes))
    }
    func passwordBinding(role: SFTPRouteRole, verifiedJumpKeyDigest: Data, peerKeyDigest: Data) throws -> SFTPCredentialBinding {
        try .init(routedTag: bindingTag(role: role, verifiedJumpKeyDigest: verifiedJumpKeyDigest), keyDigest: peerKeyDigest)
    }
    private static func field(_ data: Data, into bytes: inout Data) {
        var count = UInt32(data.count).bigEndian; withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }; bytes.append(data)
    }
}
