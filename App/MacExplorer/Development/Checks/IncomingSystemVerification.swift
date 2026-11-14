#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import OSLog

/// A sealed generated app exercises actual Launch Services delivery through the
/// normal ApplicationDelegate. No URL or security scope is injected here.
@MainActor enum IncomingSystemVerification {
    private struct Context: Sendable {
        let root: URL, first: URL, second: URL, unselected: URL
        init() throws {
            let bundle = Bundle.main, root = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard root.deletingLastPathComponent().path == repo.appendingPathComponent(".build/traverse-release").path,
                  UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                  bundle.bundleIdentifier == "local.traverse.incoming-browser." + root.lastPathComponent.lowercased(),
                  bundle.object(forInfoDictionaryKey: "TraverseIncomingBrowserCase") as? String == root.lastPathComponent
            else { throw UIVerification.Failure(message: "Exact sealed incoming-browser case required") }
            self.root = root
            first = root.appendingPathComponent("source/Incoming A", isDirectory: true)
            second = root.appendingPathComponent("source/Incoming B", isDirectory: true)
            unselected = root.appendingPathComponent("source/Unselected", isDirectory: true)
        }
        func record(_ phase: String, _ values: [String: Any]) async throws {
            var report = values; report["phase"] = phase; report["pid"] = getpid()
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            guard bytes.count <= 16_384 else { throw UIVerification.Failure(message: "Generated report bound") }
            await Task.detached {
                FileHandle.standardOutput.write(bytes); FileHandle.standardOutput.write(Data([10]))
                // This exact generated identity reports only finite fixture
                // phases/numbers. No product paths or descriptions enter logs.
                Logger(subsystem: Bundle.main.bundleIdentifier!, category: "generated-incoming")
                    .notice("\(String(decoding: bytes, as: UTF8.self), privacy: .public)")
            }.value
        }
    }

    static func run(delegate: ApplicationDelegate) async {
        var context: Context?
        var owner: BrowserWindowController?
        var failure: String?
        do {
            let value = try Context(); context = value
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--incoming-baseline") {
                let denied = await unreadable([value.first, value.second, value.unselected])
                try UIVerification.require(denied, "Generated folders were readable before URL delivery")
                try await value.record("baseline", ["passed": true, "allGeneratedFoldersDenied": true,
                    "browserCreated": false, "bookmarks": 0, "fileBodiesRead": 0])
                return // Launcher retains this exact app, then requests normal termination.
            }
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.motion.mode = .off
            let controller = BrowserWindowController(settings: settings); owner = controller
            try UIVerification.require(controller.isWorkspacePresentation, "Incoming control requires actual workspace composition")
            let browser = controller.browser, incoming = delegate.incomingForSystemVerification
            browser.permitsBackgroundVerification = true
            controller.window?.setFrameOrigin(.init(x: -12_000, y: -12_000))
            delegate.attachIncomingForSystemVerification(controller)
            controller.beginBrowsing()
            try await wait { incoming.openedCount == 1 && browser.location == .directory(value.first) && settled(browser) }
            try UIVerification.require(browser.loadError == nil && browser.displayedEntries.map(\.name) == ["Child"],
                "Cold URL did not reach the ordinary browser listing")
            try UIVerification.require(await unreadable([value.second, value.unselected]), "An unselected sibling became readable")
            guard let row = browser.displayedEntries.firstIndex(where: { $0.name == "Child" }) else {
                throw UIVerification.Failure(message: "Generated child row absent")
            }
            browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            browser.openSelection(nil)
            try await wait { browser.location == .directory(value.first.appendingPathComponent("Child")) && settled(browser) }
            try UIVerification.require(browser.displayedEntries.map(\.name) == ["Generated.txt"] && browser.loadError == nil,
                "Original URL access did not reach the descendant directory reader")
            browser.goBack(nil)
            try await wait { browser.location == .directory(value.first) && settled(browser) }
            try await value.record("cold", ["passed": true, "ordinaryDescendantListing": true,
                "unselectedSiblingsDenied": true, "tabs": browser.tabs.count,
                "workspaceComposition": controller.isWorkspacePresentation,
                "deliveredBeforeDidFinish": delegate.incomingBeforeDidFinishForVerification])
            try await wait { incoming.openedCount == 2 && browser.location == .directory(value.second) && settled(browser) }
            try UIVerification.require(browser.tabs.count == 2 && browser.loadError == nil
                && browser.displayedEntries.map(\.name) == ["Child"], "Warm URL did not create exactly one usable tab")
            try UIVerification.require(await unreadable([value.unselected]), "Warm delivery broadened to an unselected sibling")
            try await value.record("warm", ["passed": true, "tabs": browser.tabs.count, "unselectedSiblingDenied": true])
            try await wait { incoming.openedCount == 3 && browser.location == .directory(value.first) && settled(browser) }
            try UIVerification.require(browser.tabs.count == 2 && browser.loadError == nil
                && browser.displayedEntries.map(\.name) == ["Child"], "Duplicate URL failed to reuse its original tab/grant")
            await incoming.closeAndDrain()
            controller.suspendBrowsing(); await controller.flushSession()
            try await wait { ApplicationFileActivity.gate.activeCount == 0 }
            controller.window?.close(); owner = nil
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let container = try await containerUsage()
            try await value.record("drained", ["passed": true, "opened": incoming.openedCount,
                "tabs": browser.tabs.count, "activityCount": ApplicationFileActivity.gate.activeCount,
                "peakRSSBytes": usage.ru_maxrss, "bookmarks": 0, "fileBodiesRead": 0,
                "operations": 0, "networkConnections": 0, "keychainQueries": 0,
                "containerDataBytes": container.bytes, "containerDataEntries": container.entries])
        } catch {
            failure = String(describing: error)
            NSLog("TRAVERSE_GENERATED_INCOMING_FAILURE %@", String(describing: error))
        }
        if let failure, let context {
            await delegate.incomingForSystemVerification.closeAndDrain()
            owner?.suspendBrowsing(); await owner?.flushSession(); owner?.window?.close()
            try? await context.record("failed", ["passed": false, "message": failure])
        }
        if failure != nil { NSApplication.shared.terminate(nil) }
    }
    private static func containerUsage() async throws -> (bytes: UInt64, entries: Int) {
        let identifier = Bundle.main.bundleIdentifier!, home = FileManager.default.homeDirectoryForCurrentUser
        guard home.path.hasSuffix("/Library/Containers/" + identifier + "/Data") else {
            throw UIVerification.Failure(message: "Generated container home is not isolated")
        }
        return try await Task.detached {
            var pending = [home], bytes: UInt64 = 0, entries = 0
            while let path = pending.popLast() {
                var facts = stat()
                guard lstat(path.path, &facts) == 0, facts.st_size >= 0 else { throw UIVerification.Failure(message: "Generated container metadata unavailable") }
                entries += 1
                if facts.st_mode & S_IFMT == S_IFDIR {
                    pending += try FileManager().contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
                } else { bytes += UInt64(facts.st_size) }
                guard entries <= 256, bytes <= 16 * 1024 * 1024 else { throw UIVerification.Failure(message: "Generated container bound") }
            }
            return (bytes, entries)
        }.value
    }
    private static func unreadable(_ urls: [URL]) async -> Bool {
        await Task.detached {
            urls.allSatisfy { (try? FileManager().contentsOfDirectory(atPath: $0.appendingPathComponent("Child").path)) == nil }
        }.value
    }
    private static func settled(_ browser: BrowserViewController) -> Bool {
        !browser.isLoading && browser.orderingTask == nil && browser.canvasTransition == nil
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 12
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < end else { throw UIVerification.Failure(message: "Generated incoming-browser phase did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
