import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct RetentionFixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    let trash: URL

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath() == base else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("retention-" + UUID().uuidString)
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("journal")
        trash = root.appendingPathComponent("fixture-trash")
        for directory in [root, source, destination, trash] {
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        }
    }

    init(workerRoot: URL, creating: Bool) throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let base = repository.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath() == base, workerRoot.deletingLastPathComponent() == base,
              workerRoot.lastPathComponent.hasPrefix("retention-crash-"),
              UUID(uuidString: String(workerRoot.lastPathComponent.dropFirst("retention-crash-".count))) != nil else {
            throw FileOperationFailure.invalidRequest
        }
        root = workerRoot
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("journal")
        trash = root.appendingPathComponent("fixture-trash")
        let marker = root.appendingPathComponent(".retention-crash-owned-v1")
        let expected = Data("Mac Explorer owned retention crash fixture\n\(root.lastPathComponent)\n".utf8)
        if creating {
            try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
            for directory in [root, source, destination, trash] {
                try FileManager().createDirectory(at: directory, withIntermediateDirectories: false,
                                                  attributes: [.posixPermissions: 0o700])
            }
            try expected.write(to: marker, options: .withoutOverwriting)
        } else {
            guard root.resolvingSymlinksInPath() == root, try Data(contentsOf: marker) == expected else {
                throw FileOperationFailure.invalidRequest
            }
        }
    }

    func file(_ name: String, in directory: URL, text: String = "fixture") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    func service(afterTrash: (@Sendable () throws -> Void)? = nil) -> RecoverableFileOperations {
        let trash = self.trash
        let legacy = LocalFileOperations(trash: { source in
            let target = trash.appendingPathComponent(source.lastPathComponent)
            let from = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
            let to = try DirectoryAnchor(trash, resolve: false)
            try exclusiveRename(from: from.fd, name: source.lastPathComponent, to: to.fd, name: target.lastPathComponent)
            try afterTrash?()
            return target
        })
        return RecoverableFileOperations(journalDirectory: journal, hooks: RecoveryHooks(), legacy: legacy)
    }

    func replacedRecord(inputs: Int = 1) async throws -> UUID {
        var sources: [URL] = []
        for index in 0..<inputs {
            let name = index == 0 ? "one" : "item-\(index)"
            sources.append(try file(name, in: source, text: "incoming"))
            _ = try file(name, in: destination, text: "displaced")
        }
        let service = service()
        let plan = try await service.prepareTransfer(sources: sources, destinationDirectory: destination, move: false)
        let result = await service.perform(plan, resolutions: Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, .replace) }))
        #expect(result.result.disposition == .succeeded)
        return try #require(result.recordID)
    }

    func remove() { try? FileManager().removeItem(at: root) }
}

@Test func retentionConfirmedCleanupPreservesPublishedFilesAndReopensCleaned() async throws {
    let fixture = try RetentionFixture(); defer { fixture.remove() }
    let id = try await fixture.replacedRecord()
    let before = try await fixture.service().retentionInspection()
    let record = try #require(before.records.first)
    #expect(record.canCleanup)
    #expect(record.areas.allSatisfy { $0.verified })
    #expect(record.logicalBytes != nil)
    #expect(!before.automaticExpiryEnabled)
    let result = await fixture.service().cleanupRecovery(recordID: id)
    #expect(result.result.disposition == .succeeded)
    #expect(try String(contentsOf: fixture.destination.appendingPathComponent("one"), encoding: .utf8) == "incoming")
    #expect(try String(contentsOf: fixture.source.appendingPathComponent("one"), encoding: .utf8) == "incoming")
    #expect(record.areas.allSatisfy { !FileManager().fileExists(atPath: $0.url.path) })
    let reopened = try await fixture.service().retentionInspection()
    #expect(reopened.records.first?.state == "cleaned")
    #expect(reopened.records.first?.canCleanup == false)
    #expect(await fixture.service().undo(recordID: id).result.disposition == .failed)
    #expect(await fixture.service().recover(recordID: id).result.disposition == .failed)
    let compacted = try await fixture.service().compactJournal()
    #expect(compacted.databaseBytes > 0)
    #expect(try await fixture.service().retentionInspection().records.first?.state == "cleaned")
}

@Test func retentionRefusesEditedBackupAndUnrecordedAreaChildren() async throws {
    for edited in [false, true] {
        let fixture = try RetentionFixture(); defer { fixture.remove() }
        let id = try await fixture.replacedRecord()
        let record = try #require(try await fixture.service().retentionInspection().records.first)
        let backupArea = try #require(record.areas.first { FileManager().fileExists(atPath: $0.url.appendingPathComponent("displaced").path) })
        if edited {
            try Data("edited backup".utf8).write(to: backupArea.url.appendingPathComponent("displaced"))
        } else {
            _ = try fixture.file("unrecorded", in: backupArea.url)
        }
        #expect(try await fixture.service().retentionInspection().records.first?.canCleanup == false)
        #expect(await fixture.service().cleanupRecovery(recordID: id).result.disposition == .failed)
        #expect(FileManager().fileExists(atPath: backupArea.url.path))
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    }
}

@Test func retentionRefusesCopiedAreaWithMatchingMarker() async throws {
    let fixture = try RetentionFixture(); defer { fixture.remove() }
    let id = try await fixture.replacedRecord()
    let record = try #require(try await fixture.service().retentionInspection().records.first)
    let area = try #require(record.areas.first)
    let old = area.url.appendingPathExtension("preserved")
    try FileManager().moveItem(at: area.url, to: old)
    try FileManager().copyItem(at: old, to: area.url)
    #expect(try await fixture.service().retentionInspection().records.first?.canCleanup == false)
    #expect(await fixture.service().cleanupRecovery(recordID: id).result.disposition == .failed)
    #expect(FileManager().fileExists(atPath: old.path))
    #expect(FileManager().fileExists(atPath: area.url.path))
}

private final class RetentionSaveFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var saves = 0
    let failAt: Int
    init(failAt: Int) { self.failAt = failAt }
    func beforeCommit() throws {
        try lock.withLock {
            saves += 1
            if saves >= failAt { throw FileOperationFailure.ioFailure }
        }
    }
}

@Test func retentionStorageFailureBeforeCleanupLeavesFilesAndCommittedHead() async throws {
    let fixture = try RetentionFixture(); defer { fixture.remove() }
    let id = try await fixture.replacedRecord()
    let failed = await fixture.service().cleanupRecovery(recordID: id, progress: nil,
        journalHooks: JournalStorageHooks(beforeSaveCommit: { throw FileOperationFailure.ioFailure }))
    #expect(failed.result.disposition == .failed)
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    let reopened = try #require(try await fixture.service().retentionInspection().records.first)
    #expect(reopened.state == "committed")
    #expect(reopened.canCleanup)
}

@Test func retentionStorageFailureAfterNativeTrashPreservesDurableIntent() async throws {
    let fixture = try RetentionFixture(); defer { fixture.remove() }
    let id = try await fixture.replacedRecord()
    // cleanupReview and the native intent commit; recording the returned location fails.
    let failure = RetentionSaveFailure(failAt: 3)
    let failed = await fixture.service().cleanupRecovery(recordID: id, progress: nil,
        journalHooks: JournalStorageHooks(beforeSaveCommit: { try failure.beforeCommit() }))
    #expect(failed.result.disposition == .failed)
    #expect(!(try FileManager().contentsOfDirectory(atPath: fixture.trash.path)).isEmpty)
    let reopened = try #require(try await fixture.service().retentionInspection().records.first)
    #expect(reopened.state == "cleanupReview")
    #expect(!reopened.canCleanup)
    #expect(await fixture.service().undo(recordID: id).result.disposition == .failed)
    #expect(await fixture.service().recover(recordID: id).result.disposition == .failed)
    #expect(failed.result.items.flatMap(\.recoveryURLs).contains { $0.path.hasPrefix(fixture.trash.path + "/") })
}

@Test func retentionFreshGuardAfterDurableIntentRefusesAreaEdit() async throws {
    let fixture = try RetentionFixture(); defer { fixture.remove() }
    let id = try await fixture.replacedRecord()
    let record = try #require(try await fixture.service().retentionInspection().records.first)
    let area = try #require(record.areas.sorted { $0.url.path < $1.url.path }.first)
    let marker = area.url.appendingPathComponent(".mac-explorer-recovery-v1")
    let service = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(afterIntent: {
        try? Data("changed after durable intent".utf8).write(to: marker)
    }), legacy: LocalFileOperations(trash: { _ in throw FileOperationFailure.ioFailure }))
    let failed = await service.cleanupRecovery(recordID: id)
    #expect(failed.result.disposition == .failed)
    #expect(FileManager().fileExists(atPath: area.url.path))
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    #expect(try await fixture.service().retentionInspection().records.first?.state == "cleanupReview")
}

@Test func retentionUnknownNativeOutcomeRemainsReviewOnlyAcrossReopen() async throws {
    let fixture = try RetentionFixture(); defer { fixture.remove() }
    let id = try await fixture.replacedRecord()
    let result = await fixture.service(afterTrash: { throw FileOperationFailure.ioFailure }).cleanupRecovery(recordID: id)
    #expect(result.result.disposition == .failed)
    let record = try #require(try await fixture.service().retentionInspection().records.first)
    #expect(record.state == "cleanupReview")
    #expect(!record.canCleanup)
    #expect(await fixture.service().cleanupRecovery(recordID: id).result.disposition == .failed)
    #expect(await fixture.service().undo(recordID: id).result.disposition == .failed)
    #expect(await fixture.service().recover(recordID: id).result.disposition == .failed)
    #expect(!(try FileManager().contentsOfDirectory(atPath: fixture.trash.path)).isEmpty)
}

private final class RetentionGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func waitUntilEntered() { entered.wait() }
}

@Test func retentionStopDrainsNativeOutcomeAndProtectsRemainingAreas() async throws {
    let fixture = try RetentionFixture(); defer { fixture.remove() }
    let id = try await fixture.replacedRecord(inputs: 2)
    let gate = RetentionGate()
    let service = fixture.service(afterTrash: { gate.entered.signal(); gate.release.wait() })
    let task = Task { await service.cleanupRecovery(recordID: id) }
    await Task.detached { gate.waitUntilEntered() }.value
    task.cancel(); gate.release.signal()
    let result = await task.value
    #expect(result.result.disposition == .partial)
    #expect(result.result.cancellationRequested)
    let record = try #require(try await fixture.service().retentionInspection().records.first)
    #expect(record.state == "cleanupReview")
    #expect(!record.canCleanup)
    #expect(result.result.items.first?.destination != nil)
}

@Test func retentionLateStopCanFinishAfterOnlyOwnedEmptyAreaIsTrashed() async throws {
    let fixture = try RetentionFixture(); defer { fixture.remove() }
    let source = try fixture.file("one", in: fixture.source)
    let result = await fixture.service().perform(.copy(sources: [source], destinationDirectory: fixture.destination))
    let id = try #require(result.recordID)
    let gate = RetentionGate()
    let service = fixture.service(afterTrash: { gate.entered.signal(); gate.release.wait() })
    let task = Task { await service.cleanupRecovery(recordID: id) }
    await Task.detached { gate.waitUntilEntered() }.value
    task.cancel(); gate.release.signal()
    let cleaned = await task.value
    #expect(cleaned.result.disposition == .succeeded)
    #expect(cleaned.result.cancellationRequested)
    #expect(try await fixture.service().retentionInspection().records.first?.state == "cleaned")
}

@Test func retentionVerifiedUndoneJobCanBeCleaned() async throws {
    let fixture = try RetentionFixture(); defer { fixture.remove() }
    let id = try await fixture.replacedRecord()
    #expect(await fixture.service().undo(recordID: id).result.disposition == .succeeded)
    #expect(try await fixture.service().retentionInspection().records.first?.canCleanup == true)
    #expect(await fixture.service().cleanupRecovery(recordID: id).result.disposition == .succeeded)
    #expect(try String(contentsOf: fixture.destination.appendingPathComponent("one"), encoding: .utf8) == "displaced")
}

@Test func retentionProjectsNestedAreaAfterContainerMoveAndTrashesOuterOnly() async throws {
    let fixture = try RetentionFixture(); defer { fixture.remove() }
    let id = UUID()
    let outer = fixture.source.appendingPathComponent(".mac-explorer-recovery-" + UUID().uuidString)
    let container = fixture.source.appendingPathComponent("container")
    let inner = container.appendingPathComponent(".mac-explorer-recovery-" + UUID().uuidString)
    for directory in [outer, container, inner] {
        try FileManager().createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    for directory in [outer, inner] {
        let marker = directory.appendingPathComponent(".mac-explorer-recovery-v1")
        try Data("MacExplorer recovery v1\n\(id.uuidString)\nRetained until explicit cleanup.\n".utf8).write(to: marker)
        try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }
    let original = try fixture.file("original", in: inner)
    let token = OperationCancellation()
    let innerGuard = try verifiedTree(original, cancellation: token)
    let from = try DirectoryAnchor(fixture.source)
    let to = try DirectoryAnchor(outer)
    let innerAnchor = try DirectoryAnchor(inner)
    let outerIdentity = to.identity
    let innerIdentity = innerAnchor.identity
    let before = try verifiedTree(container, cancellation: token)
    let retainedContainer = outer.appendingPathComponent("original")
    try exclusiveRename(from: from.fd, name: container.lastPathComponent, to: to.fd, name: "original")
    let after = try verifiedTree(retainedContainer, cancellation: token)
    do {
        let journal = try OperationJournal(fixture.journal)
        var record = JournalRecord(version: 1, owner: journal.owner, id: id, operation: "Nested fixture")
        record.state = "committed"
        record.areas = [JournalArea(url: inner, identity: innerIdentity), JournalArea(url: outer, identity: outerIdentity)]
        record.steps = [
            JournalStep(source: fixture.source.appendingPathComponent("former"), destination: original,
                sourceParent: from.identity, destinationParent: innerIdentity, before: innerGuard, after: innerGuard),
            JournalStep(source: container, destination: retainedContainer, sourceParent: from.identity,
                destinationParent: outerIdentity, before: before, after: after)
        ]
        try journal.saveSnapshot(&record)
    }
    let inspected = try #require(try await fixture.service().retentionInspection().records.first)
    #expect(inspected.canCleanup)
    #expect(inspected.areas.contains { $0.url == retainedContainer.appendingPathComponent(inner.lastPathComponent) })
    let cleaned = await fixture.service().cleanupRecovery(recordID: id)
    #expect(cleaned.result.disposition == .succeeded)
    #expect(cleaned.result.items.count == 1)
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.trash.path).count == 1)
}

private func retentionWorkerReceipt(_ values: [String: String], root: URL, name: String) throws {
    let receipt = root.appendingPathComponent(name)
    try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]).write(to: receipt, options: .withoutOverwriting)
    try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RETENTION_CRASH_PHASE"] != nil,
               "Explicit dedicated retention interruption worker only."))
func retentionCrashQualificationWorker() async throws {
    let environment = ProcessInfo.processInfo.environment
    let phase = try #require(environment["MAC_EXPLORER_RETENTION_CRASH_PHASE"])
    let root = URL(fileURLWithPath: try #require(environment["MAC_EXPLORER_RETENTION_CRASH_ROOT"]), isDirectory: true)
    guard ["intent", "renamed", "inspect"].contains(phase) else { throw FileOperationFailure.invalidRequest }
    let fixture = try RetentionFixture(workerRoot: root, creating: phase != "inspect")
    let idFile = root.appendingPathComponent("job-id.txt")
    if phase == "inspect" {
        let data = try Data(contentsOf: idFile)
        let id = try #require(String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:)))
        let record = try await fixture.service().retentionRecord(recordID: id)
        #expect(record.state == "cleanupReview")
        #expect(!record.canCleanup)
        #expect(await fixture.service().undo(recordID: id).result.disposition == .failed)
        #expect(await fixture.service().recover(recordID: id).result.disposition == .failed)
        #expect(try String(contentsOf: fixture.destination.appendingPathComponent("one"), encoding: .utf8) == "incoming")
        #expect(try String(contentsOf: fixture.source.appendingPathComponent("one"), encoding: .utf8) == "incoming")
        let trashCount = try FileManager().contentsOfDirectory(atPath: fixture.trash.path).count
        #expect(trashCount == 0 || trashCount == 1)
        try retentionWorkerReceipt(["phase": phase, "pid": String(getpid()), "recordID": id.uuidString,
            "state": record.state, "canCleanup": String(record.canCleanup), "trashCount": String(trashCount),
            "publishedPresent": "true", "sourcePresent": "true"], root: root, name: "inspect-summary.json")
        return
    }
    let id = try await fixture.replacedRecord()
    try Data(id.uuidString.utf8).write(to: idFile, options: .withoutOverwriting)
    let terminate: @Sendable () -> Void = {
        do {
            let trashCount = try FileManager().contentsOfDirectory(atPath: fixture.trash.path).count
            try retentionWorkerReceipt(["phase": phase, "pid": String(getpid()), "recordID": id.uuidString,
                "terminationCode": "86", "trashCount": String(trashCount)], root: root, name: "termination-summary.json")
            _exit(86)
        } catch { _exit(87) }
    }
    if phase == "intent" {
        let service = RecoverableFileOperations(journalDirectory: fixture.journal,
            hooks: RecoveryHooks(afterIntent: terminate), legacy: LocalFileOperations(trash: { _ in
                throw FileOperationFailure.invalidRequest
            }))
        _ = await service.cleanupRecovery(recordID: id)
    } else {
        _ = await fixture.service(afterTrash: terminate).cleanupRecovery(recordID: id)
    }
    Issue.record("The dedicated retention worker did not reach its interruption boundary.")
}
