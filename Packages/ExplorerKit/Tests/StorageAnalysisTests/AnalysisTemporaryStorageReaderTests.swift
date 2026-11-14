import Darwin
import ExplorerCore
import Foundation
import Testing
@testable import StorageAnalysis

private struct PoolFixture: Sendable {
    let root: URL
    init() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let base = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"].map { URL(fileURLWithPath: $0) } ?? repository.appendingPathComponent(".build/test-fixtures")
        guard base.standardizedFileURL.path.hasPrefix(repository.path + "/"), base.resolvingSymlinksInPath().path == base.path else { throw StorageScanFailure.unsupportedLocation }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("analysis-temporary-storage-" + UUID().uuidString)
        try Self.directory(root); try Self.file(root.appendingPathComponent("pool.lock"))
    }
    static func directory(_ url: URL) throws { try FileManager().createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    static func file(_ url: URL, data: Data = Data()) throws {
        guard FileManager().createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw StorageScanFailure.unavailable }
    }
    func session(_ token: String = String(repeating: "a", count: 32), database: Data = Data("not a SQLite database\n".utf8)) throws -> URL {
        let path = root.appendingPathComponent("session-" + token)
        try Self.directory(path); try Self.file(path.appendingPathComponent("result.sqlite"), data: database)
        try Self.file(path.appendingPathComponent("owner.lock")); return path
    }
}
private final class PoolHold: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false, released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func pause() throws {
        condition.lock(); defer { condition.unlock() }; started = true
        while !released { guard condition.wait(until: Date().addingTimeInterval(5)) else { throw StorageScanFailure.unavailable } }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@Suite struct AnalysisTemporaryStorageReaderTests {
    @Test func missingPoolIsNotCreatedAndNonSQLiteFilesAreOnlyObserved() async throws {
        let fixture = try PoolFixture(), gate = FileActivityGate()
        let reader = AnalysisTemporaryStorageReader(activityGate: gate)
        let absent = fixture.root.appendingPathComponent("absent")
        let missing = try await reader.read(directory: absent)
        #expect(!missing.exists && missing.logicalFileBytes == 0 && missing.isComplete)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
        let session = try fixture.session()
        let before = try Data(contentsOf: session.appendingPathComponent("result.sqlite"))
        let value = try await reader.read(directory: fixture.root)
        #expect(value.exists && value.isComplete && value.sessions == 1 && value.unheldSessions == 1 && value.openSessions == 0)
        #expect(value.files == 3 && value.logicalFileBytes == UInt64(before.count) && value.allocatedNameBytes != nil)
        #expect(try Data(contentsOf: session.appendingPathComponent("result.sqlite")) == before)
        #expect(!reader.isBusy && gate.activeCount == 0)
    }
    @Test func heldOwnersAndRollbackJournalsDoNotOpenDatabases() async throws {
        let fixture = try PoolFixture(), gate = FileActivityGate()
        let reader = AnalysisTemporaryStorageReader(activityGate: gate)
        let session = try fixture.session(), journal = session.appendingPathComponent("result.sqlite-journal")
        try PoolFixture.file(journal, data: Data("generated inactive journal".utf8))
        let owner = open(session.appendingPathComponent("owner.lock").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        #expect(owner >= 0); defer { close(owner) }; #expect(flock(owner, LOCK_EX | LOCK_NB) == 0)
        let value = try await reader.read(directory: fixture.root)
        #expect(value.isComplete && value.sessions == 1 && value.openSessions == 1 && value.unheldSessions == 0 && value.files == 4)
        #expect(value.logicalFileBytes == UInt64("not a SQLite database\n".utf8.count + "generated inactive journal".utf8.count))
        #expect(try Data(contentsOf: journal) == Data("generated inactive journal".utf8))
        #expect(gate.activeCount == 0)
    }
    @Test func unexpectedNamesLinksHardlinksAndMissingControlsStayIncomplete() async throws {
        let fixture = try PoolFixture(), reader = AnalysisTemporaryStorageReader(activityGate: FileActivityGate())
        let session = try fixture.session()
        try PoolFixture.file(fixture.root.appendingPathComponent("unrelated"), data: Data(repeating: 7, count: 7))
        try FileManager().createSymbolicLink(at: session.appendingPathComponent("result.sqlite-journal"), withDestinationURL: fixture.root.appendingPathComponent("unrelated"))
        var value = try await reader.read(directory: fixture.root)
        #expect(!value.isComplete && value.gaps[.unexpectedEntry] != nil && value.gaps[.unavailableItem] != nil)
        #expect(value.logicalFileBytes == UInt64("not a SQLite database\n".utf8.count))
        try FileManager().linkItem(at: session.appendingPathComponent("result.sqlite"), to: fixture.root.appendingPathComponent("hardlink"))
        value = try await reader.read(directory: fixture.root)
        #expect(!value.isComplete && value.logicalFileBytes == 0 && value.gaps[.unavailableItem] != nil)
        let orphan = fixture.root.appendingPathComponent("session-" + String(repeating: "b", count: 32)); try PoolFixture.directory(orphan)
        value = try await reader.read(directory: fixture.root)
        #expect(value.gaps[.unavailableLease] != nil)
    }
    @Test func symlinkRootForeignModesAndFIFOControlsRefuseWithoutBlocking() async throws {
        let fixture = try PoolFixture(), reader = AnalysisTemporaryStorageReader(activityGate: FileActivityGate())
        let link = fixture.root.appendingPathComponent("link")
        try FileManager().createSymbolicLink(at: link, withDestinationURL: fixture.root)
        await #expect(throws: StorageScanFailure.self) { try await reader.read(directory: link) }
        let unsafe = fixture.root.appendingPathComponent("unsafe"); try FileManager().createDirectory(at: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        await #expect(throws: StorageScanFailure.self) { try await reader.read(directory: unsafe) }
        let fifo = fixture.root.appendingPathComponent("fifo-pool"); try PoolFixture.directory(fifo)
        #expect(mkfifo(fifo.appendingPathComponent("pool.lock").path, 0o600) == 0)
        await #expect(throws: StorageScanFailure.self) { try await reader.read(directory: fifo) }
    }
    @Test func inventoryIsBoundedAndPoolLockBusyDoesNotBecomeZero() async throws {
        let fixture = try PoolFixture(), gate = FileActivityGate()
        let reader = AnalysisTemporaryStorageReader(activityGate: gate, maximumSessions: 1)
        _ = try fixture.session(); _ = try fixture.session(String(repeating: "b", count: 32))
        let value = try await reader.read(directory: fixture.root)
        #expect(value.sessions <= 1 && !value.isComplete && value.gaps[.sessionLimit] != nil)
        let fd = open(fixture.root.appendingPathComponent("pool.lock").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        #expect(fd >= 0); defer { close(fd) }; #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: StorageScanFailure.busy) { try await reader.read(directory: fixture.root) }
        #expect(gate.activeCount == 0)
    }
    @Test func namespaceReplacementDoesNotRetargetTheInventory() async throws {
        let fixture = try PoolFixture()
        _ = try fixture.session()
        let reader = AnalysisTemporaryStorageReader(activityGate: FileActivityGate(), maximumSessions: 4096, afterInventory: {
            try FileManager().moveItem(at: fixture.root, to: fixture.root.appendingPathExtension("original"))
            try PoolFixture.directory(fixture.root); try PoolFixture.file(fixture.root.appendingPathComponent("pool.lock"))
        })
        await #expect(throws: StorageScanFailure.changed) { try await reader.read(directory: fixture.root) }
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathExtension("original").path))
    }
    @Test func cancellationRetainsActualActivityUntilTheHeldReaderDrains() async throws {
        let fixture = try PoolFixture(), gate = FileActivityGate(), hold = PoolHold()
        let reader = AnalysisTemporaryStorageReader(activityGate: gate, maximumSessions: 4096, afterInventory: { try hold.pause() }); _ = try fixture.session()
        defer { hold.release() }
        let task = Task { try await reader.read(directory: fixture.root) }
        for _ in 0..<200 { if hold.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(hold.entered && gate.activeCount == 1 && reader.isBusy)
        task.cancel(); try await Task.sleep(for: .milliseconds(20))
        #expect(reader.isBusy && gate.activeCount == 1)
        await #expect(throws: StorageScanFailure.busy) { try await reader.read(directory: fixture.root) }
        hold.release(); await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!reader.isBusy && gate.activeCount == 0)
        let value = try await reader.read(directory: fixture.root)
        #expect(value.sessions == 1 && value.isComplete)
    }
}
