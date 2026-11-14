import Foundation
import ExplorerCore
import LocalStorage
import Testing

private struct MonitorFixture {
    let root: URL
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let base = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"].map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        guard base.path.hasPrefix(repository.path + "/"), base.pathComponents.contains(".build"),
              base.resolvingSymlinksInPath().path == base.path else { throw LocalStorageError.unavailable }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("monitor-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false)
    }
    func remove() throws { try FileManager().removeItem(at: root) }
}

@Test func activityGateTracksWatcherUntilItsDescriptorCloses() async throws {
    let fixture = try MonitorFixture()
    defer { try? fixture.remove() }
    let gate = FileActivityGate()
    let monitor = DirectoryMonitor(activityGate: gate)
    let observation = monitor.observe(fixture.root) { _ in }
    defer { observation.cancel() }
    try #require(await observation.waitUntilStarted())
    #expect(gate.activeCount == 1)
    let token = try #require(gate.closeAdmission())
    observation.cancel()
    await observation.waitUntilStopped()
    #expect(await gate.waitUntilDrained(token))
    #expect(gate.ownsDrainedAdmission(token))
    let refused = monitor.observe(fixture.root) { _ in }
    #expect(!(await refused.waitUntilStarted()))
    await refused.waitUntilStopped()
    #expect(gate.activeCount == 0)
    #expect(gate.reopen(token))
}

private final class MonitorEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DirectoryMonitorEvent] = []
    private var mainThreadDelivery = false
    func record(_ event: DirectoryMonitorEvent) {
        lock.withLock { values.append(event); mainThreadDelivery = mainThreadDelivery || Thread.isMainThread }
    }
    var count: Int { lock.withLock { values.count } }
    var changedCount: Int { lock.withLock { values.filter { if case .changed = $0 { true } else { false } }.count } }
    var invalidatedCount: Int { lock.withLock { values.filter { if case .invalidated = $0 { true } else { false } }.count } }
    var errors: [LocalStorageError] { lock.withLock { values.compactMap { if case .unavailable(let error) = $0 { error } else { nil } } } }
    var deliveredOnMain: Bool { lock.withLock { mainThreadDelivery } }
    func waitForChange(after previous: Int) async throws {
        for _ in 0..<500 {
            if changedCount > previous { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalStorageError.unavailable
    }
    func waitForInvalidation() async throws {
        for _ in 0..<500 {
            if invalidatedCount > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalStorageError.unavailable
    }
}

private final class LeaseReleased: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var released: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}

private final class MonitorLease: Sendable {
    let released: LeaseReleased
    init(_ released: LeaseReleased) { self.released = released }
    deinit { released.mark() }
}

@Test func monitorObservesCreateRenameAndDeleteWithoutPollingDirectoryContents() async throws {
    let fixture = try MonitorFixture()
    defer { try? fixture.remove() }
    let events = MonitorEvents()
    let observation = DirectoryMonitor().observe(fixture.root) { events.record($0) }
    try #require(await observation.waitUntilStarted())
    let file = fixture.root.appendingPathComponent("created.txt")
    let renamed = fixture.root.appendingPathComponent("renamed.txt")
    let beforeCreate = events.changedCount
    try Data("owned fixture".utf8).write(to: file, options: .withoutOverwriting)
    try await events.waitForChange(after: beforeCreate)
    let beforeRename = events.changedCount
    try FileManager().moveItem(at: file, to: renamed)
    try await events.waitForChange(after: beforeRename)
    let beforeDelete = events.changedCount
    try FileManager().removeItem(at: renamed)
    try await events.waitForChange(after: beforeDelete)
    observation.cancel()
    await observation.waitUntilStopped()
    #expect(!events.deliveredOnMain)
    #expect(events.errors.isEmpty)
}

@Test func monitorCancellationStopsCallbacksAndRetainsLeaseUntilWorkerCloses() async throws {
    let fixture = try MonitorFixture()
    defer { try? fixture.remove() }
    let events = MonitorEvents()
    let released = LeaseReleased()
    var lease: MonitorLease? = MonitorLease(released)
    let observation = DirectoryMonitor().observe(fixture.root, retaining: lease) { events.record($0) }
    lease = nil
    try #require(await observation.waitUntilStarted())
    #expect(!released.released)
    observation.cancel()
    await observation.waitUntilStopped()
    #expect(released.released)
    let stoppedCount = events.count
    try Data("after cancellation".utf8).write(to: fixture.root.appendingPathComponent("later.txt"), options: .withoutOverwriting)
    try await Task.sleep(for: .milliseconds(100))
    #expect(events.count == stoppedCount)
    #expect(await observation.waitUntilStarted() == false)
}

@Test func monitorCancelledStartsCannotInstallLateCallbacks() async throws {
    let fixture = try MonitorFixture()
    defer { try? fixture.remove() }
    let monitor = DirectoryMonitor(maximumConcurrentStarts: 1)
    let events = MonitorEvents()
    var observations: [DirectoryObservation] = []
    for _ in 0..<40 {
        let observation = monitor.observe(fixture.root) { events.record($0) }
        observation.cancel()
        observations.append(observation)
    }
    for observation in observations {
        #expect(await observation.waitUntilStarted() == false)
        await observation.waitUntilStopped()
    }
    let stoppedCount = events.count
    try Data().write(to: fixture.root.appendingPathComponent("after-starts.txt"), options: .withoutOverwriting)
    try await Task.sleep(for: .milliseconds(100))
    #expect(events.count == stoppedCount)
}

@Test func monitorUnavailableInputsReportTypedFailureAndFinish() async throws {
    let fixture = try MonitorFixture()
    defer { try? fixture.remove() }
    let regular = fixture.root.appendingPathComponent("regular.txt")
    try Data().write(to: regular, options: .withoutOverwriting)
    for (url, expected) in [(fixture.root.appendingPathComponent("missing"), "missing"), (regular, "notDirectory")] {
        let events = MonitorEvents()
        let observation = DirectoryMonitor().observe(url) { events.record($0) }
        #expect(await observation.waitUntilStarted() == false)
        await observation.waitUntilStopped()
        #expect(events.errors.count == 1)
        if expected == "missing" { #expect(events.errors.contains { if case .notFound = $0 { true } else { false } }) }
        else { #expect(events.errors.contains { if case .notDirectory = $0 { true } else { false } }) }
        #expect(!events.deliveredOnMain)
    }
}

@Test func renamingObservedDirectoryInvalidatesAndReleasesLease() async throws {
    let fixture = try MonitorFixture()
    defer { try? fixture.remove() }
    let watched = fixture.root.appendingPathComponent("watched", isDirectory: true)
    let renamed = fixture.root.appendingPathComponent("renamed", isDirectory: true)
    try FileManager().createDirectory(at: watched, withIntermediateDirectories: false)
    let events = MonitorEvents()
    let released = LeaseReleased()
    var lease: MonitorLease? = MonitorLease(released)
    let observation = DirectoryMonitor().observe(watched, retaining: lease) { events.record($0) }
    lease = nil
    try #require(await observation.waitUntilStarted())
    try FileManager().moveItem(at: watched, to: renamed)
    try await events.waitForInvalidation()
    await observation.waitUntilStopped()
    #expect(events.invalidatedCount == 1)
    #expect(released.released)
}
