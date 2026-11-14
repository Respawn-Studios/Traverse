import Foundation

@_spi(Qualification) public enum SFTPInPlaceEditRefusalReason: Sendable { case syncUnavailable, readWriteDenied }
@_spi(Qualification) public struct SFTPInPlaceEditRefusal: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let reason: SFTPInPlaceEditRefusalReason
    public let localCleanupNeedsReview: Bool
    let proof: SFTPInPlacePrebodyRejection
    init(_ proof: SFTPInPlacePrebodyRejection, localCleanupNeedsReview: Bool) {
        self.proof = proof; reason = proof.reason; self.localCleanupNeedsReview = localCleanupNeedsReview
    }
    public var description: String { "<SFTP Edit unavailable>" }
    public var debugDescription: String { description }
}
/// Constructor belongs only to the exact in-place request decoder.
struct SFTPInPlacePrebodyRejection: Sendable {
    let request: UUID, generation: UUID, revision: UInt64, observation: UInt64
    let reason: SFTPInPlaceEditRefusalReason
    fileprivate init(request: UUID, generation: UUID, revision: UInt64, observation: UInt64, reason: SFTPInPlaceEditRefusalReason) {
        self.request = request; self.generation = generation; self.revision = revision; self.observation = observation; self.reason = reason
    }
}

/// Separate M/N events, after the actual outer session/sequence decoder.
enum SFTPInPlaceWorkerEvent: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case rejected(SFTPInPlacePrebodyRejection)
    case header(Data), chunk(Data), seal(Data), admitted(Data), source(Data), permit(Data), observed(Data), completed(Data), interrupted(Data), released(Data)
    var description: String { "<SFTP in-place v1 event>" }
    var debugDescription: String { description }
}
struct SFTPInPlaceProtocolState {
    private struct Read {
        let selection: SFTPDownloadSelection
        let catalogRevision: UInt64
        var header = false, received: UInt64 = 0
        var sealed: Data?, accepted = false
    }
    private struct Save {
        let record: SFTPInPlaceRecord
        var sent: UInt64 = 0
        var pendingSource: (UInt64, UInt64)?, pendingPermit: Data?
        var requested = 0, acknowledged = 0
    }
    private struct Release { let request: UUID, token: UUID, revision: UInt64 }
    private enum Work { case read(Read), save(Save), release(Release) }
    private var work: Work?, baselines: [UUID: UInt64] = [:]
    var isIdle: Bool { work == nil }
    var liveBaselineCount: Int { baselines.count }
    mutating func beginRead(_ selection: SFTPDownloadSelection, catalogRevision: UInt64) throws {
        guard work == nil, baselines.count < 2, selection.logicalBytes <= 1 << 20, catalogRevision > 0 else { throw SFTPProtocolFailure.phase }; work = .read(.init(selection: selection, catalogRevision: catalogRevision))
    }
    mutating func beginSave(_ record: SFTPInPlaceRecord) throws {
        try record.validate()
        guard work == nil, baselines[record.baselineToken] == record.baselineRevision else { throw SFTPProtocolFailure.phase }
        baselines.removeValue(forKey: record.baselineToken); work = .save(.init(record: record))
    }
    mutating func beginRelease(_ payload: Data) throws {
        var c = SFTPCursor(payload); let request = try c.token(), token = try c.token(), revision = try c.number(8)
        guard c.finished, revision > 0, work == nil, baselines[token] == revision else { throw SFTPProtocolFailure.phase }
        work = .release(.init(request: request, token: token, revision: revision))
    }
    mutating func noteAcceptance(_ payload: Data) throws {
        guard case .read(var read) = work, let digest = read.sealed, !read.accepted else { throw SFTPProtocolFailure.phase }
        var c = SFTPCursor(payload)
        guard try c.token() == read.selection.request, try c.take(32) == digest, c.finished else { throw SFTPProtocolFailure.invalidOutput }
        read.accepted = true; work = .read(read)
    }
    mutating func noteSource(_ payload: Data) throws {
        guard case .save(var save) = work, let pending = save.pendingSource else { throw SFTPProtocolFailure.phase }
        var c = SFTPCursor(payload); guard try c.token() == save.record.id, try c.number(8) == pending.0 else { throw SFTPProtocolFailure.invalidOutput }
        let bytes = try c.field(cap: 32768); guard c.finished, bytes.count == Int(pending.1) else { throw SFTPProtocolFailure.invalidOutput }
        save.sent += pending.1; save.pendingSource = nil; work = .save(save)
    }
    mutating func notePermit(_ payload: Data) throws {
        guard case .save(var save) = work, save.pendingPermit == payload else { throw SFTPProtocolFailure.phase }
        save.pendingPermit = nil; save.requested += 1; work = .save(save)
    }
    mutating func invalidateAfterActualSessionEnd() { work = nil; baselines.removeAll() }
    mutating func consume(_ kind: UInt64, payload: Data) throws -> SFTPInPlaceWorkerEvent {
        switch kind {
        case 201:
            guard case .read(let read) = work, !read.header, read.received == 0,
                  read.sealed == nil, !read.accepted else { throw SFTPProtocolFailure.phase }
            var c = SFTPCursor(payload)
            guard try c.token() == read.selection.request, try c.token() == read.selection.generation,
                  try c.number(8) == read.catalogRevision,
                  try c.number(8) == read.selection.row.observation else { throw SFTPProtocolFailure.stale }
            let reason = try c.number(1), status = try c.number(4)
            guard c.finished, reason == 1 && status == 0 || reason == 2 && status == 3 else { throw SFTPProtocolFailure.invalidOutput }
            let proof = SFTPInPlacePrebodyRejection(request: read.selection.request, generation: read.selection.generation,
                revision: read.catalogRevision, observation: read.selection.row.observation,
                reason: reason == 1 ? .syncUnavailable : .readWriteDenied)
            work = nil; return .rejected(proof)
        case 190...193: return try readEvent(kind, payload)
        case 194...198: return try saveEvent(kind, payload)
        case 199:
            guard case .release(let release) = work else { throw SFTPProtocolFailure.phase }
            var c = SFTPCursor(payload)
            guard try c.token() == release.request, try c.token() == release.token, try c.number(8) == release.revision else { throw SFTPProtocolFailure.invalidOutput }
            let result = try c.number(1)
            guard result == 1 || result == 2, try c.boolean(), try c.boolean(), c.finished else { throw SFTPProtocolFailure.invalidOutput }
            baselines.removeValue(forKey: release.token); work = nil; return .released(payload)
        default: throw SFTPProtocolFailure.invalidOutput
        }
    }
    private mutating func readEvent(_ kind: UInt64, _ payload: Data) throws -> SFTPInPlaceWorkerEvent {
        guard case .read(var read) = work else { throw SFTPProtocolFailure.phase }
        var c = SFTPCursor(payload)
        guard try c.token() == read.selection.request else { throw SFTPProtocolFailure.invalidOutput }
        let event: SFTPInPlaceWorkerEvent
        switch kind {
        case 190:
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
        case 191:
            guard read.header, read.sealed == nil, !read.accepted, try c.number(8) == read.received else { throw SFTPProtocolFailure.phase }
            let bytes = try c.field(cap: 32768)
            guard c.finished, !bytes.isEmpty, UInt64(bytes.count) <= read.selection.logicalBytes - read.received else { throw SFTPProtocolFailure.invalidOutput }
            read.received += UInt64(bytes.count); event = .chunk(payload)
        case 192:
            guard read.header, read.sealed == nil, read.received == read.selection.logicalBytes, !read.accepted else { throw SFTPProtocolFailure.phase }
            let digest = try c.take(32)
            guard try c.number(8) == read.received, c.finished else { throw SFTPProtocolFailure.invalidOutput }
            read.sealed = digest; event = .seal(payload)
        case 193:
            guard read.accepted, let digest = read.sealed else { throw SFTPProtocolFailure.phase }
            let token = try c.token(), revision = try c.number(8)
            guard revision == 1, try c.take(32) == digest, try c.number(1) == 1, try c.boolean(), try c.boolean(), c.finished, baselines[token] == nil,
                  baselines.count < 2 else { throw SFTPProtocolFailure.invalidOutput }
            baselines[token] = revision; work = nil; return .admitted(payload)
        default: throw SFTPProtocolFailure.invalidOutput
        }
        work = .read(read); return event
    }
    private mutating func saveEvent(_ kind: UInt64, _ payload: Data) throws -> SFTPInPlaceWorkerEvent {
        guard case .save(var save) = work else { throw SFTPProtocolFailure.phase }
        var c = SFTPCursor(payload); guard try c.token() == save.record.id else { throw SFTPProtocolFailure.invalidOutput }
        let plan = try save.record.plan, event: SFTPInPlaceWorkerEvent
        switch kind {
        case 194:
            guard save.requested == 0, save.pendingSource == nil, save.pendingPermit == nil else { throw SFTPProtocolFailure.phase }
            let offset = try c.number(8), count = try c.number(4)
            guard c.finished, offset == save.sent, (1...32768).contains(count), count <= save.record.edited.logicalBytes - save.sent else { throw SFTPProtocolFailure.invalidOutput }
            save.pendingSource = (offset, count); event = .source(payload)
        case 195:
            guard save.pendingSource == nil, save.pendingPermit == nil, save.requested == save.acknowledged,
                  save.requested < plan.count, save.sent == save.record.edited.logicalBytes else { throw SFTPProtocolFailure.phase }
            let step = try SFTPInPlaceStep(cursor: &c)
            guard step == plan[save.requested], try c.take(32) == save.record.edited.digest, c.finished else { throw SFTPProtocolFailure.invalidOutput }
            save.pendingPermit = payload; event = .permit(payload)
        case 196:
            guard save.pendingSource == nil, save.pendingPermit == nil, save.requested == save.acknowledged + 1 else { throw SFTPProtocolFailure.phase }
            let step = try SFTPInPlaceStep(cursor: &c)
            guard c.finished, step == plan[save.acknowledged] else { throw SFTPProtocolFailure.invalidOutput }
            save.acknowledged += 1; event = .observed(payload)
        case 197:
            guard save.pendingSource == nil, save.pendingPermit == nil, save.requested == plan.count, save.acknowledged == plan.count,
                  try c.token() == save.record.editorGeneration else { throw SFTPProtocolFailure.phase }
            let token = try c.token(), revision = try c.number(8), size = try c.number(8), digest = try c.take(32), actual = try c.number(8)
            _ = try c.number(4); let mode = try c.number(4), uid = try c.number(4), gid = try c.number(4)
            guard revision == save.record.baselineRevision + 1, size == save.record.edited.logicalBytes, actual == size, digest == save.record.edited.digest,
                  mode == save.record.mode, uid == save.record.uid, gid == save.record.gid,
                  try c.number(1) == UInt64(plan.count), try c.number(1) == UInt64(plan.count),
                  try c.boolean(), try c.boolean(), try c.boolean(), try c.boolean(), c.finished,
                  baselines[token] == nil, baselines.count < 2 else { throw SFTPProtocolFailure.invalidOutput }
            baselines[token] = revision; work = nil; return .completed(payload)
        case 198:
            let phase = try c.number(1), requested = try c.number(1), acknowledged = try c.number(1), cause = try c.number(1), status = try c.number(4)
            guard c.finished, phase <= 8, cause <= 10, cause == 6 || status == 0, acknowledged <= requested,
                  acknowledged == UInt64(save.acknowledged), requested <= UInt64(save.requested),
                  UInt64(save.requested) <= requested + 1 else { throw SFTPProtocolFailure.invalidOutput }
            work = nil; return .interrupted(payload)
        default: throw SFTPProtocolFailure.invalidOutput
        }
        work = .save(save); return event
    }
}
