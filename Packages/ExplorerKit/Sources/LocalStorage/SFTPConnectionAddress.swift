import Foundation

@_spi(Qualification) public enum SFTPConnectionInputFailure: Error, Sendable { case address, component, account }

/// Frozen logical identity and exact remote path, never a local URL or a grant.
/// A bare server starts at its account's home; an explicit '/' means server root.
@_spi(Qualification) public struct SFTPConnectionAddress: Sendable, Equatable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public enum HostKind: Int, Sendable { case dns, ipv4, ipv6 }
    public let host: String
    public let hostKind: HostKind
    public let port: UInt16
    public let scopeID: UInt32
    /// Nil = account home. Empty = explicit server root. Raw bytes stay exact.
    public let components: [SFTPRemoteName]?
    public var description: String { "<SFTP address>" }
    public var debugDescription: String { description }
    public var initialPathUTF8: Data {
        guard let components else { return Data([46]) }
        var data = Data([47]); for (index, component) in components.enumerated() {
            if index > 0 { data.append(47) }; data.append(component.wireUTF8)
        }; return data
    }
    /// Explicit display only; server/path names can be private. Never log this.
    public var displayAddress: String {
        let authority = hostKind == .ipv6 ? "[\(host)\(scopeID == 0 ? "" : "%25\(scopeID)")]" : host
        let suffix = port == 22 ? "" : ":\(port)"
        let path = components.map { "/" + $0.map { Self.encode($0.wireUTF8) }.joined(separator: "/") } ?? ""
        return "sftp://\(authority)\(suffix)\(path)"
    }
    /// Values for explicit user-facing fields; never diagnostics or identifiers.
    public var serverField: String { hostKind == .ipv6 ? "[\(host)\(scopeID == 0 ? "" : "%25\(scopeID)")]" : host }
    public var startingFolderField: String { components.map { "/" + $0.map { String(decoding: $0.wireUTF8, as: UTF8.self) }.joined(separator: "/") } ?? "" }
    /// A blank folder means account Home. Literal %, # and ? in a folder are
    /// names, unlike their URI spelling. Existing parsing/size rules stay final.
    public init(server: String, port: UInt16 = 22, startingFolder: String = "") throws {
        let authority: String
        do { authority = try RemoteNetworkAuthority.fieldAuthority(server: server, port: port) }
        catch { throw SFTPConnectionInputFailure.address }
        let path: String
        if startingFolder.isEmpty { path = "" }
        else {
            guard startingFolder.hasPrefix("/"), startingFolder.utf8.count <= 8192 else { throw SFTPConnectionInputFailure.component }
            path = "/" + startingFolder.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(Data($0.utf8)) }.joined(separator: "/")
        }
        try self.init("sftp://" + authority + path)
    }
    public init(_ typed: String) throws {
        guard !typed.isEmpty, typed.utf8.count <= 65536,
              typed == typed.trimmingCharacters(in: .whitespacesAndNewlines),
              !typed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !typed.contains("?"), !typed.contains("#") else { throw SFTPConnectionInputFailure.address }
        let value: Substring
        if typed.prefix(7).lowercased() == "sftp://" { value = typed.dropFirst(7) }
        else { guard !typed.contains("://") else { throw SFTPConnectionInputFailure.address }; value = typed[...] }
        let slash = value.firstIndex(of: "/"), authority = String(slash.map { value[..<$0] } ?? value[...])
        let parsed: RemoteNetworkAuthority
        do { parsed = try RemoteNetworkAuthority(authority, defaultPort: 22) }
        catch { throw SFTPConnectionInputFailure.address }
        host = parsed.host; port = parsed.port; scopeID = parsed.scopeID
        switch parsed.kind { case .dns: hostKind = .dns; case .ipv4: hostKind = .ipv4; case .ipv6: hostKind = .ipv6 }
        if let slash {
            let path = value[value.index(after: slash)...]
            if path.isEmpty { components = [] }
            else {
                var raw = path.split(separator: "/", omittingEmptySubsequences: false)
                if raw.last?.isEmpty == true { raw.removeLast() }
                guard !raw.isEmpty, raw.count <= 128 else { throw SFTPConnectionInputFailure.address }
                components = try raw.map { component in
                    guard let text = String(component).removingPercentEncoding else { throw SFTPConnectionInputFailure.component }
                    do { return try SFTPRemoteName(Data(text.utf8)) } catch { throw SFTPConnectionInputFailure.component }
                }
            }
        } else { components = nil }
        guard initialPathUTF8.count <= 8192 else { throw SFTPConnectionInputFailure.address }
    }
    private static func encode(_ data: Data) -> String {
        let hex = Array("0123456789ABCDEF".utf8); var encoded: [UInt8] = []; encoded.reserveCapacity(data.count * 3)
        for byte in data {
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) { encoded.append(byte) }
            else { encoded.append(contentsOf: [37, hex[Int(byte >> 4)], hex[Int(byte & 15)]]) }
        }; return String(decoding: encoded, as: UTF8.self)
    }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(displayAddress) }
}

@_spi(Qualification) public struct SFTPConnectionRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let address: SFTPConnectionAddress
    public let account: String
    public var description: String { "<SFTP connection request>" }
    public var debugDescription: String { description }
    public init(address: SFTPConnectionAddress, account: String) throws {
        guard !account.isEmpty, account.utf8.count <= 256,
              !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SFTPConnectionInputFailure.account }
        self.address = address; self.account = account
    }
}
