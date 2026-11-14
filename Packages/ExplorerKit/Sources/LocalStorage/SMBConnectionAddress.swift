import Foundation

@_spi(Qualification) public enum SMBConnectionInputFailure: Error, Sendable { case address, component, account }

/// Exact remote spelling. Swift String's canonical equivalence is not SMB identity.
@_spi(Qualification) public struct SMBRemoteName: Sendable, Hashable, Codable {
    public let wireUTF16: Data
    public var displayName: String {
        let bytes = Array(wireUTF16)
        return String(decoding: stride(from: 0, to: bytes.count, by: 2).map {
            UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
        }, as: UTF16.self)
    }
    public init(_ name: String) throws {
        let units = Array(name.utf16)
        guard !units.isEmpty, units.count <= 2048, name.utf8.count <= 4096,
              name != ".", name != "..", !name.unicodeScalars.contains(where: {
                  $0 == "/" || $0 == "\\" || CharacterSet.controlCharacters.contains($0)
              }) else { throw SMBConnectionInputFailure.component }
        wireUTF16 = Data(units.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
    }
    public init(from decoder: any Decoder) throws {
        try self.init(wireUTF16: decoder.singleValueContainer().decode(Data.self))
    }
    public init(wireUTF16 data: Data) throws {
        guard !data.isEmpty, data.count <= 4096, data.count % 2 == 0 else { throw SMBConnectionInputFailure.component }
        let bytes = Array(data)
        let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        let name = String(decoding: units, as: UTF16.self)
        try self.init(name)
        guard wireUTF16 == data else { throw SMBConnectionInputFailure.component } // No lossy surrogate repair.
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(wireUTF16)
    }
}

/// A logical endpoint and opaque path, never a local file URL or saved access grant.
@_spi(Qualification) public struct SMBConnectionAddress: Sendable, Equatable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public enum HostKind: Int, Sendable { case dns, ipv4, ipv6 }
    public let host: String
    public let hostKind: HostKind
    public let port: UInt16
    public let scopeID: UInt32
    public let share: SMBRemoteName
    public let components: [SMBRemoteName]
    public var description: String { "<SMB address>" }
    public var debugDescription: String { description }
    /// For explicit UI only. This can reveal private server/path names; do not log it.
    public var displayAddress: String {
        let authority = hostKind == .ipv6 ? "[\(host)\(scopeID == 0 ? "" : "%25\(scopeID)")]" : host
        let suffix = port == 445 ? "" : ":\(port)"
        return "smb://\(authority)\(suffix)/" + ([share] + components).map {
            $0.displayName.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
        }.joined(separator: "/")
    }
    public var serverField: String { hostKind == .ipv6 ? "[\(host)\(scopeID == 0 ? "" : "%25\(scopeID)")]" : host }
    public var startingFolderField: String { components.isEmpty ? "" : "/" + components.map(\.displayName).joined(separator: "/") }
    /// Shares and folder fields contain literal names, rather than URI escapes.
    public init(server: String, port: UInt16 = 445, share: String, startingFolder: String = "") throws {
        let authority: String
        do { authority = try RemoteNetworkAuthority.fieldAuthority(server: server, port: port) }
        catch { throw SMBConnectionInputFailure.address }
        _ = try SMBRemoteName(share)
        guard startingFolder.isEmpty || startingFolder.hasPrefix("/"), startingFolder.utf8.count <= 8192 else { throw SMBConnectionInputFailure.component }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let path = startingFolder.isEmpty || startingFolder == "/" ? [] : startingFolder.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let encoded = try ([share] + path).map { name -> String in
            _ = try SMBRemoteName(name)
            guard let value = name.addingPercentEncoding(withAllowedCharacters: allowed) else { throw SMBConnectionInputFailure.component }; return value
        }.joined(separator: "/")
        try self.init("smb://" + authority + "/" + encoded)
    }
    public init(_ typed: String) throws {
        guard !typed.isEmpty, typed.utf8.count <= 65536,
              typed == typed.trimmingCharacters(in: .whitespacesAndNewlines),
              !typed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !typed.contains("?"), !typed.contains("#"), !typed.contains("\\") else { throw SMBConnectionInputFailure.address }
        let value: Substring
        if typed.prefix(6).lowercased() == "smb://" { value = typed.dropFirst(6) }
        else {
            guard !typed.contains("://") else { throw SMBConnectionInputFailure.address }
            value = typed[...]
        }
        guard let slash = value.firstIndex(of: "/") else { throw SMBConnectionInputFailure.address }
        let authority = String(value[..<slash])
        let parsed: RemoteNetworkAuthority
        do { parsed = try RemoteNetworkAuthority(authority, defaultPort: 445) }
        catch { throw SMBConnectionInputFailure.address }
        host = parsed.host
        switch parsed.kind { case .dns: hostKind = .dns; case .ipv4: hostKind = .ipv4; case .ipv6: hostKind = .ipv6 }
        port = parsed.port; scopeID = parsed.scopeID
        var rawParts = value[value.index(after: slash)...].split(separator: "/", omittingEmptySubsequences: false)
        if rawParts.last?.isEmpty == true { rawParts.removeLast() }
        guard !rawParts.isEmpty, rawParts.count <= 129 else { throw SMBConnectionInputFailure.address }
        let parts = try rawParts.map { piece -> SMBRemoteName in
            guard let decoded = String(piece).removingPercentEncoding else { throw SMBConnectionInputFailure.component }
            return try SMBRemoteName(decoded)
        }
        guard parts[0].displayName.utf8.count <= 256, parts.dropFirst().reduce(0, { $0 + $1.wireUTF16.count + 2 }) <= 8192 else { throw SMBConnectionInputFailure.address }
        share = parts[0]; components = Array(parts.dropFirst())
    }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(displayAddress)
    }
}
