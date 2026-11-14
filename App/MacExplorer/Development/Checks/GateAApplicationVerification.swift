#if DEBUG
import AppKit
import CryptoKit
import Darwin
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

// SOURCE DRAFT ONLY. Not compiled, not run, and no runtime admission is implied.
// A later image must bind a reviewed adapter factory explicitly. A nil factory
// reports DEPENDENCY_UNAVAILABLE; it never manufactures a graph or recovery choice.
@MainActor protocol GateAFixtureAdapter: AnyObject {
    var sourceIdentity: String { get }
    func seedAfterActualAdmission(_ admission: ConnectionWorkspaceAdmission,
        layout: ApplicationStorageLayout, caseRoot: URL) async throws
    func expectedRetainedText(caseRoot: URL) async throws -> GateAExpectedText
    func installRefusalFixture(layout: ApplicationStorageLayout, caseRoot: URL) async throws
    func counters() async throws -> GateABackendCounters
    // Must check the actual owner SH independently of UI flags. No mutation.
    func requireActualReadPin(_ viewed: SFTPInPlaceViewedVersion, held: Bool, caseRoot: URL) async throws
    // Must validate exact graph/fence/record identities and one actual budget.
    func requireActiveGraph(layout: ApplicationStorageLayout, caseRoot: URL) async throws
    // Uses two real production readers; include both calls in bodyReads.
    func requireColdGraph(layout: ApplicationStorageLayout, caseRoot: URL) async throws
    // Must prove original fixture bytes/identities remain, with no second pool.
    func requireRefusalPreserved(layout: ApplicationStorageLayout, caseRoot: URL) async throws
    func closeAndDrain() async throws
}
struct GateAExpectedText: Sendable {
    let before: TextDocumentValue, edited: TextDocumentValue
    let beforeSHA256: String, editedSHA256: String
    let beforeBytes: Int, editedBytes: Int
}
// Instrumented PRODUCTION backend reads only. The harness's no-follow
// snapshots, seed receipts and export readback are separate oracle reads.
// A backend zero must never be reported as all-process zero-body-reading.
struct GateABackendCounters: Sendable, Equatable {
    let bodyReads: Int, payloadValidationReadEntries: Int
    let workerStarts: Int, workerIPC: Int, remoteWrites: Int
    let remoteSaveAcknowledgements: Int, outstandingOwners: Int
}

@MainActor enum GateAApplicationVerification {
    private struct Failure: Error { let stage: String }
    private struct Scope: Sendable {
        let root: URL, phase: String, layout: ApplicationStorageLayout, adapterSchema: String
        let rootIdentity: GateAGeneratedExportOracle.DirectoryIdentity
        static let action = "gate-a-application-runtime-v1"
        static let sourceCase = "1E9A5C2E-CBFE-431A-95FC-E105EE2AE825"
        static func load() throws -> Scope {
            let args = ProcessInfo.processInfo.arguments
            let checks = args.filter { $0.hasPrefix("--check-") }
            func argument(_ flag: String) -> String? {
                guard args.filter({ $0 == flag }).count == 1, let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            guard checks == ["--check-security-connection-workspace"],
                  !args.contains(where: { $0.hasPrefix("--show-") }),
                  args.filter({ $0 == "--verify-ui" }).count == 1,
                  args.filter({ $0 == "--check-security-connection-workspace" }).count == 1,
                  let phase = argument("--gate-a-phase"), ["prepare", "cold", "refusal"].contains(phase),
                  let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "scope-arguments") }
            let root = URL(fileURLWithPath: raw, isDirectory: true)
            let parent = DevelopmentFixturePaths.cases
            guard root.deletingLastPathComponent() == parent, root.resolvingSymlinksInPath() == root,
                  UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                  root.lastPathComponent != sourceCase else { throw Failure(stage: "scope-root") }
            var st = stat()
            guard lstat(root.path, &st) == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  st.st_uid == geteuid(), st.st_mode & 0o777 == 0o700 else { throw Failure(stage: "scope-private-root") }
            // Scope.load runs inside Task.detached. Anchor both marker reads
            // to this validated directory; neither a leaf link nor a special
            // file can redirect the read. At most 16 KiB per marker is read.
            let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw Failure(stage: "scope-root-open") }
            defer { Darwin.close(rootFD) }
            var anchored = stat()
            guard fstat(rootFD, &anchored) == 0, anchored.st_dev == st.st_dev,
                  anchored.st_ino == st.st_ino, anchored.st_uid == geteuid(),
                  anchored.st_mode & 0o777 == 0o700 else { throw Failure(stage: "scope-root-changed") }
            func stable(_ a: stat, _ b: stat) -> Bool {
                a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
                    && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink && a.st_size == b.st_size
                    && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
                    && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
                    && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
                    && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
            }
            func object(_ name: String) throws -> [String: Any] {
                guard ["reservation.json", "gate-a-admission.json"].contains(name) else { throw Failure(stage: "scope-marker-name") }
                var leaf = stat()
                guard fstatat(rootFD, name, &leaf, AT_SYMLINK_NOFOLLOW) == 0,
                      leaf.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      leaf.st_uid == geteuid(), leaf.st_nlink == 1,
                      leaf.st_mode & 0o7777 == 0o600,
                      leaf.st_size > 0, leaf.st_size <= 16384 else { throw Failure(stage: "scope-marker-private-file") }
                let fd = openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw Failure(stage: "scope-marker-open") }
                defer { Darwin.close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, stable(leaf, opened) else { throw Failure(stage: "scope-marker-replaced") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                var bytes = Data()
                while let block = try handle.read(upToCount: min(4096, 16385 - bytes.count)), !block.isEmpty {
                    bytes.append(block)
                    guard bytes.count <= 16384, Int64(bytes.count) <= opened.st_size else { throw Failure(stage: "scope-marker-growth") }
                }
                var after = stat(), currentLeaf = stat()
                guard Int64(bytes.count) == opened.st_size, fstat(fd, &after) == 0,
                      stable(opened, after), fstatat(rootFD, name, &currentLeaf, AT_SYMLINK_NOFOLLOW) == 0,
                      stable(after, currentLeaf) else { throw Failure(stage: "scope-marker-unstable-read") }
                guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure(stage: "scope-marker-json") }
                return result
            }
            let reservation = try object("reservation.json"), admission = try object("gate-a-admission.json")
            guard reservation["packet"] as? String == "traverse-development-v1",
                  reservation["action"] as? String == action,
                  admission["sourceCase"] as? String == sourceCase,
                  admission["phase"] as? String == (phase == "refusal" ? "refusal" : "positive-two-process"),
                  admission["runtimeApproved"] as? Bool == true,
                  admission["maximumLogicalBytes"] as? Int == 64 * 1024 * 1024,
                  admission["maximumEntries"] as? Int == 1024,
                  admission["maximumSeconds"] as? Int == 120,
                  admission["maximumRSSMiB"] as? Int == 384,
                  let adapterIdentity = admission["adapterSchema"] as? String,
                  adapterIdentity == "traverse.gatea.app-bridge.v3" else { throw Failure(stage: "scope-runtime-admission") }
            let layout = try ApplicationStorageLayout(applicationSupport: root.appendingPathComponent("state/ApplicationSupport", isDirectory: true),
                caches: root.appendingPathComponent("state/Caches", isDirectory: true), bundleIdentifier: "local.macexplorer.development.gatea")
            return .init(root: root, phase: phase, layout: layout, adapterSchema: adapterIdentity,
                rootIdentity: .init(anchored))
        }
    }
    private final class CredentialProbe: @unchecked Sendable {
        let lock = NSLock(); private var count = 0
        func hit() { lock.withLock { count += 1 } }
        var calls: Int { lock.withLock { count } }
    }
    @MainActor private final class FocusProbe { var events = 0 }
    @MainActor private final class ConnectionProbe {
        var preflightRoots: [URL] = [], preflightCalls = 0
        var admission: ConnectionWorkspaceAdmission?, admittedCalls = 0, submissions = 0
        var refusals = 0, refusalFailure: ConnectionWorkspaceFailure?
        func receive(_ event: GateAConnectionObservation) {
            switch event {
            case .beforePrepare(let roots): preflightCalls += 1; preflightRoots = roots
            case .admitted(let value): admittedCalls += 1; admission = value
            case .submitted: submissions += 1
            case .refused(let actual): refusals += 1; refusalFailure = actual
            }
        }
    }
    // ORACLE reads: these snapshots intentionally hash generated fixture file
    // bodies, including retained synthetic text. They are bounded/off-main and
    // are not production-backend reads. Refuse links/special files.
    private struct Stamp: Sendable, Equatable {
        let device: UInt64, inode: UInt64, mode: UInt32, size: Int64
        let modifiedSeconds: Int64, modifiedNanos: Int64, hash: String?
    }
    private static func snapshot(_ root: URL) async throws -> [String: Stamp] {
        try await Task.detached {
            var result: [String: Stamp] = [:], logicalBytes: Int64 = 0
            func names(_ anchor: Int32) throws -> [String] {
                let copy = dup(anchor)
                guard copy >= 0 else { throw Failure(stage: "snapshot-directory-dup") }
                guard let directory = fdopendir(copy) else { Darwin.close(copy); throw Failure(stage: "snapshot-directory-open") }
                defer { closedir(directory) }
                var names: [String] = []
                errno = 0
                while let entry = readdir(directory) {
                    let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                        ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                    }
                    if name != "." && name != ".." { names.append(name) }
                    guard names.count <= 1024 else { throw Failure(stage: "snapshot-directory-entry-bound") }
                    errno = 0
                }
                guard errno == 0 else { throw Failure(stage: "snapshot-directory-read") }
                return names.sorted()
            }
            func visit(_ fd: Int32, key: String) throws {
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_uid == geteuid() else { throw Failure(stage: "snapshot-owner") }
                let kind = info.st_mode & mode_t(S_IFMT)
                guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG),
                      kind != mode_t(S_IFREG) || info.st_nlink == 1,
                      result.count < 1024 else { throw Failure(stage: "snapshot-kind-or-bound") }
                var hash: String?
                if kind == mode_t(S_IFREG) {
                    logicalBytes += info.st_size
                    guard info.st_size >= 0, logicalBytes <= 64 * 1024 * 1024 else { throw Failure(stage: "snapshot-byte-bound") }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                    var digest = SHA256(), bytes: Int64 = 0
                    while let block = try handle.read(upToCount: 32768), !block.isEmpty {
                        bytes += Int64(block.count); guard bytes <= info.st_size else { throw Failure(stage: "snapshot-growth") }; digest.update(data: block)
                    }
                    var after = stat(); guard bytes == info.st_size, fstat(fd, &after) == 0,
                        after.st_dev == info.st_dev, after.st_ino == info.st_ino,
                        after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                        after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                        after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                        after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw Failure(stage: "snapshot-changed") }
                    hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
                }
                result[key] = .init(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino),
                    mode: UInt32(info.st_mode), size: kind == mode_t(S_IFDIR) ? 0 : info.st_size,
                    modifiedSeconds: kind == mode_t(S_IFDIR) ? 0 : Int64(info.st_mtimespec.tv_sec),
                    modifiedNanos: kind == mode_t(S_IFDIR) ? 0 : Int64(info.st_mtimespec.tv_nsec), hash: hash)
                if kind == mode_t(S_IFDIR) {
                    for name in try names(fd) {
                        var expected = stat()
                        guard fstatat(fd, name, &expected, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure(stage: "snapshot-child-stat") }
                        let childKind = expected.st_mode & mode_t(S_IFMT)
                        guard childKind == mode_t(S_IFDIR) || childKind == mode_t(S_IFREG) else { throw Failure(stage: "snapshot-child-kind") }
                        let child = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (childKind == mode_t(S_IFDIR) ? O_DIRECTORY : 0))
                        guard child >= 0 else { throw Failure(stage: "snapshot-child-open") }
                        defer { Darwin.close(child) }
                        var actual = stat()
                        guard fstat(child, &actual) == 0, actual.st_dev == expected.st_dev,
                            actual.st_ino == expected.st_ino else { throw Failure(stage: "snapshot-child-replaced") }
                        try visit(child, key: key + "/" + name)
                    }
                }
            }
            let anchor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard anchor >= 0 else { throw Failure(stage: "snapshot-root-open") }
            defer { Darwin.close(anchor) }
            try visit(anchor, key: "."); return result
        }.value
    }
    private static func need(_ value: Bool, _ stage: String) throws { if !value { throw Failure(stage: stage) } }
    private static func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() { try need(.now < deadline, stage); try await Task.sleep(for: .milliseconds(5)) }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func encoded(_ value: TextDocumentValue) -> Data { value.encoded }
    private static func noRemoteEffects(_ counts: GateABackendCounters) throws {
        try need(counts.workerStarts == 0 && counts.workerIPC == 0 && counts.remoteWrites == 0
            && counts.remoteSaveAcknowledgements == 0, "backend-offline-boundary")
    }
    static func run(factory: GateAFixtureAdapterFactory? = GateAAppAdapterFactory.reviewedFactory) async {
        var status = "FAILED", stage = "scope", phase = "unadmitted", checks: [String] = []
        var owner: ApplicationSMBConnections?, browser: BrowserViewController?, host: NSWindow?
        var adapter: (any GateAFixtureAdapter)?
        var smb: SMBPasswordVault?, sftp: SFTPPasswordVault?
        var notificationTokens: [NSObjectProtocol] = []
        let focus = FocusProbe()
        let credential = CredentialProbe(), probe = ConnectionProbe()
        let oldQualification = RemoteTextEditorFeature.qualifying
        defer { RemoteTextEditorFeature.qualifying = oldQualification }
        do {
            let scope = try await Task.detached { try Scope.load() }.value; phase = scope.phase
            try need(Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && !RemoteTextEditorFeature.ordinaryEnabled && !NSApp.isActive, "bundle-feature-or-focus")
            // The default factory is unavailable until reviewed case-bound
            // backend observations exist. Refuse before creating App owners.
            guard let factory else { status = "DEPENDENCY_UNAVAILABLE"; throw Failure(stage: "case-bound-backend-observation-source-unavailable") }
            let constructed = try await factory(scope.root, scope.layout)
            adapter = constructed
            let adapter = constructed
            try need(adapter.sourceIdentity == scope.adapterSchema, "adapter-schema-identity")
            for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification] {
                notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { focus.events += 1 }
                })
            }
            let before = try await snapshot(scope.root)
            let passwords = SMBPasswordVault.refusingQualification { credential.hit() }
            let sftpPasswords = SFTPPasswordVault.refusingQualification { credential.hit() }
            smb = passwords; sftp = sftpPasswords
            let connection = ApplicationSMBConnections(gateAQualificationLayout: scope.layout,
                passwords: passwords, sftpPasswords: sftpPasswords)
            owner = connection; connection.gateAObservation = { probe.receive($0) }
            try need(connection.installPersistentSavedVersionsLoader(), "inert-installed-loader")
            try need(try await snapshot(scope.root) == before && credential.calls == 0, "bootstrap-created-or-read-credentials")
            let bootstrapCounters = try await adapter.counters(); try noRemoteEffects(bootstrapCounters)
            try need(bootstrapCounters.bodyReads == 0 && bootstrapCounters.payloadValidationReadEntries == 0
                && !connection.gateAHasStorage && !connection.gateAHasCoordinator, "bootstrap-active-storage-or-body-read")
            checks.append("inert-owner-and-installed-loader")
            if phase == "refusal" {
                stage = "unknown-earlier-leaf-refusal-fixture"
                try await adapter.installRefusalFixture(layout: scope.layout, caseRoot: scope.root)
            }
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false; settings.motion.mode = .off
            let b = BrowserViewController(settings: settings); browser = b
            b.permitsBackgroundVerification = true; b.readVolumesForVerification = { [] }
            b.pinsController = BrowserPinsController(stateDirectory: nil)
            b.folderAccess = FolderAccessController(stateDirectory: nil)
            b.recoverableFileOperations = nil
            let native = NSWindow(contentRect: .init(x: -12000, y: -12000, width: 900, height: 600),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            host = native; native.isReleasedWhenClosed = false; native.contentViewController = b
            if phase == "prepare" || phase == "refusal" {
                stage = "actual-app-owner-prepare"
                let refusedBefore = try await snapshot(scope.root)
                connection.present(in: b, offscreen: true)
                let expectedRoots = [scope.layout.stateDirectory, scope.layout.persistentConnectionWorkspaceDirectory,
                    scope.layout.smbInPlaceRecoveryDirectory,
                    scope.layout.smbDirectory, scope.layout.connectionWorkspaceRecordDirectory,
                    scope.layout.ordinaryRemoteDownloadDirectory, scope.layout.stateDirectory.appendingPathComponent("sftp-upload-history")]
                // This is observed synchronously before the owner's Task starts.
                try need(probe.preflightCalls == 1 && Set(probe.preflightRoots.map(\.standardizedFileURL))
                    .isSuperset(of: expectedRoots.map(\.standardizedFileURL)), "roots-not-protected-before-prepare")
                await connection.gateAWaitForSetup()
                try need(probe.submissions == 0 && credential.calls == 0 && focus.events == 0, "setup-submitted-or-took-focus")
                if phase == "refusal" {
                    try need(b.status.stringValue == "Earlier connection storage needs review. Existing connections and saved versions are preserved."
                        && probe.refusals == 1 && probe.refusalFailure == .reviewRequired,
                        "refusal-not-actual-review-required")
                    try need(probe.admittedCalls == 0 && !connection.gateAHasStorage && !connection.gateAHasCoordinator
                        && connection.verificationWindow == nil, "refusal-admitted-second-pool")
                    try await adapter.requireRefusalPreserved(layout: scope.layout, caseRoot: scope.root)
                    // Creating a revision-zero review record may be truthful;
                    // the adapter compares the original occupied graph exactly.
                    let after = try await snapshot(scope.root)
                    for (key, value) in refusedBefore { try need(after[key] == value, "refusal-changed-original-entry") }
                    checks.append("actual-setup-refusal-originals-preserved")
                } else {
                    guard let admission = probe.admission else { throw Failure(stage: "actual-admission-not-observed") }
                    try need(probe.admittedCalls == 1 && connection.gateAHasStorage && connection.gateAHasCoordinator
                        && connection.verificationWindow != nil, "setup-before-admission-or-window-missing")
                    try await adapter.requireActiveGraph(layout: scope.layout, caseRoot: scope.root)
                    try need(scope.layout.channel == .portable
                        && scope.layout.ordinaryRemoteDownloadDirectory == scope.layout.cacheDirectory.appendingPathComponent("remote-downloads", isDirectory: true), "portable-or-download-layout")
                    let beforeSeed = try await adapter.counters()
                    try noRemoteEffects(beforeSeed)
                    try need(beforeSeed.bodyReads == 0 && beforeSeed.payloadValidationReadEntries == 0,
                        "setup-body-read-before-seed")
                    stage = "daybreak-seed-after-actual-admission"
                    try await adapter.seedAfterActualAdmission(admission, layout: scope.layout, caseRoot: scope.root)
                    checks.append("actual-app-opaque-admission-and-post-admission-seed")
                }
            } else {
                stage = "fresh-process-cold-global-library"
                try need(probe.preflightCalls == 0 && probe.admittedCalls == 0 && connection.verificationWindow == nil,
                    "cold-process-connected-or-admitted")
                let expected = try await adapter.expectedRetainedText(caseRoot: scope.root)
                try need(expected.before.encoded.count == expected.beforeBytes
                    && expected.edited.encoded.count == expected.editedBytes
                    && digest(expected.before.encoded) == expected.beforeSHA256
                    && digest(expected.edited.encoded) == expected.editedSHA256
                    && expected.before != expected.edited, "seed-expectation-byte-counts-hashes-and-order")
                let preColdGraph = try await adapter.counters()
                try need(preColdGraph.payloadValidationReadEntries == 0, "cold-passive-validation-before-graph")
                try await adapter.requireColdGraph(layout: scope.layout, caseRoot: scope.root)
                let postColdGraph = try await adapter.counters(); try noRemoteEffects(postColdGraph)
                try need(postColdGraph.bodyReads == preColdGraph.bodyReads + 2,
                    "cold-graph-two-actual-backend-read-entries")
                // Inert engine construction registers the exact private history
                // parent before admission. The explicit chooser creates it off
                // Main BEFORE acquireCopy/publish/real history upgrade.
                let copyState = scope.root.appendingPathComponent("state/GateALocalCopy", isDirectory: true)
                let engine = RecoverableFileOperations(journalDirectory: copyState.appendingPathComponent("history", isDirectory: true),
                    protecting: [copyState, scope.layout.stateDirectory, scope.layout.cacheDirectory], activity: ApplicationFileActivity.beginOperation)
                b.recoverableFileOperations = engine
                guard let context = ApplicationLocalTextEditors.shared.savedVersionsContext(from: b),
                      let loader = ApplicationRemoteSavedVersions.shared.gateAInstalledLoader else { throw Failure(stage: "actual-copy-context-or-loader") }
                let exportDirectory = scope.root.appendingPathComponent("state/Exports", isDirectory: true)
                // The explicit generated destination replaces only NSSavePanel;
                // admission, publication, readback and result remain real.
                var chooseCount = 0
                var exportOracle: GateAGeneratedExportOracle?
                let chosen: RemoteSavedVersionsContext = RemoteSavedVersionsContext(
                    settings: context.settings, acquire: context.acquire, finish: context.finish,
                    choose: { (_: NSWindow) async -> EditorSaveDestination? in
                        chooseCount += 1
                        do { try await Task.detached {
                            try FileManager().createDirectory(at: copyState,
                                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                            try FileManager().createDirectory(at: exportDirectory,
                                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        }.value
                            exportOracle = try await GateAGeneratedExportOracle.capture(root: scope.root,
                                expectedRoot: scope.rootIdentity, expectedByteCount: expected.edited.encoded.count)
                        }
                        catch { return nil }
                        return EditorSaveDestination(directory: exportDirectory, name: "Generated Retained Copy.txt",
                            access: FileAccessLifetimes(leases: []))
                    }, publish: context.publish, showResult: { _ in })
                RemoteTextEditorFeature.qualifying = true
                let preLibrary = try await adapter.counters()
                guard let library = ApplicationRemoteSavedVersions.shared.showGenerated(source: loader, context: chosen, visible: false)
                else { throw Failure(stage: "cold-global-library-unavailable") }
                library.gateAReviewVisible = false
                guard let discoveryWork: Task<Void, Never> = library.work else {
                    throw Failure(stage: "cold-metadata-discovery-task-missing")
                }
                await discoveryWork.value
                let postLibrary = try await adapter.counters(); try noRemoteEffects(postLibrary)
                try need(postLibrary.bodyReads == preLibrary.bodyReads
                    && postLibrary.payloadValidationReadEntries == preLibrary.payloadValidationReadEntries,
                    "library-metadata-discovery-read-body")
                let retainedChoices: [SFTPInPlaceRecoveryChoice] = library.choices
                try need(retainedChoices.count == 1, "cold-metadata-choice-count")
                let actualVersions: [SFTPInPlaceRecoveryVersion] = retainedChoices[0].availableVersions
                let expectedVersions: [SFTPInPlaceRecoveryVersion] = [.before, .edited]
                try need(actualVersions == expectedVersions && probe.preflightCalls == 0
                    && ApplicationRemoteTextEditors.shared.reservationCount == 0,
                    "cold-metadata-choice-or-connection")
                for (index, value) in [expected.before, expected.edited].enumerated() {
                    library.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    let preViewer = try await adapter.counters()
                    library.version.selectItem(at: index); library.reviewSelected(nil)
                    try await wait("cold-checked-viewer") { library.viewer != nil || library.work == nil }
                    guard let view = library.viewer, let viewed = view.viewed else { throw Failure(stage: "checked-body-viewer-missing") }
                    let postViewer = try await adapter.counters(); try noRemoteEffects(postViewer)
                    try need(postViewer.bodyReads == preViewer.bodyReads + 1, "library-one-actual-backend-read-entry")
                    try need(view.contents == value && !view.window.surface.textView.isEditable
                        && ApplicationRemoteSavedVersions.shared.reservationCount == 1, "read-only-body-or-reservation")
                    try await adapter.requireActualReadPin(viewed, held: true, caseRoot: scope.root)
                    if index == 1 {
                        view.copy()
                        guard let copyWork: Task<Void, Never> = view.work else {
                            throw Failure(stage: "actual-local-copy-task-missing")
                        }
                        await copyWork.value
                        try need(chooseCount == 1 && view.copyRecords.count == 1 && view.uncertainDestinations.isEmpty,
                            "actual-guarded-copy-not-confirmed")
                        // The preserved publisher checks upgrade success and
                        // prepareLocalTextSaveAs itself requires history10.
                        // Inspect the actual durable format; never infer it
                        // from constructing a lazy or initially absent engine.
                        try need(try await engine.inspectExistingHistory().readiness == .available(catalogVersion: 10),
                            "actual-copy-history10-not-admitted")
                        guard let exportOracle else { throw Failure(stage: "generated-export-oracle-not-captured") }
                        // Independent ORACLE read only; production backend text
                        // and digest-validation counters do not include it.
                        let bytes = try await exportOracle.readExact()
                        try need(bytes == encoded(value) && digest(bytes) == expected.editedSHA256, "export-exact-readback")
                        try await adapter.requireActualReadPin(viewed, held: true, caseRoot: scope.root)
                    }
                    let postExport = try await adapter.counters(); try noRemoteEffects(postExport)
                    try need(postExport.bodyReads == postViewer.bodyReads, "copy-or-pin-assertion-reopened-body-reader")
                    guard let reviewWork: Task<Void, Never> = library.work else {
                        throw Failure(stage: "actual-version-review-task-missing")
                    }
                    await view.closeAndDrain()
                    await reviewWork.value
                    try await adapter.requireActualReadPin(viewed, held: false, caseRoot: scope.root)
                    try need(view.closed && view.nativeClosed && ApplicationRemoteSavedVersions.shared.reservationCount == 0,
                        "actual-native-close-or-body-reservation-drain")
                }
                await library.closeAndDrain()
                try need(await ApplicationRemoteSavedVersions.shared.prepareForTermination(), "library-termination-drain")
                try need(!ApplicationRemoteTextEditors.shared.hasManagedDocuments
                    && ApplicationLocalTextEditors.shared.documentReservationCount == 0
                    && ApplicationLocalTextEditors.shared.waitingMutationsForVerification == 0
                    && ApplicationOperationCoordinator.shared.activeOwner == nil, "app-reservation-or-writer-drain")
                checks.append("fresh-process-cold-checked-before-edited-and-guarded-local-copy")
            }
            stage = "actual-owner-drain"
            await connection.closeAndDrain(); await passwords.drain(); await sftpPasswords.drain()
            try await adapter.closeAndDrain()
            let final = try await adapter.counters(); try noRemoteEffects(final)
            try need(final.outstandingOwners == 0 && credential.calls == 0 && probe.submissions == 0
                && focus.events == 0 && !RemoteTextEditorFeature.ordinaryEnabled, "final-owner-offline-focus-boundary")
            if phase == "refusal" { try need(final.bodyReads == 0 && final.payloadValidationReadEntries == 0, "refusal-body-read") }
            status = "APP_CHECKS_COMPLETED_EXTERNAL_PROCESS_DRAIN_STILL_REQUIRED"
        } catch let error as Failure { stage = error.stage }
        catch let error as ConnectionWorkspaceGeneratedSeedFailure {
            stage = "daybreak-seed-" + error.stage.rawValue
        }
        catch let error as GateADaybreakFixtureAdapter.Failure {
            stage = "daybreak-adapter-" + error.stage
        }
        catch { stage = "unexpected-error-no-details-logged" }
        // Failure cleanup joins real work; it must never report a pass because
        // a UI flag changed. External observer owns RSS/deadline/child proof.
        if owner != nil, let controller = ApplicationRemoteSavedVersions.shared.controller {
            if let viewer = controller.viewer { await viewer.closeAndDrain() }
            await controller.closeAndDrain()
        }
        if let owner { await owner.closeAndDrain() }
        await smb?.drain(); await sftp?.drain()
        if let adapter { do { try await adapter.closeAndDrain() } catch { status = "FAILED"; stage = "adapter-drain-failed" } }
        browser?.suspendBrowser(); host?.close()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        RemoteTextEditorFeature.qualifying = oldQualification
        let result: [String: Any] = ["format": "traverse-gate-a-application-draft-v3", "status": status,
            "phase": phase, "stage": stage, "checks": checks, "ordinaryRemoteEditing": false,
            "externalProcessDrain": "NOT EXERCISED BY APP", "sourceCase": Scope.sourceCase,
            "bodyReadAccounting": "backend text-read entries and payload-validation entries exclude only generated snapshot/seed-receipt/export-readback oracle reads"]
        if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let line = String(data: bytes, encoding: .utf8) { print(line) }
        NSApp.terminate(nil)
    }
}
#endif
