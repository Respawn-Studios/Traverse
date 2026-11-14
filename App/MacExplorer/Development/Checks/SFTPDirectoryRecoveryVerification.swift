#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) @testable import LocalStorage

@MainActor enum SFTPDirectoryRecoveryVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ value: () -> Bool, _ line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !value() { try require(.now < end, line); try await Task.sleep(for: .milliseconds(5)) }
    }
    private static func button(_ view: NSView, _ id: String) -> NSButton? {
        if view.identifier?.rawValue == id { return view as? NSButton }
        return view.subviews.lazy.compactMap { button($0, id) }.first
    }
    static func run() async {
        var root: URL?, host: NSWindow?, browser: BrowserViewController?, tab: SFTPTabController?
        var checks: [String] = [], clips: [[String:Any]] = [], failure: UInt?, kind: String?
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let area = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String:Any]
            try require(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && marker?["action"] as? String == "native-directory-recovery" && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = area
            let settings = BrowserSettings(persist: false); settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.reviewsRecoveryAtStartup = false; settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserViewController(settings: settings); browser = owner; owner.permitsBackgroundVerification = true
            let window = NSWindow(contentRect: .init(x: 180, y: 140, width: 1000, height: 640), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            host = window; window.isReleasedWhenClosed = false; window.contentViewController = owner
            window.title = "SFTP folder recovery · generated checks"; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait { owner.pinsController.isReady }
            owner.rebuildSidebar(); try require(!owner.sidebarRoots.contains { $0.title == "Pinned Folders" })
            checks.append("An empty pin collection has no empty sidebar heading")
            let pinURL = area.appendingPathComponent("source/Pinned", isDirectory: true)
            owner.pinsController.edit { _ = try $0.add(url: pinURL, label: "Generated pin") }
            owner.rebuildSidebar(); try require(owner.sidebarRoots.first { $0.title == "Pinned Folders" }?.children?.count == 1)
            guard let pin = owner.pinsController.collection.pins.first else { throw Failure.scope }
            owner.pinsController.edit { try $0.remove(id: pin.id) }
            owner.rebuildSidebar(); try require(!owner.sidebarRoots.contains { $0.title == "Pinned Folders" })
            checks.append("The first pin shows its section and removing the last pin hides it again")
            let transport = Transport()
            let session = SFTPBrowserSession(id: UUID(), transport: transport)
            let connection = SFTPTabController(session: session, address: try .init("sftp://generated.invalid/denied"), title: "Generated server")
            tab = connection; owner.installSFTPTab(connection)
            try await wait { session.latest.directoryRejection == .denied && !connection.rows.message.isHidden }
            let home = button(connection.rows, "sftp-recovery-home"), up = button(connection.rows, "sftp-recovery-up"), retry = button(connection.rows, "sftp-recovery-retry")
            try require(home != nil && up != nil && retry != nil && !home!.isHidden && !up!.isHidden && !retry!.isHidden)
            try require(connection.rows.cache.generation == nil && connection.selectedItemObservation == nil && session.latest.failure == nil)
            checks.append("Denied initial folder shows Home, Up and Retry without closing the live session or leaving selected-item authority")
            try await wait { owner.connectedLocationSnapshot.count == 1 }
            let connected = owner.connectedLocationSnapshot[0]
            try require(connected.id.connection == session.id && connected.status == "Folder unavailable"
                && owner.sidebarRoots.first { $0.title == "Servers" }?.children?.first?.connectionTarget == connected.id
                && owner.volumeBrowser.connectedServers.values.count == 1)
            checks.append("A live denied session remains visible in Servers and This Mac without pretending it is a mounted volume")
            let beforeRetry = await transport.counts()
            retry?.performClick(nil)
            try await wait { connection.rows.message.stringValue.contains("can’t open") && session.latest.directoryRejection == .denied }
            try await wait { connection.rows.cache.generation == nil }
            // Wait for the actual retry to reach the generated transport.
            let deadline = ContinuousClock.now + .seconds(2)
            while await transport.counts()[0] == beforeRetry[0] { try require(.now < deadline); try await Task.sleep(for: .milliseconds(5)) }
            try await wait { connection.rows.recoveryVisibleForVerification }
            checks.append("Retry performs another request on the same owner")
            home?.performClick(nil)
            try await wait { connection.rows.cache.retainedCount == 2 && !connection.hasPendingPages }
            guard case .sftp(let homeLocation) = owner.location else { throw Failure.scope }
            try require(connection.references.pathUTF8(for: homeLocation) == Data(".".utf8))
            connection.rows.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            try require(connection.selectedItemObservation?.copyPath == "./Generated.txt")
            checks.append("Home explicitly recovers metadata and Properties selection without reconnecting")
            let homeCounts = await transport.counts()
            owner.navigate(to: .computer)
            try require(owner.volumeBrowser.connectedServers.values.first?.id == connected.id && owner.focusConnectedLocation(connected.id))
            try await wait { connection.rows.cache.retainedCount == 2 && !connection.hasPendingPages }
            let returnedCounts = await transport.counts()
            try require(returnedCounts == homeCounts && owner.location == .sftp(homeLocation))
            checks.append("This Mac's live-server action returns to the existing remote tab and cached folder without another connection or listing")
            let denied = try connection.directoryLocation(components: [.init(Data("denied".utf8))], relativeToHome: false)
            owner.navigate(to: .sftp(denied))
            try await wait { session.latest.directoryRejection == .denied && connection.rows.cache.generation == nil }
            up?.performClick(nil)
            try await wait { connection.rows.cache.retainedCount == 2 && !connection.hasPendingPages }
            guard case .sftp(let rootLocation) = owner.location else { throw Failure.scope }
            try require(connection.references.pathUTF8(for: rootLocation) == Data("/".utf8))
            checks.append("Up navigates the refused absolute folder's actual parent and preserves root versus Home meaning")
            let current = owner.location, beforeStale = await transport.counts()
            home?.performClick(nil); retry?.performClick(nil)
            try require(owner.location == current)
            let afterStale = await transport.counts(); try require(beforeStale == afterStale)
            checks.append("Hidden recovery controls cannot act on a later successful visit")
            owner.updateSFTPBreadcrumbs()
            let icon = owner.pathControl.logicalItems.first?.image
            try require(icon?.size == NSSize(width: 16, height: 16) && icon?.isTemplate == true)
            checks.append("Address server symbol uses bounded native template dimensions")
            for reason: SFTPDirectoryRejection in [.missing,.unavailable] {
                connection.rows.directoryRejected(reason, canGoUp: false)
                try require(!connection.rows.message.isHidden && up?.isHidden == true && connection.rows.selectedObservation == nil)
            }
            connection.rows.observe(session.latest)
            checks.append("Missing and unavailable folders have distinct readable recovery, with no fake empty listing")
            if ProcessInfo.processInfo.arguments.contains("--record-directory-recovery") {
                for (label, percent, appearance, mode) in [("recovery-dark-100",100,BrowserAppearance.dark,BrowserMotionMode.full), ("recovery-light-150",150,.light,.reduced)] {
                    settings.appearance = appearance; settings.interfaceSize = .init(percent); settings.motion.mode = mode
                    try require(connection.rows.table.rowHeight == ceil(25 * CGFloat(percent) / 100))
                    owner.navigate(to: .sftp(denied)); try await wait { session.latest.directoryRejection == .denied && connection.rows.cache.generation == nil }
                    window.title = label + " · generated review"
                    let movie = try await NativeMotionRecorder.record(window: window, root: area, label: label, sampling: .diagnostic(for: window)) { home?.performClick(nil) }
                    try JSONEncoder().encode(movie).write(to: area.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
                    clips.append(DevelopmentMotionVerification.clip(label, report: movie, field: nil, window: window))
                    try await wait { connection.rows.cache.retainedCount == 2 && !connection.hasPendingPages }
                }
            }
            let ended = await connection.close().value; try require(ended.localResourcesEnded)
            let counts = await transport.counts(); try require(counts[2] == 1 && ApplicationFileActivity.gate.activeCount == 0)
            checks.append("One transport owner closes once, releasing the directory/paging lifetime")
            try require(owner.connectedLocationSnapshot.isEmpty && owner.volumeBrowser.connectedServers.values.isEmpty
                && !owner.sidebarRoots.contains { $0.title == "Servers" })
            checks.append("Actual session closure removes the live entries; it does not leave a mounted-drive placeholder")
        } catch {
            if case let Failure.check(line) = error { failure = line } else { failure = 0 }; kind = String(reflecting: type(of: error))
        }
        if let tab { _ = await tab.close().value }
        browser?.suspendBrowser(); host?.close()
        if let root {
            let report: [String:Any] = ["passed": failure == nil, "line": failure.map { $0 as Any } ?? NSNull(), "failureType": kind.map { $0 as Any } ?? NSNull(),
                "checks": checks, "clips": clips, "networkRequests": 0, "personalFiles": 0, "physicalInputExercised": false, "activityDrained": ApplicationFileActivity.gate.activeCount == 0]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("evidence/native-directory-recovery.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private actor Transport: SFTPDirectoryTransport {
        private var generation = UUID(), opens = 0, pages = 0, closes = 0
        func counts() -> [Int] { [opens,pages,closes] }
        func openStoredDirectory(_ path: String) async throws -> (UUID,SFTPStoredSnapshot) {
            opens += 1; if path == "/denied" { throw SFTPDirectoryRejection.denied }
            guard path == "." || path == "/" else { throw Failure.scope }
            generation = UUID(); return (generation,.init(read: UInt64(opens), revision: 1, count: 2, folders: 1, state: .complete))
        }
        func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot { throw Failure.scope }
        func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort, descending: Bool) async throws -> SFTPStoredPage? {
            guard generation == self.generation && offset == 0 else { throw Failure.scope }; pages += 1
            return .init(request: UUID(), generation: generation, snapshot: snapshot, offset: 0, rows: [
                .init(observation: 1, entry: .init(name: try .init(Data("Folder".utf8)), logicalBytes: nil, modifiedSeconds: nil, permissions: 0o040755)),
                .init(observation: 2, entry: .init(name: try .init(Data("Generated.txt".utf8)), logicalBytes: 16, modifiedSeconds: 0, permissions: 0o100644))])
        }
        func close() async -> SFTPWorkerClose {
            closes += 1; return .init(actualExit: true, exitStatus: 0, ipcEOF: true, contained: false, protocolValid: true, terminal: nil, temporaryStoreRemoved: true)
        }
    }
}
#endif
