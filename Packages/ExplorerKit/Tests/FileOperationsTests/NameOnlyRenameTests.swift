import Darwin
import Foundation
import SQLite3
import CryptoKit
@testable import FileOperations
import Testing

private struct NameRenameFixture {
    let root: URL
    let journal: URL
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/rename-protocol-fixtures")
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        journal = root.appendingPathComponent("journal")
    }
    func file(_ name: String = "before.txt", bytes: Data = Data("original".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        // Foundation file creation can normalize Unicode path bytes. This fixture
        // deliberately creates the requested native spelling for namespace tests.
        let parent = try DirectoryAnchor(root)
        let fd = openat(parent.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw FileOperationFailure.ioFailure }
        return url
    }
    func service(_ hooks: RecoveryHooks = RecoveryHooks()) -> RecoverableFileOperations { RecoverableFileOperations(journalDirectory: journal, hooks: hooks) }
    func remove() { try? FileManager().removeItem(at: root) }
    func record(_ id: UUID) throws -> JournalRecord {
        let record = try OperationJournal(journal).inspectRecord(id)
        return try #require(record)
    }
    func sql(_ sql: String) throws -> [Int64] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(journal.appendingPathComponent(SQLiteJournalStore.name).path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let db else { throw FileOperationFailure.ioFailure }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw FileOperationFailure.ioFailure }
        defer { sqlite3_finalize(stmt) }
        var rows: [Int64] = []
        while true { let rc = sqlite3_step(stmt); if rc == SQLITE_DONE { return rows }; guard rc == SQLITE_ROW else { throw FileOperationFailure.ioFailure }; rows.append(sqlite3_column_int64(stmt, 0)) }
    }
}

@Test func nameRenameUsesVersionedNamespaceGuardAndKeepsFileEdits() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file()
    let result = await f.service().perform(.rename(source: source, name: "after.txt"))
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID), record = try f.record(id)
    #expect(record.version == 4 && record.nameRename?.phase == .forwardApplied)
    #expect(record.steps.isEmpty && record.areas.isEmpty && record.trashIntents.isEmpty)
    #expect(try f.sql("PRAGMA user_version") == [3])
    let target = f.root.appendingPathComponent("after.txt")
    let handle = try FileHandle(forWritingTo: target)
    try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data("edited after Rename".utf8)); try handle.close()
    let metadata = Data("edited metadata".utf8)
    #expect(metadata.withUnsafeBytes { setxattr(target.path, "com.macexplorer.rename-test", $0.baseAddress, $0.count, 0, 0) } == 0)
    #expect(chmod(target.path, 0o640) == 0)
    let summary = try await f.service().recoveryRecords().records.first
    #expect(summary?.canUndo == true && summary?.operation == "Rename (keeps edits)")
    #expect(await f.service().undo(recordID: id).result.disposition == .succeeded)
    #expect(try Data(contentsOf: source) == Data("edited after Rename".utf8))
    var attributes = stat(); #expect(lstat(source.path, &attributes) == 0 && attributes.st_mode & 0o777 == 0o640)
    var savedMetadata = Data(count: metadata.count)
    #expect(savedMetadata.withUnsafeMutableBytes { getxattr(source.path, "com.macexplorer.rename-test", $0.baseAddress, $0.count, 0, 0) } == metadata.count)
    #expect(savedMetadata == metadata)
    #expect(try f.record(id).nameRename?.phase == .reversed)
    #expect(try await f.service().retentionRecord(recordID: id).canCleanup == false)
}

@Test(arguments: [("README", "Readme"), ("Étude.txt", "étude.txt"), ("A\u{30a}.txt", "a\u{30a}.txt"), ("é.txt", "e\u{301}.txt")])
func nameRenameCaseAndNormalizationHaveExactStoredSpelling(names: (String, String)) async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file(names.0)
    let result = await f.service().perform(.rename(source: source, name: names.1))
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    let anchor = try DirectoryAnchor(f.root)
    #expect(try NativeRenameEntry.observe(parent: anchor, name: names.0).nameBytes == Data(names.1.utf8))
    #expect(await f.service().undo(recordID: id).result.disposition == .succeeded)
    #expect(try NativeRenameEntry.observe(parent: anchor, name: names.1).nameBytes == Data(names.0.utf8))
}

@Test func nameRenameNoopHasNoJournalOrUndo() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file()
    let result = await f.service().perform(.rename(source: source, name: "before.txt"))
    #expect(result.result.disposition == .succeeded && result.recordID == nil)
    #expect(!FileManager().fileExists(atPath: f.journal.path))
}

@Test func nameRenameFolderUndoKeepsCurrentChildren() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = f.root.appendingPathComponent("Folder")
    try FileManager().createDirectory(at: source, withIntermediateDirectories: false)
    try Data("old".utf8).write(to: source.appendingPathComponent("old"))
    let result = await f.service().perform(.rename(source: source, name: "folder"))
    #expect(result.result.disposition == .succeeded)
    let target = f.root.appendingPathComponent("folder")
    try FileManager().removeItem(at: target.appendingPathComponent("old"))
    try Data("new".utf8).write(to: target.appendingPathComponent("new"))
    #expect(await f.service().undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(try FileManager().contentsOfDirectory(atPath: source.path) == ["new"])
}

@Test func nameRenameDoesNotFollowDanglingSymlink() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = f.root.appendingPathComponent("Link")
    #expect(symlink("missing-generated-target", source.path) == 0)
    let result = await f.service().perform(.rename(source: source, name: "link"))
    #expect(result.result.disposition == .succeeded)
    #expect(try f.record(#require(result.recordID)).nameRename?.entry.identity.type == S_IFLNK)
    #expect(await f.service().undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(try FileManager().destinationOfSymbolicLink(atPath: source.path) == "missing-generated-target")
}

@Test func nameRenameRejectsDistinctHardLinkAndTopologyChange() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file()
    let other = f.root.appendingPathComponent("other.txt")
    #expect(link(source.path, other.path) == 0)
    let conflict = await f.service().perform(.rename(source: source, name: "other.txt"))
    #expect(conflict.result.items.first?.status == .failed(.conflict) && conflict.recordID == nil)
    let renamed = await f.service().perform(.rename(source: source, name: "after.txt"))
    #expect(renamed.result.disposition == .succeeded)
    #expect(unlink(other.path) == 0)
    #expect(await f.service().undo(recordID: try #require(renamed.recordID)).result.disposition == .failed)
    #expect(try Data(contentsOf: f.root.appendingPathComponent("after.txt")) == Data("original".utf8))
}

@Test func nameRenameRejectsSafeSaveWithCopiedBirthtime() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file()
    let renamed = await f.service().perform(.rename(source: source, name: "after.txt"))
    let id = try #require(renamed.recordID), target = f.root.appendingPathComponent("after.txt")
    var before = stat(); #expect(lstat(target.path, &before) == 0)
    let replacement = try f.file("replacement", bytes: Data("replacement".utf8))
    let fd = open(replacement.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC); defer { if fd >= 0 { close(fd) } }
    #expect(fd >= 0)
    var attrs = attrlist(); attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT); attrs.commonattr = UInt32(ATTR_CMN_CRTIME)
    #expect(fsetattrlist(fd, &attrs, &before.st_birthtimespec, MemoryLayout<timespec>.size, 0) == 0)
    #expect(rename(replacement.path, target.path) == 0)
    #expect(await f.service().undo(recordID: id).result.disposition == .failed)
    #expect(try Data(contentsOf: target) == Data("replacement".utf8))
    #expect(!FileManager().fileExists(atPath: source.path))
}

@Test func nameRenameRevalidatesSourceAfterDurableIntent() throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file(), backup = f.root.appendingPathComponent("original-backup")
    let service = f.service(RecoveryHooks(beforeExclusiveRename: { _, _ in
        try FileManager().moveItem(at: source, to: backup)
        try Data("replacement".utf8).write(to: source, options: .withoutOverwriting)
    }))
    let result = try #require(service.sameParentRename(source: source, name: "after.txt", observing: nil, cancellation: OperationCancellation()))
    #expect(result.result.disposition == .failed)
    #expect(try Data(contentsOf: source) == Data("replacement".utf8))
    #expect(try Data(contentsOf: backup) == Data("original".utf8))
    #expect(!FileManager().fileExists(atPath: f.root.appendingPathComponent("after.txt").path))
}

@Test func nameRenameCancellationBeforeAndAfterMutation() throws {
    for afterMutation in [false, true] {
        let f = try NameRenameFixture(); defer { f.remove() }
        let source = try f.file(), cancellation = OperationCancellation()
        var hooks = RecoveryHooks()
        if afterMutation { hooks.afterRename = { cancellation.cancel() } }
        else { hooks.afterIntent = { cancellation.cancel() } }
        let result = try #require(f.service(hooks).sameParentRename(source: source, name: "after.txt", observing: nil, cancellation: cancellation))
        #expect(result.result.cancellationRequested)
        let record = try f.record(#require(result.recordID))
        if afterMutation {
            #expect(result.result.disposition == .succeeded && record.state == "committed")
            #expect(!FileManager().fileExists(atPath: source.path))
        } else {
            #expect(result.result.disposition == .cancelled && record.state == "needsReview")
            #expect(FileManager().fileExists(atPath: source.path))
        }
    }
}

@Test func nameRenameSyncFailureReopensAndRecoversCaseOnlyAfterEdit() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file("Case.txt")
    let failed = await f.service(RecoveryHooks(beforeSync: { _ in throw FileOperationFailure.ioFailure })).perform(.rename(source: source, name: "case.txt"))
    #expect(failed.result.disposition == .failed)
    let id = try #require(failed.recordID), record = try f.record(id)
    #expect(record.nameRename?.phase == .forwardIntent && record.state == "needsReview")
    let handle = try FileHandle(forWritingTo: f.root.appendingPathComponent("case.txt"))
    try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data("edited".utf8)); try handle.close()
    #expect(try await f.service().recoveryRecords().records.first?.canRecover == true)
    #expect(await f.service().recover(recordID: id).result.disposition == .succeeded)
    #expect(try NativeRenameEntry.observe(parent: DirectoryAnchor(f.root), name: "case.txt").nameBytes == Data("Case.txt".utf8))
    #expect(try Data(contentsOf: source) == Data("edited".utf8))
}

@Test func nameRenameLegacyRecordStillRefusesEditedContents() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file(), target = f.root.appendingPathComponent("after.txt")
    let parent = try DirectoryAnchor(f.root), before = try verifiedTree(source, cancellation: OperationCancellation())
    try exclusiveRename(from: parent.fd, name: source.lastPathComponent, to: parent.fd, name: target.lastPathComponent)
    let id: UUID
    do {
        let journal = try OperationJournal(f.journal)
        var old = JournalRecord(version: 1, owner: journal.owner, id: UUID(), operation: "Rename")
        old.steps = [JournalStep(source: source, destination: target, sourceParent: parent.identity, destinationParent: parent.identity, before: before, after: before)]
        old.state = "committed"; old.locations = [source, target]; id = old.id
        try journal.saveSnapshot(&old)
    }
    try Data("changed".utf8).write(to: target)
    #expect(try await f.service().recoveryRecords().records.first?.operation == "Rename (unchanged contents required)")
    #expect(await f.service().undo(recordID: id).result.disposition == .failed)
}

@Test func nameRenameCatalogUpgradeIsAtomicAndPreservesLegacyPayload() throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let id: UUID, bytes: Data
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    do {
        let journal = try OperationJournal(f.journal)
        var old = JournalRecord(version: 1, owner: journal.owner, id: UUID(), operation: "Copy")
        old.state = "committed"; id = old.id; try journal.saveSnapshot(&old)
        bytes = try encoder.encode(journal.inspectRecord(id))
    }
    _ = try f.sql("UPDATE metadata SET value='2' WHERE key='version'"); _ = try f.sql("PRAGMA user_version=2")
    do {
        let rejected = try OperationJournal(f.journal, hooks: JournalStorageHooks(beforeCatalogUpgradeCommit: { throw FileOperationFailure.ioFailure }))
        #expect(try rejected.inspect().records.isEmpty)
        #expect(throws: FileOperationFailure.ioFailure) { try rejected.validateWritableCatalog() }
    }
    #expect(try f.sql("PRAGMA user_version") == [2])
    #expect(try f.sql("SELECT CAST(value AS INTEGER) FROM metadata WHERE key='version'") == [2])
    do {
        let upgraded = try OperationJournal(f.journal)
        #expect(try encoder.encode(upgraded.inspectRecord(id)) == bytes)
    }
    #expect(try f.sql("PRAGMA user_version") == [3])
    #expect(try f.sql("SELECT CAST(value AS INTEGER) FROM metadata WHERE key='version'") == [3])
}

@Test func nameRenameCatalogUpgradeUnknownAcknowledgementStaysUpgraded() throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    do { _ = try OperationJournal(f.journal) }
    _ = try f.sql("UPDATE metadata SET value='2' WHERE key='version'"); _ = try f.sql("PRAGMA user_version=2")
    do {
        let uncertain = try OperationJournal(f.journal, hooks: JournalStorageHooks(afterCatalogUpgradeCommit: { throw FileOperationFailure.ioFailure }))
        #expect(throws: FileOperationFailure.ioFailure) { try uncertain.validateWritableCatalog() }
    }
    #expect(try f.sql("PRAGMA user_version") == [3])
    #expect(try OperationJournal(f.journal).inspect().refused.isEmpty)
}

@Test(arguments: ["checksum", "semantics", "new-record"])
func nameRenameCatalogUpgradeValidatesLegacyRecordsBeforeWriting(damage: String) async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    if damage == "new-record" {
        _ = await f.service().perform(.rename(source: try f.file(), name: "after.txt"))
    } else {
        let result = await f.service().perform(.createFolder(parent: f.root, name: "folder"))
        #expect(result.result.disposition == .succeeded)
        if damage == "checksum" { _ = try f.sql("UPDATE locations SET checksum='invalid' WHERE ordinal=0") }
        else {
            let payload = try JSONEncoder().encode(URL(string: "https://generated.invalid/not-a-local-location")!)
            let hex = payload.map { String(format: "%02x", $0) }.joined()
            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            _ = try f.sql("UPDATE jobs SET bytes=bytes+\(payload.count)-(SELECT length(payload) FROM locations WHERE job=jobs.id AND ordinal=0)")
            _ = try f.sql("UPDATE locations SET payload=X'\(hex)',checksum='\(digest)' WHERE ordinal=0")
        }
    }
    _ = try f.sql("UPDATE metadata SET value='2' WHERE key='version'"); _ = try f.sql("PRAGMA user_version=2")
    let database = f.journal.appendingPathComponent(SQLiteJournalStore.name)
    let before = try Data(contentsOf: database)
    do {
        let refused = try OperationJournal(f.journal)
        let listing = try refused.inspect()
        #expect(listing.records.isEmpty && !listing.refused.isEmpty)
        #expect(throws: (any Error).self) { try refused.validateWritableCatalog() }
    }
    #expect(try f.sql("PRAGMA user_version") == [2])
    #expect(try f.sql("SELECT CAST(value AS INTEGER) FROM metadata WHERE key='version'") == [2])
    #expect(try Data(contentsOf: database) == before)
}

@Test func nameRenameRequiresSourceInProvidedSelection() throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file(), parent = try DirectoryAnchor(f.root)
    let selections = [FileOperationSelection(urls: [], identities: []),
                      FileOperationSelection(urls: [f.root], identities: [parent.identity])]
    for selection in selections {
        let result = try #require(f.service().sameParentRename(source: source, name: "after.txt", observing: selection, cancellation: OperationCancellation()))
        #expect(result.result.items.first?.status == .failed(.invalidRequest) && result.recordID == nil)
        #expect(FileManager().fileExists(atPath: source.path))
    }
    let observed = try EntrySnapshot(parent: parent.fd, name: source.lastPathComponent)
    let handle = try FileHandle(forWritingTo: source)
    try handle.write(contentsOf: Data("different generated bytes".utf8)); try handle.close()
    let result = try #require(f.service().sameParentRename(source: source, name: "after.txt", observing: FileOperationSelection(urls: [source], identities: [observed]), cancellation: OperationCancellation()))
    #expect(result.result.items.first?.status == .failed(.sourceChanged) && result.recordID == nil)
}

private final class RenameSaveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

@Test(arguments: [1, 2, 3, 4]) func nameRenameFailedSavePreservesLastDurableState(save: Int) async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file(), counter = RenameSaveCounter()
    let hooks = RecoveryHooks(journalHooks: JournalStorageHooks(beforeSaveCommit: {
        if counter.next() >= save { throw FileOperationFailure.outOfSpace }
    }))
    let result = await f.service(hooks).perform(.rename(source: source, name: "after.txt"))
    #expect(result.result.disposition == .failed)
    let summaries = try await f.service().recoveryRecords()
    #expect(summaries.refusedEntries.isEmpty)
    if save == 1 { #expect(summaries.records.isEmpty && result.recordID == nil) }
    else {
        let id = try #require(summaries.records.first?.id)
        #expect(await f.service().recover(recordID: id).result.disposition == .succeeded)
    }
    #expect(try Data(contentsOf: source) == Data("original".utf8))
    #expect(!FileManager().fileExists(atPath: f.root.appendingPathComponent("after.txt").path))
}

@Test(arguments: [1, 2, 3, 4]) func nameRenameUnknownSaveAcknowledgementReopensAuthoritativeState(save: Int) async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file(), counter = RenameSaveCounter()
    let hooks = RecoveryHooks(journalHooks: JournalStorageHooks(afterSaveCommit: {
        if counter.next() == save { throw FileOperationFailure.ioFailure }
    }))
    let result = await f.service(hooks).perform(.rename(source: source, name: "after.txt"))
    #expect(result.result.disposition == .failed)
    let id = try #require(result.recordID)
    #expect(await f.service().recover(recordID: id).result.disposition == .succeeded)
    #expect(try Data(contentsOf: source) == Data("original".utf8))
}

@Test func nameRenameDoesNotTraverseFolderAndUnreadableFileFailsClosed() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let folder = f.root.appendingPathComponent("Folder")
    try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
    let fifo = folder.appendingPathComponent("unreadable-special-child")
    #expect(mkfifo(fifo.path, 0o000) == 0)
    let renamed = await f.service().perform(.rename(source: folder, name: "folder"))
    #expect(renamed.result.disposition == .succeeded)
    #expect(await f.service().undo(recordID: try #require(renamed.recordID)).result.disposition == .succeeded)
    let file = try f.file()
    #expect(chmod(file.path, 0o000) == 0)
    let result = await f.service().perform(.rename(source: file, name: "after.txt"))
    #expect(result.result.items.first?.status == .failed(.accessDenied))
    #expect(result.recordID == nil && FileManager().fileExists(atPath: file.path))
}

@Test func nameRenameRefusesOccupiedUndoNameAndChangedParent() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file()
    let result = await f.service().perform(.rename(source: source, name: "after.txt"))
    _ = try f.file(bytes: Data("new occupant".utf8))
    let undo = await f.service().undo(recordID: try #require(result.recordID))
    #expect(undo.result.items.first?.status == .failed(.conflict))
    #expect(try Data(contentsOf: source) == Data("new occupant".utf8))
    let parent = f.root.appendingPathComponent("scope"), held = f.root.appendingPathComponent("held-scope")
    try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
    let child = parent.appendingPathComponent("child")
    try Data("child".utf8).write(to: child)
    let hooks = RecoveryHooks(beforeSync: { _ in
        try FileManager().moveItem(at: parent, to: held)
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
    })
    let movedParent = await f.service(hooks).perform(.rename(source: child, name: "renamed"))
    #expect(movedParent.result.disposition == .failed)
    #expect(try Data(contentsOf: held.appendingPathComponent("renamed")) == Data("child".utf8))
    #expect(try FileManager().contentsOfDirectory(atPath: parent.path).isEmpty)
    #expect(movedParent.result.items.flatMap(\.recoveryURLs).contains(held.appendingPathComponent("renamed")))
}

@Test func nameRenameUndoReportsMovedParentAfterMutation() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let parent = f.root.appendingPathComponent("scope"), held = f.root.appendingPathComponent("held-scope")
    try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
    let child = parent.appendingPathComponent("child")
    try Data("child".utf8).write(to: child)
    let forward = await f.service().perform(.rename(source: child, name: "renamed"))
    let hooks = RecoveryHooks(beforeSync: { _ in
        try FileManager().moveItem(at: parent, to: held)
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
    })
    let result = await f.service(hooks).undo(recordID: try #require(forward.recordID))
    #expect(result.result.disposition == .failed)
    #expect(try Data(contentsOf: held.appendingPathComponent("child")) == Data("child".utf8))
    #expect(try FileManager().contentsOfDirectory(atPath: parent.path).isEmpty)
    #expect(result.result.items.flatMap(\.recoveryURLs).contains(held.appendingPathComponent("child")))
    #expect(try f.record(#require(forward.recordID)).locations.contains(held.appendingPathComponent("child")))
}

@Test func nameRenameRejectsMixedProtocolAndPhaseHeaders() async throws {
    let f = try NameRenameFixture(); defer { f.remove() }
    let source = try f.file()
    let result = await f.service().perform(.rename(source: source, name: "after.txt"))
    let record = try f.record(#require(result.recordID))
    var legacy = JournalRecord(version: 1, owner: record.owner, id: UUID(), operation: "Rename")
    legacy.nameRename = record.nameRename
    #expect(throws: FileOperationFailure.recoveryUncertain) { try OperationJournal.validate(legacy) }
    var wrongPhase = record; wrongPhase.state = "preparing"
    #expect(throws: FileOperationFailure.recoveryUncertain) { try OperationJournal.validate(wrongPhase) }
    var mixed = record
    let tree = try verifiedTree(f.root.appendingPathComponent("after.txt"), cancellation: OperationCancellation())
    mixed.steps = [JournalStep(source: source, destination: f.root.appendingPathComponent("after.txt"), sourceParent: tree.identity, destinationParent: tree.identity, before: tree)]
    #expect(throws: FileOperationFailure.recoveryUncertain) { try OperationJournal.validate(mixed) }
}
