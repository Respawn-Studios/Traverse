import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct Fixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL
    let trash: URL

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let base = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"].map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        guard base.path.hasPrefix(repository.path + "/"), base.pathComponents.contains(".build"),
              base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("operations-" + UUID().uuidString, isDirectory: true)
        guard root.withUnsafeFileSystemRepresentation({ mkdir($0!, 0o700) }) == 0 else { throw FileOperationFailure.ioFailure }
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        trash = root.appendingPathComponent("owned-trash", isDirectory: true)
        for directory in [source, destination, trash] {
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: false)
        }
    }

    func file(_ name: String, text: String = "original", in directory: URL? = nil) throws -> URL {
        let url = (directory ?? source).appendingPathComponent(name)
        guard url.path.hasPrefix(root.path + "/") else { throw FileOperationFailure.invalidRequest }
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    func directory(_ name: String, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? source).appendingPathComponent(name, isDirectory: true)
        guard url.path.hasPrefix(root.path + "/") else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func operations(hooks: OperationHooks = OperationHooks()) -> LocalFileOperations {
        let ownedTrash = trash
        return LocalFileOperations(trash: { source in
            // Every test service overrides Trash. Never invoke the real user's Trash.
            let result = ownedTrash.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            try FileManager().moveItem(at: source, to: result)
            return result
        }, hooks: hooks)
    }

    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { FileManager().fileExists(atPath: url.path) }
    func remove() throws { try FileManager().removeItem(at: root) }
}

@Test func createsAndRenamesWithoutReplacing() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let operations = fixture.operations()
    let created = await operations.perform(.createFolder(parent: fixture.destination, name: "New Folder"))
    #expect(created.disposition == .succeeded)
    let folder = fixture.destination.appendingPathComponent("New Folder")
    #expect(fixture.exists(folder))
    let duplicate = await operations.perform(.createFolder(parent: fixture.destination, name: "New Folder"))
    #expect(duplicate.items.first?.status == .failed(.conflict))
    let file = try fixture.file("before.txt")
    let renamed = await operations.perform(.rename(source: file, name: "after.txt"))
    #expect(renamed.disposition == .succeeded)
    #expect(!fixture.exists(file))
    #expect(try fixture.text(fixture.source.appendingPathComponent("after.txt")) == "original")
}

@Test(.enabled(if: geteuid() != 0, "Root bypasses mode-bit read denial; search-only traversal is unexercised under root."))
func searchableAncestorSupportsObservationCopyAndSameVolumeMove() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let ancestor = try fixture.directory("execute-only", in: fixture.root)
    let source = try fixture.directory("source", in: ancestor)
    let destination = try fixture.directory("destination", in: ancestor)
    let copySource = try fixture.file("copy.txt", in: source)
    let moveSource = try fixture.file("move.txt", in: source)
    try #require(ancestor.withUnsafeFileSystemRepresentation { chmod($0!, 0o111) } == 0)
    defer { _ = ancestor.withUnsafeFileSystemRepresentation { chmod($0!, 0o700) } }
    // The ancestor permits traversal to exact known children, but not reading its names.
    let readFD = ancestor.withUnsafeFileSystemRepresentation {
        Darwin.open($0!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    let readError = errno
    if readFD >= 0 { close(readFD) }
    try #require(readFD < 0 && readError == EACCES, "Fixture must exercise real directory read denial.")
    #expect(try fixture.text(copySource) == "original")
    let operations = fixture.operations()
    let observedDirectory = try? await operations.observeDirectory(destination)
    #expect(observedDirectory?.urls.map(\.path) == [destination.path])
    let observedSource = try? await operations.observeSelection([copySource])
    #expect(observedSource?.urls == [copySource])
    let copied = await operations.perform(.copy(sources: [copySource], destinationDirectory: destination))
    #expect(copied.items.map(\.status) == [.succeeded])
    #expect(fixture.exists(destination.appendingPathComponent("copy.txt")))
    #expect(try fixture.text(copySource) == "original")
    let moved = await operations.perform(.move(sources: [moveSource], destinationDirectory: destination))
    #expect(moved.items.map(\.status) == [.succeeded])
    #expect(!fixture.exists(moveSource))
    #expect(fixture.exists(destination.appendingPathComponent("move.txt")))
}

@Test func copyPreservesSourceBodiesPackagesAndSymlinks() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("文件 Café.txt", text: "copied bytes")
    let package = try fixture.directory("Example.app")
    _ = try fixture.file("nested.txt", text: "package body", in: package)
    let link = fixture.source.appendingPathComponent("link")
    try FileManager().createSymbolicLink(atPath: link.path, withDestinationPath: file.lastPathComponent)
    let dangling = fixture.source.appendingPathComponent("dangling")
    try FileManager().createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing-target")
    let result = await fixture.operations().perform(.copy(sources: [file, package, link, dangling], destinationDirectory: fixture.destination))
    let fixtureOutcomes = result.items.map { "\($0.source?.lastPathComponent ?? "create")=\($0.status)" }.joined(separator: ", ")
    try #require(result.disposition == .succeeded, "Fixture outcomes: \(fixtureOutcomes)")
    #expect(result.items.count == 4)
    #expect(try fixture.text(file) == "copied bytes")
    #expect(try fixture.text(fixture.destination.appendingPathComponent(file.lastPathComponent)) == "copied bytes")
    #expect(try fixture.text(fixture.destination.appendingPathComponent("Example.app/nested.txt")) == "package body")
    #expect(try FileManager().destinationOfSymbolicLink(atPath: fixture.destination.appendingPathComponent("link").path) == file.lastPathComponent)
    #expect(try FileManager().destinationOfSymbolicLink(atPath: fixture.destination.appendingPathComponent("dangling").path) == "missing-target")
    #expect(result.items.allSatisfy { $0.recoveryURLs.isEmpty })
}

@Test func copyPreservesOrdinaryFileModeModifiedTimeAndSyntheticXattr() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let source = try fixture.file("metadata.txt")
    try FileManager().setAttributes([
        .posixPermissions: NSNumber(value: 0o640),
        .modificationDate: Date(timeIntervalSince1970: 1_700_000_123),
    ], ofItemAtPath: source.path)
    let attribute = "com.macexplorer.fixture-copy"
    let marker = Data("owned fixture metadata".utf8)
    let setResult = marker.withUnsafeBytes { bytes in
        source.withUnsafeFileSystemRepresentation {
            setxattr($0!, attribute, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
        }
    }
    try #require(setResult == 0, "Synthetic fixture xattr must be supported for this fidelity test.")
    var before = stat()
    try #require(source.withUnsafeFileSystemRepresentation { lstat($0!, &before) } == 0)
    let result = await fixture.operations().perform(.copy(sources: [source], destinationDirectory: fixture.destination))
    try #require(result.disposition == .succeeded)
    let destination = fixture.destination.appendingPathComponent("metadata.txt")
    var copied = stat()
    var after = stat()
    try #require(destination.withUnsafeFileSystemRepresentation { lstat($0!, &copied) } == 0)
    try #require(source.withUnsafeFileSystemRepresentation { lstat($0!, &after) } == 0)
    #expect(before.st_mode & 0o777 == 0o640)
    #expect(copied.st_mode & 0o777 == before.st_mode & 0o777)
    #expect(copied.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
    #expect(copied.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
    #expect(after.st_ino == before.st_ino)
    #expect(after.st_mode == before.st_mode)
    #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
    #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
    #expect(after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec)
    #expect(after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec)
    for url in [source, destination] {
        var bytes = [UInt8](repeating: 0, count: marker.count)
        let count = bytes.withUnsafeMutableBytes { buffer in
            url.withUnsafeFileSystemRepresentation {
                getxattr($0!, attribute, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
            }
        }
        #expect(count == marker.count)
        #expect(Data(bytes) == marker)
        #expect(try fixture.text(url) == "original")
    }
    #expect(result.items.first?.recoveryURLs.isEmpty == true)
}

@Test func preflightConflictAndExecutionPreserveBothItems() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("same.txt")
    let target = try fixture.file("same.txt", text: "destination", in: fixture.destination)
    let operations = fixture.operations()
    let request = FileOperationRequest.copy(sources: [file], destinationDirectory: fixture.destination)
    #expect(try await operations.conflicts(for: request) == [target])
    let result = await operations.perform(request)
    #expect(result.items.first?.status == .failed(.conflict))
    #expect(try fixture.text(file) == "original")
    #expect(try fixture.text(target) == "destination")
    let other = try fixture.file("other.txt")
    let rename = await operations.perform(.rename(source: other, name: "same.txt"))
    #expect(rename.items.first?.status == .failed(.conflict))
    #expect(try fixture.text(other) == "original")
}

@Test func commitRaceNeverOverwritesAndRetainsOwnedStage() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("copy.txt")
    let operations = fixture.operations(hooks: OperationHooks(beforeCommit: { destination in
        try? Data("racer".utf8).write(to: destination!, options: .withoutOverwriting)
    }))
    let result = await operations.perform(.copy(sources: [file], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.conflict))
    #expect(try fixture.text(file) == "original")
    #expect(try fixture.text(fixture.destination.appendingPathComponent("copy.txt")) == "racer")
    let stage = try #require(result.items.first?.recoveryURLs.first)
    #expect(stage.path.hasPrefix(fixture.root.path + "/"))
    #expect(try fixture.text(stage.appendingPathComponent("payload")) == "original")
}

@Test func replacementAfterPreflightIsRefused() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("source.txt")
    let backup = fixture.source.appendingPathComponent("original-backup.txt")
    let operations = fixture.operations(hooks: OperationHooks(afterPreflight: {
        try? FileManager().moveItem(at: file, to: backup)
        try? Data("replacement".utf8).write(to: file, options: .withoutOverwriting)
    }))
    let result = await operations.perform(.move(sources: [file], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.sourceChanged))
    #expect(try fixture.text(file) == "replacement")
    #expect(try fixture.text(backup) == "original")
    #expect(!fixture.exists(fixture.destination.appendingPathComponent("source.txt")))
}

@Test func destinationAncestorReplacementDoesNotRedirectWrites() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("source.txt")
    let other = try fixture.directory("other", in: fixture.root)
    let detached = fixture.root.appendingPathComponent("detached")
    let operations = fixture.operations(hooks: OperationHooks(afterPreflight: {
        try? FileManager().moveItem(at: fixture.destination, to: detached)
        try? FileManager().createSymbolicLink(at: fixture.destination, withDestinationURL: other)
    }))
    let result = await operations.perform(.copy(sources: [file], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.destinationChanged))
    #expect(try FileManager().contentsOfDirectory(atPath: other.path).isEmpty)
    #expect(try FileManager().contentsOfDirectory(atPath: detached.path).isEmpty)
    #expect(try fixture.text(file) == "original")
}

@Test func observedCutRejectsReplacedIdentityAndMovesUnchangedSource() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let operations = fixture.operations()
    let file = try fixture.file("cut.txt")
    let observed = try await operations.observeSelection([file])
    let backup = fixture.source.appendingPathComponent("backup")
    try FileManager().moveItem(at: file, to: backup)
    _ = try fixture.file("cut.txt", text: "new inode")
    let refused = await operations.perform(.moveObserved(selection: observed, destinationDirectory: fixture.destination))
    #expect(refused.items.first?.status == .failed(.sourceChanged))
    #expect(try fixture.text(file) == "new inode")
    let current = try await operations.observeSelection([file])
    let moved = await operations.perform(.moveObserved(selection: current, destinationDirectory: fixture.destination))
    #expect(moved.disposition == .succeeded)
    #expect(!fixture.exists(file))
    #expect(try fixture.text(fixture.destination.appendingPathComponent("cut.txt")) == "new inode")
}

@Test func simulatedCrossVolumeMovePreservesSource() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("source.txt")
    let result = await fixture.operations(hooks: OperationHooks(destinationDeviceOverride: .max)).perform(
        .move(sources: [file], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.crossVolumeMoveUnsupported))
    #expect(try fixture.text(file) == "original")
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}

@Test func unsafeNamesDuplicatesNestedSelectionsAndRecursiveDestinationsAreRefused() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let operations = fixture.operations()
    let file = try fixture.file("file.txt")
    let folder = try fixture.directory("Folder")
    let child = try fixture.file("child.txt", in: folder)
    let nested = try fixture.directory("Nested", in: folder)
    let requests: [FileOperationRequest] = [
        .createFolder(parent: fixture.destination, name: "../escaped"),
        .trash(sources: [file, file]), .trash(sources: [folder, child]),
        .copy(sources: [folder], destinationDirectory: nested),
        .copy(sources: [file], destinationDirectory: fixture.source),
    ]
    for request in requests {
        let result = await operations.perform(request)
        #expect(result.items.allSatisfy { $0.status == .failed(.invalidRequest) })
    }
    #expect(try fixture.text(file) == "original")
    #expect(try fixture.text(child) == "original")
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    // Root rejection is exercised observationally, never as a destructive request.
    do {
        _ = try await operations.conflicts(for: .rename(source: URL(fileURLWithPath: "/"), name: "root"))
        Issue.record("Root unexpectedly passed read-only preparation.")
    } catch FileOperationFailure.invalidRequest {}
}

@Test func fixtureTrashIsRecoverableAndFailedTrashPreservesSource() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("trash.txt")
    let result = await fixture.operations().perform(.trash(sources: [file]))
    #expect(result.disposition == .succeeded)
    let destination = try #require(result.items.first?.destination)
    #expect(destination.path.hasPrefix(fixture.trash.path + "/"))
    #expect(try fixture.text(destination) == "original")
    #expect(!fixture.exists(file))
    let retained = try fixture.file("retained.txt")
    let failing = LocalFileOperations(trash: { _ in throw FileOperationFailure.accessDenied })
    let failed = await failing.perform(.trash(sources: [retained]))
    #expect(failed.items.first?.status == .failed(.accessDenied))
    #expect(try fixture.text(retained) == "original")
}

private final class Checkpoint: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = false
    var reached: Bool { lock.withLock { entered } }
    func blockOnce() {
        let block = lock.withLock { if entered { return false }; entered = true; return true }
        if block { gate.wait() }
    }
    func release() { gate.signal() }
    func waitUntilReached() async throws {
        for _ in 0..<500 {
            if reached { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        release()
        throw FileOperationFailure.unavailable
    }
}

@Test func cancelledCopyRetainsStageAndAwaitsWorkerCompletion() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("cancel.txt")
    let checkpoint = Checkpoint()
    let operations = fixture.operations(hooks: OperationHooks(beforeCommit: { _ in checkpoint.blockOnce() }))
    let destination = fixture.destination
    let task = Task { await operations.perform(.copy(sources: [file], destinationDirectory: destination)) }
    try await checkpoint.waitUntilReached()
    task.cancel()
    checkpoint.release()
    let result = await task.value
    #expect(result.disposition == .cancelled)
    #expect(result.cancellationRequested)
    #expect(result.items.first?.status == .cancelled)
    #expect(try fixture.text(file) == "original")
    #expect(!fixture.exists(destination.appendingPathComponent("cancel.txt")))
    let stage = try #require(result.items.first?.recoveryURLs.first)
    #expect(try fixture.text(stage.appendingPathComponent("payload")) == "original")
}

@Test func cancellationAfterFirstCommitReportsPartialSuccess() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let first = try fixture.file("first.txt")
    let second = try fixture.file("second.txt")
    let checkpoint = Checkpoint()
    let operations = fixture.operations(hooks: OperationHooks(afterItem: { checkpoint.blockOnce() }))
    let destination = fixture.destination
    let task = Task { await operations.perform(.copy(sources: [first, second], destinationDirectory: destination)) }
    try await checkpoint.waitUntilReached()
    task.cancel()
    checkpoint.release()
    let result = await task.value
    #expect(result.disposition == .partial)
    #expect(result.items.map(\.status) == [.succeeded, .cancelled])
    #expect(fixture.exists(destination.appendingPathComponent("first.txt")))
    #expect(!fixture.exists(destination.appendingPathComponent("second.txt")))
    #expect(try fixture.text(first) == "original")
    #expect(try fixture.text(second) == "original")
}

@Test func missingSourceAndSafeErrorsDoNotMutateDestination() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let result = await fixture.operations().perform(.copy(sources: [fixture.source.appendingPathComponent("missing")], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.notFound))
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    for failure in [FileOperationFailure.conflict, .sourceChanged, .recoveryUncertain, .accessDenied] {
        #expect(!failure.userMessage.contains(fixture.root.path))
    }
}

@Test func renameRaceAfterLastCheckPreservesOccupantsAndReportsUncertainty() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("race.txt")
    let backup = fixture.source.appendingPathComponent("backup.txt")
    let operations = fixture.operations(hooks: OperationHooks(beforeRename: {
        try? FileManager().moveItem(at: file, to: backup)
        try? Data("replacement".utf8).write(to: file, options: .withoutOverwriting)
    }))
    let result = await operations.perform(.move(sources: [file], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.recoveryUncertain))
    #expect(try fixture.text(backup) == "original")
    #expect(!fixture.exists(file))
    let destination = fixture.destination.appendingPathComponent("race.txt")
    #expect(try fixture.text(destination) == "replacement")
    #expect(result.items.first?.recoveryURLs.contains(destination) == true)
}

@Test func renameRacePreservesNewSourceConflictAndReportsBothLocations() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("race.txt")
    let backup = fixture.source.appendingPathComponent("backup.txt")
    let operations = fixture.operations(hooks: OperationHooks(beforeRename: {
        try? FileManager().moveItem(at: file, to: backup)
        try? Data("replacement".utf8).write(to: file, options: .withoutOverwriting)
    }, afterRename: {
        try? Data("new conflict".utf8).write(to: file, options: .withoutOverwriting)
    }))
    let result = await operations.perform(.move(sources: [file], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.recoveryUncertain))
    #expect(try fixture.text(backup) == "original")
    #expect(try fixture.text(file) == "new conflict")
    let destination = fixture.destination.appendingPathComponent("race.txt")
    #expect(try fixture.text(destination) == "replacement")
    #expect(result.items.first?.recoveryURLs == [file, destination])
}

@Test func destinationReplacementAfterRenameIsNeverMovedBackToSource() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("race.txt")
    let destination = fixture.destination.appendingPathComponent("race.txt")
    let detached = fixture.destination.appendingPathComponent("moved-original.txt")
    let operations = fixture.operations(hooks: OperationHooks(afterRename: {
        try? FileManager().moveItem(at: destination, to: detached)
        try? Data("unrelated occupant".utf8).write(to: destination, options: .withoutOverwriting)
    }))
    let result = await operations.perform(.move(sources: [file], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.recoveryUncertain))
    #expect(!fixture.exists(file))
    #expect(try fixture.text(detached) == "original")
    #expect(try fixture.text(destination) == "unrelated occupant")
    #expect(result.items.first?.recoveryURLs == [file, destination])
}

@Test func largeObservedBatchCanSkipInputsWithoutLosingRemainingIdentity() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let files = try (0..<1_000).map { try fixture.file("item-\($0).txt") }
    let operations = fixture.operations()
    let observed = try await operations.observeSelection(files)
    let retained = observed.excluding(Set(files.dropLast()))
    #expect(retained.urls == [files.last!])
    let file = files.last!
    let backup = fixture.source.appendingPathComponent("original-backup.txt")
    try FileManager().moveItem(at: file, to: backup)
    _ = try fixture.file(file.lastPathComponent, text: "replacement")
    let result = await operations.perform(.moveObserved(selection: retained, destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.sourceChanged))
    #expect(try fixture.text(file) == "replacement")
    #expect(try fixture.text(backup) == "original")
}

@Test func directoryChildChangesBeforeCommitAreDetectedAndStageIsRetained() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let folder = try fixture.directory("Package.app")
    let child = try fixture.file("child.txt", text: "old", in: folder)
    let operations = fixture.operations(hooks: OperationHooks(beforeCommit: { _ in
        try? Data("new".utf8).write(to: child)
    }))
    let result = await operations.perform(.copy(sources: [folder], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.sourceChanged))
    #expect(try fixture.text(child) == "new")
    #expect(!fixture.exists(fixture.destination.appendingPathComponent("Package.app")))
    let stage = try #require(result.items.first?.recoveryURLs.first)
    #expect(try fixture.text(stage.appendingPathComponent("payload/child.txt")) == "old")
}

@Test func unsupportedSpecialFileIsNotFollowedOrPublished() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let fifo = fixture.source.appendingPathComponent("pipe")
    #expect(fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) } == 0)
    let result = await fixture.operations().perform(.copy(sources: [fifo], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.unsupported))
    #expect(fixture.exists(fifo))
    #expect(!fixture.exists(fixture.destination.appendingPathComponent("pipe")))
}

@Test func regularSourceReplacedByFIFOBeforePinIsRefusedWithoutBlocking() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("source.txt")
    let saved = fixture.source.appendingPathComponent("saved.txt")
    let operations = fixture.operations(hooks: OperationHooks(afterPreflight: {
        try? FileManager().moveItem(at: file, to: saved)
        _ = file.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) }
    }))
    let result = await operations.perform(.copy(sources: [file], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.sourceChanged))
    #expect(try fixture.text(saved) == "original")
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    var current = stat()
    #expect(file.withUnsafeFileSystemRepresentation { lstat($0!, &current) } == 0)
    #expect(current.st_mode & S_IFMT == S_IFIFO)
}

@Test func duplicateDestinationNamesAreRejectedBeforeAnyBatchMutation() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let other = try fixture.directory("other", in: fixture.root)
    let first = try fixture.file("same.txt")
    let second = try fixture.file("same.txt", text: "second", in: other)
    let operations = fixture.operations()
    let request = FileOperationRequest.copy(sources: [first, second], destinationDirectory: fixture.destination)
    do {
        _ = try await operations.conflicts(for: request)
        Issue.record("Duplicate destination names unexpectedly passed preparation.")
    } catch FileOperationFailure.invalidRequest {}
    let result = await operations.perform(request)
    #expect(result.items.map(\.status) == [.failed(.invalidRequest), .failed(.invalidRequest)])
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    #expect(try fixture.text(first) == "original")
    #expect(try fixture.text(second) == "second")
}

@Test func destinationCaseRulesControlCaseVariantBatchPreparation() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let other = try fixture.directory("other", in: fixture.root)
    let first = try fixture.file("Case.txt")
    let second = try fixture.file("case.txt", text: "second", in: other)
    let fd = fixture.destination.withUnsafeFileSystemRepresentation { Darwin.open($0!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
    #expect(fd >= 0)
    guard fd >= 0 else { return }
    let caseSensitive = fpathconf(fd, _PC_CASE_SENSITIVE) == 1
    close(fd)
    let result = await fixture.operations().perform(.copy(sources: [first, second], destinationDirectory: fixture.destination))
    if caseSensitive {
        #expect(result.disposition == .succeeded)
        #expect(try fixture.text(fixture.destination.appendingPathComponent("Case.txt")) == "original")
        #expect(try fixture.text(fixture.destination.appendingPathComponent("case.txt")) == "second")
    } else {
        #expect(result.items.allSatisfy { $0.status == .failed(.invalidRequest) })
        #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }
    #expect(try fixture.text(first) == "original")
    #expect(try fixture.text(second) == "second")
}

@Test func copyRecoveryUsesCurrentAnchoredParentAfterCommitRace() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("copy.txt")
    let detached = fixture.root.appendingPathComponent("detached", isDirectory: true)
    let committed = detached.appendingPathComponent("copy.txt")
    let saved = detached.appendingPathComponent("saved-original.txt")
    let operations = fixture.operations(hooks: OperationHooks(afterCopyCommit: {
        try? FileManager().moveItem(at: fixture.destination, to: detached)
        try? FileManager().createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        try? FileManager().moveItem(at: committed, to: saved)
        try? Data("unrelated occupant".utf8).write(to: committed, options: .withoutOverwriting)
    }))
    let result = await operations.perform(.copy(sources: [file], destinationDirectory: fixture.destination))
    #expect(result.items.first?.status == .failed(.recoveryUncertain))
    let recovery = try #require(result.items.first?.recoveryURLs)
    #expect(recovery.contains(committed))
    #expect(!recovery.contains(fixture.destination.appendingPathComponent("copy.txt")))
    #expect(recovery.contains { $0.deletingLastPathComponent().path == detached.path && $0.lastPathComponent.hasPrefix(".mac-explorer-stage-") })
    #expect(try fixture.text(file) == "original")
    #expect(try fixture.text(saved) == "original")
    #expect(try fixture.text(committed) == "unrelated occupant")
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
}

@Test func staleObservedRenamePreservesReplacementOccupant() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("rename.txt")
    let operations = fixture.operations()
    let observation = try await operations.observeSelection([file])
    let saved = fixture.source.appendingPathComponent("saved.txt")
    try FileManager().moveItem(at: file, to: saved)
    _ = try fixture.file("rename.txt", text: "replacement")
    let result = await operations.perform(.rename(source: file, name: "renamed.txt"), observing: observation)
    #expect(result.items.first?.status == .failed(.sourceChanged))
    #expect(try fixture.text(file) == "replacement")
    #expect(try fixture.text(saved) == "original")
    #expect(!fixture.exists(fixture.source.appendingPathComponent("renamed.txt")))
}

@Test func staleObservedTrashNeverCallsFixtureTrashForReplacement() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("trash.txt")
    let operations = fixture.operations()
    let observation = try await operations.observeSelection([file])
    let saved = fixture.source.appendingPathComponent("saved.txt")
    try FileManager().moveItem(at: file, to: saved)
    _ = try fixture.file("trash.txt", text: "replacement")
    let result = await operations.perform(.trash(sources: [file]), observing: observation)
    #expect(result.items.first?.status == .failed(.sourceChanged))
    #expect(try fixture.text(file) == "replacement")
    #expect(try fixture.text(saved) == "original")
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test func staleObservedCreateParentPreservesBothDirectories() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let operations = fixture.operations()
    let observation = try await operations.observeDirectory(fixture.destination)
    let detached = fixture.root.appendingPathComponent("detached")
    try FileManager().moveItem(at: fixture.destination, to: detached)
    try FileManager().createDirectory(at: fixture.destination, withIntermediateDirectories: false)
    let result = await operations.perform(.createFolder(parent: fixture.destination, name: "New Folder"), observing: observation)
    #expect(result.items.first?.status == .failed(.sourceChanged))
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    #expect(try FileManager().contentsOfDirectory(atPath: detached.path).isEmpty)
}

@Test func observedIdentityCannotBeReplacedBetweenGuardAndPreparation() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("rename.txt")
    let saved = fixture.source.appendingPathComponent("saved.txt")
    let observation = try await fixture.operations().observeSelection([file])
    let operations = fixture.operations(hooks: OperationHooks(afterObservationValidation: {
        try? FileManager().moveItem(at: file, to: saved)
        try? Data("replacement".utf8).write(to: file, options: .withoutOverwriting)
    }))
    let result = await operations.perform(.rename(source: file, name: "renamed.txt"), observing: observation)
    #expect(result.items.first?.status == .failed(.sourceChanged))
    #expect(try fixture.text(file) == "replacement")
    #expect(try fixture.text(saved) == "original")
    #expect(!fixture.exists(fixture.source.appendingPathComponent("renamed.txt")))
}

@Test func observedPasteDestinationSurvivesPreparationAndIsRevalidated() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let file = try fixture.file("copy.txt")
    let observation = try await fixture.operations().observeDirectory(fixture.destination)
    let detached = fixture.root.appendingPathComponent("detached")
    let operations = fixture.operations(hooks: OperationHooks(afterObservationValidation: {
        try? FileManager().moveItem(at: fixture.destination, to: detached)
        try? FileManager().createDirectory(at: fixture.destination, withIntermediateDirectories: false)
    }))
    let request = FileOperationRequest.copy(sources: [file], destinationDirectory: fixture.destination)
    let result = await operations.perform(request, observing: observation)
    #expect(result.items.first?.status == .failed(.destinationChanged))
    #expect(try fixture.text(file) == "original")
    #expect(try FileManager().contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    #expect(try FileManager().contentsOfDirectory(atPath: detached.path).isEmpty)
}

@Test func directoryGuardsSupportRootsAndSymlinkAliasesWithoutRelaxingMutationSources() async throws {
    let fixture = try Fixture()
    defer { try? fixture.remove() }
    let operations = fixture.operations()
    // Read-only observation of a real root; every mutation below stays in the owned fixture.
    let root = try await operations.observeDirectory(URL(fileURLWithPath: "/", isDirectory: true))
    #expect(root.urls.map(\.path) == ["/"])
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager().createSymbolicLink(at: alias, withDestinationURL: fixture.destination)
    let observation = try await operations.observeDirectory(alias)
    #expect(observation.urls.map(\.path) == [fixture.destination.path])
    let result = await operations.perform(.createFolder(parent: alias, name: "New Folder"), observing: observation)
    #expect(result.disposition == .succeeded)
    #expect(fixture.exists(fixture.destination.appendingPathComponent("New Folder")))
    let nested = try await operations.observeSelection([fixture.destination, fixture.destination.appendingPathComponent("New Folder")])
    #expect(nested.urls.count == 2)
}
