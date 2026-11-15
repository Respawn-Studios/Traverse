import Foundation

/// Queue-confined authority for one candidate journal revision. Read snapshots are values;
/// mutations cannot escape without recording their affected ordinal. The store accepts only
/// the exact session it opened, against the last successfully committed encoded rows.
internal final class JournalEditSession {
    private let identity = UUID()
    private var value: JournalRecord
    private(set) var changed: [Set<Int>] = [[], [], [], []]
    private var knownSources: [URL: Int] = [:]
    private var intentSources: [URL: Int] = [:]
    private var unknownIntents = 0
    private var locationSet: Set<URL>
    private var areaIndices: [URL: Int] = [:]
    private(set) var ownedTrashPromotionPending = false

    init(_ record: JournalRecord, new: Bool) {
        value = record
        locationSet = Set(record.locations)
        for (index, area) in record.areas.enumerated() where areaIndices[area.url] == nil { areaIndices[area.url] = index }
        for step in record.steps where step.after != nil { knownSources[step.source, default: 0] += 1 }
        for intent in record.trashIntents {
            intentSources[intent.source, default: 0] += 1
            if knownSources[intent.source, default: 0] == 0 { unknownIntents += 1 }
        }
        if new {
            changed = [Set(record.steps.indices), Set(record.areas.indices),
                       Set(record.locations.indices), Set(record.trashIntents.indices)]
        }
    }

    struct Checkpoint {
        fileprivate let session: UUID
        fileprivate let value: JournalRecord
        fileprivate let changed: [Set<Int>]
        fileprivate let ownedTrashPromotionPending: Bool
    }
    func checkpoint() -> Checkpoint { Checkpoint(session: identity, value: value, changed: changed,
                                               ownedTrashPromotionPending: ownedTrashPromotionPending) }
    /// Native Trash preserves its last explicitly observed candidate even if a later save
    /// fails. A checkpoint cannot cross a commit or be used by another editing session.
    func restore(_ checkpoint: Checkpoint) throws {
        guard checkpoint.session == identity, checkpoint.value.revision == value.revision else {
            throw FileOperationFailure.recoveryUncertain
        }
        value = checkpoint.value; changed = checkpoint.changed
        ownedTrashPromotionPending = checkpoint.ownedTrashPromotionPending
        areaIndices = [:]
        for (index, area) in value.areas.enumerated() where areaIndices[area.url] == nil { areaIndices[area.url] = index }
        locationSet = Set(value.locations); knownSources = [:]; intentSources = [:]; unknownIntents = 0
        for step in value.steps where step.after != nil { knownSources[step.source, default: 0] += 1 }
        for intent in value.trashIntents {
            intentSources[intent.source, default: 0] += 1
            if knownSources[intent.source, default: 0] == 0 { unknownIntents += 1 }
        }
    }

    var snapshot: JournalRecord { value }
    var id: UUID { value.id }
    var revision: Int { value.revision }
    var state: String { value.state }
    var steps: [JournalStep] { value.steps }
    var areas: [JournalArea] { value.areas }
    var locations: [URL] { value.locations }
    var trashIntents: [JournalTrashIntent] { value.trashIntents }
    var nameRename: JournalNameRename? { value.nameRename }
    var downloadAdoption: JournalDownloadAdoption? { value.downloadAdoption }
    var persistentVolumes: PersistentVolumeBindings? { value.persistentVolumes }
    var allTrashKnown: Bool { unknownIntents == 0 }

    /// The original job changes protocol in one SQLite transaction before the
    /// first irreversible syscall. No independent v3/v9 Undo authority survives.
    func promoteOwnedTrashDeletion() throws {
        try OwnedTrashPolicy.committed(value)
        let sourceVersion = value.version
        value.version = sourceVersion == 9 ? 10 : 8
        value.state = "trashDeleteReview"
        for index in value.steps.indices { value.steps[index].ownedTrashDeletion = .retained }
        value.ownedTrash = JournalOwnedTrashHead.counted(value.steps.map { $0.ownedTrashDeletion! },
            sourceVersion: sourceVersion == 9 ? 9 : nil)
        changed[0].formUnion(value.steps.indices)
        ownedTrashPromotionPending = true
    }

    func setOwnedTrashDeletion(_ phase: OwnedTrashEntryState, at index: Int, stage: URL? = nil) throws {
        guard [8, 10].contains(value.version), value.steps.indices.contains(index),
              let current = value.steps[index].ownedTrashDeletion,
              (current == .retained && phase == .deleteIntent && stage != nil)
                || (current == .deleteIntent && (phase == .uncertain || phase == .deleteConfirmed) && stage == nil) else {
            throw FileOperationFailure.recoveryUncertain
        }
        if let stage {
            try appendNewLocations([stage])
            value.steps[index].ownedTrashStageURL = stage
        }
        value.steps[index].ownedTrashDeletion = phase
        value.ownedTrash = JournalOwnedTrashHead.counted(value.steps.compactMap(\.ownedTrashDeletion),
            sourceVersion: value.version == 10 ? 9 : nil)
        value.state = value.ownedTrash?.confirmedCount == value.steps.count ? "trashDeleted" : "trashDeleteReview"
        changed[0].insert(index)
    }

    /// The caller holds and checks the actual parent descriptor. A new job
    /// records this binding in its next SQLite transaction with the intent;
    /// older jobs remain exact-device and never acquire inferred authority.
    func bindPersistentVolume(in parent: DirectoryAnchor) throws {
        guard value.persistentVolumes != nil else { return }
        try bindPersistentVolume(PersistentVolumeBinding.qualified(in: parent))
    }

    func bindPersistentVolume(_ binding: PersistentVolumeBinding?) throws {
        guard value.persistentVolumes != nil else { return }
        try value.persistentVolumes!.insert(binding)
    }

    func matchesPersisted(_ stored: EntrySnapshot, _ current: EntrySnapshot,
                          in parent: DirectoryAnchor) throws -> Bool {
        try value.matchesPersisted(stored, current, in: parent)
    }

    func matchesPersisted(_ stored: VerifiedTree, _ current: VerifiedTree,
                          in parent: DirectoryAnchor) throws -> Bool {
        try value.matchesPersisted(stored, current, in: parent)
    }

    func areaIndex(for url: URL) -> Int? { areaIndices[url] }

    func setState(_ state: String) { value.state = state }
    func setFailureStage(_ stage: String?) { value.failureStage = stage }
    func setNameRenamePhase(_ phase: JournalNameRename.Phase) throws {
        guard [2, 4].contains(value.version), value.nameRename != nil else { throw FileOperationFailure.recoveryUncertain }
        value.nameRename!.phase = phase
    }
    func setDownloadAdoption(_ adoption: JournalDownloadAdoption) throws {
        guard value.version == 7, value.operation == "Download" else { throw FileOperationFailure.recoveryUncertain }
        value.downloadAdoption = adoption
    }

    func appendLocation(_ url: URL) throws { try appendLocations([url]) }
    func appendLocations(_ urls: [URL]) throws {
        guard urls.count <= OperationJournal.maximumLocations - value.locations.count else { throw FileOperationFailure.unsupported }
        let start = value.locations.count
        value.locations.append(contentsOf: urls)
        locationSet.formUnion(urls)
        changed[2].formUnion(start..<value.locations.count)
    }
    /// Match the old `candidates.filter { !locations.contains($0) }` behavior, including
    /// duplicate candidates absent from the existing array. Do not canonicalize URL spelling.
    func appendNewLocations(_ urls: [URL]) throws {
        try appendLocations(urls.filter { !locationSet.contains($0) })
    }
    @discardableResult func appendStep(_ step: JournalStep) throws -> Int {
        guard value.steps.count < OperationJournal.maximumSteps else { throw FileOperationFailure.unsupported }
        let index = value.steps.count
        value.steps.append(step); changed[0].insert(index)
        if step.after != nil { addKnownSource(step.source) }
        return index
    }
    func setStepOutcome(_ after: VerifiedTree, at index: Int) throws {
        guard value.steps.indices.contains(index) else { throw FileOperationFailure.recoveryUncertain }
        if value.steps[index].after == nil { addKnownSource(value.steps[index].source) }
        value.steps[index].after = after; changed[0].insert(index)
    }
    func qualifyRetainedArchiveOriginal() throws {
        guard [13, 18].contains(value.version), value.steps.count == 1,
              value.steps[0].after != nil, !value.steps[0].undone,
              value.steps[0].archiveOriginalRetainedQualified == nil else {
            throw FileOperationFailure.recoveryUncertain
        }
        value.steps[0].archiveOriginalRetainedQualified = true
        changed[0].insert(0)
    }
    func markStepUndone(at index: Int) throws {
        guard value.steps.indices.contains(index) else { throw FileOperationFailure.recoveryUncertain }
        value.steps[index].undone = true; changed[0].insert(index)
    }
    @discardableResult func appendArea(_ area: JournalArea) throws -> Int {
        guard value.areas.count < OperationJournal.maximumAreas else { throw FileOperationFailure.unsupported }
        let index = value.areas.count
        value.areas.append(area); changed[1].insert(index)
        if areaIndices[area.url] == nil { areaIndices[area.url] = index }
        return index
    }
    func setStagingProof(_ proof: JournalStagingProof, at index: Int) throws {
        guard value.areas.indices.contains(index) else { throw FileOperationFailure.recoveryUncertain }
        value.areas[index].stagingProof = proof; changed[1].insert(index)
    }
    func appendTrashIntent(_ intent: JournalTrashIntent) throws {
        guard value.trashIntents.count < OperationJournal.maximumTrashIntents else { throw FileOperationFailure.unsupported }
        changed[3].insert(value.trashIntents.count); value.trashIntents.append(intent)
        intentSources[intent.source, default: 0] += 1
        if knownSources[intent.source, default: 0] == 0 { unknownIntents += 1 }
    }
    private func addKnownSource(_ source: URL) {
        if knownSources[source, default: 0] == 0 { unknownIntents -= intentSources[source, default: 0] }
        knownSources[source, default: 0] += 1
    }
    /// Only the owning store calls this after the transaction and file guards succeed.
    func didCommit() {
        value.revision += 1
        changed = [[], [], [], []]
        ownedTrashPromotionPending = false
    }
}
