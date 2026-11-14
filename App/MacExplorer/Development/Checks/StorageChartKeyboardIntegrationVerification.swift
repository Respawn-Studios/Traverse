#if DEBUG
import AppKit
import StorageAnalysis

@MainActor enum StorageChartKeyboardIntegrationVerification {
    private static func require(_ condition: Bool, _ message: String) throws { try UIVerification.require(condition, message) }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UIVerification.Failure(message: message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func run(root: URL) async throws -> [String: Any] {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        try require(root == repository.appendingPathComponent(".build/b06-analyzer/classification-fixture-b901d8dc2fb3434b9335bc5bbaa1edfd"), "Retained generated Steam fixture required")
        let coordinator = ApplicationStorageAnalysis.shared
        let storage = try AnalysisResultStorage(directory: repository.appendingPathComponent(".build/b06-analyzer/full-scope-stores-20261018"), sessionByteLimit: 8 << 20)
        coordinator.enablePagedForQualification(storage: storage)
        let settings = BrowserSettings(persist: false)
        StorageChartIntegration.configure(settings: settings)
        StorageChartIntegration.startAtStorageRolesForQualification = true; StorageDimensionalChartProbe.enabled = true
        var accesses = 0, result: StorageAnalysisResult?, finished = false
        let properties = FilePropertiesWindowController(retainAccess: { _ in accesses += 1; return FileAccessLifetimes(leases: []) }, settings: settings, copyPaths: { _ in })
        defer {
            if !finished { result?.retainAfterCloseForQualification() }
            properties.cancel(); properties.close(); coordinator.toolWindow?.close()
            StorageChartIntegration.startAtStorageRolesForQualification = false; StorageDimensionalChartProbe.enabled = false
        }
        properties.show(urls: [root]); properties.window?.setContentSize(.init(width: 580, height: 780))
        try await wait("Keyboard integration shallow Properties") { !properties.model.isLoading }
        properties.model.analyzeStorage()
        try await wait("Keyboard integration stored result") { !coordinator.hasWork && coordinator.pagedSummaryForVerification != nil }
        result = coordinator.pagedResultForVerification
        try require(result != nil && coordinator.pagedSummaryForVerification?.value.bytes.dataLogical.knownBytes == 70
            && coordinator.pagedSummaryForVerification?.value.counts.regularFiles == 2, "Generated keyboard source oracle changed")
        try await wait("Keyboard integration native Properties chart") { StorageDimensionalChartProbe.latest?.window === properties.window }
        guard let surface = StorageDimensionalChartProbe.latest, let window = properties.window else { throw StorageScanFailure.invalidOutput }
        surface.forceVisiblePresentationForQualification = true
        try await wait("Properties root chart settled") { surface.frames.count == 1 && !surface.isAnimating }
        window.makeKeyAndOrderFront(nil); try require(window.makeFirstResponder(surface), "Properties chart focus failed")
        let scanAccesses = accesses
        surface.keyDown(with: UIVerification.key("", code: 124, flags: [], window: window))
        try require(surface.keyboardSelectionForQualification == 0, "Properties Right inspection did not retain focus")
        surface.keyDown(with: UIVerification.key("", code: 36, flags: [], window: window))
        let drill = properties.model.chartDrill
        try await wait("Keyboard Properties Steam query") { drill.levels.count == 1 && !drill.loading && surface.frames.count == 2 && !surface.isAnimating }
        try require(drill.current?.value.value.bytes.dataLogical.knownBytes == 70, "Keyboard drill changed the selected role")
        guard let items = surface.accessibilityChildren() as? [StorageChartAccessibilityElement],
              let installed = items.first(where: { $0.accessibilityLabel()?.hasPrefix("Installed items") == true }) else { throw UIVerification.Failure(message: "Properties installed-items semantic target missing") }
        try require(installed.isAccessibilityEnabled() && installed.accessibilityPerformPress(), "Properties semantic segment refused")
        try await wait("Semantic installed-items query") { drill.levels.count == 2 && !drill.loading && surface.frames.count == 3 && !surface.isAnimating }
        try require(drill.current?.value.value.bytes.dataLogical.knownBytes == 30 && !installed.accessibilityPerformPress(),
            "Semantic query lost its30-byte installed target or accepted a stale element")
        for expected in [2, 1] {
            surface.keyDown(with: UIVerification.key("", code: 53, flags: [], window: window))
            try await wait("Properties keyboard Back") { surface.frames.count == expected && !surface.isAnimating && !drill.loading }
        }
        properties.model.openFullAnalysis()
        try await wait("Keyboard same-result handoff") { coordinator.toolWindow?.pagedReadyForVerification == true
            && StorageDimensionalChartProbe.latest?.window === coordinator.toolWindow?.window }
        guard let tool = coordinator.toolWindow, let fullWindow = tool.window, let full = StorageDimensionalChartProbe.latest else { throw StorageScanFailure.invalidOutput }
        full.forceVisiblePresentationForQualification = true
        try await wait("Full analysis root settled") { full.frames.count == 1 && !full.isAnimating }
        fullWindow.makeKeyAndOrderFront(nil); try require(fullWindow.makeFirstResponder(full), "Full analysis chart focus failed")
        full.keyDown(with: UIVerification.key("", code: 124, flags: [], window: fullWindow))
        full.keyDown(with: UIVerification.key("", code: 49, flags: [], window: fullWindow))
        try await wait("Full analysis keyboard query") { tool.chartDrillForVerification.levels.count == 1
            && !tool.chartDrillForVerification.loading && full.frames.count == 2 && !full.isAnimating }
        try require(tool.chartDrillForVerification.current?.value.value.bytes.dataLogical.knownBytes == 70
            && coordinator.pagedResultForVerification?.id == result?.id && accesses == scanAccesses && !coordinator.hasWork,
            "Keyboard/semantic navigation rescanned or changed its source scope")
        let capture = repository.appendingPathComponent(".build/b06-analyzer/evidence-extension-20261018/integrated-keyboard-" + UUID().uuidString + ".png")
        try await UIVerification.snapshot(fullWindow, to: capture)
        properties.close(); tool.close(); await coordinator.stopAndDrain(); await result?.waitUntilReadersDrained()
        try require(ApplicationFileActivity.gate.activeCount == 0 && !surface.isAnimating && !full.isAnimating,
            "Integrated keyboard close retained work")
        finished = true
        return ["passed": true, "checks": ["actual Properties keyboard inspection", "Return uses stored role query", "semantic installed-items target",
            "stale semantic target refusal", "two keyboard Back levels", "same-result full-analysis handoff", "full-analysis Space query", "no source rescan/access", "close and actual query drain"],
            "source_body_reads": false, "generated_logical_bytes": 70, "capture": capture.lastPathComponent,
            "presentation_visibility_override": true, "physical_input_exercised": false, "activity_count": ApplicationFileActivity.gate.activeCount]
    }
}
#endif
