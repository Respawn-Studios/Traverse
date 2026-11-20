import Foundation

enum SMBOriginalEditAttributeContract: String, Codable, Sendable {
    case exactV1, archiveWriteV2, archiveWriteCreationApproxV3

    var prepareVerb: String {
        switch self {
        case .exactV1: return "PREPARE_EDIT"
        case .archiveWriteV2: return "PREPARE_EDIT_V2"
        case .archiveWriteCreationApproxV3: return "PREPARE_EDIT_V3"
        }
    }
    var completionVerb: String {
        switch self {
        case .exactV1: return "editComplete"
        case .archiveWriteV2: return "editCompleteV2"
        case .archiveWriteCreationApproxV3: return "editCompleteV3"
        }
    }
    func permitsCreationWitnesses(before: SMBRemoteFileSnapshot, after: SMBRemoteFileSnapshot) -> Bool {
        self == .archiveWriteCreationApproxV3
            || (before.volumeCreated == after.volumeCreated && before.created == after.created)
    }

    func permitsFirstPostwrite(before: UInt32, after: UInt32) -> Bool {
        if before == after { return true }
        guard self != .exactV1 else { return false }
        let archive: UInt32 = 0x20, normal: UInt32 = 0x80
        return (before == normal && after == archive)
            || (before != 0 && (before & (archive | normal)) == 0 && after == (before | archive))
    }
}

/// Frozen one-Save input. The worker receives values, never a local path or a
/// serialized capability; its checked handle re-proves all baseline facts.
struct SMBOriginalEditRequest: Sendable {
    let id: UUID, selection: SMBDownloadSelection, before: SMBRemoteFileSnapshot
    let beforeDigest: Data, editedLength: UInt64, editedDigest: Data
    let attributeContract: SMBOriginalEditAttributeContract
    let sourceToken: UUID?
    init(id: UUID, selection: SMBDownloadSelection, before: SMBRemoteFileSnapshot,
         beforeDigest: Data, editedLength: UInt64, editedDigest: Data,
         attributeContract: SMBOriginalEditAttributeContract = .exactV1,
         sourceToken: UUID? = nil) throws {
        guard before.editEligible, before.size <= 1 << 20, beforeDigest.count == 32,
              editedLength <= 1 << 20, editedDigest.count == 32,
              sourceToken == nil || sourceToken == selection.request,
              id != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else {
            throw SMBTextFailure.unsupported
        }
        self.id = id; self.selection = selection; self.before = before
        self.beforeDigest = beforeDigest; self.editedLength = editedLength; self.editedDigest = editedDigest
        self.attributeContract = attributeContract; self.sourceToken = sourceToken
    }
    func command(ordinal: UInt64, number: UInt64) -> String {
        let s = before
        let verb = sourceToken == nil ? attributeContract.prepareVerb
            : attributeContract.prepareVerb.replacingOccurrences(of: "PREPARE_EDIT", with: "PREPARE_EDIT_SOURCE")
        var fields: [String] = [verb, id.uuidString, String(ordinal), String(number),
            selection.snapshot.readID.uuidString, String(selection.snapshot.revision), String(selection.observation.id)]
        fields.append(contentsOf: [
            String(s.size), String(s.allocated), String(s.created), String(s.modified), String(s.changed),
            String(s.attributes), String(s.links), String(s.index), String(s.volumeCreated), String(s.volumeSerial)])
        fields.append(beforeDigest.map { String(format: "%02x", $0) }.joined())
        fields.append(String(editedLength))
        fields.append(editedDigest.map { String(format: "%02x", $0) }.joined())
        if let sourceToken { fields.append(sourceToken.uuidString) }
        return fields.joined(separator: " ") + "\n"
    }
}
enum SMBOriginalEditEvent: Sendable {
    case need(UUID, UInt64, UInt64, Int)
    case ready(UUID)
    case changed(UUID)
    case complete(UUID, SMBRemoteFileSnapshot)
    case fault(UUID, UInt8)
}
enum SMBOriginalEditOutcome: Sendable {
    case changed
    case verified(SMBRemoteFileSnapshot)
    case verifiedRecoveryNeedsAttention
}
struct SMBOriginalEditConversation: Sendable {
    enum Phase: Sendable, Equatable { case receiving, ready, authorized, complete, failed }
    let request: SMBOriginalEditRequest, ordinal: UInt64
    private(set) var phase: Phase = .receiving
    private var offset: UInt64 = 0, sequence: UInt64 = 0
    private var pending: (sequence: UInt64, offset: UInt64, count: Int)?
    init(request: SMBOriginalEditRequest, ordinal: UInt64) throws {
        guard ordinal > 0 else { throw SMBDirectoryFailure.invalidInput }
        self.request = request; self.ordinal = ordinal
    }
    mutating func data(sequence: UInt64, offset: UInt64, bytes: Data) throws -> Data {
        guard phase == .receiving, let pending, pending.sequence == sequence,
              pending.offset == offset, pending.count == bytes.count, bytes.count > 0,
              bytes.count <= 32768 else { throw SMBDirectoryFailure.invalidInput }
        var payload = Data([5]); payload.append(Data("MEXSMBU1".utf8))
        payload.append(Data(request.id.uuidString.utf8))
        for value in [ordinal, sequence, offset] {
            var n = value.bigEndian; withUnsafeBytes(of: &n) { payload.append(contentsOf: $0) }
        }
        var count = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        payload.append(bytes)
        var framed = Data(); var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        self.pending = nil; self.offset += UInt64(bytes.count); self.sequence += 1
        return framed
    }
    mutating func authorize() throws -> String {
        guard phase == .ready else { throw SMBDirectoryFailure.invalidInput }
        phase = .authorized
        return "AUTHORIZE_EDIT \(request.id.uuidString) \(ordinal)\n"
    }
    mutating func text(_ fields: [String]) throws -> SMBOriginalEditEvent {
        do { return try consume(fields) }
        catch { phase = .failed; throw error }
    }
    private mutating func consume(_ fields: [String]) throws -> SMBOriginalEditEvent {
        guard fields.count >= 3, fields[1] == request.id.uuidString,
              try Self.number(fields[2], UInt64.self) == ordinal else { throw SMBDirectoryFailure.invalidOutput }
        switch fields[0] {
        case "editNeed":
            guard fields.count == 6, phase == .receiving, pending == nil else { throw SMBDirectoryFailure.invalidOutput }
            let sequence = try Self.number(fields[3], UInt64.self)
            let offset = try Self.number(fields[4], UInt64.self)
            let count = try Self.number(fields[5], Int.self)
            guard sequence == self.sequence, offset == self.offset, count > 0, count <= 32768,
                  offset <= request.editedLength, UInt64(count) <= request.editedLength - offset else {
                throw SMBDirectoryFailure.invalidOutput
            }
            pending = (sequence, offset, count); return .need(request.id, sequence, offset, count)
        case "editReady":
            guard fields.count == 3, phase == .receiving, pending == nil,
                  offset == request.editedLength else { throw SMBDirectoryFailure.invalidOutput }
            phase = .ready; return .ready(request.id)
        case "editRefusedChanged":
            guard fields.count == 3, phase == .receiving, pending == nil,
                  offset == request.editedLength else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .changed(request.id)
        case "editComplete", "editCompleteV2", "editCompleteV3":
            guard fields.count == 13, phase == .authorized else { throw SMBDirectoryFailure.invalidOutput }
            guard fields[0] == request.attributeContract.completionVerb else {
                throw SMBDirectoryFailure.invalidOutput
            }
            let s = try SMBRemoteFileSnapshot(size: Self.number(fields[3], UInt64.self),
                allocated: Self.number(fields[4], UInt64.self), created: Self.number(fields[5], UInt64.self),
                modified: Self.number(fields[6], UInt64.self), changed: Self.number(fields[7], UInt64.self),
                attributes: Self.number(fields[8], UInt32.self), links: Self.number(fields[9], UInt32.self),
                index: Self.number(fields[10], UInt64.self), volumeCreated: Self.number(fields[11], UInt64.self),
                volumeSerial: Self.number(fields[12], UInt32.self))
            guard s.editEligible, s.size == request.editedLength,
                  s.index == request.before.index, s.volumeSerial == request.before.volumeSerial,
                  request.attributeContract.permitsCreationWitnesses(before: request.before, after: s),
                  request.attributeContract.permitsFirstPostwrite(before: request.before.attributes,
                                                                  after: s.attributes) else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .complete(request.id, s)
        case "editFault":
            guard fields.count == 4, phase == .authorized else { throw SMBDirectoryFailure.invalidOutput }
            let checkpoint = try Self.number(fields[3], UInt8.self)
            guard (3...12).contains(checkpoint) || (15...29).contains(checkpoint) else {
                throw SMBDirectoryFailure.invalidOutput
            }
            phase = .failed; return .fault(request.id, checkpoint)
        default: throw SMBDirectoryFailure.invalidOutput
        }
    }
    private static func number<T: FixedWidthInteger>(_ text: String, _ type: T.Type) throws -> T {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = T(text), String(value) == text else { throw SMBDirectoryFailure.invalidOutput }
        return value
    }
}
