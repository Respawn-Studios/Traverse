import Foundation

enum SMBUploadEvent: Sendable {
    case ready, need(sequence: UInt64, offset: UInt64, count: Int), written(UInt64)
    case sourceDigest, stageVerified(Data), complete(Data), stageCollision, finalCollision
}

/// The parent advances one U1 request only after each durable local barrier.
/// Body data is sent through one bounded binary frame and never logged.
struct SMBUploadConversation: Sendable {
    enum Phase: Sendable { case preparing, ready, creating, awaitingWrite, writing, awaitingDigest, verifyingStage, staged, publishing, complete, failed }
    let request: SMBRequestedUpload, ordinal: UInt64
    private(set) var phase: Phase = .preparing
    private var offset: UInt64 = 0, sequence: UInt64 = 0
    private var pending: UInt64?
    private var digest: Data?
    init(request: SMBRequestedUpload, ordinal: UInt64) throws {
        guard ordinal > 0 else { throw SMBUploadFailure.invalidInput }
        self.request = request; self.ordinal = ordinal
    }
    mutating func begin() throws -> String {
        guard phase == .ready else { throw SMBUploadFailure.invalidInput }
        phase = .creating; return "BEGIN_UPLOAD \(request.request.uuidString) \(ordinal)\n"
    }
    mutating func data(sequence wanted: UInt64, offset wantedOffset: UInt64, bytes: Data) throws -> Data {
        guard phase == .awaitingWrite, wanted == sequence, wantedOffset == offset, let end = pending,
              end == offset + UInt64(bytes.count), !bytes.isEmpty, bytes.count <= 32768 else { throw SMBUploadFailure.invalidInput }
        var body = Data([2]); body.append(contentsOf: "MEXSMBU1".utf8); body.append(contentsOf: request.request.uuidString.utf8)
        for value in [ordinal, sequence, offset] { for shift in stride(from: 56, through: 0, by: -8) { body.append(UInt8(truncatingIfNeeded: value >> shift)) } }
        let count = UInt32(bytes.count)
        for shift in stride(from: 24, through: 0, by: -8) { body.append(UInt8(truncatingIfNeeded: count >> shift)) }
        body.append(bytes)
        guard body.count <= 32768 + 73 else { throw SMBUploadFailure.invalidInput }
        var frame = Data()
        let length = UInt32(body.count)
        for shift in stride(from: 24, through: 0, by: -8) { frame.append(UInt8(truncatingIfNeeded: length >> shift)) }
        frame.append(body); phase = .writing; return frame
    }
    mutating func supplyDigest(_ value: Data) throws -> String {
        guard phase == .awaitingDigest, value.count == 32 else { throw SMBUploadFailure.invalidInput }
        digest = value; phase = .verifyingStage
        return "UPLOAD_DIGEST \(request.request.uuidString) \(ordinal) \(value.map { String(format: "%02x", $0) }.joined())\n"
    }
    mutating func commit() throws -> String {
        guard phase == .staged else { throw SMBUploadFailure.invalidInput }
        phase = .publishing; return "COMMIT_UPLOAD \(request.request.uuidString) \(ordinal)\n"
    }
    mutating func text(_ p: [String]) throws -> SMBUploadEvent {
        do { return try consume(p) } catch { phase = .failed; throw error }
    }
    private mutating func consume(_ p: [String]) throws -> SMBUploadEvent {
        guard p.count >= 3, p[1] == request.request.uuidString, try number(p[2]) == ordinal else { throw SMBDirectoryFailure.invalidOutput }
        switch p[0] {
        case "uploadReady":
            guard p.count == 3, phase == .preparing else { throw SMBDirectoryFailure.invalidOutput }
            phase = .ready; return .ready
        case "uploadNeed":
            guard p.count == 6, phase == .creating, let n: UInt64 = try? number(p[3]), n == sequence,
                  let at: UInt64 = try? number(p[4]), at == offset,
                  let count: UInt64 = try? number(p[5]), count > 0, count <= 32768,
                  at + count <= request.logicalBytes else { throw SMBDirectoryFailure.invalidOutput }
            pending = at + count; phase = .awaitingWrite; return .need(sequence: n, offset: at, count: Int(count))
        case "uploadWritten":
            guard p.count == 4, phase == .writing, let end = pending,
                  let reported: UInt64 = try? number(p[3]), reported == end, sequence < UInt64.max else { throw SMBDirectoryFailure.invalidOutput }
            pending = nil; offset = end; sequence += 1; phase = .creating; return .written(end)
        case "uploadSourceDigest":
            guard p.count == 3, phase == .creating, offset == request.logicalBytes else { throw SMBDirectoryFailure.invalidOutput }
            phase = .awaitingDigest; return .sourceDigest
        case "uploadStageVerified":
            guard p.count == 4, phase == .verifyingStage, let expected = digest,
                  let reported = Self.hex(p[3]), reported == expected else { throw SMBDirectoryFailure.invalidOutput }
            phase = .staged; return .stageVerified(reported)
        case "uploadComplete":
            guard p.count == 4, phase == .publishing, let expected = digest,
                  let reported = Self.hex(p[3]), reported == expected else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .complete(reported)
        case "uploadStageCollision":
            guard p.count == 3, phase == .creating, offset == 0 else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .stageCollision
        case "uploadFinalCollision":
            guard p.count == 3, phase == .publishing else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .finalCollision
        default: throw SMBDirectoryFailure.invalidOutput
        }
    }
    private func number(_ text: String) throws -> UInt64 {
        guard let value = UInt64(text), String(value) == text else { throw SMBDirectoryFailure.invalidOutput }
        return value
    }
    private static func hex(_ value: String) -> Data? {
        guard value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        var bytes = Data()
        for i in stride(from: 0, to: 64, by: 2) {
            let start = value.index(value.startIndex, offsetBy: i)
            guard let byte = UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}
