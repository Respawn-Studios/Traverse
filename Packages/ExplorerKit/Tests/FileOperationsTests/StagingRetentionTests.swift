import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct StageFixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    let trash: URL
    init() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath() == base else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("staging-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); destination = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("journal"); trash = root.appendingPathComponent("fixture-trash")
        for url in [root, source, destination, trash] {
            try FileManager().createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    init(workerRoot: URL, creating: Bool) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = repository.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath() == base, workerRoot.deletingLastPathComponent() == base,
              workerRoot.lastPathComponent.hasPrefix("staging-crash-"),
              UUID(uuidString: String(workerRoot.lastPathComponent.dropFirst("staging-crash-".count))) != nil else {
            throw FileOperationFailure.invalidRequest
        }
        root = workerRoot
        source = root.appendingPathComponent("source"); destination = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("journal"); trash = root.appendingPathComponent("fixture-trash")
        let marker = root.appendingPathComponent(".staging-crash-owned-v1")
        let expected = Data("Mac Explorer owned staging crash fixture\n\(root.lastPathComponent)\n".utf8)
        if creating {
            try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
            for url in [root, source, destination, trash] {
                try FileManager().createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try expected.write(to: marker, options: .withoutOverwriting)
        } else {
            guard root.resolvingSymlinksInPath() == root, try Data(contentsOf: marker) == expected else {
                throw FileOperationFailure.invalidRequest
            }
        }
    }
    func remove() { try? FileManager().removeItem(at: root) }
    func file(_ name: String = "file", in parent: URL? = nil) throws -> URL {
        let url = (parent ?? source).appendingPathComponent(name)
        try Data("complete fixture content".utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
    func service(_ hooks: RecoveryHooks = RecoveryHooks()) -> RecoverableFileOperations {
        let targetDirectory = trash
        return RecoverableFileOperations(journalDirectory: journal, hooks: hooks,
            legacy: LocalFileOperations(trash: { url in
                let from = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
                let to = try DirectoryAnchor(targetDirectory, resolve: false)
                try exclusiveRename(from: from.fd, name: url.lastPathComponent, to: to.fd, name: url.lastPathComponent)
                return targetDirectory.appendingPathComponent(url.lastPathComponent)
            }))
    }
    func record(_ id: UUID) throws -> JournalRecord {
        try #require(try OperationJournal(journal).inspectRecord(id))
    }
    func staged(_ input: URL) async throws -> UUID {
        let gate = StageGate()
        let operation = service(RecoveryHooks(beforeCommit: { gate.block() }))
        let task = Task { await operation.perform(.copy(sources: [input], destinationDirectory: destination)) }
        await Task.detached { gate.waitUntilEntered() }.value
        task.cancel(); gate.release.signal()
        let result = await task.value
        #expect(result.result.cancellationRequested)
        return try #require(result.recordID)
    }
}

@Test func stagingVerifiedStoppedPayloadReopensAndCleansThroughTrash() async throws {
    let f = try StageFixture(); defer { f.remove() }
    let input = try f.file()
    let id = try await f.staged(input)
    let record = try f.record(id)
    #expect(record.areas.first?.stagingProof != nil)
    #expect(record.steps.isEmpty)
    #expect(try await f.service().retentionRecord(recordID: id).canCleanup)
    #expect(await f.service().cleanupRecovery(recordID: id).result.disposition == .succeeded)
    #expect(try Data(contentsOf: input) == Data("complete fixture content".utf8))
    #expect(!FileManager().fileExists(atPath: f.destination.appendingPathComponent("file").path))
    #expect(try f.record(id).state == "cleaned")
}

@Test func stagingUnsealedPartialWriteAndSyncFailureStayProtected() async throws {
    for failSync in [false, true] {
        let f = try StageFixture(); defer { f.remove() }
        let input = try f.file()
        var hooks = RecoveryHooks()
        if failSync { hooks.beforeSync = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) } }
        else {
            hooks.copyFaults = CopyFaultHooks(beforeNativeCopy: { _, destination in
                let bytes = Data("half".utf8)
                _ = bytes.withUnsafeBytes { Darwin.write(destination, $0.baseAddress, $0.count) }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            })
        }
        let result = await f.service(hooks).perform(.copy(sources: [input], destinationDirectory: f.destination))
        let id = try #require(result.recordID)
        #expect(try f.record(id).areas.allSatisfy { $0.stagingProof == nil })
        #expect(try await f.service().retentionRecord(recordID: id).canCleanup == false)
        #expect(await f.service().cleanupRecovery(recordID: id).result.disposition == .failed)
        #expect(try Data(contentsOf: input) == Data("complete fixture content".utf8))
        #expect(try FileManager().contentsOfDirectory(atPath: f.trash.path).isEmpty)
    }
}

@Test func stagingEditedPayloadAndUnknownAreaChildRefuseCleanup() async throws {
    for unknownChild in [false, true] {
        let f = try StageFixture(); defer { f.remove() }
        let id = try await f.staged(f.file())
        let area = try #require(try f.record(id).areas.first)
        let target = area.url.appendingPathComponent(unknownChild ? "user-added" : "payload")
        try Data("user change".utf8).write(to: target)
        #expect(try await f.service().retentionRecord(recordID: id).canCleanup == false)
        #expect(await f.service().cleanupRecovery(recordID: id).result.disposition == .failed)
        #expect(try Data(contentsOf: target) == Data("user change".utf8))
        #expect(try FileManager().contentsOfDirectory(atPath: f.trash.path).isEmpty)
    }
}

@Test func stagingEqualContentSubstitutedDescendantFailsIdentityProof() async throws {
    let f = try StageFixture(); defer { f.remove() }
    let input = f.source.appendingPathComponent("tree")
    try FileManager().createDirectory(at: input, withIntermediateDirectories: false)
    _ = try f.file("leaf", in: input)
    let id = try await f.staged(input)
    let area = try #require(try f.record(id).areas.first)
    let proof = try #require(area.stagingProof)
    let payload = area.url.appendingPathComponent("payload")
    let leaf = payload.appendingPathComponent("leaf")
    var metadata = stat()
    #expect(lstat(payload.path, &metadata) == 0)
    let kept = f.root.appendingPathComponent("original-created-leaf")
    try FileManager().moveItem(at: leaf, to: kept)
    try FileManager().copyItem(at: kept, to: leaf)
    var times = [metadata.st_atimespec, metadata.st_mtimespec]
    #expect(utimensat(AT_FDCWD, payload.path, &times, AT_SYMLINK_NOFOLLOW) == 0)
    #expect(try verifiedTree(payload, cancellation: OperationCancellation()).digest == proof.payload.digest)
    #expect(try await f.service().retentionRecord(recordID: id).canCleanup == false)
    #expect(await f.service().cleanupRecovery(recordID: id).result.disposition == .failed)
    #expect(FileManager().fileExists(atPath: leaf.path))
}

@Test func stagingUnknownChildCannotBeAdoptedBeforeSeal() async throws {
    let f = try StageFixture(); defer { f.remove() }
    let input = f.source.appendingPathComponent("tree")
    try FileManager().createDirectory(at: input, withIntermediateDirectories: false)
    _ = try f.file("leaf", in: input)
    let hooks = RecoveryHooks(beforeSync: { payload in
        try Data("foreign".utf8).write(to: payload.appendingPathComponent("foreign"), options: .withoutOverwriting)
    })
    let result = await f.service(hooks).perform(.copy(sources: [input], destinationDirectory: f.destination))
    let id = try #require(result.recordID)
    #expect(try f.record(id).areas.first?.stagingProof == nil)
    #expect(try await f.service().retentionRecord(recordID: id).canCleanup == false)
}

@Test func stagingUndoneCopyAndNewFolderUseDurableMaterialization() async throws {
    for folder in [false, true] {
        let f = try StageFixture(); defer { f.remove() }
        let service = f.service()
        let result: RecoverableOperationResult
        if folder { result = await service.perform(.createFolder(parent: f.destination, name: "new")) }
        else { result = await service.perform(.copy(sources: [try f.file()], destinationDirectory: f.destination)) }
        let id = try #require(result.recordID)
        #expect(await service.undo(recordID: id).result.disposition == .succeeded)
        #expect(try await service.retentionRecord(recordID: id).canCleanup)
        #expect(await service.cleanupRecovery(recordID: id).result.disposition == .succeeded)
        #expect(try f.record(id).state == "cleaned")
    }
}

@Test func stagingOlderUnsealedPayloadIsNotRetrospectivelyAdopted() async throws {
    let f = try StageFixture(); defer { f.remove() }
    let id = try await f.staged(f.file())
    do {
        let journal = try OperationJournal(f.journal)
        var record = try #require(try journal.inspectRecord(id))
        record.areas[0].stagingProof = nil
        try journal.saveSnapshot(&record)
    }
    #expect(try await f.service().retentionRecord(recordID: id).canCleanup == false)
    #expect(await f.service().cleanupRecovery(recordID: id).result.disposition == .failed)
}

@Test func stagingUndoneEditedPayloadRemainsProtected() async throws {
    let f = try StageFixture(); defer { f.remove() }
    let input = try f.file()
    let result = await f.service().perform(.copy(sources: [input], destinationDirectory: f.destination))
    let id = try #require(result.recordID)
    #expect(await f.service().undo(recordID: id).result.disposition == .succeeded)
    let payload = try #require(try f.record(id).areas.first).url.appendingPathComponent("payload")
    try Data("user edit after Undo".utf8).write(to: payload)
    #expect(try await f.service().retentionRecord(recordID: id).canCleanup == false)
    #expect(await f.service().cleanupRecovery(recordID: id).result.disposition == .failed)
    #expect(try String(contentsOf: payload, encoding: .utf8) == "user edit after Undo")
}

@Test func stagingNestedMoveMergeUndoProjectsAndCleansEveryOwnedArea() async throws {
    let f = try StageFixture(); defer { f.remove() }
    let sourceTree = f.source.appendingPathComponent("tree")
    let sourceDeep = sourceTree.appendingPathComponent("inner/deep")
    let targetTree = f.destination.appendingPathComponent("tree")
    let targetDeep = targetTree.appendingPathComponent("inner/deep")
    for url in [sourceDeep, targetDeep] {
        try FileManager().createDirectory(at: url, withIntermediateDirectories: true)
    }
    let movedLeaf = try f.file("moved", in: sourceDeep)
    let publicSibling = try f.file("untouched", in: targetDeep)
    let originalLeaf = try verifiedTree(movedLeaf, cancellation: OperationCancellation())
    let untouched = try verifiedTree(publicSibling, cancellation: OperationCancellation())
    let originalDirectories = try [sourceTree, sourceTree.appendingPathComponent("inner"), sourceDeep]
        .map { try DirectoryAnchor($0, resolve: false).identity }
    let service = f.service()
    let plan = try await service.prepareTransfer(sources: [sourceTree], destinationDirectory: f.destination, move: true)
    let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, TransferConflictResolution.merge) })
    let result = await service.perform(plan, resolutions: choices)
    try #require(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    #expect(!FileManager().fileExists(atPath: sourceTree.path))
    try #require(await service.undo(recordID: id).result.disposition == .succeeded)
    #expect(originalLeaf.matches(try verifiedTree(movedLeaf, cancellation: OperationCancellation())))
    #expect(untouched.matches(try verifiedTree(publicSibling, cancellation: OperationCancellation())))
    #expect(!FileManager().fileExists(atPath: targetDeep.appendingPathComponent("moved").path))
    let inspection = try await service.retentionRecord(recordID: id)
    try #require(inspection.canCleanup)
    #expect(inspection.areas.count >= 3)
    #expect(inspection.areas.contains { $0.url.path.hasPrefix(sourceDeep.deletingLastPathComponent().path + "/") })
    try #require(await service.cleanupRecovery(recordID: id).result.disposition == .succeeded)
    #expect(try f.record(id).state == "cleaned")
    #expect(originalLeaf.matches(try verifiedTree(movedLeaf, cancellation: OperationCancellation())))
    #expect(untouched.matches(try verifiedTree(publicSibling, cancellation: OperationCancellation())))
    for (url, identity) in zip([sourceTree, sourceTree.appendingPathComponent("inner"), sourceDeep], originalDirectories) {
        #expect(try DirectoryAnchor(url, resolve: false).identity.sameObject(as: identity))
    }
    #expect(try FileManager().contentsOfDirectory(atPath: sourceTree.path) == ["inner"])
    #expect(try FileManager().contentsOfDirectory(atPath: sourceTree.appendingPathComponent("inner").path) == ["deep"])
    #expect(try FileManager().contentsOfDirectory(atPath: sourceDeep.path) == ["moved"])
    #expect(try FileManager().contentsOfDirectory(atPath: f.trash.path).count == inspection.areas.count)
}

@Test func stagingRecoveredNeverExecutedIntentUsesBeforeMaterialization() async throws {
    let f = try StageFixture(); defer { f.remove() }
    let input = try f.file()
    let service = f.service(RecoveryHooks(beforeExclusiveRename: { _, _ in
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENODEV))
    }))
    let result = await service.perform(.copy(sources: [input], destinationDirectory: f.destination))
    let id = try #require(result.recordID)
    let before = try f.record(id)
    #expect(before.steps.count == 1)
    #expect(before.steps.first?.after == nil)
    #expect(try await f.service().retentionRecord(recordID: id).canCleanup == false)
    #expect(await f.service().recover(recordID: id).result.disposition == .succeeded)
    let reconciled = try f.record(id)
    #expect(reconciled.state == "undone")
    #expect(reconciled.steps.first?.undone == true)
    #expect(reconciled.steps.first?.after == nil)
    #expect(try await f.service().retentionRecord(recordID: id).canCleanup)
    #expect(await f.service().cleanupRecovery(recordID: id).result.disposition == .succeeded)
    #expect(try Data(contentsOf: input) == Data("complete fixture content".utf8))
}

@Test func stagingMalformedProofFailsClosedAndOldAreaDecodes() throws {
    let f = try StageFixture(); defer { f.remove() }
    let anchor = try DirectoryAnchor(f.source)
    let old = JournalArea(url: f.source, identity: anchor.identity)
    let decoded = try JSONDecoder().decode(JournalArea.self, from: JSONEncoder().encode(old))
    #expect(decoded.stagingProof == nil)
    let input = try f.file()
    let tree = try verifiedTree(input, cancellation: OperationCancellation())
    let proof = JournalStagingProof(version: 99, payload: tree, identityDigest: String(repeating: "0", count: 64), nodeCount: 1, stepCount: 0)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try proof.validate(area: old, stepCount: 0) }
}

private final class StageGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func block() { entered.signal(); release.wait() }
    func waitUntilEntered() { entered.wait() }
}

private final class StageCounter: @unchecked Sendable {
    let lock = NSLock()
    private var count = 0
    func advance() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

@Test func stagingSealCommitFailureLeavesUnsealedEvidenceProtected() async throws {
    let f = try StageFixture(); defer { f.remove() }
    let input = try f.file()
    let active = StageCounter()
    let hooks = RecoveryHooks(beforeSync: { _ in _ = active.advance() },
        journalHooks: JournalStorageHooks(beforeSaveCommit: {
            if active.value > 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        }))
    let result = await f.service(hooks).perform(.copy(sources: [input], destinationDirectory: f.destination))
    #expect(result.result.items.contains { $0.status == .failed(.outOfSpace) })
    let id = try #require(result.recordID)
    let area = try #require(try f.record(id).areas.first)
    #expect(area.stagingProof == nil)
    #expect(FileManager().fileExists(atPath: area.url.appendingPathComponent("payload").path))
    #expect(try await f.service().retentionRecord(recordID: id).canCleanup == false)
    #expect(await f.service().cleanupRecovery(recordID: id).result.disposition == .failed)
}

@Test func stagingPartialBatchKeepsPublishedItemAndCleansOnlyProvenAreas() async throws {
    let f = try StageFixture(); defer { f.remove() }
    let first = try f.file("first"), second = try f.file("second")
    let count = StageCounter()
    let hooks = RecoveryHooks(afterStagingProof: { if count.advance() == 2 { throw CancellationError() } })
    let result = await f.service(hooks).perform(.copy(sources: [first, second], destinationDirectory: f.destination))
    let id = try #require(result.recordID)
    let record = try f.record(id)
    #expect(record.steps.count == 1)
    #expect(record.areas.count == 2)
    #expect(record.state == "needsReview")
    #expect(try await f.service().retentionRecord(recordID: id).canCleanup)
    #expect(await f.service().cleanupRecovery(recordID: id).result.disposition == .succeeded)
    #expect(try Data(contentsOf: f.destination.appendingPathComponent("first")) == Data(contentsOf: first))
    #expect(!FileManager().fileExists(atPath: f.destination.appendingPathComponent("second").path))
    #expect(FileManager().fileExists(atPath: second.path))
}


private func stagingWorkerReceipt(_ values: [String: String], root: URL, name: String) throws {
    let receipt = root.appendingPathComponent(name)
    try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]).write(to: receipt, options: .withoutOverwriting)
    try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_STAGING_CRASH_PHASE"] != nil,
               "Explicit dedicated staging interruption worker only."))
func stagingCrashQualificationWorker() async throws {
    let environment = ProcessInfo.processInfo.environment
    let phase = try #require(environment["MAC_EXPLORER_STAGING_CRASH_PHASE"])
    let boundary = try #require(environment["MAC_EXPLORER_STAGING_CRASH_BOUNDARY"])
    guard ["before-seal", "after-seal"].contains(boundary), phase == boundary || phase == "inspect" else {
        throw FileOperationFailure.invalidRequest
    }
    let root = URL(fileURLWithPath: try #require(environment["MAC_EXPLORER_STAGING_CRASH_ROOT"]), isDirectory: true)
    let fixture = try StageFixture(workerRoot: root, creating: phase != "inspect")
    let idFile = root.appendingPathComponent("job-id.txt")
    if phase == "inspect" {
        let id = try #require(String(data: Data(contentsOf: idFile), encoding: .utf8).flatMap(UUID.init(uuidString:)))
        let record = try fixture.record(id)
        let area = try #require(record.areas.first)
        let inspected = try await fixture.service().retentionRecord(recordID: id)
        let expectedSeal = boundary == "after-seal"
        #expect((area.stagingProof != nil) == expectedSeal)
        #expect(inspected.canCleanup == expectedSeal)
        #expect(record.steps.isEmpty)
        #expect(try Data(contentsOf: fixture.source.appendingPathComponent("file")) == Data("complete fixture content".utf8))
        #expect(try Data(contentsOf: area.url.appendingPathComponent("payload")) == Data("complete fixture content".utf8))
        #expect(!FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("file").path))
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
        // Inspection only: do not call cleanup, Undo, recovery or ordinary perform.
        try stagingWorkerReceipt(["phase": phase, "pid": String(getpid()), "recordID": id.uuidString,
            "hasSeal": String(area.stagingProof != nil), "canCleanup": String(inspected.canCleanup),
            "state": record.state, "sourcePresent": "true", "payloadPresent": "true",
            "publishedPresent": "false", "trashCount": "0"], root: root, name: "inspect-summary.json")
        return
    }
    let terminate: @Sendable () throws -> Void = {
        let id = try #require(String(data: Data(contentsOf: idFile), encoding: .utf8).flatMap(UUID.init(uuidString:)))
        try stagingWorkerReceipt(["phase": phase, "pid": String(getpid()), "recordID": id.uuidString,
            "terminationCode": "86"], root: root, name: "termination-summary.json")
        _exit(86)
    }
    let hooks = RecoveryHooks(beforeStagingProof: { id in
        try Data(id.uuidString.utf8).write(to: idFile, options: .withoutOverwriting)
        if boundary == "before-seal" { try terminate() }
    }, afterStagingProof: {
        if boundary == "after-seal" { try terminate() }
    })
    let input = try fixture.file()
    _ = await fixture.service(hooks).perform(.copy(sources: [input], destinationDirectory: fixture.destination))
    Issue.record("The dedicated staging worker did not reach its interruption boundary.")
}
