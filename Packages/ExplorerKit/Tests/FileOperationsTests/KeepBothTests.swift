import Darwin
import Foundation
@_spi(ArchiveProduction) @testable import FileOperations
import Testing

private struct KeepBothFixture {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("keep-both-" + UUID().uuidString)
        source = root.appendingPathComponent("source"); destination = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("journal")
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager().createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
    }
    func file(_ name: String, in parent: URL? = nil, text: String = "incoming") throws -> URL {
        let url = (parent ?? source).appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .withoutOverwriting); return url
    }
    func service(_ hooks: RecoveryHooks = RecoveryHooks()) -> RecoverableFileOperations {
        RecoverableFileOperations(journalDirectory: journal, hooks: hooks)
    }
    func remove() { try? FileManager().removeItem(at: root) }
}

private final class KeepBothOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.withLock { if used { return false }; used = true; return true } }
}

@Test(arguments: [
    ("Report.pdf", true, "Report (1).pdf"), ("Photos", false, "Photos (1)"),
    ("Photos.backup", false, "Photos.backup (1)"), ("Example.app", true, "Example (1).app"),
    (".env", true, ".env (1)"), ("archive.tar.gz", true, "archive.tar (1).gz"),
    ("日本語 café.txt", true, "日本語 café (1).txt")
])
func keepBothNumberedNames(_ input: (String, Bool, String)) throws {
    #expect(try DuplicateDestination.name(input.0, preservesExtension: input.1, number: 1) == input.2)
}

@Test func keepBothLongUnicodeNameRetainsExtension() throws {
    let original = String(repeating: "é", count: 125) + ".txt"
    let result = try DuplicateDestination.name(original, preservesExtension: true, number: 10_000)
    #expect(result.utf8.count <= 255 && result.hasSuffix(" (10000).txt"))
    #expect(throws: FileOperationFailure.invalidRequest) {
        try DuplicateDestination.name("name", preservesExtension: false, number: 0)
    }
}

@Test func keepBothCopyReservesOtherPlannedNamesAndUndo() async throws {
    let f = try KeepBothFixture(); defer { f.remove() }
    let first = try f.file("Report.pdf"), second = try f.file("Report (1).pdf", text: "second source")
    let existing = try f.file("Report.pdf", in: f.destination, text: "existing")
    let occupied = try f.file("Report (2).pdf", in: f.destination, text: "numbered existing")
    let service = f.service()
    let plan = try await service.prepareTransfer(sources: [first, second], destinationDirectory: f.destination, move: false)
    let result = await service.perform(plan, resolutions: [try #require(plan.conflicts.first).id: .keepBoth])
    #expect(result.result.disposition == .succeeded)
    #expect(result.result.items.first?.destination?.lastPathComponent == "Report (3).pdf")
    #expect(try Data(contentsOf: f.destination.appendingPathComponent("Report (3).pdf")) == Data("incoming".utf8))
    #expect(try Data(contentsOf: f.destination.appendingPathComponent("Report (1).pdf")) == Data("second source".utf8))
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(!FileManager().fileExists(atPath: f.destination.appendingPathComponent("Report (3).pdf").path))
    #expect(try Data(contentsOf: existing) == Data("existing".utf8))
    #expect(try Data(contentsOf: occupied) == Data("numbered existing".utf8))
    #expect(try Data(contentsOf: first) == Data("incoming".utf8))
}

@Test(arguments: [false, true])
func keepBothFolderTreeCopyOrMoveAndUndo(_ move: Bool) async throws {
    let f = try KeepBothFixture(); defer { f.remove() }
    let source = f.source.appendingPathComponent("Photos"), existing = f.destination.appendingPathComponent("Photos")
    try FileManager().createDirectory(at: source, withIntermediateDirectories: false)
    try FileManager().createDirectory(at: existing, withIntermediateDirectories: false)
    _ = try f.file("child.txt", in: source); _ = try f.file("old.txt", in: existing, text: "untouched")
    let service = f.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: move)
    let result = await service.perform(plan, resolutions: [try #require(plan.conflicts.first).id: .keepBoth])
    #expect(result.result.disposition == .succeeded)
    #expect(try Data(contentsOf: f.destination.appendingPathComponent("Photos (1)/child.txt")) == Data("incoming".utf8))
    #expect(FileManager().fileExists(atPath: source.path) == !move)
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(try Data(contentsOf: source.appendingPathComponent("child.txt")) == Data("incoming".utf8))
    #expect(try Data(contentsOf: existing.appendingPathComponent("old.txt")) == Data("untouched".utf8))
}

@Test func keepBothSameFolderCopyAndReplaceRefusal() async throws {
    let f = try KeepBothFixture(); defer { f.remove() }
    let source = try f.file("Report.pdf"), service = f.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: f.source, move: false)
    #expect(plan.conflicts.count == 1 && plan.conflicts.first?.canReplace == false && plan.conflicts.first?.canMerge == false)
    #expect(await service.perform(plan, resolutions: [plan.conflicts[0].id: .replace]).result.disposition == .failed)
    #expect(!FileManager().fileExists(atPath: f.journal.path))
    let result = await service.perform(plan, resolutions: [plan.conflicts[0].id: .keepBoth])
    #expect(result.result.disposition == .succeeded)
    #expect(try Data(contentsOf: f.source.appendingPathComponent("Report (1).pdf")) == Data("incoming".utf8))
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(try Data(contentsOf: source) == Data("incoming".utf8))
}

@Test func keepBothNewOccupantAfterAdmissionIsPreserved() async throws {
    let f = try KeepBothFixture(); defer { f.remove() }
    let source = try f.file("Report.pdf"), existing = try f.file("Report.pdf", in: f.destination, text: "existing")
    let selected = f.destination.appendingPathComponent("Report (1).pdf")
    var hooks = RecoveryHooks()
    hooks.afterAdmission = { try? Data("new occupant".utf8).write(to: selected, options: .withoutOverwriting) }
    let service = f.service(hooks)
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
    let result = await service.perform(plan, resolutions: [plan.conflicts[0].id: .keepBoth])
    #expect(result.result.disposition != .succeeded)
    #expect(try Data(contentsOf: selected) == Data("new occupant".utf8))
    #expect(try Data(contentsOf: source) == Data("incoming".utf8))
    #expect(try Data(contentsOf: existing) == Data("existing".utf8))
    #expect(!FileManager().fileExists(atPath: f.destination.appendingPathComponent("Report (2).pdf").path))
}

@Test func keepBothChangedConflictBeforeChoiceStops() async throws {
    let f = try KeepBothFixture(); defer { f.remove() }
    let source = try f.file("Report.pdf"), existing = try f.file("Report.pdf", in: f.destination, text: "existing")
    let service = f.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: false)
    try Data("edited destination".utf8).write(to: existing)
    #expect(await service.perform(plan, resolutions: [plan.conflicts[0].id: .keepBoth]).result.disposition == .failed)
    #expect(!FileManager().fileExists(atPath: f.journal.path))
    #expect(!FileManager().fileExists(atPath: f.destination.appendingPathComponent("Report (1).pdf").path))
    #expect(try Data(contentsOf: source) == Data("incoming".utf8))
}

@Test func keepBothContinuesPreviouslySkippedFolder() async throws {
    let f = try KeepBothFixture(); defer { f.remove() }
    let source = f.source.appendingPathComponent("Photos"), existing = f.destination.appendingPathComponent("Photos")
    try FileManager().createDirectory(at: source, withIntermediateDirectories: false)
    try FileManager().createDirectory(at: existing, withIntermediateDirectories: false)
    _ = try f.file("child.txt", in: source); _ = try f.file("old.txt", in: existing, text: "untouched")
    let service = f.service()
    let plan = try await service.prepareTransfer(sources: [source], destinationDirectory: f.destination, move: true)
    let skipped = await service.perform(plan, resolutions: Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, .skip) }))
    let next = try await service.prepareContinuation(try #require(skipped.continuation))
    let result = await service.perform(next, resolutions: [next.conflicts[0].id: .keepBoth])
    #expect(result.result.disposition == .succeeded)
    #expect(await service.undo(recordID: try #require(result.recordID)).result.disposition == .succeeded)
    #expect(try Data(contentsOf: source.appendingPathComponent("child.txt")) == Data("incoming".utf8))
    #expect(try Data(contentsOf: existing.appendingPathComponent("old.txt")) == Data("untouched".utf8))
}

@Test func keepBothStopRetainsChosenNamesForContinuationAndSeparateUndo() async throws {
    let f = try KeepBothFixture(); defer { f.remove() }
    let first = try f.file("first.txt"), second = try f.file("second.txt")
    _ = try f.file("first.txt", in: f.destination, text: "old first")
    _ = try f.file("second.txt", in: f.destination, text: "old second")
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), once = KeepBothOnce()
    let service = f.service(RecoveryHooks(afterRename: {
        if once.take() { entered.signal(); _ = release.wait(timeout: .now() + 15) }
    }))
    let plan = try await service.prepareTransfer(sources: [first, second], destinationDirectory: f.destination, move: true)
    let task = Task { await service.perform(plan, resolutions: Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, .keepBoth) })) }
    let reached = await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 15) == .success) }
    }
    task.cancel(); release.signal()
    let stopped = await task.value
    try #require(reached)
    let token = try #require(stopped.continuation)
    #expect(token.remainingSources == [second])
    #expect(token.units.first?.entry.destination.lastPathComponent == "second (1).txt")
    let next = try await service.prepareContinuation(token)
    #expect(next.conflicts.isEmpty)
    let continued = await service.perform(next)
    #expect(continued.result.disposition == .succeeded)
    #expect(await service.undo(recordID: try #require(continued.recordID)).result.disposition == .succeeded)
    #expect(await service.undo(recordID: try #require(stopped.recordID)).result.disposition == .succeeded)
    #expect(try Data(contentsOf: first) == Data("incoming".utf8))
    #expect(try Data(contentsOf: second) == Data("incoming".utf8))
    #expect(try Data(contentsOf: f.destination.appendingPathComponent("first.txt")) == Data("old first".utf8))
    #expect(try Data(contentsOf: f.destination.appendingPathComponent("second.txt")) == Data("old second".utf8))
}
