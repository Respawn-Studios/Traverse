import Darwin
import Foundation
@testable import FileOperations
import Testing

/// Independent forward qualification uses only newly generated files in this
/// marked root. Execution tests are added after the production seam is frozen.
private struct GroupedForwardFixture: Sendable {
    struct Input: Sendable {
        let url: URL
        let literalName: Data
        let body: Data
        let before: VerifiedTree
    }

    let root: URL
    let source: URL
    let destination: URL
    let ordinaryDestination: URL
    let journal: URL
    let ordinaryJournal: URL
    private let marker: Data

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("grouped-forward-" + UUID().uuidString, isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        ordinaryDestination = root.appendingPathComponent("ordinary-destination", isDirectory: true)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        ordinaryJournal = root.appendingPathComponent("ordinary-journal", isDirectory: true)
        marker = Data(("MacExplorer grouped forward generated fixture v1:" + UUID().uuidString).utf8)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try marker.write(to: root.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
        try OperationJournal.writeExclusive(GroupedCopyQualification.marker,
            name: GroupedCopyQualification.markerName, anchor: DirectoryAnchor(root, resolve: false))
        for directory in [source, destination, ordinaryDestination] {
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
    }

    func remove() {
        guard root.resolvingSymlinksInPath().path == root.path,
              (try? Data(contentsOf: root.appendingPathComponent(".fixture-owner"))) == marker else { return }
        try? FileManager().removeItem(at: root)
    }

    /// Use the literal native name, rather than a URL round trip, for creation.
    func file(_ name: String, ordinal: Int = 0, in parent: URL? = nil) throws -> Input {
        let parent = parent ?? source
        let anchor = try DirectoryAnchor(parent, resolve: false)
        let body = Data(("generated grouped forward input \(ordinal)\n" + String(repeating: "q", count: ordinal % 31)).utf8)
        let fd = openat(anchor.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        try body.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw posixFailure() }
                offset += written
            }
        }
        guard fchmod(fd, 0o640) == 0, fsync(fd) == 0 else { throw posixFailure() }
        let url = parent.appendingPathComponent(name)
        return Input(url: url, literalName: Data(name.utf8), body: body,
            before: try verifiedTree(parent: anchor.fd, name: name, cancellation: OperationCancellation()))
    }

    func files(_ count: Int) throws -> [Input] {
        try (0..<count).map { try file("member-\($0).txt", ordinal: $0) }
    }

    func literalFiles() throws -> [Input] {
        let names = ["extensionless", "UPPER.txt", ".hidden", " spaces ",
            "single-'quote.txt", "composed-\u{e9}.txt", "decomposed-e\u{301}.txt",
            String(repeating: "n", count: Int(MAXNAMLEN) - 4) + ".txt"]
        return try names.enumerated().map { try file($0.element, ordinal: $0.offset) }
    }

    func names(in directory: URL) throws -> Set<Data> {
        let anchor = try DirectoryAnchor(directory, resolve: false)
        let readable = openat(anchor.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard readable >= 0 else { throw posixFailure() }
        defer { close(readable) }
        return Set(try childNames(in: readable, cancellation: OperationCancellation(), limit: 4096)
            .map { Data($0.utf8) })
    }

    func assertSourcesPreserved(_ inputs: [Input]) throws {
        for input in inputs {
            let current = try verifiedTree(input.url, cancellation: OperationCancellation())
            #expect(input.before.matches(current))
            #expect(current.identity == input.before.identity)
            #expect(try Data(contentsOf: input.url) == input.body)
        }
    }

    /// Compare generated results independently from their journal flags. Strict
    /// fingerprints include metadata; identity separately proves a Copy object.
    enum NameSpelling { case nativeInput, foundationURL }
    func assertCopied(_ inputs: [Input], into parent: URL, spelling: NameSpelling = .nativeInput) throws {
        let nativeNames = try names(in: parent)
        for input in inputs {
            let target = parent.appendingPathComponent(String(decoding: input.literalName, as: UTF8.self))
            let expectedName = spelling == .nativeInput ? input.literalName : Data(target.lastPathComponent.utf8)
            #expect(nativeNames.contains(expectedName))
            #expect(try Data(contentsOf: target) == input.body)
            let copy = try verifiedTree(target, cancellation: OperationCancellation())
            #expect(copy.digest == input.before.digest)
            #expect(!copy.identity.sameObject(as: input.before.identity))
        }
        try assertSourcesPreserved(inputs)
    }

    func assertOrdinaryEquivalent(_ inputs: [Input]) throws {
        try assertCopied(inputs, into: destination)
        // Ordinary Copy already publishes Foundation's decomposed URL spelling.
        // Grouped Copy must retain the native input bytes, rather than repeat
        // that inherited difference. Both paths still match body and metadata.
        try assertCopied(inputs, into: ordinaryDestination, spelling: .foundationURL)
        for input in inputs {
            let name = String(decoding: input.literalName, as: UTF8.self)
            let grouped = try verifiedTree(destination.appendingPathComponent(name), cancellation: OperationCancellation())
            let ordinary = try verifiedTree(ordinaryDestination.appendingPathComponent(name), cancellation: OperationCancellation())
            #expect(grouped.digest == ordinary.digest)
        }
    }

    func service(grouped: Bool = true, groupSize: Int = 16, hooks: RecoveryHooks = RecoveryHooks()) throws -> RecoverableFileOperations {
        var configured = hooks
        if grouped { configured.groupedCopy.qualification = try GroupedCopyQualification(root: root, groupSize: groupSize) }
        return RecoverableFileOperations(journalDirectory: grouped ? journal : ordinaryJournal, hooks: configured)
    }

    func record(_ id: UUID) throws -> GroupedCopyRecord {
        let store = try OperationJournal(journal)
        guard case .groupedCopyV1(let record)? = try store.inspectCatalogRecord(id) else {
            throw FileOperationFailure.recoveryUncertain
        }
        return record
    }
}

/// Hook callbacks run off main and must expose causal ordering without sleeps.
private final class GroupedForwardProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [GroupedCopyCheckpoint] = []
    private var sawMain = false
    func record(_ event: GroupedCopyCheckpoint) {
        lock.withLock { events.append(event); sawMain = sawMain || Thread.isMainThread }
    }
    var snapshot: [GroupedCopyCheckpoint] { lock.withLock { events } }
    var ranOnMain: Bool { lock.withLock { sawMain } }
}

@Test(arguments: [TransferMetadataPolicy.strict, .destinationOwnership])
func groupedForwardLiteralFilesMatchOrdinaryCopy(policy: TransferMetadataPolicy) async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let inputs = try fixture.literalFiles()
    let sourceURLs = inputs.map(\.url)
    let grouped = try fixture.service()
    let plan = try await grouped.prepareTransfer(sources: sourceURLs, destinationDirectory: fixture.destination,
        move: false, metadataPolicy: policy)
    #expect(plan.groupedCopy != nil)
    #expect(plan.metadataPolicy == policy)
    let copied = await grouped.perform(plan)
    let ordinary = try await fixture.service(grouped: false).perform(.copy(sources: sourceURLs,
        destinationDirectory: fixture.ordinaryDestination), metadataPolicy: policy)
    #expect(copied.result.items.map(\.status) == ordinary.result.items.map(\.status))
    #expect(copied.result.disposition == .succeeded && ordinary.result.disposition == .succeeded)
    #expect(copied.result.items.allSatisfy { $0.status == .succeeded })
    let record = try fixture.record(try #require(copied.recordID))
    #expect(record.head.state == .completed)
    #expect(record.head.metadataPolicy == policy)
    #expect(record.members.map { $0.manifest.destination.nameBytes } == inputs.map(\.literalName))
    try fixture.assertOrdinaryEquivalent(inputs)
}

@Test(arguments: [1, 16, 17, 31, 33])
func groupedForwardExplicitTailsAndAcknowledgedCompletion(count: Int) async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let inputs = try fixture.files(count)
    let probe = GroupedForwardProbe()
    var hooks = RecoveryHooks()
    hooks.groupedCopy.checkpoint = { event, _ in probe.record(event) }
    let service = try fixture.service(hooks: hooks)
    let plan = try await service.prepareTransfer(sources: inputs.map(\.url), destinationDirectory: fixture.destination, move: false)
    #expect(plan.groupedCopy != nil)
    let result = await service.perform(plan)
    #expect(result.result.items.compactMap(\.source) == inputs.map(\.url))
    #expect(result.result.items.allSatisfy { $0.status == .succeeded })
    let id = try #require(result.recordID)
    let record = try fixture.record(id)
    #expect(record.head.state == .completed)
    #expect(record.members.count == count)
    #expect(record.groups.map(\.members) == stride(from: 0, to: count, by: 16).map { Array($0..<min($0 + 16, count)) })
    #expect(record.groups.allSatisfy { $0.phase == .settled })
    #expect(record.members.allSatisfy { $0.progress.phase == "published" })
    let events = probe.snapshot
    #expect(!probe.ranOnMain)
    #expect(events.allSatisfy { $0.jobID == plan.jobID && $0.recordID == id })
    #expect(events.filter { $0.stage == .memberPublished }.compactMap(\.memberOrdinal) == Array(0..<count))
    #expect(events.last?.stage == .terminalCommitted)
    for group in record.groups.dropFirst() {
        let predecessor = try #require(events.firstIndex { $0.stage == .groupOutcomesRecorded && $0.groupOrdinal == group.ordinal - 1 })
        let next = try #require(events.firstIndex { $0.stage == .groupWillDeclare && $0.groupOrdinal == group.ordinal })
        #expect(predecessor < next)
    }
    try fixture.assertCopied(inputs, into: fixture.destination)
}

private enum GroupedForwardUnsupported: String, CaseIterable, Sendable { case folder, symbolicLink, hardLink }

@Test(arguments: GroupedForwardUnsupported.allCases)
private func groupedForwardUnsupportedSeventeenthMemberSelectsWholeOrdinaryJob(kind: GroupedForwardUnsupported) async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let inputs = try fixture.files(16)
    let tail = fixture.source.appendingPathComponent("unsupported-tail")
    switch kind {
    case .folder:
        try FileManager().createDirectory(at: tail, withIntermediateDirectories: false)
        _ = try fixture.file("inside", in: tail)
    case .symbolicLink: try FileManager().createSymbolicLink(at: tail, withDestinationURL: inputs[0].url)
    case .hardLink:
        let original = try fixture.file("unselected-hardlink-original", ordinal: 99)
        try FileManager().linkItem(at: original.url, to: tail)
    }
    let tailBefore = try verifiedTree(tail, cancellation: OperationCancellation())
    let probe = GroupedForwardProbe()
    var hooks = RecoveryHooks(); hooks.groupedCopy.checkpoint = { event, _ in probe.record(event) }
    let service = try fixture.service(hooks: hooks)
    let plan = try await service.prepareTransfer(sources: inputs.map(\.url) + [tail], destinationDirectory: fixture.destination, move: false)
    #expect(plan.groupedCopy == nil)
    let result = await service.perform(plan)
    let ordinary = try await fixture.service(grouped: false).perform(.copy(sources: inputs.map(\.url) + [tail],
        destinationDirectory: fixture.ordinaryDestination))
    #expect(probe.snapshot.isEmpty)
    #expect(result.result.items.map(\.status) == ordinary.result.items.map(\.status))
    #expect(result.result.items.filter { $0.role == .transfer }.count == 17)
    if kind == .hardLink {
        // Existing ordinary Copy refuses an isolated selected hard link because
        // its nlink=2 structure cannot match a newly copied nlink=1 object.
        let expected: [FileOperationStatus] = Array(repeating: .succeeded, count: 16) + [.failed(.copyContentMismatch)]
        #expect(result.result.items.map(\.status) == expected)
        #expect(ordinary.result.items.map(\.status) == expected)
        #expect(result.result.disposition == .partial && ordinary.result.disposition == .partial)
        try fixture.assertCopied(inputs, into: fixture.destination)
        try fixture.assertCopied(inputs, into: fixture.ordinaryDestination)
        #expect(!FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("unsupported-tail").path))
        #expect(!FileManager().fileExists(atPath: fixture.ordinaryDestination.appendingPathComponent("unsupported-tail").path))
    } else {
        #expect(result.result.disposition == .succeeded && ordinary.result.disposition == .succeeded)
        #expect(result.result.items.allSatisfy { $0.status == .succeeded })
    }
    try fixture.assertSourcesPreserved(inputs)
    let tailAfter = try verifiedTree(tail, cancellation: OperationCancellation())
    #expect(tailBefore.matches(tailAfter) && tailBefore.identity == tailAfter.identity)
}

@Test func groupedForwardDuplicateWholeJobRefusesWithoutStaging() async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let input = try fixture.file("repeated")
    let service = try fixture.service()
    await #expect(throws: (any Error).self) {
        _ = try await service.prepareTransfer(sources: [input.url, input.url], destinationDirectory: fixture.destination, move: false)
    }
    #expect(try fixture.names(in: fixture.destination).isEmpty)
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    try fixture.assertSourcesPreserved([input])
}

@Test func groupedForwardInheritedControlCharacterPolicyRefusesWholeJob() async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let supported = try fixture.file("ordinary-input")
    let controlName = try fixture.file("line\nbreak.txt")
    let sourceNames = try fixture.names(in: fixture.source)
    for grouped in [true, false] {
        let service = try fixture.service(grouped: grouped)
        await #expect(throws: FileOperationFailure.invalidRequest) {
            _ = try await service.prepareTransfer(sources: [supported.url, controlName.url],
                destinationDirectory: grouped ? fixture.destination : fixture.ordinaryDestination, move: false)
        }
    }
    #expect(try fixture.names(in: fixture.source) == sourceNames)
    #expect(try fixture.names(in: fixture.destination).isEmpty)
    #expect(try fixture.names(in: fixture.ordinaryDestination).isEmpty)
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    #expect(!FileManager().fileExists(atPath: fixture.ordinaryJournal.path))
    // Descriptor-based checks keep the intentionally unsupported name outside
    // path validation, while proving the original object/bytes remain intact.
    let anchor = try DirectoryAnchor(fixture.source, resolve: false)
    for input in [supported, controlName] {
        let name = String(decoding: input.literalName, as: UTF8.self)
        #expect(try EntrySnapshot(parent: anchor.fd, name: name) == input.before.identity)
        #expect(input.before.matches(try verifiedTree(parent: anchor.fd, name: name, cancellation: OperationCancellation())))
    }
}

@Test(arguments: [GroupedCopyCheckpointStage.groupWillDeclare, .groupDeclared, .groupCreated,
    .memberWillStage, .memberStaged, .groupSealed, .memberPublished, .memberSynced,
    .groupOutcomesRecorded, .terminalWillCommit])
func groupedForwardStopRetainsOnlyAcknowledgedSubset(stage: GroupedCopyCheckpointStage) async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let inputs = try fixture.files(17)
    let probe = GroupedForwardProbe()
    var hooks = RecoveryHooks()
    hooks.groupedCopy.checkpoint = { event, cancellation in
        probe.record(event)
        if event.stage == stage { cancellation.cancel() }
    }
    let service = try fixture.service(hooks: hooks)
    let plan = try await service.prepareTransfer(sources: inputs.map(\.url), destinationDirectory: fixture.destination, move: false)
    let result = await service.perform(plan)
    #expect(result.result.cancellationRequested)
    let record = try fixture.record(try #require(result.recordID))
    let publications = record.members.filter { $0.progress.phase == "published" }
    let visible = try fixture.names(in: fixture.destination)
    #expect(publications.allSatisfy { visible.contains($0.manifest.destination.nameBytes) })
    #expect(result.result.items.filter { $0.status == .succeeded }.count == publications.count)
    if stage == .memberPublished || stage == .memberSynced {
        #expect(publications.map(\.ordinal) == [0])
        #expect(probe.snapshot.contains { $0.stage == .memberSynced && $0.memberOrdinal == 0 })
        #expect(!probe.snapshot.contains { $0.stage == .memberPublished && $0.memberOrdinal == 1 })
    }
    if stage != .terminalWillCommit {
        #expect(!probe.snapshot.contains { $0.stage == .groupDeclared && $0.groupOrdinal == 1 })
    }
    #expect(![.completed, .undone].contains(record.head.state) || stage == .terminalWillCommit)
    try fixture.assertSourcesPreserved(inputs)
}

@Test func groupedForwardConflictAfterAdmissionDoesNotReplaceOrCreateJournal() async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let inputs = try fixture.files(17)
    let service = try fixture.service()
    let plan = try await service.prepareTransfer(sources: inputs.map(\.url), destinationDirectory: fixture.destination, move: false)
    let replacement = try fixture.file("member-16.txt", ordinal: 99, in: fixture.destination)
    let result = await service.perform(plan)
    #expect(result.result.disposition != .succeeded)
    #expect(result.recordID == nil)
    #expect(try fixture.names(in: fixture.destination) == [replacement.literalName])
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    try fixture.assertSourcesPreserved(inputs + [replacement])
}

@Test func groupedForwardEqualBytesDifferentSourceObjectRefusesBeforeDeclaration() async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let input = try fixture.file("input")
    let service = try fixture.service()
    let plan = try await service.prepareTransfer(sources: [input.url], destinationDirectory: fixture.destination, move: false)
    let retained = fixture.source.appendingPathComponent("retained-original")
    try FileManager().moveItem(at: input.url, to: retained)
    try input.body.write(to: input.url, options: .withoutOverwriting)
    let replacement = try verifiedTree(input.url, cancellation: OperationCancellation())
    let result = await service.perform(plan)
    #expect(result.result.disposition != .succeeded)
    #expect(result.recordID == nil)
    #expect(try fixture.names(in: fixture.destination).isEmpty)
    #expect(!FileManager().fileExists(atPath: fixture.journal.path))
    #expect(replacement.matches(try verifiedTree(input.url, cancellation: OperationCancellation())))
    #expect(try Data(contentsOf: retained) == input.body)
}

@Test func groupedForwardReplacedDestinationParentIsNotAdopted() async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let input = try fixture.file("input")
    let service = try fixture.service()
    let plan = try await service.prepareTransfer(sources: [input.url], destinationDirectory: fixture.destination, move: false)
    let retained = fixture.root.appendingPathComponent("retained-destination", isDirectory: true)
    try FileManager().moveItem(at: fixture.destination, to: retained)
    try FileManager().createDirectory(at: fixture.destination, withIntermediateDirectories: false)
    let replacement = try DirectoryAnchor(fixture.destination, resolve: false).identity
    let result = await service.perform(plan)
    #expect(result.result.disposition != .succeeded)
    #expect(result.recordID == nil)
    #expect(try fixture.names(in: fixture.destination).isEmpty)
    #expect(try fixture.names(in: retained).isEmpty)
    #expect(try DirectoryAnchor(fixture.destination, resolve: false).identity.sameObject(as: replacement))
    try fixture.assertSourcesPreserved([input])
}

@Test func groupedForwardPublicSlotReplacementDuringDrainStaysProtected() async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let inputs = try fixture.files(17)
    let target = fixture.destination.appendingPathComponent("member-0.txt")
    let retained = fixture.root.appendingPathComponent("retained-published-object")
    var hooks = RecoveryHooks()
    hooks.groupedCopy.checkpoint = { event, _ in
        if event.stage == .memberPublished && event.memberOrdinal == 0 {
            try FileManager().moveItem(at: target, to: retained)
            try inputs[0].body.write(to: target, options: .withoutOverwriting)
        }
    }
    let result = try await fixture.service(hooks: hooks).perform(.copy(sources: inputs.map(\.url), destinationDirectory: fixture.destination))
    #expect(result.result.disposition != .succeeded)
    let record = try fixture.record(try #require(result.recordID))
    #expect(record.head.state == .needsReview)
    #expect(record.members.allSatisfy { $0.progress.phase != "published" })
    #expect(record.groups.count == 1)
    #expect(try Data(contentsOf: target) == inputs[0].body)
    #expect(try Data(contentsOf: retained) == inputs[0].body)
    #expect(!FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("member-1.txt").path))
    try fixture.assertSourcesPreserved(inputs)
}

private final class GroupedForwardFaultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    func enable() { lock.withLock { enabled = true } }
    func failIfEnabled() throws {
        if lock.withLock({ enabled }) { throw FileOperationFailure.ioFailure }
    }
}

@Test(arguments: [false, true])
func groupedForwardOutcomeSaveFailureAndLostAcknowledgementAreReview(lostAcknowledgement: Bool) async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let inputs = try fixture.files(17)
    let gate = GroupedForwardFaultGate()
    var hooks = RecoveryHooks()
    hooks.groupedCopy.checkpoint = { event, _ in
        if event.stage == .groupWillRecordOutcomes { gate.enable() }
    }
    if lostAcknowledgement { hooks.journalHooks.afterCommitBeforeAcknowledgement = { try gate.failIfEnabled() } }
    else { hooks.journalHooks.beforeSaveCommit = { try gate.failIfEnabled() } }
    let result = try await fixture.service(hooks: hooks).perform(.copy(sources: inputs.map(\.url), destinationDirectory: fixture.destination))
    #expect(result.result.disposition != .succeeded)
    let record = try fixture.record(try #require(result.recordID))
    #expect(record.groups.count == 1)
    #expect(record.members[16].progress.phase == "notDeclared")
    #expect(record.head.state != .completed)
    #expect(record.members.filter { $0.progress.phase == "published" }.count == (lostAcknowledgement ? 16 : 0))
    try fixture.assertCopied(Array(inputs.prefix(16)), into: fixture.destination)
    try fixture.assertSourcesPreserved(inputs)
}

@Test func groupedForwardDirectorySyncFailureCannotSealOrPublish() async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let inputs = try fixture.files(17)
    var hooks = RecoveryHooks()
    hooks.beforeSync = { _ in throw FileOperationFailure.ioFailure }
    let result = try await fixture.service(hooks: hooks).perform(.copy(sources: inputs.map(\.url), destinationDirectory: fixture.destination))
    #expect(result.result.disposition != .succeeded)
    let record = try fixture.record(try #require(result.recordID))
    #expect(record.head.state == .needsReview)
    #expect(record.members.allSatisfy { $0.progress.phase != "published" })
    #expect(record.groups.count == 1)
    for input in inputs { #expect(!FileManager().fileExists(atPath: fixture.destination.appendingPathComponent(String(decoding: input.literalName, as: UTF8.self)).path)) }
    try fixture.assertSourcesPreserved(inputs)
}

@Test func groupedForwardSourceEditAfterSealCannotPublish() async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let inputs = try fixture.files(17)
    let edited = Data("generated deliberate source edit after sealing".utf8)
    var hooks = RecoveryHooks()
    hooks.groupedCopy.checkpoint = { event, _ in
        if event.stage == .groupSealed && event.groupOrdinal == 0 { try edited.write(to: inputs[0].url) }
    }
    let result = try await fixture.service(hooks: hooks).perform(.copy(sources: inputs.map(\.url), destinationDirectory: fixture.destination))
    #expect(result.result.disposition != .succeeded)
    let record = try fixture.record(try #require(result.recordID))
    #expect(record.head.state == .needsReview && record.groups.count == 1)
    #expect(record.members.allSatisfy { $0.progress.phase != "published" })
    #expect(try Data(contentsOf: inputs[0].url) == edited)
    #expect(!FileManager().fileExists(atPath: fixture.destination.appendingPathComponent("member-0.txt").path))
    try fixture.assertSourcesPreserved(Array(inputs.dropFirst()))
}

private func groupedForwardAttribute(_ url: URL, name: String) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
    let length = fgetxattr(fd, name, nil, 0, 0, 0)
    guard length >= 0, length <= 4096 else { throw FileOperationFailure.ioFailure }
    var data = Data(count: length)
    let received = data.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, length, 0, 0) }
    guard received == length else { throw FileOperationFailure.ioFailure }
    return data
}

@Test(arguments: [TransferMetadataPolicy.strict, .destinationOwnership])
func groupedForwardNativeSecurityAndCustomMetadataMatchOrdinarySemantics(policy: TransferMetadataPolicy) async throws {
    let fixture = try GroupedForwardFixture(); defer { fixture.remove() }
    let initial = try fixture.file("security-input")
    let customName = "com.macexplorer.grouped-generated-fixture"
    let custom = Data("generated retained custom attribute".utf8)
    let quarantine = Data("0083;67000000;MacExplorerGeneratedFixture;00000000-0000-0000-0000-000000000002".utf8)
    for (name, value) in [(customName, custom), (CopySecurity.quarantineName, quarantine)] {
        guard value.withUnsafeBytes({ setxattr(initial.url.path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }) == 0 else { throw posixFailure() }
    }
    let input = GroupedForwardFixture.Input(url: initial.url, literalName: initial.literalName, body: initial.body,
        before: try verifiedTree(initial.url, cancellation: OperationCancellation()))
    let grouped = try await fixture.service().perform(.copy(sources: [input.url], destinationDirectory: fixture.destination), metadataPolicy: policy)
    let ordinary = try await fixture.service(grouped: false).perform(.copy(sources: [input.url], destinationDirectory: fixture.ordinaryDestination), metadataPolicy: policy)
    #expect(grouped.result.disposition == .succeeded && ordinary.result.disposition == .succeeded)
    let record = try fixture.record(try #require(grouped.recordID))
    let output = fixture.destination.appendingPathComponent("security-input")
    let reference = fixture.ordinaryDestination.appendingPathComponent("security-input")
    let groupedTree = try verifiedTree(output, cancellation: OperationCancellation())
    let ordinaryTree = try verifiedTree(reference, cancellation: OperationCancellation())
    #expect(record.members[0].progress.publication?.matches(groupedTree) == true)
    #expect(try groupedForwardAttribute(output, name: customName) == custom)
    #expect(try groupedForwardAttribute(reference, name: customName) == custom)
    #expect(!(try groupedForwardAttribute(output, name: CopySecurity.quarantineName)).isEmpty)
    #expect(!(try groupedForwardAttribute(reference, name: CopySecurity.quarantineName)).isEmpty)
    #expect(groupedTree.identity.mode == ordinaryTree.identity.mode)
    #expect(groupedTree.identity.modifiedSeconds == ordinaryTree.identity.modifiedSeconds)
    #expect(groupedTree.identity.modifiedNanos == ordinaryTree.identity.modifiedNanos)
    #expect(try Data(contentsOf: output) == input.body)
    #expect(try Data(contentsOf: reference) == input.body)
    try fixture.assertSourcesPreserved([input])
}
