import CryptoKit
import ExplorerCore
import Foundation

/// Logical saved-target identity for layouts, separate from host verification,
/// password claims and private-key access. Computing it performs no I/O.
@_spi(Qualification) public enum WorkspaceConnectionBinding {
    private static func digest(_ tag: String, _ fields: [Data]) -> Data {
        var bytes = Data(("Traverse.workspace.connection.v1\0" + tag + "\0").utf8)
        for field in fields {
            var size = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &size) { bytes.append(contentsOf: $0) }; bytes.append(field)
        }
        return Data(SHA256.hash(data: bytes))
    }
    private static func sftpFields(_ draft: SFTPServerDraft) -> [Data] {
        [Data(draft.address.host.utf8), Data(String(draft.address.port).utf8),
         Data(String(draft.address.scopeID).utf8), Data(draft.account.utf8),
         Data([draft.address.components == nil ? 1 : 0])]
    }
    public static func smb(_ draft: SMBServerDraft) -> Data {
        digest("smb", [Data(draft.address.host.utf8), Data(String(draft.address.port).utf8),
            Data(String(draft.address.scopeID).utf8), draft.address.share.wireUTF16,
            Data(draft.account.utf8), Data(draft.domain.utf8), Data(draft.security.rawValue.utf8)])
    }
    public static func sftp(_ draft: SFTPServerDraft) -> Data { digest("sftp", sftpFields(draft)) }
    public static func route(_ description: SFTPRouteDescription) -> Data {
        digest("sftp-one-jump", sftpFields(description.jump) + sftpFields(description.destination))
    }
    public static func smbComponents(_ bookmark: WorkspaceConnectionBookmark) throws -> [SMBRemoteName] {
        try bookmark.validate(); guard bookmark.kind == .smbServer else { throw WorkspaceConnectionBookmark.Failure.invalidReference }
        return try bookmark.components.map { try SMBRemoteName(wireUTF16: $0) }
    }
    public static func sftpComponents(_ bookmark: WorkspaceConnectionBookmark) throws -> [SFTPRemoteName] {
        try bookmark.validate(); guard bookmark.isSFTP else { throw WorkspaceConnectionBookmark.Failure.invalidReference }
        return try bookmark.components.map { try SFTPRemoteName($0) }
    }
}
