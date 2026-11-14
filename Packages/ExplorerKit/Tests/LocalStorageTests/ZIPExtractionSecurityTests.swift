import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import Testing

@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage

private struct SecurityZIPFixture {
    let root: URL, source: URL, parent: URL, journal: URL
    static let quarantine = Data(
        "0081;65000001;MacExplorer-B09-Qualification;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
    init(_ members: [GeneratedZIP.Member] = [.init("Folder/Report.txt"), .init("Empty/", mode: 0x4000, bytes: Data())])
        throws
    {
        let text = try #require(ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_EXTRACTION_TEST_ROOT"])
        let admitted = URL(fileURLWithPath: text)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try #require(
            admitted.lastPathComponent == "source" && admitted.resolvingSymlinksInPath() == admitted
                && admitted.deletingLastPathComponent().deletingLastPathComponent()
                    == repo.appendingPathComponent(".build/b09-extraction")
                && UUID(uuidString: admitted.deletingLastPathComponent().lastPathComponent) != nil)
        root = admitted.appendingPathComponent(UUID().uuidString)
        source = root.appendingPathComponent("Generated.zip")
        parent = root.appendingPathComponent("Destination")
        journal = root.appendingPathComponent("history")
        try FileManager().createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try GeneratedZIP.bytes(members).write(to: source, options: .withoutOverwriting)
        try setQuarantine(Self.quarantine, on: source)
    }
    func engine(_ hooks: RecoveryHooks = .init(), activity: (@Sendable () throws -> any Sendable)? = nil)
        -> RecoverableFileOperations
    {
        .init(journalDirectory: journal, hooks: hooks, activity: activity)
    }
    func plan(
        _ engine: RecoverableFileOperations, selected: ZIPExtractionSelection? = nil,
        hooks: ZIPProductionHooks = .init(inheritsQuarantine: true)
    ) async throws -> ArchiveExtractionPlan {
        try await engine.prepareArchiveExtraction(
            source: source, parent: parent, name: "Extracted", observing: engine.observeSelection([source])
        ) { check in
            try PreparedZIPDirectory(source, selection: selected, check: check, hooks: hooks)
        }
    }
}
private func setQuarantine(_ data: Data, on url: URL, replace: Bool = false) throws {
    let result = data.withUnsafeBytes {
        setxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, replace ? XATTR_REPLACE : XATTR_CREATE)
    }
    try #require(result == 0)
}
private func quarantineBytes(_ url: URL) throws -> Data {
    let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
    try #require(size > 0 && size <= 4096)
    var data = Data(count: size)
    try #require(
        data.withUnsafeMutableBytes { getxattr(url.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
            == size)
    return data
}
private final class SecurityZIPBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false
    func once() -> Bool {
        lock.withLock {
            if used { return false }
            used = true
            return true
        }
    }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_EXTRACTION_TEST_ROOT"] != nil))
struct ZIPExtractionSecurityTests {
    @Test func experimentalWitnessPreservesEveryNodeAndColdUndo() async throws {
        let f = try SecurityZIPFixture()
        let engine = f.engine()
        let original = try Data(contentsOf: f.source)
        let ordinary = try await engine.prepareZIPExtraction(
            source: f.source, parent: f.parent, name: "Ordinary", observing: engine.observeSelection([f.source]))
        #expect(ordinary.files == 1 && ordinary.folders == 2)
        await #expect(throws: ZIPExtractionFailure.quarantinedOrUncertain) {
            try await f.plan(engine, hooks: .init(inheritsQuarantine: false))
        }
        let plan = try await f.plan(engine)
        let made = await engine.performArchiveExtraction(plan)
        #expect(made.result.disposition == .succeeded)
        for path in ["", "Folder", "Folder/Report.txt", "Empty"] {
            #expect(
                try quarantineBytes(path.isEmpty ? plan.destination : plan.destination.appendingPathComponent(path))
                    == SecurityZIPFixture.quarantine)
        }
        #expect(
            try Data(contentsOf: f.source) == original && quarantineBytes(f.source) == SecurityZIPFixture.quarantine)
        #expect(await f.engine().undo(recordID: try #require(made.recordID)).result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: plan.destination.path))
        #expect(try quarantineBytes(f.source) == SecurityZIPFixture.quarantine)
    }
    @Test func selectedMembersInheritSecurityWithoutExtractingOtherPayloads() async throws {
        let f = try SecurityZIPFixture([.init("Keep/Deep/Report.txt"), .init("Other/Unselected.txt")])
        let session = try await ZIPArchiveReader().open(f.source)
        let top = try #require(try await session.page(in: session.root).items.first { $0.name == "Keep" })
        let selected = try await session.selectionForExtraction([top.id])
        let engine = f.engine()
        let plan = try await f.plan(engine, selected: selected)
        let made = await engine.performArchiveExtraction(plan)
        #expect(made.result.disposition == .succeeded && plan.files == 1 && plan.folders == 2)
        for path in ["", "Keep", "Keep/Deep", "Keep/Deep/Report.txt"] {
            #expect(
                try quarantineBytes(path.isEmpty ? plan.destination : plan.destination.appendingPathComponent(path))
                    == SecurityZIPFixture.quarantine)
        }
        #expect(!FileManager().fileExists(atPath: plan.destination.appendingPathComponent("Other").path))
        #expect(await f.engine().undo(recordID: try #require(made.recordID)).result.disposition == .succeeded)
        await session.close()
    }
    @Test func malformedOrOversizedQuarantineNeverCreatesOutputOrHistory() async throws {
        for data in [Data(), Data("generated malformed quarantine".utf8), Data(repeating: 65, count: 4097)] {
            let f = try SecurityZIPFixture()
            let engine = f.engine()
            try setQuarantine(data, on: f.source, replace: true)
            await #expect(throws: (any Error).self) { try await f.plan(engine) }
            #expect(!FileManager().fileExists(atPath: f.journal.path))
            #expect(try FileManager().contentsOfDirectory(atPath: f.parent.path).isEmpty)
        }
    }
    @Test func sourceQuarantineChangeAfterPreviewRefusesBeforeHistory() async throws {
        let f = try SecurityZIPFixture()
        let engine = f.engine()
        let plan = try await f.plan(engine)
        let changed = Data("0081;65000002;Changed-Generated-Agent;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        try setQuarantine(changed, on: f.source, replace: true)
        let result = await engine.performArchiveExtraction(plan)
        #expect(result.result.disposition != .succeeded && result.recordID == nil)
        #expect(
            !FileManager().fileExists(atPath: plan.destination.path)
                && !FileManager().fileExists(atPath: f.journal.path))
        #expect(try quarantineBytes(f.source) == changed)
    }
    @Test func securityWriteFailureAndConflictingMetadataNeverPublishOrOverwrite() async throws {
        for conflict in [false, true] {
            let f = try SecurityZIPFixture()
            let engine = f.engine()
            var hooks = ZIPProductionHooks(inheritsQuarantine: true)
            hooks.beforeSecurityWrite = { _, descriptor in
                if conflict {
                    let bytes = Data("0081;65000003;Other-Generated-Agent;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
                    try #require(
                        bytes.withUnsafeBytes {
                            fsetxattr(descriptor, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE)
                        } == 0)
                } else {
                    throw FileOperationFailure.outOfSpace
                }
            }
            let plan = try await f.plan(engine, hooks: hooks)
            let result = await engine.performArchiveExtraction(plan)
            #expect(result.result.disposition != .succeeded && !FileManager().fileExists(atPath: plan.destination.path))
            #expect(!(try await engine.retentionRecord(recordID: #require(result.recordID))).canCleanup)
            #expect(try quarantineBytes(f.source) == SecurityZIPFixture.quarantine)
        }
    }
    @Test func removedOutputQuarantineRefusesPublicationAndEditedResultRefusesUndo() async throws {
        for stage in [ArchiveProductionHooks.Stage.produced, .receiptsChecked, .synced] {
            let f = try SecurityZIPFixture()
            var hooks = RecoveryHooks()
            hooks.archiveProduction.stage = { observed, payload in
                if stage == observed {
                    try #require(
                        removexattr(payload.appendingPathComponent("Folder/Report.txt").path, "com.apple.quarantine", 0)
                            == 0)
                }
            }
            let engine = f.engine(hooks)
            let plan = try await f.plan(engine)
            let result = await engine.performArchiveExtraction(plan)
            #expect(result.result.disposition != .succeeded && !FileManager().fileExists(atPath: plan.destination.path))
        }
        let f = try SecurityZIPFixture()
        let engine = f.engine()
        let plan = try await f.plan(engine)
        let made = await engine.performArchiveExtraction(plan)
        try #require(made.result.disposition == .succeeded)
        try #require(
            removexattr(plan.destination.appendingPathComponent("Folder/Report.txt").path, "com.apple.quarantine", 0)
                == 0)
        #expect(await f.engine().undo(recordID: try #require(made.recordID)).result.disposition != .succeeded)
        #expect(FileManager().fileExists(atPath: plan.destination.appendingPathComponent("Folder/Report.txt").path))
    }
    @Test func stopDuringSecurityWriteRetainsLeaseUntilActualCompletion() async throws {
        let f = try SecurityZIPFixture()
        let gate = ExplorerCore.FileActivityGate()
        let barrier = SecurityZIPBarrier()
        let engine = f.engine(activity: { try gate.begin() })
        var hooks = ZIPProductionHooks(inheritsQuarantine: true)
        hooks.beforeSecurityWrite = { _, _ in
            if barrier.once() {
                barrier.entered.signal()
                _ = barrier.release.wait(timeout: .now() + 5)
            }
        }
        let plan = try await f.plan(engine, hooks: hooks)
        let task = Task { await engine.performArchiveExtraction(plan) }
        let entered = await Task.detached { barrier.waitForEntry() }.value
        #expect(entered)
        defer { barrier.release.signal() }
        task.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.activeCount == 1 && engine.pendingWorkerCount == 1)
        barrier.release.signal()
        let result = await task.value
        #expect(result.result.disposition != .succeeded && result.result.cancellationRequested)
        #expect(
            gate.activeCount == 0 && engine.pendingWorkerCount == 0
                && !FileManager().fileExists(atPath: plan.destination.path))
    }
}
