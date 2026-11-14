import Darwin
import Foundation
import SQLite3
@testable import FileOperations
import Testing

private struct HistoryFixture {
    let root: URL
    let journal: URL
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("history-inspection-" + UUID().uuidString)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager().removeItem(at: root) }
    func create(version: Int = 3, jobs: Int = 2) throws -> [UUID] {
        var ids: [UUID] = []
        do {
            let store = try OperationJournal(journal)
            for i in 0..<jobs {
                var record = JournalRecord(version: 1, owner: store.owner, id: UUID(), operation: "Copy")
                record.state = i == 0 ? "preparing" : "committed"
                try store.saveSnapshot(&record); ids.append(record.id)
            }
            if version == 4 { try store.upgradeForGroupedCopy() }
        }
        if version == 2 { try sql("UPDATE metadata SET value='2' WHERE key='version'; PRAGMA user_version=2") }
        return ids
    }
    func sql(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(journal.appendingPathComponent(SQLiteJournalStore.name).path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else { throw FileOperationFailure.ioFailure }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FileOperationFailure.ioFailure }
    }
    struct Observation: Equatable {
        let root: EntrySnapshot
        let files: [String: Data]
        let identities: [String: EntrySnapshot]
    }
    func observe() throws -> Observation {
        let anchor = try DirectoryAnchor(journal, resolve: false)
        let names = try GroupedCopyFilesystemEvidence.children(in: anchor, cancellation: OperationCancellation(), limit: 32)
        return Observation(root: try EntrySnapshot(fd: anchor.fd),
            files: try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: journal.appendingPathComponent($0))) }),
            identities: try Dictionary(uniqueKeysWithValues: names.map { ($0, try EntrySnapshot(parent: anchor.fd, name: $0)) }))
    }
    func inspect(hooks: OperationHistoryInspectionHooks = .init(), budget: OperationHistoryReadBudget? = nil) throws -> OperationRecoveryInspection {
        try OperationHistoryInspector.inspect(journal, cancellation: OperationCancellation(), hooks: hooks, budget: budget)
    }
}

@Test func historyInspectionMissingRootNeverCreatesHistory() async throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    let service = RecoverableFileOperations(journalDirectory: fixture.journal)
    let result = try await service.inspectExistingHistory()
    #expect(result.readiness == .absent)
    #expect(result.records.isEmpty && result.unfinishedCountIsComplete)
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.root.path).isEmpty)
}

@Test func historyInspectionExplicitPreparationReportsTheActualCatalogAndIncompleteCounts() async throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    _ = try fixture.create(version: 4)
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal)
    let available = try await engine.recoveryRecords()
    #expect(available.readiness == .available(catalogVersion: 4))
    #expect(available.unfinishedCount == 1 && available.unfinishedCountIsComplete)
    let database = fixture.journal.appendingPathComponent(SQLiteJournalStore.name)
    try Data("Generated invalid SQLite file".utf8).write(to: database)
    let unavailable = try await engine.recoveryRecords()
    #expect(unavailable.readiness == .unavailable && !unavailable.unfinishedCountIsComplete)
    #expect(!unavailable.refusedEntries.isEmpty)
}

/// Invoked only by the bounded fresh-process runner. Its fixtures/evidence stay
/// retained; ordinary unit runs do not exercise this process-crash qualification.
@Test func historyInspectionProcessQualificationWorker() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let raw = environment["MAC_EXPLORER_HISTORY_PROCESS_ROOT"],
          let phase = environment["MAC_EXPLORER_HISTORY_PROCESS_PHASE"],
          let version = environment["MAC_EXPLORER_HISTORY_PROCESS_VERSION"].flatMap(Int.init) else { return }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let allowed = package.appendingPathComponent(".build/test-fixtures", isDirectory: true).standardizedFileURL
    let root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    guard root.deletingLastPathComponent() == allowed,
          root.lastPathComponent.hasPrefix("history-process-"),
          UUID(uuidString: String(root.lastPathComponent.dropFirst(16))) != nil,
          [2, 3, 4].contains(version), ["seed", "crash", "activateBefore", "activateAfter", "inspect1", "inspect2", "recover", "cold"].contains(phase) else {
        throw FileOperationFailure.invalidRequest
    }
    let marker = Data("MacExplorer generated history process fixture v1\n\(root.lastPathComponent)\n".utf8)
    let journal = root.appendingPathComponent("journal", isDirectory: true)
    @Sendable func emit(_ value: [String: String]) throws {
        try OperationJournal.writeExclusive(try JSONEncoder().encode(value), name: phase + ".json", anchor: DirectoryAnchor(root, resolve: false))
    }
    if phase == "seed" {
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try OperationJournal.writeExclusive(marker, name: ".history-process-owner", anchor: DirectoryAnchor(root, resolve: false))
        do {
            let store = try OperationJournal(journal)
            if version == 4 { try store.upgradeForGroupedCopy() }
        }
        if version == 2 {
            var db: OpaquePointer?
            guard sqlite3_open_v2(journal.appendingPathComponent(SQLiteJournalStore.name).path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                throw FileOperationFailure.ioFailure
            }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db, "UPDATE metadata SET value='2' WHERE key='version'; PRAGMA user_version=2", nil, nil, nil) == SQLITE_OK else {
                throw FileOperationFailure.ioFailure
            }
        }
        try emit(["phase": phase, "pid": String(getpid()), "version": String(version)])
        return
    }
    let rootAnchor = try DirectoryAnchor(root, resolve: false)
    guard try OperationJournal.read(name: ".history-process-owner", anchor: rootAnchor) == marker else { throw FileOperationFailure.invalidRequest }
    let activation = environment["MAC_EXPLORER_HISTORY_PROCESS_ACTIVATION"]
    if ["activateBefore", "activateAfter"].contains(phase) {
        guard version == 3, activation == (phase == "activateBefore" ? "before" : "after"),
              let native = try NativeRenameVolume.qualified(in: rootAnchor) else { throw FileOperationFailure.invalidRequest }
        let id = native.uuid.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        let scope = try #require(QualifiedCopyPreviewScope(volumes: [id, UUID()], historyVolume: id))
        let stop: @Sendable () throws -> Void = {
            try emit(["phase": phase, "pid": String(getpid()), "activationBoundary": phase, "terminationCode": "86"])
            _exit(86)
        }
        var hooks = RecoveryHooks()
        if phase == "activateBefore" { hooks.journalHooks.beforeCatalogUpgradeCommit = stop }
        else { hooks.journalHooks.afterCatalogUpgradeCommit = stop }
        let engine = RecoverableFileOperations(journalDirectory: journal, hooks: hooks, qualifiedCopyPreview: scope)
        _ = await engine.activateCopyPreview(review: { _ in true }, persist: { receipt in
            if let receipt {
                try OperationJournal.writeExclusive(try JSONEncoder().encode(receipt), name: "unexpected-preference.json",
                    anchor: DirectoryAnchor(root, resolve: false))
            }
        })
        Issue.record("Activation did not reach its selected process boundary")
        return
    }
    if phase == "crash" {
        var db: OpaquePointer?
        guard sqlite3_open_v2(journal.appendingPathComponent(SQLiteJournalStore.name).path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else { throw FileOperationFailure.ioFailure }
        // Force real rollback-journal spill, then exit with the transaction open.
        let sql = "PRAGMA synchronous=EXTRA; PRAGMA fullfsync=ON; PRAGMA cache_size=1; BEGIN IMMEDIATE; UPDATE metadata SET value=zeroblob(262144) WHERE key='owner'"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sqlite3_db_cacheflush(db) == SQLITE_OK else { throw FileOperationFailure.ioFailure }
        let header = try Data(contentsOf: journal.appendingPathComponent(SQLiteJournalStore.name + "-journal")).prefix(8)
        guard Array(header) == [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7] else { throw FileOperationFailure.recoveryUncertain }
        try emit(["phase": phase, "pid": String(getpid()), "realHotHeader": "true", "terminationCode": "86"])
        _exit(86)
    }
    let engine = RecoverableFileOperations(journalDirectory: journal)
    if phase == "recover" {
        let result = try await engine.recoveryRecords()
        #expect(result.refusedEntries.isEmpty)
        try emit(["phase": phase, "pid": String(getpid()), "explicitRecovery": "true"])
        return
    }
    func bytes() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager().contentsOfDirectory(atPath: journal.path).map {
            ($0, try Data(contentsOf: journal.appendingPathComponent($0)))
        })
    }
    let before = try bytes()
    let result = try await engine.inspectExistingHistory()
    if phase == "cold" { #expect(result.readiness == .available(catalogVersion: version == 4 || activation == "after" ? 4 : 3)) }
    else if activation == "after" { #expect(result.readiness == .available(catalogVersion: 4)) }
    else if activation == "before" { #expect(result.readiness == .available(catalogVersion: 3) || result.readiness == .recoveryRequired) }
    else { #expect(result.readiness == .recoveryRequired) }
    #expect(try bytes() == before)
    #expect(!engine.isCopyPreviewEnabled && !FileManager().fileExists(atPath: root.appendingPathComponent("unexpected-preference.json").path))
    try emit(["phase": phase, "pid": String(getpid()), "unchanged": "true", "privateAuthority": "false",
        "unexpectedPreference": "false", "readiness": String(describing: result.readiness)])
}

@Test(arguments: [2, 3, 4]) func historyInspectionReadsSchemasWithoutUpgrade(version: Int) async throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    let ids = try fixture.create(version: version)
    let before = try fixture.observe()
    let result = try await RecoverableFileOperations(journalDirectory: fixture.journal).inspectExistingHistory()
    #expect(result.readiness == .available(catalogVersion: version))
    #expect(Set(result.records.map(\.id)) == Set(ids))
    #expect(result.unfinishedCount == 1 && result.unfinishedCountIsComplete)
    #expect(try fixture.observe() == before)
}

@Test func historyInspectionLegacyOnlyPreservesItWithoutImport() throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    try FileManager().createDirectory(at: fixture.journal, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let anchor = try DirectoryAnchor(fixture.journal, resolve: false), owner = UUID()
    try OperationJournal.writeExclusive(Data(owner.uuidString.utf8), name: ".mac-explorer-journal-v1", anchor: anchor)
    let record = JournalRecord(version: 1, owner: owner, id: UUID(), operation: "Copy")
    try OperationJournal.writeExclusive(try JSONEncoder().encode(record), name: record.id.uuidString + "-000000.json", anchor: anchor)
    let before = try fixture.observe(), result = try fixture.inspect()
    #expect(result.readiness == .legacyImportRequired && result.legacyArchivesPresent)
    #expect(!result.unfinishedCountIsComplete)
    #expect(try fixture.observe() == before)
}

@Test func historyInspectionExistingLegacyArchivesDoNotTriggerImport() throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    _ = try fixture.create()
    let anchor = try DirectoryAnchor(fixture.journal, resolve: false)
    try OperationJournal.writeExclusive(Data("preserved generated archive".utf8), name: UUID().uuidString + "-000000.json", anchor: anchor)
    let before = try fixture.observe(), result = try fixture.inspect()
    #expect(result.readiness == .available(catalogVersion: 3))
    #expect(result.legacyArchivesPresent && result.records.count == 2)
    #expect(try fixture.observe() == before)
}

@Test func historyInspectionDoesNotFinishPartialInitialization() throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    _ = try fixture.create()
    try FileManager().removeItem(at: fixture.journal.appendingPathComponent(".mac-explorer-sqlite-ready-v2"))
    let before = try fixture.observe(), result = try fixture.inspect()
    #expect(result.readiness == .initializationIncomplete)
    #expect(try fixture.observe() == before)
}

@Test func historyInspectionForeignWriterLockIsBusyAndUnchanged() throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    _ = try fixture.create()
    let writer = try OperationJournal(fixture.journal)
    let before = try fixture.observe(), result = try fixture.inspect()
    #expect(result.readiness == .busy)
    #expect(!result.unfinishedCountIsComplete)
    #expect(try fixture.observe() == before)
    withExtendedLifetime(writer) {}
}

@Test(arguments: [false, true]) func historyInspectionInactiveAndHotHeadersNeverChangeFiles(hot: Bool) throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    _ = try fixture.create()
    let anchor = try DirectoryAnchor(fixture.journal, resolve: false)
    let header: [UInt8] = hot ? [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7] : [UInt8](repeating: 0, count: 8)
    try OperationJournal.writeExclusive(Data(header), name: SQLiteJournalStore.name + "-journal", anchor: anchor)
    let before = try fixture.observe(), result = try fixture.inspect()
    #expect(result.readiness == (hot ? .recoveryRequired : .available(catalogVersion: 3)))
    #expect(try fixture.observe() == before)
}

@Test func historyInspectionWALHeaderRefusesBeforeSidecarsCanBeCreated() throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    _ = try fixture.create()
    let database = fixture.journal.appendingPathComponent(SQLiteJournalStore.name)
    let fd = open(database.path, O_WRONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
    let bytes: [UInt8] = [2, 2]
    #expect(pwrite(fd, bytes, bytes.count, 18) == 2)
    let before = try fixture.observe(), result = try fixture.inspect()
    #expect(result.readiness == .unavailable)
    #expect(try fixture.observe() == before)
}

@Test func historyInspectionReplacementRejectsStaleResult() throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    _ = try fixture.create()
    let path = fixture.journal.appendingPathComponent(SQLiteJournalStore.name)
    var hooks = OperationHistoryInspectionHooks()
    hooks.beforeFinalValidation = {
        let data = try Data(contentsOf: path)
        try FileManager().moveItem(at: path, to: fixture.root.appendingPathComponent("original.sqlite"))
        try data.write(to: path, options: .withoutOverwriting)
        try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    let result = try fixture.inspect(hooks: hooks)
    #expect(result.readiness == .changed && result.records.isEmpty)
    #expect(FileManager().fileExists(atPath: fixture.root.appendingPathComponent("original.sqlite").path))
}

@Test func historyInspectionDeadlinePreservesHistory() throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    _ = try fixture.create()
    let before = try fixture.observe()
    let budget = OperationHistoryReadBudget(cancellation: OperationCancellation(), seconds: 0)
    let result = try fixture.inspect(budget: budget)
    #expect(result.readiness == .inspectionLimited && !result.unfinishedCountIsComplete)
    #expect(try fixture.observe() == before)
}

@Test func historyInspectionCancellationCreatesNothing() throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    let cancellation = OperationCancellation(); cancellation.cancel()
    #expect(throws: CancellationError.self) {
        try OperationHistoryInspector.inspect(fixture.journal, cancellation: cancellation)
    }
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
}

@Test func historyInspectionConnectionRejectsAccidentalUpgradeAndCompaction() throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    _ = try fixture.create(jobs: 0)
    let anchor = try DirectoryAnchor(fixture.journal, resolve: false)
    let bytes = try OperationJournal.read(name: ".mac-explorer-journal-v1", anchor: anchor)
    let owner = try #require(String(data: bytes, encoding: .utf8).flatMap(UUID.init(uuidString:)))
    let store = try SQLiteJournalStore(readOnly: anchor, owner: owner,
        budget: OperationHistoryReadBudget(cancellation: OperationCancellation()))
    let before = try fixture.observe()
    #expect(throws: FileOperationFailure.invalidRequest) {
        try store.upgradeForGroupedCopy(cancellation: OperationCancellation())
    }
    #expect(throws: FileOperationFailure.invalidRequest) {
        _ = try store.maintenance(compact: true, cancellation: OperationCancellation())
    }
    #expect(try fixture.observe() == before)
}

@Test func historyInspectionEntryLimitIsReportedWithoutCallingHistoryCorrupt() throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    _ = try fixture.create()
    let before = try fixture.observe()
    let result = try OperationHistoryInspector.inspect(fixture.journal,
        cancellation: OperationCancellation(), maximumEntries: 2)
    #expect(result.readiness == .inspectionLimited && !result.unfinishedCountIsComplete)
    #expect(try fixture.observe() == before)
}

@Test func historyInspectionHookCancellationPropagatesAndPreservesHistory() throws {
    let fixture = try HistoryFixture(); defer { fixture.remove() }
    _ = try fixture.create()
    let before = try fixture.observe()
    var hooks = OperationHistoryInspectionHooks()
    hooks.beforeStoreOpen = { throw CancellationError() }
    #expect(throws: CancellationError.self) { try fixture.inspect(hooks: hooks) }
    #expect(try fixture.observe() == before)
}
