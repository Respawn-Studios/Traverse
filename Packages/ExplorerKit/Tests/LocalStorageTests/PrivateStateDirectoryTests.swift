import Darwin
import ExplorerCore
import FileOperations
import Foundation
@testable import LocalStorage
import Testing

private struct StateFixture {
    let root: URL
    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent(".build/test-fixtures")
        guard base.standardizedFileURL.path.hasPrefix(repository.path + "/"),
              base.resolvingSymlinksInPath().path == base.path else { throw LocalStorageError.unavailable }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("private-state-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func child(_ name: String) -> URL { root.appendingPathComponent(name) }
}

@Test func firstUseStatePreparationAllowsCopyWithoutSavingAnyPreference() async throws {
    let fixture = try StateFixture()
    let source = fixture.child("Source.txt"), destination = fixture.child("Destination")
    let state = fixture.child("state"), journal = state.appendingPathComponent("history")
    try Data("Generated first-use state regression".utf8).write(to: source, options: .withoutOverwriting)
    try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
    let engine = RecoverableFileOperations(journalDirectory: journal)
    let inspection = try await engine.inspectExistingHistory()
    #expect(inspection.readiness == .absent)
    #expect(!FileManager().fileExists(atPath: state.path))
    let observation = try await LocalFileOperations().observeSelection([source])
    try await PrivateStateDirectory(directory: state).prepare()
    let outcome = await engine.perform(.copy(sources: [source], destinationDirectory: destination), observing: observation)
    #expect(outcome.result.disposition == .succeeded)
    #expect(FileManager().fileExists(atPath: destination.appendingPathComponent(source.lastPathComponent).path))
    #expect(FileManager().fileExists(atPath: source.path))
}

@Test func privateStatePreparationIsInertUntilRequestedAndRetainsExistingHistory() async throws {
    let fixture = try StateFixture(), state = fixture.child("state")
    let service = PrivateStateDirectory(directory: state)
    #expect(!FileManager().fileExists(atPath: state.path))
    try await service.prepare()
    var metadata = stat()
    #expect(lstat(state.path, &metadata) == 0)
    #expect(metadata.st_mode & 0o777 == 0o700)
    let marker = state.appendingPathComponent("existing-evidence")
    let data = Data("Generated existing history must remain unchanged".utf8)
    try data.write(to: marker, options: .withoutOverwriting)
    let before = metadata.st_ino
    try await service.prepare()
    #expect(lstat(state.path, &metadata) == 0 && metadata.st_ino == before)
    #expect(try Data(contentsOf: marker) == data)
}

@Test func privateStatePreparationRefusesLinksFilesMissingParentsAndUnsafePermissions() async throws {
    let fixture = try StateFixture(), target = fixture.child("target")
    try FileManager().createDirectory(at: target, withIntermediateDirectories: false)
    let link = fixture.child("link")
    try FileManager().createSymbolicLink(at: link, withDestinationURL: target)
    let file = fixture.child("file")
    try Data("Generated wrong-kind state".utf8).write(to: file, options: .withoutOverwriting)
    let writable = fixture.child("writable")
    try FileManager().createDirectory(at: writable, withIntermediateDirectories: false)
    #expect(chmod(writable.path, 0o777) == 0)
    for state in [link, file, fixture.child("missing/state"), link.appendingPathComponent("state"), writable] {
        await #expect(throws: (any Error).self) { try await PrivateStateDirectory(directory: state).prepare() }
    }
    #expect(!FileManager().fileExists(atPath: fixture.child("missing").path))
    #expect(!FileManager().fileExists(atPath: target.appendingPathComponent("state").path))
    #expect(try Data(contentsOf: file) == Data("Generated wrong-kind state".utf8))
    #expect(chmod(writable.path, 0o700) == 0)
}

@Test func privateStatePreparationRefusesKnownRootReplacementAndDisappearance() async throws {
    let fixture = try StateFixture(), state = fixture.child("state")
    let service = PrivateStateDirectory(directory: state)
    try await service.prepare()
    try FileManager().moveItem(at: state, to: fixture.child("original-state"))
    await #expect(throws: StateDirectoryPreparationError.changed) { try await service.prepare() }
    #expect(!FileManager().fileExists(atPath: state.path))
    try FileManager().createDirectory(at: state, withIntermediateDirectories: false)
    await #expect(throws: StateDirectoryPreparationError.changed) { try await service.prepare() }
}

@Test func privateStatePreparationPreservesOwned755AndRejectsReplacedParent() async throws {
    let fixture = try StateFixture(), parent = fixture.child("parent"), state = parent.appendingPathComponent("state")
    try FileManager().createDirectory(at: state, withIntermediateDirectories: true)
    #expect(chmod(state.path, 0o755) == 0)
    let service = PrivateStateDirectory(directory: state)
    try await service.prepare()
    var metadata = stat()
    #expect(lstat(state.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o755)
    try FileManager().moveItem(at: parent, to: fixture.child("original-parent"))
    try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
    await #expect(throws: StateDirectoryPreparationError.changed) { try await service.prepare() }
    #expect(!FileManager().fileExists(atPath: state.path))
}

@Test func privateStatePreparationRechecksNamespaceAndPinsIdentityAfterFailedSync() async throws {
    let fixture = try StateFixture(), state = fixture.child("state")
    let service = PrivateStateDirectory(directory: state) { stage in
        if case .beforeSync = stage { throw StateDirectoryPreparationError.unavailable }
    }
    await #expect(throws: StateDirectoryPreparationError.unavailable) { try await service.prepare() }
    try FileManager().moveItem(at: state, to: fixture.child("original-state"))
    try FileManager().createDirectory(at: state, withIntermediateDirectories: false)
    await #expect(throws: StateDirectoryPreparationError.changed) { try await service.prepare() }
    let changedState = fixture.child("changed-state")
    let changing = PrivateStateDirectory(directory: changedState) { stage in
        if case .created = stage {
            try FileManager().moveItem(at: changedState, to: fixture.child("retained-state"))
            try FileManager().createDirectory(at: changedState, withIntermediateDirectories: false)
        }
    }
    await #expect(throws: StateDirectoryPreparationError.changed) { try await changing.prepare() }
}

private final class StatePreparationGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    private var finished = false
    var hasEntered: Bool { lock.withLock { entered } }
    var hasFinished: Bool { lock.withLock { finished } }
    func enter() {
        let first = lock.withLock { if entered { return false }; entered = true; return true }
        if first { release.wait() }
    }
    func finish() { lock.withLock { finished = true } }
}

@Test func privateStatePreparationCancellationWaitsForWorkerAndReleasesActivity() async throws {
    let fixture = try StateFixture(), gate = StatePreparationGate(), activity = FileActivityGate()
    let service = PrivateStateDirectory(directory: fixture.child("state"), activity: activity) { stage in
        #expect(!Thread.isMainThread)
        if case .beforeSync = stage { gate.enter() }
    }
    let work = Task { defer { gate.finish() }; try await service.prepare() }
    defer { gate.release.signal() }
    for _ in 0..<1_000 {
        if gate.hasEntered { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(gate.hasEntered)
    work.cancel()
    #expect(activity.activeCount == 1 && !gate.hasFinished)
    await #expect(throws: StateDirectoryPreparationError.busy) { try await service.prepare() }
    gate.release.signal()
    await #expect(throws: CancellationError.self) { try await work.value }
    #expect(activity.activeCount == 0 && gate.hasFinished)
    try await service.prepare()
}

@Test func privateStatePreparationAllowsFirstRenameAndNewFolderWithoutPreferences() async throws {
    for createFolder in [false, true] {
        let fixture = try StateFixture(), state = fixture.child("state")
        let source = fixture.child("Source.txt")
        try Data("Generated name-only first use".utf8).write(to: source, options: .withoutOverwriting)
        let engine = RecoverableFileOperations(journalDirectory: state.appendingPathComponent("history"))
        let request: FileOperationRequest = createFolder ? .createFolder(parent: fixture.root, name: "New Folder") : .rename(source: source, name: "Renamed.txt")
        let observation = createFolder ? try await LocalFileOperations().observeDirectory(fixture.root) : try await LocalFileOperations().observeSelection([source])
        try await PrivateStateDirectory(directory: state).prepare()
        let result = await engine.perform(request, observing: observation)
        #expect(result.result.disposition == .succeeded)
    }
}
