import CryptoKit
import Darwin
import Foundation

/// Private canonical identities, not caller-supplied paths or lookup keys.
struct SFTPRetainedDiskIdentity: Codable, Equatable, Sendable {
    let device: Int64, inode: UInt64, birth: Int, nanos: Int
    init(device: Int64, inode: UInt64, birth: Int, nanos: Int) {
        self.device = device; self.inode = inode; self.birth = birth; self.nanos = nanos
    }
    init(_ value: DownloadDisk.Identity) {
        device = Int64(value.device); inode = UInt64(value.inode)
        birth = value.birthSeconds; nanos = value.birthNanos
    }
    func matches(_ value: DownloadDisk.Identity) -> Bool { self == Self(value) }
}
struct SFTPRetainedBodyIntent: Codable, Equatable, Sendable {
    let reference: SFTPOriginalSpoolReference
    let folder: SFTPRetainedDiskIdentity, files: [String: SFTPRetainedDiskIdentity], marker: Data
    init(_ reference: SFTPOriginalSpoolReference, record: DownloadDisk.Record) {
        self.reference = reference; folder = .init(record.folder)
        files = record.files.mapValues(SFTPRetainedDiskIdentity.init); marker = record.marker
    }
    func validate(budget: UUID, owner: UUID) throws {
        try reference.validate()
        guard folder.inode > 0, (0...999999999).contains(folder.nanos),
              files.values.allSatisfy({ $0.inode > 0 && (0...999999999).contains($0.nanos) }),
              Set(files.keys) == Set(["payload", "owner.lock", "session.meta"]), marker.count <= 2048 else { throw SFTPSharedBudgetFailure.unsafe }
        let value = try JSONDecoder().decode(DownloadDisk.Marker.self, from: marker)
        guard try DownloadDisk.encodedMarker(value) == marker, value.version == 3,
              value.id == reference.id, value.expectedBytes == reference.logicalBytes,
              value.originalBudget == budget, value.originalOwner == owner else { throw SFTPSharedBudgetFailure.stale }
    }
}
enum SFTPRetainedRetirementStage: String, Codable, Equatable, Sendable {
    case deleting, retiringHistory, retiringEditor, releasingCharges
}
struct SFTPRetainedJournalDigest: Codable, Equatable, Sendable { let id: UUID, digest: Data }
struct SFTPRetainedRetirementIntent: Codable, Equatable, Sendable {
    let editor: SFTPOriginalEditorRecord, owner: UUID, budget: UUID
    let metadataDirectory: SFTPRetainedDiskIdentity?, metadataFiles: [String: SFTPRetainedDiskIdentity]?
    let saves: [SFTPRetainedJournalDigest], bodies: [SFTPRetainedBodyIntent]
    var stage = SFTPRetainedRetirementStage.deleting
    static func digest(_ record: SFTPInPlaceRecord) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(SHA256.hash(data: try encoder.encode(record)))
    }
    static func validateAll(_ intents: [Self], document: SFTPSharedBudgetDocument) throws {
        guard intents.count <= 8, Set(intents.map { $0.editor.id }).count == intents.count else { throw SFTPSharedBudgetFailure.unsafe }
        var bodyIDs = Set<UUID>()
        for intent in intents {
            try intent.editor.validate()
            guard intent.budget == document.budgetID, !intent.bodies.isEmpty, intent.bodies.count <= 8,
                  intent.saves.count <= 64, Set(intent.saves.map(\.id)) == Set(intent.editor.journals),
                  Set(intent.saves.map(\.id)).count == intent.saves.count,
                  intent.saves.allSatisfy({ SFTPWire.validToken($0.id) && $0.digest.count == 32 }),
                  let metadata = document.metadata.first(where: { $0.id == intent.owner }), metadata.kind == .original,
                  metadata.session == intent.editor.session,
                  try SFTPSharedBudgetTransaction.contextDigest(intent.editor.context) == metadata.context,
                  (metadata.phase == .removed ? intent.metadataDirectory == nil && intent.metadataFiles == nil
                    : intent.metadataDirectory != nil && intent.metadataFiles != nil) else { throw SFTPSharedBudgetFailure.unsafe }
            if let folder = intent.metadataDirectory, let files = intent.metadataFiles {
                guard folder.inode > 0, folder.birth == 0, folder.nanos == 0,
                      Set(files.keys) == Set(["catalog.sqlite", "owner.lock", "session.meta"]),
                      files.values.allSatisfy({ $0.inode > 0 && $0.birth == 0 && $0.nanos == 0 }) else { throw SFTPSharedBudgetFailure.unsafe }
            }
            let refs = intent.editor.recovery + (intent.editor.body.map { [$0] } ?? [])
            guard Set(refs.map(\.id)) == Set(intent.bodies.map { $0.reference.id }) else { throw SFTPSharedBudgetFailure.referenced }
            for body in intent.bodies {
                try body.validate(budget: intent.budget, owner: intent.owner)
                guard bodyIDs.insert(body.reference.id).inserted, refs.contains(body.reference),
                      let charge = document.bodies.first(where: { $0.id == body.reference.id }), charge.owner == intent.owner,
                      charge.expectedBytes == body.reference.logicalBytes, charge.phase == .removalPending else { throw SFTPSharedBudgetFailure.referenced }
            }
        }
    }
    func validateMetadataOwner(pool: Int32, document: SFTPSharedBudgetDocument, heldLease: Int32? = nil) throws {
        guard let charge = document.metadata.first(where: { $0.id == owner }) else { throw SFTPSharedBudgetFailure.stale }
        let name = "session-" + owner.uuidString
        if charge.phase == .removed {
            var facts = stat(); errno = 0
            guard metadataDirectory == nil, metadataFiles == nil,
                  fstatat(pool, name, &facts, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT else { throw SFTPSharedBudgetFailure.stale }
        } else {
            let record = try SMBCatalogFiles.record(pool, name: name, heldLease: heldLease)
            guard heldLease != nil || !record.summary.active,
                  record.files["catalog.sqlite-journal"] == nil,
                  SFTPRetainedDiskIdentity.metadata(record.directory) == metadataDirectory,
                  record.files.mapValues(SFTPRetainedDiskIdentity.metadata) == metadataFiles else { throw SFTPSharedBudgetFailure.stale }
        }
    }
    func validateGraph(editors: SFTPOriginalEditorCatalogDocument, journal: SFTPInPlaceJournalDocument?) throws {
        guard let actual = editors.records.first(where: { $0.id == editor.id }) else { throw SFTPSharedBudgetFailure.stale }
        var closed = editor; closed.body = nil; closed.bodyID = nil; closed.recovery = []; closed.journals = []; closed.phase = .closedUnused
        switch stage {
        case .deleting, .retiringHistory: guard actual == editor else { throw SFTPSharedBudgetFailure.stale }
        case .retiringEditor: guard actual == editor || actual == closed else { throw SFTPSharedBudgetFailure.stale }
        case .releasingCharges: guard actual == closed else { throw SFTPSharedBudgetFailure.stale }
        }
        let present = (journal?.records ?? []).filter { editor.journals.contains($0.id) }
        guard present.allSatisfy({ $0.session == editor.session && $0.context == editor.context && $0.path == editor.path
            && editor.recovery.contains($0.baseline) && editor.recovery.contains($0.edited) }) else { throw SFTPSharedBudgetFailure.referenced }
        let expected = try present.map { SFTPRetainedJournalDigest(id: $0.id, digest: try Self.digest($0)) }
        let complete = Set(expected.map(\.id)) == Set(saves.map(\.id)) && expected.allSatisfy(saves.contains)
        switch stage {
        case .deleting: guard complete else { throw SFTPSharedBudgetFailure.referenced }
        case .retiringHistory: guard complete || present.isEmpty else { throw SFTPSharedBudgetFailure.referenced }
        case .retiringEditor, .releasingCharges: guard present.isEmpty else { throw SFTPSharedBudgetFailure.referenced }
        }
        let ids = Set(bodies.map { $0.reference.id })
        guard !editors.records.contains(where: { $0.id != editor.id &&
            (!ids.isDisjoint(with: $0.recovery.map(\.id)) || $0.bodyID.map(ids.contains) == true) }),
              !(journal?.records ?? []).contains(where: { !editor.journals.contains($0.id) &&
                (ids.contains($0.baseline.id) || ids.contains($0.edited.id)) }) else { throw SFTPSharedBudgetFailure.referenced }
    }
}

@_spi(Qualification) public final class SFTPRetainedDocumentChoice: Sendable, CustomDebugStringConvertible {
    public let presentation: SFTPInPlaceRecoveryPresentation, copyCount: Int, removalPending: Bool
    let layout: SFTPSharedBudgetLayout, editor: SFTPOriginalEditorRecord
    let editorIdentity: RemoteSettingsReadIdentity, journalIdentity: RemoteSettingsReadIdentity?
    let captured: SFTPRetainedRetirementIntent
    let stamp: RemoteSettingsReadIdentity, revision: UInt64, intent: SFTPRetainedRetirementIntent?
    // Only validated catalog discovery in this module can mint a selection.
    fileprivate init(layout: SFTPSharedBudgetLayout, editor: SFTPOriginalEditorRecord,
        stamp: RemoteSettingsReadIdentity, revision: UInt64, intent: SFTPRetainedRetirementIntent?,
        captured: SFTPRetainedRetirementIntent, editorIdentity: RemoteSettingsReadIdentity, journalIdentity: RemoteSettingsReadIdentity?) {
        self.editorIdentity = editorIdentity; self.journalIdentity = journalIdentity; self.captured = captured
        self.layout = layout; self.editor = editor; self.stamp = stamp; self.revision = revision; self.intent = intent
        presentation = .init(editor: editor); removalPending = intent != nil
        copyCount = Set(editor.recovery.map(\.id) + (editor.body.map { [$0.id] } ?? [])).count
    }
    public var debugDescription: String { "<opaque whole-document local retirement selection>" }
    static func mint(layout: SFTPSharedBudgetLayout, editor: SFTPOriginalEditorRecord,
        stamp: RemoteSettingsReadIdentity, revision: UInt64, intent: SFTPRetainedRetirementIntent?,
        captured: SFTPRetainedRetirementIntent, editorIdentity: RemoteSettingsReadIdentity, journalIdentity: RemoteSettingsReadIdentity?) -> Self {
        .init(layout: layout, editor: editor, stamp: stamp, revision: revision, intent: intent,
            captured: captured, editorIdentity: editorIdentity, journalIdentity: journalIdentity)
    }
}

#if DEBUG
enum SFTPRetainedRemovalStage: String, Equatable, Sendable {
    case beforeBodyExclusive, intentCommitted, payloadUnlinked, leaseUnlinked, markerUnlinked, folderRemoved, directorySynchronized
    case beforeHistory, historyCommitted, beforeEditor, editorCommitted, beforeCharges, chargesCommitted
    case ledgerStagingWritten = "ledger.stagingWritten"
    case ledgerStagingSynchronized = "ledger.stagingSynchronized"
    case ledgerBeforeRename = "ledger.beforeRename"
    case ledgerRenamed = "ledger.renamed"
    case ledgerDirectorySynchronized = "ledger.directorySynchronized"
    case journalStagingWritten = "journal.stagingWritten"
    case journalStagingSynchronized = "journal.stagingSynchronized"
    case journalBeforeRename = "journal.beforeRename"
    case journalRenamed = "journal.renamed"
    case journalDirectorySynchronized = "journal.directorySynchronized"
    case editorStagingWritten = "editor.stagingWritten"
    case editorStagingSynchronized = "editor.stagingSynchronized"
    case editorBeforeRename = "editor.beforeRename"
    case editorRenamed = "editor.renamed"
    case editorDirectorySynchronized = "editor.directorySynchronized"
}
final class SFTPRetainedRemovalQualification: @unchecked Sendable {
    static let shared = SFTPRetainedRemovalQualification()
    private let lock = NSLock(); private var callback: (@Sendable (SFTPRetainedRemovalStage) throws -> Void)?
    func set(_ callback: (@Sendable (SFTPRetainedRemovalStage) throws -> Void)?) { lock.withLock { self.callback = callback } }
    func metadata(_ kind: String, _ stage: String) throws {
        guard let stage = SFTPRetainedRemovalStage(rawValue: kind + "." + stage) else { throw SFTPSharedBudgetFailure.unsafe }
        try reach(stage)
    }
    func reach(_ stage: SFTPRetainedRemovalStage) throws { let value = lock.withLock { callback }; try value?(stage) }
}
#endif
