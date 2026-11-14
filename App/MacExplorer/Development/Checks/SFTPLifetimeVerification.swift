#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum SFTPLifetimeVerification {
    private enum Failure: Error { case generated }
    private static var retained: BrowserWindowController?
    private static func require(_ value: Bool) throws { if !value { throw Failure.generated } }
    private static func wait(seconds: Double = 5, _ predicate: () -> Bool) async throws {
        let limit = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < limit); try await Task.sleep(for: .milliseconds(5)) }
    }
    static func runStandalone() async {
        var root: URL?, mode = "input", stage = "input", raw: [SFTPWorkerSession] = [], owners: [SFTPTabController] = []
        var ticker: Task<Void, Never>?, gap = 0.0, last = ProcessInfo.processInfo.systemUptime
        do {
            let args = ProcessInfo.processInfo.arguments
            func field(_ key: String) throws -> String { guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { throw Failure.generated }; return args[i + 1] }
            let location = URL(fileURLWithPath: try field("--analysis-source")); root = location; mode = try field("--generated-mode")
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try require(location.deletingLastPathComponent() == repo.appendingPathComponent(".build/b11-native-qualification")
                && location.resolvingSymlinksInPath() == location && UUID(uuidString: location.lastPathComponent)?.uuidString == location.lastPathComponent
                && Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String == location.lastPathComponent
                && ["concurrent", "idle-healthy", "idle-drop", "read-stop", "blackhole", "openssh"].contains(mode))
            guard let port = UInt16(try field("--generated-port")), port > 0 else { throw Failure.generated }
            let expected = try field("--generated-fingerprint"), settings = BrowserSettings(persist: false)
            let password: SFTPPassword
            if mode == "openssh" {
                let supplied = try await Task.detached { try SMBAuthenticatedVerification.readPrivatePassword() }.value
                password = try supplied.withUTF8Bytes { try SFTPPassword(String(decoding: $0, as: UTF8.self)) }
            } else { password = try SFTPPassword("ephemeral qualification password") }
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
            let controller = BrowserWindowController(settings: settings); retained = controller
            let browser = controller.browser; browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
            browser.tabs = [BrowserTab(location: .directory(location.appendingPathComponent("source/Empty")))]; browser.activeID = browser.tabs[0].id; browser.loadLocation()
            guard let window = controller.window else { throw Failure.generated }; window.title = "SFTP lifetimes · generated review"; window.center(); window.makeKeyAndOrderFront(nil)
            let activity = FileActivityGate(maximumActivities: 8), pool = SMBTemporaryCatalogPool(storage: try .init(directory: location.appendingPathComponent("stores/" + mode)))
            let request = try SFTPConnectionRequest(address: .init("127.0.0.1:\(port)"), account: "generated")
            last = ProcessInfo.processInfo.systemUptime
            ticker = Task { while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime; gap = max(gap, now - last); last = now
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }}
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<(mode == "concurrent" ? 2 : 1) {
                stage = "open"
                let endpoint = try await SFTPPreparedConnection.prepare(request, bundleURL: Bundle.main.bundleURL, activity: activity)
                let worker = try await SFTPWorkerSession.openPrepared(request, endpoint: endpoint, bundleURL: Bundle.main.bundleURL, activity: activity, pool: pool); raw.append(worker)
                try require(worker.review.current.fingerprint == expected && worker.review.kind == .first)
                try await worker.approve(.connectOnce); try await worker.authenticate(password)
                let session = try await SFTPBrowserSession.adoptAuthenticated(worker)
                let owner = SFTPTabController(session: session, address: request.address, title: "Generated SFTP"); owners.append(owner); browser.installSFTPTab(owner)
                if mode == "read-stop" {
                    try await wait { owner.session.latest.reading }
                    let marker = location.appendingPathComponent("evidence/read-pending"), until = ProcessInfo.processInfo.systemUptime + 5
                    while !(await Task.detached { (try? Data(contentsOf: marker)) == Data("generated read pending\n".utf8) }.value) {
                        try require(ProcessInfo.processInfo.systemUptime < until); try await Task.sleep(for: .milliseconds(10))
                    }
                }
                else {
                    stage = "initial-page"
                    try await wait { owner.session.latest.failure != nil || owner.session.latest.snapshot?.state == .complete && owner.rows.cache.retainedCount == 2 && !owner.hasPendingPages }
                    try require(owner.session.latest.failure == nil && owner.rows.cache.retainedCount == 2)
                }
            }
            let initial = ProcessInfo.processInfo.systemUptime - start
            var metrics: [String: Any] = ["firstUsableSeconds": initial]
            stage = "control"
            if mode == "concurrent" {
                try require(activity.activeCount == 2 && owners[0].connectionID != owners[1].connectionID)
                let endpoint = try await SFTPPreparedConnection.prepare(request, bundleURL: Bundle.main.bundleURL, activity: activity)
                do { _ = try await SFTPWorkerSession.openPrepared(request, endpoint: endpoint, bundleURL: Bundle.main.bundleURL, activity: activity, pool: pool); throw Failure.generated }
                catch { try require((error as? SFTPSessionFailure) == .busy) }
                let second = owners[1], generation = second.session.latest.generation, snapshot = second.session.latest.snapshot
                _ = try await owners[0].session.navigate(pathUTF8: Data(".".utf8))
                try require(second.session.latest.generation == generation && second.session.latest.snapshot == snapshot)
                let closed = await owners[0].close().value; try require(closed.localResourcesEnded && closed.temporaryStoreRemoved == true)
                let remaining = try await pool.inspect(); try require(remaining.count == 1 && remaining[0].active && activity.activeCount == 1)
                let page = try await second.session.page(offset: 0); try require(page.rows.count == 2 && second.session.latest.failure == nil)
                metrics["thirdOwnerRefusedBeforeConnect"] = true; metrics["otherOwnerSurvivesClose"] = true
            } else if mode == "openssh" {
                let owner = owners[0]
                try require(owner.rows.cache.entry(at: 0)?.entry.name.displayName == "Folder" && owner.rows.cache.entry(at: 0)?.entry.isDirectory == true)
                let child = try owner.directoryLocation(components: [SFTPRemoteName(Data("Folder".utf8))]); browser.navigate(to: .sftp(child))
                try await wait { owner.session.latest.snapshot?.state == .complete && owner.rows.cache.retainedCount == 1 && !owner.hasPendingPages }
                try require(owner.rows.cache.entry(at: 0)?.entry.name.displayName == "Nested.txt")
                browser.goBack(nil); try await wait { owner.session.latest.snapshot?.state == .complete && owner.rows.cache.retainedCount == 2 && !owner.hasPendingPages }
                metrics["independentOpenSSH"] = true; metrics["folderBackForward"] = true
            } else if mode == "idle-healthy" {
                try await Task.sleep(for: .milliseconds(17_500))
                try require(owners[0].session.latest.failure == nil)
                let page = try await owners[0].session.page(offset: 0); try require(page.rows.count == 2)
                metrics["idleUsableSeconds"] = 17.5
            } else if mode == "idle-drop" || mode == "blackhole" {
                let observed = ProcessInfo.processInfo.systemUptime
                if mode == "blackhole" {
                    let marker = location.appendingPathComponent("evidence/blackhole-ready")
                    try await Task.detached { try Data("generated encrypted relay control\n".utf8).write(to: marker, options: .withoutOverwriting) }.value
                }
                try await wait(seconds: mode == "blackhole" ? 25 : 5) { owners[0].session.latest.failure != nil }
                let latest = owners[0].session.latest
                try require(latest.snapshot?.count == 2 && latest.snapshot?.state == .complete)
                if mode == "blackhole" { try require(latest.failure == .deadline) }
                metrics["failureDelaySeconds"] = ProcessInfo.processInfo.systemUptime - observed
                metrics["observedPrefixRetained"] = true
            }
            stage = "close"
            let began = ProcessInfo.processInfo.systemUptime
            for owner in owners { let closed = await owner.close().value; try require(closed.localResourcesEnded) }
            try require(await SFTPBrowserLifetimes.shared.closeAndDrain())
            try require(await SFTPWorkerSession.pauseAndDrainOwned())
            let remaining = try await pool.inspect(); try require(remaining.isEmpty && activity.activeCount == 0)
            metrics["closeSeconds"] = ProcessInfo.processInfo.systemUptime - began
            ticker?.cancel(); await ticker?.value; ticker = nil
            try require(gap < 0.25)
            metrics.merge(["passed": true, "mode": mode, "allChildrenAndCatalogsDrained": true, "poolEmpty": true,
                "maximumMainActorGapSeconds": gap, "keychainAccesses": 0, "personalEndpoints": 0]) { _, new in new }
            try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: location.appendingPathComponent("evidence/lifetime-" + mode + ".json"), options: .withoutOverwriting)
            window.close(); retained = nil; NSApplication.shared.terminate(nil)
        } catch {
            ticker?.cancel(); await ticker?.value
            var closures: [[String: Any]] = []
            for session in raw {
                let value = await session.close()
                closures.append(["actualExit": value.actualExit, "ipcEOF": value.ipcEOF, "contained": value.contained,
                    "protocolValid": value.protocolValid, "terminalOutcome": value.terminal.map { Int($0.outcome) } ?? -1,
                    "exitStatusKnown": value.exitStatus != nil, "exitStatus": value.exitStatus ?? 0,
                    "temporaryStoreRemoved": value.temporaryStoreRemoved == true])
            }
            let ended = await SFTPBrowserLifetimes.shared.closeAndDrain(), setupEnded = await SFTPWorkerSession.pauseAndDrainOwned()
            if let root { let latest = owners.last?.session.latest
                let report: [String: Any] = ["passed": false, "stage": stage, "mode": mode, "errorType": String(reflecting: type(of: error)), "allLocalOwnersEnded": ended && setupEnded, "maximumMainActorGapSeconds": gap,
                    "observedCount": latest?.snapshot?.count ?? 0, "observationState": latest?.snapshot.map { String(describing: $0.state) } ?? "none",
                    "nativeRows": owners.last?.rows.cache.retainedCount ?? 0, "failure": latest?.failure?.rawValue ?? "none", "pendingPages": owners.last?.hasPendingPages ?? false, "closures": closures]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/lifetime-" + mode + ".json"), options: .withoutOverwriting) }
            fputs("Generated SFTP lifetime qualification failed\n", stderr); NSApplication.shared.terminate(nil)
        }
    }
}
#endif
