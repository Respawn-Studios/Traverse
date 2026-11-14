import Foundation

enum SMBFolderUploadEvent: Sendable {
    case manifestNeed(Int, Int), ready, rootCreated
    case need(Int, UInt64, UInt64, Int), sourceDigest(Int)
    case fileVerified(Int, Int, UInt64), stageVerified(Data), complete(Data)
    case stageCollision, finalCollision, failure(SMBFolderUploadDiagnostic)
}

/// Fixed worker failure coordinates. No remote name, source path, body or
/// server-provided message crosses into the app's diagnostic surface.
@_spi(Qualification) public struct SMBFolderUploadDiagnostic: Sendable, Equatable {
    public let boundary: UInt8
    public let cause: UInt8
    public let command: UInt8?
    public let status: UInt32?
    static func parse(_ parts: [String]) -> Self? {
        guard parts.count == 4, let boundary = UInt8(parts[0]), (1...10).contains(boundary),
              let causeIndex = ["invalid", "ipc", "stopped", "deadline", "remote", "authentication",
                                "denied", "security", "storage", "quota", "close"].firstIndex(of: parts[1]),
              let command = UInt8(parts[2]), command == 255 || command <= 18,
              let status = UInt32(parts[3]), (command == 255) == (status == 0),
              parts[0] == String(boundary), parts[2] == String(command), parts[3] == String(status) else { return nil }
        return Self(boundary: boundary, cause: UInt8(causeIndex + 1),
                    command: command == 255 ? nil : command, status: status == 0 ? nil : status)
    }
}

/// F2's sequence checker for exact manifest, source, and ledger exchanges.
struct SMBFolderUploadConversation: Sendable {
    enum Phase: Sendable { case preparing, manifestRequested, ready, creating, awaitingData, writing,
        awaitingFileVerified, awaitingFileAck, staged, publishing, complete, failed }
    let request: SMBRequestedFolderUpload, ordinal: UInt64
    private(set) var phase: Phase = .preparing
    private var manifestOffset = 0, fileIndex: Int
    private var fileOffset: UInt64 = 0, sequence: UInt64 = 0
    private var pendingCount = 0, verifiedFiles = 0
    private var verifiedBytes: UInt64 = 0
    private var rootAnnounced = false, rootAcknowledged = false
    private var treeDigest: Data?
    init(request: SMBRequestedFolderUpload, ordinal: UInt64) throws {
        guard ordinal > 0 else { throw SMBUploadFailure.invalidInput }
        self.request = request; self.ordinal = ordinal
        fileIndex = request.manifest.nodes.firstIndex(where: { !$0.directory }) ?? request.manifest.nodes.count
    }
    private var nodes: [SFTPFolderUploadManifest.Node] { request.manifest.nodes }
    private static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    private static func bytes(_ value: String) -> Data? {
        guard value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        var result = Data()
        for index in stride(from: 0, to: 64, by: 2) {
            let first = value.index(value.startIndex, offsetBy: index)
            guard let byte = UInt8(value[first..<value.index(first, offsetBy: 2)], radix: 16) else { return nil }
            result.append(byte)
        }
        return result
    }
    private func number<T: FixedWidthInteger>(_ value: String, as: T.Type = T.self) throws -> T {
        guard let parsed = T(value), String(parsed) == value else { throw SMBDirectoryFailure.invalidOutput }
        return parsed
    }
    private func frame(kind: UInt8, node: UInt32, sequence: UInt64, offset: UInt64, bytes: Data) throws -> Data {
        guard (1...32768).contains(bytes.count) else { throw SMBUploadFailure.invalidInput }
        var body = Data([kind]); body.append(contentsOf: "MEXSMBU1".utf8)
        body.append(contentsOf: request.request.uuidString.utf8)
        for shift in stride(from: 56, through: 0, by: -8) { body.append(UInt8(truncatingIfNeeded: ordinal >> shift)) }
        for shift in stride(from: 24, through: 0, by: -8) { body.append(UInt8(truncatingIfNeeded: node >> shift)) }
        for value in [sequence, offset] {
            for shift in stride(from: 56, through: 0, by: -8) { body.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        let count = UInt32(bytes.count)
        for shift in stride(from: 24, through: 0, by: -8) { body.append(UInt8(truncatingIfNeeded: count >> shift)) }
        body.append(bytes)
        var frame = Data(), length = UInt32(body.count)
        for shift in stride(from: 24, through: 0, by: -8) { frame.append(UInt8(truncatingIfNeeded: length >> shift)) }
        frame.append(body); return frame
    }
    mutating func manifest(offset: Int, bytes: Data) throws -> Data {
        let encoded = request.manifest.encoded
        guard phase == .manifestRequested, offset == manifestOffset, bytes.count == pendingCount,
              encoded.subdata(in: offset..<(offset + bytes.count)) == bytes else { throw SMBUploadFailure.invalidInput }
        let result = try frame(kind: 3, node: 0, sequence: 0, offset: UInt64(offset), bytes: bytes)
        manifestOffset += bytes.count; pendingCount = 0; phase = .preparing; return result
    }
    mutating func begin() throws -> String {
        guard phase == .ready else { throw SMBUploadFailure.invalidInput }
        phase = .creating; return "BEGIN_FOLDER_UPLOAD \(request.request.uuidString) \(ordinal)\n"
    }
    mutating func acknowledgeRoot() throws -> String {
        guard phase == .creating, rootAnnounced, !rootAcknowledged else { throw SMBUploadFailure.invalidInput }
        rootAcknowledged = true; return "FOLDER_ROOT_ACK \(request.request.uuidString) \(ordinal)\n"
    }
    mutating func data(node: Int, sequence wanted: UInt64, offset: UInt64, bytes: Data) throws -> Data {
        guard phase == .awaitingData, node == fileIndex, wanted == sequence, offset == fileOffset,
              bytes.count == pendingCount else { throw SMBUploadFailure.invalidInput }
        let result = try frame(kind: 4, node: UInt32(node), sequence: sequence, offset: offset, bytes: bytes)
        fileOffset += UInt64(bytes.count); sequence += 1; pendingCount = 0; phase = .writing; return result
    }
    mutating func supplyDigest(node: Int, value: Data) throws -> String {
        guard phase == .writing || phase == .creating, node == fileIndex, node < nodes.count,
              fileOffset == nodes[node].size, value.count == 32 else { throw SMBUploadFailure.invalidInput }
        phase = .awaitingFileVerified
        return "FOLDER_FILE_DIGEST \(request.request.uuidString) \(ordinal) \(node) \(Self.hex(value))\n"
    }
    mutating func acknowledgeFile(node: Int, files: Int, bytes: UInt64) throws -> String {
        guard phase == .awaitingFileAck, node == fileIndex, node < nodes.count, files == verifiedFiles + 1,
              bytes == verifiedBytes + nodes[node].size else { throw SMBUploadFailure.invalidInput }
        verifiedFiles = files; verifiedBytes = bytes
        fileIndex = ((node + 1)..<nodes.count).first(where: { !nodes[$0].directory }) ?? nodes.count
        fileOffset = 0; sequence = 0; phase = .creating
        return "FOLDER_FILE_ACK \(request.request.uuidString) \(ordinal) \(node) \(files) \(bytes)\n"
    }
    mutating func commit(_ digest: Data) throws -> String {
        guard phase == .staged, treeDigest == digest, digest.count == 32 else { throw SMBUploadFailure.invalidInput }
        phase = .publishing
        return "COMMIT_FOLDER_UPLOAD \(request.request.uuidString) \(ordinal) \(Self.hex(digest))\n"
    }
    mutating func text(_ p: [String]) throws -> SMBFolderUploadEvent {
        do { return try consume(p) } catch { phase = .failed; throw error }
    }
    private mutating func consume(_ p: [String]) throws -> SMBFolderUploadEvent {
        guard p.count >= 3, p[1] == request.request.uuidString,
              try number(p[2], as: UInt64.self) == ordinal else { throw SMBDirectoryFailure.invalidOutput }
        switch p[0] {
        case "folderUploadManifestNeed":
            guard p.count == 5, phase == .preparing,
                  let offset = try? number(p[3], as: Int.self), offset == manifestOffset,
                  let count = try? number(p[4], as: Int.self),
                  count == min(32768, request.manifest.encoded.count - offset), count > 0 else { throw SMBDirectoryFailure.invalidOutput }
            pendingCount = count; phase = .manifestRequested; return .manifestNeed(offset, count)
        case "folderUploadReady":
            guard p.count == 3, phase == .preparing,
                  manifestOffset == request.manifest.encoded.count else { throw SMBDirectoryFailure.invalidOutput }
            phase = .ready; return .ready
        case "folderUploadRootCreated":
            guard p.count == 3, phase == .creating, !rootAnnounced else { throw SMBDirectoryFailure.invalidOutput }
            rootAnnounced = true; return .rootCreated
        case "folderUploadNeed":
            guard p.count == 7, phase == .creating || phase == .writing, rootAcknowledged,
                  let node = try? number(p[3], as: Int.self), node == fileIndex, node < nodes.count,
                  let seq = try? number(p[4], as: UInt64.self), seq == sequence,
                  let offset = try? number(p[5], as: UInt64.self), offset == fileOffset,
                  let count = try? number(p[6], as: Int.self), (1...32768).contains(count),
                  offset <= nodes[node].size, UInt64(count) <= nodes[node].size - offset else { throw SMBDirectoryFailure.invalidOutput }
            pendingCount = count; phase = .awaitingData; return .need(node, seq, offset, count)
        case "folderUploadSourceDigest":
            guard p.count == 4, phase == .creating || phase == .writing, rootAcknowledged,
                  let node = try? number(p[3], as: Int.self), node == fileIndex, node < nodes.count,
                  fileOffset == nodes[node].size else { throw SMBDirectoryFailure.invalidOutput }
            return .sourceDigest(node)
        case "folderUploadFileVerified":
            guard p.count == 6, phase == .awaitingFileVerified,
                  let node = try? number(p[3], as: Int.self), node == fileIndex, node < nodes.count,
                  let files = try? number(p[4], as: Int.self), files == verifiedFiles + 1,
                  let bytes = try? number(p[5], as: UInt64.self),
                  bytes == verifiedBytes + nodes[node].size else { throw SMBDirectoryFailure.invalidOutput }
            phase = .awaitingFileAck; return .fileVerified(node, files, bytes)
        case "folderUploadStageVerified":
            guard p.count == 4, phase == .creating, rootAcknowledged,
                  verifiedFiles == request.files, verifiedBytes == request.logicalBytes,
                  fileIndex == nodes.count, let digest = Self.bytes(p[3]) else { throw SMBDirectoryFailure.invalidOutput }
            treeDigest = digest; phase = .staged; return .stageVerified(digest)
        case "folderUploadComplete":
            guard p.count == 4, phase == .publishing,
                  let digest = Self.bytes(p[3]), digest == treeDigest else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .complete(digest)
        case "folderUploadStageCollision":
            guard p.count == 3, phase == .creating, !rootAnnounced else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .stageCollision
        case "folderUploadFinalCollision":
            guard p.count == 3, phase == .publishing else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .finalCollision
        case "folderUploadFailure":
            guard p.count == 7, phase != .complete, phase != .failed,
                  let diagnostic = SMBFolderUploadDiagnostic.parse(Array(p[3...6])) else { throw SMBDirectoryFailure.invalidOutput }
            phase = .failed; return .failure(diagnostic)
        default: throw SMBDirectoryFailure.invalidOutput
        }
    }
}
