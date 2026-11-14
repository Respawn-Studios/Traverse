import Darwin
import ExplorerCore
import Foundation
import Testing
@testable import FileMemory

@Test func b073ExplicitFollowingAndLibraryPaging() async throws {
    guard NameStoreFixture.authoringPacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 3 * 1_024 * 1_024, reservedEntries: 24)
    let source = fixture.child("generated.txt")
    try Data("Generated B07.3 source".utf8).write(to: source, options: .withoutOverwriting)
    await #expect(throws: RememberedReferenceFailure.followingRequired) {
        _ = try await PersistentNameStore.createRemembering(directory: fixture.catalog,
            first: AuthoredNames(nickname: "First"), source: source)
    }
    #expect(!FileManager().fileExists(atPath: fixture.catalog.path))
    var info = stat(); #expect(lstat(source.path, &info) == 0); #expect(info.st_flags & UInt32(UF_TRACKED) == 0)
    let store = try await PersistentNameStore.createRemembering(directory: fixture.catalog,
        first: AuthoredNames(nickname: "First"), source: source, allowDocumentFollowing: true)
    #expect(lstat(source.path, &info) == 0); #expect(info.st_flags & UInt32(UF_TRACKED) != 0)
    let first = try await store.firstItemID()
    #expect(try storedSnapshot(await store.lookup(source: source)!).id == first)
    var ids = [first]
    for index in 0..<70 { ids.append(try await store.apply(store.prepareNew(AuthoredNames(nickname: "Generated \(index)")))) }
    let initial = try await store.library(pageSize: 64)
    let initialIDs = try storedMatches(initial).map(\.item.id)
    #expect(initialIDs == Array(ids.reversed().prefix(64)))
    let remaining = try await store.nextPage(#require(initial.next))
    #expect(try storedMatches(remaining).map(\.item.id) == Array(ids.reversed().dropFirst(64)))
    let stale = try await store.library(pageSize: 1)
    _ = try await store.apply(store.prepareNew(AuthoredNames(nickname: "Newest")))
    await #expect(throws: NameIndexFailure.stalePage) { _ = try await store.nextPage(#require(stale.next)) }
    _ = try await store.finishForget(store.prepareForget(first))
    #expect(lstat(source.path, &info) == 0); #expect(info.st_flags & UInt32(UF_TRACKED) != 0)
    #expect(try await store.lookup(source: source) == nil)
    await store.close()
}

@Test func b073FailedCatalogCreationLeavesFollowingTruthful() async throws {
    guard NameStoreFixture.authoringPacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 2 * 1_024 * 1_024, reservedEntries: 16)
    let source = fixture.child("generated.txt")
    try Data("Generated failed-Save source".utf8).write(to: source, options: .withoutOverwriting)
    try FileManager().createDirectory(at: fixture.catalog, withIntermediateDirectories: false)
    do {
        _ = try await PersistentNameStore.createRemembering(directory: fixture.catalog,
            first: AuthoredNames(nickname: "Not saved"), source: source, allowDocumentFollowing: true)
        Issue.record("An existing empty leaf was adopted")
    } catch { }
    var info = stat(); #expect(lstat(source.path, &info) == 0); #expect(info.st_flags & UInt32(UF_TRACKED) != 0)
    #expect(!FileManager().fileExists(atPath: fixture.catalog.appendingPathComponent("names.sqlite").path))
}

private actor NativeUseHold {
    var entered = false
    var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func markFinished() { finished = true }
}

@Test func b073VerifiedActionKeepsScopeAndForgetDrain() async throws {
    guard NameStoreFixture.authoringPacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 2 * 1_024 * 1_024, reservedEntries: 20)
    let source = fixture.child("generated.txt")
    try Data("Generated access lifetime".utf8).write(to: source, options: .withoutOverwriting)
    let gate = FileActivityGate()
    let store = try await PersistentNameStore.createRemembering(directory: fixture.catalog,
        first: AuthoredNames(nickname: "Held"), source: source, activity: gate, allowDocumentFollowing: true)
    let id = try await store.firstItemID(), hold = NativeUseHold()
    let action = Task { try await store.withVerifiedReference(id) { url in await hold.hold(); return url == source } }
    for _ in 0..<100 where !(await hold.entered) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await hold.entered); #expect(gate.activeCount > 0)
    let request = try store.prepareForget(id)
    let forgetting = Task { let outcome = try await store.finishForget(request); await hold.markFinished(); return outcome }
    try await Task.sleep(for: .milliseconds(20)); #expect(!(await hold.finished))
    await hold.release()
    #expect(try await action.value)
    #expect(try await forgetting.value == .forgotten)
    #expect(gate.activeCount == 0)
    await #expect(throws: RememberedReferenceFailure.stale) { _ = try await store.withVerifiedReference(id) { _ in true } }
    await store.close()
}

@Test func b073ConcurrentCloseCallersWaitForNativeDrain() async throws {
    guard NameStoreFixture.authoringPacket else { return }
    let fixture = try NameStoreFixture(reservedBytes: 2 * 1_024 * 1_024, reservedEntries: 20)
    let source = fixture.child("generated.txt")
    try Data("Generated close lifetime".utf8).write(to: source, options: .withoutOverwriting)
    let gate = FileActivityGate(), hold = NativeUseHold()
    let store = try await PersistentNameStore.createRemembering(directory: fixture.catalog,
        first: AuthoredNames(nickname: "Closing"), source: source, activity: gate, allowDocumentFollowing: true)
    let id = try await store.firstItemID()
    let action = Task { try await store.withVerifiedReference(id) { _ in await hold.hold() } }
    for _ in 0..<100 where !(await hold.entered) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await hold.entered)
    let first = Task { await store.close() }
    try await Task.sleep(for: .milliseconds(20))
    let second = Task { await store.close(); await hold.markFinished() }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await hold.finished))
    #expect(gate.activeCount > 0)
    await hold.release(); try await action.value; await first.value; await second.value
    #expect(await hold.finished)
    #expect(gate.activeCount == 0)
    #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .ready)
}
