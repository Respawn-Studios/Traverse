#if DEBUG
import AppKit
import ExplorerCore
import StorageAnalysis

@MainActor enum ResultQueryCompletionVerification {
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              root.resolvingSymlinksInPath().path == root.path,
              let marker = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["action"] as? String == "traverse-result-completion" else { exit(2) }
        let gate = FileActivityGate()
        var checks: [String] = [], failures: [String] = [], metrics: [String: Any] = [:]
        do { try await verify(root: root, gate: gate, checks: &checks, metrics: &metrics) }
        catch { failures.append(String(describing: error)) }
        try? JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "checks": checks, "failures": failures,
            "metrics": metrics, "generatedOnly": true, "networkRequests": 0, "personalFiles": 0,
            "activityDrained": gate.activeCount == 0], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root: URL, gate: FileActivityGate, checks: inout [String], metrics: inout [String: Any]) async throws {
        let storage = try AnalysisResultStorage(directory: root.appendingPathComponent("catalog"), sessionByteLimit: 8 << 20,
            poolByteLimit: 8 << 20, preserveAfterClose: true)
        let scanner = StorageScanner(workerURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker"), activityGate: gate)
        let session = try scanner.startPaged(root: root.appendingPathComponent("source"), storage: storage, retainingAccess: "Admitted generated result-completion control only")
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates { if update.workerDrained { terminal = update } }
        await session.waitUntilDrained()
        guard let result = terminal?.result else { throw UIVerification.Failure(message: "Generated completion result unavailable") }
        for mode in ["child", "cache", "error", "late-cancel"] {
            await result.waitUntilReadersDrained()
            if mode == "cache" { _ = try await result.page(); await result.waitUntilReadersDrained() }
            let hold = Hold(), launches = result.queryWorkerLaunchCountForQualification
            try result.installQueryReleaseHookForQualification { hold.pause() }
            var returned = false
            let request = Task { () -> String in
                defer { returned = true }
                do {
                    if mode == "cache" { _ = try await result.page() }
                    else if mode == "error" { _ = try await result.page(after: UInt64(Int64.max - 1)) }
                    else { _ = try await result.summary() }
                    return "success"
                } catch is CancellationError { return "cancelled" }
                catch { return "failed" }
            }
            try await wait("Real query did not reach its retirement boundary") { hold.entered }
            if mode == "late-cancel" { request.cancel() }
            try await Task.sleep(for: .milliseconds(30))
            let publishedEarly = returned, ownedAtBoundary = result.activeReaderCount
            hold.release()
            let outcome = await request.value
            await result.waitUntilReadersDrained()
            try result.installQueryReleaseHookForQualification(nil)
            metrics[mode] = ["returnedBeforeRetirement": publishedEarly, "ownedAtBoundary": ownedAtBoundary,
                "outcome": outcome, "readerCountAfterAwait": result.activeReaderCount,
                "newChildren": result.queryWorkerLaunchCountForQualification - launches, "holdTimedOut": hold.timedOut] as [String: Any]
            try UIVerification.require(!publishedEarly && ownedAtBoundary == 1 && !hold.timedOut && result.activeReaderCount == 0,
                "A \(mode) query returned before retiring its own admission slot")
            let expected = mode == "error" ? "failed" : mode == "late-cancel" ? "cancelled" : "success"
            try UIVerification.require(outcome == expected && (mode != "cache" || result.queryWorkerLaunchCountForQualification == launches),
                "Query retirement changed its error/cancellation/cache contract")
            checks.append(mode + " outcome waits for actual read-slot retirement")
        }
        for _ in 0..<4 {
            async let first = result.summary()
            async let second = result.groups(.fileTypes)
            _ = try await (first, second)
            try UIVerification.require(result.activeReaderCount == 0, "Completed read pair retains an admission slot")
            _ = try await result.largestFiles()
        }
        await result.waitUntilReadersDrained()
        try UIVerification.require(gate.activeCount == 0, "Reader activity did not drain")
        checks.append("Four real two-reader pairs allow an immediate dependent query without raising the limit")
    }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), message)
    }
    private final class Hold: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var waiting = false, timeout = false
        var entered: Bool { lock.withLock { waiting } }
        var timedOut: Bool { lock.withLock { timeout } }
        func pause() {
            lock.withLock { waiting = true }
            if semaphore.wait(timeout: .now() + 8) != .success { lock.withLock { timeout = true } }
        }
        func release() { semaphore.signal() }
    }
}
#endif
