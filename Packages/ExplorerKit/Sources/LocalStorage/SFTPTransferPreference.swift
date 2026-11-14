import CryptoKit
import Foundation

/// Nonsecret intent for a FUTURE explicit Connect. This is neither a worker
/// capability nor host verification, key access, a credential or mutation grant.
@_spi(Qualification) public enum SFTPTransferPreference: String, CaseIterable, Codable, Sendable {
    case normal, cautious, readOnly
}

/// Exact metadata target only. Labels are presentation; endpoint/path/account
/// bytes and the complete jump route remain distinct. Never operation authority.
@_spi(Qualification) public struct SFTPConnectionPreferenceBinding: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible {
    private let digest: Data
    public init(server: SFTPServerDraft) { self.init(tag: 1, drafts: [server]) }
    public init(route: SFTPRouteDescription) { self.init(tag: 2, drafts: [route.jump, route.destination]) }
    private init(tag: UInt8, drafts: [SFTPServerDraft]) {
        var bytes = Data("Traverse.SFTP.connection-preference.v1\0".utf8); bytes.append(tag)
        for draft in drafts {
            for field in [Data(draft.address.displayAddress.utf8), Data(draft.account.utf8)] {
                var count = UInt32(field.count).bigEndian
                withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }; bytes.append(field)
            }
        }
        digest = Data(SHA256.hash(data: bytes))
    }
    public var description: String { "<SFTP connection preference target>" }
    public var debugDescription: String { description }
}
