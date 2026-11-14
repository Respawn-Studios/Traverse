#if DEBUG
import AppKit
import StorageAnalysis
import SwiftUI

@MainActor
enum StorageApplicationLayoutVerification {
    private static func require(_ condition: Bool, _ message: String) throws { try UIVerification.require(condition, message) }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try require(condition(), message)
    }
    static func run(result: StorageAnalysisResult, report: AnalysisAttributionReport, capture: URL?) async throws -> [String] {
        try require(result.supportsApplicationLayouts, "Application Layouts header capability missing")
        let drill = StorageBreakdownChartModel(); drill.configure(result)
        try require(drill.applicationLayouts == nil && !drill.loading && result.activeReaderCount == 0,
            "Configuring a chart eagerly queried Application Layouts")
        drill.loadApplicationLayouts()
        try await wait("Native Application Layouts query did not finish") { drill.applicationLayouts != nil && !drill.loading && result.activeReaderCount == 0 }
        guard let groups = drill.applicationLayouts else { throw StorageScanFailure.invalidOutput }
        try require(groups.groups.first(where: { $0.id == 2 })?.value.bytes.dataLogical.knownBytes == 30
            && groups.groups.first(where: { $0.id == 3 })?.value.bytes.dataLogical.knownBytes == 40,
            "Application Layouts lost its literal Steam30/40-byte partition")
        drill.loadApplicationLayouts()
        try require(!drill.loading && result.activeReaderCount == 0, "Cached layout grouping started another query")
        let window = NSWindow(contentRect: .init(x: 240, y: 180, width: 580, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Application Layouts · Generated native review"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StorageAttributionView.applicationLayoutsVerificationView(report: report, drill: drill).padding(20))
        defer { drill.close(); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await wait("Native Application Layouts surface unavailable") { StorageDimensionalChartProbe.latest?.window === window }
        guard let surface = StorageDimensionalChartProbe.latest else { throw StorageScanFailure.invalidOutput }
        try await wait("Native Application Layouts root did not settle") { surface.frames.count == 1 && !surface.isAnimating }
        if let capture { try await UIVerification.snapshot(window, to: capture) }
        guard let installed = groups.attributionSlices(scopeName: "Generated").first(where: {
            $0.storedTarget == .filtered(folder: 0, facet: .applicationLayouts, key: 2)
        }), let target = installed.storedTarget,
              let index = surface.frames.last?.slices.firstIndex(where: { $0.id == StorageChartIntegration.key(target) }) else {
            throw UIVerification.Failure(message: "Native Application Layouts target missing")
        }
        surface.activateForQualification(.slice(index))
        try await wait("Native layout root drill unavailable") { drill.levels.count == 1 && !drill.loading && surface.frames.count == 2 && !surface.isAnimating }
        try require(drill.current?.value.rows.first?.title == "common" && surface.frames.last?.slices.first?.bytes == 30,
            "Application Layouts repeated outer ancestry or lost its selected root")
        surface.activateForQualification(.slice(0))
        try await wait("Native filtered layout child unavailable") { drill.levels.count == 2 && !drill.loading && surface.frames.count == 3 && !surface.isAnimating }
        try require(drill.current?.value.rows.first?.title == "Game" && surface.frames.last?.slices.first?.bytes == 30,
            "Application Layouts child lost its stored key")
        drill.returnToLevelCount(0)
        try await wait("Layout Back did not settle") { surface.frames.count == 1 && !surface.isAnimating }
        try require(drill.applicationLayouts != nil && result.activeReaderCount == 0, "Back lost its cached layout grouping")
        drill.open(target, title: "Cancelled at close"); drill.close()
        window.contentView = nil; window.close()
        await result.waitUntilReadersDrained()
        try require(!drill.canBrowse && !drill.canShowApplicationLayouts && drill.applicationLayouts == nil && result.activeReaderCount == 0,
            "Closing Application Layouts retained stale capability or readers")
        return ["explicit optional layout capability", "lazy grouping; cached repeat", "native Applications and Layouts view",
            "recognized root jump", "layout filter retained through native child", "cached Back without rescan", "layout close/query drain"]
    }
}
#endif
