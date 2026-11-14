import Foundation

/// A literal, case-insensitive name query over one observed remote directory.
/// This is display selection only: it neither reads file bodies nor grants any
/// operation authority. Do not include its text in diagnostics or descriptions.
@_spi(Qualification) public struct RemoteDirectoryFindQuery: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) throws {
        guard id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              !text.isEmpty, text.utf8.count <= 2_048, !text.contains("\0") else {
            throw RemoteDirectoryFindFailure.invalidInput
        }
        self.id = id; self.text = text
    }

    public var description: String { "<remote directory Find>" }
    public var debugDescription: String { description }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
}

/// These failures concern only the local metadata query. A stale or bounded-out
/// Find must not be mistaken for a disconnected authenticated server session.
@_spi(Qualification) public enum RemoteDirectoryFindFailure: Error, Sendable, Equatable {
    case invalidInput, stale, unavailable
}

@_spi(Qualification) public struct SFTPDirectoryFindResult: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let query: RemoteDirectoryFindQuery
    public let generation: UUID
    public let snapshot: SFTPStoredSnapshot
    public let count: UInt64
    public let folders: UInt64

    public init(query: RemoteDirectoryFindQuery, generation: UUID, snapshot: SFTPStoredSnapshot,
                count: UInt64, folders: UInt64) throws {
        guard count <= snapshot.count, folders <= count, folders <= snapshot.folders else {
            throw RemoteDirectoryFindFailure.invalidInput
        }
        self.query = query; self.generation = generation; self.snapshot = snapshot
        self.count = count; self.folders = folders
    }

    public var description: String { "<SFTP directory Find result>" }
    public var debugDescription: String { description }
}

#if !SFTP_PARENT_STANDALONE
@_spi(Qualification) public struct SMBDirectoryFindResult: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let query: RemoteDirectoryFindQuery
    public let snapshot: SMBDirectorySnapshot
    public let count: Int64
    public let folders: Int64

    public init(query: RemoteDirectoryFindQuery, snapshot: SMBDirectorySnapshot, count: Int64, folders: Int64) throws {
        guard count >= 0, folders >= 0, count <= snapshot.count,
              folders <= count, folders <= snapshot.folders else {
            throw RemoteDirectoryFindFailure.invalidInput
        }
        self.query = query; self.snapshot = snapshot; self.count = count; self.folders = folders
    }

    public var description: String { "<SMB directory Find result>" }
    public var debugDescription: String { description }
}
#endif
