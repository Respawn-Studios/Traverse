import Darwin
import ExplorerCore
import FileOperations
import Foundation
@testable import LocalStorage
import Testing

private struct Fixture {
    let root: URL
    private let manager = FileManager()

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let configured = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"]
        let base = configured.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        // Every destructive cleanup is confined to one generated child under repo .build.
        guard base.path.hasPrefix(repository.path + "/"), base.pathComponents.contains(".build"),
              base.resolvingSymlinksInPath().path == base.path else {
            throw FixtureError.unsafeRoot
        }
        root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func file(_ name: String, text: String = "fixture") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func remove() throws { try manager.removeItem(at: root) }
    enum FixtureError: Error { case unsafeRoot }
}

private func listing(_ service: LocalFileSystem, _ url: URL, hidden: Bool = false) async throws -> ([FileEntry], [ListingIssue]) {
    var entries: [FileEntry] = []
    var issues: [ListingIssue] = []
    var completed = false
    for try await event in service.entries(in: url, showHidden: hidden) {
        switch event {
        case .batch(let batch): entries += batch
        case .finished(let received): issues = received; completed = true
        }
    }
    #expect(completed)
    return (entries, issues)
}

private struct MetadataSnapshot: Equatable {
    let mode: mode_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let createdSeconds: Int
    let createdNanoseconds: Int

    init(_ url: URL) throws {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { lstat($0, &value) } ?? -1
        }
        guard status == 0 else { throw LocalStorageError.unavailable }
        mode = value.st_mode
        size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        createdSeconds = value.st_birthtimespec.tv_sec
        createdNanoseconds = value.st_birthtimespec.tv_nsec
    }
}

@Test func projectTextReadKeepsItsRootPrivacyAndByteBounds() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let root = try fixture.directory("Project")
    let text = try fixture.file("Project/Ready.txt", text: "fixture\r\n")
    let outside = try fixture.file("Other.txt", text: "fixture\r\n")
    let environment = try fixture.file("Project/.env.generated", text: "fixture\r\n")
    let git = try fixture.directory("Project/.git")
    let internalFile = try fixture.file("Project/.git/HEAD", text: "fixture\r\n")
    let link = root.appendingPathComponent("Link.txt")
    try FileManager().createSymbolicLink(at: link, withDestinationURL: outside)
    let invalid = root.appendingPathComponent("Binary.txt")
    try Data([0xff, 0x00]).write(to: invalid, options: .withoutOverwriting)
    func candidate(_ url: URL, bytes: Int64 = 9) -> FileEntry {
        .init(url: url, name: url.lastPathComponent, kind: .file, byteCount: bytes)
    }
    let service = LocalFileSystem()
    let scope = try await service.prepareProjectText(in: root)
    let observation = try await service.readProjectText([candidate(text), candidate(outside), candidate(environment),
        candidate(internalFile), candidate(link), candidate(invalid, bytes: 2), candidate(text, bytes: 10)], within: scope)
    #expect(observation.files.map(\.entry.url) == [text])
    #expect(observation.files.first?.contents.text == "fixture\n")
    #expect(observation.skipped == 6 && observation.consumed == 7)
    await #expect(throws: LocalStorageError.self) {
        try await service.prepareProjectText(in: git)
    }

    let size = 1 << 20
    let large = Data(String(repeating: String(repeating: "a", count: 1_023) + "\n", count: 1_024).utf8)
    let candidates = try (0..<5).map { index in
        let url = root.appendingPathComponent("Large-\(index).txt")
        try large.write(to: url, options: .withoutOverwriting)
        return candidate(url, bytes: Int64(size))
    }
    let firstPage = try await service.readProjectText(candidates[...], within: scope)
    #expect(firstPage.files.map(\.entry.url) == candidates.prefix(4).map(\.url))
    #expect(firstPage.skipped == 0 && firstPage.consumed == 4)
    let lastPage = try await service.readProjectText(candidates.dropFirst(firstPage.consumed), within: scope)
    #expect(lastPage.files.map(\.entry.url) == candidates.suffix(1).map(\.url))
    #expect(lastPage.skipped == 0 && lastPage.consumed == 1)

    try FileManager().moveItem(at: root, to: fixture.root.appendingPathComponent("Earlier Project", isDirectory: true))
    _ = try fixture.directory("Project")
    _ = try fixture.file("Project/Ready.txt", text: "same size")
    await #expect(throws: TextComparisonReadFailure.changed) {
        try await service.readProjectText([candidate(text)], within: scope)
    }
    await #expect(throws: TextComparisonReadFailure.changed) {
        try await service.validateProjectTextScope(scope)
    }
}

@Test func linkedFolderNavigationConfinesAndRechecksBothRoots() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let left = try fixture.directory("Left"), right = try fixture.directory("Right")
    let source = try fixture.directory("Left/Sources"), destination = try fixture.directory("Right/Sources")
    let missing = try fixture.directory("Left/Missing")
    let secret = try fixture.directory("Left/.git")
    let outside = try fixture.directory("Outside")
    let linkSource = try fixture.directory("Left/Linked")
    try FileManager().createSymbolicLink(at: right.appendingPathComponent("Linked"), withDestinationURL: outside)
    let system = LocalFileSystem()
    let link = try await system.linkFolderNavigation(left, right)
    #expect(try await system.correspondingFolder(in: link, from: left, visited: source) == destination)
    #expect(try await system.correspondingFolder(in: link, from: right, visited: destination) == source)
    #expect(try await system.correspondingFolder(in: link, from: left, visited: left) == right)
    for invalid in [missing, secret, outside, linkSource] {
        await #expect(throws: LinkedFolderFailure.unavailable) {
            try await system.correspondingFolder(in: link, from: left, visited: invalid)
        }
    }
    try FileManager().moveItem(at: right, to: fixture.root.appendingPathComponent("Earlier Right", isDirectory: true))
    _ = try fixture.directory("Right")
    _ = try fixture.directory("Right/Sources")
    await #expect(throws: LinkedFolderFailure.rootsChanged) {
        try await system.correspondingFolder(in: link, from: left, visited: source)
    }
}

@Test func shallowListingPreservesFixtureAndReportsKinds() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let unicode = try fixture.file("文件 Café 🧭.txt")
    let hidden = try fixture.file(".hidden")
    let folder = try fixture.directory("Folder")
    try Data("nested".utf8).write(to: folder.appendingPathComponent("nested.txt"))
    let package = try fixture.directory("Example.app")
    let link = fixture.root.appendingPathComponent("broken-link")
    try FileManager().createSymbolicLink(at: link, withDestinationURL: fixture.root.appendingPathComponent("absent"))
    let observed = [fixture.root, unicode, hidden, folder, package, link, folder.appendingPathComponent("nested.txt")]
    let before = try observed.map(MetadataSnapshot.init)
    let service = LocalFileSystem(batchSize: 2)
    let (entries, issues) = try await listing(service, fixture.root)
    #expect(entries.count == 4)
    #expect(issues.isEmpty)
    #expect(entries.first { $0.url == unicode }?.kind == .file)
    #expect(entries.first { $0.name == "Folder" }?.kind == .directory)
    #expect(entries.first { $0.name == "Example.app" }?.kind == .package)
    #expect(entries.first { $0.name == "broken-link" }?.kind == .symbolicLink)
    #expect(!entries.contains { $0.name == "nested.txt" })
    let (all, _) = try await listing(service, fixture.root, hidden: true)
    #expect(all.count == 5)
    #expect(all.contains { $0.name == ".hidden" })
    let after = try observed.map(MetadataSnapshot.init)
    #expect(before == after)
}

@Test func boundedOutlineListingKeepsItsRootAndShallowLimit() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let project = try fixture.directory("Project")
    let outside = try fixture.directory("Outside")
    try Data("outside".utf8).write(to: outside.appendingPathComponent("Outside.txt"))
    let nested = try fixture.directory("Project/Nested")
    try Data("inside".utf8).write(to: nested.appendingPathComponent("Inside.txt"))
    _ = try fixture.file("Project/One.txt")
    _ = try fixture.file("Project/Two.txt")
    _ = try fixture.file("Project/.gitignore")
    _ = try fixture.directory("Project/.ssh")
    let link = project.appendingPathComponent("Unresolved link", isDirectory: true)
    try FileManager().createSymbolicLink(at: link, withDestinationURL: outside)
    let fs = LocalFileSystem(batchSize: 1)
    let bounded = try await fs.boundedEntries(in: project, within: project, maximum: 2)
    #expect(!bounded.isComplete && bounded.entries.count == 2)
    let listed = try await fs.boundedEntries(in: project, within: project, showHidden: true)
    #expect(listed.isComplete && listed.hasUnavailableItems)
    #expect(listed.entries.first?.name == "Nested")
    #expect(listed.entries.first { $0.name == "Unresolved link" }?.kind == .symbolicLink)
    #expect(Set(listed.entries.map(\.name)) == ["Nested", "One.txt", "Two.txt", ".gitignore", "Unresolved link"])
    #expect(try await fs.boundedEntries(in: nested, within: project).entries.map(\.name) == ["Inside.txt"])
    await #expect(throws: (any Error).self) { try await fs.boundedEntries(in: link, within: project) }
    await #expect(throws: (any Error).self) { try await fs.boundedEntries(in: outside, within: project) }
}

@Test func batchesAreBoundedAndEmptyIsSuccessful() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let service = LocalFileSystem(batchSize: 3)
    let (empty, issues) = try await listing(service, fixture.root)
    #expect(empty.isEmpty && issues.isEmpty)
    for index in 0..<11 { _ = try fixture.file("item-\(index)") }
    var sizes: [Int] = []
    for try await event in service.entries(in: fixture.root) {
        if case .batch(let entries) = event { sizes.append(entries.count) }
    }
    #expect(sizes == [3, 3, 3, 2])
}

@Test func missingAndNotDirectoryAreFailures() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let service = LocalFileSystem()
    let file = try fixture.file("regular-file")
    do {
        _ = try await listing(service, fixture.root.appendingPathComponent("missing"))
        Issue.record("Missing location incorrectly succeeded.")
    } catch LocalStorageError.notFound {} catch { Issue.record("Unexpected missing-location error type.") }
    do {
        _ = try await listing(service, file)
        Issue.record("Regular file incorrectly listed as a folder.")
    } catch LocalStorageError.notDirectory {} catch { Issue.record("Unexpected not-directory error type.") }
}

@Test(.enabled(if: geteuid() != 0, "Root bypasses mode-bit access denial; denied behavior is unexercised under root."))
func controlledPermissionDenial() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let restricted = try fixture.directory("restricted")
    try FileManager().setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
    defer { try? FileManager().setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
    do {
        _ = try await listing(LocalFileSystem(), restricted)
        Issue.record("Mode-bit restricted directory incorrectly succeeded.")
    } catch LocalStorageError.accessDenied {} catch { Issue.record("Unexpected permission error type.") }
}

@Test func cancellationStopsConsumerAndAllowsNextListing() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    for index in 0..<1_000 { _ = try fixture.file("item-\(index)") }
    let service = LocalFileSystem(batchSize: 1, maximumConcurrentReads: 1)
    let listingRoot = fixture.root
    let task = Task {
        var received = 0
        for try await event in service.entries(in: listingRoot) {
            try Task.checkCancellation()
            if case .batch = event {
                received += 1
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        return received
    }
    do {
        let received = try await task.value
        #expect(received <= 1)
    } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error type.") }
    #expect(task.isCancelled)
    let empty = try fixture.directory("next-read")
    let (entries, issues) = try await listing(service, empty)
    #expect(entries.isEmpty && issues.isEmpty)
}

@Test func safeErrorMessagesNeverIncludeAssociatedDetails() {
    let error = LocalStorageError.other("sensitive fixture location")
    #expect(!error.userMessage.contains("sensitive"))
}

@Test func unknownVolumeFactsNeverClaimWritableOrCapacity() {
    let volume = VolumeInfo(url: URL(fileURLWithPath: "/fixture/volume"), name: "Unavailable", kind: .unknown)
    #expect(volume.isReadOnly == nil)
    #expect(volume.totalBytes == nil)
    #expect(volume.availableBytes == nil)
}

@Test func listingReportsNativeBirthAndAccessTimesWithoutFollowingLinks() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let target = try fixture.file("target.txt")
    let link = fixture.root.appendingPathComponent("opaque-link.txt")
    try FileManager().createSymbolicLink(at: link, withDestinationURL: target)
    for (url, seconds, nanos) in [(target, 1_700_000_111, 123_456_789), (link, 1_700_000_222, 444_555_666)] {
        let times = [timespec(tv_sec: seconds, tv_nsec: nanos), timespec(tv_sec: seconds + 1, tv_nsec: nanos)]
        let status = times.withUnsafeBufferPointer { values in
            url.withUnsafeFileSystemRepresentation { utimensat(AT_FDCWD, $0!, values.baseAddress!, AT_SYMLINK_NOFOLLOW) }
        }
        try #require(status == 0)
    }
    func metadata(_ url: URL) throws -> stat {
        var value = stat()
        try #require(url.withUnsafeFileSystemRepresentation { lstat($0!, &value) } == 0)
        return value
    }
    func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
    let beforeTarget = try metadata(target)
    let beforeLink = try metadata(link)
    let (entries, issues) = try await listing(LocalFileSystem(), fixture.root)
    #expect(issues.isEmpty)
    let fileEntry = try #require(entries.first { $0.name == "target.txt" })
    let linkEntry = try #require(entries.first { $0.name == "opaque-link.txt" })
    let targetBirthIsUnknown = beforeTarget.st_birthtimespec.tv_sec == 0 && beforeTarget.st_birthtimespec.tv_nsec == 0
    #expect(fileEntry.createdAt == (targetBirthIsUnknown ? nil : date(beforeTarget.st_birthtimespec)))
    #expect(fileEntry.accessedAt == date(beforeTarget.st_atimespec))
    #expect(linkEntry.kind == .symbolicLink)
    let linkBirthIsUnknown = beforeLink.st_birthtimespec.tv_sec == 0 && beforeLink.st_birthtimespec.tv_nsec == 0
    #expect(linkEntry.createdAt == (linkBirthIsUnknown ? nil : date(beforeLink.st_birthtimespec)))
    #expect(linkEntry.accessedAt == date(beforeLink.st_atimespec))
    #expect(linkEntry.accessedAt != fileEntry.accessedAt)
    for (url, before) in [(target, beforeTarget), (link, beforeLink)] {
        let after = try metadata(url)
        #expect(after.st_ino == before.st_ino)
        #expect(after.st_atimespec.tv_sec == before.st_atimespec.tv_sec)
        #expect(after.st_atimespec.tv_nsec == before.st_atimespec.tv_nsec)
        #expect(after.st_birthtimespec.tv_sec == before.st_birthtimespec.tv_sec)
        #expect(after.st_birthtimespec.tv_nsec == before.st_birthtimespec.tv_nsec)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
        #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
    }
}

@Test func creationDateDistinguishesUnknownFromValidEpochAndPreEpochFractions() throws {
    #expect(observedCreationDate(timespec(tv_sec: 0, tv_nsec: 0)) == nil)
    #expect(observedCreationDate(timespec(tv_sec: 1, tv_nsec: -1)) == nil)
    #expect(observedCreationDate(timespec(tv_sec: 1, tv_nsec: 1_000_000_000)) == nil)
    for (seconds, nanos, expected) in [
        (0, 1, 0.000_000_001),
        (0, 999_999_999, 0.999_999_999),
        (-1, 0, -1.0),
        (-1, 500_000_000, -0.5),
        (-1, 999_999_999, -0.000_000_001),
        (1_700_000_123, 123_456_789, 1_700_000_123.123_456_789),
    ] {
        let known = try #require(observedCreationDate(timespec(tv_sec: seconds, tv_nsec: nanos)))
        // Date uses floating-point reference seconds, so exact nanosecond precision is not promised.
        #expect(abs(known.timeIntervalSince1970 - expected) < 0.000_001)
    }
}

@Test func nearestExistingLocationUsesOnlyBoundedEntryMetadata() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("reported.txt")
    let link = fixture.root.appendingPathComponent("dangling-reported-link")
    try FileManager().createSymbolicLink(at: link, withDestinationURL: fixture.root.appendingPathComponent("absent-target"))
    let before = try [fixture.root, file, link].map(MetadataSnapshot.init)
    let service = LocalFileSystem(maximumConcurrentReads: 1)
    #expect(try await service.nearestExistingLocation(to: file) == file)
    #expect(try await service.nearestExistingLocation(to: link) == link)
    #expect(try await service.nearestExistingLocation(to: fixture.root.appendingPathComponent("missing/child")) == fixture.root)
    let nonDirectoryChild = file.appendingPathComponent("not-a-directory-child")
    #expect(try await service.nearestExistingLocation(to: nonDirectoryChild) == file)
    var distant = fixture.root
    for _ in 0..<80 { distant.appendPathComponent("m") }
    let probes = NearestReadGate()
    let absent = try await service.nearestExistingLocation(to: distant, retaining: nil,
        afterProbe: { _ in probes.observed("bound") }, didEnqueue: nil)
    #expect(absent == nil && probes.probes("bound") == 64)
    #expect(try [fixture.root, file, link].map(MetadataSnapshot.init) == before)
    do {
        _ = try await service.nearestExistingLocation(to: URL(string: "https://invalid.example/metadata")!)
        Issue.record("Non-file location reached local metadata inspection.")
    } catch LocalStorageError.unavailable {} catch { Issue.record("Unexpected non-file lookup error type.") }
}

@Test func nearestExistingLocationCancellationRetainsBoundedWorkerAndAccessUntilDrain() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("reported.txt")
    let before = try MetadataSnapshot(file)
    let service = LocalFileSystem(maximumConcurrentReads: 1)
    let gate = NearestReadGate()
    var activeLease: NearestReadLease? = NearestReadLease()
    var waitingLease: NearestReadLease? = NearestReadLease()
    let activeProbe = NearestReadLeaseProbe(activeLease)
    let waitingProbe = NearestReadLeaseProbe(waitingLease)
    let active = Task { [retained = activeLease!] in
        defer { gate.finished("active") }
        return try await service.nearestExistingLocation(to: file, retaining: retained,
            afterProbe: { _ in gate.observed("active", block: true) }, didEnqueue: { gate.enqueued("active") })
    }
    activeLease = nil
    defer { active.cancel(); gate.release() }
    try await waitForNearestReadGate { gate.probes("active") == 1 }
    let waiting = Task { [retained = waitingLease!] in
        defer { gate.finished("waiting") }
        return try await service.nearestExistingLocation(to: file, retaining: retained,
            afterProbe: { _ in gate.observed("waiting") }, didEnqueue: { gate.enqueued("waiting") })
    }
    waitingLease = nil
    defer { waiting.cancel() }
    try await waitForNearestReadGate { gate.isEnqueued("waiting") }
    active.cancel(); waiting.cancel()
    let later = Task {
        try await service.nearestExistingLocation(to: file, retaining: nil,
            afterProbe: { _ in gate.observed("later") }, didEnqueue: { gate.enqueued("later") })
    }
    defer { later.cancel() }
    try await waitForNearestReadGate { gate.isEnqueued("later") }
    #expect(gate.probes("waiting") == 0 && gate.probes("later") == 0)
    #expect(!gate.isFinished("active") && !gate.isFinished("waiting"))
    #expect(activeProbe.value != nil && waitingProbe.value != nil)
    gate.release()
    do { _ = try await active.value; Issue.record("Canceled blocked metadata read delivered a stale result.") }
    catch is CancellationError {} catch { Issue.record("Unexpected active metadata cancellation error.") }
    do { _ = try await waiting.value; Issue.record("Canceled queued metadata read delivered a result.") }
    catch is CancellationError {} catch { Issue.record("Unexpected queued metadata cancellation error.") }
    #expect(try await later.value == file)
    #expect(gate.probes("waiting") == 0 && gate.probes("later") == 1)
    try await waitForNearestReadGate { activeProbe.value == nil && waitingProbe.value == nil }
    #expect(try MetadataSnapshot(file) == before)
}

@Test(.enabled(if: geteuid() != 0, "Root bypasses mode-bit access denial; denied behavior is unexercised under root."))
func nearestExistingLocationDoesNotMislabelDeniedAsMissing() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let restricted = try fixture.directory("restricted-nearest-location")
    let file = restricted.appendingPathComponent("reported.txt")
    try Data("owned fixture".utf8).write(to: file, options: .withoutOverwriting)
    try FileManager().setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
    defer { try? FileManager().setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
    do {
        _ = try await LocalFileSystem().nearestExistingLocation(to: file)
        Issue.record("Denied metadata was silently substituted with an ancestor.")
    } catch LocalStorageError.accessDenied {} catch { Issue.record("Unexpected denied metadata error type.") }
}

@Test func nearestExistingLocationAdmissionIsBoundedUntilActualWorkerDrain() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("reported.txt")
    let service = LocalFileSystem(maximumConcurrentReads: 1)
    let gate = NearestReadGate()
    let active = Task {
        try await service.nearestExistingLocation(to: file, retaining: nil,
            afterProbe: { _ in gate.observed("active-cap", block: true) }, didEnqueue: nil)
    }
    var waiting: [Task<URL?, Error>] = []
    defer { active.cancel(); waiting.forEach { $0.cancel() }; gate.release() }
    try await waitForNearestReadGate { gate.probes("active-cap") == 1 }
    for index in 1..<LocalFileSystem.maximumLocationReads {
        let label = "waiting-cap-\(index)"
        waiting.append(Task {
            try await service.nearestExistingLocation(to: file, retaining: nil,
                afterProbe: { _ in gate.observed(label) }, didEnqueue: { gate.enqueued(label) })
        })
    }
    try await waitForNearestReadGate {
        (1..<LocalFileSystem.maximumLocationReads).allSatisfy { gate.isEnqueued("waiting-cap-\($0)") }
    }
    active.cancel(); waiting.forEach { $0.cancel() }
    #expect(service.outstandingLocationReads == LocalFileSystem.maximumLocationReads)
    do {
        _ = try await service.nearestExistingLocation(to: file, acquiring: {
            gate.observed("overflow-acquisition")
            return NearestReadLease()
        })
        Issue.record("Full metadata admission silently accepted overflow.")
    } catch LocalStorageError.busy {} catch { Issue.record("Unexpected metadata admission overflow error.") }
    #expect(gate.probes("overflow-acquisition") == 0)
    var overflowLease: NearestReadLease? = NearestReadLease()
    let overflowProbe = NearestReadLeaseProbe(overflowLease)
    do {
        _ = try await service.nearestExistingLocation(to: file, retaining: overflowLease,
            afterProbe: { _ in gate.observed("overflow") }, didEnqueue: { gate.enqueued("overflow") })
        Issue.record("Full metadata admission retained and enqueued overflow.")
    } catch LocalStorageError.busy {} catch { Issue.record("Unexpected retained metadata admission overflow error.") }
    overflowLease = nil
    #expect(overflowProbe.value == nil && !gate.isEnqueued("overflow") && gate.probes("overflow") == 0)
    gate.release()
    do { _ = try await active.value; Issue.record("Canceled active admission delivered a result.") }
    catch is CancellationError {} catch { Issue.record("Unexpected canceled active admission error.") }
    for request in waiting {
        do { _ = try await request.value; Issue.record("Canceled queued admission delivered a result.") }
        catch is CancellationError {} catch { Issue.record("Unexpected canceled waiting admission error.") }
    }
    #expect((1..<LocalFileSystem.maximumLocationReads).allSatisfy { gate.probes("waiting-cap-\($0)") == 0 })
    try await waitForNearestReadGate { service.outstandingLocationReads == 0 }
    #expect(try await service.nearestExistingLocation(to: file, acquiring: {
        gate.observed("later-acquisition")
        return NearestReadLease()
    }) == file)
    #expect(gate.probes("later-acquisition") == 1)
    let (entries, issues) = try await listing(service, fixture.root)
    #expect(entries.count == 1 && issues.isEmpty)
}

@Test func nearestExistingLocationReleasesAdmissionWhenAccessAcquisitionFailsOrCancels() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("reported.txt")
    let service = LocalFileSystem(maximumConcurrentReads: 1)
    do {
        _ = try await service.nearestExistingLocation(to: file, acquiring: { throw LocalStorageError.accessDenied })
        Issue.record("Failed access acquisition unexpectedly reached lookup.")
    } catch LocalStorageError.accessDenied {} catch { Issue.record("Unexpected acquisition failure type.") }
    #expect(service.outstandingLocationReads == 0)
    let canceled = Task {
        try await service.nearestExistingLocation(to: file, acquiring: {
            withUnsafeCurrentTask { $0?.cancel() }
            return NearestReadLease()
        })
    }
    do { _ = try await canceled.value; Issue.record("Canceled access acquisition reached lookup.") }
    catch is CancellationError {} catch { Issue.record("Unexpected acquisition cancellation type.") }
    #expect(service.outstandingLocationReads == 0)
    #expect(try await service.nearestExistingLocation(to: file) == file)
    #expect(LocalStorageError.busy.userMessage.contains("busy"))
}

@Test func sharedActivityAdmissionWaitsForCancelledFilesystemWorker() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("activity.txt")
    let activity = FileActivityGate()
    let service = LocalFileSystem(maximumConcurrentReads: 1, activityGate: activity)
    let blocked = NearestReadGate()
    let read = Task {
        try await service.nearestExistingLocation(to: file, retaining: nil,
            afterProbe: { _ in blocked.observed("activity", block: true) }, didEnqueue: nil)
    }
    defer { read.cancel(); blocked.release() }
    try await waitForNearestReadGate { blocked.probes("activity") == 1 }
    let token = try #require(activity.closeAdmission())
    read.cancel()
    #expect(activity.activeCount == 1 && !activity.ownsDrainedAdmission(token))
    blocked.release()
    do { _ = try await read.value; Issue.record("Cancelled metadata read returned a result") } catch is CancellationError {}
    #expect(await activity.waitUntilDrained(token))
    #expect(activity.ownsDrainedAdmission(token))
    do { _ = try await service.volumes(); Issue.record("Closed gate admitted volume metadata") }
    catch FileActivityError.admissionClosed {}
    do { _ = try await listing(service, fixture.root); Issue.record("Closed gate admitted listing") }
    catch FileActivityError.admissionClosed {}
    #expect(activity.reopen(token))
    #expect(try await service.nearestExistingLocation(to: file) == file)
}

private final class NearestReadLease: @unchecked Sendable {}
private final class NearestReadLeaseProbe: @unchecked Sendable {
    weak var value: NearestReadLease?
    init(_ value: NearestReadLease?) { self.value = value }
}
private final class NearestReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var probeCounts: [String: Int] = [:]
    private var enqueuedLabels: Set<String> = []
    private var finishedLabels: Set<String> = []
    func observed(_ label: String, block: Bool = false) {
        condition.lock()
        probeCounts[label, default: 0] += 1
        while block && !released { condition.wait() }
        condition.unlock()
    }
    func enqueued(_ label: String) { condition.lock(); enqueuedLabels.insert(label); condition.unlock() }
    func finished(_ label: String) { condition.lock(); finishedLabels.insert(label); condition.unlock() }
    func probes(_ label: String) -> Int { condition.lock(); defer { condition.unlock() }; return probeCounts[label, default: 0] }
    func isEnqueued(_ label: String) -> Bool { condition.lock(); defer { condition.unlock() }; return enqueuedLabels.contains(label) }
    func isFinished(_ label: String) -> Bool { condition.lock(); defer { condition.unlock() }; return finishedLabels.contains(label) }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
private func waitForNearestReadGate(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard condition() else { throw LocalStorageError.other("Metadata verification gate did not settle.") }
}
