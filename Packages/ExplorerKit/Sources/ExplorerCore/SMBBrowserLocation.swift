import Foundation

/// UI identity only. The connected tab's session maps these IDs to exact remote
/// components. A hint never grants access, becomes a URL or restores a socket.
public struct SMBBrowserLocation: Hashable, Sendable {
    public let connectionID: UUID
    public let directoryID: UUID
    public let displayHint: String
    public init(connectionID: UUID, directoryID: UUID, displayHint: String) {
        self.connectionID = connectionID; self.directoryID = directoryID
        // Display is bounded even if an unavailable reference came from a caller.
        self.displayHint = String(displayHint.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(4096))
    }
    public static func == (left: Self, right: Self) -> Bool {
        left.connectionID == right.connectionID && left.directoryID == right.directoryID
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(connectionID); hasher.combine(directoryID) }
}
