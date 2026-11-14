#if DEBUG && !MAC_EXPLORER_DISTRIBUTION
import AppKit
import CryptoKit
import Darwin
import Dispatch
import ExplorerCore
@testable import FileOperations

// SOURCE ONLY. Not installed in App.swift and never a backend/session factory.
// The future entry must validate the current exact image BEFORE calling make.
@MainActor protocol GateBReviewedEntryImageAdmission: AnyObject {
    var generatedCaseURL: URL { get }
    var sourceImageManifestSHA256: String { get }
    // This prerequisite must perform any image/manifest I/O off Main, bind the
    // exact process image, and reject an unapproved or mismatched future entry.
    func requireCurrentEntryAndImage() async throws
}

private struct GateBAppFixtureFailure: Error, Sendable { let stage: String }

// Retention only: no bookmark resolution/startAccess/permission synthesis.
// Drop the fixture's final reference on an explicit worker after every join;
// caller-owned references, if any, remain the caller's responsibility.
private final class GateBFixtureAccessRetention: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FileAccessLifetimes?
    init(_ value: FileAccessLifetimes) { self.value = value }
    func snapshot() -> FileAccessLifetimes? { lock.withLock { value } }
    func releaseOnWorker() {
        precondition(!Thread.isMainThread)
        lock.withLock { value = nil }
    }
}

// A worker-only observation of the REAL production hook. Four distinct slot
// directories and a one-use issued index2 destination identify its target;
// callbacks on any other directory never pause or count as index2 evidence.
private final class GateBPublicationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let slot: URL
    private var armed = false, issued = false, admitted = false
    private var payload: URL?
    private var entries = 0, released = false, expired = false, invalid = false
    init(slot: URL) { self.slot = slot }
    var syncedEntries: Int { condition.withLock { entries } }
    var timedOut: Bool { condition.withLock { expired } }
    func arm() throws {
        condition.lock(); defer { condition.unlock() }
        guard !armed, !released else { throw GateBAppFixtureFailure(stage: "publication-pause-reused") }
        armed = true
    }
    func destinationIssued() throws {
        condition.lock(); defer { condition.unlock() }
        guard armed, !issued, !released else { throw GateBAppFixtureFailure(stage: "publication-slot-not-armed-or-reused") }
        issued = true
    }
    func release() { condition.withLock { released = true; condition.broadcast() } }
    func requireHealthy() throws {
        condition.lock(); defer { condition.unlock() }
        guard !expired, !invalid else { throw GateBAppFixtureFailure(stage: "publication-hook-expired-or-unexpected") }
    }
    func observe(_ stage: ArchiveProductionHooks.Stage, _ url: URL) throws {
        guard !Thread.isMainThread else { throw GateBAppFixtureFailure(stage: "production-hook-ran-on-main") }
        let area = url.deletingLastPathComponent()
        let isPayload = url.lastPathComponent == "payload"
            && area.lastPathComponent.hasPrefix(".mac-explorer-recovery-")
            && area.deletingLastPathComponent() == slot
        let belongs = (stage == .admitted && url == slot) || isPayload
        guard belongs else { return }
        condition.lock(); defer { condition.unlock() }
        guard armed, issued else { invalid = true; throw GateBAppFixtureFailure(stage: "unissued-index2-production") }
        switch stage {
        case .admitted:
            guard !admitted else { invalid = true; throw GateBAppFixtureFailure(stage: "index2-admitted-twice") }
            admitted = true
        case .payloadCreated:
            guard admitted, payload == nil, isPayload else { invalid = true; throw GateBAppFixtureFailure(stage: "index2-payload-affinity") }
            payload = url
        case .synced:
            entries += 1
            guard admitted, payload == url, entries == 1 else { invalid = true; throw GateBAppFixtureFailure(stage: "index2-synced-affinity-or-repeat") }
            condition.broadcast()
            let deadline = Date(timeIntervalSinceNow: 5)
            // Independent worker expiry: cancellation/release reporting cannot
            // leave this real FileOperations worker indefinitely blocked.
            while !released {
                if !condition.wait(until: deadline) {
                    expired = true; released = true; condition.broadcast()
                    throw GateBAppFixtureFailure(stage: "actual-publication-pause-expired")
                }
            }
        default: break
        }
    }
}

@MainActor private final class GateBPublicationPause: GateBActualPublicationPause {
    private let gate: GateBPublicationGate
    init(_ gate: GateBPublicationGate) { self.gate = gate }
    var actualSyncedEntries: Int { gate.syncedEntries }
    func release() { gate.release() }
    func waitForActualSyncedEntry() async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while gate.syncedEntries == 0 {
            try gate.requireHealthy()
            guard .now < deadline else { throw GateBAppFixtureFailure(stage: "actual-synced-hook-not-reached") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try gate.requireHealthy()
        guard gate.syncedEntries == 1 else { throw GateBAppFixtureFailure(stage: "actual-synced-hook-repeated") }
    }
}

// All filesystem access, including marker/budget checks, directory creation,
// independent export reads and descriptor teardown, runs on this serial queue.
// No fixture body is written by this helper. Actual copy bodies are produced
// only by the unmodified guarded FileOperations engine in a future run.
private final class GateBFixtureIO: @unchecked Sendable {
    let root: URL, appState: URL, history: URL, slots: [URL]
    static let outputName = "Generated Text Copy.txt"
    private let queue = DispatchQueue(label: "Traverse.Generated.GateB.AppFixture.IO")
    private var rootFD: Int32 = -1, slotFDs: [Int32] = []
    private var rootIdentity: Identity?, slotIdentities: [Identity] = []
    private var closed = false
    private struct Identity: Sendable, Equatable {
        let device: Int64, inode: UInt64
        init(_ s: stat) { device = Int64(s.st_dev); inode = UInt64(s.st_ino) }
    }
    init(root: URL) {
        self.root = root
        let state = root.appendingPathComponent("state/GateBAppFixture", isDirectory: true)
        appState = state
        history = state.appendingPathComponent("history", isDirectory: true)
        let exports = root.appendingPathComponent("source/GateBTextCopies", isDirectory: true)
        slots = (0..<4).map { exports.appendingPathComponent("Slot-\($0)", isDirectory: true) }
    }
    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
    private static func privateDirectory(_ fd: Int32) throws -> Identity {
        var s = stat()
        guard fd >= 0, fstat(fd, &s) == 0, s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              s.st_uid == geteuid(), s.st_mode & 0o7777 == 0o700 else { throw GateBAppFixtureFailure(stage: "fixture-private-directory") }
        return Identity(s)
    }
    private static func child(_ parent: Int32, _ name: String, createExclusive: Bool = false) throws -> Int32 {
        if createExclusive { guard mkdirat(parent, name, 0o700) == 0 else { throw GateBAppFixtureFailure(stage: "fixture-owned-directory-not-fresh") } }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GateBAppFixtureFailure(stage: "fixture-directory-open") }
        do { _ = try privateDirectory(fd); return fd }
        catch { Darwin.close(fd); throw error }
    }
    private static func marker(_ fd: Int32, _ name: String) throws -> [String: Any] {
        let leaf = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard leaf >= 0 else { throw GateBAppFixtureFailure(stage: "fixture-marker-open") }
        defer { Darwin.close(leaf) }
        var before = stat()
        guard fstat(leaf, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o7777 == 0o600,
              before.st_size > 0, before.st_size <= 16384 else { throw GateBAppFixtureFailure(stage: "fixture-marker-private-bound") }
        let bytes = try readStable(leaf, parent: fd, name: name, maximum: 16384, mode: 0o600)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw GateBAppFixtureFailure(stage: "fixture-marker-json") }
        return object
    }
    private static func readStable(_ fd: Int32, parent: Int32, name: String, maximum: Int, mode: mode_t) throws -> Data {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o7777 == mode,
              before.st_size >= 0, before.st_size <= Int64(maximum) else { throw GateBAppFixtureFailure(stage: "fixture-read-private-bound") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while let part = try file.read(upToCount: min(32768, maximum + 1 - data.count)), !part.isEmpty {
            data.append(part)
            guard data.count <= maximum, Int64(data.count) <= before.st_size else { throw GateBAppFixtureFailure(stage: "fixture-read-growth") }
        }
        func same(_ x: stat, _ y: stat) -> Bool {
            Identity(x) == Identity(y) && x.st_mode == y.st_mode && x.st_uid == y.st_uid
                && x.st_nlink == y.st_nlink && x.st_size == y.st_size
                && x.st_mtimespec.tv_sec == y.st_mtimespec.tv_sec && x.st_mtimespec.tv_nsec == y.st_mtimespec.tv_nsec
                && x.st_ctimespec.tv_sec == y.st_ctimespec.tv_sec && x.st_ctimespec.tv_nsec == y.st_ctimespec.tv_nsec
        }
        var after = stat(), current = stat()
        guard Int64(data.count) == before.st_size, fstat(fd, &after) == 0, same(before, after),
              fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, same(after, current) else { throw GateBAppFixtureFailure(stage: "fixture-read-unstable") }
        return data
    }
    func prepare(manifestSHA256: String) async throws {
        try await run { [self] in
            guard !Thread.isMainThread, rootFD == -1, !closed,
                  root.standardizedFileURL == root, root.resolvingSymlinksInPath() == root,
                  root.deletingLastPathComponent() == DevelopmentFixturePaths.cases,
                  UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                  root.lastPathComponent != "15349F93-703A-4F64-8E63-4D4254E9B315" else { throw GateBAppFixtureFailure(stage: "fixture-case-scope") }
            rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            rootIdentity = try Self.privateDirectory(rootFD)
            let reservation = try Self.marker(rootFD, "reservation.json")
            let admission = try Self.marker(rootFD, "gate-b-app-admission.json")
            guard reservation["packet"] as? String == "traverse-development-v1",
                  reservation["action"] as? String == "gateb-application-runtime-v1",
                  admission["schema"] as? String == "traverse.gateb.native-close.v1",
                  admission["sourceCase"] as? String == "15349F93-703A-4F64-8E63-4D4254E9B315",
                  admission["sourceImageManifestSHA256"] as? String == manifestSHA256,
                  admission["runtimeApproved"] as? Bool == true,
                  admission["maximumLogicalBytes"] as? Int == 64 * 1024 * 1024,
                  admission["maximumEntries"] as? Int == 1024,
                  admission["maximumSeconds"] as? Int == 120,
                  admission["maximumRSSMiB"] as? Int == 384 else { throw GateBAppFixtureFailure(stage: "fixture-exact-admission") }
            let state = try Self.child(rootFD, "state"); defer { Darwin.close(state) }
            let source = try Self.child(rootFD, "source"); defer { Darwin.close(source) }
            let privateState = try Self.child(state, "GateBAppFixture", createExclusive: true); defer { Darwin.close(privateState) }
            let exports = try Self.child(source, "GateBTextCopies", createExclusive: true); defer { Darwin.close(exports) }
            for i in 0..<4 {
                let fd = try Self.child(exports, "Slot-\(i)", createExclusive: true)
                slotFDs.append(fd); slotIdentities.append(try Self.privateDirectory(fd))
            }
        }
    }
    private func checkedSlot(_ index: Int) throws -> Int32 {
        guard !Thread.isMainThread, !closed, slots.indices.contains(index), slotFDs.count == 4 else { throw GateBAppFixtureFailure(stage: "fixture-slot-state") }
        let freshRoot = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard freshRoot >= 0 else { throw GateBAppFixtureFailure(stage: "fixture-root-no-longer-current") }
        defer { Darwin.close(freshRoot) }
        guard try Self.privateDirectory(freshRoot) == rootIdentity else { throw GateBAppFixtureFailure(stage: "fixture-root-replaced") }
        let fresh = open(slots[index].path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fresh >= 0 else { throw GateBAppFixtureFailure(stage: "fixture-slot-reopen") }
        defer { Darwin.close(fresh) }
        guard try Self.privateDirectory(fresh) == slotIdentities[index],
              try Self.privateDirectory(slotFDs[index]) == slotIdentities[index] else { throw GateBAppFixtureFailure(stage: "fixture-slot-replaced") }
        return slotFDs[index]
    }
    func requireNoExport(_ index: Int) async throws {
        try await run { [self] in
            let fd = try checkedSlot(index); var s = stat()
            guard fstatat(fd, Self.outputName, &s, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw GateBAppFixtureFailure(stage: "unexpected-generated-export") }
        }
    }
    func requireExactExport(_ index: Int, _ expected: TextDocumentValue) async throws {
        try await run { [self] in
            let parent = try checkedSlot(index)
            let fd = openat(parent, Self.outputName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw GateBAppFixtureFailure(stage: "expected-generated-export-missing") }
            defer { Darwin.close(fd) }
            let bytes = try Self.readStable(fd, parent: parent, name: Self.outputName, maximum: TextDocumentValue.maximumBytes, mode: 0o644)
            guard bytes.count == expected.encoded.count, bytes == expected.encoded,
                  SHA256.hash(data: bytes) == SHA256.hash(data: expected.encoded) else { throw GateBAppFixtureFailure(stage: "generated-export-byte-mismatch") }
        }
    }
    func closeAndDrain() async throws {
        try await run { [self] in
            guard !closed else { return }
            slotFDs.forEach { Darwin.close($0) }; slotFDs = []
            if rootFD >= 0 { Darwin.close(rootFD); rootFD = -1 }
            closed = true
        }
    }
}

@MainActor private final class GateBAppFixtureOwner {
    let controller: BrowserWindowController
    let engine: RecoverableFileOperations
    let names: ApplicationPrivateNames
    let io: GateBFixtureIO
    let gate: GateBPublicationGate
    private let accessRetention: GateBFixtureAccessRetention
    private var chosen = Set<Int>()
    private var closing = false
    private var cleanup: Task<Void, Error>?
    private let coordinator = ApplicationOperationCoordinator.shared

    init(io: GateBFixtureIO, retaining access: FileAccessLifetimes) {
        self.io = io; accessRetention = GateBFixtureAccessRetention(access)
        let observedGate = GateBPublicationGate(slot: io.slots[2])
        gate = observedGate
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, url in try observedGate.observe(stage, url) }
        let generatedEngine = RecoverableFileOperations(journalDirectory: io.history, hooks: hooks,
            protecting: [io.appState], activity: ApplicationFileActivity.beginOperation)
        engine = generatedEngine
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
        settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        settings.restoresSession = false; settings.motion.mode = .off
        let generatedNames = ApplicationPrivateNames(directory: io.appState.appendingPathComponent("private-names", isDirectory: true),
            settings: settings, enablesMoveContinuity: false, enablesImport: false)
        names = generatedNames
        let generatedController = BrowserWindowController(settings: settings)
        controller = generatedController
        let browser = generatedController.browser
        browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
        browser.privateNames = generatedNames
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.recoverableFileOperations = generatedEngine
        generatedController.window?.isReleasedWhenClosed = false
        // Intentionally no beginBrowsing/navigate/search/show/activate call.
        // The actual remote editor runner owns its own native presentation.
    }
    func prepareFreshHistory10() async throws {
        let id = UUID()
        guard coordinator.begin(owner: id) else { throw GateBAppFixtureFailure(stage: "fixture-history-writer-unavailable") }
        defer { coordinator.finish(owner: id) }
        guard try await engine.inspectExistingHistory().readiness == .absent else { throw GateBAppFixtureFailure(stage: "fixture-history-not-fresh") }
        let result = await engine.upgradeLocalTextHistory()
        guard result.status == .succeeded, result.catalogVersion == 10,
              try await engine.inspectExistingHistory().readiness == .available(catalogVersion: 10),
              engine.pendingWorkerCount == 0 else { throw GateBAppFixtureFailure(stage: "actual-history10-upgrade-incomplete") }
    }
    func fixture() -> GateBApplicationFixture {
        .init(browser: controller.browser,
            destination: { [self] index in
                guard !closing, io.slots.indices.contains(index), !chosen.contains(index), let access = accessRetention.snapshot() else { throw GateBAppFixtureFailure(stage: "destination-slot-reused-or-closed") }
                if index == 2 { try gate.destinationIssued() }
                chosen.insert(index)
                // This merely retains the caller's actual fixture lifetime.
                // A generated URL is never converted into an OS access grant.
                return .init(directory: io.slots[index], name: GateBFixtureIO.outputName, access: access)
            }, requireNoExport: { [self] index in
                guard let access = accessRetention.snapshot() else { throw GateBAppFixtureFailure(stage: "export-access-not-retained") }
                defer { withExtendedLifetime(access) {} }
                try await io.requireNoExport(index)
            }, requireExactExport: { [self] index, value in
                guard let access = accessRetention.snapshot() else { throw GateBAppFixtureFailure(stage: "export-access-not-retained") }
                defer { withExtendedLifetime(access) {} }
                try await io.requireExactExport(index, value)
            }, armActualPublicationPause: { [self] index in
                guard !closing, index == 2, !chosen.contains(index) else { throw GateBAppFixtureFailure(stage: "wrong-publication-pause-slot") }
                try gate.arm(); return GateBPublicationPause(gate)
            }, closeAndDrain: { [self] in try await closeAndDrain() })
    }
    func closeAndDrain() async throws {
        if let cleanup { try await cleanup.value; return }
        // An unstructured task owns this actual join independently of cancellation
        // of the invoking runner. No global activity gate is closed/reset.
        let task = Task { @MainActor [self] in try await performCleanup() }
        cleanup = task; try await task.value
    }
    private func performCleanup() async throws {
        closing = true; gate.release()
        let browser = controller.browser
        let tasks = [browser.operationTask, browser.operationPreparationTask,
            browser.operationProgressTask, browser.listingTask, browser.orderingTask,
            browser.directoryRefreshTask, browser.recoveryInspectionTask,
            browser.retentionInspectionTask, browser.folderLoadingFeedbackTask,
            browser.addressCompletion.taskForVerification].compactMap { $0 } + browser.sidebarTasks
        // Writes are joined, never interrupted by closing a browser. The runner
        // has already released its pauses and joined its document work.
        for task in [browser.operationTask, browser.operationPreparationTask].compactMap({ $0 }) { await task.value }
        controller.suspendBrowsing()
        for task in tasks { await task.value }
        await controller.flushSession()
        await names.close()
        var barrierFailed = false
        do { _ = try await engine.inspectExistingHistory() } catch { barrierFailed = true }
        let deadline = ContinuousClock.now + .seconds(8)
        while engine.pendingWorkerCount != 0 || coordinator.activeOwner != nil
            || coordinator.preparationOwner != nil || coordinator.inspectionCount != 0
            || ApplicationLocalTextEditors.shared.waitingMutationsForVerification != 0
            || ApplicationFileActivity.gate.activeCount != 0 {
            guard .now < deadline else { throw GateBAppFixtureFailure(stage: "actual-app-writer-or-browser-drain-incomplete-access-retained") }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard coordinator.copyPreviewOwner == nil, coordinator.volumeBarrierOwner == nil,
              coordinator.transfers.isIdleForCopyPreview, !coordinator.drives.isBusy else { throw GateBAppFixtureFailure(stage: "unexpected-coordinator-owner-access-retained") }
        controller.close(); await controller.flushSession()
        guard controller.window?.isVisible != true, engine.pendingWorkerCount == 0 else { throw GateBAppFixtureFailure(stage: "generated-browser-window-or-engine-not-drained") }
        // This FIFO queue join is after every independent read and writer join.
        try await io.closeAndDrain()
        let accessOwner = accessRetention
        await Task.detached { accessOwner.releaseOnWorker() }.value
        try gate.requireHealthy()
        if barrierFailed { throw GateBAppFixtureFailure(stage: "actual-engine-drain-inspection-refused") }
    }
}

@MainActor enum GateBApplicationFixtureFactory {
    // Explicit caller only. Nothing installs this into the runner or creates a
    // backend when another dependency is nil. The caller must admit BOTH sides
    // before constructing either fixture; nil runner dependencies still refuse.
    static func make(validatedEntry: any GateBReviewedEntryImageAdmission,
                     retainingGeneratedAccess access: FileAccessLifetimes) async throws -> GateBApplicationFixture {
        try await validatedEntry.requireCurrentEntryAndImage()
        let args = ProcessInfo.processInfo.arguments
        guard Bundle.main.bundleIdentifier == "local.macexplorer.development",
              args.filter({ $0 == "--verify-ui" }).count == 1,
              args.filter({ $0 == "--check-security-remote-close" }).count == 1,
              ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] == validatedEntry.generatedCaseURL.path,
              validatedEntry.sourceImageManifestSHA256.count == 64,
              validatedEntry.sourceImageManifestSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              !RemoteTextEditorFeature.ordinaryEnabled else { throw GateBAppFixtureFailure(stage: "fixture-entry-image-or-feature") }
        let coordinator = ApplicationOperationCoordinator.shared
        guard coordinator.liveBrowsers.isEmpty, coordinator.activeOwner == nil,
              coordinator.preparationOwner == nil, coordinator.copyPreviewOwner == nil,
              coordinator.volumeBarrierOwner == nil, coordinator.inspectionCount == 0,
              coordinator.transfers.isIdleForCopyPreview, !coordinator.drives.isBusy,
              ApplicationFileActivity.gate.activeCount == 0,
              !ApplicationLocalTextEditors.shared.hasManagedDocuments else { throw GateBAppFixtureFailure(stage: "fixture-process-not-isolated") }
        let io = GateBFixtureIO(root: validatedEntry.generatedCaseURL)
        do { try await io.prepare(manifestSHA256: validatedEntry.sourceImageManifestSHA256) }
        catch { try? await io.closeAndDrain(); throw error }
        let owner = GateBAppFixtureOwner(io: io, retaining: access)
        do {
            try await owner.prepareFreshHistory10()
            guard ApplicationLocalTextEditors.shared.remoteInteractions(from: owner.controller.browser) != nil else { throw GateBAppFixtureFailure(stage: "ordinary-app-copy-service-missing") }
            return owner.fixture()
        } catch {
            do { try await owner.closeAndDrain() }
            catch { throw GateBAppFixtureFailure(stage: "factory-failure-cleanup-incomplete") }
            throw error
        }
    }
}
#endif
