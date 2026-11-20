import Foundation
@testable import FileOperations
import Testing

private final class FATRefusalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ next: Bool) { lock.withLock { value = next } }
    func read() -> Bool { lock.withLock { value } }
}

private struct CopyDestinationFixture {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    let bytes = Data("Generated FAT refusal boundary\n".utf8)

    init() throws {
        let base = try FileOperationTestFixtures.base()
        root = base.appendingPathComponent("fat-copy-refusal-" + UUID().uuidString, isDirectory: true)
        source = root.appendingPathComponent("source.txt")
        destination = root.appendingPathComponent("destination", isDirectory: true)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try bytes.write(to: source, options: .withoutOverwriting)
    }

    func unchanged() throws -> Bool {
        try Data(contentsOf: source) == bytes
            && FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty
            && !FileManager.default.fileExists(atPath: journal.path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func recoverableCopyRefusesFATAtPreparationBeforeHistoryOrStaging() async throws {
    let fixture = try CopyDestinationFixture(); defer { fixture.remove() }
    let gate = FATRefusalGate(); gate.set(true)
    var hooks = RecoveryHooks()
    hooks.forceFATCopyDestinationRefusal = { gate.read() }
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
    await #expect(throws: FileOperationFailure.fatTransferDestinationUnsupported) {
        try await engine.prepareTransfer(sources: [fixture.source], destinationDirectory: fixture.destination, move: false)
    }
    #expect(try fixture.unchanged())
}

@Test func recoverableCopyRechecksFATAtExecutionBeforeHistoryOrStaging() async throws {
    let fixture = try CopyDestinationFixture(); defer { fixture.remove() }
    let gate = FATRefusalGate()
    var hooks = RecoveryHooks()
    hooks.forceFATCopyDestinationRefusal = { gate.read() }
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
    let plan = try await engine.prepareTransfer(sources: [fixture.source], destinationDirectory: fixture.destination, move: false)
    gate.set(true)
    let result = await engine.perform(plan)
    #expect(result.recordID == nil)
    #expect(result.result.items.first { $0.role == .job }?.status == .failed(.fatTransferDestinationUnsupported))
    #expect(result.result.items.first { $0.source == fixture.source }?.status == .notStarted)
    #expect(try fixture.unchanged())
}

@Test func crossVolumeMoveRefusalKeepsSourceAndSameVolumeMoveRemainsAvailable() async throws {
    let fixture = try CopyDestinationFixture(); defer { fixture.remove() }
    let crossing = FATRefusalGate(), fat = FATRefusalGate(); fat.set(true)
    var hooks = RecoveryHooks()
    hooks.forceFATCopyDestinationRefusal = { fat.read() }
    hooks.forceCrossVolumeMoveFATRefusal = { crossing.read() }
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)

    crossing.set(true)
    await #expect(throws: FileOperationFailure.fatTransferDestinationUnsupported) {
        try await engine.prepareTransfer(sources: [fixture.source], destinationDirectory: fixture.destination, move: true)
    }
    #expect(try fixture.unchanged())

    crossing.set(false)
    let plan = try await engine.prepareTransfer(sources: [fixture.source], destinationDirectory: fixture.destination, move: true)
    crossing.set(true)
    let refused = await engine.perform(plan)
    #expect(refused.recordID == nil)
    #expect(refused.result.items.first(where: { $0.role == .job })?.status == .failed(.fatTransferDestinationUnsupported))
    #expect(try fixture.unchanged())

    crossing.set(false)
    let sameVolume = try await engine.prepareTransfer(sources: [fixture.source], destinationDirectory: fixture.destination, move: true)
    let moved = await engine.perform(sameVolume)
    #expect(moved.result.disposition == .succeeded)
    #expect(moved.recordID != nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("source.txt")) == fixture.bytes)
}

@Test func legacyCopyRefusesFATInPreflightAndRechecksBeforeStage() async throws {
    let fixture = try CopyDestinationFixture(); defer { fixture.remove() }
    let gate = FATRefusalGate(); gate.set(true)
    var hooks = OperationHooks()
    hooks.forceFATCopyDestinationRefusal = { gate.read() }
    hooks.afterPreflight = { gate.set(true) }
    let engine = LocalFileOperations(trash: { _ in throw FileOperationFailure.unsupported }, hooks: hooks)
    await #expect(throws: FileOperationFailure.fatTransferDestinationUnsupported) {
        try await engine.conflicts(for: .copy(sources: [fixture.source], destinationDirectory: fixture.destination))
    }
    #expect(try fixture.unchanged())
    gate.set(false)
    let result = await engine.perform(.copy(sources: [fixture.source], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.fatTransferDestinationUnsupported))
    #expect(try fixture.unchanged())
}
