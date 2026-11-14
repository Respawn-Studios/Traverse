#if DEBUG
import AppKit
import ExplorerCore
import StorageAnalysis

@MainActor enum LargestFilesVerification {
    private final class WeakResult { weak var value: StorageAnalysisResult? }
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              root.resolvingSymlinksInPath().path == root.path,
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let marker = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["action"] as? String == "traverse-largest-files-ui" else { exit(2) }
        let gate = FileActivityGate(), weakResult = WeakResult()
        var checks: [String] = [], failures: [String] = [], metrics: [String: Any] = [:]
        do {
            try await verify(root: root, gate: gate, weakResult: weakResult, checks: &checks, metrics: &metrics)
            try await wait("Closed native model retained its result or activity") { weakResult.value == nil && gate.activeCount == 0 }
            checks.append("Close releases largest-mode result ownership after actual reader/activity drain")
        } catch { failures.append(String(describing: error)) }
        try? JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "checks": checks, "failures": failures,
            "metrics": metrics, "generatedOnly": true, "sourceContentsReadByScanner": false,
            "personalCatalogs": 0, "networkRequests": 0, "retainedQualificationCatalog": true,
            "drained": gate.activeCount == 0], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root: URL, gate: FileActivityGate, weakResult: WeakResult,
                               checks: inout [String], metrics: inout [String: Any]) async throws {
        let settings = BrowserSettings(persist: false)
        settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true; settings.motion.mode = .off
        StorageChartIntegration.configure(settings: settings)
        let source = root.appendingPathComponent("source")
        StoredAnalysisTableProbe.enabled = true
        defer { StoredAnalysisTableProbe.enabled = false }
        let storage = try AnalysisResultStorage(directory: root.appendingPathComponent("catalog"), sessionByteLimit: 8 << 20,
            poolByteLimit: 8 << 20, preserveAfterClose: true)
        let worker = ProcessInfo.processInfo.arguments.contains("--ordinary-largest-files")
            ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/storage-scanner-worker") : root.appendingPathComponent("worker")
        let scanner = StorageScanner(workerURL: worker, activityGate: gate)
        let session = try scanner.startPaged(root: source, storage: storage, retainingAccess: "Admitted generated Largest Files root only")
        let controller = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: { session.cancel() }, onAppStorage: {})
        controller.applyToolStyle(settings)
        guard let window = controller.window else { throw UIVerification.Failure(message: "Missing native analysis window") }
        window.setFrame(.init(x: 140, y: 140, width: 960, height: 640), display: true)
        controller.showWindow(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let backdrop = ProcessInfo.processInfo.arguments.contains("--record-motion") ? GlassVerification.makeBrowserBackdropWindow(behind: window) : nil
        defer { controller.close(); backdrop?.close(); session.cancel() }
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates {
            controller.renderPaged(root: source, update: update)
            if update.workerDrained { terminal = update }
        }
        await session.waitUntilDrained()
        guard let terminal, let result = terminal.result else { throw UIVerification.Failure(message: "Generated scan result unavailable") }
        weakResult.value = result
        defer { result.retainAfterCloseForQualification() }
        let summary = try await result.summary()
        try UIVerification.require(summary.complete && result.supportsLargestFiles, "Isolated helper did not bind its new optional result capability")
        let attribution = try await result.attribution(scopeName: source.lastPathComponent, summary: summary)
        controller.renderPaged(root: source, update: terminal, summary: summary, report: attribution)
        guard let model = controller.pagedModelForVerification else { throw UIVerification.Failure(message: "Native stored browser missing") }
        try await settled(model)
        guard let folder = model.rows.first(where: { $0.kind == .directory && $0.title == "One" }) else {
            throw UIVerification.Failure(message: "Generated child folder missing")
        }
        model.open(folder); try await settled(model)
        try UIVerification.require(model.hasNext, "Generated browse fixture did not span two stored pages")
        model.next(); try await settled(model)
        try UIVerification.require(model.cursor > 0 && model.canGoBack, "Generated browse cursor did not advance")
        let position = (model.title, model.ancestors.count, model.cursor, model.sortOrder)
        let began = CACurrentMediaTime()
        model.changeMode(.largest); try await settled(model)
        metrics["nativeLargestFirstDisplayMilliseconds"] = (CACurrentMediaTime() - began) * 1000
        guard let oracle = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("oracle.json"))) as? [String: UInt64] else {
            throw UIVerification.Failure(message: "Generated literal source oracle missing")
        }
        let largest = try await result.largestFiles()
        let expected = oracle.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            let left = Data((a.key as NSString).lastPathComponent.utf8), right = Data((b.key as NSString).lastPathComponent.utf8)
            // This fixture's equal-sized distinct names are unique. Exact
            // duplicate-name ties are independently covered by Rust/Swift.
            return left.lexicographicallyPrecedes(right)
        }.prefix(32)
        try UIVerification.require(model.mode == .largest && model.rows.count == 32 && !model.hasNext && !model.canSort
            && largest.rankableFileNames == oracle.count && largest.unknownSizeFileNames == 0
            && largest.files.map { String(data: $0.rawRelativePath, encoding: .utf8)! } == expected.map(\.key),
            "Largest Files lost its full-analysis scope, exact literal ranking or fixed row bound")
        try await wait("Primary native table did not install largest rows") {
            StoredAnalysisTableProbe.latest?.window === window && StoredAnalysisTableProbe.latest?.installedRowIDsForQualification == model.rows.map(\.id)
        }
        guard let table = StoredAnalysisTableProbe.latest else { throw UIVerification.Failure(message: "Primary analysis table missing") }
        window.contentView?.layoutSubtreeIfNeeded()
        let recordedIndex = table.column(withIdentifier: .init("recorded"))
        metrics["largestVisibleTableWidth"] = table.visibleRect.width
        metrics["largestScrollContentWidth"] = table.enclosingScrollView?.contentSize.width
        metrics["largestClipVisibleWidth"] = table.enclosingScrollView?.contentView.visibleRect.width
        metrics["largestVisibleTableOrigin"] = table.visibleRect.minX
        metrics["largestRecordedColumnRight"] = recordedIndex >= 0 ? table.rect(ofColumn: recordedIndex).maxX : -1
        metrics["largestCellSpacing"] = table.intercellSpacing.width
        metrics["largestSortDescriptorCount"] = table.sortDescriptors.count
        metrics["largestColumns"] = table.tableColumns.map { ["id": $0.identifier.rawValue, "width": $0.width, "hidden": $0.isHidden] as [String: Any] }
        try UIVerification.require(table.tableColumns.first { $0.identifier.rawValue == "recorded" }?.isHidden == false
            && table.tableColumns.first { $0.identifier.rawValue == "files" }?.isHidden == true && table.sortDescriptors.isEmpty
            && recordedIndex >= 0 && table.rect(ofColumn: recordedIndex).maxX <= table.visibleRect.maxX + 2
            && table.enclosingScrollView?.hasHorizontalScroller == false,
            "Native largest table retained misleading folder columns or sortable headers")
        try UIVerification.require(table.rows(in: table.visibleRect).location == 0,
            "Largest mode did not show its first ranked row at the top")
        metrics["largestColumnWidths"] = Dictionary(uniqueKeysWithValues: table.tableColumns.filter { !$0.isHidden }.map { ($0.identifier.rawValue, $0.width) })
        checks.append("Actual generated scan, source-free result and native32-row mode match a literal cross-folder/sparse/hardlink oracle")
        let launchesBeforeReturn = result.queryWorkerLaunchCountForQualification
        model.changeMode(.browse); try await settled(model)
        try UIVerification.require(model.title == position.0 && model.ancestors.count == position.1 && model.cursor == position.2
            && model.sortOrder == position.3 && result.queryWorkerLaunchCountForQualification == launchesBeforeReturn,
            "Returning to Browse lost the prior folder position or bypassed its bounded cached page")
        checks.append("Browse preserves a nonzero page cursor/folder/sort using the existing bounded cache without another child")
        for mode in BrowserMotionMode.allCases {
            settings.motion.mode = mode; controller.applyToolStyle(settings)
            model.changeMode(.browse); try await settled(model)
            if ProcessInfo.processInfo.arguments.contains("--record-motion") {
                window.title = "Largest files · generated review"
                let report = try await NativeMotionRecorder.record(window: window, root: root, label: "largest-" + mode.rawValue) { model.changeMode(.largest) }
                try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/largest-" + mode.rawValue + ".json"), options: .withoutOverwriting)
            } else { model.changeMode(.largest) }
            try await settled(model)
            try UIVerification.require(model.rows.count == 32, "Mode transition dropped largest-file rows")
        }
        window.contentView?.layoutSubtreeIfNeeded()
        model.changeLargestMetric(.allocated); try await settled(model)
        try UIVerification.require(model.rows.count == 32 && model.largestMetric == .allocated && model.message.contains("Shared blocks"),
            "Allocation ranking was displayed as exclusive or lost its mode")
        model.changeLargestMetric(.logical); model.changeMode(.browse); model.changeMode(.largest)
        model.changeLargestMetric(.allocated); model.changeLargestMetric(.logical)
        try await settled(model)
        try UIVerification.require(model.largestMetric == .logical && model.rows.first?.value.bytes.dataLogical.knownBytes == 256 << 10,
            "Rapid mode/metric changes allowed a stale result to replace the latest request")
        checks.append("Logical/allocation mode changes coalesce and reject obsolete responses through the existing query owner")
        guard let first = model.rows.first else { throw UIVerification.Failure(message: "No generated selected row") }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await wait("Native largest selection did not reach its model") { model.selectedID == first.id }
        var resolved: URL?
        controller.onLocationAction = { result, node, action, completion in
            Task {
                do { resolved = try await result.resolveLocation(node: node, retainingAccess: "Generated selected location only").url; completion("Recorded item verified") }
                catch { completion("Recorded item unavailable") }
            }
        }
        model.act(.copyPath)
        try await wait("Selected location action did not finish") { !model.actionRunning }
        let selectedPath = largest.files.first(where: { $0.id == first.id })!.rawRelativePath
        try UIVerification.require(resolved == source.appendingPathComponent(String(data: selectedPath, encoding: .utf8)!),
            "Largest-file action resolved a folder approximation instead of the exact recorded node")
        checks.append("Selected largest-file action resolves its exact current node through the existing fresh ancestry checks")
        window.setFrame(.init(x: 140, y: 100, width: 960, height: 820), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        if controller.compactBreakdownForVerification { controller.expandBreakdownButton.performClick(nil) }
        try await Task.sleep(for: .milliseconds(80))
        window.contentView?.layoutSubtreeIfNeeded()
        try UIVerification.require(!controller.compactBreakdownForVerification && table.visibleRect.height >= 100,
            "Expanded chart and Largest Files did not retain a usable native list")
        checks.append("Expanded layered chart and Largest Files coexist with a usable list before returning to compact width")
        window.setContentSize(.init(width: 740, height: 480)); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        try UIVerification.require(table.rect(ofColumn: recordedIndex).maxX <= table.visibleRect.maxX + 2,
            "Recorded folder requires horizontal scrolling at the supported narrow width")
        let late = Task { try await result.largestFiles() }
        model.close(); controller.close(); late.cancel()
        _ = try? await late.value
        await result.waitUntilReadersDrained()
        try UIVerification.require(result.activeReaderCount == 0 && gate.activeCount == 0 && model.rows.isEmpty,
            "Close retained a reader or allowed a late result to republish")
        checks.append("Close during a queued query cancels/drains without republishing rows")
    }
    private static func settled(_ model: PagedAnalysisBrowserModel) async throws {
        try await wait("Stored page failed to settle") { !model.loading && !model.hasWork }
    }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), message)
    }
}
#endif
