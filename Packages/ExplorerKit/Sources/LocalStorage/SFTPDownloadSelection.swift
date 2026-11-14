import Foundation

/// Explicit selected observation, never an arbitrary server path or local URL.
/// Construction grants neither content access nor destination write authority.
@_spi(Qualification) public struct SFTPDownloadSelection: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumBytes: UInt64 = 1 << 30
    public let request: UUID, generation: UUID
    public let row: SFTPStoredRow
    public let logicalBytes: UInt64
    public var description: String { "<SFTP download selection>" }
    public var debugDescription: String { description }
    /// A local default only when no presentation escaping or filesystem-name
    /// translation is needed. Otherwise Download must ask for a local name.
    public var proposedLocalName: String? {
        let value = String(decoding: row.entry.name.wireUTF8, as: UTF8.self)
        guard value.utf8.count <= 255, !value.contains(":"),
              row.entry.name.isSafeForSingleLineEntry else { return nil }
        return value
    }
    public init(generation: UUID, row: SFTPStoredRow, request: UUID = UUID()) throws {
        guard SFTPWire.validToken(request), SFTPWire.validToken(generation), row.observation > 0,
              row.observation <= UInt64(Int64.max), let size = row.entry.logicalBytes, size <= Self.maximumBytes,
              row.entry.modifiedSeconds != nil, let mode = row.entry.permissions, mode & 0o170000 == 0o100000 else {
            throw SFTPProtocolFailure.invalidInput
        }
        self.request = request; self.generation = generation; self.row = row; logicalBytes = size
    }
    func command() -> Data {
        var data = SFTPWire.token(request); data.append(SFTPWire.token(generation))
        SFTPWire.number(row.observation, bytes: 8, into: &data); return data
    }
}

/// The remote channel's consistency/close check only. Local write verification,
/// synchronization, quarantine, recoverable publication and Undo are separate.
@_spi(Qualification) public struct SFTPDownloadReceipt: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let selection: SFTPDownloadSelection
    public let receivedBytes: UInt64
    public var description: String { "<SFTP downloaded source receipt>" }
    public var debugDescription: String { description }
}
