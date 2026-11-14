#if DEBUG
import AppKit
import CryptoKit
import Darwin
import ExplorerCore
import LocalStorage

@MainActor enum ArchiveBrowserVerification {
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b09-zip-browser")
        try UIVerification.require(root.deletingLastPathComponent() == base && root.resolvingSymlinksInPath() == root
            && UUID(uuidString: root.lastPathComponent) != nil && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path),
            "Archive QA requires an admitted generated root")
        let source = root.appendingPathComponent("source/Generated.zip"), args = ProcessInfo.processInfo.arguments
        let scale = args.contains("--zip-scale"), drive = args.contains("--drive-archive-browser")
        let before = try await digest(source)
        browser.permitsBackgroundVerification = true
        browser.settings.reviewsRecoveryAtStartup = false; browser.settings.autoRefreshFolders = false
        browser.settings.navigationStyle = .glass; browser.settings.appearance = .dark
        browser.navigate(to: .directory(root.appendingPathComponent("source")))
        try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
        browser.reloadFileRows(preserving: [source])
        try UIVerification.require(browser.selectedZIPURL == source && browser.commandEnabled(#selector(BrowserViewController.browseZIP(_:))), "Native ZIP command did not bind the selected regular archive")
        try UIVerification.require(BrowserMenus.fileContextMenu(target: browser).items.contains { $0.action == #selector(BrowserViewController.browseZIP(_:)) }, "ZIP context command missing")
        let baseline = resident(), start = ProcessInfo.processInfo.systemUptime
        browser.browseZIP(nil)
        guard let controller = ApplicationZIPBrowser.shared.controller else { throw UIVerification.Failure(message: "Archive window missing") }
        let model = controller.model
        try await wait { !model.isLoading && !model.isPaging && model.page != nil }
        try await Task.sleep(for: .milliseconds(16))
        controller.window?.contentView?.layoutSubtreeIfNeeded(); controller.window?.displayIfNeeded()
        try UIVerification.require(table(in: controller.window)?.numberOfRows == model.page?.items.count, "Native archive table did not install the bounded page")
        let firstPage = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        controller.window?.title = "Generated archive browser · " + root.lastPathComponent.prefix(8)
        if browser.isControlledVerification { controller.window?.setFrameOrigin(.init(x: -12000, y: -12000)) }
        try UIVerification.require(model.summary?.files == (scale ? 100_000 : 34), "Generated archive lost members")
        var timings: [Double] = []
        if scale {
            try UIVerification.require(model.page?.items.count == 256 && model.page?.total == 100_000, "Native wide ZIP page is not bounded")
            for index in 0..<20 {
                let started = ProcessInfo.processInfo.systemUptime
                model.filter = String(format: "Item %06d", 99_999 - index); model.applyFilter(); await model.drain()
                try await Task.sleep(for: .milliseconds(16))
                controller.window?.contentView?.layoutSubtreeIfNeeded(); controller.window?.displayIfNeeded()
                timings.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                try UIVerification.require(model.page?.items.count == 1, "Native filter lost its generated member")
            }
            model.filter = ""; model.applyFilter(); await model.drain()
            model.nextPage(); await model.drain()
            try UIVerification.require(model.page?.offset == 256 && model.page?.items.count == 256, "Native next page failed")
            model.previousPage(); await model.drain()
        } else {
            if drive {
                try UIVerification.require(controller.window?.isVisible == true && !browser.isControlledVerification, "Input QA needs the visible generated archive")
                try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/input-ready"), options: .withoutOverwriting)
                try await wait(seconds: 90) { model.page?.breadcrumbs.last?.name == "Documents" }
                try await wait(seconds: 90) { model.filter == "Notes" && model.page?.items.count == 1 }
                try await wait(seconds: 90) { model.page?.breadcrumbs.count == 1 && model.filter.isEmpty }
            }
            guard let folder = model.page?.items.first(where: { $0.name == "Documents" })?.folder else { throw UIVerification.Failure(message: "Generated Documents folder missing") }
            model.navigate(folder); await model.drain()
            try UIVerification.require(model.page?.items.count == 2 && model.page?.breadcrumbs.count == 2, "Native folder navigation failed")
            model.filter = "Notes"; model.applyFilter(); await model.drain()
            try UIVerification.require(model.page?.items.map(\.name) == ["Notes.txt"], "Native folder filter failed")
            model.back(); await model.drain(); model.forward(); await model.drain()
            try UIVerification.require(model.page?.folder == folder && model.filter == "Notes", "Back/Forward did not restore the virtual location and its name filter")
            model.up(); await model.drain()
            ApplicationZIPBrowser.shared.prepareForVolumeQuiescence()
            try UIVerification.require(model.suspended && !model.isLoading, "Archive quiescence did not stop demand")
            ApplicationZIPBrowser.shared.resumeAfterVolumeQuiescence()
            model.refresh(); await model.drain()
            try UIVerification.require(model.page?.breadcrumbs.count == 1 && !model.suspended, "Archive refresh after quiescence failed")
        }
        if let window = controller.window, !browser.isControlledVerification {
            try await Task.sleep(for: .milliseconds(350)); window.contentView?.layoutSubtreeIfNeeded()
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/archive-native.png"))
        }
        let peak = peakResident(), added = peak > baseline ? peak - baseline : 0
        let sorted = timings.sorted(), p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let closeStart = ProcessInfo.processInfo.systemUptime
        await ApplicationZIPBrowser.shared.stopAndDrain()
        let drain = (ProcessInfo.processInfo.systemUptime - closeStart) * 1_000
        try UIVerification.require(ApplicationZIPBrowser.shared.controller == nil && ApplicationFileActivity.gate.activeCount == 0, "Closed ZIP tool retained a catalog or I/O owner")
        try UIVerification.require(try await digest(source) == before, "Archive source changed during read-only QA")
        try UIVerification.require(!FileManager().fileExists(atPath: root.appendingPathComponent("source/Documents").path), "Archive members were materialized by browsing")
        return ["passed": !scale || firstPage <= 5_000 && p95 <= 100 && added <= 256 * 1_024 * 1_024 && drain <= 2_000,
            "scale": scale, "firstPageMilliseconds": firstPage, "filterMilliseconds": timings, "filterP95Milliseconds": p95,
            "baselineRSS": baseline, "peakRSS": peak, "addedRSS": added, "closeDrainMilliseconds": drain,
            "physicalInput": drive, "sourceUnchanged": true, "membersMaterialized": false,
            "ordinaryActivation": ArchiveBrowseActivation.enabled,
            "notExercised": ["Payload CRC/integrity", "Extraction", "Minimum OS", "Disconnected device", "Personal archives"]]
    }
    private static func digest(_ url: URL) async throws -> Data {
        try await Task.detached { Data(SHA256.hash(data: try Data(contentsOf: url))) }.value
    }
    private static func table(in window: NSWindow?) -> NSTableView? {
        guard let content = window?.contentView else { return nil }; var stack = [content]
        while let view = stack.popLast() { if let table = view as? NSTableView { return table }; stack.append(contentsOf: view.subviews) }
        return nil
    }
    private static func wait(seconds: Double = 20, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), "Native archive work did not settle")
    }
    private static func resident() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        } }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
    private static func peakResident() -> UInt64 { var value = rusage(); _ = getrusage(RUSAGE_SELF, &value); return UInt64(max(0, value.ru_maxrss)) }
}
#endif
