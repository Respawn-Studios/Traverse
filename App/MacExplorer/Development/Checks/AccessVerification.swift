import Foundation
import Darwin
import LocalStorage

/// Controlled checks only: fake security scopes/bookmarks and a newly generated
/// directory below MAC_EXPLORER_TEST_ROOT. Never invokes NSOpenPanel, TCC,
/// System Settings, signing, or a read of the user's protected folders.
@MainActor
enum AccessVerification {
    struct Failure: Error { let message: String }

    static func run(in testRoot: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.isFileURL,
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL else {
            throw Failure(message: "Access verification requires the explicitly declared disposable test root.")
        }
        // Resolve before any write; refuse redirection of the declared fixture root.
        guard testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw Failure(message: "The disposable test root must not be redirected through symlinks.")
        }
        let owned = testRoot.appendingPathComponent("access-\(UUID().uuidString)", isDirectory: true)
        try FileManager().createDirectory(at: owned, withIntermediateDirectories: true)
        try Data("mac-explorer-access-verification-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"))
        // Keep generated evidence/fixtures; no cleanup traverses user-owned paths.
        let folder = owned.appendingPathComponent("Chosen Folder", isDirectory: true)
        try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
        let state = owned.appendingPathComponent("app-state", isDirectory: true)
        var checks: [String] = []

        try require(FolderAccessDiagnostic.describe(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))).kind == .permissionOrACL,
                    "EACCES must retain permission/ACL evidence")
        try require(FolderAccessDiagnostic.describe(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))).kind == .policyOrOtherRestriction,
                    "EPERM must not be diagnosed as a specific TCC grant")
        try require(FolderAccessDiagnostic.describe(LocalStorageError.accessDenied).kind == .deniedCauseUnknown,
                    "Collapsed LocalStorage denial must remain uncertain")
        try require(FolderAccessDiagnostic.describe(LocalStorageError.notFound).kind == .missing,
                    "Missing folders must remain separate from denial")
        checks.append("Denied/uncertain/POSIX/missing error evidence stays distinct")

        let backend = ControlledFolderAccessBackend()
        var lease: FolderAccessLease? = FolderAccessLease(url: folder, backend: backend)
        lease?.close()
        lease?.close()
        lease = nil
        try require(backend.counts == (1, 1), "Repeated close/deinit must balance a successful start once")
        var automatic: FolderAccessLease? = FolderAccessLease(url: folder, backend: backend)
        automatic = nil
        _ = automatic
        try require(backend.counts == (2, 2), "Last lease reference must stop the successful scope")
        let unscoped = ControlledFolderAccessBackend(starts: false)
        let unscopedLease = FolderAccessLease(url: folder, backend: unscoped)
        try require(!unscopedLease.securityScopeStarted, "False start must be reported honestly")
        unscopedLease.close()
        try require(unscoped.counts == (1, 0), "False start must not be followed by stop or assumed denial")
        checks.append("Lease close/deinit balances successful starts and preserves false-start uncertainty")

        let controller = FolderAccessController(stateDirectory: state, backend: backend)
        var transient = await controller.acceptChosenFolder(folder)
        try require(transient != nil, "Controlled explicit choice did not return a lease")
        try require(!FileManager().fileExists(atPath: state.path), "Choosing without Remember wrote app state")
        transient = nil
        var chosen = await controller.acceptChosenFolder(folder, remember: true)
        guard let id = chosen?.selection.id else { throw Failure(message: "Controlled remembered selection failed") }
        if case .saved? = chosen?.remembering {} else { throw Failure(message: "Remember did not report persistence") }
        chosen = nil
        checks.append("Persistence is opt-in and restricted to the declared app-owned fixture store")

        let fresh = FolderAccessController(stateDirectory: state, backend: backend)
        let restored = await fresh.resolveRememberedFolders()
        try require(restored.count == 1 && restored[0].id == id, "Saved folder reference did not restore")
        if case .resolvedUnverified = restored[0].state {} else { throw Failure(message: "Fresh reference must resolve without claiming readability") }
        let childLease = await fresh.acquireAccess(to: folder.appendingPathComponent("Child"))
        try require(childLease?.url == folder, "Child work must retain the original scoped root URL")
        childLease?.close()
        let siblingLease = await fresh.acquireAccess(to: owned.appendingPathComponent("Chosen Folder Sibling"))
        try require(siblingLease == nil, "String-prefix sibling must not select a folder grant")
        checks.append("Restoration stays unverified; descendant tasks use the exact root URL and reject sibling prefixes")

        let preparation = fresh.prepareAccess(to: [folder, folder.appendingPathComponent("Child"),
            owned.appendingPathComponent("Chosen Folder Sibling")])
        try require(fresh.isCurrent(preparation), "Fresh native-menu access preparation was rejected")
        let acquirePreparation: @Sendable () throws -> ([FolderAccessLease], Bool) = {
            (try preparation.acquire(), Thread.isMainThread)
        }
        let preparationResult = try await Task.detached { try acquirePreparation() }.value
        try require(!preparationResult.1 && preparationResult.0.count == 1
            && preparationResult.0.first?.url == folder,
                    "Native-menu preparation did not retain one exact off-main root")
        preparationResult.0.forEach { $0.close() }
        checks.append("Immutable native-menu scope preparation deduplicates original roots off-main and rejects sibling prefixes")

        backend.mode = .stale
        let stale = FolderAccessController(stateDirectory: state, backend: backend)
        let staleResult = await stale.resolveRememberedFolders()
        if case .needsRenewal? = staleResult.first?.state {} else { throw Failure(message: "Stale bookmark did not request renewal") }
        let staleLease = await stale.acquireAccess(to: folder)
        try require(staleLease == nil, "Stale references must not be silently activated")
        let differentFolder = owned.appendingPathComponent("Chosen Folder Sibling", isDirectory: true)
        try FileManager().createDirectory(at: differentFolder, withIntermediateDirectories: false)
        var differentChoice = await stale.acceptChosenFolder(differentFolder)
        try require(differentChoice != nil && differentChoice?.selection.id != id, "A different URL must not renew the stale saved reference")
        differentChoice = nil
        let inactiveAfterDifferentChoice = await stale.acquireAccess(to: folder)
        try require(inactiveAfterDifferentChoice == nil, "Unrelated selection activated a stale grant")
        var renewed = await stale.acceptChosenFolder(folder, remember: true)
        try require(renewed?.selection.id == id, "Explicit exact-URL renewal must preserve the saved reference ID")
        if case .saved? = renewed?.remembering {} else { throw Failure(message: "Stale reference renewal did not save") }
        renewed = nil
        backend.mode = .fresh
        let afterRenewal = await FolderAccessController(stateDirectory: state, backend: backend).resolveRememberedFolders()
        try require(afterRenewal.count == 1 && afterRenewal.first?.id == id,
                    "Renewal accumulated duplicate saved references")
        if case .resolvedUnverified? = afterRenewal.first?.state {} else { throw Failure(message: "Renewed reference did not resolve fresh") }
        checks.append("Explicit exact-URL reselection renews one saved reference; unrelated URLs never activate stale grants")
        backend.mode = .missing
        let missing = await FolderAccessController(stateDirectory: state, backend: backend).resolveRememberedFolders()
        if case .unavailable(let diagnostic)? = missing.first?.state {
            try require(diagnostic.kind == .missing, "Missing bookmark target lost its diagnosis")
        } else { throw Failure(message: "Missing bookmark target was accepted") }
        checks.append("Stale references require renewal; missing bookmark targets remain unresolved")

        let gate = ControlledFolderAccessBackend.Gate()
        let delayed = ControlledFolderAccessBackend(gate: gate)
        let cancelling = FolderAccessController(backend: delayed)
        let task = Task { await cancelling.acceptChosenFolder(folder) }
        let began = await Task.detached { gate.waitUntilStarted() }.value
        guard began else { gate.finish.signal(); throw Failure(message: "Controlled scope worker did not start") }
        task.cancel()
        gate.finish.signal()
        let cancelledChoice = await task.value
        try require(cancelledChoice == nil, "Cancelled choice must not navigate")
        try require(delayed.counts == (1, 1), "Cancelled worker leaked its acquired scope")
        checks.append("Cancelled off-main acquisition rejects its result and releases its acquired scope")

        let forgetFailure = await fresh.forget(id: id)
        try require(forgetFailure == nil, "Controlled forget failed")
        try require(!fresh.isCurrent(preparation), "Forgotten grants left native-menu preparation current")
        let forgotten = await FolderAccessController(stateDirectory: state, backend: backend).resolveRememberedFolders()
        try require(forgotten.isEmpty, "Forget left the app-owned bookmark behind")
        var selectedAfterForget = await fresh.acceptChosenFolder(folder)
        try require(selectedAfterForget != nil && selectedAfterForget?.selection.id != id, "Forget left stale ID-matching metadata behind")
        selectedAfterForget = nil
        checks.append("Forget removes only the app-owned bookmark record")
        return checks
    }

    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
}

private final class ControlledFolderAccessBackend: FolderAccessBackend, @unchecked Sendable {
    enum Mode: Sendable, Equatable { case fresh, stale, missing }
    final class Gate: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)

        // Invoked exclusively by the detached verification worker. Keep the
        // blocking primitive in a synchronous boundary, never on MainActor.
        func waitUntilStarted() -> Bool {
            started.wait(timeout: .now() + 3) == .success
        }
    }
    private let lock = NSLock()
    private let starts: Bool
    private let gate: Gate?
    private var startCount = 0
    private var stopCount = 0
    private var resolutionMode: Mode = .fresh

    init(starts: Bool = true, gate: Gate? = nil) { self.starts = starts; self.gate = gate }

    var counts: (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (startCount, stopCount)
    }

    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return resolutionMode }
        set { lock.lock(); resolutionMode = newValue; lock.unlock() }
    }

    func startAccess(to url: URL) -> Bool {
        lock.lock(); startCount += 1; lock.unlock()
        if let gate { gate.started.signal(); _ = gate.finish.wait(timeout: .now() + 5) }
        return starts
    }
    func stopAccess(to url: URL) { lock.lock(); stopCount += 1; lock.unlock() }
    func bookmark(for url: URL) throws -> Data { Data(url.absoluteString.utf8) }
    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution {
        let mode = mode
        if mode == .missing { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
        guard let string = String(data: bookmark, encoding: .utf8), let url = URL(string: string), url.isFileURL else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        }
        return FolderBookmarkResolution(url: url, isStale: mode == .stale)
    }
}
