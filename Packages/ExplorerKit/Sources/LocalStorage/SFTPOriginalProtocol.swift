import Foundation

/// Exact K/L payloads, after the existing decoder has checked magic, session,
/// sequence and frame length. Bodies/paths never enter descriptions or logs.
enum SFTPOriginalWorkerEvent: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case header(Data), chunk(Data), seal(Data), admitted(Data)
    case source(Data), permit(Data), observed(Data), completed(Data), interrupted(Data), released(Data)
    var description: String { "<SFTP Original event>" }
    var debugDescription: String { description }
}

/// One serial Original request. The real local job/attempt independently checks
/// body and durable metadata; protocol acceptance alone grants no Saved result.
struct SFTPOriginalProtocolState {
    private struct Read {
        let selection: SFTPDownloadSelection
        var header = false, received: UInt64 = 0
        var sealed: Data?, accepted = false
    }
    private struct Save {
        let record: SFTPOriginalRecord
        var sent: UInt64 = 0
        var pendingSource: (UInt64, UInt64)?
        var pendingPermit: Data?
        var requested: UInt8 = 0, acknowledged: UInt8 = 0
        var sourceVerified = false
    }
    private struct Release { let request: UUID, token: UUID, revision: UInt64 }
    private enum Work { case read(Read), save(Save), release(Release) }
    private var work: Work?
    private var baselines: [UUID: UInt64] = [:]
    var isIdle: Bool { work == nil }
    var liveBaselineCount: Int { baselines.count }

    mutating func beginRead(_ selection: SFTPDownloadSelection) throws {
        guard work == nil, baselines.count < 2, selection.logicalBytes <= 1 << 20 else { throw SFTPProtocolFailure.phase }
        work = .read(.init(selection: selection))
    }
    mutating func beginSave(_ record: SFTPOriginalRecord) throws {
        try record.validate()
        guard work == nil, baselines[record.baselineToken] == record.baselineRevision else { throw SFTPProtocolFailure.phase }
        baselines.removeValue(forKey: record.baselineToken)
        work = .save(.init(record: record))
    }
    mutating func beginRelease(_ payload: Data) throws {
        var c = SFTPCursor(payload)
        let request = try c.token(), token = try c.token(), revision = try c.number(8)
        guard c.finished, revision > 0, work == nil, baselines[token] == revision else { throw SFTPProtocolFailure.phase }
        work = .release(.init(request: request, token: token, revision: revision))
    }
    mutating func noteAcceptance(_ payload: Data) throws {
        guard case .read(var read) = work, read.header, let digest = read.sealed, !read.accepted else { throw SFTPProtocolFailure.phase }
        var c = SFTPCursor(payload)
        guard try c.token() == read.selection.request, try c.take(32) == digest, c.finished else { throw SFTPProtocolFailure.invalidOutput }
        read.accepted = true; work = .read(read)
    }
    mutating func noteSource(_ payload: Data) throws {
        guard case .save(var save) = work, let pending = save.pendingSource else { throw SFTPProtocolFailure.phase }
        var c = SFTPCursor(payload)
        guard try c.token() == save.record.id, try c.number(8) == pending.0 else { throw SFTPProtocolFailure.invalidOutput }
        let bytes = try c.field(cap: 32768)
        guard c.finished, UInt64(bytes.count) == pending.1 else { throw SFTPProtocolFailure.invalidOutput }
        save.sent += pending.1; save.pendingSource = nil; work = .save(save)
    }
    mutating func notePermit(_ payload: Data) throws {
        guard case .save(var save) = work, save.pendingPermit == payload else { throw SFTPProtocolFailure.phase }
        var c = SFTPCursor(payload); _ = try c.token(); let edge = try c.number(1)
        if edge == 0 { save.sourceVerified = true }
        else { save.requested |= UInt8(1 << (edge - 1)) }
        save.pendingPermit = nil; work = .save(save)
    }
    mutating func invalidateAfterActualSessionEnd() { work = nil; baselines.removeAll() }

    mutating func consume(_ kind: UInt64, payload: Data) throws -> SFTPOriginalWorkerEvent {
        switch kind {
        case 180...183: return try readEvent(kind, payload)
        case 184...188: return try saveEvent(kind, payload)
        case 189:
            guard case .release(let release) = work else { throw SFTPProtocolFailure.phase }
            var c = SFTPCursor(payload)
            guard try c.token() == release.request, try c.token() == release.token,
                  try c.number(8) == release.revision else { throw SFTPProtocolFailure.invalidOutput }
            let result = try c.number(1)
            guard c.finished, result == 1 || result == 2 else { throw SFTPProtocolFailure.invalidOutput }
            baselines.removeValue(forKey: release.token); work = nil; return .released(payload)
        default: throw SFTPProtocolFailure.invalidOutput
        }
    }
    private mutating func readEvent(_ kind: UInt64, _ payload: Data) throws -> SFTPOriginalWorkerEvent {
        guard case .read(var read) = work else { throw SFTPProtocolFailure.phase }
        var c = SFTPCursor(payload)
        guard try c.token() == read.selection.request else { throw SFTPProtocolFailure.invalidOutput }
        let event: SFTPOriginalWorkerEvent
        switch kind {
        case 180:
            guard !read.header, read.sealed == nil, try c.token() == read.selection.generation else { throw SFTPProtocolFailure.phase }
            let size = try c.number(8), modified = try c.number(4), mode = try c.number(4)
            _ = try c.number(4); _ = try c.number(4)
            let path = try c.text(cap: 8192)
            guard c.finished, size == read.selection.logicalBytes,
                  modified == read.selection.row.entry.modifiedSeconds.map({ UInt64($0) }),
                  mode == read.selection.row.entry.permissions.map({ UInt64($0) }),
                  mode & 0o170000 == 0o100000, mode & 0o7000 == 0,
                  path.hasPrefix("/"), !path.hasSuffix("/"), path.split(separator: "/").count <= 127,
                  path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  path.split(separator: "/").last.map({ Data($0.utf8) }) == read.selection.row.entry.name.wireUTF8 else { throw SFTPProtocolFailure.invalidOutput }
            read.header = true; event = .header(payload)
        case 181:
            guard read.header, read.sealed == nil, !read.accepted, try c.number(8) == read.received else { throw SFTPProtocolFailure.phase }
            let bytes = try c.field(cap: 32768)
            guard c.finished, !bytes.isEmpty, UInt64(bytes.count) <= read.selection.logicalBytes - read.received else { throw SFTPProtocolFailure.invalidOutput }
            read.received += UInt64(bytes.count); event = .chunk(payload)
        case 182:
            guard read.header, read.sealed == nil, read.received == read.selection.logicalBytes, !read.accepted else { throw SFTPProtocolFailure.phase }
            let digest = try c.take(32)
            guard try c.number(8) == read.received, c.finished else { throw SFTPProtocolFailure.invalidOutput }
            read.sealed = digest; event = .seal(payload)
        case 183:
            guard read.accepted, let digest = read.sealed else { throw SFTPProtocolFailure.phase }
            let token = try c.token(), revision = try c.number(8)
            guard revision == 1, try c.take(32) == digest, c.finished, baselines[token] == nil,
                  baselines.count < 2 else { throw SFTPProtocolFailure.invalidOutput }
            baselines[token] = revision; work = nil; return .admitted(payload)
        default: throw SFTPProtocolFailure.invalidOutput
        }
        work = .read(read); return event
    }
    private mutating func saveEvent(_ kind: UInt64, _ payload: Data) throws -> SFTPOriginalWorkerEvent {
        guard case .save(var save) = work else { throw SFTPProtocolFailure.phase }
        var c = SFTPCursor(payload)
        guard try c.token() == save.record.id else { throw SFTPProtocolFailure.invalidOutput }
        let event: SFTPOriginalWorkerEvent
        switch kind {
        case 184:
            guard save.pendingSource == nil, save.pendingPermit == nil, !save.sourceVerified,
                  save.acknowledged & SFTPOriginalEdge.stage.bit != 0 else { throw SFTPProtocolFailure.phase }
            let offset = try c.number(8), count = try c.number(4)
            guard c.finished, offset == save.sent, (1...32768).contains(count),
                  count <= save.record.edited.logicalBytes - save.sent else { throw SFTPProtocolFailure.invalidOutput }
            save.pendingSource = (offset, count); event = .source(payload)
        case 185:
            guard save.pendingSource == nil, save.pendingPermit == nil else { throw SFTPProtocolFailure.phase }
            let edge = try c.number(1), requested = try c.number(1), acknowledged = try c.number(1)
            let roles = try c.take(32), digest = try c.take(32)
            guard c.finished, digest == save.record.edited.digest else { throw SFTPProtocolFailure.invalidOutput }
            if edge == 0 {
                guard !save.sourceVerified, roles == Data(repeating: 0, count: 32),
                      requested == 0, acknowledged == 0,
                      save.sent == save.record.edited.logicalBytes,
                      save.acknowledged == (SFTPOriginalEdge.container.bit | SFTPOriginalEdge.stage.bit) else { throw SFTPProtocolFailure.phase }
            } else {
                guard let parsed = SFTPOriginalEdge(rawValue: UInt8(edge)), parsed != .restore,
                      requested == UInt64(save.requested), acknowledged == UInt64(save.acknowledged),
                      roles == save.record.rolesDigest, save.requested & parsed.bit == 0,
                      save.requested == save.acknowledged else { throw SFTPProtocolFailure.phase }
                if let predecessor = parsed.predecessor {
                    guard save.acknowledged & predecessor.bit != 0 else { throw SFTPProtocolFailure.phase }
                }
                if parsed == .linkCheck { guard save.sourceVerified else { throw SFTPProtocolFailure.phase } }
            }
            save.pendingPermit = payload; event = .permit(payload)
        case 186:
            guard save.pendingSource == nil, save.pendingPermit == nil else { throw SFTPProtocolFailure.phase }
            let raw = try c.number(1), requested = try c.number(1), acknowledged = try c.number(1)
            guard c.finished, let edge = SFTPOriginalEdge(rawValue: UInt8(raw)), edge != .restore,
                  requested == UInt64(save.requested), save.requested & edge.bit != 0,
                  save.acknowledged & edge.bit == 0,
                  acknowledged == UInt64(save.acknowledged | edge.bit) else { throw SFTPProtocolFailure.invalidOutput }
            save.acknowledged |= edge.bit; event = .observed(payload)
        case 187:
            guard save.pendingSource == nil, save.pendingPermit == nil, save.sourceVerified,
                  save.sent == save.record.edited.logicalBytes, save.requested == 0x1f, save.acknowledged == 0x1f,
                  try c.token() == save.record.editorGeneration else { throw SFTPProtocolFailure.phase }
            let next = try c.token(), revision = try c.number(8), size = try c.number(8), digest = try c.take(32)
            let observedSize = try c.number(8); _ = try c.number(4)
            let mode = try c.number(4), uid = try c.number(4), gid = try c.number(4)
            guard try c.number(1) == 0x1f, try c.number(1) == 0x1f,
                  try c.boolean(), try c.boolean(), try c.boolean(), c.finished,
                  save.record.baselineRevision < UInt64.max, revision == save.record.baselineRevision + 1,
                  size == save.record.edited.logicalBytes, observedSize == size, digest == save.record.edited.digest,
                  mode == save.record.mode, uid == save.record.uid, gid == save.record.gid,
                  baselines[next] == nil, baselines.count < 2 else { throw SFTPProtocolFailure.invalidOutput }
            baselines[next] = revision; work = nil; return .completed(payload)
        case 188:
            let phase = try c.number(1), requested = try c.number(1), acknowledged = try c.number(1)
            let cause = try c.number(1), wire = try c.number(1), status = try c.number(4)
            guard c.finished, phase <= 12, cause <= 4, wire <= 10,
                  cause == 0 || wire == 0 && status == 0, cause == 0 && wire == 6 || status == 0,
                  requested & ~UInt64(save.requested) == 0, acknowledged & ~requested == 0,
                  UInt64(save.acknowledged) & ~acknowledged == 0 else { throw SFTPProtocolFailure.invalidOutput }
            work = nil; return .interrupted(payload)
        default: throw SFTPProtocolFailure.invalidOutput
        }
        work = .save(save); return event
    }
}
