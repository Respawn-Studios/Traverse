import CoreFoundation
import Foundation

/// V1 sequential facts, independent of K/L's namespace-publication bitmask.
/// Each WRITE names its exact offset/count; a missing ACK stays uncertain.
enum SFTPInPlaceKind: UInt8, Codable, Sendable { case source, write, truncate, sync, handleReadback, locationReadback }
struct SFTPInPlaceStep: Codable, Equatable, Sendable {
    let sequence: UInt8, kind: SFTPInPlaceKind, offset: UInt64, count: UInt32
    static func plan(old: UInt64, new: UInt64) throws -> [Self] {
        guard old <= 1 << 20, new <= 1 << 20 else { throw SFTPTextFailure.unsupported }
        var result = [Self(sequence: 1, kind: .source, offset: 0, count: 0)]
        var offset: UInt64 = 0
        while offset < new {
            let count = UInt32(min(32768, new - offset))
            result.append(.init(sequence: UInt8(result.count + 1), kind: .write, offset: offset, count: count)); offset += UInt64(count)
        }
        if new < old { result.append(.init(sequence: UInt8(result.count + 1), kind: .truncate, offset: new, count: 0)) }
        for kind in [SFTPInPlaceKind.sync, .handleReadback, .locationReadback] {
            result.append(.init(sequence: UInt8(result.count + 1), kind: kind, offset: new, count: 0))
        }
        return result
    }
    init(sequence: UInt8, kind: SFTPInPlaceKind, offset: UInt64, count: UInt32) {
        self.sequence = sequence; self.kind = kind; self.offset = offset; self.count = count
    }
    init(cursor: inout SFTPCursor) throws {
        let sequence = try cursor.number(1), raw = try cursor.number(1), offset = try cursor.number(8), count = try cursor.number(4)
        guard (1...37).contains(sequence), let kind = SFTPInPlaceKind(rawValue: UInt8(raw)), offset <= 1 << 20, count <= 32768 else { throw SFTPProtocolFailure.invalidOutput }
        self.init(sequence: UInt8(sequence), kind: kind, offset: offset, count: UInt32(count))
    }
    var mutatesBytes: Bool { kind == .write || kind == .truncate }
    func append(to bytes: inout Data) {
        bytes.append(sequence); bytes.append(kind.rawValue); SFTPWire.number(offset, bytes: 8, into: &bytes); SFTPWire.number(UInt64(count), bytes: 4, into: &bytes)
    }
}
enum SFTPInPlaceOutcome: String, Codable, Sendable { case prepared, inProgress, verified, notStarted, recoveryRequired }
struct SFTPInPlaceRecord: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    let id: UUID, editorGeneration: UUID, session: UUID, baselineToken: UUID, baselineRevision: UInt64
    let context: SFTPOriginalContext, path: String
    let baseline: SFTPOriginalSpoolReference, edited: SFTPOriginalSpoolReference
    let baselineModified: UInt32, uid: UInt32, gid: UInt32, mode: UInt32
    var requested: [SFTPInPlaceStep] = [], acknowledged: [SFTPInPlaceStep] = []
    var outcome = SFTPInPlaceOutcome.prepared
    var debugDescription: String { "<in-place durable Save facts>" }
    var plan: [SFTPInPlaceStep] { get throws { try SFTPInPlaceStep.plan(old: baseline.logicalBytes, new: edited.logicalBytes) } }
    var mutationMayHaveHappened: Bool { requested.contains(where: \.mutatesBytes) }
    func validate() throws {
        try context.validate(); try baseline.validate(); try edited.validate()
        guard [id, editorGeneration, session, baselineToken].allSatisfy(SFTPWire.validToken), baselineRevision > 0, baselineRevision < UInt64.max,
              baseline.id != edited.id, path.hasPrefix("/"), !path.hasSuffix("/"), path.utf8.count <= 8192, !path.utf8.contains(0),
              path.split(separator: "/").count <= 127,
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              mode & 0o170000 == 0o100000, mode & 0o7000 == 0 else { throw RemoteSettingsFailure.invalidRecord }
        let expected = try plan
        guard requested.count <= expected.count, requested == Array(expected.prefix(requested.count)),
              acknowledged == Array(requested.prefix(acknowledged.count)), acknowledged.count <= requested.count,
              requested.count <= acknowledged.count + 1 else { throw RemoteSettingsFailure.invalidRecord }
        switch outcome {
        case .prepared: guard requested.isEmpty, acknowledged.isEmpty else { throw RemoteSettingsFailure.invalidRecord }
        case .notStarted: guard !mutationMayHaveHappened else { throw RemoteSettingsFailure.invalidRecord }
        case .verified: guard requested == expected, acknowledged == expected else { throw RemoteSettingsFailure.invalidRecord }
        case .inProgress, .recoveryRequired: break
        }
    }
}
/// Same bounded physical journal as Source7, DISTINCT canonical identity.
/// Existing K/L history refuses new admission; neither history is migrated or
/// deleted. Already-running old owners cannot ignore a fourth metadata root.
struct SFTPInPlaceJournalDocument: RemoteSettingsDocument, Codable, Sendable {
    var format = 1, protocolIdentity = "sftp-guarded-inplace-save-v1"
    var revision: UInt64 = 0
    var records: [SFTPInPlaceRecord] = []
    init() {}
    func encoded() throws -> Data {
        guard format == 1, protocolIdentity == "sftp-guarded-inplace-save-v1", records.count <= 64,
              Set(records.map(\.id)).count == records.count else { throw RemoteSettingsFailure.invalidRecord }
        try records.forEach { try $0.validate() }
        var references: [UUID: SFTPOriginalSpoolReference] = [:]
        for record in records {
            for ref in [record.baseline, record.edited] {
                if let old = references[ref.id] { guard old == ref else { throw RemoteSettingsFailure.invalidRecord } }
                else { references[ref.id] = ref }
            }
        }
        guard references.count <= SFTPSharedBudgetDocument.expandedBodySlots,
              references.values.reduce(UInt64(0), { $0 + $1.logicalBytes + (64 << 10) }) <= 30 << 20 else { throw RemoteSettingsFailure.capacity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= RemoteSettingsFile<Self>.maximumBytes else { throw RemoteSettingsFailure.capacity }; return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let number = object?["format"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw RemoteSettingsFailure.invalidRecord }
            guard number.intValue == 1, object?["protocolIdentity"] as? String == "sftp-guarded-inplace-save-v1" else { throw RemoteSettingsFailure.incompatibleVersion }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard try value.encoded() == bytes else { throw RemoteSettingsFailure.invalidRecord }; return value
        } catch let error as RemoteSettingsFailure { throw error } catch { throw RemoteSettingsFailure.invalidRecord }
    }
}
final class SFTPInPlaceJournal: @unchecked Sendable {
    typealias File = RemoteSettingsFile<SFTPInPlaceJournalDocument>
    let directory: URL, layout: SFTPSharedBudgetLayout
    private let executor = UploadLocalExecutor(label: "Traverse.SFTP.InPlaceV1.Journal")
    private let probe: File.Probe?
    private var owner: File?, active: UUID?
    init(layout: SFTPSharedBudgetLayout, probe: File.Probe? = nil) { self.layout = layout; directory = layout.journal; self.probe = probe }
    deinit { let held = owner; executor.enqueueDrain { held?.close() } }
    func inspect() async throws -> SFTPInPlaceJournalDocument {
        let (value, late) = try await executor.perform { [self] in
            if let owner { try owner.validateCurrent(); return owner.snapshot }
            guard let file = try File.open(directory, writing: false) else { return .init() }
            defer { file.close() }; try file.validateCurrent(); return file.snapshot
        }
        guard !late else { throw RemoteSettingsFailure.cancelled }; return value
    }
    func prepare(_ record: SFTPInPlaceRecord, revision: UInt64) async throws {
        let (_, late) = try await executor.perform { [self] in
            guard active == nil, owner == nil else { throw RemoteSettingsFailure.busy }
            // Outermost real metadata pool.lock, then the real journal writer.
            // Two durable, DIFFERENT body IDs must belong to this exact owner.
            let budget = try SFTPSharedBudgetTransaction.open(layout: layout, writing: false); defer { budget.close() }
            let context = try SFTPSharedBudgetTransaction.contextDigest(record.context)
            guard let metadata = budget.document.metadata.first(where: { $0.kind == .original && $0.phase == .live && $0.session == record.session && $0.context == context }),
                  record.baseline.id != record.edited.id,
                  [record.baseline.id, record.edited.id].allSatisfy({ id in budget.document.bodies.contains { $0.id == id && $0.owner == metadata.id && $0.phase == .allocated } }) else { throw SFTPSharedBudgetFailure.stale }
            try record.validate(); guard record.outcome == .prepared else { throw RemoteSettingsFailure.invalidRecord }
            owner = try File.open(directory, writing: true, probe: probe)
            do {
                try mutate(revision: revision) { next in
                    guard next.records.count < 64, !next.records.contains(where: { $0.id == record.id }) else { throw RemoteSettingsFailure.capacity }
                    next.records.append(record)
                }
                active = record.id
            } catch { owner?.close(); owner = nil; throw error }
        }
        if late { throw RemoteSettingsFailure.cancelled }
    }
    func requestOnSessionExecutor(_ id: UUID, step: SFTPInPlaceStep) throws {
        try executor.synchronously { [self] in try update(id) { record in
            let expected = try record.plan
            guard record.requested == record.acknowledged, record.requested.count < expected.count,
                  expected[record.requested.count] == step else { throw RemoteSettingsFailure.invalidRecord }
            record.requested.append(step); record.outcome = .inProgress
        } }
    }
    func observeOnSessionExecutor(_ id: UUID, step: SFTPInPlaceStep) throws {
        try executor.synchronously { [self] in try update(id) { record in
            guard record.requested.count == record.acknowledged.count + 1, record.requested.last == step else { throw RemoteSettingsFailure.invalidRecord }
            record.acknowledged.append(step)
        } }
    }
    func finishOnSessionExecutor(_ id: UUID) throws {
        try executor.synchronously { [self] in try update(id) { record in
            guard record.requested == (try record.plan), record.acknowledged == record.requested else { throw RemoteSettingsFailure.invalidRecord }; record.outcome = .verified
        } }
    }
    func interruptionOnSessionExecutor(_ id: UUID, requested: UInt64, acknowledged: UInt64) throws -> (requested: Int, acknowledged: Int, mutates: Bool) {
        try executor.synchronously { [self] in
            guard active == id, let owner else { throw RemoteSettingsFailure.busy }; try owner.validateCurrent()
            guard let record = owner.snapshot.records.first(where: { $0.id == id }), acknowledged <= requested,
                  acknowledged == UInt64(record.acknowledged.count), requested <= UInt64(record.requested.count),
                  UInt64(record.requested.count) <= requested + 1 else { throw RemoteSettingsFailure.invalidRecord }
            return (record.requested.count, record.acknowledged.count, record.mutationMayHaveHappened)
        }
    }
    func endAfterActualDrain(_ id: UUID) async {
        await executor.drain { [self] in
            defer { if active == id { active = nil; owner?.close(); owner = nil } }
            guard active == id else { return }
            try? update(id) { record in if record.outcome != .verified { record.outcome = record.mutationMayHaveHappened ? .recoveryRequired : .notStarted } }
        }
    }
    private func update(_ id: UUID, change: (inout SFTPInPlaceRecord) throws -> Void) throws {
        guard active == id, let owner else { throw RemoteSettingsFailure.busy }
        try mutate(revision: owner.snapshot.revision) { next in
            guard let index = next.records.firstIndex(where: { $0.id == id }) else { throw RemoteSettingsFailure.missing }; try change(&next.records[index])
        }
    }
    private func mutate(revision: UInt64, change: (inout SFTPInPlaceJournalDocument) throws -> Void) throws {
        let workspace = try layout.storage.beginWorkspaceTransaction(); defer { workspace?.close() }
        guard let owner else { throw RemoteSettingsFailure.notOpen }; try owner.validateCurrent()
        guard owner.snapshot.revision == revision, revision < UInt64.max else { throw RemoteSettingsFailure.staleRevision }
        var next = owner.snapshot; try change(&next); next.revision += 1; _ = try next.encoded()
        try workspace?.validateCurrent(); try owner.commit(next)
        try SFTPSharedBudgetTransaction.validateMetadataFootprint(layout)
    }
}
