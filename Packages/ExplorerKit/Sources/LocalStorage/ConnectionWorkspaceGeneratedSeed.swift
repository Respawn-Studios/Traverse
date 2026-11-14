#if DEBUG
import CryptoKit
import Darwin
import ExplorerCore
import FileOperations
import Foundation

/// Only the compiled checkout source path can name generated development cases.
internal enum LocalStorageGeneratedCheckoutOrigin {
    static let developmentCases: URL? = {
        let sourcePath: String = #filePath
        guard sourcePath.hasPrefix("/") else { return nil }
        let source = URL(fileURLWithPath: sourcePath)
        var checkout = source
        for _ in 0..<5 { checkout.deleteLastPathComponent() }
        guard source.path == source.standardizedFileURL.path,
              source.path == checkout.appendingPathComponent(
                "Packages/ExplorerKit/Sources/LocalStorage/ConnectionWorkspaceGeneratedSeed.swift").path else { return nil }
        return checkout.appendingPathComponent(".build/traverse-development", isDirectory: true)
    }()
}

/// DEBUG-only source candidate for the LocalStorage target. This composes the
/// same real owners used by TraverseSecurityStorageControls; no wire peer,
/// Keychain, caller-created catalog row, or private path escapes the adapter.
@_spi(Qualification) public struct ConnectionWorkspaceGeneratedCase: Sendable, CustomDebugStringConvertible {
    let root: URL, layout: ApplicationStorageLayout
    public var debugDescription: String { "<bounded generated connection case>" }

    /// Lexical only. Actual private APFS scope and capacity are checked on the
    /// worker before every operation, including after the real seed commits.
    public init(root: URL, layout: ApplicationStorageLayout) throws {
        guard let owner = LocalStorageGeneratedCheckoutOrigin.developmentCases,
              root.isFileURL, root == root.standardizedFileURL,
              root.deletingLastPathComponent() == owner,
              let id = UUID(uuidString: root.lastPathComponent), id.uuidString == root.lastPathComponent,
              layout.channel == .portable,
              layout.stateDirectory.deletingLastPathComponent() == root.appendingPathComponent("state", isDirectory: true).appendingPathComponent("ApplicationSupport", isDirectory: true),
              layout.cacheDirectory.deletingLastPathComponent() == root.appendingPathComponent("state", isDirectory: true).appendingPathComponent("Caches", isDirectory: true),
              layout.stateDirectory.lastPathComponent == "local.macexplorer.development.gatea",
              layout.cacheDirectory.lastPathComponent == "local.macexplorer.development.gatea",
              layout.smbDirectory == layout.cacheDirectory.appendingPathComponent("smb-browsing", isDirectory: true)
        else { throw ConnectionWorkspaceFailure.unsafe }
        self.root = root; self.layout = layout
    }

    func validate() throws {
        guard !Thread.isMainThread, root.resolvingSymlinksInPath() == root else { throw ConnectionWorkspaceFailure.unsafe }
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw ConnectionWorkspaceFailure.unsafe }; defer { Darwin.close(fd) }
        _ = try ConnectionWorkspaceDisk.identity(fd, directory: true)
        var rootFacts = stat()
        guard fstat(fd, &rootFacts) == 0 else { throw ConnectionWorkspaceFailure.unsafe }
        var usage = (bytes: UInt64(0), entries: 0)
        func walk(_ directory: Int32, relative: String) throws {
            for name in try DownloadDisk.names(directory, maximum: 1024) {
                let path = relative.isEmpty ? name : relative + "/" + name
                var facts = stat()
                guard fstatat(directory, name, &facts, AT_SYMLINK_NOFOLLOW) == 0,
                      facts.st_uid == geteuid(), facts.st_dev == rootFacts.st_dev,
                      facts.st_mode & S_IFMT != S_IFLNK, facts.st_size >= 0,
                      facts.st_blocks >= 0, facts.st_flags == 0 else { throw ConnectionWorkspaceFailure.unsafe }
                usage.entries += 1
                guard facts.st_size <= 64 << 20, facts.st_blocks <= (64 << 20) / 512 else {
                    throw ConnectionWorkspaceFailure.capacity
                }
                let size = UInt64(max(facts.st_size, facts.st_blocks * 512))
                guard size <= 64 << 20, usage.bytes <= (64 << 20) - size,
                      usage.entries <= 1024 else { throw ConnectionWorkspaceFailure.capacity }
                usage.bytes += size
                if facts.st_mode & S_IFMT == S_IFDIR {
                    guard facts.st_mode & 0o7777 == 0o700 else { throw ConnectionWorkspaceFailure.unsafe }
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
                    guard child >= 0 else { throw ConnectionWorkspaceFailure.unsafe }
                    defer { Darwin.close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0,
                          opened.st_dev == facts.st_dev,
                          opened.st_ino == facts.st_ino else { throw ConnectionWorkspaceFailure.changed }
                    try walk(child, relative: path)
                } else {
                    // The App's sole selected, published Local Text Copy is
                    // deliberately user-readable (BoundedTextFileProducer:
                    // 0644). Private workspace, history, and backend leaves
                    // remain 0600. A different export name or location must
                    // not widen this exception.
                    let publishedCopy = path == "state/Exports/Generated Retained Copy.txt"
                    let expectedMode: mode_t = publishedCopy ? 0o644 : 0o600
                    guard facts.st_mode & S_IFMT == S_IFREG, facts.st_nlink == 1,
                          facts.st_mode & 0o7777 == expectedMode else { throw ConnectionWorkspaceFailure.unsafe }
                }
            }
        }
        try walk(fd, relative: "")
    }
}

/// Closed qualification-only failure surface; no source error description,
/// path, host, or body content crosses the App's JSON boundary.
@_spi(Qualification) public struct ConnectionWorkspaceGeneratedSeedFailure: Error, Sendable {
    public enum Stage: String, Sendable {
        case scope
        case metadataOwner = "metadata-owner"
        case storageOwner = "storage-owner"
        case initialBody = "initial-body"
        case editedSnapshot = "edited-snapshot"
        case inPlaceAttempt = "inplace-attempt"
        case interruptedWriteFacts = "interrupted-write-facts"
        case retainedEditedSnapshot = "retained-edited-snapshot"
        case durableRecoveryGraph = "durable-recovery-graph"
        case finalScope = "final-scope"
    }
    public let stage: Stage
    init(_ stage: Stage) { self.stage = stage }
}

@_spi(Qualification) public final class ConnectionWorkspaceGeneratedSeed: @unchecked Sendable, CustomDebugStringConvertible {
    private static let before = Data("before\n".utf8), edited = Data("after\n".utf8)
    public let beforeSHA256: String, editedSHA256: String
    public let beforeBytes: Int, editedBytes: Int
    public var debugDescription: String { "<opaque generated retained document seed>" }
    private let generatedCase: ConnectionWorkspaceGeneratedCase
    private let pin: SFTPOriginalLifetimePin
    private let state = NSLock()
    private var closed = false

    fileprivate init(generatedCase: ConnectionWorkspaceGeneratedCase, pin: SFTPOriginalLifetimePin,
                     before: Data, edited: Data) {
        self.generatedCase = generatedCase; self.pin = pin
        beforeSHA256 = Self.sha(before); editedSHA256 = Self.sha(edited)
        beforeBytes = before.count; editedBytes = edited.count
    }

    fileprivate static func sha(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    /// The caller must await this before a cold discovery or UI loader. The
    /// real lifetime SH remains held until the owner reports an actual drain.
    public func closeAndDrain() async -> Bool {
        let done = await pin.closeAndDrain()
        if done { state.withLock { closed = true } }
        return done
    }

    /// Generated expectations are fixed in this reviewed source. A fresh App
    /// process can obtain them without reading a catalog or user file.
    public static func expectedText() throws -> (before: TextDocumentValue, edited: TextDocumentValue,
        beforeSHA256: String, editedSHA256: String, beforeBytes: Int, editedBytes: Int) {
        (try TextDocumentValue.original(before), try TextDocumentValue.original(edited),
         sha(before), sha(edited), before.count, edited.count)
    }

    /// The pre-seed App assertion checks the actual durable location and
    /// graph without opening either retained body reader.
    public static func assertActiveGraph(generatedCase: ConnectionWorkspaceGeneratedCase) async throws {
        try await Task.detached { try generatedCase.validate() }.value
        let workspace = try ConnectionWorkspace(layout: generatedCase.layout)
        do {
            guard try await workspace.inspect().state == .active else { throw ConnectionWorkspaceFailure.changed }
        } catch {
            await workspace.stopAndDrain()
            throw error
        }
        await workspace.stopAndDrain()
        try await Task.detached { try generatedCase.validate() }.value
    }

    /// Fresh read-only workspace/graph discovery and both actual pinned body
    /// readers; no raw path, catalog document or invented authority is exposed.
    public static func assertColdGraph(generatedCase: ConnectionWorkspaceGeneratedCase) async throws {
        try await Task.detached { try generatedCase.validate() }.value
        let workspace = try ConnectionWorkspace(layout: generatedCase.layout)
        do {
            guard try await workspace.inspect().state == .active else { throw ConnectionWorkspaceFailure.changed }
            let choices = try await workspace.recoveryChoicesAfterExplicitRequest()
            guard choices.count == 1, choices[0].availableVersions == [.before, .edited] else {
                throw ConnectionWorkspaceFailure.changed
            }
            for (version, expected, bytes) in [(SFTPInPlaceRecoveryVersion.before, sha(before), before.count),
                                               (.edited, sha(edited), edited.count)] {
                let viewed = try await choices[0].readPinnedVersion(version)
                let body = viewed.contents.encoded
                let closedViewer = await viewed.closeAndDrain()
                guard closedViewer, body.count == bytes, Self.sha(body) == expected else {
                    throw ConnectionWorkspaceFailure.changed
                }
            }
            guard try await workspace.retainedDocumentsAfterExplicitRequest().count == 1 else {
                throw ConnectionWorkspaceFailure.changed
            }
        } catch {
            await workspace.stopAndDrain()
            throw error
        }
        await workspace.stopAndDrain()
        try await Task.detached { try generatedCase.validate() }.value
    }

    /// Same-process convenience after the actual seed pin has drained.
    public func assertColdGraph() async throws {
        guard state.withLock({ closed }) else { throw ConnectionWorkspaceFailure.busy }
        try await Self.assertColdGraph(generatedCase: generatedCase)
    }

    /// Accepts only the actual ConnectionWorkspaceAdmission minted by
    /// prepareForConnect. A public SMBTemporaryStorage URL cannot substitute.
    public static func seedAfterActualAdmission(_ admission: ConnectionWorkspaceAdmission,
                                                generatedCase: ConnectionWorkspaceGeneratedCase) async throws -> ConnectionWorkspaceGeneratedSeed {
        let configuration = admission.metadataStorage
        guard let witness = configuration.workspaceWitness, witness.access == .connection,
              witness.paths == ConnectionWorkspacePaths(generatedCase.layout),
              witness.record.isActive else { throw ConnectionWorkspaceGeneratedSeedFailure(.scope) }
        do {
            try await Task.detached {
                try generatedCase.validate()
                let held = try witness.begin(); defer { held.close() }
                try held.validateCurrent()
            }.value
        } catch { throw ConnectionWorkspaceGeneratedSeedFailure(.scope) }

        let before = Self.before, edited = Self.edited
        let session = UUID()
        let context: SFTPVerifiedSessionContext
        do { context = try Self.context() }
        catch { throw ConnectionWorkspaceGeneratedSeedFailure(.scope) }
        let metadata: SMBCatalogFiles
        do {
            metadata = try await Task.detached {
                try SMBCatalogFiles(storage: configuration, purpose: .originalPending(session: session))
            }.value
        } catch { throw ConnectionWorkspaceGeneratedSeedFailure(.metadataOwner) }
        var pin: SFTPOriginalLifetimePin?
        var snapshot: SFTPEditedTextSnapshot?
        var stage: ConnectionWorkspaceGeneratedSeedFailure.Stage = .storageOwner
        do {
            let owner = try await Task.detached {
                try SFTPOriginalStorageOwner.bindOnMetadataExecutor(files: metadata, session: session, context: context)
            }.value
            stage = .initialBody
            let storage = try SFTPInPlaceWorkingCopyStorage(metadataStorage: configuration,
                catalogProbe: nil, journalProbe: nil)
            let generation = UUID()
            let selection = try SFTPDownloadSelection(generation: generation, row: .init(observation: 1,
                entry: .init(name: SFTPRemoteName(Data("file.txt".utf8)), logicalBytes: 7,
                    modifiedSeconds: 77, permissions: 0o100600)))
            let job = try SFTPOriginalReadJob(session: session, selection: selection, context: context,
                directory: storage.layout.bodies, catalog: storage.catalog, storageOwner: owner, strategy: .inPlaceV1)
            _ = try await job.beginCommand(catalogRevision: 1)
            var header = SFTPWire.token(selection.request); header.append(SFTPWire.token(generation))
            for (value, count) in [(UInt64(7), 8), (77, 4), (0o100600, 4),
                                   (UInt64(getuid()), 4), (UInt64(getgid()), 4)] {
                SFTPWire.number(value, bytes: count, into: &header)
            }
            try SFTPWire.field(Data("/generated/file.txt".utf8), into: &header)
            try await job.header(header)
            var chunk = SFTPWire.token(selection.request); SFTPWire.number(0, bytes: 8, into: &chunk)
            try SFTPWire.field(before, into: &chunk); try await job.chunk(chunk)
            let digest = Data(SHA256.hash(data: before))
            var seal = SFTPWire.token(selection.request); seal.append(digest)
            SFTPWire.number(UInt64(before.count), bytes: 8, into: &seal)
            _ = try await job.acceptance(seal)
            var remoteAdmission = SFTPWire.token(selection.request); remoteAdmission.append(SFTPWire.token(UUID()))
            SFTPWire.number(1, bytes: 8, into: &remoteAdmission)
            remoteAdmission.append(digest); remoteAdmission.append(contentsOf: [1, 1, 1])
            let baseline = try await job.admittedInPlace(remoteAdmission)
            pin = baseline.lifetimePin
            stage = .editedSnapshot
            snapshot = try await storage.edits.stageInPlace(contents: TextDocumentValue.original(edited),
                editorGeneration: UUID(), from: baseline)
            guard let snapshot else { throw ConnectionWorkspaceFailure.unsafe }
            stage = .inPlaceAttempt
            let attempt = try await SFTPInPlaceAttempt.prepare(baseline: baseline, snapshot: snapshot,
                session: owner.session, context: context, journal: storage.journal,
                revision: try await storage.journal.inspect().revision)
            stage = .interruptedWriteFacts
            try await Task.detached {
                _ = try attempt.command()
                var source = SFTPWire.token(attempt.record.id); SFTPWire.number(0, bytes: 8, into: &source)
                SFTPWire.number(UInt64(edited.count), bytes: 4, into: &source)
                _ = try attempt.sourceOnSessionExecutor(source)
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
            }.value
            stage = .retainedEditedSnapshot
            let removed = await snapshot.closeAndDrain()
            guard !removed, snapshot.retainedForReview else {
                throw ConnectionWorkspaceGeneratedSeedFailure(.retainedEditedSnapshot)
            }
            stage = .durableRecoveryGraph
            try await Self.requireInterruptedSaveGraph(storage: storage, owner: owner,
                editorID: baseline.editorID, record: attempt.record)
            _ = await Task.detached { metadata.finish(clean: false) }.value
            guard let pin else { throw ConnectionWorkspaceGeneratedSeedFailure(.finalScope) }
            stage = .finalScope
            try await Task.detached { try generatedCase.validate() }.value
            return .init(generatedCase: generatedCase, pin: pin, before: before, edited: edited)
        } catch {
            if let snapshot { _ = await snapshot.closeAndDrain() }
            _ = await Task.detached { metadata.finish(clean: false) }.value
            if let pin { _ = await pin.closeAndDrain() }
            throw (error as? ConnectionWorkspaceGeneratedSeedFailure)
                ?? ConnectionWorkspaceGeneratedSeedFailure(stage)
        }
    }

    /// The expected false from closeAndDrain means publication was retained,
    /// so require the exact durable uncertainty graph before minting a seed.
    /// This is metadata-only; it does not open either body payload reader.
    private static func requireInterruptedSaveGraph(storage: SFTPInPlaceWorkingCopyStorage,
        owner: SFTPOriginalStorageOwner, editorID: UUID, record: SFTPInPlaceRecord) async throws {
        let planned = Array(try record.plan.prefix(2))
        guard planned.count == 2, planned[0].kind == .source,
              planned[1].kind == .write, UInt64(planned[1].count) == record.edited.logicalBytes else {
            throw ConnectionWorkspaceGeneratedSeedFailure(.durableRecoveryGraph)
        }
        let saves = try await storage.journal.inspect()
        guard saves.records.count == 1, let saved = saves.records.first,
              saved.id == record.id, saved.session == owner.session,
              saved.baseline == record.baseline, saved.edited == record.edited,
              saved.requested == planned, saved.acknowledged == [planned[0]],
              saved.outcome == .recoveryRequired else {
            throw ConnectionWorkspaceGeneratedSeedFailure(.durableRecoveryGraph)
        }
        let editors = try await storage.catalog.inspect()
        guard editors.records.count == 1, let editor = editors.records.first,
              editor.id == editorID, editor.session == owner.session,
              editor.context == record.context, editor.phase == .saveReferenced,
              editor.body == record.baseline,
              editor.recovery == [record.baseline, record.edited],
              editor.journals == [record.id] else {
            throw ConnectionWorkspaceGeneratedSeedFailure(.durableRecoveryGraph)
        }
        try await Task.detached { [layout = storage.layout] in
            let budget = try SFTPSharedBudgetTransaction.open(layout: layout, writing: false)
            defer { budget.close() }
            let document = budget.document
            guard document.budgetID == owner.budgetID,
                  document.poolPhase == .active,
                  document.metadata.count == 1,
                  let metadata = document.metadata.first,
                  metadata.id == owner.catalogID,
                  metadata.session == owner.session,
                  metadata.context == owner.contextDigest,
                  metadata.kind == .original, metadata.phase == .live,
                  document.bodies.count == 2 else {
                throw ConnectionWorkspaceGeneratedSeedFailure(.durableRecoveryGraph)
            }
            for reference in [record.baseline, record.edited] {
                guard document.bodies.filter({ $0.id == reference.id &&
                    $0.owner == metadata.id && $0.phase == .allocated &&
                    $0.expectedBytes == reference.logicalBytes }).count == 1 else {
                    throw ConnectionWorkspaceGeneratedSeedFailure(.durableRecoveryGraph)
                }
            }
        }.value
    }

    private static func context() throws -> SFTPVerifiedSessionContext {
        var key = Data()
        try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key)
        try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
        return .init(host: "generated.example", port: 22, requestedScopeID: 0,
            account: "generated", key: try .init(key), previous: nil, permitsRememberingHost: false)
    }
}

/// Unknown generated earlier-pool leaf. This is a refusal control, never a
/// catalog row, compatibility fence, authority JSON, or cleanup instruction.
@_spi(Qualification) public final class ConnectionWorkspaceGeneratedRefusal: Sendable, CustomDebugStringConvertible {
    public var debugDescription: String { "<opaque generated connection refusal witness>" }
    private let generatedCase: ConnectionWorkspaceGeneratedCase
    private let identity: ConnectionWorkspaceIdentity, stamp: ConnectionWorkspaceStamp
    private let digest: String
    private static let name = "unrecognized-generated-leaf.bin"
    private static let body = Data("TRAVERSE-GENERATED-CONNECTION-REFUSAL-1\n".utf8)
    private init(generatedCase: ConnectionWorkspaceGeneratedCase,
                 identity: ConnectionWorkspaceIdentity, stamp: ConnectionWorkspaceStamp, digest: String) {
        self.generatedCase = generatedCase; self.identity = identity; self.stamp = stamp; self.digest = digest
    }

    public static func installRefusalFixture(generatedCase: ConnectionWorkspaceGeneratedCase) async throws -> Self {
        try await Task.detached {
            try generatedCase.validate()
            let root = Darwin.open(generatedCase.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard root >= 0 else { throw ConnectionWorkspaceFailure.unsafe }; defer { Darwin.close(root) }
            let state = try child(root, "state")
            defer { Darwin.close(state) }
            let caches = try child(state, "Caches")
            defer { Darwin.close(caches) }
            let profile = try child(caches, generatedCase.layout.cacheDirectory.lastPathComponent)
            defer { Darwin.close(profile) }
            let pool = try child(profile, "smb-browsing")
            defer { Darwin.close(pool) }
            let fd = openat(pool, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ConnectionWorkspaceFailure.reviewRequired }; defer { Darwin.close(fd) }
            try DownloadDisk.writeAll(fd, body)
            try ConnectionWorkspaceDisk.sync(fd); try ConnectionWorkspaceDisk.sync(pool)
            var facts = stat()
            guard fstat(fd, &facts) == 0, facts.st_size == Int64(body.count),
                  facts.st_nlink == 1, facts.st_uid == geteuid(),
                  facts.st_mode & 0o7777 == 0o600 else { throw ConnectionWorkspaceFailure.unsafe }
            let value = Self(generatedCase: generatedCase, identity: .init(facts),
                stamp: .init(facts), digest: ConnectionWorkspaceGeneratedSeed.sha(body))
            try generatedCase.validate()
            return value
        }.value
    }

    /// Call after workspace.inspect/prepareForConnect refuses. Read only;
    /// preserves exact byte and inode evidence even if setup added a lock.
    public func assertPreserved() async throws {
        try await Task.detached {
            try self.generatedCase.validate()
            let pool = Darwin.open(self.generatedCase.layout.smbDirectory.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard pool >= 0 else { throw ConnectionWorkspaceFailure.changed }; defer { Darwin.close(pool) }
            let actual = try ConnectionWorkspaceDisk.namedIdentity(pool, Self.name)
            let bytes = try ConnectionWorkspaceDisk.read(pool, Self.name, maximum: 256)
            let fd = openat(pool, Self.name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw ConnectionWorkspaceFailure.changed }; defer { Darwin.close(fd) }
            var facts = stat()
            guard fstat(fd, &facts) == 0, actual == self.identity,
                  ConnectionWorkspaceStamp(facts) == self.stamp,
                  bytes == Self.body,
                  ConnectionWorkspaceGeneratedSeed.sha(bytes) == self.digest else {
                throw ConnectionWorkspaceFailure.changed
            }
        }.value
    }

    private static func child(_ parent: Int32, _ name: String) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw ConnectionWorkspaceFailure.unsafe }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw ConnectionWorkspaceFailure.unsafe }
        do {
            _ = try ConnectionWorkspaceDisk.identity(fd, directory: true)
            try ConnectionWorkspaceDisk.sync(parent)
            return fd
        } catch { Darwin.close(fd); throw error }
    }
}
#endif
