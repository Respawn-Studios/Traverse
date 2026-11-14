#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import StorageAnalysis

@MainActor enum ChartOverviewVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func read(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw Failure.scope }
        return value
    }
    static func run() async {
        var root: URL?, rows: [[String: Any]] = [], checks: [String] = []
        let gate = FileActivityGate()
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let admitted = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let pool = repo.appendingPathComponent(".build/traverse-development"), marker = try read(admitted.appendingPathComponent("reservation.json"))
            try require(admitted.deletingLastPathComponent() == pool && admitted.resolvingSymlinksInPath() == admitted
                && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent
                && marker["packet"] as? String == "traverse-development-v1" && marker["action"] as? String == "chart-overview-native"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
            root = admitted
            let inputs = try read(admitted.appendingPathComponent("inputs.json"))
            guard let workerID = inputs["workerCase"] as? String, UUID(uuidString: workerID)?.uuidString == workerID,
                  let workload = inputs["workload"] as? String, ["wide","mixed","controls"].contains(workload) else { throw Failure.scope }
            let candidateRoot = pool.appendingPathComponent(workerID), proof = try read(candidateRoot.appendingPathComponent("evidence/result.json"))
            let workers = [pool.appendingPathComponent("8CAED007-FB54-4D45-9436-23D4C55FCB63/source/storage-baseline"), candidateRoot.appendingPathComponent("source/candidate/worker")]
            try require(try read(candidateRoot.appendingPathComponent("reservation.json"))["action"] as? String == "chart-overview-build"
                && proof["passed"] as? Bool == true && workers.allSatisfy { $0.resolvingSymlinksInPath() == $0 })
            let digest = try await Task.detached { SHA256.hash(data: try Data(contentsOf: workers[1])).map { String(format: "%02x", $0) }.joined() }.value
            try require(digest == proof["binarySHA256"] as? String)
            let corpus = repo.appendingPathComponent(".build/b06-analyzer/20261017T140537Z-6faf182f69/fixtures")
            if workload == "controls" {
                let source = admitted.appendingPathComponent("source/Control")
                var expected: Data?
                for lane in 0..<2 {
                    let measured = try await scan(source: source, worker: workers[lane], directory: admitted.appendingPathComponent("cache/control-\(lane)"),
                        gate: gate, lane: lane, stopAtPrefix: false, cancellation: lane == 1)
                    if let expected { try require(measured.canonical == expected) } else { expected = measured.canonical }
                    rows.append(measured.record)
                }
                checks.append("Actual native attribution is identical with three legacy queries or one overview")
                checks.append("Late cancellation holds ownership through actual read retirement and publishes no result")
                let partial = try await scan(source: corpus.appendingPathComponent("wide"), worker: workers[1], directory: admitted.appendingPathComponent("cache/partial"),
                    gate: gate, lane: 1, stopAtPrefix: true, cancellation: false)
                rows.append(partial.record)
                checks.append("Stopped committed prefix decodes a types-only overview without claiming final classification")
            } else {
                var expected: Data?
                for (pair, order) in [[0,1],[1,0],[0,1]].enumerated() {
                    for lane in order {
                        let measured = try await scan(source: corpus.appendingPathComponent(workload), worker: workers[lane],
                            directory: admitted.appendingPathComponent("cache/pair-\(pair)-\(lane)"), gate: gate, lane: lane, stopAtPrefix: false, cancellation: false)
                        if let expected { try require(measured.canonical == expected) } else { expected = measured.canonical }
                        var record = measured.record; record["pair"] = pair; rows.append(record)
                    }
                    try write(["pair":pair,"rows":rows,"actualWorkersDrained":gate.activeCount == 0], to: admitted.appendingPathComponent("evidence/pair-\(pair).json"))
                }
                checks.append("Three balanced full native scan-to-chart pairs preserve exact attribution and actual query counts")
            }
            try require(gate.activeCount == 0)
            try write(["passed":true,"rows":rows,"checks":checks,"actualActivityDrained":true,"sourceBodyReads":0,"networkRequests":0],
                to: admitted.appendingPathComponent("evidence/native-chart-overview.json"))
        } catch {
            var line: UInt = 0; if case let Failure.check(value) = error { line = value }
            if let root { try? write(["passed":false,"rows":rows,"checks":checks,"line":line,"errorType":String(reflecting:type(of:error)),"activityDrained":gate.activeCount == 0],
                to: root.appendingPathComponent("evidence/native-chart-overview.json")) }
        }
        NSApp.terminate(nil)
    }
    private static func scan(source: URL, worker: URL, directory: URL, gate: FileActivityGate, lane: Int,
                             stopAtPrefix: Bool, cancellation: Bool) async throws -> (canonical: Data, record: [String: Any]) {
        let storage = try AnalysisResultStorage(directory: directory, sessionByteLimit: 64 << 20, poolByteLimit: 64 << 20, preserveAfterClose: true)
        let scanner = StorageScanner(workerURL: worker, activityGate: gate), began = ProcessInfo.processInfo.systemUptime
        let session = try scanner.startPaged(root: source, storage: storage, retainingAccess: "Admitted generated overview source only")
        var terminal: PagedStorageScanUpdate?, stopped = false
        for await update in session.updates {
            if stopAtPrefix && !stopped && update.provisionalFileTypes != nil { stopped = true; session.cancel() }
            if update.workerDrained { terminal = update }
        }
        await session.waitUntilDrained()
        let traversed = ProcessInfo.processInfo.systemUptime
        guard let terminal, let result = terminal.result else { throw Failure.scope }
        try require(terminal.workerDrained && (terminal.workerPeakResidentBytes ?? UInt64.max) <= 256 << 20)
        let summary = try await result.summary(), launches = result.queryWorkerLaunchCountForQualification
        guard let report = try await result.attribution(scopeName: "Generated", summary: summary) else { throw Failure.scope }
        let finished = ProcessInfo.processInfo.systemUptime, queryCount = result.queryWorkerLaunchCountForQualification - launches
        try require(queryCount == (lane == 1 || !summary.classificationReady ? 1 : 3) && result.activeReaderCount == 0)
        if stopAtPrefix { try require(stopped && !summary.classificationReady && !report.isComplete && !report.hasLayoutAttribution) }
        else { try require(summary.value.counts.total == (source.lastPathComponent == "Control" ? 5 : 100000)) }
        let canonical = try JSONSerialization.data(withJSONObject: projection(report), options: [.sortedKeys])
        if cancellation {
            let hold = Hold()
            try result.installQueryReleaseHookForQualification { hold.pause() }
            var published = false
            let task = Task { () -> Bool in
                do { _ = try await result.attribution(scopeName: "Generated", summary: summary); published = true; return false }
                catch is CancellationError { return true }
                catch { return false }
            }
            let end = ProcessInfo.processInfo.systemUptime + 8
            while !hold.entered && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(5)) }
            let entered = hold.entered, owned = result.activeReaderCount
            task.cancel(); hold.release()
            let cancelled = await task.value
            await result.waitUntilReadersDrained(); try result.installQueryReleaseHookForQualification(nil)
            try require(entered && owned == 1 && cancelled && !published && !hold.timedOut && result.activeReaderCount == 0)
        }
        await result.waitUntilReadersDrained()
        try require(gate.activeCount == 0)
        return (canonical,["lane":lane == 0 ? "baseline" : "candidate","session":result.id.uuidString,
            "seconds":finished-began,"traversalSeconds":traversed-began,"chartSeconds":finished-traversed,
            "queryLaunches":queryCount,"entries":String(summary.value.counts.total),"projected":summary.classificationReady,
            "workerPeakRSSBytes":terminal.workerPeakResidentBytes ?? 0,"actualReadersDrained":result.activeReaderCount == 0])
    }
    private static func projection(_ report: AnalysisAttributionReport) -> [String: Any] {
        func rows(_ slices: [AnalysisAttributionSlice]) -> [[String: Any]] {
            slices.map { slice in
                ["title":slice.title,"files":String(slice.files),"metrics":AnalysisByteMetric.allCases.map { metric -> [String: Any] in
                    let value = slice.bytes[metric]
                    return ["known":value.knownBytes.map { String($0) as Any } ?? NSNull(),"missing":String(value.notReturnedCount),
                        "failed":String(value.failedCount),"overflow":value.overflowed]
                }]
            }
        }
        return ["types":rows(report.fileTypes),"roles":rows(report.categories),"projects":rows(report.projects),
            "projectCount":report.projectCount,"complete":report.isComplete,"layout":report.hasLayoutAttribution]
    }
    private static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)
    }
    private final class Hold: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var waiting = false, timeout = false
        var entered: Bool { lock.withLock { waiting } }
        var timedOut: Bool { lock.withLock { timeout } }
        func pause() { lock.withLock { waiting = true }; if semaphore.wait(timeout:.now()+6) != .success { lock.withLock { timeout = true } } }
        func release() { semaphore.signal() }
    }
}
#endif
