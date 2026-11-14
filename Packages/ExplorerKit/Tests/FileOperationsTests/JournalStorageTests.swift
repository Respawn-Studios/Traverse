import Darwin
import Foundation
import SQLite3
@testable import FileOperations
import Testing

@Test func freshCatalog10LocalTextSaveStartsAndCommitsFirstRecord() async throws {
    let base = try FileOperationTestFixtures.base()
    let root = base.appendingPathComponent("fresh-text-record-" + UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("source/Operation Root", isDirectory: true)
    let state = root.appendingPathComponent("portable-state", isDirectory: true)
    let history = state.appendingPathComponent("operation-recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try #require((source as NSURL).appendingPathComponent("Editor.txt"))
    let before = Data("Generated sandbox editor baseline\n".utf8)
    let edited = Data("Generated sandbox editor baseline\nFirst sandbox edit.\n".utf8)
    try before.write(to: file, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

    let engine = RecoverableFileOperations(journalDirectory: history, protecting: [state])
    let opened = try await engine.readLocalTextDocument(at: file)
    #expect(try await engine.inspectExistingHistory().readiness == .absent)
    let upgrade = await engine.upgradeLocalTextHistory()
    #expect(upgrade.status == .succeeded && upgrade.catalogVersion == 10)
    let generation = UUID()
    let plan = try await engine.prepareLocalTextSave(from: opened.token, bytes: edited,
                                                     generation: generation)
    let result = await engine.performLocalTextSave(plan)
    guard case .saved(let receipt) = result else {
        Issue.record("Fresh catalog 10 Save did not commit its first text record")
        return
    }
    #expect(receipt.generation == generation)
    #expect(try Data(contentsOf: file) == edited)
    let recordID = try #require(receipt.recordID)
    #expect(try await engine.inspectLocalTextRevision(recordID: recordID).recordID == recordID)
    let manifest = try OperationJournal(history).textRecordV2(recordID).manifest
    #expect(manifest.area.hasDirectoryPath)
    #expect(manifest.area == manifest.area.standardizedFileURL)
    #expect(manifest.area.deletingLastPathComponent() == file.deletingLastPathComponent())
}

private struct JournalFixture {
    let root: URL
    let journal: URL
    let owner: UUID
    init(owner suppliedOwner: UUID? = nil) throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("journal-" + UUID().uuidString)
        journal = root.appendingPathComponent("journal")
        owner = suppliedOwner ?? UUID()
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager().createDirectory(at: journal, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try OperationJournal.writeExclusive(Data(owner.uuidString.utf8), name: ".mac-explorer-journal-v1", anchor: DirectoryAnchor(journal, resolve: false))
    }
    func remove() { try? FileManager().removeItem(at: root) }
    func record() -> JournalRecord { JournalRecord(version: 1, owner: owner, id: UUID(), operation: "Copy") }
    func legacy(_ record: JournalRecord) throws -> URL {
        let name = "\(record.id.uuidString)-\(String(format: "%06d", record.revision)).json"
        try OperationJournal.writeExclusive(try JSONEncoder().encode(record), name: name, anchor: DirectoryAnchor(journal, resolve: false))
        return journal.appendingPathComponent(name)
    }
    func sql(_ command: String) throws -> [Int64] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(journal.appendingPathComponent(SQLiteJournalStore.name).path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let database else {
            throw FileOperationFailure.ioFailure
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK, let statement else { throw FileOperationFailure.ioFailure }
        defer { sqlite3_finalize(statement) }
        var result: [Int64] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw FileOperationFailure.ioFailure }
            result.append(sqlite3_column_int64(statement, 0))
        }
    }
    func normalizedRows() throws -> [[String]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(journal.appendingPathComponent(SQLiteJournalStore.name).path, &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let database else { throw FileOperationFailure.ioFailure }
        defer { sqlite3_close(database) }
        let queries = [
            "SELECT id,revision,created_at,state,hex(head),checksum,bytes FROM jobs ORDER BY id",
            "SELECT job,ordinal,hex(payload),checksum FROM steps ORDER BY job,ordinal",
            "SELECT job,ordinal,hex(payload),checksum FROM areas ORDER BY job,ordinal",
            "SELECT job,ordinal,hex(payload),checksum FROM locations ORDER BY job,ordinal",
            "SELECT job,ordinal,hex(payload),checksum FROM trash_intents ORDER BY job,ordinal",
            "SELECT job,revision,state FROM events ORDER BY job,revision"
        ]
        return try queries.enumerated().flatMap { index, query -> [[String]] in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw FileOperationFailure.ioFailure }
            defer { sqlite3_finalize(statement) }
            var rows: [[String]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return rows }
                guard status == SQLITE_ROW else { throw FileOperationFailure.ioFailure }
                rows.append([String(index)] + (0..<sqlite3_column_count(statement)).map {
                    sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "NULL"
                })
            }
        }
    }

}

@Test func journalSQLiteRoundTripStoresNormalizedRowsWithoutNewSnapshots() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var record = fixture.record()
    let parent = try DirectoryAnchor(fixture.root, resolve: false)
    let source = fixture.root.appendingPathComponent("source")
    try Data("fixture".utf8).write(to: source)
    let tree = try verifiedTree(source, cancellation: OperationCancellation())
    record.steps = (0..<1025).map { ordinal in
        JournalStep(source: source, destination: fixture.root.appendingPathComponent("target-\(ordinal)"),
                    sourceParent: parent.identity, destinationParent: parent.identity, before: tree)
    }
    do {
        let journal = try OperationJournal(fixture.journal)
        try journal.reserveCapacity(steps: 1025, areas: 0, locations: 0, trashIntents: 0, estimatedBytes: 4_194_304)
        try journal.saveSnapshot(&record)
        record.steps[1024].after = tree; record.steps[1024].undone = true
        record.state = "committed"
        try journal.saveSnapshot(&record)
    }
    let reopened = try OperationJournal(fixture.journal)
    let inspection = try reopened.inspect()
    #expect(inspection.refused.isEmpty)
    #expect(inspection.records.count == 1)
    #expect(inspection.records.first?.revision == 2)
    #expect(inspection.records.first?.steps.count == 1025)
    #expect(inspection.records.first?.steps.last?.undone == true)
    #expect(try fixture.sql("SELECT count(*) FROM steps") == [1025])
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.journal.path).allSatisfy { !$0.hasSuffix(".json") })
}

@Test func journalLegacyMigrationPreservesEvidenceAndIsIdempotent() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var record = fixture.record()
    let first = try fixture.legacy(record)
    record.revision = 1; record.state = "committed"
    let latest = try fixture.legacy(record)
    let original = try Data(contentsOf: latest)
    do {
        let journal = try OperationJournal(fixture.journal)
        let inspected = try journal.inspect()
        #expect(inspected.records.first?.state == "committed")
        var imported = try #require(inspected.records.first)
        imported.state = "undone"
        try journal.saveSnapshot(&imported)
    }
    do {
        let journal = try OperationJournal(fixture.journal)
        #expect(try journal.inspect().records.first?.state == "undone")
        #expect(try fixture.sql("SELECT count(*) FROM legacy_imports") == [1])
        #expect(try fixture.sql("SELECT count(*) FROM jobs") == [1])
        #expect(try Data(contentsOf: latest) == original)
        #expect(FileManager().fileExists(atPath: first.path))
    }
    try Data("corrupt old intent".utf8).write(to: first)
    let refused = try OperationJournal(fixture.journal).inspect()
    #expect(refused.records.isEmpty)
    #expect(refused.refused == [latest])
}

@Test func journalLegacyMigrationStreamsBeyondOldDirectoryCap() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var record = fixture.record()
    // Only fixture creation bypasses per-revision sync to keep this large read test focused.
    for revision in 0..<8200 {
        record.revision = revision
        let name = "\(record.id.uuidString)-\(String(format: "%06d", revision)).json"
        let url = fixture.journal.appendingPathComponent(name)
        try JSONEncoder().encode(record).write(to: url, options: .withoutOverwriting)
        try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    let journal = try OperationJournal(fixture.journal)
    let inspection = try journal.inspect()
    #expect(inspection.refused.isEmpty)
    #expect(inspection.records.first?.revision == 8200)
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.journal.path).filter { $0.hasSuffix(".json") }.count == 8200)
}

@Test func journalLegacyMigrationRejectsGapsAndDoesNotImportOlderRevision() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var record = fixture.record()
    _ = try fixture.legacy(record)
    record.revision = 2; record.state = "committed"
    let latest = try fixture.legacy(record)
    let inspection = try OperationJournal(fixture.journal).inspect()
    #expect(inspection.records.isEmpty)
    #expect(inspection.refused == [latest])
}

@Test func journalTransactionFailureRollsBackRowsAndRevision() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var record = fixture.record()
    do { try OperationJournal(fixture.journal).saveSnapshot(&record) }
    do {
        let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(beforeSaveCommit: { throw FileOperationFailure.ioFailure }))
        record.state = "committed"
        #expect(throws: FileOperationFailure.ioFailure) { try journal.saveSnapshot(&record) }
        #expect(record.revision == 1)
    }
    let inspection = try OperationJournal(fixture.journal).inspect()
    #expect(inspection.records.first?.state == "preparing")
    #expect(inspection.records.first?.revision == 1)
    #expect(try fixture.sql("SELECT count(*) FROM events") == [1])
}

@Test func journalInterruptedMigrationRetriesWithoutDuplicateImports() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let record = fixture.record()
    let legacy = try fixture.legacy(record)
    do {
        let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(beforeSaveCommit: { throw FileOperationFailure.ioFailure }))
        #expect(try journal.inspect().refused == [legacy])
    }
    let inspection = try OperationJournal(fixture.journal).inspect()
    #expect(inspection.records.count == 1)
    #expect(inspection.refused.isEmpty)
    #expect(try fixture.sql("SELECT count(*) FROM legacy_imports") == [1])
}

@Test func journalCompactionRetainsRecoveryRowsAndLegacyFiles() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var record = fixture.record()
    let evidence = try fixture.legacy(record)
    let journal = try OperationJournal(fixture.journal)
    record = try #require(journal.inspect().records.first)
    record.locations = [fixture.root.appendingPathComponent("retained")]
    record.state = "mutating"; try journal.saveSnapshot(&record)
    record.state = "committed"; try journal.saveSnapshot(&record)
    let before = try journal.maintenance()
    let after = try journal.compact()
    #expect(before.eventCount == 3)
    #expect(after.eventCount == 1)
    #expect(try journal.inspect().records.first?.locations == record.locations)
    #expect(FileManager().fileExists(atPath: evidence.path))
    #expect(try fixture.sql("SELECT count(*) FROM jobs") == [1])
}

@Test func journalCorruptSQLiteNeverFallsBackToPreservedLegacy() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var record = fixture.record(); record.state = "committed"
    _ = try fixture.legacy(record)
    do { _ = try OperationJournal(fixture.journal).inspect() }
    let database = fixture.journal.appendingPathComponent(SQLiteJournalStore.name)
    try Data("not sqlite".utf8).write(to: database)
    let inspection = try OperationJournal(fixture.journal).inspect()
    #expect(inspection.records.isEmpty)
    #expect(inspection.refused.contains(database))
}

@Test func journalCorruptNormalizedRowRefusesCurrentState() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var record = fixture.record()
    record.locations = [fixture.root.appendingPathComponent("retained")]
    do { try OperationJournal(fixture.journal).saveSnapshot(&record) }
    _ = try fixture.sql("UPDATE locations SET payload=x'00'")
    let inspection = try OperationJournal(fixture.journal).inspect()
    #expect(inspection.records.isEmpty)
    #expect(inspection.refused == [fixture.journal.appendingPathComponent(SQLiteJournalStore.name)])
}

@Test func journalRejectsSQLiteAndSidecarSymlinkFIFOAndHardlink() throws {
    for suffix in ["", "-journal", "-wal", "-shm"] {
        for kind in 0..<3 {
            let fixture = try JournalFixture(); defer { fixture.remove() }
            do { _ = try OperationJournal(fixture.journal).inspect() }
            let file = fixture.journal.appendingPathComponent(SQLiteJournalStore.name + suffix)
            if suffix.isEmpty { try FileManager().removeItem(at: file) }
            let external = fixture.root.appendingPathComponent("preserved")
            try Data("preserve fixture".utf8).write(to: external)
            if kind == 0 { try FileManager().createSymbolicLink(at: file, withDestinationURL: external) }
            else if kind == 1 { #expect(mkfifo(file.path, 0o600) == 0) }
            else { #expect(link(external.path, file.path) == 0) }
            let inspection = try OperationJournal(fixture.journal).inspect()
            #expect(inspection.records.isEmpty)
            #expect(!inspection.refused.isEmpty)
            #expect(try Data(contentsOf: external) == Data("preserve fixture".utf8))
        }
    }
}

@Test func journalWriterLockPreventsConcurrentOwnerAndReservationIsBounded() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    #expect(throws: FileOperationFailure.unavailable) { _ = try OperationJournal(fixture.journal) }
    #expect(throws: FileOperationFailure.unsupported) {
        try journal.reserveCapacity(steps: OperationJournal.maximumSteps + 1, areas: 0, locations: 0, trashIntents: 0, estimatedBytes: 1024)
    }
    #expect(try journal.inspect().records.isEmpty)
}

@Test func journalForeignRegularSidecarIsPreservedAndRefused() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    do { _ = try OperationJournal(fixture.journal).inspect() }
    let sidecar = fixture.journal.appendingPathComponent(SQLiteJournalStore.name + "-journal")
    let bytes = Data("foreign journal data".utf8)
    try bytes.write(to: sidecar, options: .withoutOverwriting)
    try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
    let inspection = try OperationJournal(fixture.journal).inspect()
    #expect(inspection.records.isEmpty)
    #expect(!inspection.refused.isEmpty)
    #expect(try Data(contentsOf: sidecar) == bytes)
}

@Test func journalMissingSQLiteDoesNotReinitializeOrReuseLegacyState() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    _ = try fixture.legacy(fixture.record())
    do { _ = try OperationJournal(fixture.journal).inspect() }
    let database = fixture.journal.appendingPathComponent(SQLiteJournalStore.name)
    try FileManager().removeItem(at: database)
    let inspection = try OperationJournal(fixture.journal).inspect()
    #expect(inspection.records.isEmpty)
    #expect(inspection.refused.contains(database))
    #expect(!FileManager().fileExists(atPath: database.path))
}

@Test func journalSummaryPagesKeepNewestOrderAndFindOlderUnfinishedWork() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    var expected: [UUID] = []
    for index in 0..<130 {
        var record = fixture.record()
        record.createdAt = Date(timeIntervalSinceReferenceDate: Double(index))
        record.state = index == 0 ? "needsReview" : "committed"
        record.locations = [fixture.root.appendingPathComponent("retained-\(index)")]
        try journal.saveSnapshot(&record)
        expected.append(record.id)
    }
    #expect(try journal.unfinishedCount() == 1)
    var collected: [UUID] = []
    var cursor: UUID?
    repeat {
        let page = try journal.inspectSummaries(after: cursor, limit: 32)
        #expect(page.refused.isEmpty)
        #expect(page.records.count <= 32)
        collected.append(contentsOf: page.records.map(\.id))
        cursor = page.next
    } while cursor != nil
    #expect(collected == expected.reversed())
    #expect(try journal.inspectRecord(expected[0])?.state == "needsReview")
    try journal.validateWritableCatalog()
}

@Test func journalNarrowLookupDoesNotDecodeUnrelatedDamagedSteps() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("source")
    try Data("generated".utf8).write(to: source)
    let parent = try DirectoryAnchor(fixture.root, resolve: false)
    let tree = try verifiedTree(source, cancellation: OperationCancellation())
    var damaged = fixture.record()
    damaged.steps = [JournalStep(source: source, destination: fixture.root.appendingPathComponent("target"),
                                 sourceParent: parent.identity, destinationParent: parent.identity, before: tree)]
    var healthy = fixture.record()
    do {
        let journal = try OperationJournal(fixture.journal)
        try journal.saveSnapshot(&damaged); try journal.saveSnapshot(&healthy)
    }
    _ = try fixture.sql("UPDATE steps SET payload=x'00'")
    let journal = try OperationJournal(fixture.journal)
    try journal.validateWritableCatalog()
    #expect(try journal.inspectRecord(healthy.id)?.id == healthy.id)
    #expect(throws: (any Error).self) { _ = try journal.inspectRecord(damaged.id) }
}

@Test func journalDurabilityUsesExtraAndFullFSync() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let configuration = try OperationJournal(fixture.journal).durabilityConfiguration()
    #expect(configuration.synchronous == 3)
    #expect(configuration.fullFSync == 1)
}

@Test func journalBoundsForeignDiagnosticsAndKeepsHealthyJobUsable() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var record = fixture.record()
    do { try OperationJournal(fixture.journal).saveSnapshot(&record) }
    for index in 0..<300 {
        try Data().write(to: fixture.journal.appendingPathComponent("foreign-\(index)"), options: .withoutOverwriting)
    }
    let journal = try OperationJournal(fixture.journal)
    let summary = try journal.inspectSummaries()
    #expect(summary.refused == [fixture.journal])
    #expect(summary.records.first?.id == record.id)
    #expect(try journal.inspectRecord(record.id)?.id == record.id)
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.journal.path).filter { $0.hasPrefix("foreign-") }.count == 300)
}

@Test func journalLegacyScanHonorsCancellationWithoutChangingEvidence() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let record = fixture.record()
    let legacy = try fixture.legacy(record)
    let original = try Data(contentsOf: legacy)
    let cancellation = OperationCancellation()
    let journal = try OperationJournal(fixture.journal, cancellation: cancellation)
    cancellation.cancel()
    #expect(throws: CancellationError.self) { _ = try journal.inspectSummaries() }
    #expect(try Data(contentsOf: legacy) == original)
    #expect(try OperationJournal.read(name: legacy.lastPathComponent, anchor: DirectoryAnchor(fixture.journal, resolve: false)) == original)
}

@Test func journalValidationCacheValidatesOnlyAppendedAndChangedRows() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let metrics = JournalMetrics()
    let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(metrics: metrics))
    var record = fixture.record()
    for index in 0..<64 {
        record.locations.append(fixture.root.appendingPathComponent("item-\(index)"))
        try journal.saveSnapshot(&record)
    }
    #expect(metrics.snapshot.counters["validatedRows"] == 64)
    #expect(metrics.snapshot.counters["writtenRows"] == 64)
    #expect(metrics.snapshot.stages["save"]?.calls == 64)
    record.state = "needsReview"
    try journal.saveSnapshot(&record)
    #expect(metrics.snapshot.counters["validatedRows"] == 64)
    record.locations[31] = fixture.root.appendingPathComponent("replacement")
    try journal.saveSnapshot(&record)
    #expect(metrics.snapshot.counters["validatedRows"] == 65)
    #expect(metrics.snapshot.counters["writtenRows"] == 65)
    #expect(try fixture.sql("SELECT count(*) FROM events") == [66])
    #expect(try journalRecordsMatch(journal.inspectRecord(record.id), record))
}

@Test func journalValidationCacheMatchesFullValidatorForAllURLRows() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let parent = try DirectoryAnchor(fixture.root, resolve: false)
    let source = fixture.root.appendingPathComponent("source")
    try Data("generated".utf8).write(to: source)
    let tree = try verifiedTree(source, cancellation: OperationCancellation())
    let journal = try OperationJournal(fixture.journal)
    var record = fixture.record()
    record.steps = [JournalStep(source: source, destination: fixture.root.appendingPathComponent("destination"), sourceParent: parent.identity, destinationParent: parent.identity, before: tree)]
    record.areas = [JournalArea(url: fixture.root, identity: parent.identity)]
    record.locations = [source]
    record.trashIntents = [JournalTrashIntent(source: source, sourceParent: parent.identity, before: tree)]
    try journal.saveSnapshot(&record)
    let candidates = [source, URL(string: "https://example.invalid/item")!, URL(string: "file://foreign.invalid/item")!,
                      URL(string: "file:///tmp/../item")!, URL(string: "file:///tmp/./item")!, URL(fileURLWithPath: "/"),
                      URL(string: "file:///tmp/%2e%2e/item")!, URL(string: "file://localhost/tmp/generated")!]
    for url in candidates {
        for kind in 0..<5 {
            var changed = record
            switch kind {
            case 0: changed.steps[0] = JournalStep(source: url, destination: source, sourceParent: parent.identity, destinationParent: parent.identity, before: tree)
            case 1: changed.steps[0] = JournalStep(source: source, destination: url, sourceParent: parent.identity, destinationParent: parent.identity, before: tree)
            case 2: changed.areas[0] = JournalArea(url: url, identity: parent.identity)
            case 3: changed.locations[0] = url
            default: changed.trashIntents[0] = JournalTrashIntent(source: url, sourceParent: parent.identity, before: tree)
            }
            let accepted: Bool
            do { try OperationJournal.validate(changed); accepted = true } catch { accepted = false }
            if accepted { try journal.saveSnapshot(&changed); record = changed }
            else {
                #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.saveSnapshot(&changed) }
                #expect(changed.revision == record.revision)
                #expect(try journalRecordsMatch(journal.inspectRecord(record.id), record))
            }
        }
    }
}

@Test func journalValidationCacheDoesNotReuseDifferentURLRepresentations() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let base = fixture.root.appendingPathComponent("container", isDirectory: true)
    let relative = try #require(URL(string: "leaf", relativeTo: base))
    let absolute = try #require(URL(string: relative.absoluteString))
    #expect(relative.absoluteString == absolute.absoluteString)
    #expect(relative.relativeString != absolute.relativeString)
    #expect(!OperationJournal.sameURLRepresentation(relative, absolute))
    let metrics = JournalMetrics()
    let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(metrics: metrics))
    var record = fixture.record(); record.locations = [relative]
    try journal.saveSnapshot(&record)
    record.locations[0] = absolute
    try journal.saveSnapshot(&record)
    #expect(metrics.snapshot.counters["validatedRows"] == 2)
    let dotBase = try #require(URL(string: fixture.root.absoluteString + "/./"))
    let dotRelative = try #require(URL(string: "leaf", relativeTo: dotBase))
    #expect(!OperationJournal.sameURLRepresentation(dotRelative, dotRelative.standardizedFileURL))
}

@Test func journalValidationCacheRechecksChangedProofsAndHeaders() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let parent = try DirectoryAnchor(fixture.root, resolve: false)
    let source = fixture.root.appendingPathComponent("payload")
    try Data("generated".utf8).write(to: source)
    let tree = try verifiedTree(source, cancellation: OperationCancellation())
    let journal = try OperationJournal(fixture.journal)
    var record = fixture.record()
    record.areas = [JournalArea(url: fixture.root, identity: parent.identity,
        stagingProof: JournalStagingProof(version: 1, payload: tree, identityDigest: String(repeating: "a", count: 64), nodeCount: 1, stepCount: 0))]
    try journal.saveSnapshot(&record)
    for kind in 0..<7 {
        var changed = record
        if kind == 5 { changed.state = "foreignState" }
        else if kind == 6 { changed.failureStage = String(repeating: "x", count: 65) }
        else {
            changed.areas[0].stagingProof = JournalStagingProof(version: kind == 0 ? 2 : 1, payload: tree,
                identityDigest: kind == 1 ? "invalid" : String(repeating: "a", count: 64),
                nodeCount: kind == 2 ? 0 : (kind == 3 ? OperationLimits.maximumNodes + 1 : 1), stepCount: kind == 4 ? 1 : 0)
        }
        #expect(throws: FileOperationFailure.recoveryUncertain) { try OperationJournal.validate(changed) }
        #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.saveSnapshot(&changed) }
        #expect(try journalRecordsMatch(journal.inspectRecord(record.id), record))
    }
}

private final class JournalCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fail = false
    func setFailure(_ value: Bool) { lock.withLock { fail = value } }
    func check() throws { if lock.withLock({ fail }) { throw FileOperationFailure.outOfSpace } }
}

@Test func journalValidationCachePublishesOnlyCommittedRows() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let gate = JournalCommitGate(), metrics = JournalMetrics()
    let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(beforeSaveCommit: { try gate.check() }, metrics: metrics))
    var record = fixture.record(); record.locations = [fixture.root.appendingPathComponent("first")]
    try journal.saveSnapshot(&record)
    var next = record; next.locations[0] = fixture.root.appendingPathComponent("second")
    gate.setFailure(true)
    #expect(throws: FileOperationFailure.outOfSpace) { try journal.saveSnapshot(&next) }
    #expect(next.revision == record.revision)
    #expect(try journalRecordsMatch(journal.inspectRecord(record.id), record))
    let validated = metrics.snapshot.counters["validatedRows"] ?? 0
    gate.setFailure(false)
    try journal.saveSnapshot(&next)
    #expect(metrics.snapshot.counters["validatedRows"] == validated + 1)
    #expect(try journalRecordsMatch(journal.inspectRecord(record.id), next))
    #expect(try fixture.sql("SELECT count(*) FROM events") == [2])
}

@Test func journalValidationCacheColdSaveAndReadFullyValidateRows() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var record = fixture.record()
    record.locations = (0..<8).map { fixture.root.appendingPathComponent("item-\($0)") }
    do { let journal = try OperationJournal(fixture.journal); try journal.saveSnapshot(&record) }
    let metrics = JournalMetrics()
    let reopened = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(metrics: metrics))
    record.state = "needsReview"
    try reopened.saveSnapshot(&record)
    #expect(metrics.snapshot.counters["validatedRows"] == 8)
    try reopened.saveSnapshot(&record)
    #expect(metrics.snapshot.counters["validatedRows"] == 8)
    #expect(try journalRecordsMatch(reopened.inspectRecord(record.id), record))
    #expect(metrics.snapshot.counters["validatedRows"] == 16)
}

private func journalRecordsMatch(_ actual: JournalRecord?, _ expected: JournalRecord) throws -> Bool {
    guard let actual else { return false }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(actual) == encoder.encode(expected)
}

@Test func journalValidationCacheColdSaveRejectsCorruptPriorRows() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var record = fixture.record(); record.locations = [fixture.root.appendingPathComponent("generated")]
    do { let journal = try OperationJournal(fixture.journal); try journal.saveSnapshot(&record) }
    _ = try fixture.sql("UPDATE locations SET checksum='corrupt'")
    let reopened = try OperationJournal(fixture.journal)
    record.state = "needsReview"
    #expect(throws: FileOperationFailure.recoveryUncertain) { try reopened.saveSnapshot(&record) }
    #expect(record.revision == 1)
    #expect(try fixture.sql("SELECT count(*) FROM events") == [1])
}

@Test func journalEditMatchesSnapshotWriterAtEveryDurableBoundary() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let referenceFixture = try JournalFixture(owner: fixture.owner); defer { referenceFixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    let reference = try OperationJournal(referenceFixture.journal)
    let edit = try journal.beginEdit(operation: "Copy")
    var expected = edit.snapshot
    let parent = try DirectoryAnchor(fixture.root, resolve: false)
    let source = fixture.root.appendingPathComponent("payload")
    try Data("generated journal differential".utf8).write(to: source)
    let tree = try verifiedTree(source, cancellation: OperationCancellation())
    let step = JournalStep(source: source, destination: fixture.root.appendingPathComponent("published"),
                           sourceParent: parent.identity, destinationParent: parent.identity, before: tree)
    func saveBoth() throws {
        try journal.save(edit)
        try reference.saveSnapshot(&expected)
        #expect(try journalRecordsMatch(edit.snapshot, expected))
        #expect(try journalRecordsMatch(journal.inspectRecord(edit.id), expected))
        #expect(try fixture.normalizedRows() == referenceFixture.normalizedRows())
    }
    try saveBoth()
    try edit.appendNewLocations([source, source]); expected.locations += [source, source]
    try saveBoth()
    try edit.appendNewLocations([source]); try saveBoth()
    let area = JournalArea(url: fixture.root, identity: parent.identity)
    try edit.appendArea(area); expected.areas.append(area)
    try saveBoth()
    let proof = JournalStagingProof(version: 1, payload: tree, identityDigest: String(repeating: "a", count: 64), nodeCount: 1, stepCount: 0)
    try edit.setStagingProof(proof, at: 0); expected.areas[0].stagingProof = proof
    edit.setFailureStage("staging-proof"); expected.failureStage = "staging-proof"
    try saveBoth()
    try edit.appendStep(step); expected.steps.append(step)
    edit.setState("mutating"); expected.state = "mutating"
    edit.setFailureStage(nil); expected.failureStage = nil
    try saveBoth()
    // Duplicate native intents resolve together when an outcome for their source arrives.
    let intent = JournalTrashIntent(source: source, sourceParent: parent.identity, before: tree)
    try edit.appendTrashIntent(intent); try edit.appendTrashIntent(intent)
    expected.trashIntents += [intent, intent]
    #expect(!edit.allTrashKnown)
    try saveBoth()
    try edit.setStepOutcome(tree, at: 0); expected.steps[0].after = tree
    #expect(edit.allTrashKnown)
    try saveBoth()
    try edit.setStepOutcome(tree, at: 0); try saveBoth() // Same value still preserves the save.
    edit.setState("undoing"); expected.state = "undoing"; try saveBoth()
    try edit.markStepUndone(at: 0); expected.steps[0].undone = true; try saveBoth()
    edit.setState("undone"); expected.state = "undone"; try saveBoth()
    #expect(try fixture.sql("SELECT count(*) FROM events") == [12])
}

@Test func journalEditWarmWorkCountsFollowChangedRows() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let metrics = JournalMetrics()
    let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(metrics: metrics))
    let edit = try journal.beginEdit(operation: "Copy")
    for index in 0..<128 {
        try edit.appendLocation(fixture.root.appendingPathComponent("location-\(index)"))
        try journal.save(edit)
    }
    edit.setState("committed"); try journal.save(edit); try journal.save(edit)
    let observed = metrics.snapshot
    #expect(observed.counters["validatedRows"] == 128)
    #expect(observed.counters["comparedRows"] == 128)
    #expect(observed.counters["rowScanCandidates"] == 128)
    #expect(observed.counters["writtenRows"] == 128)
    #expect(observed.stages["save"]?.calls == 130)
    #expect(observed.stages["commit"]?.calls == 131) // Includes schema, as before.
    #expect(try fixture.sql("SELECT count(*) FROM events") == [130])
    #expect(try journalRecordsMatch(journal.inspectRecord(edit.id), edit.snapshot))
}

@Test func journalEditFailureKeepsCommittedRowsAndAllowsModifiedRetry() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let gate = JournalCommitGate(), metrics = JournalMetrics()
    let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(beforeSaveCommit: { try gate.check() }, metrics: metrics))
    let edit = try journal.beginEdit(operation: "Copy")
    try edit.appendLocation(fixture.root.appendingPathComponent("first")); try journal.save(edit)
    let committed = edit.snapshot, raw = try fixture.normalizedRows()
    try edit.appendLocation(fixture.root.appendingPathComponent("second"))
    gate.setFailure(true)
    for _ in 0..<2 {
        #expect(throws: FileOperationFailure.outOfSpace) { try journal.save(edit) }
        #expect(edit.revision == committed.revision)
        #expect(try fixture.normalizedRows() == raw)
    }
    try edit.appendLocation(fixture.root.appendingPathComponent("third"))
    edit.setState("needsReview"); gate.setFailure(false); try journal.save(edit)
    #expect(edit.locations.count == 3)
    #expect(try fixture.sql("SELECT count(*) FROM events") == [2])
    #expect(try journalRecordsMatch(journal.inspectRecord(edit.id), edit.snapshot))
}

@Test func journalEditCheckpointsCannotCrossCommitsOrSessions() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    let edit = try journal.beginEdit(operation: "Move to Trash")
    try journal.save(edit)
    let checkpoint = edit.checkpoint()
    try edit.appendLocation(fixture.root.appendingPathComponent("unconfirmed"))
    try edit.restore(checkpoint)
    #expect(edit.locations.isEmpty)
    try edit.appendLocation(fixture.root.appendingPathComponent("native-returned"))
    let nativeResult = edit.checkpoint()
    try edit.appendLocation(fixture.root.appendingPathComponent("later"))
    try edit.restore(nativeResult); try journal.save(edit)
    #expect(edit.locations.count == 1)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try edit.restore(checkpoint) }
    let other = try journal.beginEdit(operation: "Copy")
    #expect(throws: FileOperationFailure.recoveryUncertain) { try other.restore(nativeResult) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(edit) }
}

@Test func journalEditColdOpenValidatesAllRowsAndRejectsStaleSessions() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    var expected: JournalRecord
    do {
        let journal = try OperationJournal(fixture.journal)
        let edit = try journal.beginEdit(operation: "Copy")
        try edit.appendLocations((0..<8).map { fixture.root.appendingPathComponent("entry-\($0)") })
        try journal.save(edit); expected = edit.snapshot
    }
    let metrics = JournalMetrics()
    let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(metrics: metrics))
    let first = try #require(try journal.openEdit(expected.id))
    #expect(metrics.snapshot.counters["validatedRows"] == 8)
    first.setState("committed"); try journal.save(first)
    #expect(metrics.snapshot.counters["validatedRows"] == 8)
    let next = try #require(try journal.openEdit(expected.id))
    #expect(metrics.snapshot.counters["validatedRows"] == 16)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(first) }
    try journal.save(next)
    #expect(next.revision == expected.revision + 2)
    // A forged session and a snapshot detached from the editor grant no authority.
    let forged = JournalEditSession(next.snapshot, new: false)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(forged) }
    var detached = next.snapshot; detached.locations.removeAll()
    #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.saveSnapshot(&detached) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(next) }
}

@Test func journalEditPostCommitFailureRequiresColdReopen() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let gate = JournalCommitGate()
    let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(afterSaveCommit: { try gate.check() }))
    let edit = try journal.beginEdit(operation: "Copy")
    try journal.save(edit)
    try edit.appendLocation(fixture.root.appendingPathComponent("durably-written"))
    gate.setFailure(true)
    #expect(throws: FileOperationFailure.outOfSpace) { try journal.save(edit) }
    #expect(edit.revision == 1)
    #expect(try fixture.sql("SELECT count(*) FROM events") == [2])
    #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(edit) }
    gate.setFailure(false)
    let reopened = try #require(try journal.openEdit(edit.id))
    #expect(reopened.revision == 2)
    #expect(reopened.locations.count == 1)
    reopened.setState("needsReview"); try journal.save(reopened)
    #expect(try fixture.sql("SELECT count(*) FROM events") == [3])
}

@Test func journalEditColdOpenRefusesCorruptRows() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let id: UUID
    do {
        let journal = try OperationJournal(fixture.journal)
        let edit = try journal.beginEdit(operation: "Copy"); id = edit.id
        try edit.appendLocation(fixture.root.appendingPathComponent("first")); try journal.save(edit)
    }
    _ = try fixture.sql("UPDATE locations SET checksum='corrupt'")
    let journal = try OperationJournal(fixture.journal)
    #expect(throws: FileOperationFailure.recoveryUncertain) { _ = try journal.openEdit(id) }
}

@Test func journalEditURLRepresentationsAndInvalidRowsRemainChecked() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    let edit = try journal.beginEdit(operation: "Copy")
    let parent = try DirectoryAnchor(fixture.root, resolve: false)
    let source = fixture.root.appendingPathComponent("source")
    try Data("generated".utf8).write(to: source)
    let tree = try verifiedTree(source, cancellation: OperationCancellation())
    try journal.save(edit)
    let checkpoint = edit.checkpoint()
    let urls = [URL(string: "https://example.invalid/item")!, URL(string: "file://foreign.invalid/item")!,
                URL(string: "file:///tmp/../item")!, URL(string: "file:///tmp/./item")!, URL(fileURLWithPath: "/")]
    for url in urls {
        for kind in 0..<5 {
            try edit.restore(checkpoint)
            switch kind {
            case 0: try edit.appendStep(JournalStep(source: url, destination: source, sourceParent: parent.identity, destinationParent: parent.identity, before: tree))
            case 1: try edit.appendStep(JournalStep(source: source, destination: url, sourceParent: parent.identity, destinationParent: parent.identity, before: tree))
            case 2: try edit.appendArea(JournalArea(url: url, identity: parent.identity))
            case 3: try edit.appendLocation(url)
            default: try edit.appendTrashIntent(JournalTrashIntent(source: url, sourceParent: parent.identity, before: tree))
            }
            #expect(throws: FileOperationFailure.recoveryUncertain) { try OperationJournal.validate(edit.snapshot) }
            #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(edit) }
            #expect(edit.revision == 1)
        }
    }
    try edit.restore(checkpoint)
    let base = fixture.root.appendingPathComponent("container", isDirectory: true)
    let relative = try #require(URL(string: "leaf", relativeTo: base))
    let absolute = try #require(URL(string: relative.absoluteString))
    try edit.appendLocations([relative, absolute]); try journal.save(edit)
    let result = try #require(try journal.inspectRecord(edit.id))
    #expect(OperationJournal.sameURLRepresentation(edit.locations[0], relative))
    #expect(OperationJournal.sameURLRepresentation(edit.locations[1], absolute))
    #expect(!OperationJournal.sameURLRepresentation(edit.locations[0], edit.locations[1]))
    // Foundation's existing Codable URL format stores its absolute representation.
    // Persistence must match that format, while the live candidate retains its spelling.
    let encoded = try JSONEncoder().encode([relative, absolute])
    let persisted = try JSONDecoder().decode([URL].self, from: encoded)
    #expect(result.locations.count == persisted.count)
    #expect(zip(result.locations, persisted).allSatisfy(OperationJournal.sameURLRepresentation))
}

@Test func journalEditRejectsMalformedProofHeaderAndOutOfRangeMutation() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    let edit = try journal.beginEdit(operation: "Copy")
    let parent = try DirectoryAnchor(fixture.root, resolve: false)
    let source = fixture.root.appendingPathComponent("payload")
    try Data("generated".utf8).write(to: source)
    let tree = try verifiedTree(source, cancellation: OperationCancellation())
    try edit.appendArea(JournalArea(url: fixture.root, identity: parent.identity)); try journal.save(edit)
    let checkpoint = edit.checkpoint()
    for kind in 0..<7 {
        try edit.restore(checkpoint)
        if kind == 5 { edit.setState("foreignState") }
        else if kind == 6 { edit.setFailureStage(String(repeating: "x", count: 65)) }
        else {
            try edit.setStagingProof(JournalStagingProof(version: kind == 0 ? 2 : 1, payload: tree,
                identityDigest: kind == 1 ? "invalid" : String(repeating: "a", count: 64),
                nodeCount: kind == 2 ? 0 : (kind == 3 ? OperationLimits.maximumNodes + 1 : 1),
                stepCount: kind == 4 ? 1 : 0), at: 0)
        }
        #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(edit) }
    }
    try edit.restore(checkpoint)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try edit.markStepUndone(at: 0) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try edit.setStepOutcome(tree, at: -1) }
    #expect(throws: FileOperationFailure.unsupported) {
        try edit.appendLocations(Array(repeating: source, count: OperationJournal.maximumLocations + 1))
    }
    #expect(edit.locations.isEmpty)
    #expect(try fixture.sql("SELECT count(*) FROM events") == [1])
}

@Test func journalEditActualSQLiteFullPreservesRowsAndReopensForRetry() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let id: UUID
    do {
        let journal = try OperationJournal(fixture.journal)
        let edit = try journal.beginEdit(operation: "Copy"); id = edit.id
        try journal.save(edit)
    }
    let pages = try #require(try fixture.sql("PRAGMA page_count").first)
    let raw = try fixture.normalizedRows()
    let locations = (0..<512).map { fixture.root.appendingPathComponent("\($0)-" + String(repeating: "x", count: 1024)) }
    do {
        let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(maximumPageCount: pages))
        let edit = try #require(try journal.openEdit(id))
        try edit.appendLocations(locations)
        for _ in 0..<2 {
            #expect(throws: FileOperationFailure.outOfSpace) { try journal.save(edit) }
            #expect(edit.revision == 1)
            #expect(try fixture.normalizedRows() == raw)
            #expect(try journal.inspectRecord(id)?.locations.isEmpty == true)
        }
    }
    let journal = try OperationJournal(fixture.journal)
    let retry = try #require(try journal.openEdit(id))
    try retry.appendLocations(locations); try journal.save(retry)
    #expect(retry.revision == 2)
    #expect(try journal.inspectRecord(id)?.locations == locations)
}

@Test func journalEditColdOpenChecksRowBytesEventsAndOrdinals() throws {
    let changes = ["UPDATE jobs SET bytes=bytes+1", "DELETE FROM events", "UPDATE events SET state='foreign'",
                   "DELETE FROM locations WHERE ordinal=0", "UPDATE locations SET ordinal=4 WHERE ordinal=0"]
    for change in changes {
        let fixture = try JournalFixture(); defer { fixture.remove() }
        let id: UUID
        do {
            let journal = try OperationJournal(fixture.journal)
            let edit = try journal.beginEdit(operation: "Copy"); id = edit.id
            try edit.appendLocations([fixture.root.appendingPathComponent("a"), fixture.root.appendingPathComponent("b")])
            try journal.save(edit)
        }
        _ = try fixture.sql(change)
        let journal = try OperationJournal(fixture.journal)
        #expect(throws: FileOperationFailure.recoveryUncertain) { _ = try journal.openEdit(id) }
    }
}

@Test func journalEditSnapshotWriteAndForeignStoreInvalidateAuthority() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let otherFixture = try JournalFixture(owner: fixture.owner); defer { otherFixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    let other = try OperationJournal(otherFixture.journal)
    let edit = try journal.beginEdit(operation: "Copy"); try journal.save(edit)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try other.save(edit) }
    var replacement = edit.snapshot; replacement.state = "needsReview"
    try journal.saveSnapshot(&replacement)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(edit) }
    let reopened = try #require(try journal.openEdit(edit.id))
    #expect(try journalRecordsMatch(reopened.snapshot, replacement))
}

@Test func journalEditLocationSetMatchesArrayEqualityWithoutChangingRepresentations() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    let edit = try journal.beginEdit(operation: "Copy")
    let base = fixture.root.appendingPathComponent("container", isDirectory: true)
    let relative = try #require(URL(string: "leaf", relativeTo: base))
    let absolute = try #require(URL(string: relative.absoluteString))
    let localhost = try #require(URL(string: "file://localhost" + absolute.path))
    var expected: [URL] = []
    for candidates in [[relative, relative], [absolute], [localhost, absolute], [relative, localhost]] {
        expected += candidates.filter { !expected.contains($0) }
        try edit.appendNewLocations(candidates)
        try journal.save(edit)
        #expect(edit.locations.count == expected.count)
        #expect(zip(edit.locations, expected).allSatisfy(OperationJournal.sameURLRepresentation))
    }
    let actual = try #require(try journal.inspectRecord(edit.id))
    let persisted = try JSONDecoder().decode([URL].self, from: JSONEncoder().encode(expected))
    #expect(actual.locations.count == persisted.count)
    #expect(zip(actual.locations, persisted).allSatisfy(OperationJournal.sameURLRepresentation))
}

@Test func journalEditReplacementByteDeltasMatchFullWriter() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let referenceFixture = try JournalFixture(owner: fixture.owner); defer { referenceFixture.remove() }
    let journal = try OperationJournal(fixture.journal), reference = try OperationJournal(referenceFixture.journal)
    let edit = try journal.beginEdit(operation: "Copy")
    var expected = edit.snapshot
    let parent = try DirectoryAnchor(fixture.root, resolve: false)
    let source = fixture.root.appendingPathComponent("source")
    try Data("generated".utf8).write(to: source)
    let tree = try verifiedTree(source, cancellation: OperationCancellation())
    let step = JournalStep(source: source, destination: fixture.root.appendingPathComponent("target"),
        sourceParent: parent.identity, destinationParent: parent.identity, before: tree)
    try edit.appendStep(step); expected.steps.append(step)
    try journal.save(edit); try reference.saveSnapshot(&expected)
    let short = VerifiedTree(identity: tree.identity, digest: tree.digest, nativeTrashDigest: nil)
    for after in [tree, short, tree, short] {
        try edit.setStepOutcome(after, at: 0); expected.steps[0].after = after
        try journal.save(edit); try reference.saveSnapshot(&expected)
        #expect(try fixture.normalizedRows() == referenceFixture.normalizedRows())
        #expect(try journalRecordsMatch(journal.inspectRecord(edit.id), expected))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_JOURNAL_CRASH_PHASE"] != nil,
               "Explicit generated journal transaction interruption worker only."))
func journalEditCrashQualificationWorker() throws {
    let environment = ProcessInfo.processInfo.environment
    let phase = try #require(environment["MAC_EXPLORER_JOURNAL_CRASH_PHASE"])
    let boundary = try #require(environment["MAC_EXPLORER_JOURNAL_CRASH_BOUNDARY"])
    guard ["before-commit", "after-commit"].contains(boundary), phase == boundary || phase == "inspect" else {
        throw FileOperationFailure.invalidRequest
    }
    let root = URL(fileURLWithPath: try #require(environment["MAC_EXPLORER_JOURNAL_CRASH_ROOT"]), isDirectory: true)
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let base = repository.appendingPathComponent(".build/test-fixtures")
    let prefix = "journal-edit-crash-"
    guard base.resolvingSymlinksInPath() == base, root.deletingLastPathComponent() == base,
          root.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil else {
        throw FileOperationFailure.invalidRequest
    }
    let marker = Data("Mac Explorer owned journal crash fixture\n\(root.lastPathComponent)\n".utf8)
    let journalURL = root.appendingPathComponent("journal")
    if phase != "inspect" {
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try OperationJournal.writeExclusive(marker, name: ".journal-crash-owned-v1", anchor: DirectoryAnchor(root, resolve: false))
        let journal = try OperationJournal(journalURL)
        let edit = try journal.beginEdit(operation: "Copy")
        try edit.appendLocation(root.appendingPathComponent("seed")); try journal.save(edit)
        try OperationJournal.writeExclusive(Data(edit.id.uuidString.utf8), name: "job-id.txt", anchor: DirectoryAnchor(root, resolve: false))
    }
    guard root.resolvingSymlinksInPath() == root else { throw FileOperationFailure.invalidRequest }
    let anchor = try DirectoryAnchor(root, resolve: false)
    guard try OperationJournal.read(name: ".journal-crash-owned-v1", anchor: anchor) == marker else { throw FileOperationFailure.invalidRequest }
    let id = try #require(String(data: try OperationJournal.read(name: "job-id.txt", anchor: anchor), encoding: .utf8).flatMap(UUID.init(uuidString:)))
    if phase == "inspect" {
        let journal = try OperationJournal(journalURL)
        let edit = try #require(try journal.openEdit(id))
        let expected = boundary == "after-commit" ? 2 : 1
        #expect(edit.revision == expected)
        #expect(edit.locations.count == expected)
        #expect(edit.state == (boundary == "after-commit" ? "mutating" : "preparing"))
        let receipt = ["phase": phase, "pid": String(getpid()), "recordID": id.uuidString,
                       "revision": String(edit.revision), "locations": String(edit.locations.count), "state": edit.state]
        try OperationJournal.writeExclusive(JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
                                            name: "inspect-summary.json", anchor: anchor)
        return
    }
    let terminate: @Sendable () throws -> Void = {
        let receipt = ["phase": phase, "pid": String(getpid()), "recordID": id.uuidString, "terminationCode": "86"]
        try OperationJournal.writeExclusive(JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
            name: "termination-summary.json", anchor: DirectoryAnchor(root, resolve: false))
        _exit(86)
    }
    let hooks = boundary == "before-commit" ? JournalStorageHooks(beforeSaveCommit: terminate)
        : JournalStorageHooks(afterSaveCommit: terminate)
    let journal = try OperationJournal(journalURL, hooks: hooks)
    let edit = try #require(try journal.openEdit(id))
    try edit.appendLocation(root.appendingPathComponent("candidate")); edit.setState("mutating")
    try journal.save(edit)
    Issue.record("The generated journal worker did not reach the requested transaction boundary.")
}

@Test func journalEditLostCommitAcknowledgementInvalidatesSession() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let gate = JournalCommitGate()
    let journal = try OperationJournal(fixture.journal,
        hooks: JournalStorageHooks(afterCommitBeforeAcknowledgement: { try gate.check() }))
    let edit = try journal.beginEdit(operation: "Copy"); try journal.save(edit)
    try edit.appendLocation(fixture.root.appendingPathComponent("committed-with-lost-acknowledgement"))
    gate.setFailure(true)
    #expect(throws: FileOperationFailure.outOfSpace) { try journal.save(edit) }
    #expect(edit.revision == 1)
    #expect(try fixture.sql("SELECT count(*) FROM events") == [2])
    #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(edit) }
    gate.setFailure(false)
    let reopened = try #require(try journal.openEdit(edit.id))
    #expect(reopened.revision == 2)
    #expect(reopened.locations.count == 1)
    try journal.save(reopened)
    #expect(try fixture.sql("SELECT count(*) FROM events") == [3])
}

@Test func journalEditLogicalByteCeilingRefusesBeforeAnyTransaction() throws {
    let fixture = try JournalFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    let edit = try journal.beginEdit(operation: "Copy"); try journal.save(edit)
    let checkpoint = edit.checkpoint(), raw = try fixture.normalizedRows()
    // Repeated generated URL values keep the candidate's input allocation small while
    // its normalized representation exceeds 64 MiB. No user file is opened or created.
    let location = fixture.root.appendingPathComponent(String(repeating: "x", count: 4096))
    try edit.appendLocations(Array(repeating: location, count: OperationJournal.maximumLocations))
    #expect(throws: FileOperationFailure.unsupported) { try journal.save(edit) }
    #expect(edit.revision == 1)
    #expect(try fixture.normalizedRows() == raw)
    try edit.restore(checkpoint)
    try edit.appendLocation(fixture.root.appendingPathComponent("within-bound")); try journal.save(edit)
    #expect(edit.revision == 2)
    #expect(try fixture.sql("SELECT count(*) FROM events") == [2])
}
