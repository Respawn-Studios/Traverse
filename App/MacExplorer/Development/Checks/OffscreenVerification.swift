import AppKit
import ExplorerCore

#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
extension UIVerification {
    /// Controlled AppKit verification for a locked/unavailable interactive
    /// session. Mouse delivery, native menu dispatch and foreground focus are
    /// deliberately NOT claimed. No session settings or system clipboard change.
    static func runOffscreen(_ controller: BrowserWindowController, fixture: URL, metadata: [String: Any], output: URL,
                             before: [String: String]) async throws {
        let browser = controller.browser
        browser.permitsBackgroundVerification = true
        defer { browser.permitsBackgroundVerification = false }
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        try await settled(browser)
        let chrome = try verifyWindowLayout(controller)
        try verifyRenderedTabs(browser)
        try await verifySidebarLayout(browser, output: output)
        try await snapshot(controller.window!, to: output.appendingPathComponent("01-this-mac.png"))
        var checks = ["Compact menu/header/tab/address geometry and rendered tab controls (offscreen)"]
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        let plainCount = metadata["plainFileCount"] as? Int ?? 0
        try require(browser.rawEntries.count == plainCount + 7, "Offscreen listing count is incorrect")
        try require(browser.rawEntries.filter { $0.kind == .symbolicLink }.count == 2
                    && browser.rawEntries.contains { $0.name == "Example.app" && $0.kind == .package },
                    "Offscreen listing changed link/package semantics")
        let measurements: [String: Any] = ["plainFileCount": plainCount, "visibleEntries": browser.displayedEntries.count,
                                          "topChromeHeight": chrome, "firstRowsMilliseconds": browser.firstRowsMilliseconds ?? -1,
                                          "enumerationMilliseconds": browser.enumerationMilliseconds ?? -1,
                                          "completeDisplayMilliseconds": browser.completeDisplayMilliseconds ?? -1]
        try await snapshot(controller.window!, to: output.appendingPathComponent("02-details.png"))
        browser.folderFilter.selectScope(0)
        browser.focusBrowserContent()
        browser.filterField.stringValue = "Résumé"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
        try await settled(browser)
        try require(browser.displayedEntries.count == 1, "Offscreen filename filter failed")
        browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        browser.table.copy(nil)
        let urls = (browser.transferPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL])?.map { $0 as URL }
        try require(urls == [fixture.appendingPathComponent("Résumé – नमस्ते – 日本語.txt")], "Offscreen native private clipboard references failed")
        browser.filterField.stringValue = ""
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filterField))
        try await settled(browser)
        checks.append("Shallow Unicode/package/link listing, filename filtering and private file-reference clipboard")
        browser.settings.showsHiddenFiles = true
        try await Task.sleep(for: .milliseconds(80))
        try await settled(browser)
        try require(browser.rawEntries.count == plainCount + 9, "Offscreen hidden preference failed")
        browser.settings.showsHiddenFiles = false
        try await Task.sleep(for: .milliseconds(80))
        try await settled(browser)
        let firstTab = browser.activeID
        browser.newTab(nil)
        browser.navigate(to: .directory(fixture.appendingPathComponent("Empty Folder", isDirectory: true)))
        try await settled(browser)
        try require(browser.rawEntries.isEmpty && browser.loadError == nil, "Offscreen empty folder failed")
        let secondTab = browser.activeID
        browser.selectTab(firstTab)
        try await settled(browser)
        try require(browser.location == .directory(fixture), "Offscreen tabs shared their locations")
        browser.closeTab(id: secondTab)
        browser.navigate(to: .directory(fixture.appendingPathComponent("missing-fixture-folder", isDirectory: true)))
        try await settled(browser)
        try require(browser.loadError != nil && !browser.overlayActions.isHidden && browser.accessDiagnostic?.kind == .missing,
                    "Missing folder did not expose truthful recovery actions")
        browser.navigate(to: .directory(fixture))
        browser.navigate(to: .directory(fixture.appendingPathComponent("Folder A/Child", isDirectory: true)))
        try await settled(browser)
        try await Task.sleep(for: .milliseconds(120))
        try require(browser.displayedEntries.map(\.name) == ["Grandchild"], "Older listing repainted newer offscreen location")
        checks.append("Hidden preference, independent tabs, empty/missing recovery and stale navigation rejection")

        try await verifyProperties(browser, fixture: fixture, output: output)
        try requireControlledWindowsHidden("verifyProperties")
        checks.append("Bounded shallow Properties, unavailable coverage, links, cancellation, stale results, Light/Dark and injected Copy Path")
        checks += try await verifyPreferences(browser, fixture: fixture, output: output, interactive: false)
        try requireControlledWindowsHidden("verifyPreferences")
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {
            throw Failure(message: "Offscreen capability root was not configured")
        }
        let testRoot = URL(fileURLWithPath: declared, isDirectory: true)
        checks += try await AccessVerification.run(in: testRoot)
        browser.permitsBackgroundVerification = true
        defer { browser.permitsBackgroundVerification = false }
        checks += try await verifyOperations(browser, in: testRoot, output: output)
        try requireControlledWindowsHidden("verifyOperations")
        checks += try await verifyFinderWorkflows(browser, fixture: fixture, output: output, interactive: false)
        try requireControlledWindowsHidden("verifyFinderWorkflows")
        checks += try await verifyRecoveryWorkflows(browser, in: testRoot, output: output, interactive: false)
        try requireControlledWindowsHidden("verifyRecoveryWorkflows")
        checks += try await CopyPreviewActivationVerification.run(in: testRoot, output: output)
        try requireControlledWindowsHidden("verifyCopyPreviewActivation")
        checks += try await verifyOperationMaturity(browser, in: testRoot, output: output, interactive: false)
        try requireControlledWindowsHidden("verifyOperationMaturity")
        checks += try await verifyOperationResults(browser, fixture: fixture, output: output)
        try requireControlledWindowsHidden("verifyOperationResults")
        checks += try await verifyOpenAndShareWorkflows(browser, fixture: fixture, output: output)
        try requireControlledWindowsHidden("verifyOpenAndShareWorkflows")
        checks += try await verifyTransferContinuation(browser, in: testRoot, output: output, interactive: false)
        try requireControlledWindowsHidden("verifyTransferContinuation")
        checks += try await verifyDragDropWorkflows(browser, fixture: fixture, output: output)
        try requireControlledWindowsHidden("verifyDragDropWorkflows")
        checks += try await verifyDestinationDropWorkflows(browser, fixture: fixture, output: output)
        try requireControlledWindowsHidden("verifyDestinationDropWorkflows")
        checks += try await verifyTabManagement(browser, fixture: fixture, output: output)
        try requireControlledWindowsHidden("verifyTabManagement")
        checks += try await verifyTabStripInteractions(browser, fixture: fixture, output: output)
        try requireControlledWindowsHidden("verifyTabStripInteractions")
        checks += try await verifyContentPresentationRouting(browser, fixture: fixture, output: output)
        try requireControlledWindowsHidden("verifyContentPresentationRouting")
        checks += try await verifyIconsInteractions(browser, fixture: fixture, output: output)
        try requireControlledWindowsHidden("verifyIconsInteractions")
        checks += try await verifyIconsCommands(browser, fixture: fixture, output: output)
        try requireControlledWindowsHidden("verifyIconsCommands")
        try await verifyPresentation(browser, fixture: fixture, output: output)
        try requireControlledWindowsHidden("verifyPresentation")
        checks.append("Numeric size, proportional breadcrumb, Copy Path selection, view icons and header-column choices")
        let after = try await Task.detached { try fixtureSnapshot(fixture) }.value
        try require(before == after, "Offscreen browsing modified the original listing fixture")
        checks.append("Original listing fixture structure, modes, sizes and modification times unchanged")
        let qualification = (try? Data(contentsOf: output.appendingPathComponent("interactive-qualification.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let actualTrash = (qualification?["trash"] as? [String: Any])?["status"] as? String == "trash-and-no-replace-restore-qualified"
        if actualTrash { checks.append("Explicit owned-fixture API integration: real Trash, no-replace restore and original payload verified; foreground confirmation not exercised") }
        let priorFixtureRecovered = (qualification?["trash"] as? [String: Any])?["status"] as? String == "prior-owned-trash-fixture-restored-no-replace"
        if priorFixtureRecovered { checks.append("Exact prior owned Trash fixture recovered through no-replace move with payload verified; historical receipt unchanged") }
        var notExercised = ["Foreground activation and native mouse/menu/keyboard dispatch", "VoiceOver", "Inter-application clipboard",
                            "Real folder chooser/bookmarks and protected-folder privacy consent across rebuilds", "Real cross-volume operations",
                            "Disconnected mounts", "Minimum macOS runtime", "Cloud placeholders", "Release signing/notarization",
                            "System Reduce Transparency/Increase Contrast changes and compositor glass"]
        notExercised.append(actualTrash ? "Human confirmation of actual Trash" : "Actual system Trash")
        notExercised += ["Physical native drag and actual Finder interoperation", "Actual external application handoff", "Native sharing picker and recipient delivery", "Native Open With/Share focus-return regression"]
        var report: [String: Any] = [
            "passed": true, "mode": "offscreen-controlled", "checks": checks, "measurements": measurements,
            "captureMethod": "Native app view cacheDisplay only; no desktop, other apps or WindowServer glass",
            "clipboard": "Private native pasteboard only; system clipboard untouched",
            "preferences": "In memory; controlled bookmark persistence only in new owned fixtures",
            "focusBoundary": "Debug-only foreground command gate bypass for owned-fixture operations; real mouse/menu/focus qualification not claimed",
            "notExercised": notExercised,
        ]
        if let qualification { report["fixtureQualification"] = qualification }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("ui-verification.json"), options: .atomic)
        print("Offscreen controlled native verification passed: \(checks.count) groups; \(plainCount) generated plain files. Foreground input remains unexercised.")
    }
}
#endif
