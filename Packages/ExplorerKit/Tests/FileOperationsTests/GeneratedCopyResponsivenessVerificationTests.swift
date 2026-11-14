#if DEBUG
import Darwin
import Dispatch
import Foundation
@testable import FileOperations
import Testing

/// Every fixture is freshly generated, private and marked under the exact
/// repository production-fixture namespace. These tests never adopt or remove
/// existing data. The shared runner retires new, explicitly marked package
/// fixtures only after the selected run passes; failed runs stay retained.
private final class ResponsivenessFixture: @unchecked Sendable {
    private struct Manifest: Codable { let workload: String; let sizes: [Int]; let source: VerifiedTree }
    let run: URL
    let root: URL
    let source: URL
    let destination: URL
    let history: URL
    let journal: URL
    let inputs: [URL]
    let sourceTree: VerifiedTree
    private let lock = NSLock()
    private var descriptor: Int32
    var lease: Int32 { lock.withLock { descriptor } }

    init(count: Int = 1024) throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let build = repository.appendingPathComponent(".build", isDirectory: true)
        _ = try DirectoryAnchor(build, resolve: false)
        let base = build.appendingPathComponent("grouped-copy-production", isDirectory: true)
        if mkdir(base.path, 0o700) != 0, errno != EEXIST { throw posixFailure() }
        let baseAnchor = try DirectoryAnchor(base, resolve: false)
        var info = stat()
        guard fstat(baseAnchor.fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else {
            throw FileOperationFailure.invalidRequest
        }
        run = base.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        guard mkdir(run.path, 0o700) == 0 else { throw posixFailure() }
        let runAnchor = try DirectoryAnchor(run, resolve: false)
        try OperationJournal.writeExclusive(Data("MacExplorer grouped production qualification v1\n\(run.lastPathComponent)\n".utf8),
                                           name: ".qualification-owner", anchor: runAnchor)
        try OperationJournal.writeExclusive(Data("MacExplorer package responsiveness fixture v1\n\(run.lastPathComponent)\n".utf8),
                                           name: ".package-test-owner", anchor: runAnchor)
        let fixtures = run.appendingPathComponent("fixtures", isDirectory: true)
        guard mkdir(fixtures.path, 0o700) == 0 else { throw posixFailure() }
        root = fixtures.appendingPathComponent("copy-" + UUID().uuidString.lowercased(), isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else { throw posixFailure() }
        let anchor = try DirectoryAnchor(root, resolve: false)
        try OperationJournal.writeExclusive(Data("MacExplorer generated grouped production fixture v1\n\(root.lastPathComponent)\n".utf8),
                                           name: ".owned-grouped-production-fixture", anchor: anchor)
        try OperationJournal.writeExclusive(GroupedCopyQualification.marker, name: GroupedCopyQualification.markerName, anchor: anchor)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        history = root.appendingPathComponent("history", isDirectory: true)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        for url in [source, destination, history] { guard mkdir(url.path, 0o700) == 0 else { throw posixFailure() } }
        let sourceAnchor = try DirectoryAnchor(source, resolve: false)
        let sourceURL = source
        inputs = (0..<count).map { sourceURL.appendingPathComponent("generated-\($0).dat") }
        for (ordinal, url) in inputs.enumerated() {
            try OperationJournal.writeExclusive(Data(repeating: UInt8(ordinal % 251), count: 256), name: url.lastPathComponent, anchor: sourceAnchor)
        }
        sourceTree = try verifiedTree(source, cancellation: OperationCancellation())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try OperationJournal.writeExclusive(try encoder.encode(Manifest(workload: "1024x256B", sizes: [Int](repeating: 256, count: count), source: sourceTree)),
                                           name: "performance.json", anchor: anchor)
        let fd = openat(anchor.fd, ".owned-grouped-production-fixture", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw posixFailure() }
        descriptor = fd
    }
    deinit { closeLease() }
    func closeLease() { lock.withLock { if descriptor >= 0 { close(descriptor); descriptor = -1 } } }
    func engine() async throws -> RecoverableFileOperations {
        try await RecoverableFileOperations.generatedCopyResponsivenessVerificationSession(in: root,
            inheritingFixtureLeaseDescriptor: lease)
    }
    func probe() throws -> Int32 {
        let anchor = try DirectoryAnchor(root, resolve: false)
        let fd = openat(anchor.fd, ".owned-grouped-production-fixture", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }; return fd
    }
    func write(_ data: Data, name: String, in parent: URL) throws {
        try OperationJournal.writeExclusive(data, name: name, anchor: DirectoryAnchor(parent, resolve: false))
    }
    func changeManifest(_ transform: (inout [String: Any]) throws -> Void) throws {
        let anchor = try DirectoryAnchor(root, resolve: false)
        var value = try #require(JSONSerialization.jsonObject(with: OperationJournal.read(name: "performance.json", anchor: anchor)) as? [String: Any])
        try transform(&value)
        let runAnchor = try DirectoryAnchor(run, resolve: false)
        guard renameatx_np(anchor.fd, "performance.json", runAnchor.fd, "original-performance-" + UUID().uuidString,
                          UInt32(RENAME_EXCL)) == 0 else { throw posixFailure() }
        try write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), name: "performance.json", in: root)
    }
    func expectRefused() async {
        do { _ = try await engine(); Issue.record("Invalid generated responsiveness fixture was admitted") }
        catch {}
    }
    func journalAbsent() throws -> Bool {
        let anchor = try DirectoryAnchor(root, resolve: false)
        var info = stat()
        let result = fstatat(anchor.fd, "journal", &info, AT_SYMLINK_NOFOLLOW), code = errno
        return result != 0 && code == ENOENT
    }
}

private final class ResponsivenessDrainGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    func block(_ cancellation: OperationCancellation) throws {
        started.signal()
        guard release.wait(timeout: .now() + 10) == .success else { throw FileOperationFailure.unavailable }
        try cancellation.check()
    }
    func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 5) == .success }
    func finish() { release.signal() }
}

@Suite(.serialized)
struct GeneratedCopyResponsivenessVerificationTests {
    @Test func exactOriginalSeedSelectsOneTypedGroupedCopyAndKeepsOldFactoryClosed() async throws {
        let fixture = try ResponsivenessFixture()
        do { _ = try await RecoverableFileOperations.generatedCopyVerificationSession(in: fixture.root); Issue.record("Small queue factory admitted performance seed") }
        catch {}
        let normal = RecoverableFileOperations(journalDirectory: fixture.journal)
        #expect(normal.copyPreviewAvailability == .qualificationPending)
        let engine = try await fixture.engine()
        #expect(engine.copyPreviewAvailability == .available)
        #expect(try fixture.journalAbsent())
        let plan = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination,
            move: false, metadataPolicy: .strict, copyExecution: .previewIfAvailable)
        #expect(plan.executionDecision == .groupedCopy(maximumMembersPerGroup: 16))
        #expect(plan.entries.count == 1024 && plan.conflicts.isEmpty)
        #expect(try fixture.journalAbsent())
        let result = await engine.perform(plan)
        #expect(result.result.disposition == .succeeded && result.result.items.count == 1024)
        let id = try #require(result.recordID)
        let journal = try OperationJournal(fixture.journal)
        guard case .groupedCopyV1(let record)? = try journal.inspectCatalogRecord(id) else { Issue.record("Large generated session lost typed protocol"); return }
        #expect(record.head.state == .completed && record.head.groupSize == 16 && record.members.count == 1024 && record.groups.count == 64)
        #expect(record.members.allSatisfy { $0.progress.phase == "published" })
        #expect(fixture.sourceTree.matches(try verifiedTree(fixture.source, cancellation: OperationCancellation())))
        do {
            _ = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination, move: false)
            Issue.record("Completed one-job fixture was silently reused")
        } catch {}
        #expect(normal.copyPreviewAvailability == .qualificationPending)
    }

    @Test(arguments: [1, 1023, 1025])
    func countMustBeExactly1024(count: Int) async throws {
        let fixture = try ResponsivenessFixture(count: count)
        await fixture.expectRefused()
        #expect(try fixture.journalAbsent())
    }

    @Test(arguments: ["workload", "unknown-key", "digest", "source-edit", "file-size", "wrong-name", "hardlink", "symlink", "mode", "occupied-destination", "nonempty-history", "journal", "extra-child", "marker"])
    func boundedManifestAndPrivateNamespaceRefuseBeforeMutation(variant: String) async throws {
        let fixture = try ResponsivenessFixture()
        switch variant {
        case "workload": try fixture.changeManifest { $0["workload"] = "128x4KiB" }
        case "unknown-key": try fixture.changeManifest { $0["future"] = true }
        case "digest": try fixture.changeManifest { value in
            var tree = try #require(value["source"] as? [String: Any]); tree["digest"] = String(repeating: "0", count: 64); value["source"] = tree
        }
        case "source-edit":
            let fd = open(fixture.inputs[0].path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
            let bytes = [UInt8](repeating: 255, count: 256)
            guard bytes.withUnsafeBytes({ pwrite(fd, $0.baseAddress, $0.count, 0) }) == 256, fsync(fd) == 0 else { throw posixFailure() }
        case "wrong-name":
            let source = try DirectoryAnchor(fixture.source, resolve: false)
            guard renameatx_np(source.fd, "generated-0.dat", source.fd, "unexpected.dat", UInt32(RENAME_EXCL)) == 0 else { throw posixFailure() }
        case "file-size":
            let fd = open(fixture.inputs[0].path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
            guard ftruncate(fd, 257) == 0 else { throw posixFailure() }
        case "hardlink":
            guard link(fixture.inputs[0].path, fixture.run.appendingPathComponent("retained-hardlink").path) == 0 else { throw posixFailure() }
        case "symlink":
            let source = try DirectoryAnchor(fixture.source, resolve: false), run = try DirectoryAnchor(fixture.run, resolve: false)
            guard renameatx_np(source.fd, "generated-0.dat", run.fd, "retained-source", UInt32(RENAME_EXCL)) == 0,
                  symlink(fixture.run.appendingPathComponent("retained-source").path, fixture.inputs[0].path) == 0 else { throw posixFailure() }
        case "mode": guard chmod(fixture.inputs[0].path, 0o644) == 0 else { throw posixFailure() }
        case "occupied-destination": try fixture.write(Data(), name: "generated-0.dat", in: fixture.destination)
        case "nonempty-history": try fixture.write(Data(), name: "unexpected.dat", in: fixture.history)
        case "journal": guard mkdir(fixture.journal.path, 0o700) == 0 else { throw posixFailure() }
        case "extra-child": try fixture.write(Data(), name: "unexpected.dat", in: fixture.root)
        case "marker":
            let fd = open(fixture.root.appendingPathComponent(GroupedCopyQualification.markerName).path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
            guard ftruncate(fd, 0) == 0 else { throw posixFailure() }
        default: throw FileOperationFailure.invalidRequest
        }
        await fixture.expectRefused()
        if variant != "journal" { #expect(try fixture.journalAbsent()) }
    }

    @Test func leaseRootAndRequestIdentityAreRecheckedBeforeMutation() async throws {
        let fixture = try ResponsivenessFixture()
        let engine = try await fixture.engine()
        for (sources, destination, move, policy) in [
            (Array(fixture.inputs.dropLast()), fixture.destination, false, TransferMetadataPolicy.strict),
            (fixture.inputs, fixture.history, false, .strict),
            (fixture.inputs, fixture.destination, true, .strict),
            (fixture.inputs, fixture.destination, false, .destinationOwnership)] {
            do { _ = try await engine.prepareTransfer(sources: sources, destinationDirectory: destination, move: move,
                metadataPolicy: policy, copyExecution: .previewIfAvailable); Issue.record("Large fixture request escaped its exact full strict Copy") }
            catch {}
        }
        let root = try DirectoryAnchor(fixture.root, resolve: false)
        guard renameatx_np(root.fd, "destination", root.fd, "retained-destination", UInt32(RENAME_EXCL)) == 0,
              mkdirat(root.fd, "destination", 0o700) == 0 else { throw posixFailure() }
        do { _ = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination,
            move: false, copyExecution: .previewIfAvailable); Issue.record("Replaced destination incarnation was accepted") }
        catch {}
        #expect(try fixture.journalAbsent())
    }

    @Test func invalidOrLostLeaseAndSymlinkRootAreNeverAdopted() async throws {
        let fixture = try ResponsivenessFixture()
        let alias = fixture.root.deletingLastPathComponent().appendingPathComponent("copy-" + UUID().uuidString.lowercased(), isDirectory: true)
        guard symlink(fixture.root.path, alias.path) == 0 else { throw posixFailure() }
        do { _ = try await RecoverableFileOperations.generatedCopyResponsivenessVerificationSession(in: alias,
            inheritingFixtureLeaseDescriptor: fixture.lease); Issue.record("Symlinked original root was admitted") }
        catch {}
        do { _ = try await RecoverableFileOperations.generatedCopyResponsivenessVerificationSession(in: fixture.root,
            inheritingFixtureLeaseDescriptor: -1); Issue.record("Invalid inherited descriptor was admitted") }
        catch {}
        let unrelated = open(fixture.run.appendingPathComponent(".qualification-owner").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard unrelated >= 0 else { throw posixFailure() }; defer { close(unrelated) }
        do { _ = try await RecoverableFileOperations.generatedCopyResponsivenessVerificationSession(in: fixture.root,
            inheritingFixtureLeaseDescriptor: unrelated); Issue.record("A different owned marker was treated as case authority") }
        catch {}
        let separate = try fixture.probe(); defer { close(separate) }
        do { _ = try await RecoverableFileOperations.generatedCopyResponsivenessVerificationSession(in: fixture.root,
            inheritingFixtureLeaseDescriptor: separate); Issue.record("Same marker inode with a different unlocked open description was accepted") }
        catch {}
        let stillBlocked = flock(separate, LOCK_EX | LOCK_NB), stillBlockedCode = errno
        #expect(stillBlocked != 0 && stillBlockedCode == EWOULDBLOCK)
        let engine = try await fixture.engine()
        let plan = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination,
            move: false, copyExecution: .previewIfAvailable)
        // Deliberate negative test only, scoped to this exact generated marker.
        guard flock(fixture.lease, LOCK_UN) == 0 else { throw posixFailure() }
        await fixture.expectRefused()
        do { _ = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination,
            move: false, copyExecution: .previewIfAvailable); Issue.record("Lost lease was silently reacquired") }
        catch {}
        let refused = await engine.perform(plan)
        #expect(refused.result.disposition == .failed && refused.recordID == nil)
        #expect(try fixture.journalAbsent())
    }

    @Test func unlockedExactMarkerDescriptorCannotAcquireQualificationImplicitly() async throws {
        let fixture = try ResponsivenessFixture()
        fixture.closeLease()
        let unlocked = try fixture.probe(); defer { close(unlocked) }
        do { _ = try await RecoverableFileOperations.generatedCopyResponsivenessVerificationSession(in: fixture.root,
            inheritingFixtureLeaseDescriptor: unlocked); Issue.record("An initially unlocked exact marker was silently acquired") }
        catch {}
        #expect(flock(unlocked, LOCK_EX | LOCK_NB) == 0)
        #expect(try fixture.journalAbsent())
    }

    @Test func sourceChangedAfterPreparationCannotReachPublication() async throws {
        let fixture = try ResponsivenessFixture()
        let engine = try await fixture.engine()
        let plan = try await engine.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination,
            move: false, copyExecution: .previewIfAvailable)
        let fd = open(fixture.inputs[0].path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
        let bytes = [UInt8](repeating: 255, count: 256)
        guard bytes.withUnsafeBytes({ pwrite(fd, $0.baseAddress, $0.count, 0) }) == 256, fsync(fd) == 0 else { throw posixFailure() }
        let result = await engine.perform(plan)
        #expect(result.result.disposition == .failed && result.recordID == nil)
        #expect(try fixture.journalAbsent())
        #expect(try GroupedCopyFilesystemEvidence.children(in: DirectoryAnchor(fixture.destination, resolve: false),
            cancellation: OperationCancellation(), limit: 0).isEmpty)
    }

    @Test func originalSourceReceiptAndPrivateSingleAssignmentCannotBeSubstituted() async throws {
        let original = try ResponsivenessFixture(), copied = try ResponsivenessFixture()
        // Independently observed fresh generated files with an original seed's
        // receipt model a copied fixture: owner markers/lease/paths alone cannot
        // authorize adopting the new source incarnation.
        let receipt = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original.sourceTree))
        try copied.changeManifest { $0["source"] = receipt }
        await copied.expectRefused()
        let engine = try await original.engine()
        let root = original.root, descriptor = original.lease
        let secondCapability = try await engine.worker { cancellation in
            try GeneratedCopyResponsivenessCapability.admit(root, inheritedDescriptor: descriptor, cancellation: cancellation)
        }
        do { try engine.installGeneratedResponsivenessCapability(secondCapability); Issue.record("Escaped engine accepted capability reassignment") }
        catch {}
        let normal = RecoverableFileOperations(journalDirectory: original.journal)
        do { try normal.installGeneratedResponsivenessCapability(secondCapability); Issue.record("Closed public engine accepted fixture activation") }
        catch {}
        #expect(normal.copyPreviewAvailability == .qualificationPending)
        #expect(try original.journalAbsent())
        #expect(try copied.journalAbsent())
    }

    @Test func duplicateLeaseSurvivesParentCloseAndCanceledWorkerUntilActualDrain() async throws {
        let fixture = try ResponsivenessFixture()
        var engine: RecoverableFileOperations? = try await fixture.engine()
        weak let observed = engine
        fixture.closeLease()
        let probe = try fixture.probe(); defer { close(probe) }
        let initial = flock(probe, LOCK_EX | LOCK_NB), initialCode = errno
        #expect(initial != 0 && initialCode == EWOULDBLOCK)
        let optionalPlan = try await engine?.prepareTransfer(sources: fixture.inputs, destinationDirectory: fixture.destination,
            move: false, copyExecution: .previewIfAvailable)
        let plan = try #require(optionalPlan)
        #expect(plan.executionDecision == .groupedCopy(maximumMembersPerGroup: 16))
        let gate = ResponsivenessDrainGate(); defer { gate.finish() }
        let blocked = Task { [weak candidate = engine] in
            guard let candidate else { throw FileOperationFailure.unavailable }
            return try await candidate.worker { cancellation in try gate.block(cancellation); return true }
        }
        #expect(await Task.detached { gate.waitUntilStarted() }.value)
        engine = nil; blocked.cancel()
        let during = flock(probe, LOCK_EX | LOCK_NB), duringCode = errno
        #expect(during != 0 && duringCode == EWOULDBLOCK && observed != nil)
        gate.finish()
        do { _ = try await blocked.value; Issue.record("Canceled blocked worker did not observe Stop after drain") }
        catch {}
        for _ in 0..<100 where observed != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(observed == nil)
        #expect(flock(probe, LOCK_EX | LOCK_NB) == 0)
        #expect(try fixture.journalAbsent())
    }

    @Test func debugObservedBudgetRejectsOversizeNodesAndOverflowBeforeBodyAdmission() throws {
        let fixture = try ResponsivenessFixture(count: 1)
        let source = try DirectoryAnchor(fixture.source, resolve: false)
        let original = try EntrySnapshot(parent: source.fd, name: "generated-0.dat")
        let nodes = TraversalBudget(maximumObservedNodes: 1, maximumObservedLogicalBytes: 256)
        try nodes.consume(original, depth: 0)
        do { try nodes.consume(original, depth: 0); Issue.record("Configured node ceiling was bypassed") } catch {}
        #expect(nodes.nodes == 1 && nodes.bytes == 256 && nodes.remaining == 0)
        let fd = open(fixture.inputs[0].path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
        guard ftruncate(fd, 262_145) == 0 else { throw posixFailure() }
        let body = TraversalBudget(maximumObservedNodes: 1, maximumObservedLogicalBytes: 262_144)
        let comparison = CopyComparison(), untouched = CopyComparison()
        do { _ = try verifiedTree(fixture.inputs[0], cancellation: OperationCancellation(), budget: body, copyComparison: comparison)
            Issue.record("Oversized observed node reached verified body admission") }
        catch { #expect(error as? FileOperationFailure == .unsupported) }
        #expect(body.bytes == 0 && comparison.contentDigest == untouched.contentDigest)
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        encoded["size"] = NSNumber(value: Int64.max)
        let huge = try JSONDecoder().decode(EntrySnapshot.self, from: JSONSerialization.data(withJSONObject: encoded))
        let overflow = TraversalBudget()
        try overflow.consume(huge, depth: 0)
        do { try overflow.consume(original, depth: 0); Issue.record("Observed logical-size sum overflow was accepted") } catch {}
        #expect(overflow.bytes == Int64.max)
    }
}
#endif
