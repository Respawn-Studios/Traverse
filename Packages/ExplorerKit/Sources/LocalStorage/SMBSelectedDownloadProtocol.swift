import Foundation

/// Typed current catalog observation; construction is not remote read authority.
@_spi(Qualification) public struct SMBDownloadSelection: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumBytes: UInt64 = 1 << 30
    public let request: UUID, connection: UUID
    public let snapshot: SMBDirectorySnapshot
    public let observation: SMBDirectoryObservation
    public var logicalBytes: UInt64 { observation.logicalBytes }
    public var description: String { "<SMB download selection>" }
    public var debugDescription: String { description }
    public var proposedLocalName: String? {
        let value = observation.name.displayName
        let spelling = value.utf16.reduce(into: Data()) { bytes, unit in bytes.append(UInt8(unit & 255)); bytes.append(UInt8(unit >> 8)) }
        guard value.utf8.count <= 255, !value.contains(":"), spelling == observation.name.wireUTF16 else { return nil }
        return value
    }
    public init(connection: UUID, snapshot: SMBDirectorySnapshot, observation: SMBDirectoryObservation, request: UUID = UUID()) throws {
        guard connection.uuidString != "00000000-0000-0000-0000-000000000000",
              request.uuidString != "00000000-0000-0000-0000-000000000000",
              snapshot.readID.uuidString != "00000000-0000-0000-0000-000000000000",
              snapshot.state == .complete, snapshot.revision > 0, snapshot.revision <= UInt64(Int64.max),
              snapshot.count > 0, observation.id > 0, observation.attributes & 0x450 == 0,
              observation.logicalBytes <= Self.maximumBytes, observation.modifiedFileTime <= UInt64(Int64.max) else {
            throw SMBDirectoryFailure.invalidInput
        }
        self.connection = connection; self.request = request; self.snapshot = snapshot; self.observation = observation
    }
    func command(ordinal: UInt64, number: UInt64, retainingEditSource: Bool = false) -> String {
        let verb = retainingEditSource ? "PREPARE_EDIT_OPEN" : "PREPARE_DOWNLOAD"
        let identity = retainingEditSource ? " \(observation.objectID ?? 0) \(observation.parentID ?? 0)" : ""
        return "\(verb) \(request.uuidString) \(ordinal) \(number) \(snapshot.readID.uuidString) \(snapshot.revision) \(observation.id)\(identity)\n"
    }
}

/// Queried through the same handle that supplied the body. A later Edit must
/// revalidate every field before mutation; this record grants no write itself.
struct SMBRemoteFileSnapshot: Sendable, Equatable, Codable {
    let size: UInt64, allocated: UInt64, created: UInt64, modified: UInt64, changed: UInt64
    let attributes: UInt32, links: UInt32, index: UInt64, volumeCreated: UInt64, volumeSerial: UInt32
    var editEligible: Bool {
        size <= 1 << 20 && links == 1 && attributes & 0x451 == 0
            && index != 0 && index != .max && volumeSerial != 0
    }
}

/// Remote consistency and CLOSE outcome only; local seal/publication are separate.
@_spi(Qualification) public struct SMBDownloadReceipt: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let selection: SMBDownloadSelection
    public let receivedBytes: UInt64
    let sourceSnapshot: SMBRemoteFileSnapshot?
    let editSourceRetained: Bool
    public var description: String { "<SMB received source receipt>" }
    public var debugDescription: String { description }
    init(selection: SMBDownloadSelection, receivedBytes: UInt64, sourceSnapshot: SMBRemoteFileSnapshot? = nil,
         editSourceRetained: Bool = false) {
        self.selection = selection; self.receivedBytes = receivedBytes; self.sourceSnapshot = sourceSnapshot
        self.editSourceRetained = editSourceRetained
    }
}

enum SMBDownloadEvent: Sendable {
    case prepared(SMBDownloadSelection)
    case bytes(UUID, UInt64, Data)
    case complete(SMBDownloadReceipt)
    case sourceFull(UUID)
    case sourceUnavailable(UUID)
    case released(UUID)
}

/// One exact transfer. The outer browser owns mode/session/global sequencing;
/// this module owns prepare/begin/chunk/ACK/close ordering and selection equality.
struct SMBDownloadConversation: Sendable {
    static let binaryHeaderBytes = 97
    static let maximumFrameBytes = 32768 + binaryHeaderBytes
    enum Phase: Sendable, Equatable { case preparing, prepared, receiving, awaitingAppend, releasing, complete, failed }
    let selection: SMBDownloadSelection
    let ordinal: UInt64
    let retainingEditSource: Bool
    private(set) var phase: Phase = .preparing
    private var offset: UInt64 = 0, sequence: UInt64 = 0
    private var pending: (sequence: UInt64, end: UInt64)?

    init(selection: SMBDownloadSelection, ordinal: UInt64, retainingEditSource: Bool = false) throws {
        guard ordinal > 0 else { throw SMBDirectoryFailure.invalidInput }
        self.selection = selection; self.ordinal = ordinal; self.retainingEditSource = retainingEditSource
    }

    mutating func begin() throws -> String {
        guard phase == .prepared else { throw SMBDirectoryFailure.busy }
        guard ordinal > 0 else { throw SMBDirectoryFailure.invalidInput }
        phase = .receiving; return "BEGIN_DOWNLOAD \(selection.request.uuidString) \(ordinal)\n"
    }
    mutating func release() throws -> String {
        guard phase == .prepared else { throw SMBDirectoryFailure.busy }
        phase = .releasing; return "RELEASE_DOWNLOAD \(selection.request.uuidString) \(ordinal)\n"
    }
    /// Called only after the retained spool really appended the returned bytes.
    mutating func appended(request: UUID, endOffset: UInt64) throws -> String {
        guard phase == .awaitingAppend, request == selection.request, let pending,
              endOffset == pending.end, pending.sequence == sequence, sequence < UInt64.max else {
            throw SMBDirectoryFailure.invalidInput
        }
        self.pending = nil; offset = endOffset; sequence += 1; phase = .receiving
        return "ACK_DOWNLOAD \(request.uuidString) \(ordinal) \(pending.sequence) \(offset)\n"
    }
    mutating func text(_ fields: [String]) throws -> SMBDownloadEvent {
        do { return try consumeText(fields) }
        catch { phase = .failed; pending = nil; throw error }
    }
    private mutating func consumeText(_ fields: [String]) throws -> SMBDownloadEvent {
        guard fields.count >= 3, fields[1] == selection.request.uuidString,
              try number(fields[2], UInt64.self) == ordinal, ordinal > 0 else { throw SMBDirectoryFailure.invalidOutput }
        switch fields[0] {
        case "downloadSourceFull":
            guard retainingEditSource, phase == .preparing, fields.count == 3 else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .sourceFull(selection.request)
        case "downloadSourceUnavailable":
            guard retainingEditSource, phase == .preparing, fields.count == 3 else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .sourceUnavailable(selection.request)
        case "downloadPrepared":
            guard phase == .preparing, fields.count == 7,
                  try number(fields[3], UInt32.self) == selection.observation.attributes,
                  try number(fields[4], UInt64.self) == selection.logicalBytes,
                  try number(fields[5], UInt64.self) == selection.observation.modifiedFileTime,
                  try remoteName(fields[6]).wireUTF16 == selection.observation.name.wireUTF16 else {
                throw SMBDirectoryFailure.invalidOutput
            }
            phase = .prepared; return .prepared(selection)
        case "downloadComplete":
            guard (fields.count == 4 || fields.count == 14), phase == .receiving, pending == nil,
                  offset == selection.logicalBytes, try number(fields[3], UInt64.self) == offset else {
                throw SMBDirectoryFailure.invalidOutput
            }
            let source: SMBRemoteFileSnapshot?
            if fields.count == 14 {
                source = try SMBRemoteFileSnapshot(size: number(fields[4], UInt64.self),
                    allocated: number(fields[5], UInt64.self), created: number(fields[6], UInt64.self),
                    modified: number(fields[7], UInt64.self), changed: number(fields[8], UInt64.self),
                    attributes: number(fields[9], UInt32.self), links: number(fields[10], UInt32.self),
                    index: number(fields[11], UInt64.self), volumeCreated: number(fields[12], UInt64.self),
                    volumeSerial: number(fields[13], UInt32.self))
                guard source?.size == offset, source?.modified == selection.observation.modifiedFileTime,
                      source?.attributes == selection.observation.attributes else { throw SMBDirectoryFailure.invalidOutput }
            } else { source = nil }
            phase = .complete; return .complete(.init(selection: selection, receivedBytes: offset,
                                                     sourceSnapshot: source, editSourceRetained: retainingEditSource))
        case "downloadReleased":
            guard fields.count == 3, phase == .releasing, offset == 0 else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .released(selection.request)
        default: throw SMBDirectoryFailure.invalidOutput
        }
    }
    /// Exact binary envelope: tag/magic, session, global sequence, request UUID,
    /// chunk sequence, offset, length, data. It never passes a text formatter.
    mutating func binary(_ payload: Data, session: UUID, globalSequence: UInt64, magic: String = "MEXSMBD1") throws -> SMBDownloadEvent {
        do { return try consumeBinary(payload, session: session, globalSequence: globalSequence, magic: magic) }
        catch { phase = .failed; pending = nil; throw error }
    }
    private mutating func consumeBinary(_ payload: Data, session: UUID, globalSequence: UInt64, magic: String) throws -> SMBDownloadEvent {
        let bytes = [UInt8](payload)
        guard phase == .receiving, pending == nil, bytes.count >= Self.binaryHeaderBytes,
              bytes.count <= Self.maximumFrameBytes, Array(bytes[0..<9]) == Array(("\0" + magic).utf8),
              Array(bytes[9..<45]) == Array(session.uuidString.utf8),
              integer(bytes, 45, 8) == globalSequence,
              Data(bytes[53..<69]) == withUnsafeBytes(of: selection.request.uuid, { Data($0) }),
              integer(bytes, 69, 8) == ordinal, ordinal > 0,
              integer(bytes, 77, 8) == sequence, integer(bytes, 85, 8) == offset else {
            throw SMBDirectoryFailure.invalidOutput
        }
        let count = integer(bytes, 93, 4)
        guard count > 0, count <= 32768, UInt64(bytes.count) == UInt64(Self.binaryHeaderBytes) + count,
              offset <= selection.logicalBytes, count <= selection.logicalBytes - offset else {
            throw SMBDirectoryFailure.invalidOutput
        }
        pending = (sequence, offset + count); phase = .awaitingAppend
        return .bytes(selection.request, offset, Data(bytes[Self.binaryHeaderBytes...]))
    }
    private func integer(_ bytes: [UInt8], _ at: Int, _ count: Int) -> UInt64 {
        bytes[at..<at+count].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    private func number<T: FixedWidthInteger>(_ text: String, _ type: T.Type) throws -> T {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = T(text), String(value) == text else {
            throw SMBDirectoryFailure.invalidOutput
        }
        return value
    }
    private func remoteName(_ text: String) throws -> SMBRemoteName {
        let raw = Array(text.utf8)
        guard !raw.isEmpty, raw.count <= 8192, raw.count % 4 == 0,
              raw.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SMBDirectoryFailure.invalidOutput }
        var wire = Data()
        for at in stride(from: 0, to: raw.count, by: 4) {
            guard let unit = UInt16(String(decoding: raw[at..<at+4], as: UTF8.self), radix: 16) else { throw SMBDirectoryFailure.invalidOutput }
            wire.append(UInt8(unit & 255)); wire.append(UInt8(unit >> 8))
        }
        do { return try SMBRemoteName(wireUTF16: wire) } catch { throw SMBDirectoryFailure.invalidOutput }
    }
}
