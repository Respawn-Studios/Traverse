import Darwin
import ExplorerCore
import Foundation
import Testing
@testable import FileMemory

@Test func privateNamesAbsentInspectionCreatesNothingAndFirstSaveReopensReadOnly() async throws {
    let fixture = try NameStoreFixture()
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .absent)
    #expect(!FileManager().fileExists(atPath: fixture.catalog.path))
    let store = try await PersistentNameStore.create(directory: fixture.catalog,
        first: AuthoredNames(nickname: "Café-Project", alternateNames: ["Personal Alias"], labels: ["Work"]))
    let id = try await store.firstItemID()
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .busy)
    await #expect(throws: NameStoreFailure.busy) { try await PersistentNameStore.open(directory: fixture.catalog, action: .edit) }
    await store.close()
    let before = try fixture.image()
    let inspection = await PersistentNameStore.inspect(directory: fixture.catalog)
    #expect(inspection.status == .ready)
    #expect(inspection.records == 1)
    let reopened = try await PersistentNameStore.open(directory: fixture.catalog)
    let matches = try storedMatches(await reopened.query(RememberedNameQuery(text: "cafe project")))
    #expect(matches.map(\.item.id) == [id])
    #expect(matches.first?.item.names.nickname == "Café-Project")
    await #expect(throws: NameStoreFailure.readOnly) { try await reopened.prepareNew(AuthoredNames(nickname: "Not saved")) }
    await reopened.close()
    #expect(try fixture.image() == before)
}

@Test func privateNamesEditsRemainAtomicAndStaleOrForeignCapturesCannotWrite() async throws {
    let fixture = try NameStoreFixture()
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Old"))
    let snapshot = try await store.snapshot(store.firstItemID())
    let edit = try await store.prepareEdit(snapshot, names: AuthoredNames(nickname: "New", labels: ["Shared"]))
    let stale = try await store.prepareEdit(snapshot, names: AuthoredNames(nickname: "Stale"))
    _ = try await store.apply(edit)
    #expect(try await store.resolve(edit) == .saved)
    await #expect(throws: NameIndexFailure.staleEdit) { try await store.apply(stale) }
    await #expect(throws: NameIndexFailure.staleEdit) { try await store.prepareEdit(snapshot, names: AuthoredNames(nickname: "Old editor")) }
    await store.close()
    let reopened = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit)
    #expect(try await reopened.resolve(edit) == .saved)
    await #expect(throws: NameIndexFailure.staleEdit) { try await reopened.apply(edit) }
    #expect(try storedSnapshot(await reopened.snapshot(snapshot.id)).names.nickname == "New")
    await reopened.close()
}

@Test func privateNamesDurableForgetSuppressesPagesAndPurgesOnlyTheSelectedRecord() async throws {
    let fixture = try NameStoreFixture()
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Withdraw", labels: ["Shared"]))
    let first = try await store.firstItemID()
    let edit = try await store.prepareNew(AuthoredNames(nickname: "Retain", labels: ["Shared"]))
    let second = try await store.apply(edit)
    let stale = try await store.prepareEdit(store.snapshot(first), names: AuthoredNames(nickname: "Resurrect"))
    let page = try await store.query(RememberedNameQuery(text: "Shared"))
    #expect(try storedMatches(page).count == 2)
    let request = try store.prepareForget(first)
    #expect(store.qualificationPayloadCount == 0)
    #expect(!page.publish { _ in Issue.record("A withdrawn page was published") })
    #expect(try await store.finishForget(request) == .forgotten)
    await #expect(throws: NameIndexFailure.staleEdit) { try await store.apply(stale) }
    #expect(try storedMatches(await store.query(RememberedNameQuery(text: "Shared"))).map(\.item.id) == [second])
    let stats = try await store.qualificationStatistics()
    #expect(stats.records == 1 && stats.names == 2)
    await store.close()
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .ready)
    let reopened = try await PersistentNameStore.open(directory: fixture.catalog)
    await #expect(throws: NameIndexFailure.missingRecord) { try await reopened.snapshot(first) }
    #expect(try storedSnapshot(await reopened.snapshot(second)).names.nickname == "Retain")
    await reopened.close()
    let raw = try Data(contentsOf: fixture.catalog.appendingPathComponent("names.sqlite"))
    #expect(raw.range(of: Data("Withdraw".utf8)) == nil)
}

@Test func privateNamesForgetAllFencesPendingNewEditsAndInterruptedPurge() async throws {
    let fixture = try NameStoreFixture()
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Private"))
    let pending = try await store.prepareNew(AuthoredNames(nickname: "Delayed new item"))
    let cancellation = RememberedNameCancellation(); cancellation.cancel()
    let request = try store.prepareForget()
    #expect(try await store.finishForget(request, cancellation: cancellation) == .hiddenPending)
    await #expect(throws: NameStoreFailure.forgetPending) { try await store.query(RememberedNameQuery(text: "Private")) }
    await store.close()
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .forgetPending)
    let reopened = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit)
    #expect(try await reopened.finishPendingForget() == .forgotten)
    await #expect(throws: NameIndexFailure.staleEdit) { try await reopened.apply(pending) }
    let fresh = try await reopened.prepareNew(AuthoredNames(nickname: "Private"))
    let id = try await reopened.apply(fresh)
    #expect(id != pending.itemID)
    await reopened.close()
}

private actor DrainObservation {
    var finished = false
    func mark() { finished = true }
}
@Test func privateNamesForgetWaitsForActualOwnedWorkAndRevokesPublicationImmediately() async throws {
    let fixture = try NameStoreFixture(), activity = FileActivityGate()
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Held"), activity: activity)
    let page = try await store.query(RememberedNameQuery(text: "Held"))
    var use: RememberedNameUse? = try store.beginUse(page)
    let done = DrainObservation(), request = try store.prepareForget(await store.firstItemID())
    let task = Task { let result = try await store.finishForget(request); await done.mark(); return result }
    try await Task.sleep(for: .milliseconds(30))
    #expect(await !done.finished)
    #expect(activity.activeCount > 0)
    #expect(!page.publish { _ in Issue.record("Held stale publication") })
    withExtendedLifetime(use) {}; use = nil
    #expect(try await task.value == .forgotten)
    #expect(await done.finished)
    await store.close(); #expect(activity.activeCount == 0)
}

@Test func privateNamesKnownRuntimeMismatchRequiresExplicitIndexUpdateButCanForget() async throws {
    let fixture = try NameStoreFixture()
    let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Résumé"))
    let id = try await store.firstItemID(); await store.close()
    try fixture.databaseSQL("UPDATE store_header SET runtime='different-qualified-runtime'")
    let before = try fixture.image()
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .indexUpdateRequired)
    #expect(try fixture.image() == before)
    let read = try await PersistentNameStore.open(directory: fixture.catalog)
    await #expect(throws: NameStoreFailure.indexUpdateRequired) { try await read.query(RememberedNameQuery(text: "resume")) }
    await read.close()
    let updated = try await PersistentNameStore.open(directory: fixture.catalog, action: .updateIndex)
    #expect(try storedMatches(await updated.query(RememberedNameQuery(text: "resume"))).map(\.item.id) == [id])
    #expect(try await updated.snapshot(id).revision == 1)
    await updated.close()
    try fixture.databaseSQL("UPDATE store_header SET runtime='another-runtime'")
    let forget = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit)
    let request = try forget.prepareForget(id)
    #expect(try await forget.finishForget(request) == .forgotten)
    await forget.close()
}
