#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) @testable import LocalStorage

/// Real bundled signed child, native parent, encrypted generated peer and tab.
/// No Keychain, DNS, body transfer, personal host or saved-server state.
@MainActor enum SFTPWorkerDirectoryRecoveryVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool, _ line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while !predicate() { try require(.now < end, line); try await Task.sleep(for: .milliseconds(5)) }
    }
    private static func button(_ view: NSView, _ id: String) -> NSButton? {
        if view.identifier?.rawValue == id { return view as? NSButton }; return view.subviews.lazy.compactMap { button($0,id) }.first
    }
    static func run() async {
        var root: URL?, worker: SFTPWorkerSession?, tab: SFTPTabController?, browser: BrowserViewController?, window: NSWindow?
        var close: SFTPWorkerClose?, checks: [String] = [], failure: UInt?, kind: String?, poolEmpty = false
        let activity = FileActivityGate()
        do {
            guard let rootPath = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let area = URL(fileURLWithPath: rootPath), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf:area.appendingPathComponent("reservation.json"))) as? [String:Any]
            func argument(_ flag: String) throws -> String {
                let args = ProcessInfo.processInfo.arguments
                guard let i = args.firstIndex(of:flag), args.indices.contains(i+1) else { throw Failure.scope }; return args[i+1]
            }
            guard area.resolvingSymlinksInPath() == area, area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
                  marker?["action"] as? String == "native-worker-directory-recovery", Bundle.main.bundleIdentifier == "local.macexplorer.development",
                  let port = UInt16(try argument("--generated-port")), port > 0 else { throw Failure.scope }
            root = area
            let fingerprint = try argument("--generated-fingerprint")
            let storage = try SMBTemporaryStorage(directory: area.appendingPathComponent("state/catalogs")), pool = SMBTemporaryCatalogPool(storage: storage)
            let raw = try await SFTPWorkerSession.openGenerated(port: port, activity: activity, pool: pool); worker = raw
            try require(raw.review.current.fingerprint == fingerprint && raw.review.kind == .first)
            try await raw.approve(.connectOnce); try await raw.authenticateGenerated()
            let session = try await SFTPBrowserSession.adoptAuthenticated(raw)
            checks.append("The native parent authenticates and negotiates recovery with the exact bundled signed worker")
            let settings = BrowserSettings(persist:false); settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
            let owner = BrowserViewController(settings:settings); browser = owner; owner.permitsBackgroundVerification = true; owner.readVolumesForVerification = { [] }
            let panel = NSWindow(contentRect:.init(x:180,y:140,width:1000,height:640),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window = panel; panel.isReleasedWhenClosed = false; panel.contentViewController = owner; panel.makeKeyAndOrderFront(nil)
            let remote = SFTPTabController(session:session,address:try .init(server:"127.0.0.1",port:port,startingFolder:"/denied"),title:"Generated encrypted server"); tab = remote
            owner.installSFTPTab(remote)
            try await wait { session.latest.directoryRejection == .denied && remote.rows.recoveryVisibleForVerification }
            try require(session.latest.failure == nil && remote.rows.cache.generation == nil && remote.selectedItemObservation == nil && owner.connectedLocationSnapshot.count == 1)
            checks.append("Actual encrypted OPENDIR denial reaches recoverable native UI with no old selection authority")
            guard let home = button(remote.rows,"sftp-recovery-home") else { throw Failure.scope }; home.performClick(nil)
            try await wait { session.latest.snapshot?.state == .complete && remote.rows.cache.retainedCount == 2 && !remote.hasPendingPages }
            try require(remote.connectionID == raw.review.session && session.latest.failure == nil && session.latest.directoryRejection == nil)
            checks.append("Home on that same tab loads a complete paged listing without reconnecting")
            if let file = (0..<2).first(where:{ remote.rows.cache.entry(at:UInt64($0))?.entry.isDirectory == false }) {
                remote.rows.table.selectRowIndexes(IndexSet(integer:file),byExtendingSelection:false)
                try require(remote.selectedItemObservation?.copyName != nil)
            } else { throw Failure.scope }
            checks.append("Properties metadata becomes available only from the fresh observed file row")
            let missing = try remote.directoryLocation(components:[.init(Data("missing-canonical".utf8))],relativeToHome:false)
            owner.navigate(to:.sftp(missing)); try await wait { session.latest.directoryRejection == .missing && remote.rows.cache.generation == nil }
            try require(remote.selectedItemObservation == nil && session.latest.failure == nil)
            home.performClick(nil); try await wait { remote.rows.cache.retainedCount == 2 && !remote.hasPendingPages }
            checks.append("A later missing folder retires the old generation and Home recovers again")
            close = await remote.close().value
            try require(close?.localResourcesEnded == true && close?.exitStatus == 0 && close?.contained == false && close?.protocolValid == true
                && close?.temporaryStoreRemoved == true && close?.terminal?.catalogWriterEnd == .closed && activity.activeCount == 0)
            poolEmpty = try await pool.inspect().isEmpty; try require(poolEmpty)
            checks.append("Actual child exit, IPC EOF, writer closure and temporary catalog removal drain before success")
        } catch { if case let Failure.check(line) = error { failure = line } else { failure = 0 }; kind = String(reflecting:type(of:error)) }
        if let tab { close = await tab.close().value } else if let worker { close = await worker.close() }
        browser?.suspendBrowser(); window?.close()
        if let root {
            let report: [String:Any] = ["passed":failure == nil,"checks":checks,"line":failure.map { $0 as Any } ?? NSNull(),"failureType":kind.map { $0 as Any } ?? NSNull(),
                "actualExit":close?.actualExit ?? false,"ipcEOF":close?.ipcEOF ?? false,"contained":close?.contained ?? false,"temporaryStoreRemoved":close?.temporaryStoreRemoved ?? false,
                "poolEmpty":poolEmpty,"activityDrained":activity.activeCount == 0,"keychainCalls":0,"fileBodyRequests":0,"personalEndpoints":0]
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/native-worker-directory-recovery.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
}
#endif
