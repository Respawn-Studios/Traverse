import AppKit
import Foundation

#if DEBUG
extension UIVerification {
    /// Call only with the owned fixture and evidence roots already validated by run().
    static func verifyProperties(_ browser: BrowserViewController, fixture: URL, output: URL) async throws {
        let file = fixture.appendingPathComponent("Résumé – नमस्ते – 日本語.txt")
        let folder = fixture.appendingPathComponent("Folder A", isDirectory: true)
        let link = fixture.appendingPathComponent("Broken link")
        let missing = fixture.appendingPathComponent("not-created-by-fixture")
        let reader = FilePropertiesReader()
        let report = try await reader.read([file, folder, link, missing])
        try require(report.observations.count == 4 && report.unavailableCount == 1, "Properties lost unavailable-item coverage")
        try require(report.observations[0].byteCount != nil && report.observations[0].mode != nil,
                    "Properties did not inspect ordinary file metadata")
        try require(report.observations[1].isDirectory && report.observations[1].byteCount == nil,
                    "Properties calculated a folder's recursive size")
        try require(report.observations[2].isSymbolicLink && report.observations[2].failure == nil,
                    "Properties followed or rejected a broken symbolic link")
        let bounded = try await reader.read(Array(repeating: file, count: FilePropertiesReader.maximumInspectedItems + 1))
        try require(bounded.observations.count == FilePropertiesReader.maximumInspectedItems && bounded.omittedCount == 1,
                    "Properties inspection was not bounded or coverage was inaccurate")
        let unsupported = try await reader.read([URL(string: "https://example.invalid/not-a-local-file")!])
        try require(unsupported.unavailableCount == 1, "Properties accepted a non-local URL")

        let cancelled = Task { try await reader.read([file]) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw Failure(message: "Cancelled Properties metadata read completed successfully")
        } catch is CancellationError {}

        // Deliberately complete an old request after the newer request. This fake
        // ignores cancellation so rejection also depends on the model's revision.
        let oldReport = try await reader.read([file])
        let newReport = try await reader.read([folder])
        let delayed = PropertiesDelayedVerificationReader(oldURL: file, oldReport: oldReport, newReport: newReport)
        let model = FilePropertiesModel(reader: delayed, copyPaths: { _ in })
        model.update(urls: [file])
        try await Task.sleep(for: .milliseconds(20))
        model.update(urls: [folder])
        try await waitUntil("New Properties selection") { !model.isLoading && model.report != nil }
        try await Task.sleep(for: .milliseconds(260))
        try require(model.report?.observations.first?.url == folder, "A stale Properties read replaced the newer selection")
        model.update(urls: [file])
        model.cancel()
        try await Task.sleep(for: .milliseconds(260))
        try require(!model.isLoading && model.report == nil, "Cancelled Properties session repainted its content")

        let appearance = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = appearance }
        let content = NSView()
        let surface = NavigationGlassSurface(contentView: content)
        surface.isGlassEnabled = false
        try require(surface.isUsingOpaqueSurface && content.isDescendant(of: surface), "Solid navigation material lost its content")
        surface.isGlassEnabled = true
        try require(surface.isUsingOpaqueSurface == NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                    && content.isDescendant(of: surface), "Glass material did not respect Reduce Transparency or retain its content")

        var copied: [URL] = []
        let controller = FilePropertiesWindowController(copyPaths: { copied = $0 })
        defer { controller.window?.orderOut(nil); controller.cancel() }
        BrowserAppearanceController.apply(.light)
        let controlled = ProcessInfo.processInfo.arguments.contains("--offscreen")
        if controlled { controller.update(urls: [file]) }
        else { controller.show(urls: [file], relativeTo: browser.view.window) }
        try await waitUntil("Single-item Properties and Light appearance") {
            !controller.model.isLoading && controller.model.report != nil
                && controller.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        }
        controller.model.copyPaths(controller.model.urls)
        try require(copied == [file], "Properties Copy Path did not use the injected writer")
        try require(controller.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
                    "Properties did not adopt the Light application appearance")
        try await snapshot(controller.window!, to: output.appendingPathComponent("10-properties-light.png"))
        BrowserAppearanceController.apply(.dark)
        controller.update(urls: [file, folder, link, missing])
        try await waitUntil("Multiple-item Properties and Dark appearance") {
            !controller.model.isLoading && controller.model.report != nil
                && controller.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        try require(controller.model.report?.selectedCount == 4, "Properties panel retained the old selection")
        try require(controller.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                    "Properties did not adopt the Dark application appearance")
        try await snapshot(controller.window!, to: output.appendingPathComponent("11-properties-dark-multiple.png"))
        BrowserAppearanceController.apply(.system)
        try require(NSApplication.shared.appearance == nil, "System appearance retained an application override")
        controller.close()
        try await waitUntil("Properties window close") { controller.window?.isVisible == false }
        if !controlled { browser.view.window?.makeKeyAndOrderFront(nil) }
    }
}

private struct PropertiesDelayedVerificationReader: FilePropertiesReading {
    let oldURL: URL
    let oldReport: FilePropertiesReport
    let newReport: FilePropertiesReport

    func read(_ urls: [URL]) async throws -> FilePropertiesReport {
        let old = urls.first == oldURL
        let report = old ? oldReport : newReport
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (old ? 0.2 : 0.01)) {
                continuation.resume(returning: report)
            }
        }
    }
}
#endif
