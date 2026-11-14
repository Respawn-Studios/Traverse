import Foundation

/// A saved navigation preference, never an SSH identity or access grant.
@_spi(Qualification) public struct SFTPDefaultDirectory: Sendable, Equatable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public enum Root: String, Sendable, Codable { case home, server }
    public enum Failure: Error, Sendable { case invalidDirectory, incompatibleRoot }
    public let root: Root
    public let components: [SFTPRemoteName]
    public var description: String { "<SFTP default directory>" }
    public var debugDescription: String { description }

    public init(root: Root, components: [SFTPRemoteName] = []) throws {
        self.root = root; self.components = components; try validate()
    }
    /// Exact fallback for every legacy saved record. Nil is Home; a present
    /// array is an absolute server path, including the empty server root.
    public init(legacy address: SFTPConnectionAddress) throws {
        try self.init(root: address.components == nil ? .home : .server,
                      components: address.components ?? [])
    }
    public func validate() throws {
        guard components.count <= 128,
              components.reduce(1, { $0 + 1 + $1.wireUTF8.count }) <= 8192 else {
            throw Failure.invalidDirectory
        }
        for component in components { _ = try SFTPRemoteName(component.wireUTF8) }
    }
    /// Explicit saved-field editing preserves its configured root. Literal %, #
    /// and ? remain filename bytes, not URI escapes. No filesystem resolution.
    public init(field: String, root: Root) throws {
        guard field.utf8.count <= 8192,
              !field.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidDirectory
        }
        let suffix: Substring
        switch root {
        case .home:
            guard !field.hasPrefix("/") else { throw Failure.incompatibleRoot }
            if field.isEmpty || field == "~" || field == "~/" { suffix = "" }
            else if field.hasPrefix("~/") { suffix = field.dropFirst(2) }
            else { suffix = Substring(field) }
        case .server:
            guard field.hasPrefix("/") else { throw Failure.incompatibleRoot }
            suffix = field.dropFirst()
        }
        let names: [SFTPRemoteName]
        if suffix.isEmpty { names = [] }
        else { names = try suffix.split(separator: "/", omittingEmptySubsequences: false).map { try SFTPRemoteName(Data($0.utf8)) } }
        try self.init(root: root, components: names)
    }
    /// A worker-observed REALPATH is already canonical. Preserve its literal
    /// UTF-8 components, including names that cannot be entered in a field.
    static func observedCanonicalServerPath(_ path: String) throws -> Self {
        let bytes = Data(path.utf8)
        guard bytes.first == 47, bytes.count <= 8192 else { throw Failure.invalidDirectory }
        if bytes.count == 1 { return try .init(root: .server) }
        let names = try bytes.dropFirst().split(separator: 47, omittingEmptySubsequences: false)
            .map { try SFTPRemoteName(Data($0)) }
        let result = try Self(root: .server, components: names)
        guard result.pathUTF8 == bytes else { throw Failure.invalidDirectory }
        return result
    }
    /// Explicit user-facing text only. Never include this in diagnostics.
    public var fieldText: String {
        let names = components.map { String(decoding: $0.wireUTF8, as: UTF8.self) }.joined(separator: "/")
        return root == .home ? (names.isEmpty ? "~" : "~/" + names) : "/" + names
    }
    /// Names which require escaped presentation cannot roundtrip through a
    /// literal editable field. Breadcrumbs/pins still retain their exact bytes.
    public var editableFieldText: String? {
        components.allSatisfy(\.isSafeForSingleLineEntry) ? fieldText : nil
    }
    public var pathUTF8: Data {
        var value = Data(root == .home ? [46] : [47])
        for (index, component) in components.enumerated() {
            if root == .home || index > 0 { value.append(47) }
            value.append(component.wireUTF8)
        }
        return value
    }
    private enum CodingKeys: String, CodingKey { case root, components }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(root: fields.decode(Root.self, forKey: .root),
            components: fields.decode([Data].self, forKey: .components).map { try SFTPRemoteName($0) })
    }
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(root, forKey: .root)
        try fields.encode(components.map(\.wireUTF8), forKey: .components)
    }
}
