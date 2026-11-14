import CryptoKit
import Foundation

struct SFTPFolderUploadSelection: Sendable, Equatable, CustomDebugStringConvertible {
    let request: UUID, generation: UUID, revision: UInt64, directory: String, name: SFTPRemoteName
    let manifest: SFTPFolderUploadManifest
    var debugDescription: String { "<SFTP fresh-folder selection>" }
    var rootPath: Data { Data((directory == "/" ? "" : directory).utf8) + Data([47]) + name.wireUTF8 }
    init(request: UUID, generation: UUID, revision: UInt64, directory: String, name: SFTPRemoteName, manifest: SFTPFolderUploadManifest) throws {
        guard revision > 0 else { throw SFTPProtocolFailure.invalidInput }
        _ = try SFTPUploadSelection(request: request, generation: generation, revision: revision, directory: directory, name: name, logicalBytes: manifest.logicalBytes)
        self.request = request; self.generation = generation; self.revision = revision; self.directory = directory; self.name = name; self.manifest = manifest
        for node in manifest.nodes {
            let path = rootPath + node.components.reduce(into: Data()) { $0.append(47); $0.append($1) }
            guard path.count <= 8192, path.split(separator: 47).count <= 127 else { throw SFTPProtocolFailure.invalidInput }
            if !node.directory {
                let components = path.split(separator: 47, omittingEmptySubsequences: false), parent = components.dropLast().map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
                _ = try SFTPUploadSelection(request: request, generation: generation, revision: revision, directory: parent,
                    name: SFTPRemoteName(Data(components.last!)), logicalBytes: node.size)
            }
        }
    }
    func command() throws -> Data {
        var value = SFTPWire.token(request); value.append(SFTPWire.token(generation)); SFTPWire.number(revision, bytes: 8, into: &value)
        try SFTPWire.field(name.wireUTF8, into: &value); SFTPWire.number(UInt64(manifest.encoded.count), bytes: 4, into: &value)
        value.append(manifest.digest); SFTPWire.number(UInt64(manifest.files), bytes: 4, into: &value); SFTPWire.number(UInt64(manifest.folders), bytes: 4, into: &value)
        SFTPWire.number(manifest.logicalBytes, bytes: 8, into: &value); return value
    }
}

enum SFTPFolderUploadReply: Sendable {
    case manifest(offset: Int, bytes: Data), source(node: Int, offset: UInt64, bytes: Data)
    case filePermit(node: Int, digest: Data), rootAcknowledged, progress(node: Int, files: Int, bytes: UInt64), finalPermit(Data)
}
struct SFTPFolderUploadReceipt: Sendable, Equatable { let selection: SFTPFolderUploadSelection, digest: Data }
@_spi(Qualification) public struct SFTPFolderUploadInterruption: Error, Sendable, CustomDebugStringConvertible {
    public let cause: SFTPUploadInterruption.Cause, phase: UInt8, node: Int
    public let rootMayExist: Bool, rootAcknowledged: Bool, verifiedFiles: Int, verifiedBytes: UInt64, status: UInt32
    public var debugDescription: String { "<SFTP interrupted folder upload>" }
}

/// Strict finite exchange: an H peer can request only the admitted manifest's
/// next chunk/member/offset. No peer-supplied path selects a local read source.
struct SFTPFolderUploadProtocolState {
    let selection: SFTPFolderUploadSelection
    private var started = false, rootAnnounced = false, rootAcknowledged = false, filePermitted = false, closed = false
    private var manifestSent = 0, nextFile: Int, offset: UInt64 = 0, files = 0, bytes: UInt64 = 0
    private var hashes: [Data?], authorizedDigest: Data?
    private enum Pending {
        case manifest(Int, Int), source(Int, UInt64, Int), file(Int, Data), root, progress(Int, Int, UInt64), final(Data)
    }
    private var pending: Pending?
    init(_ selection: SFTPFolderUploadSelection) {
        self.selection = selection; nextFile = selection.manifest.nodes.firstIndex(where: { !$0.directory }) ?? selection.manifest.nodes.count
        hashes = Array(repeating: nil, count: selection.manifest.nodes.count)
    }
    mutating func consume(_ kind: UInt64, cursor: inout SFTPCursor) throws -> SFTPWorkerEvent {
        guard !closed, try cursor.token() == selection.request else { throw SFTPProtocolFailure.invalidOutput }
        let m = selection.manifest
        switch kind {
        case 160:
            guard !started, pending == nil, try cursor.token() == selection.generation,
                  try cursor.number(4) == UInt64(m.encoded.count), try cursor.take(32) == m.digest,
                  try cursor.number(4) == UInt64(m.files), try cursor.number(4) == UInt64(m.folders),
                  try cursor.number(8) == m.logicalBytes, try cursor.field(cap: 8192) == selection.rootPath else { throw SFTPProtocolFailure.invalidOutput }
            started = true; return .folderUploadStarted(selection)
        case 161:
            let start = Int(try cursor.number(4)), count = Int(try cursor.number(4))
            guard started, pending == nil, !rootAnnounced, start == manifestSent, manifestSent < m.encoded.count,
                  count == min(32768, m.encoded.count - manifestSent) else { throw SFTPProtocolFailure.invalidOutput }
            pending = .manifest(start, count); return .folderUploadManifestRequest(selection.request, start, count)
        case 162:
            let node = Int(try cursor.number(4)), at = try cursor.number(8), count = Int(try cursor.number(4))
            guard started, rootAcknowledged, pending == nil, !filePermitted, node == nextFile, node < m.nodes.count,
                  at == offset, offset < m.nodes[node].size,
                  count == Int(min(32768, m.nodes[node].size - offset)) else { throw SFTPProtocolFailure.invalidOutput }
            pending = .source(node, at, count); return .folderUploadSourceRequest(selection.request, node, at, count)
        case 163:
            let node = Int(try cursor.number(4)), digest = try cursor.take(32)
            guard started, rootAcknowledged, pending == nil, !filePermitted, node == nextFile, node < m.nodes.count,
                  offset == m.nodes[node].size else { throw SFTPProtocolFailure.invalidOutput }
            pending = .file(node, digest); return .folderUploadFilePermitRequest(selection.request, node, digest)
        case 164:
            guard started, pending == nil, manifestSent == m.encoded.count, !rootAnnounced else { throw SFTPProtocolFailure.invalidOutput }
            rootAnnounced = true; pending = .root; return .folderUploadRootCreated(selection.request)
        case 165:
            let node = Int(try cursor.number(4)), count = Int(try cursor.number(4)), size = try cursor.number(8)
            guard started, rootAcknowledged, pending == nil, filePermitted, node == nextFile, node < m.nodes.count,
                  hashes[node] != nil, count == files + 1, size == bytes + m.nodes[node].size else { throw SFTPProtocolFailure.invalidOutput }
            files = count; bytes = size; pending = .progress(node, files, bytes); filePermitted = false; offset = 0
            nextFile = ((node + 1)..<m.nodes.count).first(where: { !m.nodes[$0].directory }) ?? m.nodes.count
            return .folderUploadVerified(selection.request, node, files, bytes)
        case 166:
            let count = Int(try cursor.number(4)), size = try cursor.number(8), digest = try cursor.take(32)
            guard started, rootAcknowledged, pending == nil, nextFile == m.nodes.count, files == count, count == m.files,
                  bytes == size, size == m.logicalBytes, authorizedDigest == nil else { throw SFTPProtocolFailure.invalidOutput }
            var hash = SHA256(); hash.update(data: m.encoded)
            for (node, digest) in zip(m.nodes, hashes) where !node.directory { guard let digest else { throw SFTPProtocolFailure.invalidOutput }; hash.update(data: digest) }
            guard digest == Data(hash.finalize()) else { throw SFTPProtocolFailure.invalidOutput }
            pending = .final(digest); return .folderUploadFinalPermitRequest(selection.request, digest)
        case 167:
            let count = Int(try cursor.number(4)), size = try cursor.number(8), digest = try cursor.take(32)
            guard started, pending == nil, authorizedDigest == digest, count == files, count == m.files, size == bytes, size == m.logicalBytes,
                  try cursor.take(3) == Data([1,1,1]) else { throw SFTPProtocolFailure.invalidOutput }
            closed = true; return .folderUploadComplete(.init(selection: selection, digest: digest))
        case 168:
            let node = Int(try cursor.number(4))
            guard let cause = SFTPUploadInterruption.Cause(rawValue: UInt8(try cursor.number(1))) else { throw SFTPProtocolFailure.invalidOutput }
            let phase = UInt8(try cursor.number(1)), may = try cursor.number(1), ack = try cursor.number(1)
            let count = Int(try cursor.number(4)), size = try cursor.number(8), status = UInt32(try cursor.number(4))
            guard started, node < m.nodes.count, phase <= 6, may <= 1, ack <= 1, ack <= may,
                  count <= files, size <= bytes, ack == 0 || rootAnnounced,
                  may != 0 || ack == 0 && count == 0 && size == 0,
                  cause == .status ? status > 1 : status == 0 else { throw SFTPProtocolFailure.invalidOutput }
            closed = true; return .folderUploadInterrupted(.init(cause: cause, phase: phase, node: node, rootMayExist: may == 1,
                rootAcknowledged: ack == 1, verifiedFiles: count, verifiedBytes: size, status: status))
        default: throw SFTPProtocolFailure.invalidOutput
        }
    }
    mutating func reply(request: UUID, _ response: SFTPFolderUploadReply) throws -> (UInt8, Data) {
        guard !closed, selection.request == request else { throw SFTPProtocolFailure.phase }
        var value = SFTPWire.token(request); let tag: UInt8
        switch (pending, response) {
        case (.manifest(let offset, let count), .manifest(let at, let bytes)) where at == offset && count == bytes.count:
            guard bytes == selection.manifest.encoded.subdata(in: offset..<(offset + count)) else { throw SFTPProtocolFailure.invalidInput }
            tag = 24; SFTPWire.number(UInt64(offset), bytes: 4, into: &value); try SFTPWire.field(bytes, into: &value); manifestSent += count
        case (.source(let node, let offset, let count), .source(let index, let at, let bytes)) where node == index && offset == at && count == bytes.count:
            tag = 25; SFTPWire.number(UInt64(node), bytes: 4, into: &value); SFTPWire.number(offset, bytes: 8, into: &value); try SFTPWire.field(bytes, into: &value); self.offset += UInt64(count)
        case (.file(let node, let digest), .filePermit(let index, let actual)) where node == index && digest == actual:
            tag = 26; SFTPWire.number(UInt64(node), bytes: 4, into: &value); value.append(digest); hashes[node] = digest; filePermitted = true
        case (.root, .rootAcknowledged): tag = 27; rootAcknowledged = true
        case (.progress(let node, let files, let bytes), .progress(let index, let count, let size)) where node == index && files == count && bytes == size:
            tag = 28; SFTPWire.number(UInt64(node), bytes: 4, into: &value); SFTPWire.number(UInt64(files), bytes: 4, into: &value); SFTPWire.number(bytes, bytes: 8, into: &value)
        case (.final(let digest), .finalPermit(let actual)) where digest == actual:
            tag = 29; value.append(digest); authorizedDigest = digest
        default: throw SFTPProtocolFailure.phase
        }
        pending = nil; return (tag, value)
    }
}
