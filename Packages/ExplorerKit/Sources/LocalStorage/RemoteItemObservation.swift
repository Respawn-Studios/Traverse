import Foundation

/// Immutable listing facts only. Carries no URL, session, credential, source
/// handle or file-operation authority. Intentionally has no Codable conformance.
@_spi(Qualification) public struct RemoteItemObservation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case file, folder, link, other, unknown }
    public enum PathRoot: Sendable, Equatable { case smbShare(String), sftpHome, sftpAbsolute }
    public enum Failure: Error { case bound }
    public let name: String
    public let displayPath: String
    public let copyName: String?
    public let copyPath: String?
    public let pathRoot: PathRoot
    public let kind: Kind
    public let logicalBytes: UInt64?
    public let modified: Date?
    public let permissions: UInt32?
    public let listingComplete: Bool

    public init(smb row: SMBDirectoryObservation, directory: [SMBRemoteName], share: SMBRemoteName, listingComplete: Bool) throws {
        guard directory.count <= 128,
              directory.reduce(row.name.wireUTF16.count, { $0 + $1.wireUTF16.count + 2 }) <= 16_384 else { throw Failure.bound }
        let path = (directory + [row.name]).map(\.displayName).joined(separator: "/")
        name = row.name.displayName; displayPath = path; copyName = Self.safeLine(name); copyPath = Self.safeLine(path)
        pathRoot = .smbShare(share.displayName)
        kind = row.isReparsePoint ? .link : row.isDirectory ? .folder : .file
        logicalBytes = kind == .file ? row.logicalBytes : nil
        if row.modifiedFileTime == 0 { modified = nil }
        else {
            let seconds = Double(row.modifiedFileTime) / 10_000_000 - 11_644_473_600
            modified = (-62_135_596_800.0...253_402_300_799.0).contains(seconds) ? Date(timeIntervalSince1970: seconds) : nil
        }
        permissions = nil; self.listingComplete = listingComplete
    }

    public init(sftp row: SFTPStoredRow, directory: [SFTPRemoteName], homeRelative: Bool, listingComplete: Bool) throws {
        guard directory.count <= 128,
              directory.reduce(row.entry.name.wireUTF8.count, { $0 + $1.wireUTF8.count + 1 }) <= 16_384 else { throw Failure.bound }
        let parts = directory + [row.entry.name], prefix = homeRelative ? "./" : "/"
        name = row.entry.name.displayName
        displayPath = prefix + parts.map(\.displayName).joined(separator: "/")
        copyName = Self.safeLine(String(decoding: row.entry.name.wireUTF8, as: UTF8.self))
        copyPath = Self.safeLine(prefix + parts.map { String(decoding: $0.wireUTF8, as: UTF8.self) }.joined(separator: "/"))
        pathRoot = homeRelative ? .sftpHome : .sftpAbsolute
        if let mode = row.entry.permissions {
            switch mode & 0o170000 {
            case 0o100000: kind = .file
            case 0o040000: kind = .folder
            case 0o120000: kind = .link
            default: kind = .other
            }
        } else { kind = .unknown }
        logicalBytes = kind == .file ? row.entry.logicalBytes : nil
        modified = row.entry.modifiedSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        permissions = row.entry.permissions; self.listingComplete = listingComplete
    }

    private static func safeLine(_ text: String) -> String? {
        guard text.utf8.count <= 32_768, !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
                || [0x061c,0x200e,0x200f].contains($0.value)
                || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value)
        }) else { return nil }
        return text
    }
}
