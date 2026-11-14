import Darwin
import Foundation
import SQLite3
@testable import FileOperations
import Testing

private struct PreviewFixture {
    let root: URL
    let journal: URL
    let source: URL
    let destination: URL
    let scope: QualifiedCopyPreviewScope
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("preview-activation-" + UUID().uuidString)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        for directory in [root, source, destination] {
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let observed = try NativeRenameVolume.qualified(in: DirectoryAnchor(root, resolve: false))
        let native = try #require(observed)
        let id = native.uuid.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        // These controls exercise one actual volume; the other direction/topology
        // evidence is the separately retained native qualification, not this UUID.
        scope = try #require(QualifiedCopyPreviewScope(volumes: [id, UUID()], historyVolume: id))
    }
    func remove() { try? FileManager().removeItem(at: root) }
    func engine(hooks: RecoveryHooks = .init()) -> RecoverableFileOperations {
        RecoverableFileOperations(journalDirectory: journal, hooks: hooks, qualifiedCopyPreview: scope)
    }
    func files(_ count: Int = 16, bytes: Int = 32) throws -> [URL] {
        try (0..<count).map {
            let url = source.appendingPathComponent("Sample-\($0).txt")
            try Data(repeating: UInt8($0 % 255), count: bytes).write(to: url)
            return url
        }
    }
    func version() async throws -> Int? {
        let inspection = try await RecoverableFileOperations(journalDirectory: journal).inspectExistingHistory()
        if case .available(let value) = inspection.readiness { return value }; return nil
    }
    func historyBytes() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager().contentsOfDirectory(atPath: journal.path).map {
            ($0, try Data(contentsOf: journal.appendingPathComponent($0)))
        })
    }
    func seedOlderHistory() throws -> UUID {
        let store = try OperationJournal(journal)
        var oldest: UUID?
        for index in 0..<70 {
            var record = JournalRecord(version: 1, owner: store.owner, id: UUID(), operation: "Copy")
            record.createdAt = Date(timeIntervalSince1970: Double(1_000 + index))
            record.state = "committed"; record.locations = [source]
            try store.saveSnapshot(&record)
            if oldest == nil { oldest = record.id }
        }
        return try #require(oldest)
    }
    func corruptLocationChecksum(_ id: UUID) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(journal.appendingPathComponent(SQLiteJournalStore.name).path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else { throw FileOperationFailure.ioFailure }
        defer { sqlite3_close(db) }
        // A valid-shaped digest of the oldest payload, outside the visible page.
        // Its head stays valid, so a summary/count check cannot find this fault.
        let sql = "UPDATE locations SET checksum='" + String(repeating: "0", count: 64) + "' WHERE job='" + id.uuidString + "' AND ordinal=0"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK,
              sqlite3_changes(db) == 1 else { throw FileOperationFailure.ioFailure }
    }
}

private actor PreviewReceiptBox {
    var receipt: CopyPreviewActivationReceipt?
    var calls = 0
    func save(_ receipt: CopyPreviewActivationReceipt?) { self.receipt = receipt; calls += 1 }
}
private actor PreviewReviewGate {
    var entered = false
    var continuation: CheckedContinuation<Bool, Never>?
    func review() async -> Bool { entered = true; return await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(returning: true); continuation = nil }
}
private enum PreviewTestFailure: Error { case injected }
private final class PreviewWorkerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func hold() throws {
        condition.lock(); defer { condition.unlock() }
        started = true
        let deadline = Date().addingTimeInterval(5)
        while !released { guard condition.wait(until: deadline) else { throw PreviewTestFailure.injected } }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@Test func copyPreviewActivationRefusesAnActuallyRunningWorkerUntilItDrains() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), gate = PreviewWorkerGate()
    defer { gate.release() }
    let work = Task { try await engine.worker { _ in try gate.hold() } }
    for _ in 0..<500 { if gate.entered { break }; try await Task.sleep(for: .milliseconds(2)) }
    #expect(gate.entered && !engine.isIdleForCopyPreview)
    #expect(await engine.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .notIdle)
    gate.release(); try await work.value
    #expect(engine.isIdleForCopyPreview)
}

@Test func copyPreviewProductionStopPreservesSourcesAndColdHistory() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    var hooks = RecoveryHooks()
    hooks.groupedCopy.checkpoint = { point, cancellation in if point.stage == .memberStaged { cancellation.cancel() } }
    let engine = fixture.engine(hooks: hooks), files = try fixture.files()
    #expect(await engine.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .enabled)
    let plan = try await engine.prepareTransfer(sources: files, destinationDirectory: fixture.destination, move: false, copyExecution: .previewIfAvailable)
    let result = await engine.perform(plan)
    #expect(result.result.cancellationRequested && result.result.disposition != .succeeded)
    for file in files { #expect(try Data(contentsOf: file).count == 32) }
    let fresh = fixture.engine()
    let page = try await fresh.inspectExistingHistory()
    #expect(page.readiness == .available(catalogVersion: 4) && page.records.first?.kind == .groupedCopy)
    #expect(!fresh.isCopyPreviewEnabled)
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).filter { !$0.hasPrefix(".") }.isEmpty)
}

@Test func copyPreviewActivationDefaultEngineStaysClosedWithoutCreatingHistory() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal)
    #expect(await engine.activateCopyPreview(review: { _ in Issue.record("Closed engine requested consent"); return true },
        persist: { _ in Issue.record("Closed engine attempted preference persistence") }) == .qualificationUnavailable)
    #expect(engine.copyPreviewAvailability == .qualificationPending && !engine.isCopyPreviewEnabled)
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
}

@Test func copyPreviewActivationForeignWriterPreservesHistoryAndDoesNotAskForConsent() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal), before = try fixture.historyBytes()
    let outcome = await fixture.engine().activateCopyPreview(review: { _ in Issue.record("Busy history requested consent"); return true }, persist: { _ in })
    #expect(outcome == .notEnabled(history: .none, savedChoiceMayRemain: false))
    #expect(try fixture.historyBytes() == before)
    withExtendedLifetime(journal) {}
}

@Test func copyPreviewActivationCancellationBeforeMutationCreatesNothing() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), gate = PreviewReviewGate()
    let task = Task { await engine.activateCopyPreview(review: { _ in await gate.review() }, persist: { _ in Issue.record("Cancelled activation attempted persistence") }) }
    for _ in 0..<500 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(2)) }
    #expect(await gate.entered)
    task.cancel(); await gate.finish()
    #expect(await task.value == .cancelled && engine.isIdleForCopyPreview)
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
}

@Test func copyPreviewActivationFailedPreferenceRollbackIsReported() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = fixture.engine()
    let result = await engine.activateCopyPreview(review: { _ in true }, persist: { _ in throw PreviewTestFailure.injected })
    #expect(result == .notEnabled(history: .upgraded, savedChoiceMayRemain: true))
    #expect(!engine.isCopyPreviewEnabled && engine.isIdleForCopyPreview)
    #expect(try await fixture.version() == 4)
}

@Test func copyPreviewProductionDoesNotAdoptOrUpgradeAReplacementCatalog() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), files = try fixture.files()
    #expect(await engine.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .enabled)
    let plan = try await engine.prepareTransfer(sources: files, destinationDirectory: fixture.destination, move: false, copyExecution: .previewIfAvailable)
    #expect(plan.executionDecision == .groupedCopy(maximumMembersPerGroup: 16))
    try FileManager().moveItem(at: fixture.journal, to: fixture.root.appendingPathComponent("original-history"))
    _ = try OperationJournal(fixture.journal)
    let before = try fixture.historyBytes()
    #expect(await engine.perform(plan).result.disposition != .succeeded)
    #expect(try fixture.historyBytes() == before)
    #expect(try await fixture.version() == 3)
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    let fallback = try await engine.prepareTransfer(sources: files, destinationDirectory: fixture.destination, move: false, copyExecution: .previewIfAvailable)
    #expect(fallback.executionDecision == .standard(.historyUnavailable))
}

@Test func copyPreviewProductionRetainsStandardConflictAndUnsupportedInputPaths() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), files = try fixture.files()
    #expect(await engine.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .enabled)
    let conflict = fixture.destination.appendingPathComponent(files[0].lastPathComponent)
    try Data("Existing generated destination".utf8).write(to: conflict)
    let plan = try await engine.prepareTransfer(sources: files, destinationDirectory: fixture.destination, move: false, copyExecution: .previewIfAvailable)
    #expect(plan.executionDecision == .standard(.destinationConflict) && plan.conflicts.count == 1)
    #expect(try Data(contentsOf: conflict) == Data("Existing generated destination".utf8))
    let directory = fixture.source.appendingPathComponent("Folder")
    try FileManager().createDirectory(at: directory, withIntermediateDirectories: false)
    let unsupported = try await engine.prepareTransfer(sources: [directory], destinationDirectory: fixture.destination, move: false, copyExecution: .previewIfAvailable)
    #expect(unsupported.executionDecision == .standard(.unsupportedInput))
}

@Test func copyPreviewActivationDeclineCreatesNothingAndReleasesAdmission() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), box = PreviewReceiptBox()
    let result = await engine.activateCopyPreview(review: { disclosure in
        #expect(disclosure.previousCatalogVersion == nil && disclosure.requiresHistoryUpgrade); return false
    }, persist: { await box.save($0) })
    #expect(result == .cancelled && engine.isIdleForCopyPreview)
    #expect(await box.calls == 0)
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    _ = try await engine.observeDirectory(fixture.source)
}

@Test func copyPreviewActivationReservesThroughConsentAndPreferenceAcknowledgement() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), gate = PreviewReviewGate(), box = PreviewReceiptBox()
    let task = Task { await engine.activateCopyPreview(review: { _ in await gate.review() }, persist: {
        #expect(!engine.isIdleForCopyPreview)
        await #expect(throws: FileOperationFailure.unavailable) { try await engine.observeDirectory(fixture.source) }
        await box.save($0)
    }) }
    for _ in 0..<500 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(2)) }
    #expect(await gate.entered && !engine.isIdleForCopyPreview)
    #expect(await engine.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .notIdle)
    await #expect(throws: FileOperationFailure.unavailable) { try await engine.inspectExistingHistory() }
    await gate.finish()
    #expect(await task.value == .enabled)
    #expect(engine.isIdleForCopyPreview && engine.productionCopySession != nil)
    #expect(await box.calls == 1)
    #expect(await box.receipt != nil)
    #expect(try await fixture.version() == 4)
}

@Test func copyPreviewActivationRechecksHistoryAfterConsent() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), box = PreviewReceiptBox()
    let outcome = await engine.activateCopyPreview(review: { _ in
        // An independent explicit writer changes the observed namespace.
        _ = try? OperationJournal(fixture.journal)
        return true
    }, persist: { await box.save($0) })
    #expect(outcome == .notEnabled(history: .uncertain, savedChoiceMayRemain: false))
    #expect(engine.productionCopySession == nil && engine.isIdleForCopyPreview)
    #expect(try await fixture.version() == 3)
    #expect(await box.calls == 0)
}

@Test func copyPreviewActivationReportsCommittedUpgradeAfterAcknowledgementLoss() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    _ = try OperationJournal(fixture.journal)
    var hooks = RecoveryHooks()
    hooks.journalHooks.afterCatalogUpgradeCommit = { throw PreviewTestFailure.injected }
    let engine = fixture.engine(hooks: hooks), box = PreviewReceiptBox()
    let outcome = await engine.activateCopyPreview(review: { _ in true }, persist: { await box.save($0) })
    #expect(outcome == .notEnabled(history: .upgraded, savedChoiceMayRemain: false))
    #expect(try await fixture.version() == 4)
    #expect(await box.calls == 0 && engine.productionCopySession == nil && engine.isIdleForCopyPreview)
}

@Test func copyPreviewActivationPreferenceFailureLeavesPreviewOffAndUpgradeVisible() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), box = PreviewReceiptBox()
    let outcome = await engine.activateCopyPreview(review: { _ in true }, persist: { receipt in
        await box.save(receipt)
        if receipt != nil { throw PreviewTestFailure.injected }
    })
    #expect(outcome == .notEnabled(history: .upgraded, savedChoiceMayRemain: false))
    #expect(await box.calls == 2)
    #expect(await box.receipt == nil)
    #expect(engine.productionCopySession == nil && engine.isIdleForCopyPreview)
    #expect(try await fixture.version() == 4)
}

@Test func copyPreviewSavedOnRebindIsReadOnlyAndRejectsReplacement() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let box = PreviewReceiptBox()
    #expect(await fixture.engine().activateCopyPreview(review: { _ in true }, persist: { await box.save($0) }) == .enabled)
    let receipt = try #require(await box.receipt), before = try fixture.historyBytes()
    let fresh = fixture.engine()
    #expect(await fresh.rebindCopyPreview(receipt))
    #expect(try fixture.historyBytes() == before)
    let db = fixture.journal.appendingPathComponent(SQLiteJournalStore.name)
    let bytes = try Data(contentsOf: db)
    try FileManager().moveItem(at: db, to: fixture.root.appendingPathComponent("original.sqlite"))
    try bytes.write(to: db)
    try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: db.path)
    let replaced = try fixture.historyBytes()
    #expect(!(await fixture.engine().rebindCopyPreview(receipt)))
    #expect(try fixture.historyBytes() == replaced)
}

@Test func copyPreviewSavedOnDoesNotRecreateMissingOrUpgradeOldHistory() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let box = PreviewReceiptBox()
    #expect(await fixture.engine().activateCopyPreview(review: { _ in true }, persist: { await box.save($0) }) == .enabled)
    let receipt = try #require(await box.receipt)
    try FileManager().moveItem(at: fixture.journal, to: fixture.root.appendingPathComponent("preserved-history"))
    #expect(!(await fixture.engine().rebindCopyPreview(receipt)))
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    _ = try OperationJournal(fixture.journal)
    let old = try fixture.historyBytes()
    #expect(!(await fixture.engine().rebindCopyPreview(receipt)))
    #expect(try fixture.historyBytes() == old)
    #expect(try await fixture.version() == 3)
}

@Test func copyPreviewSavedOnFullyValidatesHistoryOutsideTheVisiblePage() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let oldest = try fixture.seedOlderHistory(), box = PreviewReceiptBox()
    #expect(await fixture.engine().activateCopyPreview(review: { _ in true }, persist: { await box.save($0) }) == .enabled)
    let receipt = try #require(await box.receipt)
    try fixture.corruptLocationChecksum(oldest)
    let before = try fixture.historyBytes(), fresh = fixture.engine()
    let page = try await fresh.inspectExistingHistory()
    #expect(page.readiness == .available(catalogVersion: 4) && page.records.count == 64)
    #expect(!page.records.contains { $0.id == oldest } && page.unfinishedCountIsComplete)
    #expect(!(await fresh.rebindCopyPreview(receipt)))
    #expect(!fresh.isCopyPreviewEnabled)
    #expect(try fixture.historyBytes() == before)
}

@Test func copyPreviewCapturedPlanFullyValidatesHistoryBeforeAnyPublication() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let oldest = try fixture.seedOlderHistory(), engine = fixture.engine(), files = try fixture.files()
    #expect(await engine.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .enabled)
    let plan = try await engine.prepareTransfer(sources: files, destinationDirectory: fixture.destination,
        move: false, copyExecution: .previewIfAvailable)
    #expect(plan.executionDecision == .groupedCopy(maximumMembersPerGroup: 16))
    try fixture.corruptLocationChecksum(oldest)
    let before = try fixture.historyBytes()
    let result = await engine.perform(plan)
    #expect(result.result.disposition != .succeeded && result.recordID == nil)
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    #expect(try fixture.historyBytes() == before)
    for file in files { #expect(try Data(contentsOf: file).count == 32) }
}

@Test func copyPreviewProductionPlanKeepsCapturedAuthorityAfterDisableAndCanUndo() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), files = try fixture.files(17)
    #expect(await engine.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .enabled)
    let plan = try await engine.prepareTransfer(sources: files, destinationDirectory: fixture.destination, move: false, copyExecution: .previewIfAvailable)
    #expect(plan.executionDecision == .groupedCopy(maximumMembersPerGroup: 16))
    engine.disableCopyPreview()
    let outcome = await engine.perform(plan)
    #expect(outcome.result.disposition == .succeeded)
    let id = try #require(outcome.recordID)
    #expect(try await engine.inspectExistingHistory().records.first?.kind == .groupedCopy)
    #expect(await engine.undo(recordID: id).result.disposition == .succeeded)
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).filter { !$0.hasPrefix(".") }.isEmpty)
    for file in files { #expect(try Data(contentsOf: file).count == 32) }
}

@Test func copyPreviewProductionLimitsFallbackBeforeBodyReadingOrMutation() async throws {
    let fixture = try PreviewFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), files = try fixture.files(16, bytes: 0)
    #expect(await engine.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .enabled)
    var plan = try await engine.prepareTransfer(sources: Array(files.prefix(15)), destinationDirectory: fixture.destination, move: false, copyExecution: .previewIfAvailable)
    #expect(plan.executionDecision == .standard(.outsidePreviewLimits))
    let fd = open(files[0].path, O_WRONLY | O_NOFOLLOW)
    #expect(fd >= 0)
    #expect(ftruncate(fd, 67_108_865) == 0); close(fd)
    plan = try await engine.prepareTransfer(sources: files, destinationDirectory: fixture.destination, move: false, copyExecution: .previewIfAvailable)
    #expect(plan.executionDecision == .standard(.outsidePreviewLimits))
    #expect(plan.groupedCopy == nil)
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}

/// Opt-in integration timing; ordinary regression runs do not exercise this
/// profile. All generated cases and the full receipt remain retained.
@Test func copyPreviewProductionIntegrationProfileWorker() async throws {
    guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_COPY_PREVIEW_PROFILE_RECEIPT"] else { return }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let repository = package.deletingLastPathComponent().deletingLastPathComponent()
    let receipt = URL(fileURLWithPath: path).standardizedFileURL
    guard receipt.deletingLastPathComponent().path == repository.appendingPathComponent(".build/evidence").path,
          receipt.lastPathComponent.hasPrefix("copy-preview-integration-"), receipt.pathExtension == "json" else { throw FileOperationFailure.invalidRequest }
    var samples: [[String: String]] = []
    var ordinary: [Double] = [], grouped: [Double] = []
    for pair in 0..<3 {
        for accelerated in (pair % 2 == 0 ? [false, true] : [true, false]) {
            let fixture = try PreviewFixture(), engine = fixture.engine()
            let files = try fixture.files(1024, bytes: 256)
            #expect(await engine.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .enabled)
            let start = ProcessInfo.processInfo.systemUptime
            let plan = try await engine.prepareTransfer(sources: files, destinationDirectory: fixture.destination,
                move: false, copyExecution: accelerated ? .previewIfAvailable : .standard)
            #expect(plan.executionDecision == (accelerated ? .groupedCopy(maximumMembersPerGroup: 16) : .standard(.previewOff)))
            let result = await engine.perform(plan)
            let seconds = ProcessInfo.processInfo.systemUptime - start
            #expect(result.result.disposition == .succeeded && result.recordID != nil)
            for (ordinal, file) in files.enumerated() {
                let expected = Data(repeating: UInt8(ordinal % 255), count: 256)
                #expect(try Data(contentsOf: file) == expected)
                #expect(try Data(contentsOf: fixture.destination.appendingPathComponent(file.lastPathComponent)) == expected)
            }
            let cold = try await fixture.engine().inspectExistingHistory()
            #expect(cold.readiness == .available(catalogVersion: 4) && cold.records.count == 1)
            #expect(cold.records.first?.kind == (accelerated ? .groupedCopy : .ordinary))
            if accelerated { grouped.append(seconds) } else { ordinary.append(seconds) }
            samples.append(["pair": String(pair), "execution": accelerated ? "grouped16" : "standard", "seconds": String(seconds),
                "fixture": fixture.root.lastPathComponent, "count": "1024", "bytesPerFile": "256", "verified": "true"])
        }
    }
    let ordinaryMedian = ordinary.sorted()[1], groupedMedian = grouped.sorted()[1]
    let passed = groupedMedian <= ordinaryMedian / 2
    let report: [String: Any] = ["passed": passed, "samples": samples, "ordinaryMedianSeconds": ordinaryMedian,
        "groupedMedianSeconds": groupedMedian, "ratio": ordinaryMedian / groupedMedian,
        "scope": "Three alternating matched pairs; same-volume Workspace; Strict; qualified public production routing; warm filesystem caches; core prepare+perform timing",
        "outsideTiming": ["Fixture seeding", "Explicit activation and preference callback", "Source/destination oracle and cold inspection", "UI/queue admission"],
        "limits": ["No memory measurement", "No internal-device extension", "No power loss", "Not a new filesystem/topology qualification"]]
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: receipt, options: .withoutOverwriting)
    #expect(passed, "The production integration did not meet the existing twofold tiny-file preview target")
}
