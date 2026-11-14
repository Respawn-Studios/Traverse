import Darwin
import Dispatch
import ExplorerCore
import Foundation
import Testing
@_spi(ApplicationOwnership) @testable import StorageAnalysis

/// Generated scan results exercise the actual file owner, gate and sidecar.
/// Missing explicit helper path leaves these native controls NOT EXERCISED.
@Suite struct RetainedNativeGeneratedAdmissionTests {
    private func helper() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"],
              path.hasPrefix("/"), !path.contains("..") else { throw StorageScanFailure.unavailable }
        return URL(fileURLWithPath: path)
    }
    @Test func admittedLeaseIsExactAndDrainsAfterGateClosure() async throws {
        let gate = FileActivityGate(maximumActivities: 1), foreign = FileActivityGate()
        let token: FileActivityGate.DrainToken
        do {
            let admitted = try gate.begin()
            token = try #require(gate.closeAdmission())
            #expect(try gate.continueOrBegin(admitted) === admitted)
            #expect(throws: FileActivityError.foreignLease) {
                try foreign.continueOrBegin(admitted)
            }
            #expect(throws: FileActivityError.admissionClosed) {
                try gate.continueOrBegin(nil)
            }
        }
        #expect(await gate.waitUntilDrained(token))
        #expect(gate.activeCount == 0)
        #expect(gate.reopen(token))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil))
    func ordinaryPagedScanHasNoRetentionCandidate() async throws {
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated\n".utf8))
        let scanner = StorageScanner(workerURL: try helper(), activityGate: FileActivityGate())
        let ordinary = try AnalysisResultStorage(directory: fixture.pool)
        let session = try scanner.startPaged(root: source, storage: ordinary, retainingAccess: UUID())
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates where update.workerDrained { terminal = update }
        _ = try #require(terminal?.result)
        #expect((await session.drainedRetainedCandidate()).map { _ in true } == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil))
    func ordinaryPagedScanAdmitsAtOneActivity() async throws {
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated\n".utf8))
        let gate = FileActivityGate(maximumActivities: 1)
        let scanner = StorageScanner(workerURL: try helper(), activityGate: gate)
        let session = try scanner.startPaged(root: source,
            storage: AnalysisResultStorage(directory: fixture.pool), retainingAccess: UUID())
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates where update.workerDrained { terminal = update }
        let result = try #require(terminal?.result)
        #expect(gate.activeCount == 0)
        await result.closeAfterRevokingApplicationConsumersAndDrain()
        await AnalysisStoreFiles.waitForScheduledDiscards()
    }

    // Fault/pause controls deliberately do not exist in shipping Release code.
    // Keep ordinary admission and the hook-free cases available in both builds.
    #if DEBUG
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil))
    func ordinaryDiscardAfterActualDatabaseUnlinkRecoversOnNextAdmission() async throws {
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated\n".utf8))
        let helperURL = try helper(), gate = FileActivityGate()
        let ordinary = try AnalysisResultStorage(directory: fixture.pool)
        let scanner = StorageScanner(workerURL: helperURL, activityGate: gate)
        let session = try scanner.startPaged(root: source, storage: ordinary, retainingAccess: UUID())
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates where update.workerDrained { terminal = update }
        let result = try #require(terminal?.result)
        let old = fixture.pool.appendingPathComponent(
            "session-" + result.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        var poolBefore = stat(), folderBefore = stat(), databaseBefore = stat(), leaseBefore = stat()
        guard lstat(fixture.pool.path, &poolBefore) == 0,
              lstat(old.path, &folderBefore) == 0,
              lstat(old.appendingPathComponent("result.sqlite").path, &databaseBefore) == 0,
              lstat(old.appendingPathComponent("owner.lock").path, &leaseBefore) == 0 else {
            throw StorageScanFailure.changed
        }
        AnalysisStoreFiles.setOrdinaryDiscardAfterDatabaseUnlinkFaultForQualification(true)
        await result.closeAfterRevokingApplicationConsumersAndDrain()
        await AnalysisStoreFiles.waitForScheduledDiscards()
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("result.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("owner.lock").path))
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("discard.intent").path))
        let bytes = try Data(contentsOf: old.appendingPathComponent("discard.intent"))
        let intent = try JSONDecoder().decode(AnalysisStoreFiles.OrdinaryDiscardIntent.self, from: bytes)
        let volume = try #require(intent.volumeUUID)
        #expect(intent.format == "traverse-analysis-ordinary-discard-v2")
        // Model a reboot/remount device-number change without performing one:
        // object and stable-volume witnesses remain the same.
        var poolAfter = poolBefore, folderAfter = folderBefore
        var databaseAfter = databaseBefore, leaseAfter = leaseBefore
        poolAfter.st_dev = poolBefore.st_dev &+ 1
        folderAfter.st_dev = poolAfter.st_dev
        databaseAfter.st_dev = poolAfter.st_dev
        leaseAfter.st_dev = poolAfter.st_dev
        #expect(folderAfter.st_dev == poolAfter.st_dev)
        #expect(databaseAfter.st_dev == folderAfter.st_dev && leaseAfter.st_dev == folderAfter.st_dev)
        #expect(intent.matchesDirectory(folderAfter, volume: volume))
        #expect(intent.matchesDatabase(databaseAfter) && intent.matchesLease(leaseAfter))
        #expect(!intent.matchesDirectory(folderAfter, volume: UUID())) // Different volume must refuse.
        let next = try AnalysisStoreFiles(storage: ordinary, id: UUID(), activityGate: gate)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        next.discardAndClose()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil))
    func nativeCASConflictBeforePublicationIntentKeepsTemporaryPin() async throws {
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated\n".utf8))
        let helperURL = try helper(), gate = FileActivityGate(), storage = try fixture.storage()
        let backend = try RetainedNativeBackend(storage: storage, indexDirectory: fixture.indexDirectory,
            workerURL: helperURL, activityGate: gate, accessProvider: GeneratedRetainedTestAccess(root: source))
        try await backend.bootstrapForGeneratedQualification()
        let scanner = StorageScanner(workerURL: helperURL, activityGate: gate)
        let session = try scanner.startPagedRetainedCandidate(root: source, storage: storage, retainingAccess: UUID())
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates where update.workerDrained { terminal = update }
        let result = try #require(terminal?.result)
        let maybeCandidate = await session.drainedRetainedCandidate()
        let candidate = try #require(maybeCandidate)
        let closed = try #require(gate.closeAdmission())
        #expect(await gate.waitUntilDrained(closed))
        guard case .refused(.busy) = await backend.pinPublication(candidate) else {
            throw StorageScanFailure.changed
        }
        #expect(gate.reopen(closed))
        guard case .pinned(let pin, let record) = await backend.pinPublication(candidate) else {
            throw StorageScanFailure.changed
        }
        guard case .pending = await backend.resolvePin(pin, as: .preserveUncertain) else {
            throw StorageScanFailure.changed // No durable intent yet authorizes preservation.
        }
        let store = RetainedNativeIndexStore(directory: fixture.indexDirectory)
        let initial = try await store.load()
        let proposed = try initial.publishing(record, expectedEpoch: initial.epoch)
        await backend.installBeforePublicationIntentForQualification {
            guard let current = try? await store.load(),
                  let changed = try? current.beginningForgetAll(expectedEpoch: current.epoch) else { return }
            _ = await store.commit(changed, expectedEpoch: current.epoch)
        }
        guard case .notCommitted(let current) = await backend.commitIndex(proposed, expectedEpoch: initial.epoch),
              current.epoch == initial.epoch + 1 else { throw StorageScanFailure.changed }
        guard case .resolved(let received, .temporary) = await backend.resolvePin(pin, as: .temporary),
              received == pin else { throw StorageScanFailure.changed }
        #expect((try await store.load()).visibleRecords.isEmpty)
        #expect(!FileManager.default.fileExists(atPath:
            fixture.indexDirectory.appendingPathComponent("publication.intent").path))
        #expect(result.id == record.catalogID)
        await result.closeAfterRevokingApplicationConsumersAndDrain()
        await AnalysisStoreFiles.waitForScheduledDiscards()
        #expect(!FileManager.default.fileExists(atPath:
            fixture.pool.appendingPathComponent(record.catalog.sessionChild).path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil))
    func nativeCommitLeaseSpansPreservationAndIndexTransaction() async throws {
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated\n".utf8))
        let helperURL = try helper(), gate = FileActivityGate(), storage = try fixture.storage()
        let backend = try RetainedNativeBackend(storage: storage, indexDirectory: fixture.indexDirectory,
            workerURL: helperURL, activityGate: gate, accessProvider: GeneratedRetainedTestAccess(root: source))
        try await backend.bootstrapForGeneratedQualification()
        let scanner = StorageScanner(workerURL: helperURL, activityGate: gate)
        let session = try scanner.startPagedRetainedCandidate(root: source, storage: storage, retainingAccess: UUID())
        for await _ in session.updates {}
        let maybeCandidate = await session.drainedRetainedCandidate()
        let candidate = try #require(maybeCandidate)
        guard case .pinned(let pin, let record) = await backend.pinPublication(candidate) else {
            throw StorageScanFailure.changed
        }
        let initial = try await backend.loadCanonicalIndex()
        let proposed = try initial.publishing(record, expectedEpoch: initial.epoch)
        let latch = RetainedQueryReleaseLatch()
        defer { latch.release.signal() }
        await backend.installAfterPreservationForQualification {
            latch.entered.signal()
            _ = await awaitGeneratedRetainedPermit(latch.release)
        }
        let commit = Task { await backend.commitIndex(proposed, expectedEpoch: initial.epoch) }
        let entered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: latch.entered.wait(timeout: .now() + 5) == .success)
            }
        }
        guard entered else { throw StorageScanFailure.changed }
        let closed = try #require(gate.closeAdmission())
        #expect(gate.activeCount == 1) // The short arm lease has already ended.
        latch.release.signal()
        guard case .committed = await commit.value else { throw StorageScanFailure.changed }
        #expect(await gate.waitUntilDrained(closed))
        #expect(gate.activeCount == 0)
        #expect(gate.reopen(closed))
        guard case .resolved(let actual, .retained(let epoch)) = await backend.resolvePin(
            pin, as: .retained(epoch: proposed.epoch)), actual == pin,
            epoch == proposed.epoch else { throw StorageScanFailure.changed }
        #expect(await backend.closeAllWarmRetaining())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil))
    func gateCloseBeforePreservationDrainsCommittedPublication() async throws {
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated\n".utf8))
        let gate = FileActivityGate(maximumActivities: 1)
        let backend = try RetainedNativeBackend(storage: fixture.storage(),
            indexDirectory: fixture.indexDirectory, workerURL: try helper(),
            activityGate: gate, accessProvider: GeneratedRetainedTestAccess(root: source))
        try await backend.bootstrapForGeneratedQualification()
        let scanner = StorageScanner(workerURL: try helper(), activityGate: gate)
        let session = try scanner.startPagedRetainedCandidate(root: source,
            storage: fixture.storage(), retainingAccess: UUID())
        for await _ in session.updates {}
        let maybeCandidate = await session.drainedRetainedCandidate()
        let candidate = try #require(maybeCandidate)
        guard case .pinned(let pin, let record) = await backend.pinPublication(candidate) else {
            throw StorageScanFailure.changed
        }
        let initial = try await backend.loadCanonicalIndex()
        let proposed = try initial.publishing(record, expectedEpoch: initial.epoch)
        let captured = RetainedDrainTokenBox()
        await backend.installBeforePublicationIntentForQualification {
            captured.set(gate.closeAdmission())
        }
        guard case .committed = await backend.commitIndex(proposed, expectedEpoch: initial.epoch) else {
            throw StorageScanFailure.changed
        }
        let token = try #require(captured.get())
        #expect(await gate.waitUntilDrained(token))
        #expect(gate.activeCount == 0)
        #expect(gate.reopen(token))
        guard case .resolved(let actual, .retained(let epoch)) =
                await backend.resolvePin(pin, as: .retained(epoch: proposed.epoch)),
              actual == pin, epoch == proposed.epoch else { throw StorageScanFailure.changed }
        #expect(await backend.closeAllWarmRetaining())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil))
    func generatedPostStageFailureKeepsFullReservationUntilExactRecovery() async throws {
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated\n".utf8))
        let helperURL = try helper(), gate = FileActivityGate(maximumActivities: 1), storage = try fixture.storage()
        let backend = try RetainedNativeBackend(storage: storage, indexDirectory: fixture.indexDirectory,
            workerURL: helperURL, activityGate: gate, accessProvider: GeneratedRetainedTestAccess(root: source))
        try await backend.bootstrapForGeneratedQualification()
        let scanner = StorageScanner(workerURL: helperURL, activityGate: gate)
        let session = try scanner.startPagedRetainedCandidate(root: source, storage: storage, retainingAccess: UUID())
        for await _ in session.updates {}
        let maybeCandidate = await session.drainedRetainedCandidate()
        let candidate = try #require(maybeCandidate)
        guard case .pinned(let pin, let record) = await backend.pinPublication(candidate) else {
            throw StorageScanFailure.changed
        }
        let initial = try await backend.loadCanonicalIndex()
        let proposed = try initial.publishing(record, expectedEpoch: initial.epoch)
        await backend.setIndexFaultForQualification(.afterStageCreate)
        guard case .indeterminate = await backend.commitIndex(proposed,
            expectedEpoch: initial.epoch) else { throw StorageScanFailure.changed }
        guard case .resolved(let actual, .preserveUncertain) = await backend.resolvePin(
            pin, as: .preserveUncertain), actual == pin else { throw StorageScanFailure.changed }
        guard await backend.closeAllWarmRetaining() else { throw StorageScanFailure.changed }
        await #expect(throws: StorageScanFailure.changed) { try await backend.loadCanonicalIndex() }
        #expect(throws: StorageScanFailure.resourceLimit) {
            _ = try AnalysisStoreFiles(storage: fixture.storage(poolByteLimit: 3 << 30),
                id: UUID(), activityGate: gate)
        }
        await backend.setIndexFaultForQualification(nil)
        let recovered = try await backend.recoverInterruptedPublication()
        #expect(recovered.visibleRecords.isEmpty)
        #expect(!FileManager.default.fileExists(atPath:
            fixture.pool.appendingPathComponent(record.catalog.sessionChild).path))
        #expect(!FileManager.default.fileExists(atPath:
            fixture.indexDirectory.appendingPathComponent("publication.intent").path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil))
    func nativeCloseJoinsActualQueryWhileActivityAdmissionIsClosed() async throws {
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated\n".utf8))
        let helperURL = try helper(), gate = FileActivityGate(), storage = try fixture.storage()
        let backend = try RetainedNativeBackend(storage: storage, indexDirectory: fixture.indexDirectory,
            workerURL: helperURL, activityGate: gate, accessProvider: GeneratedRetainedTestAccess(root: source))
        try await backend.bootstrapForGeneratedQualification()
        let scanner = StorageScanner(workerURL: helperURL, activityGate: gate)
        let session = try scanner.startPagedRetainedCandidate(root: source, storage: storage, retainingAccess: UUID())
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates where update.workerDrained { terminal = update }
        let result = try #require(terminal?.result)
        let maybeCandidate = await session.drainedRetainedCandidate()
        let candidate = try #require(maybeCandidate)
        let controller = RetainedAnalysisController(initial: try await backend.loadCanonicalIndex(), backend: backend)
        let maybeTicket = await controller.publicationTicket()
        let ticket = try #require(maybeTicket)
        guard case .publication(.committed(_), let allowed, let pending) = await controller.publish(candidate, ticket: ticket),
              allowed, !pending else { throw StorageScanFailure.changed }
        let latch = RetainedQueryReleaseLatch()
        defer { latch.release.signal() }
        try result.installQueryReleaseHookForQualification {
            latch.entered.signal()
            _ = latch.release.wait(timeout: .now() + 5)
        }
        let query = Task { _ = try? await result.summary() }
        let entered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: latch.entered.wait(timeout: .now() + 5) == .success)
            }
        }
        guard entered, result.activeReaderCount == 1 else { throw StorageScanFailure.changed }
        let closed = try #require(gate.closeAdmission())
        let maybeRevocation = await controller.beginRevocation(.retainOnClose)
        let revocation = try #require(maybeRevocation)
        let closeReturned = DispatchSemaphore(value: 0)
        let closing = Task {
            let outcome = await controller.completeRevocation(revocation,
                consumers: RetainedGeneratedNoConsumers())
            closeReturned.signal()
            return outcome
        }
        for _ in 0..<100 {
            if (await controller.snapshot()).hasWork { break }
            await Task.yield()
        }
        #expect((await controller.snapshot()).hasWork)
        let earlyReturn = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: closeReturned.wait(timeout: .now() + .milliseconds(200)) == .success)
            }
        }
        #expect(!earlyReturn)
        #expect(result.activeReaderCount == 1)
        latch.release.signal()
        guard case .coordinationComplete = await closing.value else { throw StorageScanFailure.changed }
        _ = await query.value
        #expect(await gate.waitUntilDrained(closed))
        #expect(gate.activeCount == 0)
    }

    #endif

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil))
    func blockedReadCloseIsJoinedBeforeRetainCloseAndReopen() async throws {
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated\n".utf8))
        let gate = FileActivityGate(), helperURL = try helper(), storage = try fixture.storage()
        let backend = try RetainedNativeBackend(storage: storage, indexDirectory: fixture.indexDirectory,
            workerURL: helperURL, activityGate: gate, accessProvider: GeneratedRetainedTestAccess(root: source))
        try await backend.bootstrapForGeneratedQualification()
        let scanner = StorageScanner(workerURL: helperURL, activityGate: gate)
        let session = try scanner.startPagedRetainedCandidate(root: source, storage: storage, retainingAccess: UUID())
        for await _ in session.updates {}
        let maybeCandidate = await session.drainedRetainedCandidate()
        let candidate = try #require(maybeCandidate)
        let controller = RetainedAnalysisController(initial: try await backend.loadCanonicalIndex(), backend: backend)
        let maybeTicket = await controller.publicationTicket()
        let ticket = try #require(maybeTicket)
        guard case .publication(.committed(_), true, false) =
                await controller.publish(candidate, ticket: ticket) else { throw StorageScanFailure.changed }
        let catalogID = candidate.capture.result.id
        let maybeFirstRevocation = await controller.beginRevocation(.retainOnClose)
        let firstRevocation = try #require(maybeFirstRevocation)
        guard case .coordinationComplete = await controller.completeRevocation(firstRevocation,
            consumers: RetainedGeneratedNoConsumers()) else { throw StorageScanFailure.changed }
        #expect(await controller.resumeAdmissions())
        guard case .opened(let firstHandle) = await controller.openPrevious(catalogID) else {
            throw StorageScanFailure.changed
        }
        let blocked = RetainedBlockingApplicationConsumers()
        defer { blocked.release.signal() }
        let oldClose = Task { await controller.closeRead(catalogID, consumers: blocked) }
        let entered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: blocked.entered.wait(timeout: .now() + 5) == .success)
            }
        }
        guard entered else { throw StorageScanFailure.changed }
        #expect((await controller.snapshot()).hasWork)
        let maybeSecondRevocation = await controller.beginRevocation(.retainOnClose)
        let secondRevocation = try #require(maybeSecondRevocation)
        let returned = DispatchSemaphore(value: 0)
        let revoking = Task {
            let outcome = await controller.completeRevocation(secondRevocation,
                consumers: RetainedGeneratedNoConsumers())
            returned.signal()
            return outcome
        }
        let returnedEarly = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: returned.wait(timeout: .now() + .milliseconds(200)) == .success)
            }
        }
        #expect(!returnedEarly) // The old callback is tracked work and must join.
        blocked.release.signal()
        guard case .refused(.stale) = await oldClose.value else { throw StorageScanFailure.changed }
        guard case .coordinationComplete = await revoking.value else { throw StorageScanFailure.changed }
        #expect(await controller.resumeAdmissions())
        guard case .opened(let newHandle) = await controller.openPrevious(catalogID),
              newHandle != firstHandle else { throw StorageScanFailure.changed }
        #expect((await controller.snapshot()).reads == 1)
        guard case .readClosed = await controller.closeRead(catalogID,
            consumers: RetainedGeneratedNoConsumers()) else { throw StorageScanFailure.changed }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil))
    func replacementRetiresOnlyOldNativeCatalogAfterConsumerDrain() async throws {
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated\n".utf8))
        let helperURL = try helper(), gate = FileActivityGate(), storage = try fixture.storage()
        let backend = try RetainedNativeBackend(storage: storage, indexDirectory: fixture.indexDirectory,
            workerURL: helperURL, activityGate: gate, accessProvider: GeneratedRetainedTestAccess(root: source))
        try await backend.bootstrapForGeneratedQualification()
        let scanner = StorageScanner(workerURL: helperURL, activityGate: gate)
        let first = try scanner.startPagedRetainedCandidate(root: source, storage: storage, retainingAccess: UUID())
        for await _ in first.updates {}
        let maybeFirstCandidate = await first.drainedRetainedCandidate()
        let firstCandidate = try #require(maybeFirstCandidate)
        let controller = RetainedAnalysisController(initial: try await backend.loadCanonicalIndex(), backend: backend)
        let maybeFirstTicket = await controller.publicationTicket()
        let firstTicket = try #require(maybeFirstTicket)
        guard case .publication(.committed(_), true, false) = await controller.publish(firstCandidate,
            ticket: firstTicket) else { throw StorageScanFailure.changed }
        let initial = try await backend.loadCanonicalIndex()
        let old = try #require(initial.visibleRecords.first)
        let second = try scanner.startPagedRetainedCandidate(root: source, storage: storage, retainingAccess: UUID())
        for await _ in second.updates {}
        let maybeSecondCandidate = await second.drainedRetainedCandidate()
        let secondCandidate = try #require(maybeSecondCandidate)
        let maybeSecondTicket = await controller.publicationTicket()
        let secondTicket = try #require(maybeSecondTicket)
        guard case .publication(.committed(_), true, false) = await controller.publish(secondCandidate,
            replacing: old.catalogID, ticket: secondTicket) else { throw StorageScanFailure.changed }
        let replaced = try await backend.loadCanonicalIndex()
        guard replaced.retiring?.catalog == old.catalog,
              let current = replaced.visibleRecords.first,
              current.catalogID != old.catalogID else { throw StorageScanFailure.changed }
        guard case .coordinationComplete = await controller.reconcileRetiring(
            consumers: RetainedGeneratedNoConsumers()) else { throw StorageScanFailure.changed }
        let after = try await backend.loadCanonicalIndex()
        #expect(after.retiring == nil)
        #expect(after.visibleRecords == [current])
        #expect(!FileManager.default.fileExists(atPath: fixture.pool.appendingPathComponent(old.catalog.sessionChild).path))
        #expect(FileManager.default.fileExists(atPath: fixture.pool.appendingPathComponent(current.catalog.sessionChild).path))
        let third = try scanner.startPagedRetainedCandidate(root: source, storage: storage, retainingAccess: UUID())
        for await _ in third.updates {}
        let maybeThirdCandidate = await third.drainedRetainedCandidate()
        let thirdCandidate = try #require(maybeThirdCandidate)
        let maybeThirdTicket = await controller.publicationTicket()
        let thirdTicket = try #require(maybeThirdTicket)
        guard case .publication(.committed(_), true, false) = await controller.publish(thirdCandidate,
            replacing: current.catalogID, ticket: thirdTicket) else { throw StorageScanFailure.changed }
        guard case .coordinationComplete = await controller.reconcileRetiring(
            consumers: RetainedGeneratedNoConsumers()) else { throw StorageScanFailure.changed }
        let final = try await backend.loadCanonicalIndex()
        #expect(final.retiring == nil)
        #expect(final.visibleRecords.count == 1)
        #expect(final.visibleRecords[0].catalogID == thirdCandidate.capture.result.id)
        #expect(!FileManager.default.fileExists(atPath: fixture.pool.appendingPathComponent(current.catalog.sessionChild).path))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_RETAINED_QUAL_HELPER"] != nil))
    func blockedRetirementIsFencedCancelledAndJoinedByForget() async throws {
        let fixture = try RetainedFixture(), source = fixture.root.appendingPathComponent("source")
        try RetainedFixture.directory(source)
        try RetainedFixture.file(source.appendingPathComponent("alpha.txt"), Data("generated\n".utf8))
        let helperURL = try helper(), gate = FileActivityGate(), storage = try fixture.storage()
        let backend = try RetainedNativeBackend(storage: storage, indexDirectory: fixture.indexDirectory,
            workerURL: helperURL, activityGate: gate, accessProvider: GeneratedRetainedTestAccess(root: source))
        try await backend.bootstrapForGeneratedQualification()
        let scanner = StorageScanner(workerURL: helperURL, activityGate: gate)
        let controller = RetainedAnalysisController(initial: try await backend.loadCanonicalIndex(), backend: backend)
        let first = try scanner.startPagedRetainedCandidate(root: source, storage: storage, retainingAccess: UUID())
        for await _ in first.updates {}
        let maybeFirst = await first.drainedRetainedCandidate()
        let firstCandidate = try #require(maybeFirst)
        let maybeFirstTicket = await controller.publicationTicket()
        let firstTicket = try #require(maybeFirstTicket)
        guard case .publication(.committed(_), true, false) = await controller.publish(firstCandidate,
            ticket: firstTicket) else { throw StorageScanFailure.changed }
        let firstIndex = try await backend.loadCanonicalIndex()
        let old = try #require(firstIndex.visibleRecords.first)
        let second = try scanner.startPagedRetainedCandidate(root: source, storage: storage, retainingAccess: UUID())
        for await _ in second.updates {}
        let maybeSecond = await second.drainedRetainedCandidate()
        let secondCandidate = try #require(maybeSecond)
        let maybeSecondTicket = await controller.publicationTicket()
        let secondTicket = try #require(maybeSecondTicket)
        guard case .publication(.committed(_), true, false) = await controller.publish(secondCandidate,
            replacing: old.catalogID, ticket: secondTicket) else { throw StorageScanFailure.changed }
        let blocked = RetainedBlockingRetiredConsumers()
        defer { blocked.release.signal() }
        let retiring = Task { await controller.reconcileRetiring(consumers: blocked) }
        let entered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: blocked.entered.wait(timeout: .now() + 5) == .success)
            }
        }
        guard entered else { throw StorageScanFailure.changed }
        #expect((await controller.snapshot()).hasWork)
        let maybeTicket = await controller.beginRevocation(.forgetAll)
        let ticket = try #require(maybeTicket) // Must succeed while retired consumers are blocked.
        let closing = Task { await controller.completeRevocation(ticket, consumers: RetainedGeneratedNoConsumers()) }
        blocked.release.signal()
        guard case .refused(.cancelled) = await retiring.value else { throw StorageScanFailure.changed }
        guard case .coordinationComplete = await closing.value else { throw StorageScanFailure.changed }
        let final = try await backend.loadCanonicalIndex()
        #expect(final.visibleRecords.isEmpty)
        #expect(final.retiring == nil && final.pendingForget.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.pool.appendingPathComponent(old.catalog.sessionChild).path))
    }
}

private final class RetainedQueryReleaseLatch: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}
private final class RetainedDrainTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: FileActivityGate.DrainToken?
    func set(_ value: FileActivityGate.DrainToken?) { lock.withLock { token = value } }
    func get() -> FileActivityGate.DrainToken? { lock.withLock { token } }
}
private struct RetainedGeneratedNoConsumers: RetainedApplicationConsumerDrain, RetainedRetiredConsumerDrain {
    func revokeAndJoin() async throws {}
    func revokeAndJoin(catalogID: UUID) async throws {}
}

private final class RetainedBlockingApplicationConsumers: RetainedApplicationConsumerDrain, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func revokeAndJoin() async throws {
        entered.signal()
        guard await awaitGeneratedRetainedPermit(release) else { throw StorageScanFailure.unavailable }
    }
}

private final class RetainedBlockingRetiredConsumers: RetainedRetiredConsumerDrain, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func revokeAndJoin(catalogID: UUID) async throws {
        entered.signal()
        guard await awaitGeneratedRetainedPermit(release) else { throw StorageScanFailure.unavailable }
    }
}

private struct GeneratedRetainedTestAccess: RetainedFreshAccessProvider {
    let root: URL
    func acquire(for record: RetainedAnalysisRecord) async throws -> RetainedCurrentRootAccess {
        guard case .single(let saved) = record.scope,
              saved.locator == root.standardizedFileURL.path else { throw StorageScanFailure.accessDenied }
        return .single(root, UUID())
    }
}

// The generated latch deliberately delays an async callback. Its bounded wait
// runs on a utility queue so the async executor is free to perform the action
// whose ordering this test is checking. No product callback is changed.
private func awaitGeneratedRetainedPermit(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
        }
    }
}
