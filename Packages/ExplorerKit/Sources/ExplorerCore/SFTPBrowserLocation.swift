import Foundation

/// Session UI identity, never a local path, saved authority or reconnect token.
public struct SFTPBrowserLocation: Hashable, Sendable {
    public let connectionID: UUID
    public let directoryID: UUID
    public let displayHint: String
    public init(connectionID: UUID, directoryID: UUID, displayHint: String) {
        self.connectionID = connectionID; self.directoryID = directoryID
        self.displayHint = String(displayHint.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(4096))
    }
    public static func == (left: Self, right: Self) -> Bool { left.connectionID == right.connectionID && left.directoryID == right.directoryID }
    public func hash(into hasher: inout Hasher) { hasher.combine(connectionID); hasher.combine(directoryID) }
}
