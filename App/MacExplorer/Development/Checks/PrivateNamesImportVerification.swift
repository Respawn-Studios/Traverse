#if DEBUG
import AppKit
import Darwin
import FileMemory

@MainActor enum PrivateNamesImportVerification {
    static func runScale(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b07-integrated-acceptance")
        try UIVerification.require(root.deletingLastPathComponent() == base && root.resolvingSymlinksInPath() == root
            && UUID(uuidString: root.lastPathComponent) != nil
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Native scale needs its own admitted case")
        let owner = ApplicationPrivateNames(directory: root.appendingPathComponent("names"), settings: browser.settings, enablesImport: true)
        browser.privateNames = owner
        browser.settings.autoRefreshFolders = false; browser.settings.reviewsRecoveryAtStartup = false
        let controller = PrivateNamesWindowController(owner: owner)
        controller.show(browser: browser)
        if browser.isControlledVerification { controller.window?.setFrameOrigin(NSPoint(x: -12000, y: -12000)) }
        var intervals: [Double] = [], previous = ProcessInfo.processInfo.systemUptime
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime
                if intervals.count < 4096 { intervals.append((now - previous) * 1000) }
                previous = now
            }
        }
        defer { heartbeat.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        let preview = try await owner.prepareNameImport(root.appendingPathComponent("metadata/input.json"))
        try UIVerification.require(preview.recordCount == 100_000, "Native scale input is not the frozen 100k corpus")
        guard case .imported = await owner.applyNameImport(preview) else { throw UIVerification.Failure(message: "Native scale import failed") }
        let model = controller.model
        try await wait { !model.loading && model.rows.count == 64 && model.rows.allSatisfy { $0.availability == .needsRelink } }
        let displayMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        model.query = "000333"; model.reload()
        try await wait { !model.loading && model.rows.count == 1 && model.rows[0].availability == .needsRelink }
        heartbeat.cancel(); await heartbeat.value
        intervals.sort()
        var usage = rusage(); try UIVerification.require(getrusage(RUSAGE_SELF, &usage) == 0, "Native memory measurement unavailable")
        let p95 = intervals.isEmpty ? 0 : intervals[min(intervals.count-1, intervals.count*95/100)]
        let maximum = intervals.max() ?? 0
        let passed = usage.ru_maxrss <= 256 * 1024 * 1024 && p95 <= 100 && maximum <= 250
            && owner.management?.savedItems == 100_000 && owner.management?.storedReferences == 0
        let report: [String: Any] = ["passed": passed, "records": 100_000, "scanToNativeDisplayMilliseconds": displayMilliseconds,
            "mainHeartbeatP95Milliseconds": p95, "mainHeartbeatMaxMilliseconds": maximum, "samples": intervals.count,
            "peakRSSBytes": usage.ru_maxrss, "visibleRows": 64, "noNativeAccess": true,
            "configuration": "Signed development app; optimized module timing measured separately"]
        controller.close(); await owner.close(); browser.suspendBrowser()
        try await wait { ApplicationFileActivity.gate.activeCount == 0 }
        return report
    }
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b07-continuity-management", isDirectory: true)
        try UIVerification.require(root.deletingLastPathComponent() == expected && root.resolvingSymlinksInPath() == root
            && UUID(uuidString: root.lastPathComponent) != nil
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Import QA needs an admitted generated root")
        guard let parent = browser.view.window else { throw UIVerification.Failure(message: "Import parent window missing") }
        let input = root.appendingPathComponent("source/import.json"), names = root.appendingPathComponent("names")
        let settings = browser.settings
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
        let owner = ApplicationPrivateNames(directory: names, settings: settings, enablesImport: true)
        browser.privateNames = owner
        browser.navigate(to: .directory(input.deletingLastPathComponent()))
        let cancelled = try await owner.prepareNameImport(input)
        try UIVerification.require(cancelled.recordCount == 2 && cancelled.discardedLocations == 2,
            "Native import preview lost field-only counts")
        try UIVerification.require(!(try await confirm(cancelled, owner: owner, window: parent, accept: false)), "Cancel was accepted")
        owner.cancelNameImport()
        try UIVerification.require(!FileManager().fileExists(atPath: names.path), "Cancelled preview created a catalog")
        let forgotten = try await owner.prepareNameImport(input)
        try UIVerification.require(try await owner.forgetAllNames() == .forgotten, "Absent-catalog Forget failed")
        try UIVerification.require(await owner.applyNameImport(forgotten) == .notImported(.stalePreview)
            && !FileManager().fileExists(atPath: names.path), "An old preview recreated forgotten names")
        let controller = PrivateNamesWindowController(owner: owner)
        controller.show(browser: browser)
        if browser.isControlledVerification { controller.window?.setFrameOrigin(NSPoint(x: -12000, y: -12000)) }
        let model = controller.model
        try await wait { !model.loading }
        let preview = try await owner.prepareNameImport(input)
        try UIVerification.require(try await confirm(preview, owner: owner, window: parent, accept: true), "Native Import confirmation refused")
        guard case .imported(let attempt) = await owner.applyNameImport(preview), attempt.records == 2 else {
            throw UIVerification.Failure(message: "Confirmed native import failed")
        }
        try await wait { !model.loading && model.rows.count == 2 && model.rows.allSatisfy { $0.availability == .needsRelink } }
        try UIVerification.require(owner.management?.savedItems == 2 && owner.management?.storedReferences == 0,
            "Import added a reference or failed to refresh Privacy counts")
        let firstIDs = Set(model.rows.map(\.id))
        model.query = "Orion"; model.reload()
        try await wait { !model.loading && model.rows.count == 1 && model.rows[0].availability == .needsRelink }
        try UIVerification.require(model.rows[0].title == "Orion imported report" && model.rows[0].location == nil,
            "Imported names were not directly searchable, or a path became access")
        let duplicate = try await owner.prepareNameImport(input)
        try UIVerification.require(duplicate.matchingDescriptions == 2, "Duplicate preview did not explain existing descriptions")
        owner.cancelNameImport()
        model.query = ""; model.reload()
        try await wait { !model.loading && Set(model.rows.map(\.id)) == firstIDs }
        if let window = controller.window {
            window.title = "Remembered Items · generated import acceptance"
            window.contentView?.layoutSubtreeIfNeeded()
            if !browser.isControlledVerification {
                try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("import-native.png"))
            } else { try await UIVerification.snapshot(window, to: root.appendingPathComponent("import-native.png")) }
        }
        controller.close(); await owner.close()
        let cold = ApplicationPrivateNames(directory: names, settings: settings, enablesImport: true)
        await cold.refreshManagement()
        try UIVerification.require(cold.management?.savedItems == 2 && cold.management?.storedReferences == 0,
            "Native cold reopening lost imported descriptions")
        await cold.close(); browser.suspendBrowser()
        try await wait { ApplicationFileActivity.gate.activeCount == 0 }
        return ["passed": true, "metadataOnly": true, "personalCatalogOpened": false,
            "checks": ["Native sheet Cancel creates nothing", "Actual Import button commits complete batch",
                "Absent-catalog Forget invalidates preview before creation", "Open Remembered Items refreshes after import",
                "Direct indexed names, Needs Relink and no imported access", "Duplicate warning leaves records unchanged",
                "Cold reopening and actual access/worker drain"],
            "notExercised": ["Physical Open-panel file selection", "Time Machine or grant restore", "Power loss"]]
    }
    private static func confirm(_ preview: PreparedNameImport, owner: ApplicationPrivateNames,
                                window: NSWindow, accept: Bool) async throws -> Bool {
        let action = Task { await owner.reviewNameImport(preview, in: window) }
        try await wait { window.attachedSheet != nil }
        guard let sheet = window.attachedSheet, let content = sheet.contentView else {
            throw UIVerification.Failure(message: "Native import sheet missing")
        }
        var pending = [content], button: NSButton?
        while let view = pending.popLast() {
            if let candidate = view as? NSButton,
               candidate.title == (accept ? "Import \(preview.recordCount) Descriptions" : "Cancel") { button = candidate; break }
            pending.append(contentsOf: view.subviews)
        }
        guard let button else { throw UIVerification.Failure(message: "Native import confirmation button missing") }
        button.performClick(nil)
        return await action.value
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), "Native import presentation did not settle")
    }
}
#endif
