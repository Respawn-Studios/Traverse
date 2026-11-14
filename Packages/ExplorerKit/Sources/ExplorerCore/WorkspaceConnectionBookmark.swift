import Foundation

/// A private layout preference, never a connection or credential/access grant.
/// Components retain the exact provider spelling; no URL or shell is involved.
public struct WorkspaceConnectionBookmark: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: String, Codable, Sendable { case smbServer, sftpServer, sftpRoute }
    public enum Failure: Error, Equatable, Sendable { case invalidReference, invalidDirectory }
    public let kind: Kind
    public let serverID: UUID
    public let binding: Data
    public let title: String
    public let components: [Data]
    public let relativeToHome: Bool
    public var isSFTP: Bool { kind != .smbServer }
    public var description: String { "<saved workspace connection>" }
    public var debugDescription: String { description }

    public init(kind: Kind, serverID: UUID, binding: Data, title: String,
                components: [Data] = [], relativeToHome: Bool = false) throws {
        self.kind = kind; self.serverID = serverID; self.binding = binding
        self.title = title; self.components = components; self.relativeToHome = relativeToHome
        try validate()
    }
    public func validate() throws {
        guard binding.count == 32, !title.isEmpty, title.utf8.count <= 512,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              isSFTP || !relativeToHome else { throw Failure.invalidReference }
        guard components.count <= 128 else { throw Failure.invalidDirectory }
        if isSFTP {
            guard components.reduce(1, { $0 + 1 + $1.count }) <= 8192 else { throw Failure.invalidDirectory }
            for part in components {
                guard !part.isEmpty, let text = String(data: part, encoding: .utf8), Data(text.utf8) == part,
                      part != Data([46]), part != Data([46,46]), !part.contains(0), !part.contains(47) else {
                    throw Failure.invalidDirectory
                }
            }
        } else {
            guard components.reduce(0, { $0 + $1.count / 2 }) + max(0, components.count - 1) <= 4096 else {
                throw Failure.invalidDirectory
            }
            for part in components {
                guard !part.isEmpty, part.count <= 4096, part.count % 2 == 0 else { throw Failure.invalidDirectory }
                let bytes = Array(part)
                let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
                let text = String(decoding: units, as: UTF16.self)
                let exact = Data(text.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
                guard exact == part, text != ".", text != "..", text.utf8.count <= 4096,
                      !text.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || CharacterSet.controlCharacters.contains($0) }) else {
                    throw Failure.invalidDirectory
                }
            }
        }
    }
    public func directory(_ components: [Data]) throws -> Self {
        try .init(kind: kind, serverID: serverID, binding: binding, title: title,
                  components: components, relativeToHome: relativeToHome)
    }
    public func matches(_ location: BrowserLocation) -> Bool {
        switch location { case .sftp: isSFTP; case .smb: !isSFTP; default: false }
    }
    /// Opaque IDs are deliberately fresh for every restored/duplicated tab.
    /// They have no owner and cannot resolve a remote request until Connect.
    public func disconnectedTab() throws -> BrowserTab {
        try validate()
        let connection = UUID(), directory = UUID()
        let location: BrowserLocation = isSFTP
            ? .sftp(.init(connectionID: connection, directoryID: directory, displayHint: title))
            : .smb(.init(connectionID: connection, directoryID: directory, displayHint: title))
        var tab = BrowserTab(location: location); tab.connectionBookmark = self; return tab
    }
}
