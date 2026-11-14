import Foundation

/// A metadata observation, not allocated storage, a transfer manifest or an
/// atomic server snapshot. Every regular-file directory entry contributes its
/// logical size; links are counted separately and never followed.
@_spi(Qualification) public struct RemoteFolderSizeSummary: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let logicalBytes: UInt64
    public let files: UInt32
    /// Descendant folders; the selected root is not included.
    public let folders: UInt32
    public let excludedLinks: UInt32
    public let observedAt: Date

    public init(logicalBytes: UInt64, files: UInt32, folders: UInt32,
                excludedLinks: UInt32, observedAt: Date = Date()) throws {
        let descendants = UInt64(files) + UInt64(folders) + UInt64(excludedLinks)
        guard descendants < 32_768, files != 0 || logicalBytes == 0,
              observedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RemoteFolderSizeFailure.invalidInput
        }
        self.logicalBytes = logicalBytes; self.files = files; self.folders = folders
        self.excludedLinks = excludedLinks; self.observedAt = observedAt
    }

    public var description: String { "<remote folder size summary>" }
    public var debugDescription: String { description }
}

/// An unavailable total must never be presented as an exact zero-byte folder.
@_spi(Qualification) public enum RemoteFolderSizeFailure: Error, Sendable, Equatable {
    case stale, denied, changed, unsupported, limit, deadline, connectionLost, unavailable, invalidInput

    init?(wireReason: UInt8) {
        switch wireReason {
        case 1: self = .stale
        case 2: self = .denied
        case 3: self = .changed
        case 4: self = .unsupported
        case 5: self = .limit
        case 6: self = .deadline
        case 7: self = .unavailable
        default: return nil
        }
    }
}

/// An exact selected observation in a complete listing, never a caller path.
@_spi(Qualification) public struct SFTPFolderSizeSelection: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let request: UUID
    public let generation: UUID
    public let snapshot: SFTPStoredSnapshot
    public let row: SFTPStoredRow

    public init(request: UUID = UUID(), generation: UUID, snapshot: SFTPStoredSnapshot, row: SFTPStoredRow) throws {
        guard SFTPWire.validToken(request), SFTPWire.validToken(generation), snapshot.state == .complete,
              snapshot.read > 0, snapshot.revision > 0, snapshot.read <= UInt64(Int64.max),
              snapshot.revision <= UInt64(Int64.max), snapshot.count > 0, snapshot.count <= UInt64(Int64.max),
              snapshot.folders > 0, snapshot.folders <= snapshot.count,
              row.observation > 0, row.observation <= UInt64(Int64.max),
              row.entry.isDirectory == true else { throw RemoteFolderSizeFailure.invalidInput }
        self.request = request; self.generation = generation; self.snapshot = snapshot; self.row = row
    }

    public var description: String { "<SFTP folder size selection>" }
    public var debugDescription: String { description }
}

#if !SFTP_PARENT_STANDALONE
@_spi(Qualification) public struct SMBFolderSizeSelection: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let request: UUID
    public let connection: UUID
    public let snapshot: SMBDirectorySnapshot
    public let observation: SMBDirectoryObservation

    public init(request: UUID = UUID(), connection: UUID, snapshot: SMBDirectorySnapshot,
                observation: SMBDirectoryObservation) throws {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard request != zero, connection != zero, snapshot.readID != zero, snapshot.state == .complete,
              snapshot.revision > 0, snapshot.revision <= UInt64(Int64.max),
              snapshot.count > 0, snapshot.folders > 0, snapshot.folders <= snapshot.count, observation.id > 0,
              observation.attributes & 0x450 == 0x10 else { throw RemoteFolderSizeFailure.invalidInput }
        self.request = request; self.connection = connection; self.snapshot = snapshot; self.observation = observation
    }

    public var description: String { "<SMB folder size selection>" }
    public var debugDescription: String { description }
}
#endif
