import Foundation

/// A literal folder path inside the current share, not a saved connection or
/// proof of access. The source session resolves and pins its ancestry again.
@_spi(Qualification) public struct SMBMoveDestination: Sendable, Equatable,
    CustomDebugStringConvertible {
    public let components: [SMBRemoteName]
    public var debugDescription: String { "<SMB move destination>" }
    public var path: String { "/" + components.map(\.displayName).joined(separator: "/") }

    public init(components: [SMBRemoteName]) throws {
        guard Self.validParent(components) else { throw SMBActionFailure.invalidInput }
        self.components = components
    }

    public init(field: String) throws {
        guard field.hasPrefix("/"), field.utf8.count <= 8192 else { throw SMBActionFailure.invalidInput }
        if field == "/" { try self.init(components: []); return }
        var suffix = field.dropFirst()
        if suffix.last == "/" { suffix = suffix.dropLast() }
        guard !suffix.isEmpty else { throw SMBActionFailure.invalidInput }
        let components = try suffix.split(separator: "/", omittingEmptySubsequences: false)
            .map { try SMBRemoteName(String($0)) }
        try self.init(components: components)
    }

    static func validParent(_ path: [SMBRemoteName]) -> Bool {
        path.count <= 32 && path.allSatisfy(SMBUploadName.safe)
            && units(path) <= 1792
    }
    static func units(_ path: [SMBRemoteName]) -> Int {
        path.reduce(0) { $0 + $1.wireUTF16.count / 2 } + max(0, path.count - 1)
    }
    static func validMove(sourceDirectory: [SMBRemoteName], name: SMBRemoteName,
                          isDirectory: Bool, destination: [SMBRemoteName]) -> Bool {
        guard validParent(sourceDirectory), validParent(destination), SMBUploadName.safe(name),
              sourceDirectory != destination,
              units(destination) + (destination.isEmpty ? 0 : 1) + name.wireUTF16.count / 2 <= 2048 else { return false }
        // A positive lexical refusal only. The worker also compares retained
        // object identities to catch alternate spellings and server aliases.
        return !isDirectory || !destination.starts(with: sourceDirectory + [name])
    }
    static func validCopy(sourceDirectory: [SMBRemoteName], source: SMBRemoteName,
                          destination: [SMBRemoteName], target: SMBRemoteName?) -> Bool {
        guard validParent(sourceDirectory), validParent(destination), SMBUploadName.safe(source),
              let target, SMBUploadName.safe(target),
              units(destination) + (destination.isEmpty ? 0 : 1) + target.wireUTF16.count / 2 <= 2048,
              !target.displayName.lowercased().hasPrefix(".traverse-smb-copy-") else { return false }
        return sourceDirectory != destination || source.displayName.lowercased() != target.displayName.lowercased()
    }
}
