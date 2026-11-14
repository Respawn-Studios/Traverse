import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import Testing
@_spi(ApplicationOwnership) @testable import StorageAnalysis

/// Generated APFS fixtures only. No personal root, network or source contents.
struct RetainedFixture {
    let root: URL, state: URL, indexDirectory: URL, pool: URL
    init() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let base = repository.appendingPathComponent(".build/test-fixtures")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("retained-native-" + UUID().uuidString)
        state = root.appendingPathComponent("state")
        indexDirectory = state.appendingPathComponent("retained-analysis")
        pool = root.appendingPathComponent("pool")
        try Self.directory(root); try Self.directory(state); try Self.directory(pool)
        try Self.file(pool.appendingPathComponent("pool.lock"), Data())
    }
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }
    static func file(_ url: URL, _ bytes: Data) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: bytes,
            attributes: [.posixPermissions: 0o600]) else { throw StorageScanFailure.unavailable }
    }
    func record(_ bytes: Data = Data("generated catalog metadata".utf8)) throws -> RetainedAnalysisRecord {
        let id = UUID()
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let catalog = try RetainedAnalysisRecord.Catalog(catalogID: id, bytes: UInt64(bytes.count), sha256: hash)
        let rootRecord = try RetainedAnalysisRecord.Root(locator: root.appendingPathComponent("source").path,
            volume: UUID(), inode: 1, generation: 1,
            birth: RetainedAnalysisRecord.Time(seconds: 1))
        let coverage = try RetainedAnalysisRecord.Coverage(reasonCounts: [UInt64](repeating: 0, count: 12),
            reportedNotices: 0, workerNotices: 0, uncategorizedNotices: 0,
            reasonCountsAreComplete: true, terminalReason: nil)
        return try RetainedAnalysisRecord(catalog: catalog, helperSHA256: String(repeating: "b", count: 64),
            policy: .standard, scope: .single(rootRecord),
            observedFrom: .init(seconds: 1), observedThrough: .init(seconds: 2),
            coverage: coverage, complete: true, committedEntries: 1)
    }
    func catalogDirectory(_ record: RetainedAnalysisRecord, bytes: Data) throws -> URL {
        let folder = pool.appendingPathComponent(record.catalog.sessionChild)
        try Self.directory(folder)
        try Self.file(folder.appendingPathComponent("result.sqlite"), bytes)
        try Self.file(folder.appendingPathComponent("owner.lock"), Data())
        return folder
    }
    func storage(poolByteLimit: UInt64 = 8 << 30) throws -> AnalysisResultStorage {
        try .init(directory: pool, sessionByteLimit: 2 << 30, poolByteLimit: poolByteLimit,
                  retentionStateDirectory: indexDirectory)
    }
}

private struct RepairNoAccess: RecordedAnalysisAccessProvider {
    func acquireSingle(recordedRoot: URL) async throws -> RecordedSingleRootAccess {
        throw StorageScanFailure.accessDenied
    }
    func acquireStartup() async throws -> RecordedStartupRootAccess {
        throw StorageScanFailure.accessDenied
    }
}

@Suite struct RetainedNativeGeneratedFailureTests {
    private func repairOwner(_ fixture: RetainedFixture) throws -> RecordedAnalysisOwner {
        let gate = FileActivityGate()
        let worker = fixture.root.appendingPathComponent("unused-repair-worker")
        return try RecordedAnalysisOwner(scanner: StorageScanner(workerURL: worker, activityGate: gate),
            storage: fixture.storage(), workerURL: worker, activityGate: gate,
            accessProvider: RepairNoAccess())
    }

    @Test func explicitRepairRecoversOnlyAnInterruptedIndexStage() async throws {
        let fixture = try RetainedFixture(), store = RetainedNativeIndexStore(directory: fixture.indexDirectory)
        try await store.bootstrap()
        let stage = fixture.indexDirectory.appendingPathComponent("index.stage")
        try RetainedFixture.file(stage, Data("partial generated stage".utf8))
        let owner = try repairOwner(fixture)
        guard case .needsAttention(.indexRequiresAttention) = await owner.inspectRecorded(),
              case .ready(let records) = await owner.repairSavedAnalyses() else {
            throw StorageScanFailure.changed
        }
        #expect(records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stage.path))
        let canonical = try await store.load().encoded()
        guard case .ready(let alreadyHealthy) = await owner.repairSavedAnalyses() else {
            throw StorageScanFailure.changed
        }
        #expect(alreadyHealthy.isEmpty)
        #expect(try await store.load().encoded() == canonical)
    }

    // These injected failures must not require fault controls in Release code.
    #if DEBUG
    @Test func explicitRepairUsesSealedPublicationIntentAndKeepsUnknownIntent() async throws {
        let fixture = try RetainedFixture(), store = RetainedNativeIndexStore(directory: fixture.indexDirectory)
        try await store.bootstrap()
        let bytes = Data("generated catalog metadata".utf8), record = try fixture.record(bytes)
        let folder = try fixture.catalogDirectory(record, bytes: bytes)
        let proposed = try (await store.load()).publishing(record, expectedEpoch: 0)
        guard case .prepared(let receipt) = await store.preparePublication(
            proposed, expectedEpoch: 0, record: record) else { throw StorageScanFailure.changed }
        await store.setFaultForQualification(.afterStageCreate)
        guard case .indeterminate = await store.commitPreparedPublication(
            proposed, expectedEpoch: 0, receipt: receipt) else { throw StorageScanFailure.changed }
        await store.setFaultForQualification(nil)
        let owner = try repairOwner(fixture)
        guard case .needsAttention(.indexRequiresAttention) = await owner.inspectRecorded(),
              case .ready(let records) = await owner.repairSavedAnalyses() else {
            throw StorageScanFailure.changed
        }
        #expect(records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.indexDirectory.appendingPathComponent("publication.intent").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.indexDirectory.appendingPathComponent("index.stage").path))

        let unknown = try RetainedFixture(), unknownStore = RetainedNativeIndexStore(directory: unknown.indexDirectory)
        try await unknownStore.bootstrap()
        let marker = unknown.indexDirectory.appendingPathComponent("publication.intent")
        let malformed = Data("{".utf8)
        try RetainedFixture.file(marker, malformed)
        let unknownOwner = try repairOwner(unknown)
        guard case .needsAttention(.indexRequiresAttention) = await unknownOwner.repairSavedAnalyses() else {
            throw StorageScanFailure.changed
        }
        #expect(try Data(contentsOf: marker) == malformed)
        await #expect(throws: StorageScanFailure.changed) { _ = try await unknownStore.load() }
    }

    #endif

    private func publish(_ record: RetainedAnalysisRecord,
                         store: RetainedNativeIndexStore) async throws -> RetainedAnalysisIndex {
        let current = try await store.load()
        let proposed = try current.publishing(record, expectedEpoch: current.epoch)
        guard case .prepared(let receipt) = await store.preparePublication(
            proposed, expectedEpoch: current.epoch, record: record),
              case .committed = await store.commitPreparedPublication(
                proposed, expectedEpoch: current.epoch, receipt: receipt) else {
            throw StorageScanFailure.changed
        }
        return proposed
    }

    @Test func oldOrdinaryOwnerOnlyAndEmptyPartialsAreRemovedBeforeNewAdmission() throws {
        let fixture = try RetainedFixture()
        let old = fixture.pool.appendingPathComponent("session-" +
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let empty = fixture.pool.appendingPathComponent("session-" +
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        try RetainedFixture.directory(old)
        try RetainedFixture.directory(empty)
        try RetainedFixture.file(old.appendingPathComponent("owner.lock"), Data())
        let storage = try AnalysisResultStorage(directory: fixture.pool)
        let next = try AnalysisStoreFiles(storage: storage, id: UUID(), activityGate: FileActivityGate())
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        next.discardAndClose()
    }

    @Test func closedVisibleCatalogKeepsFullQuotaReservationAcrossHide() async throws {
        let fixture = try RetainedFixture(), store = RetainedNativeIndexStore(directory: fixture.indexDirectory)
        try await store.bootstrap()
        let bytes = Data("generated catalog metadata".utf8), record = try fixture.record(bytes)
        _ = try fixture.catalogDirectory(record, bytes: bytes)
        let published = try await publish(record, store: store)
        #expect(throws: StorageScanFailure.resourceLimit) {
            _ = try AnalysisStoreFiles(storage: fixture.storage(poolByteLimit: 3 << 30),
                id: UUID(), activityGate: FileActivityGate())
        }
        let hidden = try published.beginningForgetAll(expectedEpoch: 1)
        guard case .committed = await store.commit(hidden, expectedEpoch: 1) else { throw StorageScanFailure.unavailable }
        #expect(throws: StorageScanFailure.resourceLimit) {
            _ = try AnalysisStoreFiles(storage: fixture.storage(poolByteLimit: 3 << 30),
                id: UUID(), activityGate: FileActivityGate())
        }
    }

    #if DEBUG
    @Test func postStageFailureIsIndeterminateAndColdLoadRefuses() async throws {
        let fixture = try RetainedFixture(), store = RetainedNativeIndexStore(directory: fixture.indexDirectory)
        try await store.bootstrap()
        let bytes = Data("generated catalog metadata".utf8), record = try fixture.record(bytes)
        let folder = try fixture.catalogDirectory(record, bytes: bytes)
        let proposed = try (await store.load()).publishing(record, expectedEpoch: 0)
        guard case .prepared(let receipt) = await store.preparePublication(
            proposed, expectedEpoch: 0, record: record) else { throw StorageScanFailure.changed }
        await store.setFaultForQualification(.afterStageCreate)
        let outcome = await store.commitPreparedPublication(proposed, expectedEpoch: 0, receipt: receipt)
        var indeterminate = false
        if case .indeterminate = outcome { indeterminate = true }
        #expect(indeterminate)
        await #expect(throws: StorageScanFailure.changed) { try await store.load() }
        #expect(throws: StorageScanFailure.resourceLimit) {
            _ = try AnalysisStoreFiles(storage: fixture.storage(poolByteLimit: 3 << 30),
                id: UUID(), activityGate: FileActivityGate())
        }
        #expect(FileManager.default.fileExists(atPath: fixture.indexDirectory.appendingPathComponent("index.stage").path))
        await store.setFaultForQualification(nil)
        let recovered = try await store.recoverInterruptedPublication(poolURL: fixture.pool,
            quota: 2 << 30, activityGate: FileActivityGate())
        #expect(recovered.visibleRecords.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.indexDirectory.appendingPathComponent("index.stage").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.indexDirectory.appendingPathComponent("publication.intent").path))
    }

    @Test func committedRenameWithLingeringIntentKeepsTheExactCatalog() async throws {
        let fixture = try RetainedFixture(), store = RetainedNativeIndexStore(directory: fixture.indexDirectory)
        try await store.bootstrap()
        let bytes = Data("generated catalog metadata".utf8), record = try fixture.record(bytes)
        let folder = try fixture.catalogDirectory(record, bytes: bytes)
        let proposed = try (await store.load()).publishing(record, expectedEpoch: 0)
        guard case .prepared(let receipt) = await store.preparePublication(
            proposed, expectedEpoch: 0, record: record) else { throw StorageScanFailure.changed }
        await store.setFaultForQualification(.afterRename)
        guard case .indeterminate = await store.commitPreparedPublication(
            proposed, expectedEpoch: 0, receipt: receipt) else { throw StorageScanFailure.changed }
        await #expect(throws: StorageScanFailure.changed) { try await store.load() }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        await store.setFaultForQualification(nil)
        let recovered = try await store.recoverInterruptedPublication(poolURL: fixture.pool,
            quota: 2 << 30, activityGate: FileActivityGate())
        let recoveredBytes = try recovered.encoded(), proposedBytes = try proposed.encoded()
        #expect(recoveredBytes == proposedBytes)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.indexDirectory.appendingPathComponent("publication.intent").path))
    }

    #endif

    @Test func truncatedPublicationIntentRefusesWithoutDeletingCatalog() async throws {
        let fixture = try RetainedFixture(), store = RetainedNativeIndexStore(directory: fixture.indexDirectory)
        try await store.bootstrap()
        let bytes = Data("generated catalog metadata".utf8), record = try fixture.record(bytes)
        let folder = try fixture.catalogDirectory(record, bytes: bytes)
        let proposed = try (await store.load()).publishing(record, expectedEpoch: 0)
        guard case .prepared = await store.preparePublication(
            proposed, expectedEpoch: 0, record: record) else { throw StorageScanFailure.changed }
        let marker = fixture.indexDirectory.appendingPathComponent("publication.intent")
        let markerFD = open(marker.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard markerFD >= 0 else { throw StorageScanFailure.changed }
        defer { close(markerFD) }
        let broken = Data("{".utf8)
        guard ftruncate(markerFD, 0) == 0,
              broken.withUnsafeBytes({ Darwin.write(markerFD, $0.baseAddress, $0.count) }) == broken.count,
              fsync(markerFD) == 0 else { throw StorageScanFailure.changed }
        var malformedIntentRefused = false
        do {
            _ = try await store.recoverInterruptedPublication(poolURL: fixture.pool,
                quota: 2 << 30, activityGate: FileActivityGate())
        } catch let error as DecodingError {
            guard case .dataCorrupted = error else { throw error }
            malformedIntentRefused = true
        }
        #expect(malformedIntentRefused)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: marker) == broken)
    }

    #if DEBUG
    @Test func hideFirstPartialUnlinkPreservesChargeAndRecoversExactly() async throws {
        let fixture = try RetainedFixture(), store = RetainedNativeIndexStore(directory: fixture.indexDirectory)
        try await store.bootstrap()
        let bytes = Data("generated catalog metadata".utf8), record = try fixture.record(bytes)
        let folder = try fixture.catalogDirectory(record, bytes: bytes)
        let published = try await publish(record, store: store)
        let hidden = try published.beginningForgetAll(expectedEpoch: 1)
        guard case .committed = await store.commit(hidden, expectedEpoch: 1) else { throw StorageScanFailure.unavailable }
        await store.setFaultForQualification(.afterDatabaseUnlink)
        let receipt = await store.cleanup(record.catalog, expectedEpoch: 2, poolURL: fixture.pool,
            quota: 2 << 30, activityGate: FileActivityGate())
        var exactPartial = false
        if case .partialUncertain(let catalog, let database, let lock, let directory) = receipt {
            exactPartial = catalog == record.catalog && database && !lock && !directory
        }
        #expect(exactPartial)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("result.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("owner.lock").path))
        #expect((try await store.load()).pendingForget.map(\.catalog) == [record.catalog])
        #expect(throws: StorageScanFailure.resourceLimit) {
            _ = try AnalysisStoreFiles(storage: fixture.storage(poolByteLimit: 3 << 30),
                id: UUID(), activityGate: FileActivityGate())
        }
        await store.setFaultForQualification(nil)
        guard case .removed(let recovered) = await store.cleanup(record.catalog, expectedEpoch: 2,
            poolURL: fixture.pool, quota: 2 << 30, activityGate: FileActivityGate()),
            recovered == record.catalog else { throw StorageScanFailure.changed }
        let acknowledged = try hidden.acknowledgingForget(record.catalog, expectedEpoch: 2)
        guard case .committed = await store.commit(acknowledged, expectedEpoch: 2) else {
            throw StorageScanFailure.unavailable
        }
        #expect((try await store.load()).pendingForget.isEmpty)
    }

    @Test func ordinaryAdmissionAfterInterruptedForgetKeepsExactTombstoneOwner() async throws {
        let fixture = try RetainedFixture()
        let gate = FileActivityGate()
        let storage = try fixture.storage(poolByteLimit: 4 << 30)
        try await RecordedAnalysisOwner.prepareSharedPoolForExplicitAnalysis(
            storage: storage, activityGate: gate)
        let store = RetainedNativeIndexStore(directory: fixture.indexDirectory)
        let bytes = Data("generated catalog metadata".utf8)
        let record = try fixture.record(bytes)
        let folder = try fixture.catalogDirectory(record, bytes: bytes)
        let published = try await publish(record, store: store)
        let hidden = try published.beginningForgetAll(expectedEpoch: 1)
        guard case .committed = await store.commit(hidden, expectedEpoch: 1) else {
            throw StorageScanFailure.changed
        }
        await store.setFaultForQualification(.afterDatabaseUnlink)
        guard case .partialUncertain = await store.cleanup(record.catalog, expectedEpoch: 2,
            poolURL: fixture.pool, quota: 2 << 30, activityGate: gate) else {
            throw StorageScanFailure.changed
        }
        await store.setFaultForQualification(nil)

        // An ordinary scan is permitted, including when recording is off, but
        // its pool inventory must retain the hidden catalog's cleanup owner.
        try await RecordedAnalysisOwner.prepareSharedPoolForExplicitAnalysis(
            storage: storage, activityGate: gate)
        let ordinary = try AnalysisStoreFiles(storage: storage, id: UUID(), activityGate: gate)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("owner.lock").path))
        #expect((try await store.load()).pendingForget.map(\.catalog) == [record.catalog])
        ordinary.discardAndClose()
        await AnalysisStoreFiles.waitForScheduledDiscards()
    }

    #endif

    @Test func exactRemovalThenSeparateAcknowledgmentIsDurable() async throws {
        let fixture = try RetainedFixture(), store = RetainedNativeIndexStore(directory: fixture.indexDirectory)
        try await store.bootstrap()
        let bytes = Data("generated catalog metadata".utf8), record = try fixture.record(bytes)
        let folder = try fixture.catalogDirectory(record, bytes: bytes)
        let published = try await publish(record, store: store)
        let hidden = try published.beginningForgetAll(expectedEpoch: 1)
        guard case .committed = await store.commit(hidden, expectedEpoch: 1) else { throw StorageScanFailure.unavailable }
        let receipt = await store.cleanup(record.catalog, expectedEpoch: 2, poolURL: fixture.pool,
            quota: 2 << 30, activityGate: FileActivityGate())
        guard case .removed(let removed) = receipt, removed == record.catalog else { throw StorageScanFailure.changed }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect((try await store.load()).pendingForget.count == 1)
        let acknowledged = try hidden.acknowledgingForget(record.catalog, expectedEpoch: 2)
        guard case .committed = await store.commit(acknowledged, expectedEpoch: 2) else { throw StorageScanFailure.unavailable }
        #expect((try await store.load()).pendingForget.isEmpty)
    }
}
