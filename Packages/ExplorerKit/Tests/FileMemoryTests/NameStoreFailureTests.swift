import Foundation
import Testing
@testable import FileMemory

@Test(arguments: [NameStoreBoundary.saveRows, .saveCommit])
func privateNamesRollbackAndLostSaveAcknowledgementStayDistinct(_ boundary: NameStoreBoundary) async throws {
    let fixture = try NameStoreFixture()
    let original = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Before"))
    let id = try await original.firstItemID(); await original.close()
    let store = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit, probe: {
        if $0 == boundary { throw NameStoreFailure.unavailable }
    }, vfs: nil)
    let snapshot = try await store.snapshot(id)
    let edit = try await store.prepareEdit(snapshot, names: AuthoredNames(nickname: "After"))
    await #expect(throws: (any Error).self) { try await store.apply(edit) }
    #expect(!snapshot.publish { _ in Issue.record("A pre-edit snapshot was re-published") })
    if boundary == .saveCommit {
        await #expect(throws: NameStoreFailure.recoveryRequired) { try await store.prepareNew(AuthoredNames(nickname: "Must wait")) }
    } else {
        #expect(try storedSnapshot(await store.snapshot(id)).names.nickname == "Before")
    }
    await store.close()
    let reopened = try await PersistentNameStore.open(directory: fixture.catalog, action: .recover)
    #expect(try storedSnapshot(await reopened.snapshot(id)).names.nickname == (boundary == .saveCommit ? "After" : "Before"))
    #expect(try await reopened.resolve(edit) == (boundary == .saveCommit ? .saved : .notCurrent))
    await reopened.close()
}

@Test(arguments: [NameStoreBoundary.revocationRows, .purgeRows])
func privateNamesFailedFenceCannotPromiseDurabilityAndFailedPurgeStaysHidden(_ boundary: NameStoreBoundary) async throws {
    let fixture = try NameStoreFixture()
    let original = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Do not leak"))
    let id = try await original.firstItemID(); await original.close()
    let store = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit, probe: {
        if $0 == boundary { throw NameStoreFailure.unavailable }
    }, vfs: nil)
    let page = try await store.query(RememberedNameQuery(text: "Do not leak"))
    let snapshot = try await store.snapshot(id)
    let request = try store.prepareForget(id)
    let outcome = try await store.finishForget(request)
    #expect(outcome == (boundary == .revocationRows ? .sessionHiddenOnly : .hiddenPending))
    #expect(!page.publish { _ in Issue.record("Withdrawn page leaked") })
    #expect(!snapshot.publish { _ in Issue.record("Withdrawn snapshot leaked") })
    await store.close()
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == (boundary == .revocationRows ? .ready : .forgetPending))
    let reopened = try await PersistentNameStore.open(directory: fixture.catalog, action: .recover)
    if boundary == .revocationRows {
        #expect(try storedSnapshot(await reopened.snapshot(id)).names.nickname == "Do not leak")
    } else {
        await #expect(throws: NameIndexFailure.missingRecord) { try await reopened.snapshot(id) }
        #expect(try await reopened.finishPendingForget() == .forgotten)
        #expect(try await reopened.qualificationStatistics().records == 0)
    }
    await reopened.close()
}

@Test func privateNamesCloseWaitsForUseAndRetainsItsNativeLockUntilDrain() async throws {
    let fixture = try NameStoreFixture()
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "In use"))
    var pages: [StoredNamePage] = []
    for _ in 0..<10 { pages.append(try await store.query(RememberedNameQuery(text: "In use"))) }
    #expect(store.qualificationPayloadCount == 4)
    #expect(!pages[0].publish { _ in Issue.record("Evicted page published") })
    let id = try await store.firstItemID()
    var snapshots: [StoredNameSnapshot] = []
    for _ in 0..<70 { snapshots.append(try await store.snapshot(id)) }
    #expect(store.qualificationPayloadCount == 68)
    #expect(!snapshots[0].publish { _ in Issue.record("Evicted snapshot published") })
    let page = try #require(pages.last)
    var use: RememberedNameUse? = try store.beginUse(page)
    let closing = Task { await store.close() }
    try await Task.sleep(for: .milliseconds(30))
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .busy)
    #expect(!page.publish { _ in Issue.record("Publication after close") })
    withExtendedLifetime(use) {}; use = nil
    await closing.value
    #expect(store.qualificationPayloadCount == 0)
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .ready)
}
