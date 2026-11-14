import Darwin
import Foundation
@testable import FileOperations
import Testing

private func waitForPersistentIdentityGate(_ gate: DispatchSemaphore) -> Bool {
    gate.wait(timeout: .now() + 5) == .success
}

/// The previous writer's synthesized Head decoder ignored unknown JSON keys.
/// Its readHead version check is the compatibility boundary for new records.
private struct PriorWriterHeadControl: Codable {
    let version: Int, revision: Int
    let owner: UUID, id: UUID, operation: String, createdAt: Date, state: String
    let failureStage: String?, counts: [Int], allTrashKnown: Bool
    let nameRename: JournalNameRename?

    var passesPriorReadHead: Bool {
        if version == 2 {
            return counts.count == 4 && counts[0] == 0 && counts[1] == 0 && counts[3] == 0 && nameRename != nil
        }
        return version == 1 && nameRename == nil
    }
}

private struct PersistentIdentityFixture {
    let root: URL
    let history: URL
    let destination: URL

    init() throws {
        let base = try FileOperationTestFixtures.base()
        root = base.appendingPathComponent("persistent-identity-" + UUID().uuidString, isDirectory: true)
        history = root.appendingPathComponent("history", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func engine(_ hooks: RecoveryHooks = RecoveryHooks()) -> RecoverableFileOperations {
        RecoverableFileOperations(journalDirectory: history, hooks: hooks)
    }
    func file(_ name: String = "source.txt") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("Generated persistent identity fixture\n".utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    func priorDevice() throws -> (current: dev_t, old: dev_t) {
        let current = try DirectoryAnchor(root, resolve: false).identity.device
        return (current, current == Int32.max ? current - 1 : current + 1)
    }

    func syntheticOldRecord(_ id: UUID, foreignUUID: Bool = false, omitBindings: Bool = false) throws {
        let devices = try priorDevice()
        let journal = try OperationJournal(history)
        let current = try journal.inspectRecord(id)
        var record = try #require(current)
        let encoded = try JSONEncoder().encode(record)
        let raw = try JSONSerialization.jsonObject(with: encoded)
        // Walk the serialized generated record so every stored device relation,
        // including the binding, represents one coherent earlier mount epoch.
        func rebase(_ value: Any) -> Any {
            if var dictionary = value as? [String: Any] {
                for (key, member) in dictionary {
                    if key == "device", let number = member as? NSNumber,
                       number.int32Value == devices.current {
                        dictionary[key] = NSNumber(value: devices.old)
                    } else { dictionary[key] = rebase(member) }
                }
                return dictionary
            }
            if let array = value as? [Any] { return array.map(rebase) }
            return value
        }
        var changed = try #require(rebase(raw) as? [String: Any])
        if omitBindings { changed.removeValue(forKey: "persistentVolumes") }
        if foreignUUID {
            var volumes = try #require(changed["persistentVolumes"] as? [String: Any])
            var entries = try #require(volumes["entries"] as? [[String: Any]])
            #expect(!entries.isEmpty)
            entries[0]["uuid"] = Data(repeating: 0xA5, count: 16).base64EncodedString()
            volumes["entries"] = entries
            changed["persistentVolumes"] = volumes
        }
        record = try JSONDecoder().decode(JournalRecord.self,
                                          from: JSONSerialization.data(withJSONObject: changed))
        try journal.saveSnapshot(&record)
    }
}

@Test func newTreeRecordRefusesBindingRemovalBeforeAnyHistoryRewrite() async throws {
    let fixture = try PersistentIdentityFixture(); defer { fixture.remove() }
    let source = try fixture.file()
    let move = await fixture.engine().perform(.move(sources: [source], destinationDirectory: fixture.destination))
    #expect(move.result.disposition == .succeeded)
    let id = try #require(move.recordID)
    #expect(throws: FileOperationFailure.recoveryUncertain) {
        try fixture.syntheticOldRecord(id, omitBindings: true)
    }
    let unchanged = try OperationJournal(fixture.history).inspectRecord(id)
    #expect(unchanged?.version == 3 && unchanged?.persistentVolumes != nil)
    #expect(await fixture.engine().undo(recordID: id).result.disposition == .succeeded)
    #expect(try Data(contentsOf: source) ==
            Data("Generated persistent identity fixture\n".utf8))
}

@Test func persistentVolumeBindingMatchesSyntheticRemountOnlyOnSameUUID() throws {
    let fixture = try PersistentIdentityFixture(); defer { fixture.remove() }
    let anchor = try DirectoryAnchor(fixture.root, resolve: false)
    let current = anchor.identity
    let observedVolume = try PersistentVolumeBinding.qualified(in: anchor)
    let qualified = try #require(observedVolume)
    let devices = try fixture.priorDevice()
    var bindings = PersistentVolumeBindings()
    try bindings.insert(.init(device: devices.old, uuid: qualified.uuid))
    let encoded = try JSONEncoder().encode(current)
    var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    fields["device"] = NSNumber(value: devices.old)
    let stored = try JSONDecoder().decode(EntrySnapshot.self,
                                          from: JSONSerialization.data(withJSONObject: fields))
    #expect(bindings.matches(stored, current, currentVolume: qualified))
    #expect(bindings.matchesEntireSnapshot(stored, current, currentVolume: qualified))
    #expect(!bindings.matches(stored, current,
                              currentVolume: .init(device: qualified.device, uuid: Data(repeating: 0xA5, count: 16))))
    #expect(!PersistentVolumeBindings().matches(stored, current, currentVolume: qualified))
}

@Test func newOrdinaryRecordVersionsFencePriorHeadDecoderAndMissingBindings() async throws {
    let fixture = try PersistentIdentityFixture(); defer { fixture.remove() }
    let source = try fixture.file()
    let copy = await fixture.engine().perform(.copy(sources: [source], destinationDirectory: fixture.destination))
    #expect(copy.result.disposition == .succeeded)
    let rename = await fixture.engine().perform(.rename(source: source, name: "renamed.txt"))
    #expect(rename.result.disposition == .succeeded)
    let journal = try OperationJournal(fixture.history)
    for (id, version) in [(try #require(copy.recordID), 3), (try #require(rename.recordID), 4)] {
        let loaded = try journal.inspectRecord(id)
        let record = try #require(loaded)
        #expect(record.version == version)
        let encoded = try JSONEncoder().encode(SQLiteJournalStore.Head(record))
        let old = try JSONDecoder().decode(PriorWriterHeadControl.self, from: encoded)
        #expect(!old.passesPriorReadHead)
        let oldEncoding = try JSONEncoder().encode(old)
        let oldFields = try #require(JSONSerialization.jsonObject(with: oldEncoding) as? [String: Any])
        #expect(oldFields["persistentVolumes"] == nil)
        var stripped = record
        stripped.persistentVolumes = nil
        #expect(throws: FileOperationFailure.recoveryUncertain) { try OperationJournal.validateHeader(stripped) }
    }
}

@Test func committedMoveUndoSurvivesSyntheticMountDeviceChangeWithFullAfterImage() async throws {
    let fixture = try PersistentIdentityFixture(); defer { fixture.remove() }
    let source = try fixture.file()
    let move = await fixture.engine().perform(.move(sources: [source], destinationDirectory: fixture.destination))
    #expect(move.result.disposition == .succeeded)
    let id = try #require(move.recordID)
    try fixture.syntheticOldRecord(id)
    let result = await fixture.engine().undo(recordID: id)
    #expect(result.result.disposition == .succeeded)
    #expect(try Data(contentsOf: source) == Data("Generated persistent identity fixture\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("source.txt").path))
}

@Test func copiedPayloadRetainsVersionedProofAcrossSyntheticRemountAndUndo() async throws {
    let fixture = try PersistentIdentityFixture(); defer { fixture.remove() }
    let source = try fixture.file()
    let copy = await fixture.engine().perform(.copy(sources: [source], destinationDirectory: fixture.destination))
    #expect(copy.result.disposition == .succeeded)
    let id = try #require(copy.recordID)
    let recorded: JournalRecord? = try {
        let journal = try OperationJournal(fixture.history)
        return try journal.inspectRecord(id)
    }()
    #expect(recorded?.areas.first?.stagingProof?.version == 2)
    try fixture.syntheticOldRecord(id)
    #expect(await fixture.engine().undo(recordID: id).result.disposition == .succeeded)
    let retention = try await fixture.engine().retentionRecord(recordID: id)
    #expect(retention.canCleanup)
    #expect(try Data(contentsOf: source) == Data("Generated persistent identity fixture\n".utf8))
}

@Test func nativeNameRenameUndoSurvivesSyntheticMountDeviceChangeWithExactEntryProof() async throws {
    let fixture = try PersistentIdentityFixture(); defer { fixture.remove() }
    let source = try fixture.file()
    let rename = await fixture.engine().perform(.rename(source: source, name: "renamed.txt"))
    #expect(rename.result.disposition == .succeeded)
    let id = try #require(rename.recordID)
    let recorded: JournalRecord? = try {
        let journal = try OperationJournal(fixture.history)
        return try journal.inspectRecord(id)
    }()
    #expect(recorded?.version == 4 && recorded?.nameRename != nil)
    try fixture.syntheticOldRecord(id)
    let result = await fixture.engine().undo(recordID: id)
    #expect(result.result.disposition == .succeeded)
    #expect(try Data(contentsOf: source) == Data("Generated persistent identity fixture\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("renamed.txt").path))
}

@Test func syntheticMountDeviceChangeRejectsForeignVolumeAndChangedAfterImage() async throws {
    let foreign = try PersistentIdentityFixture(); defer { foreign.remove() }
    let foreignSource = try foreign.file()
    let first = await foreign.engine().perform(.move(sources: [foreignSource], destinationDirectory: foreign.destination))
    #expect(first.result.disposition == .succeeded)
    let firstID = try #require(first.recordID)
    try foreign.syntheticOldRecord(firstID, foreignUUID: true)
    #expect(await foreign.engine().undo(recordID: firstID).result.disposition == .failed)
    #expect(!FileManager.default.fileExists(atPath: foreignSource.path))

    let changed = try PersistentIdentityFixture(); defer { changed.remove() }
    let changedSource = try changed.file()
    let second = await changed.engine().perform(.move(sources: [changedSource], destinationDirectory: changed.destination))
    #expect(second.result.disposition == .succeeded)
    let secondID = try #require(second.recordID)
    try changed.syntheticOldRecord(secondID)
    let target = changed.destination.appendingPathComponent("source.txt")
    try Data("Changed after publication\n".utf8).write(to: target, options: .atomic)
    #expect(await changed.engine().undo(recordID: secondID).result.disposition == .failed)
    #expect(try Data(contentsOf: target) == Data("Changed after publication\n".utf8))
}

@Test func syntheticMountDeviceChangeDoesNotResolveAnUnacknowledgedRenameIntent() async throws {
    let fixture = try PersistentIdentityFixture(); defer { fixture.remove() }
    let source = try fixture.file()
    let interrupted = await fixture.engine(RecoveryHooks(beforeExclusiveRename: { _, _ in
        throw FileOperationFailure.ioFailure
    })).perform(.move(sources: [source], destinationDirectory: fixture.destination))
    #expect(interrupted.result.disposition == .failed)
    let id = try #require(interrupted.recordID)
    let recorded: JournalRecord? = try {
        let journal = try OperationJournal(fixture.history)
        return try journal.inspectRecord(id)
    }()
    #expect(recorded?.steps.count == 1 && recorded?.steps[0].after == nil)
    try fixture.syntheticOldRecord(id)
    let recovery = await fixture.engine().recover(recordID: id)
    #expect(recovery.result.disposition == .failed)
    #expect(try Data(contentsOf: source) == Data("Generated persistent identity fixture\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("source.txt").path))
}

@Test func newStagingProofKeepsReadOnlyRetentionEligibleAfterSyntheticRemount() async throws {
    let fixture = try PersistentIdentityFixture(); defer { fixture.remove() }
    let source = try fixture.file()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let hooks = RecoveryHooks(beforeCommit: { entered.signal(); release.wait() })
    let operation = fixture.engine(hooks)
    let task = Task { await operation.perform(.copy(sources: [source], destinationDirectory: fixture.destination)) }
    let reached = await Task.detached { waitForPersistentIdentityGate(entered) }.value
    guard reached else {
        task.cancel(); release.signal()
        Issue.record("Generated staging operation never reached its precommit boundary")
        return
    }
    task.cancel(); release.signal()
    let result = await task.value
    let id = try #require(result.recordID)
    let recorded: JournalRecord? = try {
        let journal = try OperationJournal(fixture.history)
        return try journal.inspectRecord(id)
    }()
    #expect(recorded?.areas.first?.stagingProof?.version == 2)
    #expect(recorded?.steps.isEmpty == true)
    try fixture.syntheticOldRecord(id)
    let retention = try await fixture.engine().retentionRecord(recordID: id)
    #expect(retention.canCleanup)
    #expect(try Data(contentsOf: source) == Data("Generated persistent identity fixture\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("source.txt").path))
}
