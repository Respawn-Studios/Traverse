import Darwin
import Foundation
@testable import FileOperations
import Testing

private enum CrossVolumeFixtureBoundaryError: Error {
    case unsafeURL(stage: String)
    case nonDirectoryAncestor(stage: String, index: Int, kind: mode_t)
    case unavailableAncestor(stage: String, index: Int, code: Int32)
    case outsideRepository
    case outsideBuildFixtureRoot
    case redirectedBuildFixtureRoot
}

private func requireNoSymlinkComponents(_ url: URL, stage: String) throws {
    // Foundation can standardize '/private/tmp' to '/tmp' on macOS. Validate the
    // explicit absolute spelling instead, then lstat every ancestor without following links.
    guard url.isFileURL, url.path.hasPrefix("/"), url.host == nil || url.host == "" || url.host == "localhost",
          !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
        throw CrossVolumeFixtureBoundaryError.unsafeURL(stage: stage)
    }
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for (index, component) in url.pathComponents.dropFirst().enumerated() {
        current.appendPathComponent(component)
        var value = stat()
        guard current.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0 else {
            throw CrossVolumeFixtureBoundaryError.unavailableAncestor(stage: stage, index: index, code: errno)
        }
        guard value.st_mode & S_IFMT == S_IFDIR else {
            throw CrossVolumeFixtureBoundaryError.nonDirectoryAncestor(stage: stage, index: index, kind: value.st_mode & S_IFMT)
        }
    }
}

private struct CrossVolumeMetadata: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ url: URL) throws {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0 else { throw FileOperationFailure.notFound }
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
}

private struct OwnedCrossVolumeRoot {
    let url: URL
    let parent: URL
    let uuid: UUID
    let identity: CrossVolumeMetadata
    private var marker: URL { url.appendingPathComponent(".mac-explorer-owned-fixture") }
    private var markerData: Data { Data("MacExplorer cross-volume fixture v1\n\(uuid.uuidString)\n".utf8) }

    init(parent: URL, uuid: UUID) throws {
        try requireNoSymlinkComponents(parent, stage: parent.path == "/private/tmp" ? "temporary-parent" : "repository-parent")
        self.parent = parent
        self.uuid = uuid
        url = parent.appendingPathComponent("mac-explorer-cross-volume-" + uuid.uuidString, isDirectory: true)
        guard url.withUnsafeFileSystemRepresentation({ mkdir($0!, 0o700) }) == 0 else { throw FileOperationFailure.ioFailure }
        do {
            identity = try CrossVolumeMetadata(url)
            try Data("MacExplorer cross-volume fixture v1\n\(uuid.uuidString)\n".utf8)
                .write(to: url.appendingPathComponent(".mac-explorer-owned-fixture"), options: .withoutOverwriting)
        } catch {
            // Only an empty directory created by this exact mkdir may be removed before its marker exists.
            _ = url.withUnsafeFileSystemRepresentation { rmdir($0!) }
            throw error
        }
    }

    func remove() throws {
        guard url.deletingLastPathComponent().path == parent.path,
              url.lastPathComponent == "mac-explorer-cross-volume-" + uuid.uuidString else { throw FileOperationFailure.invalidRequest }
        try requireNoSymlinkComponents(url, stage: "owned-root-cleanup")
        let current = try CrossVolumeMetadata(url)
        guard current.device == identity.device, current.inode == identity.inode else { throw FileOperationFailure.sourceChanged }
        var value = stat()
        guard marker.withUnsafeFileSystemRepresentation({ lstat($0!, &value) }) == 0,
              value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_uid == geteuid(),
              try Data(contentsOf: marker) == markerData else { throw FileOperationFailure.invalidRequest }
        try FileManager().removeItem(at: url)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1",
               "Explicit private temporary fixtures require MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS=1."))
func explicitPrivateTmpCanonicalAnchorsSupportGuardedCreateAndRename() async throws {
    let root = try OwnedCrossVolumeRoot(parent: URL(fileURLWithPath: "/private/tmp", isDirectory: true), uuid: UUID())
    defer { do { try root.remove() } catch { Issue.record("Owned private temporary fixture cleanup failed; retained for review.") } }
    let operations = LocalFileOperations(trash: { _ in throw FileOperationFailure.unsupported })
    let parentGuard = try await operations.observeDirectory(root.url)
    #expect(parentGuard.urls.map(\.path) == [root.url.path])
    let create = FileOperationRequest.createFolder(parent: root.url, name: "created")
    #expect(try await operations.conflicts(for: create, observing: parentGuard).isEmpty)
    let created = await operations.perform(create, observing: parentGuard)
    try #require(created.items.map(\.status) == [.succeeded])
    let source = root.url.appendingPathComponent("created/source.txt")
    let body = Data("owned private temporary fixture".utf8)
    try body.write(to: source, options: .withoutOverwriting)
    let sourceGuard = try await operations.observeSelection([source])
    #expect(sourceGuard.urls.map(\.path) == [source.path])
    let rename = FileOperationRequest.rename(source: source, name: "renamed.txt")
    #expect(try await operations.conflicts(for: rename, observing: sourceGuard).isEmpty)
    let renamed = await operations.perform(rename, observing: sourceGuard)
    #expect(renamed.items.map(\.status) == [.succeeded])
    #expect(!FileManager().fileExists(atPath: source.path))
    #expect(try Data(contentsOf: root.url.appendingPathComponent("created/renamed.txt")) == body)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1",
               "Real cross-volume fixtures require MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS=1."))
func actualCrossVolumeCopyPreservesSourcesAndMetadataAndMoveIsRefused() async throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let repository = package.deletingLastPathComponent().deletingLastPathComponent()
    let base = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        ?? package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
    let components = base.pathComponents
    let insideFixtureRoot = components.indices.dropLast().contains {
        components[$0] == ".build" && components[$0 + 1] == "test-fixtures"
    }
    guard base.path.hasPrefix(repository.path + "/") else { throw CrossVolumeFixtureBoundaryError.outsideRepository }
    guard insideFixtureRoot else { throw CrossVolumeFixtureBoundaryError.outsideBuildFixtureRoot }
    guard base.resolvingSymlinksInPath().path == base.path else { throw CrossVolumeFixtureBoundaryError.redirectedBuildFixtureRoot }
    try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
    let uuid = UUID()
    let local = try OwnedCrossVolumeRoot(parent: base, uuid: uuid)
    defer { do { try local.remove() } catch { Issue.record("Owned repository cross-volume fixture cleanup failed; retained for review.") } }
    let temporary = try OwnedCrossVolumeRoot(parent: URL(fileURLWithPath: "/private/tmp", isDirectory: true), uuid: uuid)
    defer { do { try temporary.remove() } catch { Issue.record("Owned temporary cross-volume fixture cleanup failed; retained for review.") } }
    try #require(local.identity.device != temporary.identity.device,
                 "Enabled cross-volume fixture roots must have genuinely different st_dev values.")
    let source = local.url.appendingPathComponent("source", isDirectory: true)
    let destination = temporary.url.appendingPathComponent("destination", isDirectory: true)
    let emptyDestination = temporary.url.appendingPathComponent("empty-destination", isDirectory: true)
    for directory in [source, destination, emptyDestination] {
        try FileManager().createDirectory(at: directory, withIntermediateDirectories: false)
    }
    let file = source.appendingPathComponent("payload.bin")
    let bytes = Data((0..<(1_024 * 1_024)).map { UInt8(truncatingIfNeeded: $0) })
    try bytes.write(to: file, options: .withoutOverwriting)
    try FileManager().setAttributes([.posixPermissions: NSNumber(value: 0o640),
                                    .modificationDate: Date(timeIntervalSince1970: 1_700_000_123)], ofItemAtPath: file.path)
    let attribute = "com.macexplorer.fixture-cross-volume"
    let marker = Data("owned cross-volume metadata".utf8)
    let setResult = marker.withUnsafeBytes { value in
        file.withUnsafeFileSystemRepresentation { setxattr($0!, attribute, value.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
    }
    try #require(setResult == 0, "Synthetic fixture xattr must be supported for metadata qualification.")
    let bundle = source.appendingPathComponent("Example.app", isDirectory: true)
    try FileManager().createDirectory(at: bundle, withIntermediateDirectories: false)
    let bundleChild = bundle.appendingPathComponent("owned.txt")
    let bundleBytes = Data("owned package body".utf8)
    try bundleBytes.write(to: bundleChild, options: .withoutOverwriting)
    let link = source.appendingPathComponent("opaque-link")
    try FileManager().createSymbolicLink(atPath: link.path, withDestinationPath: "payload.bin")
    let relatives = ["payload.bin", "Example.app", "Example.app/owned.txt", "opaque-link"]
    let before = try relatives.map { try CrossVolumeMetadata(source.appendingPathComponent($0)) }
    // Every service in this test has an injected non-system Trash adapter.
    let operations = LocalFileOperations(trash: { _ in throw FileOperationFailure.unsupported })
    let destinationObservation = try await operations.observeDirectory(destination)
    #expect(destinationObservation.urls.map(\.path) == [destination.path])
    let copyRequest = FileOperationRequest.copy(sources: [file, bundle, link], destinationDirectory: destination)
    #expect(try await operations.conflicts(for: copyRequest, observing: destinationObservation).isEmpty)
    let copied = await operations.perform(copyRequest, observing: destinationObservation)
    try #require(copied.items.map(\.status) == [.succeeded, .succeeded, .succeeded])
    #expect(copied.items.allSatisfy { $0.recoveryURLs.isEmpty })
    #expect(try Data(contentsOf: destination.appendingPathComponent("payload.bin")) == bytes)
    #expect(try Data(contentsOf: destination.appendingPathComponent("Example.app/owned.txt")) == bundleBytes)
    #expect(try FileManager().destinationOfSymbolicLink(atPath: destination.appendingPathComponent("opaque-link").path) == "payload.bin")
    let copiedMetadata = try CrossVolumeMetadata(destination.appendingPathComponent("payload.bin"))
    #expect(copiedMetadata.mode & 0o777 == before[0].mode & 0o777)
    #expect(copiedMetadata.modifiedSeconds == before[0].modifiedSeconds)
    #expect(copiedMetadata.modifiedNanos == before[0].modifiedNanos)
    for url in [file, destination.appendingPathComponent("payload.bin")] {
        var value = [UInt8](repeating: 0, count: marker.count)
        let count = value.withUnsafeMutableBytes { buffer in
            url.withUnsafeFileSystemRepresentation { getxattr($0!, attribute, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW) }
        }
        #expect(count == marker.count)
        #expect(Data(value) == marker)
    }
    let observed = try await operations.observeSelection([file])
    for target in [destination, emptyDestination] {
        let refused = await operations.perform(.moveObserved(selection: observed, destinationDirectory: target))
        #expect(refused.items.map(\.status) == [.failed(.crossVolumeMoveUnsupported)])
        #expect(refused.items.allSatisfy { $0.recoveryURLs.isEmpty })
    }
    #expect(try relatives.map { try CrossVolumeMetadata(source.appendingPathComponent($0)) } == before)
    #expect(try Data(contentsOf: file) == bytes)
    #expect(try Data(contentsOf: bundleChild) == bundleBytes)
    #expect(try FileManager().destinationOfSymbolicLink(atPath: link.path) == "payload.bin")
    #expect(try Data(contentsOf: destination.appendingPathComponent("payload.bin")) == bytes)
    #expect(try FileManager().contentsOfDirectory(atPath: emptyDestination.path).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1",
               "Real recoverable moves require marked two-volume fixtures."))
func actualCrossVolumeRecoverableMoveValidatesBytesMetadataAndRestoresSourceOnUndo() async throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let base = package.appendingPathComponent(".build/test-fixtures")
    guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
    try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
    let id = UUID()
    let local = try OwnedCrossVolumeRoot(parent: base, uuid: id)
    let remote = try OwnedCrossVolumeRoot(parent: URL(fileURLWithPath: "/private/tmp", isDirectory: true), uuid: id)
    defer {
        do { try local.remove(); try remote.remove() }
        catch { Issue.record("Owned recoverable two-volume fixture retained after cleanup refusal.") }
    }
    try #require(local.identity.device != remote.identity.device)
    let folder = local.url.appendingPathComponent("folder")
    try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
    let file = folder.appendingPathComponent("payload")
    let bytes = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0) })
    try bytes.write(to: file, options: .withoutOverwriting)
    try FileManager().setAttributes([.posixPermissions: 0o640, .modificationDate: Date(timeIntervalSince1970: 1_700_001_234)], ofItemAtPath: file.path)
    let xattr = Data("owned metadata".utf8)
    try #require(xattr.withUnsafeBytes { setxattr(file.path, "com.macexplorer.recovery-fixture", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) } == 0)
    try FileManager().createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "payload")
    let original = try verifiedTree(folder, cancellation: OperationCancellation())
    let service = RecoverableFileOperations(journalDirectory: local.url.appendingPathComponent("journal"))
    let copied = await service.perform(.move(sources: [folder], destinationDirectory: remote.url))
    #expect(copied.result.items.map(\.status) == [.succeeded])
    let target = remote.url.appendingPathComponent("folder")
    #expect(!FileManager().fileExists(atPath: folder.path))
    #expect(try verifiedTree(target, cancellation: OperationCancellation()).digest == original.digest)
    #expect(try Data(contentsOf: target.appendingPathComponent("payload")) == bytes)
    let record = try #require(try await service.recoveryRecords().records.first)
    #expect(record.locations.contains { $0.deletingLastPathComponent() == local.url && $0.lastPathComponent.hasPrefix(".mac-explorer-recovery-") })
    #expect(await service.undo(recordID: try #require(copied.recordID)).result.disposition == .succeeded)
    #expect(original.matches(try verifiedTree(folder, cancellation: OperationCancellation())))
    #expect(!FileManager().fileExists(atPath: target.path))
    #expect(try Data(contentsOf: file) == bytes)
    // Nested directory merges retire containers after child backups. Undo must inspect
    // those temporarily relocated descendants, restore containers first, then children.
    let nested = folder.appendingPathComponent("nested")
    try FileManager().createDirectory(at: nested, withIntermediateDirectories: false)
    try Data("nested body".utf8).write(to: nested.appendingPathComponent("child"), options: .withoutOverwriting)
    try FileManager().createDirectory(at: target.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try Data("untouched sibling".utf8).write(to: target.appendingPathComponent("untouched"), options: .withoutOverwriting)
    let merge = try await service.prepareTransfer(sources: [folder], destinationDirectory: remote.url, move: true)
    let choices = Dictionary(uniqueKeysWithValues: merge.conflicts.map { ($0.id, TransferConflictResolution.merge) })
    let merged = await service.perform(merge, resolutions: choices)
    #expect(merged.result.disposition == .succeeded)
    #expect(!FileManager().fileExists(atPath: folder.path))
    #expect(try Data(contentsOf: target.appendingPathComponent("payload")) == bytes)
    #expect(await service.undo(recordID: try #require(merged.recordID)).result.disposition == .succeeded)
    #expect(try Data(contentsOf: file) == bytes)
    #expect(try String(contentsOf: nested.appendingPathComponent("child"), encoding: .utf8) == "nested body")
    #expect(try String(contentsOf: target.appendingPathComponent("untouched"), encoding: .utf8) == "untouched sibling")
    #expect(!FileManager().fileExists(atPath: target.appendingPathComponent("payload").path))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1",
               "Move/Undo/cleanup requires explicitly enabled marked two-volume fixtures."))
func actualCrossVolumeMoveUndoCleansOnlyVerifiedRecoveryAreasOnTheirVolumes() async throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let base = package.appendingPathComponent(".build/test-fixtures")
    guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
    try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
    let id = UUID()
    let local = try OwnedCrossVolumeRoot(parent: base, uuid: id)
    defer {
        do { try local.remove() }
        catch { Issue.record("Owned repository Move/Undo/cleanup fixture retained after cleanup refusal.") }
    }
    let temporary = try OwnedCrossVolumeRoot(parent: URL(fileURLWithPath: "/private/tmp", isDirectory: true), uuid: id)
    defer {
        do { try temporary.remove() }
        catch { Issue.record("Owned temporary Move/Undo/cleanup fixture retained after cleanup refusal.") }
    }
    try #require(local.identity.device != temporary.identity.device)
    let source = temporary.url.appendingPathComponent("source-tree")
    let localTrash = local.url.appendingPathComponent("fixture-trash")
    let temporaryTrash = temporary.url.appendingPathComponent("fixture-trash")
    for directory in [source, localTrash, temporaryTrash] {
        try FileManager().createDirectory(at: directory, withIntermediateDirectories: false)
    }
    let body = Data("owned cross-volume staging cleanup fixture".utf8)
    try body.write(to: source.appendingPathComponent("body"), options: .withoutOverwriting)
    try FileManager().createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "body")
    // /private/tmp inherits a group the current process may not be able to preserve
    // on Workspace. This success-path fixture explicitly uses its own effective
    // group; production must still refuse any metadata it cannot reproduce.
    for url in [source, source.appendingPathComponent("body"), source.appendingPathComponent("link")] {
        try #require(lchown(url.path, uid_t.max, getegid()) == 0)
    }
    let original = try verifiedTree(source, cancellation: OperationCancellation())
    let localRoot = local.url, temporaryRoot = temporary.url
    let legacy = LocalFileOperations(trash: { area in
        let targetDirectory: URL
        if area.deletingLastPathComponent().path == localRoot.path { targetDirectory = localTrash }
        else if area.deletingLastPathComponent().path == temporaryRoot.path { targetDirectory = temporaryTrash }
        else { throw FileOperationFailure.invalidRequest }
        guard area.lastPathComponent.hasPrefix(".mac-explorer-recovery-"),
              UUID(uuidString: String(area.lastPathComponent.dropFirst(".mac-explorer-recovery-".count))) != nil else {
            throw FileOperationFailure.invalidRequest
        }
        let from = try DirectoryAnchor(area.deletingLastPathComponent(), resolve: false)
        let to = try DirectoryAnchor(targetDirectory, resolve: false)
        guard from.identity.device == to.identity.device else { throw FileOperationFailure.invalidRequest }
        try exclusiveRename(from: from.fd, name: area.lastPathComponent, to: to.fd, name: area.lastPathComponent)
        return targetDirectory.appendingPathComponent(area.lastPathComponent)
    })
    let journalURL = local.url.appendingPathComponent("journal")
    let service = RecoverableFileOperations(journalDirectory: journalURL, hooks: RecoveryHooks(), legacy: legacy)
    let moved = await service.perform(.move(sources: [source], destinationDirectory: local.url))
    let diagnosticRecord = try moved.recordID.flatMap { try OperationJournal(journalURL).inspectRecord($0) }
    var boundaryChecks = ""
    if moved.result.disposition != .succeeded, let area = diagnosticRecord?.areas.first {
        let staged = area.url.appendingPathComponent("payload")
        boundaryChecks = "; sourceMatches=\(original.matches(try verifiedTree(source, cancellation: OperationCancellation())))"
        for relative in ["", "body", "link"] {
            let a = relative.isEmpty ? source : source.appendingPathComponent(relative)
            let b = relative.isEmpty ? staged : staged.appendingPathComponent(relative)
            if let actual = try? verifiedTree(b, cancellation: OperationCancellation()) {
                let expected = try verifiedTree(a, cancellation: OperationCancellation())
                var aStat = stat(), bStat = stat()
                try #require(lstat(a.path, &aStat) == 0 && lstat(b.path, &bStat) == 0)
                boundaryChecks += "; uidMatches=\(aStat.st_uid == bStat.st_uid),gidMatches=\(aStat.st_gid == bStat.st_gid),flagsMatches=\(aStat.st_flags == bStat.st_flags)"
                boundaryChecks += "; node=\(relative.isEmpty ? "root" : relative),digestMatches=\(actual.digest == expected.digest),modeMatches=\(actual.identity.mode == expected.identity.mode),mtimeMatches=\(actual.identity.modifiedSeconds == expected.identity.modifiedSeconds && actual.identity.modifiedNanos == expected.identity.modifiedNanos)"
            } else { boundaryChecks += "; node=\(relative.isEmpty ? "root" : relative),unavailable" }
        }
    }
    let diagnostic = "statuses=\(moved.result.items.map { String(describing: $0.status) }.joined(separator: ",")); state=\(diagnosticRecord?.state ?? "no-record"); stage=\(diagnosticRecord?.failureStage ?? "none"); steps=\(diagnosticRecord?.steps.count ?? 0); seals=\(diagnosticRecord?.areas.filter { $0.stagingProof != nil }.count ?? 0)\(boundaryChecks)"
    try #require(moved.result.disposition == .succeeded, Comment(rawValue: diagnostic))
    let jobID = try #require(moved.recordID)
    let published = local.url.appendingPathComponent(source.lastPathComponent)
    #expect(!FileManager().fileExists(atPath: source.path))
    #expect(try verifiedTree(published, cancellation: OperationCancellation()).digest == original.digest)
    try #require(await service.undo(recordID: jobID).result.disposition == .succeeded)
    #expect(original.matches(try verifiedTree(source, cancellation: OperationCancellation())))
    #expect(!FileManager().fileExists(atPath: published.path))
    let inspected = try await service.retentionRecord(recordID: jobID)
    try #require(inspected.canCleanup)
    #expect(inspected.areas.count == 2)
    #expect(try Set(inspected.areas.map { try DirectoryAnchor($0.url, resolve: false).identity.device }).count == 2)
    try #require(await service.cleanupRecovery(recordID: jobID).result.disposition == .succeeded)
    #expect(original.matches(try verifiedTree(source, cancellation: OperationCancellation())))
    #expect(!FileManager().fileExists(atPath: published.path))
    #expect(try Data(contentsOf: source.appendingPathComponent("body")) == body)
    #expect(try FileManager().contentsOfDirectory(atPath: localTrash.path).count == 1)
    #expect(try FileManager().contentsOfDirectory(atPath: temporaryTrash.path).count == 1)
    #expect(try OperationJournal(journalURL).inspectRecord(jobID)?.state == "cleaned")
}
