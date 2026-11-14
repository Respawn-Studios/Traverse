import Darwin
import ExplorerCore
import Foundation
import SQLite3
import Testing
@testable import FileMemory

private func trackedSource(_ fixture: NameStoreFixture, _ name: String, folder: Bool = false) async throws -> URL {
    let url = fixture.child(name)
    if folder { try FileManager().createDirectory(at: url, withIntermediateDirectories: false) }
    else { try Data("Generated B07 source".utf8).write(to: url, options: .withoutOverwriting) }
    try await NativeDocumentReferenceReader(activity: nil).qualificationEnableTracking(url, cancellation: .init())
    return url
}
func referenceDisplay(_ handle: StoredRememberedReference) throws -> RememberedReferenceDisplay {
    var value: RememberedReferenceDisplay?
    #expect(handle.publish { value = $0 }); return try #require(value)
}

private final class ReferenceBlock: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false
    func hold() { entered.signal(); release.wait() }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func markFinished() { lock.withLock { finished = true } }
    var isFinished: Bool { lock.withLock { finished } }
}

@Test func b07ExactBindingObservationIncludesRecoveryMembersWithoutAdoption() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try MoveFixture(bytes: 4 * 1_024 * 1_024, entries: 32)
    func source(_ name: String, tracked: Bool) async throws -> URL {
        let url = fixture.source.appendingPathComponent(name)
        try Data("Generated ZIP binding fixture".utf8).write(to: url, options: .withoutOverwriting)
        if tracked { try await NativeDocumentReferenceReader(activity: nil).qualificationEnableTracking(url, cancellation: .init()) }
        return url
    }
    let original = try await source("original.zip", tracked: true)
    let reader = NativeDocumentReferenceReader(activity: nil)
    let originalIdentity = try #require(try await reader.currentIdentity(original, cancellation: .init()))
    let store = try await PersistentNameStore.createRemembering(directory: fixture.catalog,
        first: AuthoredNames(nickname: "Generated ZIP"), source: original)
    #expect(try await store.hasCurrentBoundReference(at: original))

    let untracked = try await source("untracked.zip", tracked: false)
    #expect(try await !store.hasCurrentBoundReference(at: untracked))

    let area = fixture.source.appendingPathComponent(".mac-explorer-recovery-" + UUID().uuidString)
    try FileManager().createDirectory(at: area, withIntermediateDirectories: false)
    let displaced = area.appendingPathComponent("displaced")
    let payload = area.appendingPathComponent("payload")
    let extra = area.appendingPathComponent("extra")
    try Data("Generated unsupported recovery leaf".utf8).write(to: extra, options: .withoutOverwriting)
    await #expect(throws: RememberedReferenceFailure.unsupported) {
        _ = try await store.hasCurrentBoundReference(at: extra)
    }
    try FileManager().moveItem(at: original, to: displaced)
    #expect(try await store.hasCurrentBoundReference(at: displaced))
    await #expect(throws: RememberedReferenceFailure.unsupported) {
        _ = try await store.lookup(source: displaced)
    }

    try Data("Generated replacement".utf8).write(to: original, options: .withoutOverwriting)
    // A kernel logical-document ID can transfer to the recreated pathname.
    // Check the catalog against the actual native owner, not an assumed inode
    // lifetime across async worker hops. A distinct-ID occupant still refuses.
    func ownsOriginal(_ identity: NativeDocumentIdentity?) -> Bool {
        identity?.volume == originalIdentity.volume && identity?.document == originalIdentity.document
    }
    let replacementOwnsOriginal = ownsOriginal(try await reader.currentIdentity(original, cancellation: .init()))
    let displacedOwnsOriginal = ownsOriginal(try await reader.currentIdentity(displaced, cancellation: .init()))
    try #require(replacementOwnsOriginal != displacedOwnsOriginal)
    print("B07_REFERENCE_RECREATE_OWNER " + (replacementOwnsOriginal ? "replacement" : "displaced"))
    func checkOriginalMapping(in catalog: PersistentNameStore) async throws {
        if replacementOwnsOriginal {
            #expect(try await catalog.hasCurrentBoundReference(at: original))
        } else {
            await #expect(throws: RememberedReferenceFailure.changed) {
                _ = try await catalog.hasCurrentBoundReference(at: original)
            }
        }
        #expect(try await catalog.hasCurrentBoundReference(at: displaced) == displacedOwnsOriginal)
    }
    try await checkOriginalMapping(in: store)
    try Data("Generated payload".utf8).write(to: payload, options: .withoutOverwriting)
    #expect(try await !store.hasCurrentBoundReference(at: payload))

    let another = try await source("another.zip", tracked: true)
    let proposal = try await store.prepareRemembering(AuthoredNames(nickname: "Another ZIP"), source: another)
    _ = try await store.apply(proposal)
    try FileManager().removeItem(at: payload)
    try FileManager().moveItem(at: another, to: payload)
    #expect(try await store.hasCurrentBoundReference(at: payload))
    await store.close()
    let cold = try await PersistentNameStore.open(directory: fixture.catalog)
    try await checkOriginalMapping(in: cold)
    #expect(try await cold.hasCurrentBoundReference(at: payload))
    await cold.close()
}

@Test func b07ReferenceRemovalAndForgetDrainActualWorkers() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 4 * 1_024 * 1_024, reservedEntries: 24)
    let source = try await trackedSource(fixture, "generated.txt")
    let gate = FileActivityGate()
    let store = try await PersistentNameStore.createRemembering(directory: fixture.catalog,
        first: AuthoredNames(nickname: "Retained label"), source: source, activity: gate)
    let id = try await store.firstItemID(), visible = try await store.resolveReference(id)
    let reader = await store.referenceReader, block = ReferenceBlock()
    reader.qualificationHold = { block.hold() }
    let work = Task { try await store.resolveReference(id) }
    #expect(await Task.detached { block.waitForEntry() }.value)
    #expect(gate.activeCount >= 1)
    let request = try store.prepareRemoveAccess(id)
    #expect(!visible.publish { _ in Issue.record("Removed access republished") })
    let removal = Task {
        let result = try await store.finishRemoveAccess(request); block.markFinished(); return result
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!block.isFinished)
    await #expect(throws: NameStoreFailure.busy) { _ = try await store.prepareRelink(id, source: source) }
    block.release.signal()
    await #expect(throws: RememberedReferenceFailure.stale) { _ = try await work.value }
    #expect(try await removal.value == .removed)
    reader.qualificationHold = nil
    #expect(gate.activeCount == 0)
    #expect(try storedSnapshot(await store.snapshot(id)).names.nickname == "Retained label")
    _ = try await store.apply(store.prepareRelink(id, source: source))
    let secondBlock = ReferenceBlock(); reader.qualificationHold = { secondBlock.hold() }
    let secondWork = Task { try await store.resolveReference(id) }
    #expect(await Task.detached { secondBlock.waitForEntry() }.value)
    let forget = try store.prepareForget(id)
    let finishing = Task { let result = try await store.finishForget(forget); secondBlock.markFinished(); return result }
    try await Task.sleep(for: .milliseconds(20)); #expect(!secondBlock.isFinished)
    secondBlock.release.signal()
    await #expect(throws: RememberedReferenceFailure.stale) { _ = try await secondWork.value }
    #expect(try await finishing.value == .forgotten)
    reader.qualificationHold = nil
    await store.close(); #expect(gate.activeCount == 0)
}

@Test func b07ReferenceCatalogRelinkAndForget() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 4 * 1_024 * 1_024, reservedEntries: 32)
    let source = try await trackedSource(fixture, "source.txt"), target = try await trackedSource(fixture, "target.txt")
    let store = try await PersistentNameStore.createRemembering(directory: fixture.catalog,
        first: AuthoredNames(nickname: "Original nickname", labels: ["private"]), source: source)
    let id = try await store.firstItemID()
    let initial = try await store.resolveReference(id)
    #expect(try referenceDisplay(initial).availability == .available)
    let savedRevision = try storedSnapshot(await store.snapshot(id)).revision
    let pendingNameEdit = try await store.prepareEdit(store.snapshot(id), names: AuthoredNames(nickname: "Original nickname", labels: ["private"]))
    let renamed = fixture.child("renamed.txt")
    try FileManager().moveItem(at: source, to: renamed)
    try await store.refreshVerifiedReference(id)
    #expect(try storedSnapshot(await store.snapshot(id)).revision == savedRevision)
    _ = try await store.apply(pendingNameEdit)
    try FileManager().moveItem(at: renamed, to: source)
    let beforeCancel = try fixture.image()
    let cancelled = try await store.prepareRelink(id, source: target)
    #expect(try await store.preview(cancelled).chosenLocation.path == target.path)
    await store.cancel(cancelled)
    #expect(try fixture.image() == beforeCancel)
    await #expect(throws: RememberedReferenceFailure.stale) { _ = try await store.apply(cancelled) }
    let relink = try await store.prepareRelink(id, source: target)
    #expect(try await store.apply(relink) == id)
    #expect(try await store.resolve(relink) == .saved)
    #expect(!initial.publish { _ in Issue.record("Old reference republished after Relink") })
    #expect(try referenceDisplay(await store.resolveReference(id)).location?.path == target.path)
    #expect(try storedSnapshot(await store.snapshot(id)).names.nickname == "Original nickname")
    let duplicate = try await store.prepareRemembering(AuthoredNames(nickname: "Second"), source: source)
    let second = try await store.apply(duplicate)
    await #expect(throws: RememberedReferenceFailure.alreadyRemembered(second)) { _ = try await store.prepareRelink(id, source: source) }
    let unavailable = try store.prepareRemoveAccess(id)
    #expect(try await store.finishRemoveAccess(unavailable) == .removed)
    #expect(try referenceDisplay(await store.resolveReference(id)).availability == .accessRemoved)
    #expect(try storedMatches(await store.query(RememberedNameQuery(text: "Original nickname", match: .exact))).count == 1)
    await store.close()
    let reopened = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit)
    #expect(try referenceDisplay(await reopened.resolveReference(id)).availability == .accessRemoved)
    let regrant = try await reopened.prepareRelink(id, source: target)
    _ = try await reopened.apply(regrant)
    let visible = try await reopened.resolveReference(id)
    #expect(try referenceDisplay(visible).availability == .available)
    let forget = try reopened.prepareForget(id)
    #expect(!visible.publish { _ in Issue.record("Forgotten location published") })
    #expect(try await reopened.finishForget(forget) == .forgotten)
    await #expect(throws: NameIndexFailure.missingRecord) { _ = try await reopened.resolveReference(id) }
    #expect(try storedSnapshot(await reopened.snapshot(second)).names.nickname == "Second")
    await reopened.close()
    _ = try NameStoreFixture.usage()
}

@Test func b07ReferenceStaleEditAndAtomicFailure() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 4 * 1_024 * 1_024, reservedEntries: 32)
    let a = try await trackedSource(fixture, "a.txt"), b = try await trackedSource(fixture, "b.txt")
    let store = try await PersistentNameStore.createRemembering(directory: fixture.catalog, first: AuthoredNames(nickname: "Before"), source: a)
    let id = try await store.firstItemID(), stale = try await store.prepareRelink(id, source: b)
    let edit = try await store.prepareEdit(store.snapshot(id), names: AuthoredNames(nickname: "Newer edit"))
    _ = try await store.apply(edit)
    await #expect(throws: RememberedReferenceFailure.stale) { _ = try await store.apply(stale) }
    #expect(try storedSnapshot(await store.snapshot(id)).names.nickname == "Newer edit")
    #expect(try referenceDisplay(await store.resolveReference(id)).location?.path == a.path)
    await store.close()
    let failed = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit, probe: {
        if $0 == .referenceRows { throw NameStoreFailure.quota }
    }, vfs: nil)
    let new = try await failed.prepareRemembering(AuthoredNames(nickname: "Never committed"), source: b)
    await #expect(throws: NameStoreFailure.quota) { _ = try await failed.apply(new) }
    #expect(try storedMatches(await failed.query(RememberedNameQuery(text: "Never committed", match: .exact))).isEmpty)
    #expect(try await failed.qualificationStatistics().records == 1)
    await failed.close()
    let cold = try await PersistentNameStore.open(directory: fixture.catalog)
    #expect(try storedSnapshot(await cold.snapshot(id)).names.nickname == "Newer edit")
    await cold.close()
}

@Test func b07ReferenceUpgradeIsExplicit() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 4 * 1_024 * 1_024, reservedEntries: 24)
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Legacy"))
    let id = try await store.firstItemID(); await store.close()
    try fixture.databaseSQL("DROP INDEX active_document_reference; DROP TABLE item_references; UPDATE store_header SET format=1; PRAGMA user_version=1")
    let before = try fixture.image()
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .referenceUpdateRequired)
    #expect(try fixture.image() == before)
    let legacy = try await PersistentNameStore.open(directory: fixture.catalog)
    #expect(try storedSnapshot(await legacy.snapshot(id)).names.nickname == "Legacy")
    await legacy.close(); #expect(try fixture.image() == before)
    let upgraded = try await PersistentNameStore.open(directory: fixture.catalog, action: .upgradeReferences)
    #expect(try referenceDisplay(await upgraded.resolveReference(id)).availability == .needsRelink)
    #expect(try storedSnapshot(await upgraded.snapshot(id)).names.nickname == "Legacy")
    await upgraded.close()
    let finalInspection = await PersistentNameStore.inspect(directory: fixture.catalog)
    #expect(finalInspection.status == .ready)
}

@Test func b07ReferenceLongLocatorUsesItsOwnBound() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 2 * 1_024 * 1_024, reservedEntries: 24)
    var parent = fixture.root
    for index in 0..<3 {
        parent.appendPathComponent("\(index)-" + String(repeating: "x", count: 178))
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
    }
    let source = parent.appendingPathComponent("Café-📁.txt")
    try Data("Generated long-path source".utf8).write(to: source, options: .withoutOverwriting)
    let reader = NativeDocumentReferenceReader(activity: nil)
    try await reader.qualificationEnableTracking(source, cancellation: .init())
    let reference = try await reader.capture(source, cancellation: .init())
    #expect(try reference.reference.encoded().count > 2_048)
    let store = try await PersistentNameStore.createRemembering(directory: fixture.catalog,
        first: AuthoredNames(nickname: "Long locator"), source: source)
    let id = try await store.firstItemID(); await store.close()
    let cold = try await PersistentNameStore.open(directory: fixture.catalog)
    #expect(try referenceDisplay(await cold.resolveReference(id)).availability == .available)
    await cold.close()
}

@Test func b07ReferenceFailedAdmissionReleasesPreparedNames() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 2 * 1_024 * 1_024, reservedEntries: 24)
    let source = try await trackedSource(fixture, "source.txt")
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Kept"))
    let id = try await store.firstItemID()
    let work = try (0..<64).map { _ in try store.references.begin(id) }
    for _ in 0..<70 {
        await #expect(throws: RememberedReferenceFailure.capacity) {
            _ = try await store.prepareRemembering(AuthoredNames(nickname: "Not admitted"), source: source)
        }
    }
    work.forEach { store.references.finish($0) }
    let change = try await store.prepareRemembering(AuthoredNames(nickname: "Admitted later"), source: source)
    let blocking = try (0..<64).map { _ in try store.references.begin(id) }
    await #expect(throws: RememberedReferenceFailure.capacity) { _ = try await store.apply(change) }
    blocking.forEach { store.references.finish($0) }
    var edits: [PreparedNameEdit] = []
    for _ in 0..<64 { edits.append(try await store.prepareNew(AuthoredNames(nickname: "No leaked slot"))) }
    for edit in edits { await store.cancel(edit) }
    await store.close()
}

@Test func b07ReferencePendingPurgeFailureSuspendsWriter() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 2 * 1_024 * 1_024, reservedEntries: 24)
    let source = try await trackedSource(fixture, "source.txt")
    let initial = try await PersistentNameStore.createRemembering(directory: fixture.catalog, first: AuthoredNames(nickname: "Retained"), source: source)
    let id = try await initial.firstItemID(); await initial.close()
    let failure: NameStoreProbe = { if $0 == .accessPurgeRows { throw NameStoreFailure.quota } }
    let store = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit, probe: failure, vfs: nil)
    #expect(try await store.finishRemoveAccess(store.prepareRemoveAccess(id)) == .disabledPending)
    await #expect(throws: NameStoreFailure.recoveryRequired) { _ = try await store.snapshot(id) }
    await store.close()
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .accessRemovalPending)
    let failedRecovery = try await PersistentNameStore.open(directory: fixture.catalog, action: .recover, probe: failure, vfs: nil)
    await #expect(throws: NameStoreFailure.uncertainCommit) { try await failedRecovery.finishPendingAccessRemoval() }
    await #expect(throws: NameStoreFailure.recoveryRequired) { _ = try await failedRecovery.snapshot(id) }
    await failedRecovery.close()
    let recovered = try await PersistentNameStore.open(directory: fixture.catalog, action: .recover)
    try await recovered.finishPendingAccessRemoval()
    #expect(try referenceDisplay(await recovered.resolveReference(id)).availability == .accessRemoved)
    #expect(try storedSnapshot(await recovered.snapshot(id)).names.nickname == "Retained")
    await recovered.close()
}

@Test func b07ReferenceMalformedRowsRefuseWithoutWrites() async throws {
    guard NameStoreFixture.nativePacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 2 * 1_024 * 1_024, reservedEntries: 40)
    let source = try await trackedSource(fixture, "source.txt")
    let invalid = ["UPDATE item_references SET document=1.5", "UPDATE item_references SET evidence=NULL",
                   "UPDATE item_references SET evidence=zeroblob(131073)"]
    for (index, sql) in invalid.enumerated() {
        let directory = fixture.child("invalid-\(index)")
        let store = try await PersistentNameStore.createRemembering(directory: directory, first: AuthoredNames(nickname: "Generated"), source: source)
        await store.close()
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(directory.appendingPathComponent("names.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK); #expect(sqlite3_close(db) == SQLITE_OK)
        let before = try Data(contentsOf: directory.appendingPathComponent("names.sqlite"))
        #expect(await PersistentNameStore.inspect(directory: directory).status == .unsafe)
        do {
            _ = try await PersistentNameStore.open(directory: directory)
            Issue.record("Malformed reference storage opened")
        } catch {
            // SQLite can detect the invalid indexed value during its own
            // integrity check before our typed reference decoder is reached.
            #expect((error as? NameStoreFailure) == .unsafe || (error as? NameIndexFailure) == .storage(SQLITE_CORRUPT))
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("names.sqlite")) == before)
    }
}
