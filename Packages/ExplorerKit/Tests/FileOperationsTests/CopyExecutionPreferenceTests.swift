import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct CopyRequestFixture {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    let identity: EntrySnapshot
    private static let marker = Data("Generated Copy request test v1\n".utf8)
    init() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let base = repository.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("copy-request-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let anchor = try DirectoryAnchor(root, resolve: false); identity = anchor.identity
        try OperationJournal.writeExclusive(Self.marker, name: ".copy-request-owner", anchor: anchor)
        source = root.appendingPathComponent("item.dat")
        try OperationJournal.writeExclusive(Data("Generated Copy request payload".utf8), name: "item.dat", anchor: anchor)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        journal = root.appendingPathComponent("journal", isDirectory: true)
    }
    func remove() {
        guard let anchor = try? DirectoryAnchor(root, resolve: false), anchor.identity.sameObject(as: identity),
              (try? OperationJournal.read(name: ".copy-request-owner", anchor: anchor)) == Self.marker else { return }
        try? FileManager().removeItem(at: root)
    }
}

@Test func normalPublicCopyPreviewRequestRemainsClosedAndOrdinary() async throws {
    let fixture = try CopyRequestFixture(); defer { fixture.remove() }
    let engine = RecoverableFileOperations(journalDirectory: fixture.journal)
    #expect(engine.copyPreviewAvailability == .qualificationPending)
    let sourceBefore = try verifiedTree(fixture.source, cancellation: OperationCancellation())
    let plan = try await engine.prepareTransfer(sources: [fixture.source], destinationDirectory: fixture.destination,
                                               move: false, copyExecution: .previewIfAvailable)
    #expect(plan.executionDecision == .standard(.qualificationPending))
    #expect(plan.groupedCopy == nil)
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    let result = await engine.perform(plan)
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    let journal = try OperationJournal(fixture.journal)
    guard case .treeV3? = try journal.inspectCatalogRecord(id) else { Issue.record("Closed public preview request must remain ordinary"); return }
    #expect(sourceBefore.matches(try verifiedTree(fixture.source, cancellation: OperationCancellation())))
}

@Test func ordinaryDefaultAndInternalQualificationKeepEstablishedSelection() async throws {
    let fixture = try CopyRequestFixture(); defer { fixture.remove() }
    let normal = RecoverableFileOperations(journalDirectory: fixture.journal)
    let standard = try await normal.prepareTransfer(sources: [fixture.source], destinationDirectory: fixture.destination, move: false)
    #expect(standard.executionDecision == .standard(.previewOff) && standard.groupedCopy == nil)
    let root = try DirectoryAnchor(fixture.root, resolve: false)
    try OperationJournal.writeExclusive(GroupedCopyQualification.marker, name: GroupedCopyQualification.markerName, anchor: root)
    var hooks = RecoveryHooks(); hooks.groupedCopy.qualification = try GroupedCopyQualification(root: fixture.root)
    let legacy = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
    let legacyPlan = try await legacy.prepareTransfer(sources: [fixture.source], destinationDirectory: fixture.destination, move: false)
    #expect(legacyPlan.groupedCopy != nil)
    #expect(legacyPlan.executionDecision == .groupedCopy(maximumMembersPerGroup: 16))
}

#if DEBUG
private struct GeneratedCopyRequestFixture {
    let run: URL
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    let inputs: [URL]
    let runIdentity: EntrySnapshot
    let marker: Data
    init(count: Int = 17) throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let base = repository.appendingPathComponent(".build/grouped-copy-production", isDirectory: true)
        _ = try DirectoryAnchor(base.deletingLastPathComponent(), resolve: false)
        if mkdir(base.path, 0o700) != 0, errno != EEXIST { throw posixFailure() }
        let baseAnchor = try DirectoryAnchor(base, resolve: false)
        var info = stat()
        guard fstat(baseAnchor.fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw FileOperationFailure.invalidRequest }
        run = base.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager().createDirectory(at: run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let runAnchor = try DirectoryAnchor(run, resolve: false); runIdentity = runAnchor.identity
        marker = Data("MacExplorer grouped production qualification v1\n\(run.lastPathComponent)\n".utf8)
        try OperationJournal.writeExclusive(marker, name: ".qualification-owner", anchor: runAnchor)
        let fixtures = run.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager().createDirectory(at: fixtures, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = fixtures.appendingPathComponent("copy-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let rootAnchor = try DirectoryAnchor(root, resolve: false)
        try OperationJournal.writeExclusive(Data("MacExplorer generated grouped production fixture v1\n\(root.lastPathComponent)\n".utf8),
                                           name: ".owned-grouped-production-fixture", anchor: rootAnchor)
        try OperationJournal.writeExclusive(GroupedCopyQualification.marker, name: GroupedCopyQualification.markerName, anchor: rootAnchor)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager().createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sources = source
        inputs = (0..<count).map { sources.appendingPathComponent($0 % 2 == 0 ? "Case-\($0).txt" : "caf\u{00E9}-\($0).txt") }
        let sourceAnchor = try DirectoryAnchor(source, resolve: false)
        for (ordinal, url) in inputs.enumerated() {
            try OperationJournal.writeExclusive(Data(repeating: UInt8(ordinal), count: ordinal == 0 ? 0 : 4096), name: url.lastPathComponent, anchor: sourceAnchor)
        }
        let seed = ["count": String(count), "sourceFingerprint": String(repeating: "0", count: 64), "emptyDestinationFingerprint": String(repeating: "0", count: 64)]
        try OperationJournal.writeExclusive(try JSONEncoder().encode(seed), name: "seed.json", anchor: rootAnchor)
    }
    func remove() {
        guard let anchor = try? DirectoryAnchor(run, resolve: false), anchor.identity.sameObject(as: runIdentity),
              (try? OperationJournal.read(name: ".qualification-owner", anchor: anchor)) == marker else { return }
        try? FileManager().removeItem(at: run)
    }
}

@Test(arguments: [TransferMetadataPolicy.strict, .destinationOwnership])
func generatedCopySessionRequiresCapturedRequestAndProducesTypedJob(policy: TransferMetadataPolicy) async throws {
    let fixture = try GeneratedCopyRequestFixture(); defer { fixture.remove() }
    let engine = try await RecoverableFileOperations.generatedCopyVerificationSession(in: fixture.root)
    #expect(engine.copyPreviewAvailability == .available)
    let standard = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination, move: false)
    #expect(standard.groupedCopy == nil && standard.executionDecision == .standard(.previewOff))
    let grouped = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination,
        move: false, metadataPolicy: policy, copyExecution: .previewIfAvailable)
    #expect(grouped.executionDecision == .groupedCopy(maximumMembersPerGroup: 16))
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    let result = await engine.perform(grouped)
    #expect(result.result.disposition == .succeeded)
    let id = try #require(result.recordID)
    let journal = try OperationJournal(fixture.journal)
    guard case .groupedCopyV1(let record)? = try journal.inspectCatalogRecord(id) else { Issue.record("Generated public session did not produce typed grouped history"); return }
    #expect(record.members.count == 17 && record.groups.count == 2 && record.head.metadataPolicy == policy)
}

@Test func generatedCopySessionRefusesLookalikeAndEscapedLocations() async throws {
    let fake = try CopyRequestFixture(); defer { fake.remove() }
    do { _ = try await RecoverableFileOperations.generatedCopyVerificationSession(in: fake.root); Issue.record("Lookalike generated session was accepted") }
    catch {}
    let fixture = try GeneratedCopyRequestFixture(count: 1); defer { fixture.remove() }
    let engine = try await RecoverableFileOperations.generatedCopyVerificationSession(in: fixture.root)
    do {
        _ = try await engine.prepareTransfer(sources: [fake.source], destinationDirectory: fixture.destination, move: false)
        Issue.record("Standard fallback escaped generated session authority")
    } catch {}
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    let foreign = RecoverableFileOperations(journalDirectory: fake.journal)
    let foreignPlan = try await foreign.prepareTransfer(sources: [fake.source], destinationDirectory: fake.destination, move: false)
    let foreignRefusal = await engine.perform(foreignPlan)
    #expect(foreignRefusal.result.disposition == .failed)
    #expect(!FileManager().fileExists(atPath: fake.destination.appendingPathComponent(fake.source.lastPathComponent).path))
    let refusal = await engine.perform(.createFolder(parent: fake.destination, name: "must-not-create"))
    #expect(refusal.result.disposition == .failed)
    #expect(!FileManager().fileExists(atPath: fake.destination.appendingPathComponent("must-not-create").path))
}

@Test func generatedCopySessionFallsBackForWholeMoveAndConflictBeforeMutation() async throws {
    let fixture = try GeneratedCopyRequestFixture(count: 1); defer { fixture.remove() }
    let engine = try await RecoverableFileOperations.generatedCopyVerificationSession(in: fixture.root)
    let moved = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination,
                                                move: true, copyExecution: .previewIfAvailable)
    #expect(moved.groupedCopy == nil && moved.executionDecision == .standard(.move))
    let target = try DirectoryAnchor(fixture.destination, resolve: false)
    try OperationJournal.writeExclusive(Data("Generated conflict".utf8), name: fixture.inputs[0].lastPathComponent, anchor: target)
    let conflicted = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination,
                                                     move: false, copyExecution: .previewIfAvailable)
    #expect(conflicted.groupedCopy == nil && conflicted.executionDecision == .standard(.destinationConflict))
    #expect(conflicted.conflicts.count == 1 && !FileManager().fileExists(atPath: fixture.journal.path))
}

@Test func generatedCopySessionFolderFallbackDoesNotPartitionJob() async throws {
    let fixture = try GeneratedCopyRequestFixture(count: 1); defer { fixture.remove() }
    let engine = try await RecoverableFileOperations.generatedCopyVerificationSession(in: fixture.root)
    let folder = fixture.source.appendingPathComponent("generated-folder", isDirectory: true)
    try FileManager().createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let plan = try await engine.prepareTransfer(sources: fixture.inputs + [folder], destinationDirectory: fixture.destination,
                                              move: false, copyExecution: .previewIfAvailable)
    #expect(plan.groupedCopy == nil && plan.executionDecision == .standard(.unsupportedInput))
    #expect(plan.sources.count == 2 && !FileManager().fileExists(atPath: fixture.journal.path))
}

@Test func generatedCopySessionRejectsSymlinkRootAndLaterDestinationAlias() async throws {
    let fixture = try GeneratedCopyRequestFixture(count: 1); defer { fixture.remove() }
    let alias = fixture.root.deletingLastPathComponent().appendingPathComponent("copy-" + UUID().uuidString, isDirectory: true)
    try FileManager().createSymbolicLink(at: alias, withDestinationURL: fixture.root)
    do { _ = try await RecoverableFileOperations.generatedCopyVerificationSession(in: alias); Issue.record("Symlink fixture root was accepted") }
    catch {}
    let engine = try await RecoverableFileOperations.generatedCopyVerificationSession(in: fixture.root)
    let other = try CopyRequestFixture(); defer { other.remove() }
    try FileManager().removeItem(at: fixture.destination) // This exact generated directory is still empty.
    try FileManager().createSymbolicLink(at: fixture.destination, withDestinationURL: other.destination)
    do {
        _ = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination,
                                             move: false, copyExecution: .standard)
        Issue.record("Later destination alias escaped standard fixture fallback")
    } catch {}
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    #expect(!FileManager().fileExists(atPath: other.destination.appendingPathComponent(fixture.inputs[0].lastPathComponent).path))
}
#endif
