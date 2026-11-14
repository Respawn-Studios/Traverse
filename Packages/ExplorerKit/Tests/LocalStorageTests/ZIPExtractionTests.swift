import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import Testing
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage

private struct ExtractionFixture {
    let root: URL, source: URL, destination: URL, journal: URL
    init(_ members: [GeneratedZIP.Member] = [.init("Folder/Report.txt"), .init("Empty/", mode: 0x4000, bytes: Data())]) throws {
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_EXTRACTION_TEST_ROOT"] else { throw FileOperationFailure.invalidRequest }
        let admitted = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard admitted.lastPathComponent == "source", admitted.resolvingSymlinksInPath() == admitted,
              admitted.deletingLastPathComponent().deletingLastPathComponent() == repo.appendingPathComponent(".build/b09-extraction"),
              UUID(uuidString: admitted.deletingLastPathComponent().lastPathComponent) != nil,
              FileManager().fileExists(atPath: admitted.deletingLastPathComponent().appendingPathComponent("reservation.json").path) else { throw FileOperationFailure.invalidRequest }
        root = admitted.appendingPathComponent(UUID().uuidString); source = root.appendingPathComponent("Generated.zip")
        destination = root.appendingPathComponent("Destination"); journal = root.appendingPathComponent("journal")
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try GeneratedZIP.bytes(members).write(to: source, options: .withoutOverwriting)
    }
    func service(_ hooks: RecoveryHooks = .init(), activity: (@Sendable () throws -> any Sendable)? = nil) -> RecoverableFileOperations {
        .init(journalDirectory: journal, hooks: hooks, activity: activity)
    }
    func plan(_ engine: RecoverableFileOperations, name: String = "Extracted", hooks: ZIPProductionHooks? = nil) async throws -> ArchiveExtractionPlan {
        let selected = try await engine.observeSelection([source])
        if let hooks {
            return try await engine.prepareArchiveExtraction(source: source, parent: destination, name: name, observing: selected) { check in
                try PreparedZIPDirectory(source, check: check, hooks: hooks)
            }
        }
        return try await engine.prepareZIPExtraction(source: source, parent: destination, name: name, observing: selected)
    }
}
private final class ExtractionBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock(); private var used = false
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func once() -> Bool { lock.withLock { if used { return false }; used = true; return true } }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_EXTRACTION_TEST_ROOT"] != nil))
struct ZIPExtractionTests {
    @Test func ordinaryCopyAndCreateKeepTheirExistingVerificationGuards() async throws {
        let f = try ExtractionFixture(), service = f.service(), source = try Data(contentsOf: f.source)
        let copied = await service.perform(.copy(sources: [f.source], destinationDirectory: f.destination))
        #expect(copied.result.disposition == .succeeded)
        #expect(try Data(contentsOf: f.destination.appendingPathComponent("Generated.zip")) == source)
        #expect(await service.undo(recordID: try #require(copied.recordID)).result.disposition == .succeeded)
        let created = await service.perform(.createFolder(parent: f.destination, name: "Ordinary Folder"))
        #expect(created.result.disposition == .succeeded)
        let child = f.destination.appendingPathComponent("Ordinary Folder/User child.txt")
        try Data("preserve child".utf8).write(to: child)
        #expect(await service.undo(recordID: try #require(created.recordID)).result.disposition != .succeeded)
        #expect(try Data(contentsOf: child) == Data("preserve child".utf8))
    }
    @Test func observationalPreparationThenPublishedTreeHasExactUndoAndRetention() async throws {
        let bytes = Data("Generated Unicode 日本語".utf8)
        let f = try ExtractionFixture([try ContentZIP.member("Café/Report.txt", bytes: bytes), .init("Empty/", mode: 0x4000, bytes: Data()), .init("Zero", bytes: Data())])
        let service = f.service(), original = try Data(contentsOf: f.source), plan = try await f.plan(service)
        #expect(plan.files == 2 && plan.folders == 2 && plan.logicalBytes == bytes.count)
        #expect(try !FileManager().fileExists(atPath: f.journal.path) && (try FileManager().contentsOfDirectory(atPath: f.destination.path)).isEmpty)
        let outcome = await service.performArchiveExtraction(plan), id = try #require(outcome.recordID)
        #expect(outcome.result.disposition == .succeeded)
        #expect(try Data(contentsOf: plan.destination.appendingPathComponent("Café/Report.txt")) == bytes)
        #expect(try Data(contentsOf: f.source) == original)
        let history = try await service.inspectExistingHistory()
        #expect(history.records.first?.canUndo == true && history.records.first?.operation == "Extract ZIP")
        #expect(try await service.retentionRecord(recordID: id).canCleanup)
        let cold = f.service(), undone = await cold.undo(recordID: id)
        #expect(undone.result.disposition == .succeeded && !FileManager().fileExists(atPath: plan.destination.path))
        #expect(try await cold.retentionRecord(recordID: id).canCleanup)
        #expect(try Data(contentsOf: f.source) == original)
    }
    @Test func emptyArchiveAndBoundedShortWritesRemainValid() async throws {
        let empty = try ExtractionFixture([]), engine = empty.service(), plan = try await empty.plan(engine)
        let made = await engine.performArchiveExtraction(plan)
        #expect(try made.result.disposition == .succeeded && (try FileManager().contentsOfDirectory(atPath: plan.destination.path)).isEmpty)
        #expect(await engine.undo(recordID: try #require(made.recordID)).result.disposition == .succeeded)
        let bytes = Data((0..<70_003).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let f = try ExtractionFixture([try ContentZIP.member(bytes: bytes)]), service = f.service()
        var hooks = ZIPProductionHooks(); hooks.writeChunk = 7
        let short = try await f.plan(service, hooks: hooks), result = await service.performArchiveExtraction(short)
        #expect(try result.result.disposition == .succeeded && (try Data(contentsOf: short.destination.appendingPathComponent("Generated.txt"))) == bytes)
    }
    @Test func streamedDescriptorsUseTheSameGuardedPublicationAndUndo() async throws {
        let bytes = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0 * 31) })
        for signed in [false, true] {
            for wide in [false, true] {
                let f = try ExtractionFixture(), engine = f.service()
                let archive = try StreamedZIP.bytes(bytes, signed: signed, localWide: wide)
                try archive.write(to: f.source)
                let plan = try await f.plan(engine), outcome = await engine.performArchiveExtraction(plan)
                #expect(outcome.result.disposition == .succeeded)
                #expect(try Data(contentsOf: plan.destination.appendingPathComponent("Streamed.bin")) == bytes)
                #expect(await engine.undo(recordID: try #require(outcome.recordID)).result.disposition == .succeeded)
                #expect(try Data(contentsOf: f.source) == archive)
            }
        }
        let f = try ExtractionFixture(), engine = f.service()
        var bad = try StreamedZIP.bytes(bytes)
        let record = try #require(ContentZIP.records(bad).first)
        bad[Int(record.centralOffset) - 12] ^= 1
        try bad.write(to: f.source)
        await #expect(throws: (any Error).self) { try await f.plan(engine) }
        #expect(try !FileManager().fileExists(atPath: f.journal.path) && (try FileManager().contentsOfDirectory(atPath: f.destination.path)).isEmpty)
    }
    @Test func engineReplayAndChangedSourceOrDestinationRefuseBeforeHistory() async throws {
        let f = try ExtractionFixture(), service = f.service(), plan = try await f.plan(service)
        #expect(await f.service().performArchiveExtraction(plan).result.items.first?.status == .failed(.invalidRequest))
        #expect(await service.performArchiveExtraction(plan).result.disposition == .succeeded)
        #expect(await service.performArchiveExtraction(plan).result.items.first?.status == .failed(.invalidRequest))
        let changed = try ExtractionFixture(), second = changed.service(), stale = try await changed.plan(second)
        try Data("changed".utf8).write(to: changed.source)
        #expect(await second.performArchiveExtraction(stale).result.items.first?.status == .failed(.sourceChanged))
        #expect(!FileManager().fileExists(atPath: changed.journal.path))
        let conflict = try ExtractionFixture(), third = conflict.service(), occupied = try await conflict.plan(third)
        try Data("keep existing".utf8).write(to: occupied.destination)
        #expect(await third.performArchiveExtraction(occupied).result.items.first?.status == .failed(.conflict))
        #expect(try Data(contentsOf: occupied.destination) == Data("keep existing".utf8))
        #expect(!FileManager().fileExists(atPath: conflict.journal.path))
    }
    @Test func unsafeCollidingAndUnsupportedArchivesCreateNoOutputOrHistory() async throws {
        var cases: [[GeneratedZIP.Member]] = [
            [.init("../escape")], [.init("/absolute")], [.init("C:/escape")], [.init("back\\slash")], [.init("a/./b")],
            [.init("Case"), .init("case")], [.init("é"), .init("e\u{301}")], [.init("x"), .init("x/child")],
            [.init("link", mode: 0xa000)], [.init("fifo", mode: 0x1000)], [.init(String(repeating: "a", count: 256))]
        ]
        for flags: UInt16 in [0x0801, 0x0808, 0x0840] { var member = GeneratedZIP.Member("one"); member.flags = flags; cases.append([member]) }
        var unsupported = GeneratedZIP.Member("one"); unsupported.method = 99; cases.append([unsupported])
        for members in cases {
            let f = try ExtractionFixture(members), engine = f.service()
            await #expect(throws: (any Error).self) { try await f.plan(engine) }
            #expect(try !FileManager().fileExists(atPath: f.journal.path) && (try FileManager().contentsOfDirectory(atPath: f.destination.path)).isEmpty)
        }
    }
    @Test func replacedParentAtStagingAdmissionCannotRedirectPrivateWrites() async throws {
        let f = try ExtractionFixture(), retained = f.root.appendingPathComponent("Original Destination")
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, parent in
            guard stage == .admitted else { return }
            try FileManager().moveItem(at: parent, to: retained)
            try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
        }
        let engine = f.service(hooks), plan = try await f.plan(engine)
        let result = await engine.performArchiveExtraction(plan)
        #expect(result.result.items.first?.status == .failed(.destinationChanged))
        #expect(result.recordID == nil && !FileManager().fileExists(atPath: f.journal.path))
        #expect(try FileManager().contentsOfDirectory(atPath: f.destination.path).isEmpty)
        #expect(try FileManager().contentsOfDirectory(atPath: retained.path).isEmpty)
    }
    @Test func quarantinePresenceAndNewQuarantineAfterPreviewRefuseWithoutSecurityWrites() async throws {
        for after in [false, true] {
            let f = try ExtractionFixture(), service = f.service(), plan = after ? try await f.plan(service) : nil
            // Deliberately malformed generated metadata is a refusal control;
            // no quarantine flags are parsed, propagated, cleared or approved.
            let data = Data("generated malformed quarantine".utf8)
            #expect(data.withUnsafeBytes { setxattr(f.source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE) } == 0)
            if let plan { #expect(await service.performArchiveExtraction(plan).result.disposition != .succeeded) }
            else { await #expect(throws: ZIPExtractionFailure.quarantinedOrUncertain) { try await f.plan(service) } }
            #expect(try !FileManager().fileExists(atPath: f.journal.path) && (try FileManager().contentsOfDirectory(atPath: f.destination.path)).isEmpty)
            #expect(getxattr(f.source.path, "com.apple.quarantine", nil, 0, 0, 0) == data.count)
        }
    }
    @Test func corruptBodyAndDiskFailureRetainUnprovenPartialTreesWithoutPublication() async throws {
        for corrupt in [false, true] {
            let f = try ExtractionFixture([.init("Generated.txt", bytes: Data(repeating: 0x42, count: 70_003))])
            if corrupt { var source = try Data(contentsOf: f.source); source[30 + "Generated.txt".utf8.count] ^= 0xff; try source.write(to: f.source) }
            let original = try Data(contentsOf: f.source), service = f.service()
            var faults = ZIPProductionHooks(); faults.writeChunk = 4_096; faults.failAfterBytes = 8_192
            let plan = try await f.plan(service, hooks: corrupt ? nil : faults), result = await service.performArchiveExtraction(plan)
            #expect(result.result.disposition != .succeeded && !FileManager().fileExists(atPath: plan.destination.path))
            if !corrupt { #expect(result.result.items.first?.status == .failed(.outOfSpace)) }
            let id = try #require(result.recordID), retained = try await service.retentionRecord(recordID: id)
            #expect(retained.state == "needsReview" && !retained.canCleanup && !retained.areas.isEmpty)
            #expect(await f.service().recover(recordID: id).result.disposition != .succeeded)
            #expect(try Data(contentsOf: f.source) == original)
        }
    }
    @Test func createdNodeContentAndPostValidationChangesCannotPublish() async throws {
        for stage in [ArchiveProductionHooks.Stage.produced, .receiptsChecked, .validated, .synced] {
            let f = try ExtractionFixture(), original = try Data(contentsOf: f.source)
            var hooks = RecoveryHooks()
            hooks.archiveProduction.stage = { observed, payload in
                if observed == stage { try Data("different".utf8).write(to: payload.appendingPathComponent("Folder/Report.txt")) }
            }
            let service = f.service(hooks), plan = try await f.plan(service), result = await service.performArchiveExtraction(plan)
            #expect(result.result.disposition != .succeeded && !FileManager().fileExists(atPath: plan.destination.path))
            #expect(!(try await service.retentionRecord(recordID: #require(result.recordID))).canCleanup)
            #expect(try Data(contentsOf: f.source) == original)
        }
    }
    @Test func newlyOccupiedPublicationNeverOverwritesAndEditedResultRefusesUndo() async throws {
        let f = try ExtractionFixture(); var hooks = RecoveryHooks()
        hooks.beforeExclusiveRename = { _, destination in try Data("keep this".utf8).write(to: destination, options: .withoutOverwriting) }
        let service = f.service(hooks), plan = try await f.plan(service), result = await service.performArchiveExtraction(plan)
        #expect(try result.result.disposition != .succeeded && (try Data(contentsOf: plan.destination)) == Data("keep this".utf8))
        #expect(await f.service().recover(recordID: try #require(result.recordID)).result.disposition != .succeeded)
        let other = try ExtractionFixture(), engine = other.service(), normal = try await other.plan(engine)
        let made = await engine.performArchiveExtraction(normal)
        try Data("user edit".utf8).write(to: normal.destination.appendingPathComponent("Folder/Report.txt"))
        let undo = await other.service().undo(recordID: try #require(made.recordID))
        #expect(try undo.result.disposition != .succeeded && (try Data(contentsOf: normal.destination.appendingPathComponent("Folder/Report.txt"))) == Data("user edit".utf8))
    }
    @Test func newExternalHardLinkAfterProductionCannotChangeTheAdmittedTreeProof() async throws {
        let f = try ExtractionFixture()
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            if stage == .produced {
                try FileManager().linkItem(at: payload.appendingPathComponent("Folder/Report.txt"), to: f.root.appendingPathComponent("Unexpected link"))
            }
        }
        let service = f.service(hooks), plan = try await f.plan(service), result = await service.performArchiveExtraction(plan)
        #expect(result.result.disposition != .succeeded && !FileManager().fileExists(atPath: plan.destination.path))
        #expect(!(try await service.retentionRecord(recordID: #require(result.recordID))).canCleanup)
        #expect(FileManager().fileExists(atPath: f.root.appendingPathComponent("Unexpected link").path))
    }
    @Test func stopDuringActualWriteKeepsLeaseUntilWorkerDrains() async throws {
        let f = try ExtractionFixture([.init("Large", bytes: Data(repeating: 0x41, count: 196_609))]), gate = FileActivityGate(), barrier = ExtractionBarrier()
        let engine = f.service(activity: { try gate.begin() })
        var hooks = ZIPProductionHooks(); hooks.beforeWrite = { _ in if barrier.once() { barrier.entered.signal(); barrier.release.wait() } }
        let plan = try await f.plan(engine, hooks: hooks), task = Task { await engine.performArchiveExtraction(plan) }
        let entered = await Task.detached { barrier.waitForEntry() }.value
        #expect(entered); defer { barrier.release.signal() }
        task.cancel(); try await Task.sleep(for: .milliseconds(20))
        #expect(gate.activeCount == 1 && engine.pendingWorkerCount == 1)
        barrier.release.signal(); let stopped = await task.value
        #expect(stopped.result.cancellationRequested && stopped.result.disposition != .succeeded)
        #expect(gate.activeCount == 0 && engine.pendingWorkerCount == 0 && !FileManager().fileExists(atPath: plan.destination.path))
    }
}
