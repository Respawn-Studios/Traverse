import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import Testing
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage

private struct CreationFixture {
    let root: URL, input: URL, folder: URL, file: URL, destination: URL, journal: URL
    var sources: [URL] { [folder, file] }
    init(bytes: Data = Data((0..<4_099).map { UInt8(truncatingIfNeeded: $0 * 31) })) throws {
        if let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_CREATION_TEST_ROOT"] {
            // Explicit historical runs retain their original root admission.
            let admitted = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard admitted.lastPathComponent == "source", admitted.resolvingSymlinksInPath() == admitted,
                  admitted.deletingLastPathComponent().deletingLastPathComponent() == repo.appendingPathComponent(".build/b09-zip-creation"),
                  UUID(uuidString: admitted.deletingLastPathComponent().lastPathComponent) != nil,
                  FileManager().fileExists(atPath: admitted.deletingLastPathComponent().appendingPathComponent("reservation.json").path) else { throw FileOperationFailure.invalidRequest }
            root = admitted.appendingPathComponent(UUID().uuidString)
        } else {
            root = try LocalStorageTestFixtures.directory()
        }
        input = root.appendingPathComponent("Input")
        folder = input.appendingPathComponent("Café 日本語"); file = input.appendingPathComponent("Root.txt")
        destination = root.appendingPathComponent("Destination"); journal = root.appendingPathComponent("journal")
        try FileManager().createDirectory(at: folder.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("Body.bin"), options: .withoutOverwriting)
        try Data().write(to: folder.appendingPathComponent("Zero.txt"), options: .withoutOverwriting)
        try Data("generated root".utf8).write(to: file, options: .withoutOverwriting)
    }
    func service(_ hooks: RecoveryHooks = .init(), activity: (@Sendable () throws -> any Sendable)? = nil) -> RecoverableFileOperations {
        .init(journalDirectory: journal, hooks: hooks, activity: activity)
    }
    func plan(_ service: RecoverableFileOperations, compression: ZIPCompression = .balanced,
              hooks: ZIPCreationHooks? = nil) async throws -> ArchiveCreationPlan {
        let selection = try await service.observeSelection(sources)
        if let hooks {
            return try await service.prepareArchiveCreation(sources: sources, parent: destination, name: "Generated.zip", observing: selection) { check in
                try PreparedZIPFile(sources, compression: compression, check: check, hooks: hooks)
            }
        }
        return try await service.prepareZIPCreation(sources: sources, parent: destination, name: "Generated.zip", compression: compression, observing: selection)
    }
}
private final class CreationBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock(); private var used = false
    func wait() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func once() -> Bool { lock.withLock { if used { return false }; used = true; return true } }
}

@Suite(.serialized)
struct ZIPCreationTests {
    @Test func authoredZIPColdUndoOffersOnlyItsRecordedOutputParent() async throws {
        let f = try CreationFixture(), writer = f.service()
        let plan = try await f.plan(writer)
        let made = await writer.performArchiveCreation(plan)
        #expect(made.result.disposition == .succeeded)
        let id = try #require(made.recordID)
        let before = try #require(try OperationJournal(f.journal).inspectRecord(id))
        #expect(before.version == 3 && before.operation == "Create ZIP" && before.state == "committed")

        let cold = f.service()
        let lead = try #require(try await cold.undoAccessRequirement(recordID: id))
        #expect(lead.recordID == id)
        #expect(lead.directory.standardizedFileURL.pathComponents == f.destination.standardizedFileURL.pathComponents)
        let unchanged = try #require(try OperationJournal(f.journal).inspectRecord(id))
        #expect(unchanged.revision == before.revision && unchanged.state == "committed")
        #expect(await cold.undo(recordID: id).result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: plan.destination.path))
        await #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try await cold.undoAccessRequirement(recordID: id)
        }
    }

    @Test func authoredZIPColdUndoRefusesAnUnboundPrivateAreaWithoutTouchingOutput() async throws {
        let f = try CreationFixture(), writer = f.service()
        let plan = try await f.plan(writer)
        let made = await writer.performArchiveCreation(plan)
        #expect(made.result.disposition == .succeeded)
        let id = try #require(made.recordID)
        let output = try Data(contentsOf: plan.destination)
        do {
            let journal = try OperationJournal(f.journal)
            var record = try #require(try journal.inspectRecord(id))
            let area = try #require(record.areas.first)
            record.areas[0] = JournalArea(
                url: f.destination.appendingPathComponent(".mac-explorer-recovery-" + UUID().uuidString),
                identity: area.identity)
            try journal.saveSnapshot(&record)
        }
        let cold = f.service()
        await #expect(throws: FileOperationFailure.recoveryUncertain) {
            _ = try await cold.undoAccessRequirement(recordID: id)
        }
        #expect(try Data(contentsOf: plan.destination) == output)
    }

    @Test func everyCompressionModeHasExactUnicodeEmptyFolderRoundTripAndColdUndo() async throws {
        for mode in ZIPCompression.allCases {
            let f = try CreationFixture(), service = f.service(), original = try Data(contentsOf: f.folder.appendingPathComponent("Body.bin"))
            let plan = try await f.plan(service, compression: mode)
            #expect(plan.files == 3 && plan.folders == 2 && plan.logicalBytes == original.count + 14)
            #expect(try !FileManager().fileExists(atPath: f.journal.path) && (try FileManager().contentsOfDirectory(atPath: f.destination.path)).isEmpty)
            let result = await service.performArchiveCreation(plan), id = try #require(result.recordID)
            #expect(result.result.disposition == .succeeded)
            let data = try Data(contentsOf: plan.destination), report = try ContentZIP.verify(data)
            #expect(report.files == 3 && report.folders == 2 && report.decodedBytes == plan.logicalBytes)
            let selected = try await service.observeSelection([plan.destination])
            let extraction = try await service.prepareZIPExtraction(source: plan.destination, parent: f.destination, name: "Roundtrip", observing: selected)
            let extracted = await service.performArchiveExtraction(extraction)
            #expect(extracted.result.disposition == .succeeded)
            #expect(try Data(contentsOf: extraction.destination.appendingPathComponent("Café 日本語/Body.bin")) == original)
            #expect(FileManager().fileExists(atPath: extraction.destination.appendingPathComponent("Café 日本語/Empty").path))
            #expect(await service.undo(recordID: try #require(extracted.recordID)).result.disposition == .succeeded)
            #expect(try await service.retentionRecord(recordID: id).canCleanup)
            #expect(await f.service().undo(recordID: id).result.disposition == .succeeded)
            #expect(!FileManager().fileExists(atPath: plan.destination.path))
            #expect(try Data(contentsOf: f.folder.appendingPathComponent("Body.bin")) == original)
        }
        let f = try CreationFixture(), service = f.service(), empty = f.input.appendingPathComponent("Only Empty")
        try FileManager().createDirectory(at: empty, withIntermediateDirectories: false)
        let selected = try await service.observeSelection([empty])
        let plan = try await service.prepareZIPCreation(sources: [empty], parent: f.destination, name: "Empty.zip", observing: selected)
        let result = await service.performArchiveCreation(plan)
        #expect(result.result.disposition == .succeeded)
        let checked = try ContentZIP.verify(Data(contentsOf: plan.destination))
        #expect(checked.files == 0 && checked.folders == 1 && checked.decodedBytes == 0)
    }
    @Test func highCompressionRemainsRoundTripCompatibleWithinAbsoluteBounds() async throws {
        let bytes = Data(repeating: 0, count: 2 * 1_024 * 1_024), f = try CreationFixture(bytes: bytes), service = f.service()
        let plan = try await f.plan(service), result = await service.performArchiveCreation(plan)
        #expect(result.result.disposition == .succeeded)
        #expect(try ContentZIP.verify(Data(contentsOf: plan.destination)).decodedBytes == bytes.count + 14)
    }
    @Test func wrongEngineReplayChangedChildAndOccupiedTargetRefuseWithoutMutation() async throws {
        let f = try CreationFixture(), service = f.service(), plan = try await f.plan(service)
        #expect(await f.service().performArchiveCreation(plan).result.items.first?.status == .failed(.invalidRequest))
        #expect(await service.performArchiveCreation(plan).result.disposition == .succeeded)
        #expect(await service.performArchiveCreation(plan).result.items.first?.status == .failed(.invalidRequest))
        let changed = try CreationFixture(), second = changed.service(), stale = try await changed.plan(second)
        try Data("changed child".utf8).write(to: changed.folder.appendingPathComponent("Body.bin"))
        #expect(await second.performArchiveCreation(stale).result.items.first?.status == .failed(.sourceChanged))
        #expect(!FileManager().fileExists(atPath: changed.journal.path))
        let conflict = try CreationFixture(), third = conflict.service(), occupied = try await conflict.plan(third)
        try Data("keep existing".utf8).write(to: occupied.destination)
        #expect(await third.performArchiveCreation(occupied).result.items.first?.status == .failed(.conflict))
        #expect(try Data(contentsOf: occupied.destination) == Data("keep existing".utf8))
        #expect(!FileManager().fileExists(atPath: conflict.journal.path))
    }
    @Test func sourceOverlapLinksPrivatePathsAndResourceForksRefuseBeforeHistory() async throws {
        for kind in ["link", "hardlink", "privacy", "resource", "quarantine", "unsafe"] {
            let f = try CreationFixture(), service = f.service(), body = f.folder.appendingPathComponent("Body.bin")
            switch kind {
            case "link": try FileManager().createSymbolicLink(at: f.folder.appendingPathComponent("Link"), withDestinationURL: f.file)
            case "hardlink": try FileManager().linkItem(at: body, to: f.input.appendingPathComponent("Extra link"))
            case "privacy": try FileManager().createDirectory(at: f.folder.appendingPathComponent("credentials"), withIntermediateDirectories: false)
            case "unsafe": try Data("generated".utf8).write(to: f.folder.appendingPathComponent("Back\\slash"))
            default:
                let name = kind == "resource" ? "com.apple.ResourceFork" : "com.apple.quarantine", bytes = Data("generated metadata".utf8)
                #expect(bytes.withUnsafeBytes { setxattr(body.path, name, $0.baseAddress, $0.count, 0, XATTR_CREATE) } == 0)
            }
            await #expect(throws: (any Error).self) { try await f.plan(service) }
            #expect(try !FileManager().fileExists(atPath: f.journal.path) && (try FileManager().contentsOfDirectory(atPath: f.destination.path)).isEmpty)
        }
        let f = try CreationFixture(), service = f.service(), selected = try await service.observeSelection(f.sources)
        await #expect(throws: FileOperationFailure.invalidRequest) {
            try await service.prepareZIPCreation(sources: f.sources, parent: f.folder, name: "Inside.zip", observing: selected)
        }
        #expect(!FileManager().fileExists(atPath: f.journal.path))
    }
    @Test func boundedShortWritesAndActualFailureRetainUnpublishedStaging() async throws {
        for fail in [false, true] {
            let f = try CreationFixture(), service = f.service(), source = try Data(contentsOf: f.folder.appendingPathComponent("Body.bin"))
            var hooks = ZIPCreationHooks(); hooks.writeChunk = 3; hooks.failAfterBytes = fail ? 100 : nil
            let plan = try await f.plan(service, hooks: hooks), result = await service.performArchiveCreation(plan)
            if fail {
                #expect(result.result.items.first?.status == .failed(.outOfSpace) && !FileManager().fileExists(atPath: plan.destination.path))
                let id = try #require(result.recordID), retention = try await service.retentionRecord(recordID: id)
                #expect(!retention.canCleanup && retention.state == "needsReview")
                #expect(await f.service().recover(recordID: id).result.disposition != .succeeded)
            } else {
                let report = try ContentZIP.verify(Data(contentsOf: plan.destination))
                #expect(result.result.disposition == .succeeded && report.files == 3)
            }
            #expect(try Data(contentsOf: f.folder.appendingPathComponent("Body.bin")) == source)
        }
    }
    @Test func corruptionAndNewHardLinkCannotBecomePublishedProducerProof() async throws {
        for afterProducer in [false, true] {
            let f = try CreationFixture()
            var recovery = RecoveryHooks(), producer = ZIPCreationHooks()
            if afterProducer {
                recovery.archiveProduction.stage = { stage, payload in
                    if stage == .produced { try FileManager().linkItem(at: payload, to: f.root.appendingPathComponent("Unexpected link")) }
                }
            } else {
                producer.beforeValidation = { fd in var value: UInt8 = 0; guard pwrite(fd, &value, 1, 0) == 1 else { throw FileOperationFailure.ioFailure } }
            }
            let service = f.service(recovery), plan = try await f.plan(service, hooks: producer), result = await service.performArchiveCreation(plan)
            #expect(result.result.disposition != .succeeded && !FileManager().fileExists(atPath: plan.destination.path))
            #expect(!(try await service.retentionRecord(recordID: #require(result.recordID))).canCleanup)
        }
    }
    @Test func actualSourceReadCancellationRetainsItsWorkerAndLeaseUntilDrain() async throws {
        let f = try CreationFixture(), gate = FileActivityGate(), barrier = CreationBarrier()
        let service = f.service(activity: { try gate.begin() })
        var hooks = ZIPCreationHooks()
        hooks.beforeSourceRead = { _ in if barrier.once() { barrier.entered.signal(); barrier.release.wait() } }
        let plan = try await f.plan(service, hooks: hooks)
        let work = Task { await service.performArchiveCreation(plan) }
        #expect(await Task.detached { barrier.wait() }.value)
        work.cancel(); await Task.yield()
        #expect(gate.activeCount == 1 && service.pendingWorkerCount == 1)
        barrier.release.signal(); let result = await work.value
        #expect(result.result.disposition != .succeeded && !FileManager().fileExists(atPath: plan.destination.path))
        #expect(gate.activeCount == 0 && service.pendingWorkerCount == 0)
    }
    @Test func receiptToVerificationAndPublicationWindowsNeverAcceptChangedOutputs() async throws {
        for stage in [ArchiveProductionHooks.Stage.receiptsChecked, .validated, .synced] {
            let f = try CreationFixture()
            var hooks = RecoveryHooks()
            hooks.archiveProduction.stage = { observed, payload in
                if observed == stage { try FileManager().setAttributes([.posixPermissions: 0o755], ofItemAtPath: payload.path) }
            }
            let engine = f.service(hooks), plan = try await f.plan(engine), result = await engine.performArchiveCreation(plan)
            #expect(result.result.disposition != .succeeded && !FileManager().fileExists(atPath: plan.destination.path))
        }
        let f = try CreationFixture()
        var hooks = RecoveryHooks()
        hooks.beforeExclusiveRename = { _, destination in try Data("preserve occupant".utf8).write(to: destination, options: .withoutOverwriting) }
        let engine = f.service(hooks), plan = try await f.plan(engine), result = await engine.performArchiveCreation(plan)
        #expect(result.result.disposition != .succeeded)
        #expect(try Data(contentsOf: plan.destination) == Data("preserve occupant".utf8))
    }
    @Test func destinationReplacementAndEditedResultKeepExistingFilesProtected() async throws {
        let f = try CreationFixture(), old = f.root.appendingPathComponent("Original destination")
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, parent in
            if stage == .admitted { try FileManager().moveItem(at: parent, to: old); try FileManager().createDirectory(at: parent, withIntermediateDirectories: false) }
        }
        let service = f.service(hooks), plan = try await f.plan(service), result = await service.performArchiveCreation(plan)
        #expect(result.recordID == nil && result.result.items.first?.status == .failed(.destinationChanged))
        #expect(try FileManager().contentsOfDirectory(atPath: f.destination.path).isEmpty)
        let edited = try CreationFixture(), engine = edited.service(), ready = try await edited.plan(engine)
        let completed = await engine.performArchiveCreation(ready)
        try Data("user edited archive".utf8).write(to: ready.destination)
        #expect(await engine.undo(recordID: try #require(completed.recordID)).result.disposition != .succeeded)
        #expect(try Data(contentsOf: ready.destination) == Data("user edited archive".utf8))
    }
    @Test func changedSourceDuringReadAndActualEncodedQuotaRetainOnlyPrivateWork() async throws {
        for changeSource in [false, true] {
            let f = try CreationFixture(), barrier = CreationBarrier(), changed = Data(repeating: 0x42, count: 4_099)
            var hooks = ZIPCreationHooks()
            if changeSource {
                hooks.beforeSourceRead = { url in
                    if url.lastPathComponent == "Body.bin", barrier.once() { try changed.write(to: url) }
                }
            } else { hooks.maximumEncodedBytes = 100 }
            let engine = f.service(), plan = try await f.plan(engine, hooks: hooks), result = await engine.performArchiveCreation(plan)
            #expect(result.result.items.first?.status == .failed(changeSource ? .sourceChanged : .unsupported))
            #expect(!FileManager().fileExists(atPath: plan.destination.path))
            #expect(!(try await engine.retentionRecord(recordID: #require(result.recordID))).canCleanup)
            if changeSource { #expect(try Data(contentsOf: f.folder.appendingPathComponent("Body.bin")) == changed) }
        }
    }
}
