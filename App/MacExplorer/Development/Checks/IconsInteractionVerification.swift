import AppKit
import ExplorerCore
import FileOperations

#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
@MainActor
private final class IconFixtureDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingSequenceNumber: Int
    let draggingSourceOperationMask: NSDragOperation
    var draggingLocation = NSPoint.zero
    var draggingDestinationWindow: NSWindow?
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, source: Any?, sequence: Int, allowed: NSDragOperation = [.copy, .move]) {
        draggingPasteboard = board; draggingSource = source; draggingSequenceNumber = sequence
        draggingSourceOperationMask = allowed
        super.init()
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
extension UIVerification {
    static func verifyIconsInteractions(_ browser: BrowserViewController, fixture: URL,
                                        output: URL) async throws -> [String] {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let build = project.appendingPathComponent(".build", isDirectory: true).path + "/"
        try require(output.path.hasPrefix(build) && output.resolvingSymlinksInPath() == output,
                    "Icons output is not an owned repository build root")
        let root = output.appendingPathComponent("icons-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false,
                                         attributes: [.posixPermissions: 0o700])
        try Data("MacExplorer generated Icons fixture v1\n".utf8)
            .write(to: root.appendingPathComponent(".owned-fixture"), options: .withoutOverwriting)
        let longName = "Résumé – नमस्ते – 日本語 – a deliberately long filename that needs two lines.txt"
        let longURL = root.appendingPathComponent(longName)
        let other = root.appendingPathComponent("Second file.txt")
        let folder = root.appendingPathComponent("Folder.with.period", isDirectory: true)
        let preview = FileIconBrowserView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 440),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = preview
        // Positive native input/accessibility requires an interactive window;
        // retain offscreen placement for this generated component regression.
        window.setFrameOrigin(.init(x:-12000,y:-12000));window.orderFront(nil)
        defer { window.orderOut(nil) }
        let samples = [FileEntry(url: longURL, name: longName, kind: .file),
                       FileEntry(url: other, name: "Second file.txt", kind: .file),
                       FileEntry(url: folder, name: "Folder.with.period", kind: .directory),
                       FileEntry(url: root.appendingPathComponent("Example.app"), name: "Example.app", kind: .package),
                       FileEntry(url: root.appendingPathComponent("Opaque Link"), name: "Opaque Link", kind: .symbolicLink)]
        func rows(_ entries: [FileEntry]) -> OrderedRows {
            OrderedRows(entries: entries, rowsByURL: Dictionary(uniqueKeysWithValues:
                entries.enumerated().map { ($0.element.url, $0.offset) }))
        }
        preview.update(rows(samples), selected: [longURL, other], cut: [longURL], showsExtensions: false)
        preview.layoutSubtreeIfNeeded(); preview.collectionView.layoutSubtreeIfNeeded()
        try await waitUntil("Recycled symbolic Icons items") { preview.visibleItems.count == samples.count }
        guard var longItem = preview.visibleItems.first(where: { $0.entry?.url == longURL }),
              let folderItem = preview.visibleItems.first(where: { $0.entry?.url == folder }) else {
            throw Failure(message: "Unicode or folder Icons item missing")
        }
        let originalTileFrame = longItem.view.frame
        var tinyTileRows: [[String: Any]] = []
        var tinyTilePassed = true
        func tileNumbers(_ rect: NSRect) -> [Double] {
            [Double(rect.origin.x), Double(rect.origin.y), Double(rect.size.width), Double(rect.size.height)]
        }
        for width: CGFloat in [0, 1, 2, 16, 136] {
            longItem.view.setFrameSize(NSSize(width: width, height: 120))
            let before = longItem.view.bounds
            longItem.view.layoutSubtreeIfNeeded()
            let after = longItem.view.bounds
            let label = longItem.view.convert(longItem.filenameLabel.bounds, from: longItem.filenameLabel)
            let exercised = before.size == NSSize(width: width, height: 120) && after.size == before.size
            let passed = exercised && tileNumbers(longItem.filenameLabel.frame).allSatisfy(\.isFinite)
                && longItem.filenameLabel.frame.size.width >= 0 && longItem.filenameLabel.frame.size.height >= 0
            let contained = label.minX >= after.minX - 0.001 && label.maxX <= after.maxX + 0.001
                && label.minY >= after.minY - 0.001 && label.maxY <= after.maxY + 0.001
            tinyTilePassed = tinyTilePassed && passed
            tinyTileRows.append(["requestedWidth": Double(width), "boundsBefore": tileNumbers(before),
                "boundsAfter": tileNumbers(after), "allocationExercised": exercised,
                "labelFrame": tileNumbers(longItem.filenameLabel.frame), "labelInTile": tileNumbers(label),
                "contained": contained, "passed": passed])
        }
        longItem.view.frame = originalTileFrame
        longItem.view.layoutSubtreeIfNeeded()
        let restoredLabel = longItem.view.convert(longItem.filenameLabel.bounds, from: longItem.filenameLabel)
        let positiveRestored = longItem.view.frame == originalTileFrame && longItem.view.bounds.contains(restoredLabel)
        try JSONSerialization.data(withJSONObject: ["cases": tinyTileRows, "passed": tinyTilePassed && positiveRestored,
            "positiveAllocationRestored": positiveRestored,
            "scope": "Direct-item stress: finite nonnegative native geometry and positive restoration; containment at unsupported tiny item widths is diagnostic only; live Xcode warning cause unqualified"],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("icons-tiny-geometry.json"), options: .withoutOverwriting)
        try require(tinyTilePassed && positiveRestored,
                    "Recycled Icons stress has invalid native geometry or loses its positive layout; numeric observations were preserved")
        try require(longItem.view.gestureRecognizers.contains { gesture in
            guard let click = gesture as? NSClickGestureRecognizer else { return false }
            return click.numberOfClicksRequired == 2 && click.buttonMask == 1
                && !click.delaysPrimaryMouseButtonEvents && click.delegate === longItem
        }, "Icons item double-click recognizer delays native selection/drag or is missing")
        try require(longItem.filenameLabel.stringValue == (longName as NSString).deletingPathExtension
                    && folderItem.filenameLabel.stringValue == "Folder.with.period"
                    && longItem.view.accessibilityLabel()?.contains(longName) == true
                    && longItem.view.toolTip?.contains(longName) == true && !longItem.cutBadge.isHidden,
                    "Icons lost full Unicode name, directory suffix semantics, or cut feedback")
        let labelFrame = longItem.view.convert(longItem.filenameLabel.bounds, from: longItem.filenameLabel)
        try require(longItem.view.bounds.contains(labelFrame) && longItem.filenameLabel.maximumNumberOfLines == 2,
                    "Icons filename label escapes its recycled tile")
        guard let anchor = preview.selectionAnchor(for: [longURL]) else { throw Failure(message: "Icons filename anchor unavailable") }
        try require(anchor.intersects(preview.collectionView.visibleRect)
                    && anchor == preview.collectionView.convert(longItem.filenameLabel.bounds, from: longItem.filenameLabel)
                        .intersection(preview.collectionView.visibleRect),
                    "Icons sharing anchor is not the actual visible filename")

        guard let flow = preview.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else {
            throw Failure(message: "Icons native flow layout is unavailable")
        }
        let originalPreviewSize = preview.frame.size
        var parentRows: [[String: Any]] = []
        var parentPassed = true, tinyParentsDeferred = true, tinyParentExercised = false, onePointMaterialized = false
        var minimumTileMaterialized = false
        for width: CGFloat in [0, 1, 2, 16, 21, 22, 24, 36, 56, 53, 156, 700] {
            preview.setFrameSize(NSSize(width: width, height: originalPreviewSize.height))
            preview.layoutSubtreeIfNeeded()
            preview.collectionView.layoutSubtreeIfNeeded()
            let exercised = preview.bounds.width == width
            let items = preview.visibleItems
            let firstFrame = flow.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
            let deferred = firstFrame == nil && flow.layoutAttributesForElements(in: preview.collectionView.bounds).isEmpty
            if exercised && width <= 36 {
                tinyParentExercised = true
                tinyParentsDeferred = tinyParentsDeferred && deferred && items.isEmpty
            }
            var itemRows: [[String: Any]] = []
            for item in items {
                item.view.layoutSubtreeIfNeeded()
                let bounds = item.view.bounds
                let label = item.view.convert(item.filenameLabel.bounds, from: item.filenameLabel)
                if exercised && bounds.width == 1 { onePointMaterialized = true }
                if exercised && bounds.width == 16 { minimumTileMaterialized = true }
                let passed = tileNumbers(bounds).allSatisfy(\.isFinite)
                    && tileNumbers(item.filenameLabel.frame).allSatisfy(\.isFinite)
                    && item.filenameLabel.frame.size.width >= 0 && item.filenameLabel.frame.size.height >= 0
                    && label.minX >= bounds.minX - 0.001 && label.maxX <= bounds.maxX + 0.001
                    && label.minY >= bounds.minY - 0.001 && label.maxY <= bounds.maxY + 0.001
                parentPassed = parentPassed && passed
                itemRows.append(["tileBounds": tileNumbers(bounds), "labelFrame": tileNumbers(item.filenameLabel.frame),
                                 "labelInTile": tileNumbers(label), "passed": passed])
            }
            parentRows.append(["requestedParentWidth": Double(width), "parentBounds": tileNumbers(preview.bounds),
                "clipBounds": tileNumbers(preview.scrollView.contentView.bounds),
                "flowItemWidth": Double(flow.itemSize.width), "allocationExercised": exercised,
                "firstLayoutItemFrame": firstFrame.map(tileNumbers) ?? [], "deferredUntilAllocated": deferred,
                "materializedVisibleCount": items.count, "items": itemRows])
        }
        preview.setFrameSize(originalPreviewSize)
        preview.layoutSubtreeIfNeeded(); preview.collectionView.layoutSubtreeIfNeeded()
        try await waitUntil("Restore Icons collection after tiny-parent layout") { preview.visibleItems.count == samples.count }
        // Native resizing may recycle the original item for another entry.
        // Following pointer/accessibility checks must use the current long file.
        guard let restoredItem = preview.visibleItems.first(where: { $0.entry?.url == longURL }) else {
            throw Failure(message: "Restored Icons collection lost the exact long-name item")
        }
        longItem = restoredItem
        let parentPositiveRestored = flow.itemSize == NSSize(width: 136, height: 120)
            && preview.visibleItems.allSatisfy { item in
                item.view.bounds.contains(item.view.convert(item.filenameLabel.bounds, from: item.filenameLabel))
            }
        try JSONSerialization.data(withJSONObject: ["cases": parentRows,
            "passed": parentPassed && parentPositiveRestored && tinyParentExercised && tinyParentsDeferred && minimumTileMaterialized,
            "tinyParentExercised": tinyParentExercised, "tinyParentsDeferred": tinyParentsDeferred, "onePointMaterialized": onePointMaterialized,
            "minimumTileMaterialized": minimumTileMaterialized,
            "positiveAllocationRestored": parentPositiveRestored,
            "scope": "Actual collection parent resize: unsupported tiny allocations must explicitly defer attributes/items; materialized16-point and restored136-point items must retain finite contained labels"],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("icons-tiny-parent-geometry.json"), options: .withoutOverwriting)
        try require(tinyParentExercised && tinyParentsDeferred,
                    "Unsupported tiny parent did not explicitly defer native Icons attributes/items; numeric observations were preserved")
        try require(minimumTileMaterialized, "Native Icons flow did not materialize its 16-point boundary; numeric observations were preserved")
        try require(parentPassed && parentPositiveRestored,
                    "Actual tiny-parent Icons flow escapes its labels or loses ordinary 136-point tiles; numeric observations were preserved")

        var open = 0, rename = 0, copy = 0, cut = 0, paste = 0, undo = 0, back = 0, trash = 0, quick = 0
        let collection = preview.collectionView
        collection.onOpen = { open += 1 }; collection.onRename = { rename += 1 }
        collection.onCopy = { copy += 1 }; collection.onCut = { cut += 1 }; collection.onPaste = { paste += 1 }
        collection.onUndo = { undo += 1 }; collection.onBack = { back += 1 }
        collection.onTrash = { trash += 1 }; collection.onQuickLook = { quick += 1 }
        collection.commandValidation = { _ in false }
        collection.copy(nil); collection.cut(nil); collection.paste(nil); collection.undo(nil)
        try require(copy + cut + paste + undo == 0, "Icons responder ignored semantic command validation")
        collection.commandValidation = { _ in true }
        collection.copy(nil); collection.cut(nil); collection.paste(nil); collection.undo(nil)
        collection.keyDown(with: key("\r", code: 36, flags: [], window: window))
        collection.keyDown(with: key(" ", code: 49, flags: [], window: window))
        collection.keyDown(with: key("\u{7f}", code: 51, flags: [], window: window))
        collection.keyDown(with: key("\u{7f}", code: 51, flags: .command, window: window))
        collection.explorerKeysEnabled = false
        collection.keyDown(with: key("\r", code: 36, flags: [], window: window))
        try require(copy == 1 && cut == 1 && paste == 1 && undo == 1 && open == 1 && quick == 1
                    && back == 1 && trash == 1 && rename == 1, "Icons keyboard/responder commands did not route semantic callbacks")
        preview.setSelection([longURL]); preview.focus()
        collection.keyDown(with: key(String(UnicodeScalar(0xF703)!), code: 124, flags: [], window: window))
        try require(preview.orderedSelectedURLs == [other], "Native Icons Right arrow did not advance selection")
        collection.keyDown(with: key(String(UnicodeScalar(0xF703)!), code: 124, flags: .shift, window: window))
        try require(Set(preview.orderedSelectedURLs) == [other, folder], "Native Icons Shift-Right did not extend a range")
        preview.setSelection([other])
        collection.keyDown(with: key(String(UnicodeScalar(0xF702)!), code: 123, flags: [], window: window))
        try require(preview.orderedSelectedURLs == [longURL], "Native Icons Left arrow did not return selection")
        collection.keyDown(with: key(String(UnicodeScalar(0xF701)!), code: 125, flags: [], window: window))
        try require(preview.orderedSelectedURLs == [samples[4].url], "Native Icons Down arrow did not reach its next visual row")
        collection.keyDown(with: key(String(UnicodeScalar(0xF700)!), code: 126, flags: [], window: window))
        try require(preview.orderedSelectedURLs == [longURL], "Native Icons Up arrow did not return to its visual row")
        collection.selectAll(nil)
        try require(preview.selectedCount == samples.count, "Native Icons Select All omitted displayed items")
        preview.setSelection([longURL, other])
        collection.onContextMenu = { _ in NSMenu() }
        let point = longItem.view.convert(NSPoint(x: longItem.view.bounds.midX, y: longItem.view.bounds.midY), to: nil)
        guard let contextEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1) else { throw Failure(message: "Icons context event unavailable") }
        _ = collection.menu(for: contextEvent)
        try require(Set(preview.orderedSelectedURLs) == [longURL, other], "Icons context click collapsed a selected multiselection")
        guard let accessible = longItem.view.accessibilityCustomActions()?.first,
              accessible.target as? FileIconItem === longItem,
              accessible.selector == #selector(FileIconItem.accessibleOpen(_:)) else { throw Failure(message: "Icons accessible Open action missing") }
        try require(longItem.accessibleOpen(accessible) && open == 2 && preview.orderedSelectedURLs == [longURL],
                    "Icons accessible Open did not select its current observed item and route the shared command")
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for transparent in [false, true] {
                preview.contentBackgroundIsTransparent = transparent
                try await snapshot(window, to: output.appendingPathComponent("icons-\(dark ? "dark" : "light")-\(transparent ? "transparent" : "solid").png"))
            }
        }
        let many = (0..<100_000).map { index in
            FileEntry(url: root.appendingPathComponent(String(format: "virtual-%05d.txt", index)),
                      name: String(format: "virtual-%05d.txt", index), kind: .file)
        }
        preview.update(rows(many), selected: [], cut: [], showsExtensions: true)
        preview.layoutSubtreeIfNeeded(); collection.layoutSubtreeIfNeeded()
        try await waitUntil("Virtualized Icons viewport") { !preview.visibleItems.isEmpty }
        try require(preview.itemCount == 100_000 && preview.visibleItems.count < 100,
                    "Icons created an item view for every listing entry")
        collection.selectAll(nil)
        let fullOrders = preview.fullSelectionOrderCount
        try require(preview.selectedCount == many.count
                    && preview.orderedSelectedURLs(upTo: 256) == many.prefix(256).map(\.url)
                    && preview.fullSelectionOrderCount == fullOrders,
                    "A bounded preview sorted or materialized an entire 100,000-item native selection")
        let tail = Array(many.suffix(512))
        preview.setSelection(Set(tail.map(\.url)))
        for limit in [0, 1, 7, 64, 128, 256] {
            try require(preview.orderedSelectedURLs(upTo: limit) == tail.prefix(limit).map(\.url),
                        "Bounded Icons selection differs from full display order for a sparse tail")
        }
        let last = many.last!.url
        let replacements = preview.snapshotReplacementCount
        guard let retainedTile = preview.visibleItems.first else { throw Failure(message: "No visible Icons tile to inspect") }
        preview.updateAppearance(selected: [last], cut: [last], showsExtensions: false)
        try require(preview.snapshotReplacementCount == replacements && preview.visibleItems.contains { $0 === retainedTile },
                    "Appearance-only Icons refresh replaced the ordered snapshot or recycled all visible tiles")
        preview.reveal(last)
        try await waitUntil("Last virtualized Icons item") { preview.visibleEntries.contains { $0.url == last } }
        try require(preview.selectionAnchor(for: [last]) != nil && preview.visibleItems.count < 100,
                    "Icons reveal/anchor lost virtualization")
        guard let lastTile = preview.visibleItems.first(where: { $0.entry?.url == last }) else {
            throw Failure(message: "Last Icons item did not materialize")
        }
        try require(!lastTile.cutBadge.isHidden && lastTile.filenameLabel.stringValue == "virtual-99999",
                    "A newly visible recycled Icons tile retained old Cut or extension appearance")
        preview.update(rows([]), selected: [last], cut: [], showsExtensions: true)
        collection.layoutSubtreeIfNeeded()
        try require(preview.itemCount == 0 && preview.orderedSelectedURLs.isEmpty
                    && preview.selectionAnchor(for: [last]) == nil, "Empty Icons retained stale selection/geometry")

        let sourceFolder = root.appendingPathComponent("Source", isDirectory: true)
        let target = sourceFolder.appendingPathComponent("Target", isDirectory: true)
        try FileManager().createDirectory(at: target, withIntermediateDirectories: true)
        let source = sourceFolder.appendingPathComponent("Generated source.txt")
        let payload = Data("generated Icons drag source".utf8)
        try payload.write(to: source, options: .withoutOverwriting)
        let oldMode = browser.settings.viewMode, oldBackground = browser.permitsBackgroundVerification
        let coordinator = browser.dragDrop
        let oldHooks = coordinator.hooks, oldVerification = coordinator.permitsVerification
        browser.permitsBackgroundVerification = true; coordinator.permitsVerification = true
        var admissions: [BrowserDropRequest] = []
        coordinator.hooks.admit = { admissions.append($0); return true }
        defer {
            coordinator.windowWillClose(); coordinator.hooks = oldHooks; coordinator.permitsVerification = oldVerification
            browser.permitsBackgroundVerification = oldBackground; browser.settings.viewMode = oldMode
            coordinator.configureDestinationViews()
        }
        browser.settings.viewMode = .icons
        browser.navigate(to: .directory(sourceFolder)); try await settled(browser)
        try await waitUntil("Actual Icons presentation") { browser.usesFileIcons && browser.iconBrowser.itemCount == 2 }
        browser.iconBrowser.layoutSubtreeIfNeeded(); browser.iconBrowser.collectionView.layoutSubtreeIfNeeded()
        browser.iconBrowser.setSelection([source]); browser.fileSelectionDidChange(); coordinator.selectionDidChange()
        try await waitUntil("Icons source and target drag cache") {
            coordinator.verificationState.readySource && coordinator.hasPreparedDestinationForVerification(target)
                && !coordinator.verificationState.preparing
        }
        try require(coordinator.pasteboardWriter(for: source) != nil && coordinator.pasteboardWriter(for: target) == nil,
                    "Icons immediate URL writer lost selected-item bounds")
        if let row = browser.rowsByURL[source] {
            try require(coordinator.pasteboardWriter(for: row) == nil, "Hidden table acquired Icons source authority")
        }
        try require(coordinator.registerSourceForVerification(sequence: 6101), "Actual Icons source was not registered")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([source as NSURL])
        let drag = IconFixtureDrag(board: board, source: browser.iconBrowser.collectionView, sequence: 6101)
        let hiddenSource = IconFixtureDrag(board: board, source: browser.table, sequence: 6101)
        let wrongSequence = IconFixtureDrag(board: board, source: browser.iconBrowser.collectionView, sequence: 6199)
        try require(coordinator.validateFileDrop(hiddenSource, destination: target).isEmpty
                    && coordinator.validateFileDrop(wrongSequence, destination: target).isEmpty,
                    "Icons trusted a hidden table or mismatched native source sequence")
        if NSEvent.modifierFlags.intersection([.option, .command, .control]).isEmpty {
            try require(coordinator.validateFileDrop(drag, destination: target) == .move,
                        "Authenticated Icons source did not negotiate an internal Move")
        }
        try require(await coordinator.dropForVerification(from: coordinator, urls: [source], destination: target,
                                                          moveModifier: .option), "Icons Option Copy was refused")
        try require(admissions.last?.move == false && admissions.last?.destination == target,
                    "Icons routed the wrong destination or modifier policy")
        guard let targetItem = browser.iconBrowser.visibleItems.first(where: { $0.entry?.url == target }) else {
            throw Failure(message: "Native Icons folder target is not visible")
        }
        let nativeCollection = browser.iconBrowser.collectionView
        drag.draggingDestinationWindow = browser.view.window
        drag.draggingLocation = targetItem.filenameLabel.convert(
            NSPoint(x: targetItem.filenameLabel.bounds.midX, y: targetItem.filenameLabel.bounds.midY), to: nil)
        if NSEvent.modifierFlags.intersection([.option, .command, .control]).isEmpty {
            try require(nativeCollection.draggingUpdated(drag) == .move && nativeCollection.performDragOperation(drag),
                        "Native Icons folder hit-testing/callback route did not admit authenticated Move")
            let acceptedCount = admissions.count
            try require(!nativeCollection.performDragOperation(drag) && admissions.count == acceptedCount,
                        "Repeated Icons native callback admitted the same drag twice")
        }
        let external = IconFixtureDrag(board: board, source: nil, sequence: 6102, allowed: .copy)
        external.draggingDestinationWindow = browser.view.window; external.draggingLocation = drag.draggingLocation
        _ = nativeCollection.draggingEntered(external)
        try await waitUntil("Icons external Copy source observation") { coordinator.verificationState.external }
        if NSEvent.modifierFlags.intersection([.option, .command, .control]).isEmpty {
            try require(nativeCollection.draggingUpdated(external) == .copy
                        && nativeCollection.performDragOperation(external)
                        && admissions.last?.move == false,
                        "Native Icons callback requested external source retirement or lost folder destination")
        }

        browser.settings.viewMode = .details
        try await waitUntil("Switch away from Icons invalidates native source") { !browser.usesFileIcons }
        guard let targetRow = browser.rowsByURL[target] else { throw Failure(message: "Generated target row missing") }
        try require(coordinator.validateDrop(drag, row: targetRow, operation: .on).isEmpty,
                    "Old Icons view retained internal authority after a presentation switch")
        try require(try Data(contentsOf: source) == payload
                    && !FileManager().fileExists(atPath: target.appendingPathComponent(source.lastPathComponent).path),
                    "Injected Icons admission mutated its generated fixture")
        browser.settings.viewMode = oldMode
        try await waitUntil("Restore original file presentation") { browser.presentedFileViewMode == oldMode }
        browser.navigate(to: .directory(fixture)); try await settled(browser)
        let checks = [
            "Actual tiny-parent native Icons flow preserves filename containment and returns ordinary 136-point tiles; direct-item stress retains finite nonnegative geometry and restores positive allocation",
            "Recycled symbolic Icons render long Unicode names, full-name accessibility/tooltips, cut badges and actual visible filename anchors in Light/Dark/Solid/transparent view renders",
            "100,000 supplied observations retain fewer than 100 visible item views; native Select All and bounded preview order avoid whole-selection sorting; reveal/anchor and empty replacement reject stale geometry without filesystem reads",
            "Icons native responder validation, Explorer/Mac Return, context multiselection and accessible Open route semantic callbacks; no real handoff or VoiceOver claimed",
            "Generic drag registry authenticates actual active collection view and native sequence; hidden table and switched-away Icons source refuse; internal Move/Option Copy retain ordinary observed admission"
        ]
        try JSONSerialization.data(withJSONObject: ["checks": checks, "admittedRequests": admissions.count,
            "physicalDragExercised": false, "finderExercised": false, "voiceOverExercised": false,
            "windowServerGlassExercised": false, "fileMutationExercised": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("icons-interactions.json"), options: .withoutOverwriting)
        return checks
    }
}
#endif
