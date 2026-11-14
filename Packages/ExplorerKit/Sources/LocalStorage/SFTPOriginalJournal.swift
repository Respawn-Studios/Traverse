import CoreFoundation
import CryptoKit
import Foundation

enum SFTPOriginalEdge: UInt8, Codable, CaseIterable, Sendable {
    case container = 1, stage, linkCheck, preserve, publish, restore
    var bit: UInt8 { 1 << (rawValue - 1) }
    var predecessor: SFTPOriginalEdge? {
        switch self { case .container, .restore: nil; case .stage: .container; case .linkCheck: .stage; case .preserve: .linkCheck; case .publish: .preserve }
    }
}
enum SFTPOriginalOutcome: String, Codable, Sendable {
    case prepared, staging, previousObserved, publicationRequested, verified
    case notStarted, reviewStage, reviewOriginalMove, reviewPublication, restoredAliasRetained
}
struct SFTPOriginalContext: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    let host: SFTPHostIdentity, account: String, keyDigest: Data, routeDigest: Data?
    var debugDescription: String { "<SFTP original context>" }
    init(_ context: SFTPVerifiedSessionContext) throws {
        host = try SFTPHostIdentity(canonicalHost: context.host, port: context.port, interfaceScope: context.requestedScopeID)
        account = context.account; keyDigest = Data(SHA256.hash(data: context.key.bytes)); routeDigest = context.routeKeyBinding
    }
    func validate() throws {
        try host.validate()
        guard !account.isEmpty, account.utf8.count <= 256,
              !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              keyDigest.count == 32, routeDigest == nil || routeDigest?.count == 32 else { throw RemoteSettingsFailure.invalidRecord }
    }
}
struct SFTPOriginalSpoolReference: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    let id: UUID, logicalBytes: UInt64, digest: Data
    var debugDescription: String { "<SFTP original checked spool reference>" }
    func validate() throws {
        guard SFTPWire.validToken(id), logicalBytes <= 1 << 20, digest.count == 32 else { throw RemoteSettingsFailure.invalidRecord }
    }
}
struct SFTPOriginalRecord: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    let id: UUID, editorGeneration: UUID, session: UUID, baselineToken: UUID, baselineRevision: UInt64
    let context: SFTPOriginalContext, originalParent: String, originalName: Data
    let baseline: SFTPOriginalSpoolReference, edited: SFTPOriginalSpoolReference
    let uid: UInt32, gid: UInt32, mode: UInt32
    var requested: UInt8 = 0, acknowledged: UInt8 = 0
    var sourceVerified = false
    var outcome = SFTPOriginalOutcome.prepared
    var debugDescription: String { "<SFTP original durable record>" }
    var transactionName: String { "Traverse-Recovery-" + id.uuidString.replacingOccurrences(of: "-", with: "") }
    var originalPath: String { (originalParent == "/" ? "" : originalParent) + "/" + String(decoding: originalName, as: UTF8.self) }
    var transactionPath: String { (originalParent == "/" ? "" : originalParent) + "/" + transactionName }
    var rolesDigest: Data {
        var hash = SHA256()
        for value in [originalPath, transactionPath, transactionPath + "/candidate", transactionPath + "/link-check", transactionPath + "/previous"] {
            var size = UInt32(value.utf8.count).bigEndian
            withUnsafeBytes(of: &size) { hash.update(data: Data($0)) }; hash.update(data: Data(value.utf8))
        }
        return Data(hash.finalize())
    }
    func validate() throws {
        try context.validate(); try baseline.validate(); try edited.validate()
        guard [id, editorGeneration, session, baselineToken].allSatisfy(SFTPWire.validToken), baselineRevision > 0,
              originalParent.hasPrefix("/"), originalParent.utf8.count <= 8192,
              originalParent == "/" || !originalParent.hasSuffix("/") && originalParent.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !originalParent.utf8.contains(0), originalParent.split(separator: "/").count <= 126,
              !originalName.isEmpty, originalName.count <= 255,
              (try? SFTPRemoteName(originalName)) != nil, originalPath.utf8.count <= 8192,
              (transactionPath + "/candidate").utf8.count <= 8192,
              mode & 0o170000 == 0o100000, mode & 0o7000 == 0,
              requested & ~0x3f == 0, acknowledged & ~requested == 0 else { throw RemoteSettingsFailure.invalidRecord }
        // Named mutation facts form a closed ordered prefix. Restore is a
        // separately reviewed future action, never an automatic rollback edge.
        guard requested & SFTPOriginalEdge.restore.bit == 0,
              acknowledged & SFTPOriginalEdge.restore.bit == 0 else { throw RemoteSettingsFailure.invalidRecord }
        for edge in SFTPOriginalEdge.allCases where edge != .container && edge != .restore && requested & edge.bit != 0 {
            guard let preceding = edge.predecessor, acknowledged & preceding.bit != 0 else { throw RemoteSettingsFailure.invalidRecord }
        }
        if requested & SFTPOriginalEdge.linkCheck.bit != 0 { guard sourceVerified else { throw RemoteSettingsFailure.invalidRecord } }
        if outcome == .verified {
            guard requested == 0x1f, acknowledged == 0x1f, sourceVerified else { throw RemoteSettingsFailure.invalidRecord }
        }
        if sourceVerified { guard acknowledged & SFTPOriginalEdge.stage.bit != 0 else { throw RemoteSettingsFailure.invalidRecord } }
        switch outcome {
        case .prepared, .notStarted:
            guard requested == 0, acknowledged == 0, !sourceVerified else { throw RemoteSettingsFailure.invalidRecord }
        case .staging:
            guard requested != 0, requested & SFTPOriginalEdge.publish.bit == 0 else { throw RemoteSettingsFailure.invalidRecord }
        case .previousObserved:
            guard acknowledged & SFTPOriginalEdge.preserve.bit != 0 else { throw RemoteSettingsFailure.invalidRecord }
        case .publicationRequested, .reviewPublication:
            guard requested & SFTPOriginalEdge.publish.bit != 0 else { throw RemoteSettingsFailure.invalidRecord }
        case .reviewOriginalMove:
            guard requested & SFTPOriginalEdge.preserve.bit != 0, requested & SFTPOriginalEdge.publish.bit == 0 else { throw RemoteSettingsFailure.invalidRecord }
        case .reviewStage:
            guard requested != 0, requested & (SFTPOriginalEdge.preserve.bit | SFTPOriginalEdge.publish.bit) == 0 else { throw RemoteSettingsFailure.invalidRecord }
        case .verified: break
        case .restoredAliasRetained: throw RemoteSettingsFailure.invalidRecord
        }
    }
}
struct SFTPOriginalJournalDocument: RemoteSettingsDocument, Codable, Sendable {
    var format = 1, protocolIdentity = "sftp-original-save-journal"
    var revision: UInt64 = 0
    var records: [SFTPOriginalRecord] = []
    init() {}
    func encoded() throws -> Data {
        guard format == 1, protocolIdentity == "sftp-original-save-journal", records.count <= 64,
              Set(records.map(\.id)).count == records.count else { throw RemoteSettingsFailure.invalidRecord }
        try records.forEach { try $0.validate() }
        var references: [UUID: SFTPOriginalSpoolReference] = [:]
        var remoteBytes: UInt64 = 0
        for record in records {
            for value in [record.baseline, record.edited] {
                if let prior = references[value.id] { guard prior == value else { throw RemoteSettingsFailure.invalidRecord } }
                else { references[value.id] = value }
            }
            let amount = record.baseline.logicalBytes + record.edited.logicalBytes
            guard remoteBytes <= (128 << 20) - amount else { throw RemoteSettingsFailure.capacity }; remoteBytes += amount
        }
        let localBytes = references.values.reduce(UInt64(0)) { $0 + $1.logicalBytes + (64 << 10) }
        guard localBytes <= 32 << 20 else { throw RemoteSettingsFailure.capacity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= RemoteSettingsFile<Self>.maximumBytes else { throw RemoteSettingsFailure.capacity }; return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let number = object?["format"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw RemoteSettingsFailure.invalidRecord }
            guard number.intValue == 1, object?["protocolIdentity"] as? String == "sftp-original-save-journal" else { throw RemoteSettingsFailure.incompatibleVersion }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard try value.encoded() == bytes else { throw RemoteSettingsFailure.invalidRecord }; return value
        } catch let error as RemoteSettingsFailure { throw error }
        catch { throw RemoteSettingsFailure.invalidRecord }
    }
}

/// New dedicated namespace; the existing saved-server and fresh-upload stores
/// are never opened or migrated. Every mutation uses the actual anchored file.
final class SFTPOriginalJournal: @unchecked Sendable {
    typealias File = RemoteSettingsFile<SFTPOriginalJournalDocument>
    let directory: URL
    private let executor = UploadLocalExecutor(label: "Traverse.SFTP.Original.Journal")
    private let probe: File.Probe?
    private var owner: File?, active = Set<UUID>()
    let sharedLayout: SFTPSharedBudgetLayout?
    init(directory: URL, probe: File.Probe? = nil, sharedLayout: SFTPSharedBudgetLayout? = nil) {
        self.directory = directory; self.probe = probe; self.sharedLayout = sharedLayout
    }
    func matchesBudget(_ layout: SFTPSharedBudgetLayout) -> Bool { sharedLayout == layout && directory == layout.journal }
    deinit { let held = owner; executor.enqueueDrain { held?.close() } }
    func inspect() async throws -> (revision: UInt64, records: [SFTPOriginalRecord], active: Set<UUID>) {
        let (value, late) = try await executor.perform { [self] () throws -> (UInt64, [SFTPOriginalRecord], Set<UUID>) in
            if let owner { try owner.validateCurrent(); return (owner.snapshot.revision, owner.snapshot.records, active) }
            guard let file = try File.open(directory, writing: false) else { return (0, [], []) }
            defer { file.close() }; return (file.snapshot.revision, file.snapshot.records, Set<UUID>())
        }
        guard !late else { throw RemoteSettingsFailure.cancelled }; return value
    }
    func prepare(_ record: SFTPOriginalRecord, revision: UInt64) async throws {
        let (_, late) = try await executor.perform { [self] in
            guard active.isEmpty else { throw RemoteSettingsFailure.busy }
            guard owner == nil, let sharedLayout, sharedLayout.journal == directory else { throw SFTPSharedBudgetFailure.unsafe }
            let budget = try SFTPSharedBudgetTransaction.open(layout: sharedLayout, writing: false)
            defer { budget.close() }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let context = Data(SHA256.hash(data: try encoder.encode(record.context)))
            guard let storageOwner = budget.document.metadata.first(where: {
                $0.kind == .original && $0.phase == .live && $0.session == record.session && $0.context == context
            }), [record.baseline.id, record.edited.id].allSatisfy({ body in
                budget.document.bodies.contains(where: { $0.id == body && $0.owner == storageOwner.id && $0.phase == .allocated })
            }) else { throw SFTPSharedBudgetFailure.stale }
            try record.validate()
            guard record.requested == 0, record.acknowledged == 0, !record.sourceVerified, record.outcome == .prepared else { throw RemoteSettingsFailure.invalidRecord }
            try mutate(revision: revision) { document in
                guard !document.records.contains(where: { $0.id == record.id }), document.records.count < 64 else { throw RemoteSettingsFailure.capacity }
                document.records.append(record)
            }
            active.insert(record.id)
        }
        // A late cancellation is not a fictitious undo of the durable record.
        if late { throw RemoteSettingsFailure.cancelled }
    }
    func verifyStreamOnSessionExecutor(_ id: UUID, digest: Data) throws {
        try executor.synchronously { [self] in try updateActive(id) { record in
            guard record.edited.digest == digest, record.acknowledged & SFTPOriginalEdge.stage.bit != 0 else { throw RemoteSettingsFailure.invalidRecord }
            record.sourceVerified = true
        } }
    }
    func requestEdgeOnSessionExecutor(_ id: UUID, edge: SFTPOriginalEdge, rolesDigest: Data, requested: UInt8, acknowledged: UInt8) throws {
        try executor.synchronously { [self] in try updateActive(id) { record in
            guard edge != .restore, record.rolesDigest == rolesDigest, record.requested == requested,
                  record.acknowledged == acknowledged, record.requested & edge.bit == 0 else { throw RemoteSettingsFailure.invalidRecord }
            if let preceding = edge.predecessor { guard record.acknowledged & preceding.bit != 0 else { throw RemoteSettingsFailure.invalidRecord } }
            if edge == .linkCheck { guard record.sourceVerified else { throw RemoteSettingsFailure.invalidRecord } }
            record.requested |= edge.bit
            record.outcome = edge == .publish ? .publicationRequested : .staging
        } }
    }
    func observeEdgeOnSessionExecutor(_ id: UUID, edge: SFTPOriginalEdge, requested: UInt8, acknowledged: UInt8) throws {
        try executor.synchronously { [self] in try updateActive(id) { record in
            guard edge != .restore, record.requested == requested, record.requested & edge.bit != 0,
                  record.acknowledged & edge.bit == 0, acknowledged == (record.acknowledged | edge.bit) else { throw RemoteSettingsFailure.invalidRecord }
            record.acknowledged = acknowledged
            if edge == .preserve { record.outcome = .previousObserved }
        } }
    }
    func validateInterruptionOnSessionExecutor(_ id: UUID, requested: UInt8, acknowledged: UInt8) throws {
        try executor.synchronously { [self] in
            guard active.contains(id), let owner else { throw RemoteSettingsFailure.busy }; try owner.validateCurrent()
            guard let record = owner.snapshot.records.first(where: { $0.id == id }), requested & ~record.requested == 0,
                  acknowledged & ~requested == 0, record.acknowledged & ~acknowledged == 0 else { throw RemoteSettingsFailure.invalidRecord }
        }
    }
    func finishObservedOnSessionExecutor(_ id: UUID, digest: Data, requested: UInt8, acknowledged: UInt8) throws {
        try executor.synchronously { [self] in try updateActive(id) { record in
            guard record.edited.digest == digest, record.sourceVerified, record.requested == requested,
                  record.acknowledged == acknowledged, requested == 0x1f, acknowledged == 0x1f else { throw RemoteSettingsFailure.invalidRecord }
            record.outcome = .verified
        } }
    }
    func endAfterActualDrain(_ id: UUID) async {
        await executor.drain { [self] in endOnJournalExecutor(id) }
    }
    private func endOnJournalExecutor(_ id: UUID) {
        defer {
            active.remove(id)
            if active.isEmpty { owner?.close(); owner = nil }
        }
        guard active.contains(id) else { return }
        try? updateActive(id) { record in
            if record.outcome == .verified { return }
            if record.requested & SFTPOriginalEdge.publish.bit != 0 { record.outcome = .reviewPublication }
            else if record.requested & SFTPOriginalEdge.preserve.bit != 0 { record.outcome = .reviewOriginalMove }
            else if record.requested != 0 { record.outcome = .reviewStage }
            else { record.outcome = .notStarted }
        }
    }
    func endAfterActualDrainOnSessionExecutor(_ id: UUID) {
        _ = try? executor.synchronously(cleanup: true) { [self] in endOnJournalExecutor(id) }
    }

    func close() async -> Bool {
        let (closed, late) = (try? await executor.perform { [self] in
            guard active.isEmpty else { return false }; owner?.close(); owner = nil; return true
        }) ?? (false, false)
        return closed && !late
    }
    private func updateActive(_ id: UUID, change: (inout SFTPOriginalRecord) throws -> Void) throws {
        guard active.contains(id), let owner else { throw RemoteSettingsFailure.busy }
        try mutate(revision: owner.snapshot.revision) { document in
            guard let index = document.records.firstIndex(where: { $0.id == id }) else { throw RemoteSettingsFailure.missing }
            try change(&document.records[index])
        }
    }
    private func mutate(revision: UInt64, change: (inout SFTPOriginalJournalDocument) throws -> Void) throws {
        guard let sharedLayout, sharedLayout.journal == directory else { throw SFTPSharedBudgetFailure.unsafe }
        if owner == nil { owner = try File.open(directory, writing: true, probe: probe) }
        guard let owner else { throw RemoteSettingsFailure.notOpen }; try owner.validateCurrent()
        guard owner.snapshot.revision == revision, revision < UInt64.max else { throw RemoteSettingsFailure.staleRevision }
        var next = owner.snapshot; try change(&next); next.revision += 1; _ = try next.encoded(); try owner.commit(next)
        try SFTPSharedBudgetTransaction.validateMetadataFootprint(sharedLayout)
    }
}
