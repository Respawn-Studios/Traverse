import AppKit
import ExplorerCore
import FileOperations

#if DEBUG
@MainActor
extension UIVerification {
    /// Real recoverable commands against a new marked disposable root. The
    /// isolated controller owns its engine, journal, hooks and private pasteboard;
    /// no owner browser state, system clipboard or real Trash is used.
    static func verifyIconsCommands(_ parent: BrowserViewController, fixture: URL,
                                    output: URL) async throws -> [String] {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let build = project.appendingPathComponent(".build", isDirectory: true).path + "/"
        try require(output.path.hasPrefix(build) && output.resolvingSymlinksInPath() == output,
                    "Icons command output is not an owned repository build root")
        let owned = output.appendingPathComponent("icons-commands-" + UUID().uuidString, isDirectory: true)
        let source = owned.appendingPathComponent("Source", isDirectory: true)
        let destination = owned.appendingPathComponent("Destination", isDirectory: true)
        let bodies = ["Original.txt": "generated Icons rename", "Copy.txt": "generated Icons copy",
                      "Move.txt": "generated Icons move", "Keep.txt": "generated Icons keep",
                      "Guard.txt": "generated Icons guarded rename"]
        try await Task.detached {
            let fm = FileManager()
            try fm.createDirectory(at: owned, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("MacExplorer owned Icons command fixture v1\n".utf8)
                .write(to: owned.appendingPathComponent(".owned-fixture"), options: .withoutOverwriting)
            try fm.createDirectory(at: source, withIntermediateDirectories: false)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            for (name, body) in bodies {
                try Data(body.utf8).write(to: source.appendingPathComponent(name), options: .withoutOverwriting)
            }
        }.value
        let originalAppAppearance = NSApplication.shared.appearance
        let settings = BrowserSettings(persist: false)
        settings.defaultSearchScope = .filter // This packet measures the explicit Filter surface.
        settings.viewMode = .icons; settings.keyboardProfile = .explorer
        settings.autoRefreshFolders = false; settings.restoresSession = false
        settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        let controller = BrowserWindowController(settings: settings)
        let browser = controller.browser
        let engine = RecoverableFileOperations(journalDirectory: owned.appendingPathComponent("journal", isDirectory: true))
        let board = NSPasteboard.withUniqueName()
        browser.permitsBackgroundVerification = true
        browser.recoverableFileOperations = engine
        browser.transferPasteboard = board
        browser.clipboardWriter = { text, urls in BrowserClipboard.publish(text, urls: urls, to: board) }
        browser.operationResultPresenter = { _ in }
        var errors: [String] = []
        browser.operationErrorPresenter = { errors.append($0) }
        browser.operationNamePrompt = { title, _ in title == "New Folder" ? "Created Icons Folder" : "Renamed 日本語.txt" }
        browser.operationTrashPrompt = { _ in false }
        browser.transferConflictPrompt = { _ in nil }
        defer {
            browser.clearCutSelection()
            browser.suspendBrowser()
            browser.operationNamePrompt = nil; browser.operationTrashPrompt = nil
            browser.operationResultPresenter = nil; browser.operationErrorPresenter = nil
            browser.transferConflictPrompt = nil; browser.recoveryInspectionTask?.cancel()
            browser.recoverableFileOperations = nil
            controller.window?.orderOut(nil)
            NSApplication.shared.appearance = originalAppAppearance
            board.releaseGlobally()
        }
        browser.rebuildSidebar()
        browser.navigate(to: .directory(source)); try await settled(browser)
        try await waitUntil("Isolated Icons command surface") { browser.usesFileIcons && browser.iconBrowser.itemCount == bodies.count }
        browser.focusBrowserContent()
        let collection = browser.iconBrowser.collectionView
        func selectOwned(_ name: String) throws {
            let url = source.appendingPathComponent(name)
            try require(browser.rowsByURL[url] != nil, "Owned Icons command item is unavailable")
            browser.setFileSelection([url]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
            try require(browser.selectedURLs == [url] && browser.activeFileView === collection,
                        "Icons command selection did not belong to its active collection")
        }
        func waitCommand(_ description: String) async throws {
            try await waitUntil(description) { !browser.hasPendingFileOperation && browser.cutPreparationTask == nil }
            await browser.recoveryInspectionTask?.value
            try await settled(browser)
        }
        func undo(_ description: String) async throws {
            try await waitUntil(description + " capability") { browser.canUndoFileOperation }
            browser.focusBrowserContent(); collection.undo(nil)
            try await waitCommand(description)
        }
        func requireBody(_ url: URL, _ body: String, _ message: String) throws {
            try require(try Data(contentsOf: url) == Data(body.utf8), message)
        }

        browser.createFolder(BrowserMenus.newFolderItem(target: browser, named: true)); try await waitCommand("Icons New Folder")
        let created = source.appendingPathComponent("Created Icons Folder", isDirectory: true)
        try require(browser.lastOperationResult?.disposition == .succeeded && FileManager().fileExists(atPath: created.path),
                    "Icons New Folder did not commit through its recoverable engine")
        try await undo("Icons New Folder Undo")
        try require(!FileManager().fileExists(atPath: created.path), "Icons New Folder Undo left its published folder")

        try selectOwned("Original.txt")
        collection.keyDown(with: key(String(UnicodeScalar(0xF705)!), code: 120, flags: [], window: controller.window!))
        try await waitCommand("Icons F2 Rename")
        let original = source.appendingPathComponent("Original.txt")
        let renamed = source.appendingPathComponent("Renamed 日本語.txt")
        try require(browser.lastOperationResult?.disposition == .succeeded && !FileManager().fileExists(atPath: original.path),
                    "Icons F2 Rename failed or retained the old name")
        try requireBody(renamed, bodies["Original.txt"]!, "Icons Rename changed its generated file body")
        try await undo("Icons Rename Undo")
        try requireBody(original, bodies["Original.txt"]!, "Icons Rename Undo did not restore its original body")
        try require(!FileManager().fileExists(atPath: renamed.path), "Icons Rename Undo left the renamed occupant")

        try selectOwned("Copy.txt"); collection.copy(nil)
        let copiedSource = source.appendingPathComponent("Copy.txt")
        try require((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL])?
                        .map({ $0 as URL }) == [copiedSource], "Icons Copy did not write its explicit private file reference")
        browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
        collection.paste(nil); try await waitCommand("Icons recoverable Copy/Paste")
        let copied = destination.appendingPathComponent("Copy.txt")
        try requireBody(copiedSource, bodies["Copy.txt"]!, "Icons Copy lost or changed its source")
        try requireBody(copied, bodies["Copy.txt"]!, "Icons Paste did not publish the exact generated copy")
        try await undo("Icons Copy Undo")
        try require(!FileManager().fileExists(atPath: copied.path), "Icons Copy Undo left its destination")
        try requireBody(copiedSource, bodies["Copy.txt"]!, "Icons Copy Undo removed its source")

        browser.navigate(to: .directory(source)); try await settled(browser)
        try selectOwned("Move.txt"); collection.cut(nil)
        try await waitUntil("Icons Cut observation") { browser.cutPreparationTask == nil }
        let movedSource = source.appendingPathComponent("Move.txt")
        try require(browser.pendingCut?.urls == [movedSource] && browser.cutURLs == [movedSource],
                    "Icons Cut did not retain its observed source")
        try requireBody(movedSource, bodies["Move.txt"]!, "Icons Cut changed data before Paste")
        browser.iconBrowser.layoutSubtreeIfNeeded(); collection.layoutSubtreeIfNeeded()
        guard let cutItem = browser.iconBrowser.visibleItems.first(where: { $0.entry?.url == movedSource }) else {
            throw Failure(message: "Cut Icons item is not visible")
        }
        try require(!cutItem.cutBadge.isHidden && cutItem.view.accessibilityLabel()?.contains("ready to move") == true,
                    "Real Icons Cut did not update its visible accessible state")
        try selectOwned("Keep.txt")
        browser.navigate(to: .directory(destination)); try await settled(browser); browser.focusBrowserContent()
        collection.paste(nil); try await waitCommand("Icons observed Cut/Paste")
        let moved = destination.appendingPathComponent("Move.txt")
        try require(!FileManager().fileExists(atPath: movedSource.path) && browser.pendingCut == nil
                    && browser.cutURLs.isEmpty && board.types?.isEmpty != false,
                    "Icons Paste did not complete the observed Move or clear its exact unchanged private clipboard")
        try requireBody(moved, bodies["Move.txt"]!, "Icons Move destination body does not match its source")
        try await undo("Icons Move Undo")
        try requireBody(movedSource, bodies["Move.txt"]!, "Icons Move Undo did not restore its source body")
        try require(!FileManager().fileExists(atPath: moved.path), "Icons Move Undo retained its destination")

        browser.navigate(to: .directory(source)); try await settled(browser)
        try selectOwned("Keep.txt")
        let beforeTrash = try await engine.recoveryRecords().records.map(\.id)
        var trashPrompts = 0
        browser.operationTrashPrompt = { count in trashPrompts += 1; return false }
        collection.keyDown(with: key("\u{7f}", code: 51, flags: .command, window: controller.window!))
        try await waitCommand("Icons cancelled Trash preparation")
        try require(trashPrompts == 1, "Icons Trash did not reach its explicit confirmation boundary")
        try requireBody(source.appendingPathComponent("Keep.txt"), bodies["Keep.txt"]!, "Cancelled Icons Trash changed its source")
        let afterTrash = try await engine.recoveryRecords().records.map(\.id)
        try require(beforeTrash == afterTrash, "Cancelled Icons Trash created a mutation journal record")

        let guardURL = source.appendingPathComponent("Guard.txt")
        let heldOriginal = source.appendingPathComponent("Guard original retained.txt")
        var replacementError: Error?
        browser.operationNamePrompt = { _, _ in
            do {
                try await Task.detached {
                    try FileManager().moveItem(at: guardURL, to: heldOriginal)
                    try Data(bodies["Guard.txt"]!.utf8).write(to: guardURL, options: .withoutOverwriting)
                }.value
            } catch { replacementError = error }
            return "Must not rename.txt"
        }
        let beforeGuardErrors = errors.count
        let beforeGuardRecords = try await engine.recoveryRecords().records.map(\.id)
        browser.lastOperationResult = nil
        try selectOwned("Guard.txt")
        collection.keyDown(with: key(String(UnicodeScalar(0xF705)!), code: 120, flags: [], window: controller.window!))
        try await waitCommand("Icons prompt-time replacement refusal")
        let afterGuardRecords = try await engine.recoveryRecords().records.map(\.id)
        try require(replacementError == nil && errors.count == beforeGuardErrors
                    && browser.lastOperationResult?.items.first?.status == .failed(.sourceChanged)
                    && beforeGuardRecords == afterGuardRecords
                    && !FileManager().fileExists(atPath: source.appendingPathComponent("Must not rename.txt").path),
                    "Icons Rename transferred prompt consent to an identical replacement occupant")
        try requireBody(guardURL, bodies["Guard.txt"]!, "Icons stale prompt damaged the replacement occupant")
        try requireBody(heldOriginal, bodies["Guard.txt"]!, "Icons stale prompt damaged its retained original")
        browser.refresh(nil); try await settled(browser)
        browser.setFileSelection([guardURL]); browser.fileSelectionDidChange()
        settings.viewMode = .details
        try await waitUntil("Isolated Details mode") { browser.presentedFileViewMode == .details }
        settings.viewMode = .icons
        try await waitUntil("Isolated Icons mode round-trip") { browser.presentedFileViewMode == .icons }
        try require(browser.selectedURLs == [guardURL], "Details/Icons round-trip lost actual selected item")
        let restored = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
        try require(restored.viewMode == .icons, "Versioned settings serialization did not round-trip Icons")
        var appearanceEvidence: [[String: Any]] = []
        controller.window?.appearance = nil
        settings.navigationStyle = .solid
        browser.updateMaterialSurfaces()
        for dark in [false, true] {
            // Exercise the actual product preference and its application-level
            // appearance propagation, rather than a mixed window-only override.
            settings.appearance = dark ? .dark : .light
            let expected: NSAppearance.Name = dark ? .darkAqua : .aqua
            try await waitUntil("Application appearance reaches the Icons filter") {
                NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected
                    && browser.filterField.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected
            }
            browser.filterField.needsDisplay = true
            let captureURL = output.appendingPathComponent("icons-app-commands-\(dark ? "dark" : "light").png")
            try await snapshot(controller.window!, to: captureURL)
            let measurement = try iconsFilterMeasurement(browser, window: controller.window!, png: captureURL)
            appearanceEvidence.append(["dark": dark, "measurement": measurement])
        }
        try JSONSerialization.data(withJSONObject: ["appearanceRoute": "BrowserSettings.appearance -> BrowserAppearanceController -> NSApplication",
            "navigationStyle": settings.navigationStyle.rawValue, "qualification": "Controlled Solid native glyph readability",
            "measurements": appearanceEvidence], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("icons-commands-appearance.json"), options: .withoutOverwriting)
        for evidence in appearanceEvidence {
            guard let measurement = evidence["measurement"] as? [String: Any],
                  let spread = measurement["textLuminanceSpread"] as? Double else {
                throw Failure(message: "Icons filter appearance evidence is incomplete")
            }
            try require(spread > 0.08, "Icons filter text rectangle rendered without measurable placeholder glyph contrast")
        }
        let appearanceRoutes = try await iconsIndependentAppearanceRoutes(fixture: source, output: output)
        try require(errors.isEmpty, "Unexpected error occurred during real Icons command qualification")
        let checks = [
            "Actual Icons responder and shared commands commit recoverable New Folder/Rename/Copy/Cut-Paste and Undo in an isolated marked generated fixture/journal",
            "Copy and Undo retain source bytes; Cut preserves source before Paste, targets its original observation despite selection changes, and Move Undo restores exact source bytes",
            "Cancelled Icons Trash preserves its source and creates no mutation record; system Trash was not invoked",
            "Prompt-time byte-identical replacement refuses Rename while preserving both occupants; Details/Icons selection and versioned settings serialization round-trip",
            "Full owned app-grid Solid native renders pass placeholder readability in Light/Dark; independent born-Dark Glass and Light-to-Dark Glass/Solid routes pass native-leaf appearance/geometry/readability",
            "Full-window Glass cacheDisplay bitmaps remain explicitly unqualified for compositor and appearance-transition readability, irrespective of pixel contrast; foreground input, WindowServer Glass, real Finder, handoff and VoiceOver remain unexercised"
        ]
        try JSONSerialization.data(withJSONObject: ["checks": checks, "recordCount": afterTrash.count,
            "unexpectedDialogErrors": errors.count, "replacementRefusal": "Explicit sourceChanged result; no mutation history",
            "actualSystemTrashExercised": false,
            "clipboard": "Private unique pasteboard", "captureMethod": "Owned native cacheDisplay only",
            "independentAppearanceRoutes": appearanceRoutes,
            "notExercised": ["Full-window Glass compositor and appearance-transition readability",
                "Foreground input", "WindowServer Glass", "Real Finder handoff", "VoiceOver"]],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("icons-commands.json"), options: .withoutOverwriting)
        return checks
    }

    /// Samples only the native search text rectangle from this exact owned app
    /// render. Rounded bezel edges and search/cancel symbols are excluded, so a
    /// blank uniform pill cannot pass by contributing border/icon contrast.
    private static func iconsFilterMeasurement(_ browser: BrowserViewController, window: NSWindow,
                                               png: URL) throws -> [String: Any] {
        let field = browser.filterField
        guard let cell = field.cell as? NSSearchFieldCell,
              let content = window.contentView, let capture = content.superview ?? window.contentView,
              let bitmap = NSBitmapImageRep(data: try Data(contentsOf: png)) else {
            throw Failure(message: "Owned Icons filter raster or native cell unavailable")
        }
        let text = cell.searchTextRect(forBounds: field.bounds)
        try require(field.bounds.insetBy(dx: -1, dy: -1).contains(text) && text.width > 40 && text.height > 8,
                    "Native Icons filter text rectangle is outside its control")
        try require(field.placeholderString == "Filter loaded filenames" && field.stringValue.isEmpty && field.isEnabled,
                    "Icons appearance probe does not contain the expected enabled placeholder")
        let sample = capture.convert(text.insetBy(dx: 2, dy: 1), from: field)
        var pixels = try iconsSearchTextPixels(bitmap, sample: sample, bounds: capture.bounds, flipped: capture.isFlipped)
        var resolvedText: [Double] = []
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let color = field.textColor?.usingColorSpace(.deviceRGB) {
                resolvedText = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
            }
        }
        pixels["fieldBounds"] = NSStringFromRect(field.bounds)
        pixels["nativeTextRect"] = NSStringFromRect(text)
        pixels["appAppearance"] = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown"
        pixels["fieldAppearance"] = field.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown"
        pixels["resolvedTextRGB"] = resolvedText
        pixels["resolvedBackgroundRGB"] = iconsResolvedRGB(field.backgroundColor, appearance: field.effectiveAppearance)
        pixels["drawsBackground"] = field.drawsBackground
        pixels["wantsLayer"] = field.wantsLayer
        return pixels
    }

    private static func iconsResolvedRGB(_ color: NSColor?, appearance: NSAppearance) -> [Double] {
        var rgb: [Double] = []
        appearance.performAsCurrentDrawingAppearance {
            if let value = color?.usingColorSpace(.deviceRGB) {
                rgb = [Double(value.redComponent), Double(value.greenComponent), Double(value.blueComponent)]
            }
        }
        return rgb
    }

    private static func iconsSearchTextPixels(_ bitmap: NSBitmapImageRep, sample: NSRect,
                                              bounds: NSRect, flipped: Bool) throws -> [String: Any] {
        let sx = CGFloat(bitmap.pixelsWide) / bounds.width
        let sy = CGFloat(bitmap.pixelsHigh) / bounds.height
        let x0 = max(0, Int((sample.minX - bounds.minX) * sx))
        let x1 = min(bitmap.pixelsWide, Int((sample.maxX - bounds.minX) * sx))
        let top = flipped ? sample.minY - bounds.minY : bounds.maxY - sample.maxY
        let y0 = max(0, Int(top * sy))
        let y1 = min(bitmap.pixelsHigh, Int((top + sample.height) * sy))
        try require(x0 < x1 && y0 < y1, "Icons filter sample is outside its owned render")
        var low = 1.0, high = 0.0, total = 0.0, alpha = 0.0, count = 0, white = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luminance = (Double(color.redComponent) + Double(color.greenComponent) + Double(color.blueComponent)) / 3
                low = min(low, luminance); high = max(high, luminance); total += luminance
                alpha += Double(color.alphaComponent); count += 1
                if luminance > 0.97 { white += 1 }
            }
        }
        try require(count > 0, "Icons filter had no measurable text pixels")
        return ["textLuminanceSpread": high - low, "meanTextRectangleLuminance": total / Double(count),
                "nearWhiteFraction": Double(white) / Double(count), "meanTextAlpha": alpha / Double(count)]
    }

    /// Each route owns a fresh controller. Capture the full window before the
    /// leaf: a leaf render must not seed the native cache used by the full render.
    /// Glass full-window results are evidence only, never compositor qualification.
    private static func iconsIndependentAppearanceRoutes(fixture: URL, output: URL) async throws -> [[String: Any]] {
        var routes: [[String: Any]] = []
        for (name, bornDark, solid) in [("born-dark-glass", true, false),
                                        ("light-to-dark-glass", false, false),
                                        ("light-to-dark-solid", false, true)] {
            let originalAppearance = NSApplication.shared.appearance
            let settings = BrowserSettings(persist: false)
            settings.defaultSearchScope = .filter // This raster packet targets Filter placeholder contrast.
            settings.viewMode = .icons
            settings.autoRefreshFolders = false; settings.restoresSession = false
            settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
            settings.navigationStyle = solid ? .solid : .glass
            settings.appearance = bornDark ? .dark : .light
            BrowserAppearanceController.apply(settings.appearance)
            var controller: BrowserWindowController!
            NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
                controller = BrowserWindowController(settings: settings)
            }
            let browser = controller.browser
            browser.permitsBackgroundVerification = true
            defer {
                browser.suspendBrowser()
                browser.recoveryInspectionTask?.cancel()
                controller.window?.orderOut(nil)
                NSApplication.shared.appearance = originalAppearance
            }
            guard let window = controller.window else { throw Failure(message: "Independent appearance window unavailable") }
            window.appearance = nil
            browser.rebuildSidebar()
            browser.navigate(to: .directory(fixture)); try await settled(browser)
            try await waitUntil("Independent Icons appearance surface") {
                browser.usesFileIcons && browser.iconBrowser.itemCount > 0
            }
            if !bornDark {
                try await waitUntil("Independent route initial Light appearance") {
                    browser.filterField.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
                }
                // A real initial full render defines a Light-to-Dark transition;
                // there are no control substitutions or material reparenting probes.
                try await snapshot(window, to: output.appendingPathComponent("icons-filter-" + name + "-initial-light.png"))
                settings.appearance = .dark
            }
            try await waitUntil("Independent route actual Dark appearance") {
                NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    && browser.filterField.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
            browser.filterField.needsDisplay = true
            let fullURL = output.appendingPathComponent("icons-filter-" + name + "-full.png")
            try await snapshot(window, to: fullURL)
            let full = try iconsFilterMeasurement(browser, window: window, png: fullURL)
            let leaf = try iconsFilterLeaf(browser.filterField,
                to: output.appendingPathComponent("icons-filter-" + name + "-leaf.png"))
            try require(!window.isVisible, "Independent appearance verification unexpectedly showed a window")
            routes.append(["route": name, "navigationStyle": settings.navigationStyle.rawValue,
                "navigationOpaqueFallback": browser.navigationSurface?.isUsingOpaqueSurface ?? true,
                "appAppearance": NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown",
                "fieldAppearance": browser.filterField.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown",
                "captureOrder": "Initial Light full if transitioning; Dark full before Dark native leaf",
                "full": full, "leaf": leaf,
                "fullQualification": solid ? "Required controlled Solid glyph readability" :
                    "UNQUALIFIED: native Glass cacheDisplay does not establish WindowServer compositor or transition readability",
                "fullHasMeasurableGlyphContrast": (full["textLuminanceSpread"] as? Double ?? 0) > 0.08,
                "windowVisible": window.isVisible])
        }
        // Persist all independent observations before asserting, retaining red
        // evidence when a supported native-leaf or Solid route regresses.
        try JSONSerialization.data(withJSONObject: ["routes": routes,
            "boundary": "Native leaf appearance, geometry and readability required for every fresh route; Solid full readability required; Glass full composite explicitly unqualified",
            "productionAppearanceChanges": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("icons-independent-appearance-routes.json"), options: .withoutOverwriting)
        for route in routes {
            guard let name = route["route"] as? String, let leaf = route["leaf"] as? [String: Any],
                  let full = route["full"] as? [String: Any] else {
                throw Failure(message: "Independent Icons appearance report is incomplete")
            }
            try require(route["appAppearance"] as? String == NSAppearance.Name.darkAqua.rawValue
                        && route["fieldAppearance"] as? String == NSAppearance.Name.darkAqua.rawValue,
                        "Independent Icons appearance route did not reach Dark")
            try require((leaf["textLuminanceSpread"] as? Double ?? 0) > 0.08,
                        "Independent Icons native filter leaf lost glyph readability: " + name)
            if name == "light-to-dark-solid" {
                try require((full["textLuminanceSpread"] as? Double ?? 0) > 0.08,
                            "Independent Icons Solid full render lost glyph readability")
            }
        }
        return routes
    }

    private static func iconsFilterLeaf(_ field: NSSearchField, to url: URL) throws -> [String: Any] {
        guard let cell = field.cell as? NSSearchFieldCell,
              let bitmap = field.bitmapImageRepForCachingDisplay(in: field.bounds) else {
            throw Failure(message: "Native filter-only bitmap or cell unavailable")
        }
        let text = cell.searchTextRect(forBounds: field.bounds)
        try require(field.bounds.insetBy(dx: -1, dy: -1).contains(text) && text.width > 40 && text.height > 8,
                    "Native filter-only text rectangle is outside its control")
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            field.cacheDisplay(in: field.bounds, to: bitmap)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(message: "Native filter-only PNG unavailable")
        }
        try data.write(to: url, options: .withoutOverwriting)
        var result = try iconsSearchTextPixels(bitmap, sample: text.insetBy(dx: 2, dy: 1),
                                              bounds: field.bounds, flipped: field.isFlipped)
        result["fieldBounds"] = NSStringFromRect(field.bounds)
        result["nativeTextRect"] = NSStringFromRect(text)
        return result
    }
}
#endif
