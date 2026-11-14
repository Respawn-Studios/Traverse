import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct ProtectedHistoryFixture {
    let root: URL
    let journal: URL
    let source: URL
    let destination: URL
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("protected-history-" + UUID().uuidString)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        for url in [root, source, destination] {
            try FileManager().createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    func remove() { try? FileManager().removeItem(at: root) }
    func engine() -> RecoverableFileOperations { RecoverableFileOperations(journalDirectory: journal) }
    func file(_ name: String = "Sample.txt", in parent: URL? = nil) throws -> URL {
        let url = (parent ?? source).appendingPathComponent(name)
        try Data("Generated history-protection fixture".utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
    private enum HistoryEntry: Equatable { case file(Data), directory, other }
    private func historyEntries() throws -> [String: HistoryEntry] {
        let anchor = try DirectoryAnchor(journal, resolve: false)
        return try Dictionary(uniqueKeysWithValues: FileManager().contentsOfDirectory(atPath: journal.path).map {
            let snapshot = try EntrySnapshot(parent: anchor.fd, name: $0)
            let value: HistoryEntry = snapshot.type == S_IFREG ? .file(try Data(contentsOf: journal.appendingPathComponent($0)))
                : snapshot.isDirectory ? .directory : .other
            return ($0, value)
        })
    }
    func historyBytes() throws -> Data {
        let entries = try historyEntries()
        let anchor = try DirectoryAnchor(journal, resolve: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(anchor.identity)
        for name in entries.keys.sorted() {
            bytes.append(contentsOf: name.utf8); bytes.append(0)
            bytes.append(try encoder.encode(EntrySnapshot(parent: anchor.fd, name: name)))
            switch entries[name]! {
            case .file(let data): bytes.append(1); bytes.append(contentsOf: String(data.count).utf8); bytes.append(0); bytes.append(data)
            case .directory: bytes.append(2)
            case .other: bytes.append(3)
            }
        }
        return bytes
    }
}

@Test func protectedHistoryCopyIntoLiveStoreRefusesWithoutChangingHistory() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    _ = try OperationJournal(fixture.journal)
    let file = try fixture.file(), before = try fixture.historyBytes()
    let engine = fixture.engine()
    let result = await engine.perform(.copy(sources: [file], destinationDirectory: fixture.journal))
    #expect(result.result.disposition == .failed && result.recordID == nil)
    #expect(result.result.items.contains { $0.status == .failed(.operationHistoryProtected) })
    #expect(try fixture.historyBytes() == before)
    #expect(try Data(contentsOf: file) == Data("Generated history-protection fixture".utf8))
    #expect(try await engine.inspectExistingHistory().readiness == .available(catalogVersion: 3))
}

@Test func protectedHistoryOrdinaryCommandsRejectStoreChildrenAndAncestors() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    _ = try OperationJournal(fixture.journal)
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: RecoveryHooks(),
        legacy: LocalFileOperations(trash: { _ in Issue.record("Protected history reached native Trash"); throw FileOperationFailure.ioFailure }))
    let metadata = fixture.journal.appendingPathComponent(SQLiteJournalStore.name)
    let requests: [FileOperationRequest] = [
        .createFolder(parent: fixture.journal, name: "new"),
        .rename(source: fixture.journal, name: "renamed"),
        .rename(source: metadata, name: "renamed.sqlite"),
        .rename(source: fixture.root, name: "renamed-root"),
        .trash(sources: [fixture.journal]), .trash(sources: [metadata]), .trash(sources: [fixture.root]),
        .copy(sources: [metadata], destinationDirectory: fixture.destination),
        .copy(sources: [fixture.journal], destinationDirectory: fixture.destination),
        .copy(sources: [fixture.root], destinationDirectory: fixture.destination),
        .move(sources: [fixture.journal], destinationDirectory: fixture.destination)
    ]
    let before = try fixture.historyBytes()
    for request in requests {
        let result = await engine.perform(request)
        #expect(result.recordID == nil && result.result.disposition == .failed)
        #expect(result.result.items.contains { $0.status == .failed(.operationHistoryProtected) })
        #expect(result.result.items.allSatisfy { $0.recoveryURLs.isEmpty })
        #expect(try fixture.historyBytes() == before)
    }
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}

@Test func protectedHistoryMissingStoreReservesItsNameAndSourceAncestors() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), file = try fixture.file("journal")
    let requests: [FileOperationRequest] = [
        .createFolder(parent: fixture.root, name: "journal"),
        .rename(source: fixture.root, name: "renamed-root"),
        .copy(sources: [fixture.root], destinationDirectory: fixture.destination),
        .copy(sources: [file], destinationDirectory: fixture.root)
    ]
    for request in requests {
        let result = await engine.perform(request)
        #expect(result.recordID == nil && result.result.items.contains { $0.status == .failed(.operationHistoryProtected) })
        #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    }
}

@Test func protectedHistoryUnrelatedSiblingsAndLinkOnlyCopiesRemainUsable() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    let engine = fixture.engine(), file = try fixture.file("operations-v2.sqlite")
    let copied = await engine.perform(.copy(sources: [file], destinationDirectory: fixture.destination))
    #expect(copied.result.disposition == .succeeded)
    #expect(await engine.undo(recordID: try #require(copied.recordID)).result.disposition == .succeeded)
    let link = fixture.source.appendingPathComponent("History link")
    try FileManager().createSymbolicLink(at: link, withDestinationURL: fixture.journal)
    let linked = await engine.perform(.copy(sources: [link], destinationDirectory: fixture.destination))
    #expect(linked.result.disposition == .succeeded)
    let target = fixture.destination.appendingPathComponent(link.lastPathComponent)
    #expect(try FileManager().destinationOfSymbolicLink(atPath: target.path) == fixture.journal.path)
    #expect(await engine.undo(recordID: try #require(linked.recordID)).result.disposition == .succeeded)
}

@Test func protectedHistoryKeepBothUsesTheResolvedSiblingWithoutReadingTheStoreTree() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    _ = try OperationJournal(fixture.journal)
    let folder = fixture.source.appendingPathComponent("journal", isDirectory: true)
    try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
    _ = try fixture.file("ordinary.txt", in: folder)
    let engine = fixture.engine()
    let plan = try await engine.prepareTransfer(sources: [folder], destinationDirectory: fixture.root, move: false)
    let conflict = try #require(plan.conflicts.first)
    #expect(!conflict.canMerge && !conflict.canReplace && plan.entries.first?.children == nil)
    let before = try fixture.historyBytes()
    let rejected = await engine.perform(plan, resolutions: [conflict.id: .replace])
    #expect(rejected.recordID == nil && rejected.result.items.contains { $0.status == .failed(.operationHistoryProtected) })
    #expect(try fixture.historyBytes() == before)
    let kept = await engine.perform(plan, resolutions: [conflict.id: .keepBoth])
    #expect(kept.result.disposition == .succeeded)
    #expect(FileManager().fileExists(atPath: fixture.root.appendingPathComponent("journal (1)/ordinary.txt").path))
    #expect(await engine.undo(recordID: try #require(kept.recordID)).result.disposition == .succeeded)
}

@Test func protectedHistoryAliasesAndCaseVariantsCannotBypassTheBoundary() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    _ = try OperationJournal(fixture.journal)
    let engine = fixture.engine(), file = try fixture.file()
    let alias = fixture.root.appendingPathComponent("History alias")
    try FileManager().createSymbolicLink(at: alias, withDestinationURL: fixture.journal)
    let before = try fixture.historyBytes()
    await #expect(throws: FileOperationFailure.operationHistoryProtected) {
        _ = try await engine.prepareTransfer(sources: [file], destinationDirectory: alias, move: false)
    }
    let metadataAlias = alias.appendingPathComponent(SQLiteJournalStore.name)
    let copied = await engine.perform(.copy(sources: [metadataAlias], destinationDirectory: fixture.destination))
    #expect(copied.recordID == nil && copied.result.items.contains { $0.status == .failed(.operationHistoryProtected) })
    let parent = try DirectoryAnchor(fixture.root, resolve: false)
    if fpathconf(parent.fd, _PC_CASE_SENSITIVE) == 0 {
        let insensitive = fixture.root.appendingPathComponent("JOURNAL", isDirectory: true)
        await #expect(throws: FileOperationFailure.operationHistoryProtected) {
            _ = try await engine.prepareTransfer(sources: [file], destinationDirectory: insensitive, move: false)
        }
        let renamed = await engine.perform(.rename(source: insensitive, name: "Elsewhere"))
        #expect(renamed.recordID == nil && renamed.result.items.contains { $0.status == .failed(.operationHistoryProtected) })
    }
    #expect(try fixture.historyBytes() == before)
}

@Test func protectedHistoryMissingNameCaseVariantsAndMultipleMissingParentsStayReserved() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    let parent = try DirectoryAnchor(fixture.root, resolve: false)
    let engine = fixture.engine()
    if fpathconf(parent.fd, _PC_CASE_SENSITIVE) == 0 {
        let result = await engine.perform(.createFolder(parent: fixture.root, name: "JOURNAL"))
        #expect(result.recordID == nil && result.result.items.contains { $0.status == .failed(.operationHistoryProtected) })
        #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    }
    let nested = RecoverableFileOperations(journalDirectory: fixture.root.appendingPathComponent("Reserved/Nested/history"))
    let result = await nested.perform(.createFolder(parent: fixture.root, name: "Reserved"))
    #expect(result.recordID == nil && result.result.items.contains { $0.status == .failed(.operationHistoryProtected) })
    #expect(!FileManager().fileExists(atPath: fixture.root.appendingPathComponent("Reserved").path))
}

@Test func protectedHistoryAlternateMetadataHardLinkIsRefused() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    _ = try OperationJournal(fixture.journal)
    let link = fixture.source.appendingPathComponent("History metadata link")
    try FileManager().linkItem(at: fixture.journal.appendingPathComponent(SQLiteJournalStore.name), to: link)
    let before = try fixture.historyBytes()
    let result = await fixture.engine().perform(.copy(sources: [link], destinationDirectory: fixture.destination))
    #expect(result.recordID == nil && result.result.items.contains { $0.status == .failed(.operationHistoryProtected) })
    #expect(try fixture.historyBytes() == before)
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}

@Test func protectedHistoryCapturedPlanRejectsAParentRedirectedIntoTheStore() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    _ = try OperationJournal(fixture.journal)
    let engine = fixture.engine(), file = try fixture.file()
    let plan = try await engine.prepareTransfer(sources: [file], destinationDirectory: fixture.destination, move: false)
    try FileManager().moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("Original destination"))
    try FileManager().createSymbolicLink(at: fixture.destination, withDestinationURL: fixture.journal)
    let before = try fixture.historyBytes()
    let result = await engine.perform(plan)
    #expect(result.result.disposition == .failed && result.recordID == nil)
    #expect(try fixture.historyBytes() == before)
    #expect(!FileManager().fileExists(atPath: fixture.journal.appendingPathComponent(file.lastPathComponent).path))
}

@Test func protectedHistoryGuardDoesNotImposeRelativeTreeDepthOnAbsoluteParents() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    var parent = fixture.source
    for _ in 0..<80 {
        parent.appendPathComponent("d", isDirectory: true)
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
    }
    let file = try fixture.file(in: parent), engine = fixture.engine()
    let result = await engine.perform(.copy(sources: [file], destinationDirectory: fixture.destination))
    #expect(result.result.disposition == .succeeded)
    #expect(await engine.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
}

@Test func protectedHistoryFirmlinkSpellingUsesTheSameDirectoryIdentities() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    guard fixture.root.path.hasPrefix("/Volumes/") else { return } // Native mounted-workspace control.
    _ = try OperationJournal(fixture.journal)
    let alias = URL(fileURLWithPath: "/System/Volumes/Data" + fixture.journal.path, isDirectory: true)
    guard FileManager().fileExists(atPath: alias.path) else { return }
    let original = try DirectoryAnchor(fixture.journal, resolve: false), alternate = try DirectoryAnchor(alias, resolve: false)
    #expect(original.identity.sameObject(as: alternate.identity))
    let engine = fixture.engine(), file = try fixture.file(), before = try fixture.historyBytes()
    await #expect(throws: FileOperationFailure.operationHistoryProtected) {
        _ = try await engine.prepareTransfer(sources: [file], destinationDirectory: alias, move: false)
    }
    #expect(try fixture.historyBytes() == before)
}

@Test func protectedHistoryKeepBothCannotClaimTheFutureStoreName() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    let journal = fixture.root.appendingPathComponent("Report (1).txt", isDirectory: true)
    let engine = RecoverableFileOperations(journalDirectory: journal)
    let source = try fixture.file("Report.txt"), target = try fixture.file("Report.txt", in: fixture.root)
    let original = try Data(contentsOf: target)
    let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: fixture.root, move: false)
    let conflict = try #require(plan.conflicts.first)
    let result = await engine.perform(plan, resolutions: [conflict.id: .keepBoth])
    #expect(result.recordID == nil && result.result.items.contains { $0.status == .failed(.operationHistoryProtected) })
    #expect(!FileManager().fileExists(atPath: journal.path))
    #expect(try Data(contentsOf: target) == original && Data(contentsOf: source) == original)
}

@Test func protectedHistoryProductionPreviewRejectsDirectAndRedirectedDestinations() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    let anchor = try DirectoryAnchor(fixture.root, resolve: false)
    let observedVolume = try NativeRenameVolume.qualified(in: anchor)
    let volume = try #require(observedVolume)
    let native = volume.uuid.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    let scope = try #require(QualifiedCopyPreviewScope(volumes: [native, UUID()], historyVolume: native))
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal, qualifiedCopyPreview: scope)
    let files = try (0..<16).map { try fixture.file("Sample-\($0).txt") }
    #expect(await engine.activateCopyPreview(review: { _ in true }, persist: { _ in }) == .enabled)
    await #expect(throws: FileOperationFailure.operationHistoryProtected) {
        _ = try await engine.prepareTransfer(sources: files, destinationDirectory: fixture.journal, move: false, copyExecution: .previewIfAvailable)
    }
    let plan = try await engine.prepareTransfer(sources: files, destinationDirectory: fixture.destination, move: false, copyExecution: .previewIfAvailable)
    #expect(plan.executionDecision == .groupedCopy(maximumMembersPerGroup: 16))
    try FileManager().moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("Original destination"))
    try FileManager().createSymbolicLink(at: fixture.destination, withDestinationURL: fixture.journal)
    let before = try fixture.historyBytes()
    let result = await engine.perform(plan)
    #expect(result.recordID == nil && result.result.items.contains { $0.status == .failed(.operationHistoryProtected) })
    #expect(try fixture.historyBytes() == before)
}

@Test func protectedHistoryMutationGuardRejectsAParentMovedIntoTheStoreByALateCallback() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    _ = try OperationJournal(fixture.journal)
    let file = try fixture.file()
    let moved = fixture.journal.appendingPathComponent("Externally moved destination", isDirectory: true)
    var hooks = RecoveryHooks()
    hooks.beforeExclusiveRename = { _, destination in
        guard destination == fixture.destination.appendingPathComponent(file.lastPathComponent) else { return }
        try FileManager().moveItem(at: fixture.destination, to: moved)
    }
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
    let result = await engine.perform(.copy(sources: [file], destinationDirectory: fixture.destination))
    #expect(result.result.disposition == .failed)
    #expect(!FileManager().fileExists(atPath: moved.appendingPathComponent(file.lastPathComponent).path))
    #expect(try Data(contentsOf: file) == Data("Generated history-protection fixture".utf8))
    // The injected callback moved this parent, not the engine. Its own retained
    // staged payload is honestly reported; the test does not claim a clean store.
    #expect(result.recordID != nil && result.result.items.contains { !$0.recoveryURLs.isEmpty })
}

private final class HistoryRenameGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var hasEntered: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func pauseFirstRename() throws {
        condition.lock(); defer { condition.unlock() }
        if entered { return }
        entered = true
        let deadline = Date().addingTimeInterval(5)
        while !released { guard condition.wait(until: deadline) else { throw FileOperationFailure.unavailable } }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@Test func protectedHistoryChecksDoNotInterruptAReplaceSegmentAfterStop() async throws {
    let fixture = try ProtectedHistoryFixture(); defer { fixture.remove() }
    let source = try fixture.file(), target = try fixture.file(in: fixture.destination)
    try Data("Displaced original".utf8).write(to: target)
    let gate = HistoryRenameGate(); defer { gate.release() }
    var hooks = RecoveryHooks(); hooks.afterRename = { try? gate.pauseFirstRename() }
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
    let plan = try await engine.prepareTransfer(sources: [source], destinationDirectory: fixture.destination, move: false)
    let conflict = try #require(plan.conflicts.first)
    let task = Task { await engine.perform(plan, resolutions: [conflict.id: .replace]) }
    for _ in 0..<500 { if gate.hasEntered { break }; try await Task.sleep(for: .milliseconds(2)) }
    #expect(gate.hasEntered)
    task.cancel(); gate.release()
    let result = await task.value
    #expect(result.result.disposition == .succeeded && result.result.cancellationRequested)
    #expect(try Data(contentsOf: target) == Data(contentsOf: source))
    #expect(await engine.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(try Data(contentsOf: target) == Data("Displaced original".utf8))
}
