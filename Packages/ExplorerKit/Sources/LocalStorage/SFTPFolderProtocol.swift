#if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
import Foundation

/// A phase-bound decoder for the two new folder protocol versions. It never
/// accepts a member path or receipt before its selected manifest is complete.
struct SFTPFolderProtocolState {
    private enum Phase { case starting, listing, prepared, awaitingReceipt, receiving, releasing, ended }
    let selection: SFTPFolderDownloadSelection
    private var phase: Phase = .starting, nodes: [SFTPFolderManifest.Node] = []
    private var componentBytes = 0, nextFile = 0, current: Int?, memberBytes: UInt64 = 0, totalBytes: UInt64 = 0, files = 0
    private var manifest: SFTPFolderManifest?
    var ended: Bool { phase == .ended }
    init(_ selection: SFTPFolderDownloadSelection) { self.selection = selection }
    mutating func beginReceipt(_ prepared: SFTPPreparedFolderDownload) throws {
        guard phase == .prepared, prepared.selection == selection, prepared.manifest == manifest else { throw SFTPProtocolFailure.stale }
        phase = .awaitingReceipt
    }
    mutating func beginRelease(_ request: UUID) throws {
        guard phase == .prepared, request == selection.request else { throw SFTPProtocolFailure.stale }; phase = .releasing
    }
    mutating func consume(_ kind: UInt64, cursor: inout SFTPCursor) throws -> SFTPWorkerEvent? {
        let request = try cursor.token()
        guard request == selection.request else { throw SFTPProtocolFailure.stale }
        switch kind {
        case 150:
            guard phase == .starting, try cursor.token() == selection.generation,
                  try cursor.number(8) == selection.read, try cursor.number(8) == selection.revision,
                  try cursor.number(8) == selection.observation else { throw SFTPProtocolFailure.stale }
            phase = .listing; return .folderStarted(request)
        case 151:
            let stage = try cursor.number(1), count = try cursor.number(4), bytes = try cursor.number(8)
            guard count <= 2_048, bytes <= 1 << 30,
                  phase == .listing && stage == 0 || phase == .receiving && (1...3).contains(stage) else { throw SFTPProtocolFailure.phase }
            return .folderMetadataProgress(request, UInt8(stage), Int(count))
        case 152:
            let ordinal = try cursor.number(4), depth = try cursor.number(1)
            guard phase == .listing, ordinal == nodes.count, nodes.count < 2_048, depth <= 32 else { throw SFTPProtocolFailure.invalidOutput }
            var components: [Data] = []
            for _ in 0..<Int(depth) {
                let bytes = try cursor.field(cap: 255)
                guard SFTPFolderManifest.localName(bytes) != nil, componentBytes <= (4 << 20) - bytes.count else { throw SFTPProtocolFailure.invalidOutput }
                componentBytes += bytes.count; components.append(bytes)
            }
            let present = try cursor.boolean(), size = try cursor.number(8), modified = try cursor.number(4), permissions = try cursor.number(4)
            guard present || size == 0 else { throw SFTPProtocolFailure.invalidOutput }
            nodes.append(.init(components: components, size: present ? size : nil, modified: UInt32(modified), permissions: UInt32(permissions)))
            return nil
        case 153:
            let count = try cursor.number(4), files = try cursor.number(4), folders = try cursor.number(4), bytes = try cursor.number(8), longest = try cursor.number(4)
            guard phase == .listing, count == nodes.count else { throw SFTPProtocolFailure.phase }
            let value = try SFTPFolderManifest(nodes: nodes)
            guard files == value.files, folders == value.folders, bytes == value.logicalBytes, longest == value.longestPathBytes else { throw SFTPProtocolFailure.invalidOutput }
            let prepared = try SFTPPreparedFolderDownload(selection: selection, manifest: value)
            manifest = value; phase = .prepared; return .folderPrepared(prepared)
        case 154:
            guard phase == .awaitingReceipt else { throw SFTPProtocolFailure.phase }; phase = .receiving; return .folderReceiving(request)
        case 155:
            let ordinal = try cursor.number(4)
            while nextFile < nodes.count, nodes[nextFile].directory { nextFile += 1 }
            guard phase == .receiving, current == nil, nextFile < nodes.count, ordinal == nextFile else { throw SFTPProtocolFailure.invalidOutput }
            current = nextFile; memberBytes = 0; return .folderMemberStarted(request, nextFile)
        case 156:
            let ordinal = try cursor.number(4), offset = try cursor.number(8), bytes = try cursor.field(cap: 32_768)
            guard phase == .receiving, let current, ordinal == current, !bytes.isEmpty,
                  offset == memberBytes, let size = nodes[current].size, memberBytes <= size,
                  UInt64(bytes.count) <= size - memberBytes else { throw SFTPProtocolFailure.invalidOutput }
            memberBytes += UInt64(bytes.count); totalBytes += UInt64(bytes.count)
            return .folderMemberBytes(request, current, offset, bytes)
        case 157:
            let ordinal = try cursor.number(4), bytes = try cursor.number(8)
            guard phase == .receiving, let current, ordinal == current, bytes == memberBytes, bytes == nodes[current].size else { throw SFTPProtocolFailure.invalidOutput }
            self.current = nil; nextFile = current + 1; files += 1; return .folderMemberFinished(request, current, bytes)
        case 158:
            let bytes = try cursor.number(8), count = try cursor.number(4), complete = try cursor.boolean(), closed = try cursor.boolean()
            guard phase == .receiving, let manifest, current == nil, complete, closed,
                  bytes == totalBytes, bytes == manifest.logicalBytes, count == files, count == manifest.files else { throw SFTPProtocolFailure.invalidOutput }
            phase = .ended; return .folderComplete(request, bytes, files)
        case 159:
            guard phase == .releasing else { throw SFTPProtocolFailure.phase }; phase = .ended; return .folderReleased(request)
        default: throw SFTPProtocolFailure.invalidOutput
        }
    }
}

extension SFTPFolderDownloadSelection {
    func command() -> Data {
        var data = SFTPWire.token(request); data.append(SFTPWire.token(generation))
        for value in [read, revision, observation] { SFTPWire.number(value, bytes: 8, into: &data) }; return data
    }
}

@_spi(Qualification) public struct SFTPFolderDownloadProgress: Sendable {
    public enum Phase: Sendable, Equatable { case checkingFolders, receiving, checkingCopy }
    public let phase: Phase, receivedBytes: UInt64, completedFiles: Int, checkedEntries: Int
}
struct SFTPFolderDownloadReceipt: Sendable { let request: UUID, bytes: UInt64, files: Int }
#endif
