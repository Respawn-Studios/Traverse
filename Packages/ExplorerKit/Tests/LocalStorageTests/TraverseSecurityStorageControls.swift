#if DEBUG
// This opt-in suite uses Debug-only fault-injection hooks. Production behavior
// remains covered by the ordinary LocalStorage tests in both configurations.
import CryptoKit
import Darwin
import ExplorerCore
import FileOperations
import Foundation
import Testing
@_spi(Qualification) @testable import LocalStorage

/// Existing document/browser actors with a generated in-process Save peer.
/// The peer acknowledges the strict local five-step record without network IO.
private actor RepeatedInPlaceSavePeer: SFTPDirectoryTransport {
    nonisolated let allowsInPlaceEditing = true
    nonisolated let allowsRequestedDownloads: Bool
    nonisolated let allowsRequestedFolderDownloads: Bool
    private(set) var saves = 0
    private var attempts = 0
    private let conflictOnAttempt: Int?
    private let openedBaseline: SFTPInPlaceBaseline?
    private var generation = UUID()
    init(conflictOnAttempt: Int? = nil, openedBaseline: SFTPInPlaceBaseline? = nil) {
        self.conflictOnAttempt = conflictOnAttempt; self.openedBaseline = openedBaseline
        allowsRequestedDownloads = openedBaseline != nil
        allowsRequestedFolderDownloads = openedBaseline != nil
    }

    func readInPlace(_ selection: SFTPDownloadSelection, snapshot: SFTPStoredSnapshot,
        storage: SFTPInPlaceWorkingCopyStorage) async throws -> SFTPInPlaceBaseline {
        guard let openedBaseline, selection.generation == generation,
              snapshot.state == .complete else { throw SFTPBrowserFailure.stale }
        return openedBaseline
    }

    func saveInPlace(_ baseline: SFTPInPlaceBaseline, snapshot: SFTPEditedTextSnapshot,
        journal: SFTPInPlaceJournal) async throws -> SFTPInPlaceSaveCompletion {
        attempts += 1
        let conflict = attempts == conflictOnAttempt
        let attempt = try await SFTPInPlaceAttempt.prepare(baseline: baseline, snapshot: snapshot,
            session: baseline.session, context: baseline.context, journal: journal,
            revision: try await journal.inspect().revision)
        _ = try attempt.command()
        var source = SFTPWire.token(attempt.record.id)
        SFTPWire.number(0, bytes: 8, into: &source)
        SFTPWire.number(attempt.record.edited.logicalBytes, bytes: 4, into: &source)
        _ = try attempt.sourceOnSessionExecutor(source)
        let plan = try attempt.record.plan
        for step in plan {
            var request = SFTPWire.token(attempt.record.id)
            step.append(to: &request); request.append(attempt.record.edited.digest)
            _ = try attempt.permitOnSessionExecutor(request)
            var observed = SFTPWire.token(attempt.record.id)
            step.append(to: &observed)
            try attempt.observedOnSessionExecutor(observed)
            if conflict && step.kind == .source {
                var failed = SFTPWire.token(attempt.record.id)
                failed.append(SFTPInPlaceFailurePhase.source.rawValue)
                failed.append(1); failed.append(1)
                failed.append(SFTPInPlaceFailureCause.conflict.rawValue)
                SFTPWire.number(0, bytes: 4, into: &failed)
                let interruption = try attempt.interruptedOnSessionExecutor(failed)
                await attempt.finishLocalAfterOperationReturned()
                throw interruption
            }
        }
        var completed = SFTPWire.token(attempt.record.id)
        completed.append(SFTPWire.token(attempt.record.editorGeneration))
        completed.append(SFTPWire.token(UUID()))
        SFTPWire.number(attempt.record.baselineRevision + 1, bytes: 8, into: &completed)
        SFTPWire.number(attempt.record.edited.logicalBytes, bytes: 8, into: &completed)
        completed.append(attempt.record.edited.digest)
        SFTPWire.number(attempt.record.edited.logicalBytes, bytes: 8, into: &completed)
        SFTPWire.number(UInt64(attempt.record.baselineModified + 1), bytes: 4, into: &completed)
        for value in [attempt.record.mode, attempt.record.uid, attempt.record.gid] {
            SFTPWire.number(UInt64(value), bytes: 4, into: &completed)
        }
        completed.append(UInt8(plan.count)); completed.append(UInt8(plan.count))
        completed.append(contentsOf: [1, 1, 1, 1])
        try attempt.completedOnSessionExecutor(completed)
        await attempt.finishLocalAfterOperationReturned()
        let next = try await attempt.continuationAfterLocalDrain()
        saves += 1
        return .continued(next, attempt.record.id)
    }

    func openStoredDirectory(_ path: String) async throws -> (UUID, SFTPStoredSnapshot) {
        guard openedBaseline != nil else { throw SFTPBrowserFailure.unavailable }
        generation = UUID()
        return (generation, .init(read: 1, revision: 1, count: 1, folders: 0, state: .complete))
    }
    func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot { throw SFTPBrowserFailure.unavailable }
    func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64,
        sort: SFTPStoredSort, descending: Bool) async throws -> SFTPStoredPage? { throw SFTPBrowserFailure.unavailable }
    func close() async -> SFTPWorkerClose {
        .init(actualExit: true, exitStatus: 0, ipcEOF: true, contained: false,
            protocolValid: true, terminal: nil, temporaryStoreRemoved: true)
    }
}

/// These controls only run inside an exact, worktree-owned generated case.
/// They feed local bytes through the real read and Save owners; no SSH peer is
/// contacted and no caller-created path is treated as editor authority.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_SECURITY_STORAGE_ROOT"] != nil))
struct TraverseSecurityStorageControls {
    private enum Failure: Error, Sendable { case scope, assertion(Int), injected }

    @Test func heldPublicDownloadsKeepPrivateEditorOpenAndSave() async throws {
        let fixture = try await Fixture.ready(in: Self.caseRoot("held-download-editor"))
        _ = await fixture.snapshot.closeAndDrain()
        let peer = RepeatedInPlaceSavePeer(openedBaseline: fixture.baseline)
        let browser = SFTPBrowserSession(id: fixture.baseline.session, transport: peer,
                                         exposedDownloads: false, exposedFolderDownloads: false)
        try Self.require(!browser.allowsRequestedDownloads && !browser.allowsRequestedFolderDownloads
                         && browser.allowsInPlaceEditing)
        let generation = try await browser.navigate(pathUTF8: Data(".".utf8))
        let selection = try SFTPDownloadSelection(generation: generation, row: .init(observation: 1,
            entry: .init(name: SFTPRemoteName(Data("file.txt".utf8)), logicalBytes: 7,
                modifiedSeconds: 77, permissions: 0o100600)))
        let document = try await browser.openInPlaceText(selection, storage: fixture.storage)
        guard case .saved = await document.save(contents: try TextDocumentValue.original(Data("after\n".utf8)),
                                               generation: UUID()) else { throw Failure.assertion(#line) }
        try Self.require(await peer.saves == 1)
        _ = await document.closeAfterExplicitBufferDecision()
        _ = await browser.close()
        _ = await Task.detached { fixture.metadata.finish(clean: false) }.value
        await fixture.drain()
    }

    private final class RemovalGate: @unchecked Sendable {
        private let lock = NSLock()
        private var intentCommitted = false
        let target: SFTPRetainedRemovalStage
        init(_ target: SFTPRetainedRemovalStage) { self.target = target }
        func reach(_ stage: SFTPRetainedRemovalStage) throws {
            try lock.withLock {
                if stage == .intentCommitted { intentCommitted = true }
                if intentCommitted && stage == target { throw Failure.injected }
            }
        }
    }

    private static func require(_ condition: Bool, line: Int = #line) throws {
        if !condition { throw Failure.assertion(line) }
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func caseRoot(_ name: String) throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["TRAVERSE_SECURITY_STORAGE_ROOT"] else { throw Failure.scope }
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        let expected = repoRoot().appendingPathComponent(".build/traverse-security-review", isDirectory: true)
        guard root == root.standardizedFileURL, root.deletingLastPathComponent() == expected,
              root.lastPathComponent.hasPrefix("storage-controls-"),
              UUID(uuidString: String(root.lastPathComponent.dropFirst("storage-controls-".count))) != nil,
              root.resolvingSymlinksInPath() == root else { throw Failure.scope }
        var facts = stat()
        guard lstat(root.path, &facts) == 0, facts.st_uid == geteuid(),
              facts.st_mode & S_IFMT == S_IFDIR, facts.st_mode & 0o7777 == 0o700 else { throw Failure.scope }
        let child = root.appendingPathComponent(name, isDirectory: true)
        guard mkdir(child.path, 0o700) == 0 else { throw Failure.scope }
        return child
    }

    private static func context() throws -> SFTPVerifiedSessionContext {
        var key = Data()
        try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key)
        try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        return .init(host: "generated.example", port: 22, requestedScopeID: 0,
            account: "generated", key: try .init(key), previous: nil, permitsRememberingHost: false)
    }

    private static func layout(in root: URL) throws -> ApplicationStorageLayout {
        try ApplicationStorageLayout(applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            caches: root.appendingPathComponent("Cache", isDirectory: true), bundleIdentifier: "generated.security-storage")
    }

    private static func existingCaseRoot(_ name: String) throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["TRAVERSE_SECURITY_STORAGE_ROOT"] else { throw Failure.scope }
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        let child = root.appendingPathComponent(name, isDirectory: true)
        guard child.deletingLastPathComponent() == root, child.resolvingSymlinksInPath() == child else { throw Failure.scope }
        var facts = stat()
        guard lstat(child.path, &facts) == 0, facts.st_uid == geteuid(),
              facts.st_mode & S_IFMT == S_IFDIR, facts.st_mode & 0o7777 == 0o700 else { throw Failure.scope }
        return child
    }

    private static func mark(_ path: URL) throws {
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.scope }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Failure.scope }
    }

    private static func waitForMarker(_ path: URL, seconds: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var facts = stat()
            if lstat(path.path, &facts) == 0 {
                try require(DownloadDisk.privateFile(facts) && facts.st_size == 0)
                return
            }
            guard errno == ENOENT else { throw Failure.scope }
            usleep(20_000)
        }
        throw Failure.assertion(#line)
    }

    private static func generatedInventory(_ root: URL) throws -> [String: String] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { throw Failure.scope }
        var result: [String: String] = [:]
        for case let path as URL in files {
            guard result.count < 256, path.path.hasPrefix(root.path + "/") else { throw Failure.scope }
            var facts = stat()
            guard lstat(path.path, &facts) == 0, facts.st_uid == geteuid(),
                  facts.st_mode & S_IFMT == S_IFDIR || facts.st_mode & S_IFMT == S_IFREG else { throw Failure.scope }
            let digest: String
            if facts.st_mode & S_IFMT == S_IFREG {
                guard facts.st_size <= 1 << 20 else { throw Failure.scope }
                digest = SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
            } else { digest = "directory" }
            let relative = String(path.path.dropFirst(root.path.count + 1))
            result[relative] = "\(facts.st_dev):\(facts.st_ino):\(facts.st_mode):\(facts.st_size):\(facts.st_mtimespec.tv_sec):\(facts.st_mtimespec.tv_nsec):\(facts.st_ctimespec.tv_sec):\(facts.st_ctimespec.tv_nsec):\(digest)"
        }
        return result
    }

    private static func child(_ mode: String, _ name: String) throws -> Process {
        guard let raw = ProcessInfo.processInfo.environment["TRAVERSE_SECURITY_CONTROL_EXECUTABLE"] else { throw Failure.scope }
        let caseDirectory = try existingCaseRoot(name)
        let owned = caseDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let executable = URL(fileURLWithPath: raw)
        guard executable == executable.standardizedFileURL, executable.resolvingSymlinksInPath() == executable,
              executable.path.hasPrefix(owned.path + "/")
        else { throw Failure.scope }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--security-child", mode, name]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = FileHandle.nullDevice
        let log = caseDirectory.appendingPathComponent("child-" + mode + ".log")
        let descriptor = open(log.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.scope }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        process.standardError = output
        do { try process.run() } catch { try? output.close(); throw error }
        try? output.close()
        return process
    }

    private static func waitFor(_ process: Process, ready: URL? = nil) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let ready {
                var facts = stat()
                if lstat(ready.path, &facts) == 0 {
                    try require(process.isRunning && facts.st_mode & S_IFMT == S_IFREG && facts.st_uid == geteuid())
                    return
                }
            } else if !process.isRunning { return }
            if !process.isRunning { throw Failure.assertion(#line) }
            try await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        throw Failure.assertion(#line)
    }

    private final class Fixture: @unchecked Sendable {
        let workspace: ConnectionWorkspace, layout: ApplicationStorageLayout
        let baseline: SFTPInPlaceBaseline, snapshot: SFTPEditedTextSnapshot
        let metadata: SMBCatalogFiles, storage: SFTPInPlaceWorkingCopyStorage

        private init(workspace: ConnectionWorkspace, layout: ApplicationStorageLayout,
            baseline: SFTPInPlaceBaseline, snapshot: SFTPEditedTextSnapshot,
            metadata: SMBCatalogFiles, storage: SFTPInPlaceWorkingCopyStorage) {
            self.workspace = workspace; self.layout = layout; self.baseline = baseline
            self.snapshot = snapshot; self.metadata = metadata; self.storage = storage
        }

        static func ready(in root: URL) async throws -> Fixture {
            let layout = try TraverseSecurityStorageControls.layout(in: root)
            let workspace = try ConnectionWorkspace(layout: layout)
            let configuration = try await workspace.prepareForConnect().metadataStorage
            let session = UUID(), context = try TraverseSecurityStorageControls.context()
            let metadata = try await Task.detached {
                try SMBCatalogFiles(storage: configuration, purpose: .originalPending(session: session))
            }.value
            let owner = try await Task.detached {
                try SFTPOriginalStorageOwner.bindOnMetadataExecutor(files: metadata, session: session, context: context)
            }.value
            let storage = try SFTPInPlaceWorkingCopyStorage(metadataStorage: configuration, catalogProbe: nil, journalProbe: nil)
            let generation = UUID()
            let selection = try SFTPDownloadSelection(generation: generation, row: .init(observation: 1,
                entry: .init(name: SFTPRemoteName(Data("file.txt".utf8)), logicalBytes: 7,
                    modifiedSeconds: 77, permissions: 0o100600)))
            let job = try SFTPOriginalReadJob(session: session, selection: selection, context: context,
                directory: storage.layout.bodies, catalog: storage.catalog, storageOwner: owner, strategy: .inPlaceV1)
            _ = try await job.beginCommand(catalogRevision: 1)
            var header = SFTPWire.token(selection.request); header.append(SFTPWire.token(generation))
            for (value, bytes) in [(UInt64(7), 8), (77, 4), (0o100600, 4), (UInt64(getuid()), 4), (UInt64(getgid()), 4)] {
                SFTPWire.number(value, bytes: bytes, into: &header)
            }
            try SFTPWire.field(Data("/generated/file.txt".utf8), into: &header)
            try await job.header(header)
            var chunk = SFTPWire.token(selection.request); SFTPWire.number(0, bytes: 8, into: &chunk)
            try SFTPWire.field(Data("before\n".utf8), into: &chunk); try await job.chunk(chunk)
            let digest = Data(SHA256.hash(data: Data("before\n".utf8)))
            var seal = SFTPWire.token(selection.request); seal.append(digest); SFTPWire.number(7, bytes: 8, into: &seal)
            _ = try await job.acceptance(seal)
            var admission = SFTPWire.token(selection.request); admission.append(SFTPWire.token(UUID()))
            SFTPWire.number(1, bytes: 8, into: &admission); admission.append(digest); admission.append(contentsOf: [1, 1, 1])
            let baseline = try await job.admittedInPlace(admission)
            let snapshot = try await storage.edits.stageInPlace(contents: TextDocumentValue.original(Data("after\n".utf8)),
                editorGeneration: UUID(), from: baseline)
            return Fixture(workspace: workspace, layout: layout, baseline: baseline,
                snapshot: snapshot, metadata: metadata, storage: storage)
        }

        static func retained(in root: URL) async throws -> Fixture {
            let fixture = try await ready(in: root)
            let baseline = fixture.baseline, snapshot = fixture.snapshot, storage = fixture.storage
            let attempt = try await SFTPInPlaceAttempt.prepare(baseline: baseline, snapshot: snapshot,
                session: baseline.session, context: baseline.context, journal: storage.journal,
                revision: try await storage.journal.inspect().revision)
            _ = try attempt.command()
            var source = SFTPWire.token(attempt.record.id); SFTPWire.number(0, bytes: 8, into: &source)
            SFTPWire.number(6, bytes: 4, into: &source); _ = try attempt.sourceOnSessionExecutor(source)
            for step in try attempt.record.plan.prefix(2) {
                var request = SFTPWire.token(attempt.record.id); step.append(to: &request)
                request.append(attempt.record.edited.digest)
                _ = try attempt.permitOnSessionExecutor(request)
                if step.kind == .source {
                    var observation = SFTPWire.token(attempt.record.id); step.append(to: &observation)
                    try attempt.observedOnSessionExecutor(observation)
                }
            }
            await attempt.finishLocalAfterOperationReturned()
            _ = await snapshot.closeAndDrain()
            _ = await Task.detached { fixture.metadata.finish(clean: false) }.value
            return fixture
        }

        func releasePin() async throws { try TraverseSecurityStorageControls.require(await baseline.lifetimePin.closeAndDrain()) }
        func drain() async { await workspace.stopAndDrain(); _ = await baseline.lifetimePin.closeAndDrain() }
    }

    private static func closedV3SFTPFixture(in root: URL) async throws ->
        (ApplicationStorageLayout, [String: ConnectionWorkspaceIdentity], [String: String], [String: String]) {
        let fixture = try await Fixture.retained(in: root)
        do {
            try await fixture.releasePin()
            let paths = ConnectionWorkspacePaths(fixture.layout)
            let oldGraph = try ConnectionWorkspaceDisk.graphIdentity(paths, stable: true)
            try Self.require(Set(oldGraph.keys) == ConnectionWorkspaceDisk.graphKeys)
            let oldBodies = try Self.generatedInventory(fixture.storage.layout.bodies)
            let oldJournal = try Self.generatedInventory(fixture.storage.layout.journal)
            try Self.require(oldBodies.keys.contains { $0.hasPrefix("download-") })
            try Self.require(oldJournal["servers.json"] != nil)
            await fixture.drain()
            return (fixture.layout, oldGraph, oldBodies, oldJournal)
        } catch { await fixture.drain(); throw error }
    }

    @Test func nonemptyV3SFTPVersionsRemainColdReadableAfterSMBV4Upgrade() async throws {
        let (layout, oldGraph, oldBodies, oldJournal) = try await Self.closedV3SFTPFixture(
            in: Self.caseRoot("sftp-v3-to-smb-v4"))
        let workspace = try ConnectionWorkspace(layout: layout)
        let paths = ConnectionWorkspacePaths(layout)
        let bodies = layout.persistentConnectionWorkspaceDirectory.appendingPathExtension("original-bodies")
        let journal = bodies.appendingPathExtension("original-journal")
        do {
            let admission = try await workspace.prepareSMBInPlaceEdits()
            try Self.require(admission.metadataStorage.workspaceWitness?.record.format == 4)
            let upgradedGraph = try ConnectionWorkspaceDisk.graphIdentity(paths, stable: true, includingSMB: true)
            try Self.require(Set(upgradedGraph.keys) == ConnectionWorkspaceDisk.smbGraphKeys)
            for (name, identity) in oldGraph {
                try Self.require(upgradedGraph[name] == identity)
            }
        } catch { await workspace.stopAndDrain(); throw error }
        await workspace.stopAndDrain()

        let cold = try ConnectionWorkspace(layout: layout)
        do {
            let reconnected = try await cold.prepareForConnect()
            try Self.require(reconnected.metadataStorage.workspaceWitness?.record.format == 4)
            let choices = try await cold.recoveryChoicesAfterExplicitRequest()
            try Self.require(choices.count == 1 && choices[0].availableVersions == [.before, .edited])
            try Self.require(try await choices[0].readVersion(.before).encoded == Data("before\n".utf8))
            try Self.require(try await choices[0].readVersion(.edited).encoded == Data("after\n".utf8))
            try Self.require(try Self.generatedInventory(bodies) == oldBodies)
            try Self.require(try Self.generatedInventory(journal) == oldJournal)
        } catch { await cold.stopAndDrain(); throw error }
        await cold.stopAndDrain()
    }

    @Test func pendingSMBV4UpgradeResumesWithoutChangingV3SFTPVersions() async throws {
        let (layout, oldGraph, oldBodies, oldJournal) = try await Self.closedV3SFTPFixture(
            in: Self.caseRoot("sftp-v3-pending-smb-v4"))
        let paths = ConnectionWorkspacePaths(layout)
        try await Task.detached {
            guard let file = try ConnectionWorkspaceDisk.File.open(paths.record, writing: true,
                existingOnly: true, probe: { stage in
                    if stage == .beforeRename { throw Failure.injected }
                }) else { throw Failure.assertion(#line) }
            defer { file.close() }
            do {
                _ = try ConnectionWorkspaceSMBUpgradeDisk.prepare(paths, file: file)
                throw Failure.assertion(#line)
            } catch Failure.injected { }
        }.value

        let workspace = try ConnectionWorkspace(layout: layout)
        let bodies = layout.persistentConnectionWorkspaceDirectory.appendingPathExtension("original-bodies")
        let journal = bodies.appendingPathExtension("original-journal")
        do {
            let choice = try await workspace.smbInPlaceUpgradeChoiceAfterExplicitRequest()
            try Self.require(choice.action == .resumePending)
            let admission = try await workspace.resumeSMBInPlaceUpgrade(choice)
            try Self.require(admission.metadataStorage.workspaceWitness?.record.format == 4)
            let upgradedGraph = try ConnectionWorkspaceDisk.graphIdentity(paths, stable: true, includingSMB: true)
            for (name, identity) in oldGraph { try Self.require(upgradedGraph[name] == identity) }
        } catch { await workspace.stopAndDrain(); throw error }
        await workspace.stopAndDrain()

        let cold = try ConnectionWorkspace(layout: layout)
        do {
            let versions = try await cold.recoveryChoicesAfterExplicitRequest()
            try Self.require(versions.count == 1 && versions[0].availableVersions == [.before, .edited])
            try Self.require(try await versions[0].readVersion(.before).encoded == Data("before\n".utf8))
            try Self.require(try await versions[0].readVersion(.edited).encoded == Data("after\n".utf8))
            try Self.require(try Self.generatedInventory(bodies) == oldBodies)
            try Self.require(try Self.generatedInventory(journal) == oldJournal)
        } catch { await cold.stopAndDrain(); throw error }
        await cold.stopAndDrain()
    }

    /// Exercise the real Open constructor's post-marker interruption. The
    /// generated payload length models later crashes before the budget's
    /// allocating-to-allocated commit; no payload bytes are used by discovery.
    private static func interruptedReceive(in root: URL, payloadBytes: Int,
        duplicateReceivingEditor: Bool = false) async throws -> SFTPSharedBudgetLayout {
        try require((0...7).contains(payloadBytes))
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        let configuration = try await workspace.prepareForConnect().metadataStorage
        let session = UUID(), context = try Self.context()
        let metadata = try await Task.detached {
            try SMBCatalogFiles(storage: configuration, purpose: .originalPending(session: session))
        }.value
        let owner = try await Task.detached {
            try SFTPOriginalStorageOwner.bindOnMetadataExecutor(files: metadata, session: session, context: context)
        }.value
        let storage = try SFTPInPlaceWorkingCopyStorage(metadataStorage: configuration, catalogProbe: nil, journalProbe: nil)
        let generation = UUID()
        let selection = try SFTPDownloadSelection(generation: generation, row: .init(observation: 1,
            entry: .init(name: SFTPRemoteName(Data("file.txt".utf8)), logicalBytes: 7,
                modifiedSeconds: 77, permissions: 0o100600)))
        let job = try SFTPOriginalReadJob(session: session, selection: selection, context: context,
            directory: storage.layout.bodies, catalog: storage.catalog, storageOwner: owner, strategy: .inPlaceV1)
        _ = try await job.beginCommand(catalogRevision: 1)
        try await job.setHeaderPostMkdirFaultForQualification { throw Failure.injected }
        var header = SFTPWire.token(selection.request); header.append(SFTPWire.token(generation))
        for (value, bytes) in [(UInt64(7), 8), (77, 4), (0o100600, 4), (UInt64(getuid()), 4), (UInt64(getgid()), 4)] {
            SFTPWire.number(value, bytes: bytes, into: &header)
        }
        try SFTPWire.field(Data("/generated/file.txt".utf8), into: &header)
        do { try await job.header(header); throw Failure.assertion(#line) }
        catch Failure.injected { }
        if duplicateReceivingEditor {
            try await storage.catalog.begin(id: UUID(), session: session, request: UUID(),
                context: context, expectedBytes: 7)
        }
        let bodyID = try await Self.pendingBodyID(storage.layout, owner: owner.catalogID)
        let pool = try ConnectionWorkspaceDisk.openDirectory(storage.layout.bodies)
        let folder = openat(pool, "download-" + bodyID.uuidString, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard folder >= 0 else { Darwin.close(pool); throw Failure.assertion(#line) }
        let payload = openat(folder, "payload", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard payload >= 0 else { Darwin.close(folder); Darwin.close(pool); throw Failure.assertion(#line) }
        do {
            let url = storage.layout.bodies.appendingPathComponent("download-" + bodyID.uuidString, isDirectory: true)
                .appendingPathComponent("payload")
            _ = try DownloadedFileQuarantine.markFreshSpoolFile(payload, at: url)
            if payloadBytes > 0 { try DownloadDisk.writeAll(payload, Data(Data("before\n".utf8).prefix(payloadBytes))) }
            guard fsync(payload) == 0, fsync(folder) == 0 else { throw Failure.assertion(#line) }
        } catch {
            Darwin.close(payload); Darwin.close(folder); Darwin.close(pool); throw error
        }
        Darwin.close(payload); Darwin.close(folder); Darwin.close(pool)
        try require(await Task.detached { metadata.finish(clean: true) }.value)
        await workspace.stopAndDrain()
        return storage.layout
    }

    private static func pendingBodyID(_ shared: SFTPSharedBudgetLayout, owner: UUID? = nil) async throws -> UUID {
        try await Task.detached { [shared] in
            let transaction = try SFTPSharedBudgetTransaction.open(layout: shared, writing: false)
            defer { transaction.close() }
            let matches = transaction.document.bodies.filter { $0.phase == .allocating && (owner == nil || $0.owner == owner) }
            guard matches.count == 1, let charge = matches.first else {
                throw Failure.assertion(#line)
            }
            return charge.id
        }.value
    }

    @Test func interruptedReceiveDoesNotHideLaterSavedVersionsAndConflict() async throws {
        for bytes in [0, 3, 7] {
            let root = try Self.caseRoot("mixed-receive-\(bytes)")
            let shared = try await Self.interruptedReceive(in: root, payloadBytes: bytes)
            let fixture = try await Fixture.ready(in: root)
            _ = await fixture.snapshot.closeAndDrain()
            let peer = RepeatedInPlaceSavePeer(conflictOnAttempt: 2)
            let browser = SFTPBrowserSession(id: fixture.baseline.session, transport: peer)
            let document = SFTPInPlaceDocumentSession(browser: browser, baseline: fixture.baseline, storage: fixture.storage)
            let first = await document.save(contents: try TextDocumentValue.original(Data("after one\n".utf8)), generation: UUID())
            guard case .saved = first else { throw Failure.assertion(#line) }
            let second = await document.save(contents: try TextDocumentValue.original(Data("after two\n".utf8)), generation: UUID())
            guard case .needsReview(let recordID, let facts) = second,
                  recordID != nil, facts?.cause == .conflict,
                  facts?.remoteBytesMayHaveChanged == false else { throw Failure.assertion(#line) }
            try Self.require(await peer.saves == 1)
            let closed = await document.closeAfterExplicitBufferDecision()
            guard case .disconnectedRecoveryRetained = closed else { throw Failure.assertion(#line) }
            _ = await Task.detached { fixture.metadata.finish(clean: false) }.value
            await fixture.drain()

            let cold = try ConnectionWorkspace(layout: fixture.layout)
            let before = try Self.generatedInventory(root)
            let listing = try await cold.recoveryListingAfterExplicitRequest()
            try Self.require(listing.incompleteReceiveCount == 1 && listing.choices.count == 2)
            try Self.require(listing.choices.contains { $0.outcome == .verified }
                && listing.choices.contains { $0.outcome == .notStarted })
            for choice in listing.choices {
                try Self.require(choice.availableVersions == [.before, .edited])
                let version = try await choice.readVersion(.before)
                try Self.require(version.encoded == Data("before\n".utf8) || version.encoded == Data("after one\n".utf8))
            }
            try Self.require(try Self.generatedInventory(root) == before)
            do { _ = try await cold.retainedDocumentsAfterExplicitRequest(); throw Failure.assertion(#line) }
            catch SFTPSharedBudgetFailure.recoveryRequired { }
            try Self.require(try Self.generatedInventory(root) == before)
            await cold.stopAndDrain()
            try Self.require(shared.bodies == fixture.storage.layout.bodies)
        }
    }

    @Test func ambiguousOrDanglingInterruptedReceiveStillRequiresReview() async throws {
        let ambiguous = try Self.caseRoot("ambiguous-receive")
        _ = try await Self.interruptedReceive(in: ambiguous, payloadBytes: 0, duplicateReceivingEditor: true)
        let ambiguousWorkspace = try ConnectionWorkspace(layout: Self.layout(in: ambiguous))
        let ambiguousBefore = try Self.generatedInventory(ambiguous)
        do { _ = try await ambiguousWorkspace.recoveryListingAfterExplicitRequest(); throw Failure.assertion(#line) }
        catch SFTPSharedBudgetFailure.recoveryRequired { }
        try Self.require(try Self.generatedInventory(ambiguous) == ambiguousBefore)
        let ambiguousAdmission = try await ambiguousWorkspace.prepareForConnect()
        do { try await ambiguousAdmission.metadataStorage.prepareSharedOriginalStorageForConnect(); throw Failure.assertion(#line) }
        catch SFTPSharedBudgetFailure.recoveryRequired { }
        try Self.require(try Self.generatedInventory(ambiguous) == ambiguousBefore)
        await ambiguousWorkspace.stopAndDrain()

        let dangling = try Self.caseRoot("dangling-receive")
        let shared = try await Self.interruptedReceive(in: dangling, payloadBytes: 0)
        let editor = try await Task.detached { [shared] in
            guard let file = try RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.open(shared.editors, writing: true) else {
                throw Failure.assertion(#line)
            }
            defer { file.close() }
            var next = file.snapshot; next.records.removeAll { $0.phase == .receiving }; next.revision += 1
            try file.commit(next)
            return next
        }.value
        try Self.require(editor.records.isEmpty)
        let danglingWorkspace = try ConnectionWorkspace(layout: Self.layout(in: dangling))
        let danglingBefore = try Self.generatedInventory(dangling)
        do { _ = try await danglingWorkspace.recoveryListingAfterExplicitRequest(); throw Failure.assertion(#line) }
        catch SFTPSharedBudgetFailure.recoveryRequired { }
        try Self.require(try Self.generatedInventory(dangling) == danglingBefore)
        await danglingWorkspace.stopAndDrain()
    }

    @Test func incompleteSiblingNeverAuthorizesRetainedDocumentRemoval() async throws {
        let root = try Self.caseRoot("incomplete-removal-refusal")
        let fixture = try await Fixture.retained(in: root)
        try await fixture.releasePin()
        let choices = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
        try Self.require(choices.count == 1)
        _ = try await Self.interruptedReceive(in: root, payloadBytes: 3)
        let before = try Self.generatedInventory(root)
        let listing = try await fixture.workspace.recoveryListingAfterExplicitRequest()
        try Self.require(listing.incompleteReceiveCount == 1 && listing.choices.count == 1)
        do { try await fixture.workspace.removeRetainedDocument(choices[0]); throw Failure.assertion(#line) }
        catch SFTPSharedBudgetFailure.recoveryRequired { }
        try Self.require(try Self.generatedInventory(root) == before)
        await fixture.drain()
    }

    @Test func sequentialVerifiedSavesReachTheExistingEightBodyLimitWithoutDroppingHistory() async throws {
        let fixture = try await Fixture.ready(in: Self.caseRoot("repeated-save"))
        _ = await fixture.snapshot.closeAndDrain()
        let peer = RepeatedInPlaceSavePeer()
        let browser = SFTPBrowserSession(id: fixture.baseline.session, transport: peer)
        let document = SFTPInPlaceDocumentSession(browser: browser, baseline: fixture.baseline, storage: fixture.storage)
        let generations = (0..<8).map { _ in UUID() }
        var contents = "before\n"
        var outcomes: [SFTPInPlaceSaveResult] = []
        for index in 0..<8 {
            contents += "edit \(index)\n"
            outcomes.append(await document.save(contents: try TextDocumentValue.original(Data(contents.utf8)),
                generation: generations[index]))
        }
        let savedRows = try await fixture.storage.journal.inspect().records.count
        let budget = try await fixture.storage.inspectBudgetSummary()
        let close = await document.closeAfterExplicitBufferDecision()
        _ = await browser.close()
        _ = await Task.detached { fixture.metadata.finish(clean: false) }.value
        await fixture.drain()
        var recordIDs = Set<UUID>()
        for index in 0..<7 {
            guard case .saved(let receipt) = outcomes[index] else { throw Failure.assertion(#line) }
            try Self.require(receipt.generation == generations[index])
            recordIDs.insert(receipt.recordID)
        }
        guard case .refusedBeforeSubmission(.stagingCapacity) = outcomes[7] else { throw Failure.assertion(#line) }
        try Self.require(recordIDs.count == 7 && savedRows == 7)
        try Self.require(budget?.heldBodies == 8 && budget?.pendingBodies == 0)
        try Self.require(await peer.saves == 7)
        try Self.require(close == .closedVersionsRetained)
    }

    @Test func explicitConnectRetiresOnlyDrainedMetadataAndKeepsEightBodiesForColdRecovery() async throws {
        let root = try Self.caseRoot("connect-storage-reconciliation")
        let fixture = try await Fixture.ready(in: root)
        _ = await fixture.snapshot.closeAndDrain()
        let peer = RepeatedInPlaceSavePeer()
        let browser = SFTPBrowserSession(id: fixture.baseline.session, transport: peer)
        let document = SFTPInPlaceDocumentSession(browser: browser, baseline: fixture.baseline, storage: fixture.storage)
        var contents = "before\n"
        for index in 0..<7 {
            contents += "edit \(index)\n"
            guard case .saved = await document.save(contents: try TextDocumentValue.original(Data(contents.utf8)),
                generation: UUID()) else { throw Failure.assertion(#line) }
        }
        try Self.require(await peer.saves == 7)
        try Self.require(await document.closeAfterExplicitBufferDecision() == .closedVersionsRetained)
        _ = await browser.close()
        try Self.require(!(await Task.detached { fixture.metadata.finish(clean: false) }.value))
        await fixture.drain()

        let cold = try ConnectionWorkspace(layout: fixture.layout)
        let configuration = try await cold.prepareForConnect().metadataStorage
        let context = try Self.context()
        for _ in 0..<2 {
            let session = UUID()
            let metadata = try await Task.detached {
                try SMBCatalogFiles(storage: configuration, purpose: .originalPending(session: session))
            }.value
            _ = try await Task.detached {
                try SFTPOriginalStorageOwner.bindOnMetadataExecutor(files: metadata, session: session, context: context)
            }.value
            try Self.require(!(await Task.detached { metadata.finish(clean: false) }.value))
        }
        let full = try await fixture.storage.inspectBudgetSummary()
        try Self.require(full?.owners == 3 && full?.heldBodies == 8 && full?.inactiveLiveOwners == 3
            && full!.reservedBytes > 1536 << 20)
        do {
            _ = try await Task.detached { try SMBCatalogFiles(storage: configuration) }.value
            throw Failure.assertion(#line)
        } catch SFTPSharedBudgetFailure.capacity { }
        let protected = try Self.generatedInventory(root).filter { $0.key.contains(".original-bodies") }
        try await configuration.prepareSharedOriginalStorageForConnect()
        let expanded = try await fixture.storage.inspectBudgetSummary()
        try Self.require(expanded?.owners == 0 && expanded?.heldBodies == 8
            && expanded!.reservedBytes < 32 << 20)
        try Self.require(try Self.generatedInventory(root).filter { $0.key.contains(".original-bodies") } == protected)
        let ledger = try await Task.detached { [shared = fixture.storage.layout] in
            let owner = try SFTPSharedBudgetTransaction.open(layout: shared, writing: false)
            defer { owner.close() }; return owner.document
        }.value
        try Self.require(ledger.format == 3 && ledger.metadata.count == 3
            && ledger.metadata.allSatisfy { $0.phase == .removed }
            && ledger.bodies.count == 8)
        let choices = try await cold.recoveryListingAfterExplicitRequest()
        try Self.require(choices.choices.count == 7 && choices.choices.allSatisfy { $0.outcome == .verified })
        let retained = try await cold.retainedDocumentsAfterExplicitRequest()
        try Self.require(retained.count == 1 && retained[0].copyCount == 8)
        let fourth = try await Task.detached { try SMBCatalogFiles(storage: configuration) }.value
        try Self.require(await Task.detached { fourth.finish(clean: true) }.value)

        let next = try await Fixture.ready(in: root)
        let ten = try await next.storage.inspectBudgetSummary()
        try Self.require(ten?.heldBodies == 10)
        _ = await next.snapshot.closeAndDrain()
        let laterPeer = RepeatedInPlaceSavePeer()
        let laterBrowser = SFTPBrowserSession(id: next.baseline.session, transport: laterPeer)
        let laterDocument = SFTPInPlaceDocumentSession(browser: laterBrowser, baseline: next.baseline, storage: next.storage)
        guard case .saved = await laterDocument.save(contents: try TextDocumentValue.original(Data("later\n".utf8)),
            generation: UUID()) else { throw Failure.assertion(#line) }
        try Self.require(await laterDocument.closeAfterExplicitBufferDecision() == .closedVersionsRetained)
        _ = await laterBrowser.close()
        _ = await Task.detached { next.metadata.finish(clean: false) }.value
        await next.drain()
        let both = try await cold.retainedDocumentsAfterExplicitRequest()
        try Self.require(both.count == 2)
        guard let old = both.first(where: { $0.copyCount == 8 }) else { throw Failure.assertion(#line) }
        try await cold.removeRetainedDocument(old)
        let afterRetirement = try await fixture.storage.inspectBudgetSummary()
        try Self.require(afterRetirement?.heldBodies == 2)
        let remaining = try await cold.recoveryListingAfterExplicitRequest()
        try Self.require(remaining.choices.count == 1 && remaining.choices[0].outcome == .verified)
        let afterLedger = try await Task.detached { [shared = fixture.storage.layout] in
            let owner = try SFTPSharedBudgetTransaction.open(layout: shared, writing: false)
            defer { owner.close() }; return owner.document
        }.value
        try Self.require(afterLedger.format == 3 && (afterLedger.retirements ?? []).isEmpty)
        await cold.stopAndDrain()
    }

    @Test func explicitConnectRefusesActiveBodyWithoutChangingTheOldLedger() async throws {
        let root = try Self.caseRoot("connect-active-refusal")
        let fixture = try await Fixture.ready(in: root)
        let configuration = try await fixture.workspace.prepareForConnect().metadataStorage
        let before = try Self.generatedInventory(root)
        do {
            try await configuration.prepareSharedOriginalStorageForConnect()
            throw Failure.assertion(#line)
        } catch SFTPSharedBudgetFailure.busy { }
        try Self.require(try Self.generatedInventory(root) == before)
        let ledger = try await Task.detached { [shared = fixture.storage.layout] in
            let owner = try SFTPSharedBudgetTransaction.open(layout: shared, writing: false)
            defer { owner.close() }; return owner.document
        }.value
        try Self.require(ledger.format == 1 && ledger.bodies.count == 2)
        _ = await fixture.snapshot.closeAndDrain()
        try await fixture.releasePin()
        _ = await Task.detached { fixture.metadata.finish(clean: false) }.value
        await fixture.drain()
    }

    @Test func explicitConnectOnFreshWorkspaceUpgradesLedgerAndKeepsSMBAdmission() async throws {
        let root = try Self.caseRoot("connect-fresh-workspace")
        let workspace = try ConnectionWorkspace(layout: Self.layout(in: root))
        let configuration = try await workspace.prepareForConnect().metadataStorage
        try await configuration.prepareSharedOriginalStorageForConnect()
        let initial = try await Task.detached { [shared = SFTPSharedBudgetLayout(storage: configuration)] in
            let owner = try SFTPSharedBudgetTransaction.open(layout: shared, writing: false)
            defer { owner.close() }; return owner.document
        }.value
        try Self.require(initial.format == 3 && initial.metadata.isEmpty && initial.bodies.isEmpty)
        let ordinary = try await Task.detached { try SMBCatalogFiles(storage: configuration) }.value
        try Self.require(await Task.detached { ordinary.finish(clean: true) }.value)
        try await configuration.prepareSharedOriginalStorageForConnect()
        let final = try await Task.detached { [shared = SFTPSharedBudgetLayout(storage: configuration)] in
            let owner = try SFTPSharedBudgetTransaction.open(layout: shared, writing: false)
            defer { owner.close() }; return owner.document
        }.value
        try Self.require(final.format == 3 && final.bodies.isEmpty)
        await workspace.stopAndDrain()
    }

    @Test func interruptedConnectMetadataRemovalKeepsItsOwnerAndRequiresReview() async throws {
        let root = try Self.caseRoot("connect-removal-interrupted")
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        let configuration = try await workspace.prepareForConnect().metadataStorage
        let session = UUID()
        let metadata = try await Task.detached {
            try SMBCatalogFiles(storage: configuration, purpose: .originalPending(session: session))
        }.value
        _ = try await Task.detached {
            try SFTPOriginalStorageOwner.bindOnMetadataExecutor(files: metadata, session: session,
                context: try Self.context())
        }.value
        let path = configuration.directory.appendingPathComponent("session-" + metadata.id.uuidString)
        try Self.require(!(await Task.detached { metadata.finish(clean: false) }.value))
        defer { SFTPSharedBudgetQualification.shared.set(nil) }
        SFTPSharedBudgetQualification.shared.set { stage in
            if stage == .metadataRemovalIntent { throw Failure.injected }
        }
        var interrupted = false
        do { try await configuration.prepareSharedOriginalStorageForConnect() }
        catch Failure.injected { interrupted = true }
        SFTPSharedBudgetQualification.shared.set(nil)
        try Self.require(interrupted && FileManager.default.fileExists(atPath: path.path))
        let ledger = try await Task.detached { [shared = SFTPSharedBudgetLayout(storage: configuration)] in
            let owner = try SFTPSharedBudgetTransaction.open(layout: shared, writing: false)
            defer { owner.close() }; return owner.document
        }.value
        try Self.require(ledger.format == 1 && ledger.metadata.count == 1
            && ledger.metadata[0].phase == .removalPending && ledger.bodies.isEmpty)
        do { try await configuration.prepareSharedOriginalStorageForConnect(); throw Failure.assertion(#line) }
        catch SFTPSharedBudgetFailure.recoveryRequired { }
        try Self.require(FileManager.default.fileExists(atPath: path.path))
        await workspace.stopAndDrain()
    }

    @Test func versionThreeBodySlotsKeepTheThirtyMiBByteLimit() throws {
        let owner = UUID(), session = UUID(), budget = UUID()
        var document = SFTPSharedBudgetDocument()
        document.format = 3; document.retirements = []; document.budgetID = budget; document.revision = 1
        document.poolPhase = .active
        document.metadata = [.init(id: owner, kind: .original, session: session,
            quota: SFTPSharedBudgetDocument.originalMetadataBytes, context: Data(repeating: 7, count: 32), phase: .removed)]
        let small = try DownloadDisk.reservation(expectedBytes: 0, tree: false)
        document.bodies = (0..<64).map { _ in .init(id: UUID(), owner: owner, expectedBytes: 0,
            reservedBytes: small, phase: .allocated) }
        try document.validate()
        let encoded = try document.encoded()
        try Self.require(try SFTPSharedBudgetDocument.decode(encoded).encoded() == encoded)
        var old = document; old.format = 2
        do { try old.validate(); throw Failure.assertion(#line) }
        catch SFTPSharedBudgetFailure.unsafe { }
        document.bodies.append(.init(id: UUID(), owner: owner, expectedBytes: 0,
            reservedBytes: small, phase: .allocated))
        do { try document.validate(); throw Failure.assertion(#line) }
        catch SFTPSharedBudgetFailure.unsafe { }
        let large = try DownloadDisk.reservation(expectedBytes: 1 << 20, tree: false)
        document.bodies = (0..<32).map { _ in .init(id: UUID(), owner: owner, expectedBytes: 1 << 20,
            reservedBytes: large, phase: .allocated) }
        do { try document.validate(); throw Failure.assertion(#line) }
        catch SFTPSharedBudgetFailure.capacity { }
    }

    @Test func editorBodyReferencesFitTheEightMemberRetirementIntent() throws {
        let references = (0..<9).map { value in
            SFTPOriginalSpoolReference(id: UUID(), logicalBytes: 0,
                digest: Data(repeating: UInt8(value), count: 32))
        }
        var record = SFTPOriginalEditorRecord(id: UUID(), session: UUID(), request: UUID(),
            context: try SFTPOriginalContext(Self.context()), expectedBytes: 0)
        record.path = "/generated.txt"
        record.phase = .recoveryOnly
        record.recovery = Array(references.prefix(8))
        record.bodyID = references[0].id
        record.body = references[0]
        try record.validate()
        var document = SFTPOriginalEditorCatalogDocument()
        document.revision = 1
        document.records = [record]
        let accepted = try document.encoded()
        try Self.require(try SFTPOriginalEditorCatalogDocument.decode(accepted).encoded() == accepted)

        record.bodyID = references[8].id
        record.body = references[8]
        do { try record.validate(); throw Failure.assertion(#line) }
        catch RemoteSettingsFailure.invalidRecord { }
        document.records = [record]
        do { _ = try document.encoded(); throw Failure.assertion(#line) }
        catch RemoteSettingsFailure.invalidRecord { }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var untrusted = try encoder.encode(document); untrusted.append(10)
        do { _ = try SFTPOriginalEditorCatalogDocument.decode(untrusted); throw Failure.assertion(#line) }
        catch RemoteSettingsFailure.invalidRecord { }
    }

    @Test func liveEditorDiscoveryAndViewerPinBlockWholeDocumentRemoval() async throws {
        let fixture = try await Fixture.retained(in: Self.caseRoot("retirement"))
        do {
            let whileVisible = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
            // Discovery omits a body whose real owner SH is still held.
            // Mint a checked choice after that owner closes, then open a real
            // viewed-version SH to exercise Remove's live-owner refusal.
            // A separate race control must reach the final EX acquisition.
            try Self.require(whileVisible.isEmpty)
            try await fixture.releasePin()
            let beforeViewer = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
            try Self.require(beforeViewer.count == 1 && beforeViewer[0].copyCount == 2 && !beforeViewer[0].removalPending)
            let versions = try await fixture.workspace.recoveryChoicesAfterExplicitRequest()
            try Self.require(versions.count == 1)
            let viewed = try await versions[0].readPinnedVersion(.before)
            try Self.require(viewed.contents.encoded == Data("before\n".utf8))
            do {
                try await fixture.workspace.removeRetainedDocument(beforeViewer[0])
                throw Failure.assertion(#line)
            } catch SFTPSharedBudgetFailure.busy { }
            let afterRefusal = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
            try Self.require(afterRefusal.isEmpty)
            try Self.require(await viewed.closeAndDrain())
            let choices = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
            try Self.require(choices.count == 1 && choices[0].copyCount == 2 && !choices[0].removalPending)
            try await fixture.workspace.removeRetainedDocument(choices[0])
            try Self.require(try await fixture.workspace.retainedDocumentsAfterExplicitRequest().isEmpty)
            let ledger = try await Task.detached { [layout = fixture.layout] in
                guard let file = try RemoteSettingsFile<SFTPSharedBudgetDocument>.open(
                    layout.persistentConnectionWorkspaceDirectory.appendingPathExtension("original-budget"),
                    writing: false, retainedRetirement: .inspectCommittedLedger) else { throw Failure.assertion(#line) }
                defer { file.close() }; return file.snapshot
            }.value
            try Self.require(ledger.format == 2 && (ledger.retirements ?? []).isEmpty
                && ledger.bodies.allSatisfy { $0.phase == .removed })
        } catch { await fixture.drain(); throw error }
        await fixture.drain()
    }

    @Test func documentRecoveryReaderSealJoinsPinnedReadAndPreservesGlobalReview() async throws {
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var entered = false
            let release = DispatchSemaphore(value: 0)
            func hold() throws {
                lock.withLock { entered = true }
                guard release.wait(timeout: .now() + 5) == .success else { throw Failure.assertion(#line) }
            }
            func waitUntilEntered() async throws -> Bool {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while ContinuousClock.now < deadline {
                    if lock.withLock({ entered }) { return true }
                    try await Task.sleep(for: .milliseconds(10))
                }
                return lock.withLock { entered }
            }
        }
        let fixture = try await Fixture.retained(in: Self.caseRoot("reader-seal"))
        do {
            try await fixture.releasePin()
            let reader = SFTPInPlaceRecoveryReadOwner()
            let choices = try await reader.discover(layout: fixture.storage.layout, origin: nil)
            try Self.require(choices.count == 1)
            try Self.require(try await choices[0].readVersion(.before).encoded == Data("before\n".utf8))
            await reader.stopAndDrain()
            try Self.require(try await choices[0].readVersion(.edited).encoded == Data("after\n".utf8))

            let gate = Gate()
            SFTPInPlaceRecoveryQualification.shared.set { stage in
                if stage == .bodyPinned { try gate.hold() }
            }
            defer { gate.release.signal(); SFTPInPlaceRecoveryQualification.shared.set(nil) }
            let active = Task { try await choices[0].readPinnedVersion(.before) }
            let reached = try await gate.waitUntilEntered()
            guard reached else {
                active.cancel(); _ = try? await active.value
                throw Failure.assertion(#line)
            }
            reader.seal()
            let draining = Task { await reader.sealAndDrain() }
            gate.release.signal()
            try Self.require(await draining.value)
            var escaped = false
            do {
                let viewed = try await active.value
                escaped = true
                _ = await viewed.closeAndDrain()
            } catch { }
            try Self.require(!escaped)
            SFTPInPlaceRecoveryQualification.shared.set(nil)
            do {
                _ = try await choices[0].readVersion(.before)
                throw Failure.assertion(#line)
            } catch SFTPTextFailure.closed { }
            do {
                _ = try await reader.discover(layout: fixture.storage.layout, origin: nil)
                throw Failure.assertion(#line)
            } catch SFTPTextFailure.closed { }
            let global = try await fixture.workspace.recoveryChoicesAfterExplicitRequest()
            try Self.require(global.count == 1)
            try Self.require(try await global[0].readVersion(.before).encoded == Data("before\n".utf8))
        } catch { await fixture.drain(); throw error }
        await fixture.drain()
    }

    @Test func liveEditorPinBlocksEvictedCacheRepair() async throws {
        let root = try Self.caseRoot("repair")
        let fixture = try await Fixture.retained(in: root)
        do {
            let retained = root.appendingPathComponent("retained-earlier", isDirectory: true)
            try Self.require(rename(fixture.layout.smbDirectory.path, retained.path) == 0)
            try Self.require(try await fixture.workspace.inspect().state == .activeCompatibilityNeedsReview)
            do {
                _ = try await fixture.workspace.repairChoiceAfterExplicitRequest()
                throw Failure.assertion(#line)
            } catch let issue as ConnectionWorkspaceFailure { try Self.require(issue == .busy) }
            try await fixture.releasePin()
            let choice = try await fixture.workspace.repairChoiceAfterExplicitRequest()
            try Self.require(choice.action == .repair)
            try await fixture.workspace.repairConnectionStorage(choice)
            try Self.require(try await fixture.workspace.inspect().state == .active)
            let versions = try await fixture.workspace.recoveryChoicesAfterExplicitRequest()
            try Self.require(versions.count == 1)
            try Self.require(try await versions[0].readVersion(.before).encoded == Data("before\n".utf8))
            try Self.require(try await versions[0].readVersion(.edited).encoded == Data("after\n".utf8))
        } catch { await fixture.drain(); throw error }
        await fixture.drain()
    }

    @Test func interruptedRetirementResumesOnlyItsRecordedWholeDocument() async throws {
        // Each callback throws only after a real read/Save fixture has minted
        // two recovery bodies and the editor pin has drained. These are local
        // interruption controls, not a process-exit or power-loss simulation.
        let points: [SFTPRetainedRemovalStage] = [
            .intentCommitted, .payloadUnlinked, .leaseUnlinked, .markerUnlinked,
            .folderRemoved, .directorySynchronized, .beforeHistory,
            .historyCommitted, .beforeEditor, .editorCommitted, .beforeCharges
        ]
        for (index, point) in points.enumerated() {
            let fixture = try await Fixture.retained(in: Self.caseRoot("retirement-resume-\(index)"))
            do {
                try await fixture.releasePin()
                let choices = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
                try Self.require(choices.count == 1 && !choices[0].removalPending)
                SFTPRetainedRemovalQualification.shared.set { stage in
                    if stage == point { throw Failure.injected }
                }
                var didInterrupt = false
                do { try await fixture.workspace.removeRetainedDocument(choices[0]) }
                catch Failure.injected { didInterrupt = true }
                SFTPRetainedRemovalQualification.shared.set(nil)
                try Self.require(didInterrupt)
                let pending = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
                try Self.require(pending.count == 1 && pending[0].removalPending)
                try await fixture.workspace.removeRetainedDocument(pending[0])
                try Self.require(try await fixture.workspace.retainedDocumentsAfterExplicitRequest().isEmpty)
                try Self.require(try await fixture.workspace.recoveryChoicesAfterExplicitRequest().isEmpty)
            } catch {
                SFTPRetainedRemovalQualification.shared.set(nil)
                await fixture.drain()
                throw error
            }
            await fixture.drain()
        }
    }

    @Test func committedRetirementMetadataStagesRequireExactResume() async throws {
        let points: [SFTPRetainedRemovalStage] = [
            .ledgerStagingWritten, .ledgerStagingSynchronized, .ledgerBeforeRename,
            .ledgerRenamed, .ledgerDirectorySynchronized,
            .journalStagingWritten, .journalStagingSynchronized, .journalBeforeRename,
            .journalRenamed, .journalDirectorySynchronized,
            .editorStagingWritten, .editorStagingSynchronized, .editorBeforeRename,
            .editorRenamed, .editorDirectorySynchronized
        ]
        for (index, point) in points.enumerated() {
            let fixture = try await Fixture.retained(in: Self.caseRoot("retirement-metadata-\(index)"))
            do {
                try await fixture.releasePin()
                let choices = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
                try Self.require(choices.count == 1 && !choices[0].removalPending)
                let gate = RemovalGate(point)
                SFTPRetainedRemovalQualification.shared.set { stage in try gate.reach(stage) }
                var interrupted = false
                do { try await fixture.workspace.removeRetainedDocument(choices[0]) }
                catch Failure.injected { interrupted = true }
                catch RemoteSettingsFailure.durabilityUncertain { interrupted = true }
                SFTPRetainedRemovalQualification.shared.set(nil)
                try Self.require(interrupted)

                let pieces = point.rawValue.split(separator: ".")
                try Self.require(pieces.count == 2)
                let location: URL
                switch pieces[0] {
                case "ledger": location = fixture.storage.layout.ledger
                case "journal": location = fixture.storage.layout.journal
                case "editor": location = fixture.storage.layout.editors
                default: throw Failure.assertion(#line)
                }
                let pendingPath = location.appendingPathComponent("pending.json")
                let hasStage = pieces[1] == "stagingWritten" || pieces[1] == "stagingSynchronized" || pieces[1] == "beforeRename"
                try Self.require(FileManager.default.fileExists(atPath: pendingPath.path) == hasStage)
                let before: Data?
                if hasStage { before = try Data(contentsOf: pendingPath) }
                else { before = nil }
                let pending = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
                try Self.require(pending.count == 1 && pending[0].removalPending)
                if let before { try Self.require(try Data(contentsOf: pendingPath) == before) }
                try await fixture.workspace.removeRetainedDocument(pending[0])
                try Self.require(try await fixture.workspace.retainedDocumentsAfterExplicitRequest().isEmpty)
                try Self.require(try await fixture.workspace.recoveryChoicesAfterExplicitRequest().isEmpty)
                try Self.require(!FileManager.default.fileExists(atPath: pendingPath.path))
            } catch {
                SFTPRetainedRemovalQualification.shared.set(nil)
                await fixture.drain()
                throw error
            }
            await fixture.drain()
        }
    }

    @Test func preIntentLedgerStagesPreserveBodiesAndRequireReview() async throws {
        let points: [SFTPRetainedRemovalStage] = [
            .ledgerStagingWritten, .ledgerStagingSynchronized, .ledgerBeforeRename
        ]
        for (index, point) in points.enumerated() {
            let root = try Self.caseRoot("retirement-pre-intent-\(index)")
            let fixture = try await Fixture.retained(in: root)
            do {
                try await fixture.releasePin()
                let choices = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
                try Self.require(choices.count == 1 && !choices[0].removalPending)
                let bodyBefore = try Self.generatedInventory(fixture.storage.layout.bodies)
                SFTPRetainedRemovalQualification.shared.set { stage in
                    if stage == point { throw Failure.injected }
                }
                var interrupted = false
                do { try await fixture.workspace.removeRetainedDocument(choices[0]) }
                catch Failure.injected { interrupted = true }
                SFTPRetainedRemovalQualification.shared.set(nil)
                try Self.require(interrupted)
                let stage = fixture.storage.layout.ledger.appendingPathComponent("pending.json")
                try Self.require(FileManager.default.fileExists(atPath: stage.path))
                let staged = try Data(contentsOf: stage)
                try Self.require(try Self.generatedInventory(fixture.storage.layout.bodies) == bodyBefore)
                var refused = false
                do { _ = try await fixture.workspace.retainedDocumentsAfterExplicitRequest() }
                catch RemoteSettingsFailure.recoveryRequired { refused = true }
                catch SFTPSharedBudgetFailure.recoveryRequired { refused = true }
                try Self.require(refused)
                try Self.require(try Data(contentsOf: stage) == staged)
                try Self.require(try Self.generatedInventory(fixture.storage.layout.bodies) == bodyBefore)
            } catch {
                SFTPRetainedRemovalQualification.shared.set(nil)
                await fixture.drain()
                throw error
            }
            await fixture.drain()
        }
    }

    @Test func completedRetirementDoesNotReopenAfterLateCallback() async throws {
        let fixture = try await Fixture.retained(in: Self.caseRoot("retirement-after-charges"))
        do {
            try await fixture.releasePin()
            let choices = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
            try Self.require(choices.count == 1 && !choices[0].removalPending)
            SFTPRetainedRemovalQualification.shared.set { stage in
                if stage == .chargesCommitted { throw Failure.injected }
            }
            var interrupted = false
            do { try await fixture.workspace.removeRetainedDocument(choices[0]) }
            catch Failure.injected { interrupted = true }
            SFTPRetainedRemovalQualification.shared.set(nil)
            try Self.require(interrupted)
            try Self.require(try await fixture.workspace.retainedDocumentsAfterExplicitRequest().isEmpty)
            try Self.require(try await fixture.workspace.recoveryChoicesAfterExplicitRequest().isEmpty)
            let ledger = try await Task.detached { [layout = fixture.layout] in
                guard let file = try RemoteSettingsFile<SFTPSharedBudgetDocument>.open(
                    layout.persistentConnectionWorkspaceDirectory.appendingPathExtension("original-budget"),
                    writing: false, retainedRetirement: .inspectCommittedLedger) else { throw Failure.assertion(#line) }
                defer { file.close() }; return file.snapshot
            }.value
            try Self.require((ledger.retirements ?? []).isEmpty && ledger.bodies.allSatisfy { $0.phase == .removed })
        } catch {
            SFTPRetainedRemovalQualification.shared.set(nil)
            await fixture.drain()
            throw error
        }
        await fixture.drain()
    }

    @Test func interruptedCacheRepairResumesWithoutReplacingRecoveryBodies() async throws {
        let points: [ConnectionWorkspaceRepairPoint] = [
            .intentRecorded, .parentsRecorded, .stageRecorded,
            .allocatorWritten, .allocatorRecorded, .markerRecorded, .markerWritten,
            .fullyFencedRecorded, .beforePublication, .published, .publicationRecorded,
            .locationPendingWritten, .locationPendingSynced, .locationBeforeRename,
            .locationRenamed, .locationDirectorySynced
        ]
        for (index, point) in points.enumerated() {
            let root = try Self.caseRoot("repair-resume-\(index)")
            let fixture = try await Fixture.retained(in: root)
            do {
                let retained = root.appendingPathComponent("retained-earlier", isDirectory: true)
                try Self.require(rename(fixture.layout.smbDirectory.path, retained.path) == 0)
                try await fixture.releasePin()
                let choice = try await fixture.workspace.repairChoiceAfterExplicitRequest()
                try Self.require(choice.action == .repair)
                ConnectionWorkspaceRepairQualification.shared.set { stage in
                    if stage == point { throw Failure.injected }
                }
                var didInterrupt = false
                do { try await fixture.workspace.repairConnectionStorage(choice) }
                catch Failure.injected { didInterrupt = true }
                catch RemoteSettingsFailure.durabilityUncertain { didInterrupt = true }
                ConnectionWorkspaceRepairQualification.shared.set(nil)
                try Self.require(didInterrupt)
                let pendingPath = choice.paths.record.appendingPathComponent("pending.json")
                let preRename = point == .locationPendingWritten || point == .locationPendingSynced || point == .locationBeforeRename
                if point.rawValue.hasPrefix("location") {
                    try Self.require(FileManager.default.fileExists(atPath: pendingPath.path) == preRename)
                }
                let pendingBytes: Data?
                if preRename { pendingBytes = try Data(contentsOf: pendingPath) }
                else { pendingBytes = nil }
                let resume = try await fixture.workspace.repairChoiceAfterExplicitRequest()
                try Self.require(resume.action == .resume)
                if let pendingBytes { try Self.require(try Data(contentsOf: pendingPath) == pendingBytes) }
                try await fixture.workspace.repairConnectionStorage(resume)
                try Self.require(try await fixture.workspace.inspect().state == .active)
                try Self.require(!FileManager.default.fileExists(atPath: pendingPath.path))
                let versions = try await fixture.workspace.recoveryChoicesAfterExplicitRequest()
                try Self.require(versions.count == 1)
                try Self.require(try await versions[0].readVersion(.before).encoded == Data("before\n".utf8))
                try Self.require(try await versions[0].readVersion(.edited).encoded == Data("after\n".utf8))
            } catch {
                ConnectionWorkspaceRepairQualification.shared.set(nil)
                await fixture.drain()
                throw error
            }
            await fixture.drain()
        }
    }

    @Test func repairRefusesBeforeIntentAndSurvivesLateCallback() async throws {
        let earlyRoot = try Self.caseRoot("repair-before-intent")
        let early = try await Fixture.retained(in: earlyRoot)
        do {
            try Self.require(rename(early.layout.smbDirectory.path,
                earlyRoot.appendingPathComponent("retained-earlier", isDirectory: true).path) == 0)
            try await early.releasePin()
            let first = try await early.workspace.repairChoiceAfterExplicitRequest()
            try Self.require(first.action == .repair)
            ConnectionWorkspaceRepairQualification.shared.set { stage in
                if stage == .graphHeld { throw Failure.injected }
            }
            var interrupted = false
            do { try await early.workspace.repairConnectionStorage(first) }
            catch Failure.injected { interrupted = true }
            ConnectionWorkspaceRepairQualification.shared.set(nil)
            try Self.require(interrupted)
            let again = try await early.workspace.repairChoiceAfterExplicitRequest()
            try Self.require(again.action == .repair && again.current == first.current && again.pending == nil)
            try await early.workspace.repairConnectionStorage(again)
            try Self.require(try await early.workspace.inspect().state == .active)
            let versions = try await early.workspace.recoveryChoicesAfterExplicitRequest()
            try Self.require(versions.count == 1)
            try Self.require(try await versions[0].readVersion(.before).encoded == Data("before\n".utf8))
            try Self.require(try await versions[0].readVersion(.edited).encoded == Data("after\n".utf8))
        } catch {
            ConnectionWorkspaceRepairQualification.shared.set(nil)
            await early.drain()
            throw error
        }
        await early.drain()

        let lateRoot = try Self.caseRoot("repair-after-complete")
        let late = try await Fixture.retained(in: lateRoot)
        do {
            try Self.require(rename(late.layout.smbDirectory.path,
                lateRoot.appendingPathComponent("retained-earlier", isDirectory: true).path) == 0)
            try await late.releasePin()
            let choice = try await late.workspace.repairChoiceAfterExplicitRequest()
            try Self.require(choice.action == .repair)
            ConnectionWorkspaceRepairQualification.shared.set { stage in
                if stage == .activeRecorded { throw Failure.injected }
            }
            var interrupted = false
            do { try await late.workspace.repairConnectionStorage(choice) }
            catch Failure.injected { interrupted = true }
            ConnectionWorkspaceRepairQualification.shared.set(nil)
            try Self.require(interrupted)
            try Self.require(try await late.workspace.inspect().state == .active)
            let versions = try await late.workspace.recoveryChoicesAfterExplicitRequest()
            try Self.require(versions.count == 1)
            try Self.require(try await versions[0].readVersion(.before).encoded == Data("before\n".utf8))
            try Self.require(try await versions[0].readVersion(.edited).encoded == Data("after\n".utf8))
        } catch {
            ConnectionWorkspaceRepairQualification.shared.set(nil)
            await late.drain()
            throw error
        }
        await late.drain()
    }

    @Test func repairNeverAdoptsOccupiedOrReplacedGeneratedRoots() async throws {
        let occupiedRoot = try Self.caseRoot("repair-occupied-root")
        let occupied = try await Fixture.retained(in: occupiedRoot)
        do {
            try Self.require(rename(occupied.layout.smbDirectory.path,
                occupiedRoot.appendingPathComponent("retained-earlier", isDirectory: true).path) == 0)
            try await occupied.releasePin()
            try Self.require(mkdir(occupied.layout.smbDirectory.path, 0o700) == 0)
            let before = try Self.generatedInventory(occupiedRoot)
            var refused = false
            do { _ = try await occupied.workspace.repairChoiceAfterExplicitRequest() }
            catch let issue as ConnectionWorkspaceFailure {
                refused = issue == .reviewRequired || issue == .changed
            }
            try Self.require(refused)
            try Self.require(try Self.generatedInventory(occupiedRoot) == before)
            let preserved = occupiedRoot.appendingPathComponent("preserved-occupied", isDirectory: true)
            try Self.require(rename(occupied.layout.smbDirectory.path, preserved.path) == 0)
            let choice = try await occupied.workspace.repairChoiceAfterExplicitRequest()
            try Self.require(choice.action == .repair)
            try await occupied.workspace.repairConnectionStorage(choice)
            try Self.require(try await occupied.workspace.inspect().state == .active)
            let versions = try await occupied.workspace.recoveryChoicesAfterExplicitRequest()
            try Self.require(versions.count == 1)
            try Self.require(try await versions[0].readVersion(.before).encoded == Data("before\n".utf8))
            try Self.require(try await versions[0].readVersion(.edited).encoded == Data("after\n".utf8))
        } catch { await occupied.drain(); throw error }
        await occupied.drain()

        let replacedRoot = try Self.caseRoot("repair-replaced-stage")
        let replaced = try await Fixture.retained(in: replacedRoot)
        do {
            try Self.require(rename(replaced.layout.smbDirectory.path,
                replacedRoot.appendingPathComponent("retained-earlier", isDirectory: true).path) == 0)
            try await replaced.releasePin()
            let choice = try await replaced.workspace.repairChoiceAfterExplicitRequest()
            ConnectionWorkspaceRepairQualification.shared.set { stage in
                if stage == .stageRecorded { throw Failure.injected }
            }
            var interrupted = false
            do { try await replaced.workspace.repairConnectionStorage(choice) }
            catch Failure.injected { interrupted = true }
            ConnectionWorkspaceRepairQualification.shared.set(nil)
            try Self.require(interrupted)
            let resume = try await replaced.workspace.repairChoiceAfterExplicitRequest()
            try Self.require(resume.action == .resume)
            guard let stageName = try ConnectionWorkspaceRecord.decode(resume.current).repair?.stageName else {
                throw Failure.assertion(#line)
            }
            let stage = choice.paths.earlier.deletingLastPathComponent().appendingPathComponent(stageName, isDirectory: true)
            let preserved = replacedRoot.appendingPathComponent("preserved-stage", isDirectory: true)
            try Self.require(rename(stage.path, preserved.path) == 0 && mkdir(stage.path, 0o700) == 0)
            let before = try Self.generatedInventory(replacedRoot)
            var refused = false
            do { _ = try await replaced.workspace.repairChoiceAfterExplicitRequest() }
            catch let issue as ConnectionWorkspaceFailure {
                refused = issue == .reviewRequired || issue == .changed
            }
            try Self.require(refused)
            try Self.require(try Self.generatedInventory(replacedRoot) == before)
        } catch {
            ConnectionWorkspaceRepairQualification.shared.set(nil)
            await replaced.drain()
            throw error
        }
        await replaced.drain()
    }

    /// The generated host dispatches these exact child roles. The parent
    /// checks their exit and reopens the workspace with fresh process state.
    static func runSecurityChild(_ mode: String, name: String) async throws {
        let accepted = ["retire-exit": "retirement-process-exit", "repair-exit": "repair-process-exit",
            "editor-hold": "editor-process", "viewer-hold": "viewer-remove", "viewer-repair": "viewer-repair",
            "viewer-drop": "viewer-dropped", "owner-race-hold": "owner-exclusive-race"]
        try require(accepted[mode] == name)
        let root = try existingCaseRoot(name)
        if mode == "owner-race-hold" {
            let bodies = try layout(in: root).persistentConnectionWorkspaceDirectory.appendingPathExtension("original-bodies")
            let pool = open(bodies.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard pool >= 0 else { throw Failure.scope }; defer { Darwin.close(pool) }
            var facts = stat()
            try require(fstat(pool, &facts) == 0 && facts.st_uid == geteuid()
                && facts.st_mode & S_IFMT == S_IFDIR && facts.st_mode & 0o7777 == 0o700)
            let folders = try DownloadDisk.names(pool, maximum: 4).filter { $0.hasPrefix("download-") }.sorted()
            try require(folders.count == 2)
            let record = try DownloadDisk.record(pool, name: folders[0])
            let folder = openat(pool, folders[0], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard folder >= 0 else { throw Failure.scope }; defer { Darwin.close(folder) }
            try require(try DownloadDisk.identity(folder) == record.folder)
            let lease = openat(folder, "owner.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard lease >= 0 else { throw Failure.scope }; defer { Darwin.close(lease) }
            try require(fstat(lease, &facts) == 0 && DownloadDisk.privateFile(facts) && facts.st_size == 0
                && (try DownloadDisk.identity(lease)) == record.files["owner.lock"])
            try require(fstatat(folder, "owner.lock", &facts, AT_SYMLINK_NOFOLLOW) == 0
                && DownloadDisk.privateFile(facts) && DownloadDisk.Identity(facts) == record.files["owner.lock"])
            try mark(root.appendingPathComponent("ready"))
            try waitForMarker(root.appendingPathComponent("arm"), seconds: 8)
            try require(flock(lease, LOCK_SH | LOCK_NB) == 0)
            try require(try DownloadDisk.identity(lease) == record.files["owner.lock"])
            try require(fstatat(folder, "owner.lock", &facts, AT_SYMLINK_NOFOLLOW) == 0
                && DownloadDisk.privateFile(facts) && DownloadDisk.Identity(facts) == record.files["owner.lock"])
            try mark(root.appendingPathComponent("held"))
            // Keep the actual child image and SH descriptor observable while
            // the parent checks the final EX refusal and unchanged bodies.
            try await Task.sleep(for: .seconds(2))
            try await waitForDrain(in: root)
            return
        }
        if mode == "retire-exit" {
            let fixture = try await Fixture.retained(in: root)
            try await fixture.releasePin()
            let choices = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
            try require(choices.count == 1)
            SFTPRetainedRemovalQualification.shared.set { stage in
                if stage == .payloadUnlinked { _exit(85) }
            }
            try await fixture.workspace.removeRetainedDocument(choices[0])
            throw Failure.assertion(#line)
        }
        if mode == "repair-exit" {
            let fixture = try await Fixture.retained(in: root)
            try require(rename(fixture.layout.smbDirectory.path,
                root.appendingPathComponent("retained-earlier", isDirectory: true).path) == 0)
            try await fixture.releasePin()
            let choice = try await fixture.workspace.repairChoiceAfterExplicitRequest()
            try require(choice.action == .repair)
            ConnectionWorkspaceRepairQualification.shared.set { stage in
                if stage == .published { _exit(85) }
            }
            try await fixture.workspace.repairConnectionStorage(choice)
            throw Failure.assertion(#line)
        }
        if mode == "editor-hold" {
            let fixture = try await Fixture.retained(in: root)
            try mark(root.appendingPathComponent("ready"))
            try await waitForDrain(in: root)
            try await fixture.releasePin()
            await fixture.drain()
            return
        }
        let workspace = try ConnectionWorkspace(layout: layout(in: root))
        let choices = try await workspace.recoveryChoicesAfterExplicitRequest()
        try require(choices.count == 1)
        if mode == "viewer-drop" {
            weak var released: SFTPInPlaceViewedVersion?
            do {
                let viewed = try await choices[0].readPinnedVersion(.before)
                try require(viewed.contents.encoded == Data("before\n".utf8))
                released = viewed
            }
            try require(released == nil)
            try mark(root.appendingPathComponent("ready"))
            try await waitForDrain(in: root)
            await workspace.stopAndDrain()
            return
        }
        let viewed = try await choices[0].readPinnedVersion(.before)
        try require(viewed.contents.encoded == Data("before\n".utf8))
        try mark(root.appendingPathComponent("ready"))
        try await waitForDrain(in: root)
        try require(await viewed.closeAndDrain())
        await workspace.stopAndDrain()
    }

    private static func waitForDrain(in root: URL) async throws {
        let path = root.appendingPathComponent("drain")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.assertion(#line)
    }

    @Test func stableWorkspaceVolumeIdentitySurvivesSyntheticDeviceChange() async throws {
        let root = try Self.caseRoot("stable-volume-device-change")
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        _ = try await workspace.prepareForConnect()
        guard let file = try ConnectionWorkspaceDisk.File.open(layout.connectionWorkspaceRecordDirectory,
                                                               writing: true, existingOnly: true) else {
            throw Failure.scope
        }
        var changed = file.snapshot
        try Self.require(changed.format == 3 && changed.isActive && changed.graph.values.allSatisfy { $0.volume != nil })
        let oldDevice = try Self.requireDevice(changed.earlier)
        changed.earlier = changed.earlier?.rebased(device: oldDevice &+ 1, volume: changed.earlier?.volume)
        changed.earlierLock = changed.earlierLock?.rebased(device: oldDevice &+ 1, volume: changed.earlierLock?.volume)
        changed.graph = changed.graph.mapValues { $0.rebased(device: oldDevice &+ 1, volume: $0.volume) }
        try file.commit(changed); file.close()
        try Self.require(try await workspace.inspect().state == .active)
        _ = try await workspace.prepareForConnect()
        await workspace.stopAndDrain()
    }

    @Test func activityReviewAdmissionNeverPreparesAWorkspace() async throws {
        let absentRoot = try Self.caseRoot("activity-review-absent")
        let absentLayout = try Self.layout(in: absentRoot)
        let absentWorkspace = try ConnectionWorkspace(layout: absentLayout)
        let absentBefore = try Self.generatedInventory(absentRoot)
        do { _ = try await absentWorkspace.admitExistingForReview(); throw Failure.assertion(#line) }
        catch ConnectionWorkspaceFailure.reviewRequired { }
        try Self.require(try Self.generatedInventory(absentRoot) == absentBefore)
        try Self.require(try await absentWorkspace.inspect().state == .unprepared)
        await absentWorkspace.stopAndDrain()

        let activeRoot = try Self.caseRoot("activity-review-active")
        let activeLayout = try Self.layout(in: activeRoot)
        let activeWorkspace = try ConnectionWorkspace(layout: activeLayout)
        _ = try await activeWorkspace.prepareForConnect()
        let activeBefore = try Self.generatedInventory(activeRoot)
        let admission = try await activeWorkspace.admitExistingForReview()
        try Self.require(admission.metadataStorage.directory == activeLayout.persistentConnectionWorkspaceDirectory)
        try Self.require(try await SMBTemporaryCatalogPool(storage: admission.metadataStorage).inspect().isEmpty)
        try Self.require(try Self.generatedInventory(activeRoot) == activeBefore)
        try Self.require(try await activeWorkspace.inspect().state == .active)
        await activeWorkspace.stopAndDrain()
    }

    @Test func legacyWorkspaceDeviceChangeRequiresExplicitExactReconciliation() async throws {
        let root = try Self.caseRoot("legacy-device-review")
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        _ = try await workspace.prepareForConnect()
        try Self.seedLegacyDeviceChange(layout)
        do { _ = try await workspace.prepareForConnect(); throw Failure.assertion(#line) }
        catch ConnectionWorkspaceFailure.changed { }
        let choice = try await workspace.legacyIdentityChoiceAfterExplicitRequest()
        try Self.require(choice.action == .reconcile && choice.observedObjectCount == 14)
        try await workspace.reconcileLegacyIdentity(choice)
        try Self.require(try await workspace.inspect().state == .active)
        _ = try await workspace.prepareForConnect()
        do { try await workspace.reconcileLegacyIdentity(choice); throw Failure.assertion(#line) }
        catch ConnectionWorkspaceFailure.changed { }
        await workspace.stopAndDrain()
    }

    @Test func recognizedColdReceiveSurvivesLegacyRebindAndConnectPreparation() async throws {
        let root = try Self.caseRoot("legacy-cold-receive")
        let shared = try await Self.interruptedReceive(in: root, payloadBytes: 3)
        let pendingBefore = try await Task.detached { [shared] in
            let transaction = try SFTPSharedBudgetTransaction.open(layout: shared, writing: false)
            defer { transaction.close() }
            guard let pending = transaction.document.bodies.first(where: { $0.phase == .allocating }) else {
                throw Failure.scope
            }
            return pending
        }.value
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        try Self.seedLegacyDeviceChange(layout)
        let before = try Self.generatedInventory(root)
        do { _ = try await workspace.prepareForConnect(); throw Failure.assertion(#line) }
        catch ConnectionWorkspaceFailure.changed { }
        let choice = try await workspace.legacyIdentityChoiceAfterExplicitRequest()
        try Self.require(choice.action == .reconcile && choice.observedObjectCount == 14)
        try Self.require(try Self.generatedInventory(root) == before)
        try await workspace.reconcileLegacyIdentity(choice)
        let afterRebind = try Self.generatedInventory(root)
        try Self.require(before.filter { !$0.key.contains("connection-workspace-location") } ==
                         afterRebind.filter { !$0.key.contains("connection-workspace-location") })
        let admitted = try await workspace.prepareForConnect()
        try await admitted.metadataStorage.prepareSharedOriginalStorageForConnect()
        let budget = try await Task.detached { [storage = admitted.metadataStorage] in
            let transaction = try SFTPSharedBudgetTransaction.open(layout: .init(storage: storage), writing: false)
            defer { transaction.close() }
            return transaction.document
        }.value
        try Self.require(budget.bodies.filter { $0.phase == .allocating }.count == 1 &&
                         budget.bodies.contains(pendingBefore))
        let afterConnect = try Self.generatedInventory(root)
        try Self.require(before.filter { $0.key.contains("connection-workspace.original-bodies") } ==
                         afterConnect.filter { $0.key.contains("connection-workspace.original-bodies") })
        let listing = try await workspace.recoveryListingAfterExplicitRequest()
        try Self.require(listing.incompleteReceiveCount == 1 && listing.choices.isEmpty)
        try Self.require(FileManager.default.fileExists(atPath: shared.bodies.path))
        await workspace.stopAndDrain()
    }

    @Test func legacyColdReceiveRefusesHeldWriterWithoutChangingGraph() async throws {
        let root = try Self.caseRoot("legacy-cold-held-writer")
        let shared = try await Self.interruptedReceive(in: root, payloadBytes: 3)
        let bodyID = try await Self.pendingBodyID(shared)
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        try Self.seedLegacyDeviceChange(layout)
        let before = try Self.generatedInventory(root)
        let lockURL = shared.bodies.appendingPathComponent("download-" + bodyID.uuidString, isDirectory: true)
            .appendingPathComponent("owner.lock")
        var held = open(lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard held >= 0 else { throw Failure.scope }
        defer { if held >= 0 { Darwin.close(held) } }
        try Self.require(flock(held, LOCK_EX | LOCK_NB) == 0)
        try Self.require((try? await workspace.legacyIdentityChoiceAfterExplicitRequest()) == nil)
        try Self.require(try Self.generatedInventory(root) == before)
        Darwin.close(held); held = -1
        let choice = try await workspace.legacyIdentityChoiceAfterExplicitRequest()
        try Self.require(choice.observedObjectCount == 14)
        try Self.require(try Self.generatedInventory(root) == before)
        await workspace.stopAndDrain()
    }

    @Test func legacyColdReceiveRefusesForeignBodyMarkerWithoutChangingGraph() async throws {
        let root = try Self.caseRoot("legacy-cold-foreign-marker")
        let shared = try await Self.interruptedReceive(in: root, payloadBytes: 3)
        let bodyID = try await Self.pendingBodyID(shared)
        let markerURL = shared.bodies.appendingPathComponent("download-" + bodyID.uuidString, isDirectory: true)
            .appendingPathComponent("session.meta")
        let marker = try JSONDecoder().decode(DownloadDisk.Marker.self, from: Data(contentsOf: markerURL))
        let foreign = UUID()
        try Self.require(foreign != marker.originalBudget)
        let altered = try DownloadDisk.encodedMarker(.init(version: marker.version, id: marker.id,
            expectedBytes: marker.expectedBytes, treeReservation: marker.treeReservation,
            originalBudget: foreign, originalOwner: marker.originalOwner))
        let fd = open(markerURL.path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.scope }
        do { try DownloadDisk.writeAll(fd, altered); try Self.require(fsync(fd) == 0) }
        catch { Darwin.close(fd); throw error }
        Darwin.close(fd)
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        try Self.seedLegacyDeviceChange(layout)
        let before = try Self.generatedInventory(root)
        try Self.require((try? await workspace.legacyIdentityChoiceAfterExplicitRequest()) == nil)
        try Self.require(try Self.generatedInventory(root) == before)
        await workspace.stopAndDrain()
    }

    @Test func legacyColdReceiveDoesNotAdmitRemovalPending() async throws {
        let root = try Self.caseRoot("legacy-cold-removal-pending")
        let shared = try await Self.interruptedReceive(in: root, payloadBytes: 3)
        guard let ledger = try RemoteSettingsFile<SFTPSharedBudgetDocument>.open(shared.ledger, writing: true) else {
            throw Failure.scope
        }
        var changed = ledger.snapshot
        guard let index = changed.bodies.firstIndex(where: { $0.phase == .allocating }) else { throw Failure.scope }
        changed.bodies[index].phase = .removalPending; changed.revision += 1
        try ledger.commit(changed); ledger.close()
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        try Self.seedLegacyDeviceChange(layout)
        let before = try Self.generatedInventory(root)
        try Self.require((try? await workspace.legacyIdentityChoiceAfterExplicitRequest()) == nil)
        try Self.require(try Self.generatedInventory(root) == before)
        await workspace.stopAndDrain()
    }

    @Test func ordinaryRepairGraphStillRefusesColdPendingReceive() async throws {
        let root = try Self.caseRoot("ordinary-repair-cold-pending")
        _ = try await Self.interruptedReceive(in: root, payloadBytes: 3)
        let layout = try Self.layout(in: root)
        let before = try Self.generatedInventory(root)
        let refused = try await Task.detached {
            guard let file = try ConnectionWorkspaceDisk.File.open(layout.connectionWorkspaceRecordDirectory,
                writing: false) else { throw Failure.scope }
            defer { file.close() }
            do {
                let graph = try ConnectionWorkspaceRepairGraph.open(paths: .init(layout), record: file.snapshot)
                graph.close()
                return false
            } catch ConnectionWorkspaceFailure.reviewRequired { return true }
        }.value
        try Self.require(refused)
        try Self.require(try Self.generatedInventory(root) == before)
    }

    @Test func legacyColdReceiveStaleChoiceAndInterruptedPublicationRemainReviewable() async throws {
        let staleRoot = try Self.caseRoot("legacy-cold-stale-choice")
        let staleShared = try await Self.interruptedReceive(in: staleRoot, payloadBytes: 0)
        let staleLayout = try Self.layout(in: staleRoot)
        let staleWorkspace = try ConnectionWorkspace(layout: staleLayout)
        try Self.seedLegacyDeviceChange(staleLayout)
        let stale = try await staleWorkspace.legacyIdentityChoiceAfterExplicitRequest()
        guard let editors = try RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.open(staleShared.editors, writing: true) else {
            throw Failure.scope
        }
        var changed = editors.snapshot; changed.revision += 1
        try editors.commit(changed); editors.close()
        let beforeStale = try Self.generatedInventory(staleRoot)
        do { try await staleWorkspace.reconcileLegacyIdentity(stale); throw Failure.assertion(#line) }
        catch ConnectionWorkspaceFailure.changed { }
        try Self.require(try Self.generatedInventory(staleRoot) == beforeStale)
        let fresh = try await staleWorkspace.legacyIdentityChoiceAfterExplicitRequest()
        try await staleWorkspace.reconcileLegacyIdentity(fresh)
        await staleWorkspace.stopAndDrain()

        let interruptedRoot = try Self.caseRoot("legacy-cold-interrupted-publication")
        let interruptedShared = try await Self.interruptedReceive(in: interruptedRoot, payloadBytes: 7)
        let interruptedLayout = try Self.layout(in: interruptedRoot)
        let interruptedWorkspace = try ConnectionWorkspace(layout: interruptedLayout)
        try Self.seedLegacyDeviceChange(interruptedLayout)
        let choice = try await interruptedWorkspace.legacyIdentityChoiceAfterExplicitRequest()
        let before = try Self.generatedInventory(interruptedRoot)
        ConnectionWorkspaceRebindQualification.shared.set { _ in throw Failure.injected }
        defer { ConnectionWorkspaceRebindQualification.shared.set(nil) }
        do { try await interruptedWorkspace.reconcileLegacyIdentity(choice); throw Failure.assertion(#line) }
        catch Failure.injected { }
        ConnectionWorkspaceRebindQualification.shared.set(nil)
        let afterFault = try Self.generatedInventory(interruptedRoot)
        try Self.require(before.filter { !$0.key.contains("connection-workspace-location") } ==
                         afterFault.filter { !$0.key.contains("connection-workspace-location") })
        let resume = try await interruptedWorkspace.legacyIdentityChoiceAfterExplicitRequest()
        try Self.require(resume.action == .resume)
        try await interruptedWorkspace.reconcileLegacyIdentity(resume)
        let afterResume = try Self.generatedInventory(interruptedRoot)
        try Self.require(before.filter { !$0.key.contains("connection-workspace-location") } ==
                         afterResume.filter { !$0.key.contains("connection-workspace-location") })
        try Self.require(FileManager.default.fileExists(atPath: interruptedShared.bodies.path))
        await interruptedWorkspace.stopAndDrain()
    }

    @Test func unchangedLegacyWorkspaceStillAdmitsWithoutMigration() async throws {
        let root = try Self.caseRoot("legacy-same-device")
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        _ = try await workspace.prepareForConnect()
        try Self.seedLegacyDeviceChange(layout, deviceOffset: 0)
        try Self.require(try await workspace.inspect().state == .active)
        _ = try await workspace.prepareForConnect()
        await workspace.stopAndDrain()
    }

    @Test func interruptedLegacyIdentityPublicationRequiresExplicitResume() async throws {
        let root = try Self.caseRoot("legacy-rebind-interrupted")
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        _ = try await workspace.prepareForConnect()
        try Self.seedLegacyDeviceChange(layout)
        let first = try await workspace.legacyIdentityChoiceAfterExplicitRequest()
        ConnectionWorkspaceRebindQualification.shared.set { _ in throw Failure.injected }
        do { try await workspace.reconcileLegacyIdentity(first); throw Failure.assertion(#line) }
        catch Failure.injected { }
        ConnectionWorkspaceRebindQualification.shared.set(nil)
        do { _ = try await workspace.prepareForConnect(); throw Failure.assertion(#line) }
        catch RemoteSettingsFailure.recoveryRequired { }
        let resume = try await workspace.legacyIdentityChoiceAfterExplicitRequest()
        try Self.require(resume.action == .resume)
        try await workspace.reconcileLegacyIdentity(resume)
        try Self.require(try await workspace.inspect().state == .active)
        _ = try await workspace.prepareForConnect()
        await workspace.stopAndDrain()
    }

    @Test func legacyIdentityReconciliationRefusesChangedGraphWithoutWriting() async throws {
        let root = try Self.caseRoot("legacy-rebind-foreign")
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        _ = try await workspace.prepareForConnect()
        try Self.seedLegacyDeviceChange(layout)
        guard let file = try ConnectionWorkspaceDisk.File.open(layout.connectionWorkspaceRecordDirectory,
                                                               writing: true, existingOnly: true) else {
            throw Failure.scope
        }
        var changed = file.snapshot
        changed.graph["ledger"] = changed.graph["editors"]
        let bytes = try changed.encoded()
        try file.commit(changed); file.close()
        do { _ = try await workspace.legacyIdentityChoiceAfterExplicitRequest(); throw Failure.assertion(#line) }
        catch ConnectionWorkspaceFailure.changed { }
        guard let unchanged = try ConnectionWorkspaceDisk.File.open(layout.connectionWorkspaceRecordDirectory,
                                                                    writing: false) else { throw Failure.scope }
        try Self.require(try unchanged.snapshot.encoded() == bytes && unchanged.pending == nil)
        unchanged.close()
        await workspace.stopAndDrain()
    }

    @Test func stableWorkspaceIdentityRefusesForeignVolumeUUID() async throws {
        let root = try Self.caseRoot("stable-volume-foreign")
        let layout = try Self.layout(in: root)
        let workspace = try ConnectionWorkspace(layout: layout)
        _ = try await workspace.prepareForConnect()
        guard let file = try ConnectionWorkspaceDisk.File.open(layout.connectionWorkspaceRecordDirectory,
                                                               writing: true, existingOnly: true) else {
            throw Failure.scope
        }
        var changed = file.snapshot
        guard let ledger = changed.graph["ledger"] else { throw Failure.scope }
        let foreign = UUID()
        try Self.require(foreign != ledger.volume)
        changed.graph["ledger"] = ledger.rebased(device: ledger.device, volume: foreign)
        try file.commit(changed); file.close()
        do { _ = try await workspace.inspect(); throw Failure.assertion(#line) }
        catch ConnectionWorkspaceFailure.changed { }
        do { _ = try await workspace.prepareForConnect(); throw Failure.assertion(#line) }
        catch ConnectionWorkspaceFailure.changed { }
        await workspace.stopAndDrain()
    }

    private static func requireDevice(_ identity: ConnectionWorkspaceIdentity?) throws -> Int32 {
        guard let identity else { throw Failure.scope }; return identity.device
    }

    private static func seedLegacyDeviceChange(_ layout: ApplicationStorageLayout,
                                               deviceOffset: Int32 = 1) throws {
        guard let file = try ConnectionWorkspaceDisk.File.open(layout.connectionWorkspaceRecordDirectory,
                                                               writing: true, existingOnly: true) else {
            throw Failure.scope
        }
        defer { file.close() }
        var old = file.snapshot
        let priorDevice = try requireDevice(old.earlier) &+ deviceOffset
        old.format = 1; old.protocolIdentity = "traverse-persistent-connections-v1"
        old.earlier = old.earlier?.rebased(device: priorDevice, volume: nil)
        old.earlierLock = old.earlierLock?.rebased(device: priorDevice, volume: nil)
        old.graph = old.graph.mapValues { $0.rebased(device: priorDevice, volume: nil) }
        try file.commit(old)
    }

    @Test func processExitResumesRecordedRemoveAndPublishedRepair() async throws {
        let retirement = try Self.caseRoot("retirement-process-exit")
        let remove = try Self.child("retire-exit", "retirement-process-exit")
        try await Self.waitFor(remove)
        try Self.require(remove.terminationReason == .exit && remove.terminationStatus == 85)
        let retired = try ConnectionWorkspace(layout: Self.layout(in: retirement))
        let pending = try await retired.retainedDocumentsAfterExplicitRequest()
        try Self.require(pending.count == 1 && pending[0].removalPending)
        try await retired.removeRetainedDocument(pending[0])
        try Self.require(try await retired.retainedDocumentsAfterExplicitRequest().isEmpty)
        try Self.require(try await retired.recoveryChoicesAfterExplicitRequest().isEmpty)
        await retired.stopAndDrain()

        let repairRoot = try Self.caseRoot("repair-process-exit")
        let repair = try Self.child("repair-exit", "repair-process-exit")
        try await Self.waitFor(repair)
        try Self.require(repair.terminationReason == .exit && repair.terminationStatus == 85)
        let resumed = try ConnectionWorkspace(layout: Self.layout(in: repairRoot))
        let choice = try await resumed.repairChoiceAfterExplicitRequest()
        try Self.require(choice.action == .resume)
        try await resumed.repairConnectionStorage(choice)
        try Self.require(try await resumed.inspect().state == .active)
        let versions = try await resumed.recoveryChoicesAfterExplicitRequest()
        try Self.require(versions.count == 1)
        try Self.require(try await versions[0].readVersion(.before).encoded == Data("before\n".utf8))
        try Self.require(try await versions[0].readVersion(.edited).encoded == Data("after\n".utf8))
        await resumed.stopAndDrain()
    }

    @Test func separateProcessOwnerPinsBlockRemoveAndRepairUntilDrain() async throws {
        let editorRoot = try Self.caseRoot("editor-process")
        let editor = try Self.child("editor-hold", "editor-process")
        try await Self.waitFor(editor, ready: editorRoot.appendingPathComponent("ready"))
        let editorLayout = try Self.layout(in: editorRoot)
        let editorWorkspace = try ConnectionWorkspace(layout: editorLayout)
        try Self.require(try await editorWorkspace.retainedDocumentsAfterExplicitRequest().isEmpty)
        try Self.require(rename(editorLayout.smbDirectory.path,
            editorRoot.appendingPathComponent("retained-earlier", isDirectory: true).path) == 0)
        do {
            _ = try await editorWorkspace.repairChoiceAfterExplicitRequest()
            throw Failure.assertion(#line)
        } catch let issue as ConnectionWorkspaceFailure { try Self.require(issue == .busy) }
        try Self.mark(editorRoot.appendingPathComponent("drain"))
        try await Self.waitFor(editor)
        try Self.require(editor.terminationReason == .exit && editor.terminationStatus == 0)
        let editorRepair = try await editorWorkspace.repairChoiceAfterExplicitRequest()
        try Self.require(editorRepair.action == .repair)
        try await editorWorkspace.repairConnectionStorage(editorRepair)
        try Self.require(try await editorWorkspace.inspect().state == .active)
        let editorVersions = try await editorWorkspace.recoveryChoicesAfterExplicitRequest()
        try Self.require(editorVersions.count == 1)
        try Self.require(try await editorVersions[0].readVersion(.before).encoded == Data("before\n".utf8))
        try Self.require(try await editorVersions[0].readVersion(.edited).encoded == Data("after\n".utf8))
        await editorWorkspace.stopAndDrain()

        let removeRoot = try Self.caseRoot("viewer-remove")
        let removeFixture = try await Fixture.retained(in: removeRoot)
        try await removeFixture.releasePin()
        let staleable = try await removeFixture.workspace.retainedDocumentsAfterExplicitRequest()
        try Self.require(staleable.count == 1)
        let viewer = try Self.child("viewer-hold", "viewer-remove")
        try await Self.waitFor(viewer, ready: removeRoot.appendingPathComponent("ready"))
        do {
            try await removeFixture.workspace.removeRetainedDocument(staleable[0])
            throw Failure.assertion(#line)
        } catch SFTPSharedBudgetFailure.busy { }
        try Self.mark(removeRoot.appendingPathComponent("drain"))
        try await Self.waitFor(viewer)
        try Self.require(viewer.terminationReason == .exit && viewer.terminationStatus == 0)
        let choices = try await removeFixture.workspace.retainedDocumentsAfterExplicitRequest()
        try Self.require(choices.count == 1)
        try await removeFixture.workspace.removeRetainedDocument(choices[0])
        try Self.require(try await removeFixture.workspace.retainedDocumentsAfterExplicitRequest().isEmpty)
        try Self.require(try await removeFixture.workspace.recoveryChoicesAfterExplicitRequest().isEmpty)
        await removeFixture.drain()

        let repairRoot = try Self.caseRoot("viewer-repair")
        let repairFixture = try await Fixture.retained(in: repairRoot)
        try await repairFixture.releasePin()
        let repairViewer = try Self.child("viewer-repair", "viewer-repair")
        try await Self.waitFor(repairViewer, ready: repairRoot.appendingPathComponent("ready"))
        try Self.require(rename(repairFixture.layout.smbDirectory.path,
            repairRoot.appendingPathComponent("retained-earlier", isDirectory: true).path) == 0)
        do {
            _ = try await repairFixture.workspace.repairChoiceAfterExplicitRequest()
            throw Failure.assertion(#line)
        } catch let issue as ConnectionWorkspaceFailure { try Self.require(issue == .busy) }
        try Self.mark(repairRoot.appendingPathComponent("drain"))
        try await Self.waitFor(repairViewer)
        try Self.require(repairViewer.terminationReason == .exit && repairViewer.terminationStatus == 0)
        let fresh = try await repairFixture.workspace.repairChoiceAfterExplicitRequest()
        try Self.require(fresh.action == .repair)
        try await repairFixture.workspace.repairConnectionStorage(fresh)
        try Self.require(try await repairFixture.workspace.inspect().state == .active)
        let repairVersions = try await repairFixture.workspace.recoveryChoicesAfterExplicitRequest()
        try Self.require(repairVersions.count == 1)
        try Self.require(try await repairVersions[0].readVersion(.before).encoded == Data("before\n".utf8))
        try Self.require(try await repairVersions[0].readVersion(.edited).encoded == Data("after\n".utf8))
        await repairFixture.drain()
    }

    @Test func droppedViewerPinRemainsQuarantinedUntilChildExits() async throws {
        let root = try Self.caseRoot("viewer-dropped")
        let fixture = try await Fixture.retained(in: root)
        do {
            try await fixture.releasePin()
            let initial = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
            try Self.require(initial.count == 1 && !initial[0].removalPending)
            let child = try Self.child("viewer-drop", "viewer-dropped")
            try await Self.waitFor(child, ready: root.appendingPathComponent("ready"))
            do {
                try await fixture.workspace.removeRetainedDocument(initial[0])
                throw Failure.assertion(#line)
            } catch SFTPSharedBudgetFailure.busy { }
            try Self.mark(root.appendingPathComponent("drain"))
            try await Self.waitFor(child)
            try Self.require(child.terminationReason == .exit && child.terminationStatus == 0)
            let available = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
            try Self.require(available.count == 1 && !available[0].removalPending)
            try await fixture.workspace.removeRetainedDocument(available[0])
            try Self.require(try await fixture.workspace.retainedDocumentsAfterExplicitRequest().isEmpty)
            try Self.require(try await fixture.workspace.recoveryChoicesAfterExplicitRequest().isEmpty)
        } catch { await fixture.drain(); throw error }
        await fixture.drain()
    }

    @Test func finalOwnerExclusiveRaceRefusesBeforeDurableIntent() async throws {
        let root = try Self.caseRoot("owner-exclusive-race")
        let fixture = try await Fixture.retained(in: root)
        var raceChild: Process?
        do {
            try await fixture.releasePin()
            let choices = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
            try Self.require(choices.count == 1 && choices[0].copyCount == 2 && !choices[0].removalPending)
            let beforeState = try Self.generatedInventory(fixture.layout.stateDirectory)
            let beforeCache = try Self.generatedInventory(fixture.layout.cacheDirectory)
            let child = try Self.child("owner-race-hold", "owner-exclusive-race")
            raceChild = child
            try await Self.waitFor(child, ready: root.appendingPathComponent("ready"))
            SFTPRetainedRemovalQualification.shared.set { stage in
                if stage == .beforeBodyExclusive {
                    try Self.mark(root.appendingPathComponent("arm"))
                    try Self.waitForMarker(root.appendingPathComponent("held"), seconds: 8)
                }
            }
            var refused = false
            do { try await fixture.workspace.removeRetainedDocument(choices[0]) }
            catch SFTPSharedBudgetFailure.busy { refused = true }
            SFTPRetainedRemovalQualification.shared.set(nil)
            try Self.require(refused && child.isRunning)
            try Self.waitForMarker(root.appendingPathComponent("arm"), seconds: 1)
            try Self.waitForMarker(root.appendingPathComponent("held"), seconds: 1)
            try Self.require(try Self.generatedInventory(fixture.layout.stateDirectory) == beforeState)
            try Self.require(try Self.generatedInventory(fixture.layout.cacheDirectory) == beforeCache)
            let unchanged = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
            try Self.require(unchanged.isEmpty)
            try Self.mark(root.appendingPathComponent("drain"))
            try await Self.waitFor(child)
            try Self.require(child.terminationReason == .exit && child.terminationStatus == 0)
            raceChild = nil
            let fresh = try await fixture.workspace.retainedDocumentsAfterExplicitRequest()
            try Self.require(fresh.count == 1 && fresh[0].copyCount == 2 && !fresh[0].removalPending)
            try await fixture.workspace.removeRetainedDocument(fresh[0])
            try Self.require(try await fixture.workspace.retainedDocumentsAfterExplicitRequest().isEmpty)
            try Self.require(try await fixture.workspace.recoveryChoicesAfterExplicitRequest().isEmpty)
            let ledger = try await Task.detached { [layout = fixture.layout] in
                guard let file = try RemoteSettingsFile<SFTPSharedBudgetDocument>.open(
                    layout.persistentConnectionWorkspaceDirectory.appendingPathExtension("original-budget"),
                    writing: false, retainedRetirement: .inspectCommittedLedger) else { throw Failure.assertion(#line) }
                defer { file.close() }; return file.snapshot
            }.value
            try Self.require((ledger.retirements ?? []).isEmpty && ledger.bodies.count == 2
                && ledger.bodies.allSatisfy { $0.phase == .removed })
        } catch {
            SFTPRetainedRemovalQualification.shared.set(nil)
            if let raceChild {
                try? Self.mark(root.appendingPathComponent("drain"))
                try? await Self.waitFor(raceChild)
                if raceChild.isRunning {
                    _ = kill(raceChild.processIdentifier, SIGKILL)
                    raceChild.waitUntilExit()
                }
            }
            await fixture.drain()
            throw error
        }
        await fixture.drain()
    }
}
#endif
