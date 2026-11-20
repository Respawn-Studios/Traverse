#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import FileOperations
import LocalStorage

@MainActor enum TARArchiveVerification {
    private enum Failure:Error{case scope,check(UInt)}
    private static func require(_ value:Bool,_ line:UInt = #line)throws{if !value{throw Failure.check(line)}}
    private static func wait(line: UInt = #line, _ value:()->Bool)async throws{
        let deadline=ProcessInfo.processInfo.systemUptime+20
        while !value(){try require(ProcessInfo.processInfo.systemUptime<deadline, line);try await Task.sleep(for:.milliseconds(10))}
    }
    private static func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    static func run()async {
        var root:URL?,owner:BrowserWindowController?,clips=[[String:Any]](),checks=[String]()
        do{
            guard let raw=ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"]else{throw Failure.check(#line)}
            let location=URL(fileURLWithPath:raw),repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker=try JSONSerialization.jsonObject(with:Data(contentsOf:location.appendingPathComponent("reservation.json")))as?[String:Any]
            try require(location.resolvingSymlinksInPath()==location && location.deletingLastPathComponent()==repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString:location.lastPathComponent)?.uuidString==location.lastPathComponent && marker?["action"]as?String=="plain-tar-native"
                && Bundle.main.bundleIdentifier=="local.macexplorer.development" && Bundle.main.bundleURL==repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app"))
            root=location
            let compressed = ProcessInfo.processInfo.arguments.contains("--compressed-tar")
            let inline = InlineArchiveFeature.available
            let offscreen = ProcessInfo.processInfo.arguments.contains("--offscreen")
            func show(_ window: NSWindow) {
                if offscreen { window.setFrameOrigin(.init(x: -12000, y: -12000)) }
                else { window.center(); NSApp.activate(ignoringOtherApps: true) }
                window.makeKeyAndOrderFront(nil)
            }
            func capture(_ window: NSWindow, _ name: String) async throws {
                if !offscreen { try await GlassVerification.captureOwnedWindow(window, to: location.appendingPathComponent("evidence/" + name + ".png")) }
            }
            func checkImage(_ preview: ArchiveTextPreviewOwner, valid: Bool, label: String, open: () throws -> Void) async throws {
                try require(!preview.retainsPresentation)
                try open()
                try await wait { !preview.isReading && preview.windowForVerification != nil }
                guard let panel = preview.windowForVerification else { throw Failure.check(#line) }
                try UIVerification.require(valid ? preview.imageSizeForVerification == NSSize(width: 420, height: 240)
                    : preview.statusForVerification?.contains("This image could not be read") == true,
                    "Generated image result: \(preview.statusForVerification ?? "missing")")
                try require(panel.title.hasSuffix(" — Image Preview") && preview.textForVerification?.isEmpty == true)
                if valid {
                    preview.layoutForVerification()
                    guard let canvas = preview.imageCanvasForVerification,
                          let zoom = descendants(canvas).compactMap({ $0 as? NSButton })
                            .first(where: { $0.accessibilityIdentifier() == "raster-preview-zoom-in" })
                    else { throw Failure.check(#line) }
                    try require(canvas.fitsWindow && canvas.magnification > 0)
                    let fitted = canvas.magnification
                    try require(zoom.isEnabled)
                    zoom.performClick(nil)
                    try UIVerification.require(!canvas.fitsWindow && canvas.magnification > fitted,
                        "Image zoom fitted=\(fitted) current=\(canvas.magnification) fits=\(canvas.fitsWindow)")
                    let zoomed = canvas.magnification, originalFrame = panel.frame
                    panel.setFrame(.init(origin: originalFrame.origin,
                        size: .init(width: originalFrame.width + 100, height: originalFrame.height + 50)), display: true)
                    preview.layoutForVerification()
                    try require(abs(canvas.magnification - zoomed) < 0.0001)
                    try await capture(panel, label + "-zoomed")
                    panel.setFrame(originalFrame, display: true)
                    guard let reset = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                        timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                        characters: "0", charactersIgnoringModifiers: "0", isARepeat: false, keyCode: 29)
                    else { throw Failure.check(#line) }
                    try require(panel.performKeyEquivalent(with: reset))
                    preview.layoutForVerification()
                    try UIVerification.require(canvas.fitsWindow && abs(canvas.magnification - fitted) < 0.01,
                        "Image Fit after resize initial=\(fitted) current=\(canvas.magnification) fits=\(canvas.fitsWindow)")
                    try await capture(panel, label)
                }
                else { try require(preview.imageSizeForVerification == nil) }
                panel.performClose(nil)
                try await wait { !preview.retainsPresentation }
                await preview.drain()
            }
            func record(_ window: NSWindow, _ label: String, action: @MainActor () throws -> Void) async throws {
                if offscreen { try action(); return }
                let report = try await NativeMotionRecorder.record(window: window, root: location, label: label,
                    sampling: .diagnostic(for: window), action: action)
                try JSONEncoder().encode(report).write(to: location.appendingPathComponent("evidence/" + label + ".json"), options: .withoutOverwriting)
                clips.append(DevelopmentMotionVerification.clip(label, report: report, field: nil, window: window))
            }
            CompressedTARFeature.qualifying = compressed
            ApplicationCompressedArchives.shared.cacheDirectoryForVerification = location.appendingPathComponent("cache")
            let large=ProcessInfo.processInfo.arguments.contains("--large-interface"),settings=BrowserSettings(persist:false)
            settings.appearance=large ? .light:.dark;settings.navigationStyle = .glass;settings.glassFileContent=true
            settings.motion.mode=large ? .reduced:.full;settings.interfaceSize = .init(large ? 150:100)
            settings.autoRefreshFolders=false;settings.restoresSession=false;settings.reviewsRecoveryAtStartup=false
            settings.opensArchivesInTraverse=true
            InterfacePresentation.shared.bind(settings)
            let controller=BrowserWindowController(settings:settings);owner=controller
            let browser=controller.browser;browser.readVolumesForVerification={[]};browser.permitsBackgroundVerification=true
            func compareText(_ table: FileTableView, paths: [String], embedded: Bool, screenshot: String) async throws {
                guard let parent = table.window, paths.count == 2 else { throw Failure.check(#line) }
                show(parent)
                try require(parent.makeFirstResponder(table))
                table.selectRowIndexes([0, 1], byExtendingSelection: false)
                let menu = embedded ? BrowserMenus.menu(.file, target: browser) : table.contextMenuProvider?()
                let command = menu.flatMap { menu in
                    embedded ? BrowserMenus.commandItem(#selector(BrowserViewController.compareTextFiles(_:)), in: menu)
                        : menu.items.first(where: { $0.title == "Compare Text Files…" })
                }
                guard let item = command, let action = item.action,
                      (item.target as? NSMenuItemValidation)?.validateMenuItem(item) == true else { throw Failure.check(#line) }
                try require(NSApp.sendAction(action, to: item.target, from: item))
                try await wait { controller.workspace.textComparisonWindow?.planForVerification != nil }
                guard let comparison = controller.workspace.textComparisonWindow, let window = comparison.window else { throw Failure.check(#line) }
                let expected = paths.map { $0 == "Note.txt" ? "note" : "abc" }
                try require(Set(paths) == ["Note.txt", "Folder/Member.txt"]
                    && comparison.beforeSurface.textView.string == expected[0]
                    && comparison.currentSurface.textView.string == expected[1]
                    && comparison.labels.left == paths[0] && comparison.labels.right == paths[1]
                    && comparison.planForVerification?.changedLineCounts?.added == 1
                    && comparison.planForVerification?.changedLineCounts?.removed == 1
                    && !comparison.beforeSurface.textView.isEditable && !comparison.currentSurface.textView.isEditable)
                try await capture(window, screenshot)
                await comparison.closeAndDrain()
                parent.makeKeyAndOrderFront(nil)
            }
            func compareTAR(_ model: TARBrowserModel, rows: TARMetadataRows, embedded: Bool, screenshot: String) async throws {
                model.scope = .archive
                model.query = ".txt"
                try await wait { !model.busy && rows.rowIDsForVerification == model.items.map(\.id)
                    && Set(model.items.map(\.path)) == ["Note.txt", "Folder/Member.txt"] }
                try await compareText(rows.table, paths: model.items.map(\.path), embedded: embedded, screenshot: screenshot)
                model.query = ""
                model.scope = .folder
                try await wait { !model.busy && rows.rowIDsForVerification == model.items.map(\.id)
                    && model.items.map(\.name) == ["Folder", "Note.txt"] }
            }
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            browser.clipboardWriter = { text, urls in BrowserClipboard.publish(text, urls: urls, to: board) }
            func inspect(_ table: FileTableView, archive: String, path: String,
                         bytes: UInt64, compression: String?, recordedTime: TimeInterval,
                         hasTimeZone: Bool, screenshot: String) async throws {
                guard let menu = table.contextMenuProvider?(),
                      let index = menu.items.firstIndex(where: { $0.title == "Properties…" }) else { throw Failure.check(#line) }
                menu.performActionForItem(at: index)
                guard let properties = browser.listedItemPropertiesController, let details = properties.window,
                      case .archive(let item) = properties.selection else { throw Failure.check(#line) }
                try require(item.archiveName == archive && item.path == path && item.logicalBytes == bytes
                    && item.compression == compression && (item.packedBytes != nil) == (compression != nil)
                    && item.modification?.date.timeIntervalSince1970 == recordedTime && item.modification?.hasTimeZone == hasTimeZone
                    && !properties.canCalculateSize)
                properties.copyName()
                try require(board.string(forType: .string) == item.name && board.availableType(from: [.fileURL]) == nil)
                if browser.isArchiveLocation {
                    let copy = NSMenuItem(title: "Copy Path", action: #selector(BrowserViewController.copyPath(_:)), keyEquivalent: "")
                    copy.target = browser
                    try require(browser.validateMenuItem(copy) && copy.title == "Copy Path in Archive"
                        && NSApp.sendAction(copy.action!, to: browser, from: copy))
                } else { properties.copyPath() }
                try require(board.string(forType: .string) == path && board.availableType(from: [.fileURL]) == nil)
                try await capture(details, screenshot)
                properties.done()
                try await wait { properties.window == nil }
            }
            browser.folderAccess=FolderAccessController(stateDirectory:nil)
            browser.recoverableFileOperations=browser.operationCoordinator.engine(at:location.appendingPathComponent("state/history"))
            browser.privateNames=ApplicationPrivateNames(directory:location.appendingPathComponent("state/names"),settings:settings)
            let source=location.appendingPathComponent(compressed ? "source/Review.tar.gz" : "source/Review.tar")
            let originalDigest = try await Task.detached { SHA256.hash(data: try Data(contentsOf: source)) }.value
            browser.tabs=[.init(location:.directory(source.deletingLastPathComponent()))];browser.activeID=browser.tabs[0].id;browser.loadLocation()
            guard let main=controller.window else{throw Failure.check(#line)}
            main.setContentSize(.init(width:large ? 1180:980,height:large ? 740:650))
            main.title="Archive source · generated review";show(main)
            try await wait{!browser.isLoading && browser.orderingTask==nil && browser.rowsByURL[source] != nil}
            if !compressed && inline {
                let zip = source.deletingLastPathComponent().appendingPathComponent("Review.zip")
                try require(browser.rowsByURL[zip] != nil)
                browser.setFileSelection([zip]); browser.fileSelectionDidChange(); browser.openSelection(nil)
                try await wait { browser.currentArchive?.hasRenderedCurrentRowsForVerification == true && browser.currentArchive?.busy == false }
                guard let archive = browser.currentArchive, let table = archive.table,
                      let model = archive.zipModelForVerification,
                      let index = model.visibleItems.firstIndex(where: { $0.name == "Note.txt" }) else { throw Failure.check(#line) }
                try await verifyEmbeddedShortcuts(browser: browser, table: table)
                if !offscreen {
                    try await verifyArchiveNameSelection(table, browser: browser, names: model.visibleItems.map(\.name),
                        extraName: "Poster.png", embedded: true)
                    archive.setScope(.archive)
                    archive.setQuery(".txt")
                    try await wait { !model.isQueryPending && table.numberOfRows == 2 && model.visibleItems.count == 2 }
                    try await compareText(table, paths: model.visibleItems.map(\.path), embedded: true, screenshot: "zip-archive-text-diff")
                    archive.setQuery("")
                    archive.setScope(.folder)
                    try await wait { !model.isQueryPending && table.numberOfRows == model.visibleItems.count && model.visibleItems.count > 2 }
                }
                try require(!browser.commandEnabled(#selector(BrowserViewController.showProperties(_:))))
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                try await inspect(table, archive: "Review.zip", path: "Note.txt", bytes: 4,
                    compression: "Deflate", recordedTime: 1_709_213_696, hasTimeZone: false, screenshot: "zip-member-properties")
                guard let poster = model.visibleItems.firstIndex(where: { $0.name == "Poster.png" }) else { throw Failure.check(#line) }
                table.selectRowIndexes(IndexSet(integer: poster), byExtendingSelection: false)
                main.makeKeyAndOrderFront(nil); main.makeFirstResponder(table)
                try await checkImage(model.textPreviewForVerification, valid: true, label: "zip-member-image") {
                    guard let menu = table.contextMenuProvider?(),
                          let image = menu.items.firstIndex(where: { $0.title == "Preview Image" }) else { throw Failure.check(#line) }
                    menu.performActionForItem(at: image)
                }
                table.deselectAll(nil)
                try require(!browser.commandEnabled(#selector(BrowserViewController.showProperties(_:))))
                try await verifyTypedAddress(browser: browser, capture: { try await capture(main, $0) })
                if !offscreen {
                ApplicationZIPBrowser.shared.show(zip, from: browser)
                guard let separateZIP = ApplicationZIPBrowser.shared.controller,
                      let zipWindow = separateZIP.window else { throw Failure.check(#line) }
                show(zipWindow)
                try await wait { separateZIP.model.viewIsCurrent && !separateZIP.model.isPreparingSelection
                    && separateZIP.model.rowsForVerification?.table.numberOfRows == separateZIP.model.visibleItems.count }
                guard let zipRows = separateZIP.model.rowsForVerification,
                      let note = separateZIP.model.visibleItems.firstIndex(where: { $0.name == "Note.txt" }) else { throw Failure.check(#line) }
                try await verifyArchiveNameSelection(zipRows.table, browser: browser, names: separateZIP.model.visibleItems.map(\.name),
                    extraName: "Poster.png", embedded: false)
                separateZIP.model.nameScope = .archive
                separateZIP.model.filter = ".txt"
                try await wait { !separateZIP.model.isQueryPending && zipRows.table.numberOfRows == 2 && separateZIP.model.visibleItems.count == 2 }
                try await compareText(zipRows.table, paths: separateZIP.model.visibleItems.map(\.path),
                    embedded: false, screenshot: "zip-window-text-diff")
                separateZIP.model.filter = ""
                separateZIP.model.nameScope = .folder
                try await wait { !separateZIP.model.isQueryPending && zipRows.table.numberOfRows == separateZIP.model.visibleItems.count
                    && separateZIP.model.visibleItems.count > 2 }
                zipRows.table.selectRowIndexes([note], byExtendingSelection: false)
                try await verifyStandaloneClipboard(owner: controller, browser: browser,
                    source: zip, archiveWindow: zipWindow, clipboard: separateZIP.clipboard, table: zipRows.table,
                    ready: { separateZIP.model.viewIsCurrent && !separateZIP.model.isPreparingSelection },
                    cutAllowed: separateZIP.model.canMoveMembers(separateZIP.model.selection), board: board,
                    destination: location.appendingPathComponent("source/Separate ZIP Paste Destination", isDirectory: true))
                await ApplicationZIPBrowser.shared.stopAndDrain()
                browser.clipboardState.synchronize(); try require(browser.clipboardState.scopedItem == nil)
                }
                browser.navigate(to: .directory(source.deletingLastPathComponent()))
                try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
                show(main)
                checks.append("Current ZIP row Properties uses recorded compression and size; exact text Copy and empty-selection refusal do not open any content")
            }
            browser.setFileSelection([source]);browser.fileSelectionDidChange();try require(browser.selectedTARURL==source)
            if compressed {
                // A queued explicit Open cannot leak into a later passive
                // presentation before the archive pool has admitted its model.
                browser.openSelection(nil)
                browser.navigate(to: .directory(source.deletingLastPathComponent()))
                browser.navigate(to: .archive(try ArchiveLocation(source: source, format: .tar)))
            } else {
                try require(NSApplication.shared.sendAction(#selector(BrowserViewController.browseZIP(_:)),to:browser,from:nil))
            }
            let model: TARBrowserModel
            let window: NSWindow
            if compressed || inline {
                try await wait { browser.currentArchive?.tarModelForVerification != nil }
                guard let embedded = browser.currentArchive?.tarModelForVerification else { throw Failure.check(#line) }
                model = embedded; window = main
                if compressed {
                try await wait { model.requiresPreparation && !model.busy }
                try require(model.summary == nil && !model.current && !model.canExtract
                    && !FileManager().fileExists(atPath: location.appendingPathComponent("cache/compressed-archives").path))
                window.title="TAR Archive · generated review"
                try await capture(window, "compressed-prepare")
                guard let content = window.contentView,
                      let item = descendants(content).compactMap({ $0 as? NSPopUpButton }).flatMap({ $0.itemArray })
                        .first(where: { $0.title == "Prepare Compressed Archive" }), let action = item.action else { throw Failure.check(#line) }
                try require((item.target as? NSMenuItemValidation)?.validateMenuItem(item) == true)
                try await record(window, "tar-prepare") {
                    _ = NSApplication.shared.sendAction(action, to: item.target, from: item)
                }
                checks.append("Leaving a queued explicit Open invalidates its preparation intent; passive presentation shows Prepare without cache/body preparation, and the native Prepare command still admits the bounded operation")
                }
            } else {
                guard let archive=ApplicationTARBrowser.shared.controller,let native=archive.window else{throw Failure.check(#line)}
                model=archive.model; window=native
            }
            window.setContentSize(.init(width:large ? 1180:980,height:large ? 740:650));window.title="TAR Archive · generated review";show(window)
            try await wait{model.current && !model.busy}
            try require(model.items.map(\.name)==["Folder","Note.txt"] && model.summary?.files==4 && model.summary?.folders==2)
            guard let content=window.contentView,let rows=descendants(content).compactMap({$0 as? TARMetadataRows}).first else{throw Failure.check(#line)}
            // The model publishes before its coalesced AppKit table render.
            try await wait { rows.table.numberOfRows == 2 && rows.rowIDsForVerification == model.items.map(\.id) }
            if compressed || inline { try await verifyEmbeddedShortcuts(browser: browser, table: rows.table) }
            if !offscreen {
                try await verifyArchiveNameSelection(rows.table, browser: browser, names: model.items.map(\.name),
                    extraName: "Folder", embedded: compressed || inline)
                try BrowserShortcutVerification.verifyArchiveContextMenu(rows.table, browser: browser, settings: model.settings, label: "TAR member table")
                try await compareTAR(model, rows: rows, embedded: compressed || inline,
                    screenshot: compressed ? "tar-gzip-text-diff" : "tar-archive-text-diff")
                checks.append("TAR keyboard and native ShowMenu actions preserve multiple selection and respect preset/custom/cleared bindings")
                checks.append("Select by Name uses the shared native sheet for the displayed archive page, with normal typing, Return, Replace and Add.")
                checks.append("Two archive search results open the exact member versions in the native text comparison. Browsing, normal extraction and Undo still use their ordinary owners.")
                if inline && !compressed {
                    ApplicationTARBrowser.shared.show(source, from: browser)
                    guard let separate = ApplicationTARBrowser.shared.controller,
                          let separateWindow = separate.window else { throw Failure.check(#line) }
                    show(separateWindow)
                    try await wait {
                        separate.model.current && !separate.model.busy
                            && separateWindow.contentView.map {
                                descendants($0).contains { ($0 as? TARMetadataRows)?.table.numberOfRows == 2 }
                            } == true
                    }
                    guard let content = separateWindow.contentView,
                          let separateRows = descendants(content).compactMap({ $0 as? TARMetadataRows }).first else { throw Failure.check(#line) }
                    try await wait { separateWindow.isKeyWindow }
                    try await verifyArchiveNameSelection(separateRows.table, browser: browser, names: separate.model.items.map(\.name),
                        extraName: "Folder", embedded: false)
                    try BrowserShortcutVerification.verifyArchiveContextMenu(separateRows.table, browser: browser,
                        settings: separate.model.settings, label: "Separate TAR window")
                    try await compareTAR(separate.model, rows: separateRows, embedded: false, screenshot: "tar-window-text-diff")
                    guard let query = descendants(content).compactMap({ $0 as? NSTextField })
                        .first(where: { $0.identifier?.rawValue == "tar-name-query" }),
                          separateWindow.makeFirstResponder(query), let nativeEditor = query.currentEditor() as? NSTextView else {
                        throw Failure.check(#line)
                    }
                    try require(abs((query.font?.pointSize ?? 0) - (large ? 19.5 : 13)) < 0.01)
                    nativeEditor.selectAll(nil); nativeEditor.insertText("Note", replacementRange: nativeEditor.selectedRange())
                    nativeEditor.keyDown(with: UIVerification.key("\r", code: 36, flags: [], window: separateWindow))
                    try await wait { separate.model.current && !separate.model.busy && separate.model.query == "Note"
                        && separate.model.items.map(\.name) == ["Note.txt"] }
                    nativeEditor.keyDown(with: UIVerification.key("\u{1b}", code: 53, flags: [], window: separateWindow))
                    try await wait { separate.model.current && !separate.model.busy && separate.model.query.isEmpty
                        && separateRows.table.numberOfRows == 2 }
                    try require(separateWindow.makeFirstResponder(separateRows.table))
                    try await capture(separateWindow, "separate-tar-keyboard")
                    guard let note = separate.model.items.firstIndex(where: { $0.name == "Note.txt" }) else { throw Failure.check(#line) }
                    separateRows.table.selectRowIndexes([note], byExtendingSelection: false)
                    try await verifyStandaloneClipboard(owner: controller, browser: browser,
                        source: source, archiveWindow: separateWindow, clipboard: separate.clipboard, table: separateRows.table,
                        ready: { separate.model.current && !separate.model.busy && !separate.model.isPreparingPreview },
                        cutAllowed: separate.model.canGroupMembers, board: board,
                        destination: location.appendingPathComponent("source/Separate Paste Destination", isDirectory: true))
                    await ApplicationTARBrowser.shared.closeAndDrain()
                    browser.clipboardState.synchronize()
                    try require(browser.clipboardState.scopedItem == nil)
                    show(window)
                    try await wait { window.isKeyWindow }
                    checks.append("Separate ZIP/TAR Copy delivers exact bytes into a local pane with Undo; remapped New Folder, Create File, Duplicate and Remove open their actual reviews and Cancel unchanged. Local Add rejects a changed clipboard, source close expires its intent, and native keys follow the focused archive")
                }
            }
            try require(rows.table.marquee != nil)
            checks.append("ordinary Browse Archive routing, metadata-only summary and the shared native selection controller")
            for(label,back)in[("tar-folder-open",false),("tar-folder-back",true)] {
                // Inline navigation restores the ordinary browser title.
                // Reapply this check's exact capture title at each boundary.
                window.title="TAR Archive · generated review"
                try await record(window, label) {
                    if back{model.back()}else{rows.table.selectRowIndexes([0],byExtendingSelection:false);model.openSelection()}
                }
                try await wait{model.current && !model.busy}
                try require(back ? model.breadcrumbs.count==1 : model.breadcrumbs.count==2
                    && model.items.map(\.name)==["Empty","Broken.png","Member.txt","Poster.png"])
                if !back {
                    try await wait { rows.rowIDsForVerification == model.items.map(\.id) }
                    model.previewOffscreenForVerification = offscreen
                    let preview = model.textPreviewForVerification
                    guard let broken = model.items.firstIndex(where: { $0.name == "Broken.png" }),
                          let poster = model.items.firstIndex(where: { $0.name == "Poster.png" }) else { throw Failure.check(#line) }
                    rows.table.selectRowIndexes(IndexSet(integer: broken), byExtendingSelection: false)
                    try await checkImage(preview, valid: false, label: "tar-invalid-image", open: model.openSelection)
                    rows.table.selectRowIndexes(IndexSet(integer: poster), byExtendingSelection: false)
                    show(window); window.makeFirstResponder(rows.table)
                    try await checkImage(preview, valid: true, label: "tar-member-image") {
                        guard let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                            isARepeat: false, keyCode: 49) else { throw Failure.check(#line) }
                        rows.table.keyDown(with: space)
                    }
                    show(window)
                }
            }
            checks.append("Ordinary folder navigation and Back restore the correct recorded pages")
            if inline {
                try await verifyTypedAddress(browser: browser, capture: { try await capture(window, $0) })
                checks.append("Native ZIP/TAR address editing preserves full paths, checks missing folders before navigation and supports relative folders, Back/Forward, Escape and stale-field refusal")
            }
            checks.append("Native archive image preview checks the selected complete image without extracting it; a mislabeled image shows an error and the next Space preview succeeds")
            let clipboardHistoryCount = (compressed || inline ? 2 : 0) + (inline && !compressed && !offscreen ? 2 : 0)
            if compressed || inline {
                try await verifyFolderPaste(owner: controller, browser: browser, model: model, rows: rows,
                    board: board, destination: location.appendingPathComponent("source/Paste Destination", isDirectory: true))
                checks.append("TAR Copy/Paste and shared native row-drop callbacks each copy a folder directly with nested text/empty child and ordinary Undo; stale selection and duplicate-drop admission refuse, and TAR offers carry no ZIP identity")
            }
            if compressed || inline {
                let previousItems = model.items.map(\.id)
                browser.navigate(to: .directory(source.deletingLastPathComponent()))
                try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
                try await Task.detached {
                    let bytes = try Data(contentsOf: source)
                    try bytes.write(to: source, options: .atomic)
                }.value
                if compressed {
                    let preparations = ApplicationCompressedArchives.shared.preparationRequestsForVerification
                    browser.navigate(to: .archive(try ArchiveLocation(source: source, format: .tar)))
                    try await wait { model.requiresPreparation && !model.busy }
                    try require(model.summary == nil && !model.current
                        && ApplicationCompressedArchives.shared.preparationRequestsForVerification == preparations)
                    checks.append("Passive return to a changed prepared source admits no new preparation request; stale rows are unavailable")
                    browser.navigate(to: .directory(source.deletingLastPathComponent()))
                    try await wait { !browser.isLoading && browser.rowsByURL[source] != nil }
                }
                browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.openSelection(nil)
                if compressed && !CompressedArchiveOpenFeature.available {
                    try await wait { browser.currentArchive?.tarModelForVerification?.requiresPreparation == true
                        && browser.currentArchive?.tarModelForVerification?.busy == false }
                    guard let reopened = browser.currentArchive?.tarModelForVerification else { throw Failure.check(#line) }
                    try require(!reopened.current && reopened.summary == nil)
                    reopened.prepareCompressed()
                }
                try await wait { model.current && !model.busy && model.items.map(\.id) != previousItems }
                try require(model.items.map(\.name) == ["Folder", "Note.txt"])
                checks.append("A replaced source invalidates retained rows; a deliberate Development Open prepares the reused compressed owner without a second click")
                if compressed && CompressedArchiveOpenFeature.available {
                    browser.currentArchive?.stop()
                    await browser.currentArchive?.drain()
                    try require(model.requiresPreparation && !model.current)
                    browser.navigate(to: .directory(source.deletingLastPathComponent()))
                    try await wait { !browser.isLoading && browser.rowsByURL[source] != nil }
                    browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.openSelection(nil)
                    try await wait { model.current && !model.busy }
                    try require(model.items.map(\.name) == ["Folder", "Note.txt"])
                    checks.append("A fresh explicit Open resumes a stopped, reused compressed owner; Stop itself never retries preparation")
                }
            }
            guard let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,characters:"f",charactersIgnoringModifiers:"f",isARepeat:false,keyCode:3)else{throw Failure.check(#line)}
            try require(window.performKeyEquivalent(with:event))
            guard let field=descendants(content).compactMap({$0 as? NSTextField}).first(where:{$0.placeholderString==(compressed || inline ? "Find archive names":"Find names")}),
                  let editor=field.currentEditor()as?NSTextView else{throw Failure.check(#line)}
            model.scope = .archive;editor.selectAll(nil);editor.insertText("Member",replacementRange:.init(location:0,length:editor.string.utf16.count))
            try await wait{model.current && !model.busy && model.query=="Member" && model.items.count==1}
            try require(model.items[0].path=="Folder/Member.txt");window.makeFirstResponder(rows.table)
            rows.table.sortDescriptors=[NSSortDescriptor(key:"modified",ascending:false)]
            try await wait{model.current && !model.busy && model.order.field == .modified && model.order.descending}
            checks.append("Command-F uses the native editor; entire-archive name filtering and Date Modified header sort reach the stored session")
            try await wait { rows.rowIDsForVerification == model.items.map(\.id) }
            rows.table.selectRowIndexes([0], byExtendingSelection: false)
            try await inspect(rows.table, archive: source.lastPathComponent, path: "Folder/Member.txt", bytes: 3,
                compression: nil, recordedTime: compressed ? 1_700_000_123.125 : 1_700_000_123,
                hasTimeZone: true, screenshot: "tar-member-properties")
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(rows.table)
            checks.append("TAR Properties shares the native listed-item window, copies its recorded path and does not infer a packed size")
            try require(model.canPreviewSelected)
            model.previewOffscreenForVerification = offscreen
            model.previewSelected()
            let preview = model.textPreviewForVerification
            try await wait { !model.isPreparingPreview && !preview.isReading && preview.textForVerification == "abc" }
            try require(preview.statusForVerification?.contains("3 UTF-8 bytes") == true
                && preview.statusTipForVerification?.contains("no per-file content checksum") == true)
            if let native = preview.windowForVerification { try await capture(native, "tar-selected-text") }
            model.previewSelectedAsBytes()
            try await wait { !model.isPreparingPreview && !preview.isReading
                && preview.statusForVerification?.contains("hexadecimal offsets") == true }
            try require(preview.textForVerification?.contains("61 62 63") == true)
            if let native = preview.windowForVerification { try await capture(native, "tar-selected-hex") }
            preview.windowForVerification?.performClose(nil)
            // Accepted user Close may finish through the shared short fade.
            // Keep the presentation owned until AppKit actually closes it.
            try await wait { !preview.retainsPresentation }
            await preview.drain()
            try require(!preview.retainsPresentation && preview.textForVerification?.isEmpty != false)
            checks.append("Explicit Text/Hex previews show exact read-only member bytes through one preview owner, then close and drain; editable Open has its separate native editor flow")
            func requestExtraction()async throws{
                // Model publication precedes the coalesced AppKit render.
                // Drive a row only once the actual visible page has arrived.
                try await wait { model.current && !model.busy && rows.rowIDsForVerification == model.items.map(\.id) }
                rows.table.selectRowIndexes([0],byExtendingSelection:false)
                try await wait { model.selectedSupported }
                guard let item=rows.table.menu?.items.first(where:{$0.title=="Extract Selected…"}),let action=item.action else{throw Failure.check(#line)}
                try require(rows.validateMenuItem(item) && NSApplication.shared.sendAction(action,to:item.target,from:item))
            }
            try await requestExtraction();try await wait{ApplicationArchiveExtraction.shared.controller?.model.canExtract==true}
            guard let first=ApplicationArchiveExtraction.shared.controller else{throw Failure.check(#line)}
            try require(first.model.selectedCount==1 && first.model.tarMembers != nil && first.model.members==nil
                && first.model.isFileExtraction && first.model.name == "Member.txt")
            first.window?.performClose(nil);await ApplicationArchiveExtraction.shared.closeAndDrain()
            try require(try await browser.recoverableFileOperations!.inspectExistingHistory().records.count == clipboardHistoryCount)
            checks.append("Cancel before admission creates no operation history or output")
            try await requestExtraction();try await wait{ApplicationArchiveExtraction.shared.controller?.model.canExtract==true}
            guard let extraction=ApplicationArchiveExtraction.shared.controller,let review=extraction.window else{throw Failure.check(#line)}
            review.title="Extract TAR · generated review";show(review)
            try require(extraction.model.summary?.files==1 && extraction.model.summary?.folders==0 && extraction.model.summary?.bytes==3)
            extraction.model.name = source.lastPathComponent
            try await wait { !extraction.model.isPreparing && extraction.model.notice == FileOperationFailure.conflict.userMessage }
            try require(!extraction.model.canExtract && extraction.model.outcome == nil)
            extraction.model.name = "Member.txt"
            try await wait { extraction.model.canExtract }
            if !offscreen { try await capture(review, "tar-extract-file") }
            // The archive window can retire after its exact selection has been
            // reviewed. The separate operation owner keeps source authority.
            await ApplicationTARBrowser.shared.closeAndDrain()
            if compressed || inline { await browser.currentArchive?.closeAndDrain() }
            extraction.model.extract();try await wait{extraction.model.outcome != nil && !extraction.model.isRunning}
            try require(extraction.model.outcome?.result.disposition == .succeeded && extraction.model.canUndo)
            guard let output=extraction.model.outcome?.result.items.first?.destination else{throw Failure.check(#line)}
            try require(output == source.deletingLastPathComponent().appendingPathComponent("Member.txt"))
            try require(try await Task.detached { try Data(contentsOf: output) == Data("abc".utf8) }.value)
            extraction.model.undo();try await wait{extraction.model.undoOutcome != nil && !extraction.model.isRunning}
            try require(extraction.model.undoOutcome?.result.disposition == .succeeded && !FileManager().fileExists(atPath:output.path))
            let history=try await browser.recoverableFileOperations!.inspectExistingHistory()
            try require(history.records.count == clipboardHistoryCount + 1
                && history.records.filter { $0.operation == "Extract ZIP" }.count == (inline && !compressed && !offscreen ? 1 : 0)
                && history.records.allSatisfy { ["Extract TAR", "Extract ZIP"].contains($0.operation) })
            try require(history.records.contains { $0.locations.contains(output) }
                && !history.records.flatMap(\.locations).contains(where: { $0.path.hasPrefix(location.appendingPathComponent("cache").path + "/") }))
            try require(try await Task.detached { SHA256.hash(data: try Data(contentsOf: source)) == originalDigest }.value)
            checks.append("Single selected extraction refuses a collision, survives archive-window close, publishes the exact file without a wrapper and has reachable Undo")
            await ApplicationArchiveExtraction.shared.closeAndDrain()
            if compressed {
                try ApplicationCompressedArchives.shared.prepareForQuiescence()
                guard let gate = ApplicationFileActivity.gate.closeAdmission() else { throw Failure.check(#line) }
                let drained = await ApplicationCompressedArchives.shared.drain()
                let activityDrained = await ApplicationFileActivity.gate.waitUntilDrained(gate)
                ApplicationFileActivity.gate.reopen(gate)
                ApplicationCompressedArchives.shared.resumeAfterQuiescence()
                try require(drained && activityDrained)
                checks.append("Actual prepared-copy retirement drains before the simulated volume barrier reopens; no device action is requested")

                let damaged = location.appendingPathComponent("source/Damaged.tgz")
                try await Task.detached {
                    var data = try Data(contentsOf: source)
                    guard data.count >= 8 else { throw Failure.check(#line) }
                    data[data.count - 8] ^= 1 // generated gzip CRC mismatch
                    try data.write(to: damaged, options: .withoutOverwriting)
                }.value
                browser.navigate(to: .directory(source.deletingLastPathComponent()))
                try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[damaged] != nil }
                browser.setFileSelection([damaged]); browser.fileSelectionDidChange()
                try require(NSApplication.shared.sendAction(#selector(BrowserViewController.browseZIP(_:)), to: browser, from: nil))
                try await wait { browser.currentArchive?.tarModelForVerification?.requiresPreparation == true
                    && browser.currentArchive?.tarModelForVerification?.busy == false }
                guard let failedModel = browser.currentArchive?.tarModelForVerification else { throw Failure.check(#line) }
                failedModel.prepareCompressed()
                try await wait { !failedModel.busy }
                try require(!failedModel.current && failedModel.summary == nil && !failedModel.canExtract
                    && failedModel.notice.contains("damaged"))
                try await capture(main, "compressed-failure")
                await browser.currentArchive?.closeAndDrain()
                try require(await ApplicationCompressedArchives.shared.closeAndDrain())
                let unchanged = try await browser.recoverableFileOperations!.inspectExistingHistory()
                try require(unchanged.records.count == clipboardHistoryCount + 1)
                checks.append("Damaged gzip refuses a current catalog, extraction and new history through the ordinary UI; failed preparation and its descriptors drain")
            }
            try await verifyDirectExtraction(browser: browser, source: source)
            checks.append("Direct whole-archive extraction prepares plain/compressed TAR in the shared workbench, preserves the source, avoids an occupied folder and Undoes the exact output")
            if compressed {
                let bzip2 = location.appendingPathComponent("source/Review bzip2.tbz")
                try await verifyDirectExtraction(browser: browser, source: bzip2)
                checks.append("The same whole-archive extraction prepares a bzip2 TAR alias, keeps its compound identity and verifies nested/empty delivery, collision naming and Undo")
                if inline && !offscreen {
                    try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[bzip2] != nil }
                    show(main)
                    browser.setFileSelection([bzip2]); browser.fileSelectionDidChange(); browser.openSelection(nil)
                    try await wait { browser.currentArchive?.hasRenderedCurrentRowsForVerification == true
                        && browser.currentArchive?.tarModelForVerification?.current == true && browser.currentArchive?.busy == false }
                    guard let candidate = browser.currentArchive?.tarModelForVerification, let content = main.contentView,
                          let matches = descendants(content).compactMap({ $0 as? TARMetadataRows }).first(where: { $0.window === main }) else { throw Failure.check(#line) }
                    try await compareTAR(candidate, rows: matches, embedded: true, screenshot: "tar-bzip2-text-diff")
                    checks.append("A prepared bzip2 TAR alias opens the exact same two text members through the native comparison.")
                }
            }
            if inline && !offscreen {
                try await verifyInactivePaneClipboard(owner: controller, root: location, board: board, compressed: compressed)
                checks.append("Closing a pane moves its inactive copied archive tab without reopening it; explicit navigation survives pending pane startup, and Paste from the surviving local pane delivers exact bytes with ordinary Undo")
            }
            try require(ApplicationFileActivity.gate.activeCount==0 && browser.operationTask==nil && browser.operationPreparationTask==nil)
            try write(["passed":true,"checks":checks,"clips":clips,"interfacePercent":settings.interfaceSize.percent,"activityAfter":0,
                "metadataOnlyDefault":true,"compressedPreparedExplicitly":compressed,"explicitPreview":true,"explicitExtraction":true,
                "offscreenFunctionalFlow":offscreen,"visualInspection":!offscreen,"physicalPointer":false,"osGrantAcceptance":false,"networkRequests":0,"keychainCalls":0],root:location)
        }catch{
            var line:UInt=0;if case let Failure.check(value)=error{line=value}
            if let root{try?write(["passed":false,"line":line,"errorType":String(reflecting:type(of:error)),
                "failure":String(describing:error),"message":(error as? UIVerification.Failure)?.message ?? "",
                "checks":checks,"clips":clips],root:root)}
        }
        await ApplicationTARBrowser.shared.closeAndDrain();await ApplicationArchiveExtraction.shared.closeAndDrain()
        await ArchiveTabCatalogPool.shared.closeAndDrain(); _ = await ApplicationCompressedArchives.shared.closeAndDrain()
        owner?.suspendBrowsing();await owner?.flushSession();owner?.window?.close();NSApplication.shared.terminate(nil)
    }

    private static func verifyDirectExtraction(browser: BrowserViewController, source: URL) async throws {
        browser.navigate(to: .directory(source.deletingLastPathComponent()))
        try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil && browser.canStartArchiveExtraction }
        browser.setFileSelection([source]); browser.fileSelectionDidChange()
        let before = try await Task.detached { SHA256.hash(data: try Data(contentsOf: source)) }.value
        let stem = ArchiveActionNames.extractionFolder(for: source)
        let occupied = source.deletingLastPathComponent().appendingPathComponent(stem, isDirectory: true)
        try await Task.detached { try FileManager().createDirectory(at: occupied, withIntermediateDirectories: false) }.value
        browser.extractArchiveDirect(nil)
        guard let review = ApplicationArchiveExtraction.shared.controller else { throw Failure.check(#line) }
        try await wait { review.model.outcome != nil && !review.model.isRunning && browser.operationTask == nil }
        try UIVerification.require(review.model.outcome?.result.disposition == .succeeded,
            "Direct TAR extraction failed: " + review.model.notice)
        guard let id = review.model.outcome?.recordID, let engine = browser.recoverableFileOperations else { throw Failure.check(#line) }
        let destination = source.deletingLastPathComponent().appendingPathComponent(stem + " 2", isDirectory: true)
        try require(review.model.name == destination.lastPathComponent)
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        let contents = try await Task.detached {
            try Data(contentsOf: destination.appendingPathComponent("Folder/Member.txt")) == Data("abc".utf8)
                && FileManager().contentsOfDirectory(atPath: destination.appendingPathComponent("Folder/Empty").path).isEmpty
                && SHA256.hash(data: Data(contentsOf: source)) == before
        }.value
        try require(contents)
        let inverse = await engine.undo(recordID: id)
        let unchanged = try await Task.detached {
            try FileManager().contentsOfDirectory(atPath: occupied.path).isEmpty
                && SHA256.hash(data: Data(contentsOf: source)) == before
                && !FileManager().fileExists(atPath: destination.path)
        }.value
        try require(inverse.result.disposition == .succeeded && unchanged)
    }

    private static func verifyTypedAddress(browser: BrowserViewController,
        capture: (String) async throws -> Void) async throws {
        guard case .archive(let root) = browser.location, root.folderPath.isEmpty,
              let owner = browser.currentArchive else { throw Failure.check(#line) }
        browser.view.window?.makeKeyAndOrderFront(nil)
        func path() -> [String]? {
            if case .archive(let current) = browser.location, current.source == root.source { return current.folderPath }
            return nil
        }
        func enter(_ text: String) throws {
            guard let editor = browser.pathField.currentEditor() else { throw Failure.check(#line) }
            browser.pathField.stringValue = text; editor.string = text
            browser.locationEntered(nil)
        }
        func settled(_ expected: [String]) async throws {
            try await wait { path() == expected && browser.currentArchive?.hasRenderedCurrentRowsForVerification == true
                && browser.currentArchive?.busy == false && browser.pathField.isHidden && browser.canvasTransition == nil }
        }
        browser.focusLocation(nil)
        try require(browser.pathField.stringValue == root.editablePath && !browser.pathField.isHidden)
        try enter(root.source.path + "/Missing Folder")
        try await wait { !owner.busy }
        try require(path() == [] && !browser.pathField.isHidden && owner.current
            && browser.pathField.stringValue.hasSuffix("/Missing Folder"))
        try enter(root.source.path + "/Folder")
        try await settled(["Folder"])
        browser.focusLocation(nil)
        try require(browser.pathField.stringValue == root.source.path + "/Folder")
        try await capture("archive-address-" + root.format.rawValue)
        try enter("Empty")
        try await settled(["Folder", "Empty"])
        browser.focusLocation(nil); try enter("../")
        try await settled(["Folder"])
        browser.goBack(nil); try await settled(["Folder", "Empty"])
        browser.goForward(nil); try await settled(["Folder"])
        browser.focusLocation(nil)
        try enter(root.source.path)
        try await settled([])
        browser.focusLocation(nil)
        browser.pathField.stringValue = "Folder"; browser.pathField.currentEditor()?.string = "Folder"
        browser.cancelLocationEditing()
        browser.locationEntered(nil) // A stale field cannot navigate this live visit.
        try require(path() == [] && browser.pathField.isHidden)
        browser.focusBrowserContent()
    }

    private static func verifyFolderPaste(owner: BrowserWindowController, browser: BrowserViewController,
        model: TARBrowserModel, rows: TARMetadataRows, board: NSPasteboard, destination: URL) async throws {
        let workspace = owner.workspace
        guard let engine = browser.recoverableFileOperations, let window = owner.window else { throw Failure.check(#line) }
        try await Task.detached { try FileManager().createDirectory(at: destination, withIntermediateDirectories: false) }.value
        workspace.activate(browser)
        if window.frame.width < 1140 { window.setContentSize(.init(width: 1140, height: window.contentLayoutRect.height)) }
        try UIVerification.require(owner.isWorkspacePresentation && workspace.splitActive(at: .trailing), "Actual TAR split-pane destination")
        let peer = workspace.activeBrowser
        peer.permitsBackgroundVerification = true; peer.recoverableFileOperations = engine
        peer.dragDrop.permitsVerification = true
        peer.navigate(to: .directory(destination))
        try await wait { !peer.isLoading && peer.orderingTask == nil && peer.location.directoryURL?.path == destination.path }
        window.makeKeyAndOrderFront(nil); workspace.activate(browser)
        browser.transferPasteboard = board
        try await wait { model.current && !model.busy && rows.rowIDsForVerification == model.items.map(\.id) }
        guard let folder = model.items.firstIndex(where: { $0.name == "Folder" }) else { throw Failure.check(#line) }
        rows.table.selectRowIndexes([folder], byExtendingSelection: false)
        let copy = NSMenuItem(title: "Copy", action: #selector(FileTableView.copy(_:)), keyEquivalent: "c")
        let cut = NSMenuItem(title: "Cut", action: #selector(FileTableView.cut(_:)), keyEquivalent: "x")
        let paste = NSMenuItem(title: "Paste", action: #selector(FileTableView.paste(_:)), keyEquivalent: "v")
        let output = destination.appendingPathComponent("Folder", isDirectory: true)
        func completeAndUndo(since earlier: UUID?) async throws {
            try await wait { ApplicationArchiveExtraction.shared.canAcceptPreparedSelection && peer.operationTask == nil
                && peer.lastRecoveryRecordID != earlier && !peer.isLoading && peer.rowsByURL[output] != nil }
            try require(peer.lastOperationResult?.disposition == .succeeded)
            try require(try await Task.detached {
                try Data(contentsOf: output.appendingPathComponent("Member.txt")) == Data("abc".utf8)
                    && FileManager().contentsOfDirectory(atPath: output.appendingPathComponent("Empty").path).isEmpty
            }.value)
            window.makeKeyAndOrderFront(nil); workspace.activate(peer); peer.focusBrowserContent()
            try await wait { peer.canUndoFileOperation }
            peer.undoFileOperation(nil)
            try await wait { peer.operationTask == nil && !peer.isLoading && peer.rowsByURL[output] == nil }
            try require(peer.lastOperationResult?.disposition == .succeeded && !FileManager().fileExists(atPath: output.path)
                && browser.clipboardState.scopedItem?.isAlive == true)
        }
        try require(window.makeFirstResponder(rows.table) && rows.table.validateMenuItem(copy))
        try UIVerification.require(rows.table.validateMenuItem(cut) == model.canModifySelectedMembers,
            "TAR Cut availability must follow its qualified member authoring")
        try require(NSApp.sendAction(copy.action!, to: rows.table, from: copy))
        try await wait { !model.isPreparingPreview && board.types == [ScopedItemClipboardIntent.pasteboardType] }
        try require(board.types == [ScopedItemClipboardIntent.pasteboardType])
        workspace.activate(peer)
        let earlier = peer.lastRecoveryRecordID
        try require(!peer.settings.alwaysReviewArchiveCopies && window.makeFirstResponder(peer.table) && peer.table.validateMenuItem(paste)
            && NSApp.sendAction(paste.action!, to: peer.table, from: paste))
        try await completeAndUndo(since: earlier)
        window.makeKeyAndOrderFront(nil); workspace.activate(browser)
        try await wait { !model.busy && model.current }
        guard let drag = rows.memberDragSource else { throw Failure.check(#line) }
        let dragBoard = NSPasteboard.withUniqueName()
        defer { drag.retire(); dragBoard.releaseGlobally() }
        let selected = model.selection
        func begin(_ sequence: Int) throws -> FixtureDraggingInfo {
            guard let writer = rows.tableView(rows.table, pasteboardWriterForRow: folder) else { throw Failure.check(#line) }
            dragBoard.clearContents(); try require(dragBoard.writeObjects([writer]))
            drag.begin(sequence: sequence, tarIDs: selected, board: dragBoard)
            return FixtureDraggingInfo(board: dragBoard, source: rows.table, sequence: sequence)
        }
        let stale = try begin(1)
        model.selection = []
        try require(ArchiveMemberDragSource.capture(stale) == nil)
        drag.end(sequence: 1); model.selection = selected
        let drop = try begin(2)
        guard let captured = ArchiveMemberDragSource.capture(drop) else {
            throw UIVerification.Failure(message: "TAR extraction capture refused at " + ArchiveMemberDragSource.lastCaptureReasonForVerification)
        }
        try require(captured.tarModel === model && captured.model == nil && captured.ids.isEmpty && captured.tarIDs == selected)
        try require((ArchiveMemberDragSource.capture(drop, for: .moveWithinArchive) != nil) == model.canMoveMembers(selected))
        workspace.activate(peer); peer.focusBrowserContent()
        peer.dragDrop.selectionDidChange()
        try await wait { peer.dragDrop.hasPreparedDestinationForVerification(destination) }
        let beforeDrop = peer.lastRecoveryRecordID
        try require(peer.dragDrop.validateDrop(drop, row: -1, operation: .on) == .copy
            && peer.dragDrop.acceptDrop(drop, row: -1, operation: .on)
            && !peer.dragDrop.acceptDrop(drop, row: -1, operation: .on))
        drag.end(sequence: 2)
        try await completeAndUndo(since: beforeDrop)
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        window.makeKeyAndOrderFront(nil); workspace.activate(peer)
        try require(workspace.closeActivePane() && workspace.activeBrowser === browser)
        browser.clipboardState.clear()
    }
    private static func verifyStandaloneClipboard(owner: BrowserWindowController, browser: BrowserViewController,
        source: URL, archiveWindow: NSWindow, clipboard: ArchiveWindowClipboard, table: ArchiveMetadataTable,
        ready: () -> Bool, cutAllowed: Bool, board: NSPasteboard, destination: URL) async throws {
        guard let window = owner.window, let engine = browser.recoverableFileOperations else { throw Failure.check(#line) }
        let workspace = owner.workspace
        let selection = table.selectedRowIndexes
        let archiveDigest = try await Task.detached { try SHA256.hash(data: Data(contentsOf: source)) }.value
        let previousBoard = browser.transferPasteboard
        browser.transferPasteboard = board
        defer { browser.transferPasteboard = previousBoard }
        try await Task.detached { try FileManager().createDirectory(at: destination, withIntermediateDirectories: false) }.value
        window.makeKeyAndOrderFront(nil); workspace.activate(browser)
        if window.frame.width < 1140 { window.setContentSize(.init(width: 1140, height: window.contentLayoutRect.height)) }
        try require(workspace.splitActive(at: .trailing))
        let peer = workspace.activeBrowser
        peer.permitsBackgroundVerification = true; peer.recoverableFileOperations = engine
        peer.navigate(to: .directory(destination))
        try await wait { !peer.isLoading && peer.orderingTask == nil }
        archiveWindow.makeKeyAndOrderFront(nil)
        try await wait { archiveWindow.isKeyWindow && ready() }
        try require(archiveWindow.makeFirstResponder(table))
        let copy = NSMenuItem(title: "Copy", action: #selector(FileTableView.copy(_:)), keyEquivalent: "c")
        let cut = NSMenuItem(title: "Cut", action: #selector(FileTableView.cut(_:)), keyEquivalent: "x")
        let paste = NSMenuItem(title: "Paste", action: #selector(FileTableView.paste(_:)), keyEquivalent: "v")
        guard let menu = table.contextMenuProvider?(), let contextCopy = menu.items.first(where: { $0.title == "Copy" }),
              let validator = contextCopy.target as? NSMenuItemValidation else { throw Failure.check(#line) }
        try require(validator.validateMenuItem(contextCopy) && table.validateMenuItem(copy)
            && table.validateMenuItem(cut) == cutAllowed)
        let savedProfile = browser.settings.keyboardProfile, savedKeys = browser.settings.shortcutPreferences
        let savedBehavior = browser.settings.customBehavior
        browser.settings.keyboardProfile = .mac; browser.settings.shortcutPreferences = .init()
        defer {
            browser.settings.customBehavior = savedBehavior
            browser.settings.keyboardProfile = savedProfile; browser.settings.shortcutPreferences = savedKeys
        }
        try require(archiveWindow.performKeyEquivalent(with: UIVerification.key("c", code: 8, flags: .command, window: archiveWindow)))
        try await wait { browser.clipboardState.scopedItem?.archiveWindowOwner === clipboard && ready() }
        try require(board.types == [ScopedItemClipboardIntent.pasteboardType] && browser.clipboardState.scopedItem?.isAlive == true)
        // A different selection does not silently replace the sealed copied IDs.
        table.deselectAll(nil)
        window.makeKeyAndOrderFront(nil); workspace.activate(peer); peer.focusBrowserContent()
        try await wait { window.isKeyWindow }
        try require(!table.routeStandaloneKeyEquivalent(UIVerification.key("c", code: 8, flags: .command, window: archiveWindow)))
        try require(peer.table.validateMenuItem(paste))
        let before = peer.lastRecoveryRecordID, output = destination.appendingPathComponent("Note.txt")
        NSApp.sendAction(paste.action!, to: peer.table, from: paste)
        try await wait { ApplicationArchiveExtraction.shared.canAcceptPreparedSelection && peer.lastRecoveryRecordID != before
            && peer.operationTask == nil && !peer.isLoading && peer.rowsByURL[output] != nil }
        try require(peer.lastOperationResult?.disposition == .succeeded)
        try require(try await Task.detached { try Data(contentsOf: output) == Data("note".utf8) }.value)
        try await wait { peer.canUndoFileOperation }
        peer.undoFileOperation(nil)
        try await wait { peer.operationTask == nil && !peer.isLoading && peer.rowsByURL[output] == nil }
        try require(peer.lastOperationResult?.disposition == .succeeded && browser.clipboardState.scopedItem?.isAlive == true)
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        workspace.activate(peer); try require(workspace.closeActivePane() && workspace.activeBrowser === browser)
        archiveWindow.makeKeyAndOrderFront(nil); try require(archiveWindow.makeFirstResponder(table))
        table.selectRowIndexes(selection, byExtendingSelection: false)
        try require(table.commandValidation?(#selector(BrowserViewController.renameSelection(_:))) == cutAllowed)
        let customKey = UIVerification.key(String(UnicodeScalar(NSF8FunctionKey)!), code: 100,
            flags: [.control, .option, .shift], window: archiveWindow)
        guard let chord = BrowserShortcut(customKey), !SystemShortcutSnapshot.shared.conflicts(customKey) else { throw Failure.check(#line) }
        browser.settings.customizeBehavior()
        for command in [BrowserCommand.newFolder, .newTextFile, .duplicate, .trash] {
            browser.settings.shortcutPreferences = .init(overrides: [command: [chord]])
            try require(browser.settings.shortcutMap.issues.isEmpty
                && archiveWindow.makeFirstResponder(table) && archiveWindow.performKeyEquivalent(with: customKey))
            try await wait { ApplicationArchiveCreation.shared.controller != nil }
            guard let review = ApplicationArchiveCreation.shared.controller else { throw Failure.check(#line) }
            switch command {
            case .newFolder: try require(review.model.isMemberNewFolder)
            case .newTextFile: try require(review.model.isMemberNewFile)
            case .duplicate: try require(review.model.isMemberDuplicate)
            case .trash: try require(review.model.isMemberRemoval)
            default: throw Failure.check(#line)
            }
            await ApplicationArchiveCreation.shared.closeAndDrain()
            try await wait { ready() }
            archiveWindow.makeKeyAndOrderFront(nil)
        }
        browser.settings.keyboardProfile = .mac; browser.settings.shortcutPreferences = .init()
        try require(archiveWindow.makeFirstResponder(table))
        table.deselectAll(nil)
        try require(table.commandValidation?(#selector(BrowserViewController.renameSelection(_:))) == false)
        let added = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + " Input.txt")
        try await Task.detached { try Data("added".utf8).write(to: added, options: .withoutOverwriting) }.value
        func localCopy() throws {
            browser.clipboardState.clear()
            try require(BrowserClipboard.write(nil, urls: [added], to: board) && table.validateMenuItem(paste))
        }
        try localCopy(); NSApp.sendAction(paste.action!, to: table, from: paste)
        try await wait { ApplicationArchiveCreation.shared.controller != nil }
        await ApplicationArchiveCreation.shared.closeAndDrain()
        try await wait { ready() }
        archiveWindow.makeKeyAndOrderFront(nil); try require(archiveWindow.makeFirstResponder(table))
        try localCopy(); NSApp.sendAction(paste.action!, to: table, from: paste)
        board.clearContents()
        try await wait { ready() }
        try require(ApplicationArchiveCreation.shared.controller == nil)
        let afterCancel = try await Task.detached { try SHA256.hash(data: Data(contentsOf: source)) }.value
        try require(afterCancel == archiveDigest)
        table.selectRowIndexes(selection, byExtendingSelection: false)
        try require(archiveWindow.performKeyEquivalent(with: UIVerification.key("c", code: 8, flags: .command, window: archiveWindow)))
        try await wait { browser.clipboardState.scopedItem?.archiveWindowOwner === clipboard && ready() }
    }
    private static func verifyInactivePaneClipboard(owner: BrowserWindowController, root: URL, board: NSPasteboard,
                                                   compressed: Bool) async throws {
        let workspace = owner.workspace
        guard let window = owner.window else { throw Failure.check(#line) }
        let logger = DiagnosticRecorder(directory: root.appendingPathComponent("state/inactive-paste-diagnostics"),
            limits: try .init(bytes: 64 << 10, segmentBytes: 8 << 10), recording: true)
        let previousRecorder = ApplicationDiagnostics.shared.recorder
        ApplicationDiagnostics.shared.configureForVerification(logger)
        defer { ApplicationDiagnostics.shared.configureForVerification(previousRecorder) }
        do {
        let cases: [(label: String, source: String)] = compressed
            ? [("gzip", "Review.tar.gz"), ("bzip2", "Review bzip2.tbz")]
            : [("zip", "Review.zip"), ("tar", "Review.tar")]
        for item in cases {
            var browser = workspace.activeBrowser
            guard let engine = browser.recoverableFileOperations else { throw Failure.check(#line) }
            let source = root.appendingPathComponent("source/" + item.source)
            let destination = root.appendingPathComponent("source/Inactive " + item.label, isDirectory: true)
            try await Task.detached { try FileManager().createDirectory(at: destination, withIntermediateDirectories: false) }.value
            window.makeKeyAndOrderFront(nil); workspace.activate(browser)
            browser.navigate(to: .directory(source.deletingLastPathComponent()))
            try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
            browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.openSelection(nil)
            if compressed && !CompressedArchiveOpenFeature.available {
                try await wait { browser.currentArchive?.tarModelForVerification?.requiresPreparation == true
                    && browser.currentArchive?.busy == false }
                browser.currentArchive?.tarModelForVerification?.prepareCompressed()
            }
            try await wait { browser.currentArchive?.current == true && browser.currentArchive?.busy == false
                && browser.currentArchive?.hasRenderedCurrentRowsForVerification == true }
            if item.label != "zip" {
                guard let archive = browser.currentArchive, let tar = archive.tarModelForVerification else { throw Failure.check(#line) }
                browser = try await verifyPendingOpenTransfer(owner: owner, browser: browser, archive: archive,
                    model: tar, destination: destination, compressed: compressed,
                    evidence: root.appendingPathComponent("evidence/pending-" + item.label + ".json"))
            }
            guard let archive = browser.currentArchive, let table = archive.table,
                  let note = archive.zipModelForVerification?.visibleItems.firstIndex(where: { $0.name == "Note.txt" })
                    ?? archive.tarModelForVerification?.items.firstIndex(where: { $0.name == "Note.txt" }) else { throw Failure.check(#line) }
            let tab = browser.activeID
            let preparations = ApplicationCompressedArchives.shared.preparationRequestsForVerification
            browser.transferPasteboard = board
            table.selectRowIndexes([note], byExtendingSelection: false)
            try require(window.makeFirstResponder(table))
            let copy = NSMenuItem(title: "Copy", action: #selector(FileTableView.copy(_:)), keyEquivalent: "c")
            try require(table.validateMenuItem(copy) && NSApp.sendAction(copy.action!, to: table, from: copy))
            try await wait { !archive.busy && browser.clipboardState.scopedItem?.archiveOwner === archive }
            guard let copied = browser.clipboardState.scopedItem?.id else { throw Failure.check(#line) }
            let local = BrowserTab(location: .directory(destination))
            browser.tabs.append(local); browser.selectTab(local.id)
            try await wait { !browser.isLoading && browser.orderingTask == nil && browser.location.directoryURL?.path == destination.path }
            try require(workspace.splitActive(at: .trailing))
            let survivor = workspace.activeBrowser
            try require(survivor.isLoading && !survivor.canModifyCurrentFolder)
            var beginFinished = false
            survivor.didFinishBeginForVerification = { beginFinished = true }
            survivor.permitsBackgroundVerification = true; survivor.recoverableFileOperations = engine
            survivor.folderAccess = browser.folderAccess; survivor.privateNames = browser.privateNames
            survivor.readVolumesForVerification = { [] }
            // Explicit navigation must supersede the still-queued begin task.
            survivor.navigate(to: .directory(destination))
            let explicitVisit = survivor.sessionID
            try await wait { beginFinished && !survivor.isLoading && survivor.orderingTask == nil }
            survivor.didFinishBeginForVerification = nil
            try require(survivor.sessionID == explicitVisit)
            workspace.activate(browser)
            try require(workspace.closeActivePane() && workspace.activeBrowser === survivor)
            try await wait { browser.isBrowserSuspended && !survivor.isLoading && survivor.orderingTask == nil && survivor.canvasTransition == nil }
            survivor.focusBrowserContent()
            try await wait { survivor.canPasteArchiveIntoLocalFolder }
            try require(survivor.archiveTabs[tab] === archive && !archive.isPresented
                && survivor.clipboardState.scopedItem?.id == copied && survivor.clipboardState.scopedItem?.isAlive == true)
            let receiptCurrent = ScopedItemPaste(state: survivor.clipboardState)?.isCurrent() == true
            try require(receiptCurrent && survivor.recoverableFileOperations === engine)
            try JSONSerialization.data(withJSONObject: ["targetReady": survivor.canPasteArchiveIntoLocalFolder,
                "exactEngine": survivor.recoverableFileOperations === engine, "receiptCurrent": receiptCurrent,
                "sourcePaneSuspended": browser.isBrowserSuspended, "ownerMoved": survivor.archiveTabs[tab] === archive,
                "sourceInactive": !archive.isPresented, "commandPaneFocused": survivor.hasFileCommandFocus,
                "startupFinished": beginFinished, "explicitVisitPreserved": survivor.sessionID == explicitVisit,
                "textEditorFocused": survivor.view.window?.firstResponder is NSTextView,
                "hasSheet": survivor.view.window?.attachedSheet != nil,
                "canPaste": survivor.canPasteScopedItem], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("evidence/inactive-" + item.label + "-clipboard.json"), options: .withoutOverwriting)
            try UIVerification.require(survivor.canPasteScopedItem,
                "An inactive copied " + item.label + " tab lost its live Paste owner after Close Pane")
            let paste = NSMenuItem(title: "Paste", action: #selector(FileTableView.paste(_:)), keyEquivalent: "v")
            let earlier = survivor.lastRecoveryRecordID, output = destination.appendingPathComponent("Note.txt")
            try require(survivor.table.validateMenuItem(paste) && NSApp.sendAction(paste.action!, to: survivor.table, from: paste))
            try JSONSerialization.data(withJSONObject: ["callbackInstalled": survivor.table.onPaste != nil,
                "sourcePreparationBegan": archive.busy,
                "pasteDestinationCaptured": survivor.status.stringValue == "Checking the archive and destination…",
                "canPasteAfterDispatch": survivor.canPasteScopedItem], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("evidence/inactive-" + item.label + "-dispatch.json"), options: .withoutOverwriting)
            do {
                try await wait { ApplicationArchiveExtraction.shared.canAcceptPreparedSelection && survivor.lastRecoveryRecordID != earlier
                    && survivor.operationTask == nil && !survivor.isLoading && survivor.rowsByURL[output] != nil }
            } catch {
                let sourceMatches: Bool
                switch survivor.clipboardState.scopedItem?.source {
                case .zip(let copied): sourceMatches = copied.archiveURL == archive.source
                case .tar(let copied): sourceMatches = copied.archiveURL == archive.source
                default: sourceMatches = false
                }
                let status = survivor.status.stringValue.replacingOccurrences(of: root.path, with: "<generated>")
                let notice = (archive.zipModelForVerification?.notice ?? archive.tarModelForVerification?.notice ?? "")
                    .replacingOccurrences(of: root.path, with: "<generated>")
                try JSONSerialization.data(withJSONObject: ["targetStatus": status, "sourceNotice": notice,
                    "sourceMatches": sourceMatches, "sourceBusy": archive.busy, "canPaste": survivor.canPasteScopedItem,
                    "receiptCurrent": ScopedItemPaste(state: survivor.clipboardState)?.isCurrent() == true,
                    "extractionReady": ApplicationArchiveExtraction.shared.canAcceptPreparedSelection,
                    "hasExtractionReview": ApplicationArchiveExtraction.shared.controller != nil,
                    "historyChanged": survivor.lastRecoveryRecordID != earlier], options: [.sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/inactive-" + item.label + "-terminal.json"), options: .withoutOverwriting)
                throw error
            }
            let exactBytes = try await Task.detached { try Data(contentsOf: output) == Data("note".utf8) }.value
            try require(survivor.lastOperationResult?.disposition == .succeeded && exactBytes)
            try await wait { survivor.canUndoFileOperation }
            survivor.undoFileOperation(nil)
            try await wait { survivor.operationTask == nil && !survivor.isLoading && survivor.rowsByURL[output] == nil }
            try require(survivor.lastOperationResult?.disposition == .succeeded)
            try require(ApplicationCompressedArchives.shared.preparationRequestsForVerification == preparations)
            await ApplicationArchiveExtraction.shared.closeAndDrain()
            survivor.clipboardState.clear(); survivor.closeTab(id: tab); await archive.closeAndDrain()
        }
        if compressed { try require(await ApplicationCompressedArchives.shared.closeAndDrain()) }
        } catch {
            _ = await logger.export(to: root.appendingPathComponent("evidence/inactive-paste-diagnostics.json"), retainingAccess: ())
            await logger.closeAndDrain()
            throw error
        }
        _ = await logger.export(to: root.appendingPathComponent("evidence/inactive-paste-diagnostics.json"), retainingAccess: ())
        await logger.closeAndDrain()
    }
    private static func verifyPendingOpenTransfer(owner: BrowserWindowController, browser: BrowserViewController,
        archive: ArchiveTabController, model: TARBrowserModel, destination: URL, compressed: Bool,
        evidence: URL) async throws -> BrowserViewController {
        let workspace = owner.workspace, tab = browser.activeID
        guard let engine = browser.recoverableFileOperations else { throw Failure.check(#line) }
        var entered = false, release: CheckedContinuation<Void, Never>?
        model.beforeOpenAccessForVerification = {
            entered = true
            await withCheckedContinuation { release = $0 }
        }
        defer { model.beforeOpenAccessForVerification = nil; release?.resume() }
        let preparations = ApplicationCompressedArchives.shared.preparationRequestsForVerification
        model.refresh()
        try await wait { entered }
        try require(model.busy && model.summary == nil)
        let local = BrowserTab(location: .directory(destination))
        browser.tabs.append(local); browser.selectTab(local.id)
        try await wait { !browser.isLoading && browser.orderingTask == nil }
        try require(workspace.splitActive(at: .trailing))
        let survivor = workspace.activeBrowser
        var began = false
        survivor.didFinishBeginForVerification = { began = true }
        survivor.permitsBackgroundVerification = true; survivor.recoverableFileOperations = engine
        survivor.folderAccess = browser.folderAccess; survivor.privateNames = browser.privateNames
        survivor.readVolumesForVerification = { [] }
        survivor.navigate(to: .directory(destination))
        try await wait { began && !survivor.isLoading && survivor.orderingTask == nil }
        survivor.didFinishBeginForVerification = nil
        workspace.activate(browser)
        try require(workspace.closeActivePane() && workspace.activeBrowser === survivor
            && survivor.archiveTabs[tab] === archive && browser.isBrowserSuspended && !archive.isPresented)
        release?.resume(); release = nil
        try await wait { !model.busy }
        try UIVerification.require(model.summary != nil,
            "A consumed TAR Open lost its pane owner while draining before access")
        let completedPreparations = ApplicationCompressedArchives.shared.preparationRequestsForVerification
        try require(completedPreparations == preparations + (compressed ? 1 : 0))
        survivor.selectTab(tab)
        try await wait { archive.current && !archive.busy && archive.hasRenderedCurrentRowsForVerification }
        try require(ApplicationCompressedArchives.shared.preparationRequestsForVerification == completedPreparations)
        try JSONSerialization.data(withJSONObject: ["consumedOpenTransferred": true,
            "summaryBeforeReselect": true, "preparationOnReselect": false], options: [.sortedKeys])
            .write(to: evidence, options: .withoutOverwriting)
        return survivor
    }
    private static func verifyArchiveNameSelection(_ surface: FileTableView, browser: BrowserViewController,
                                                  names: [String], extraName: String, embedded: Bool) async throws {
        guard let table = surface as? ArchiveMetadataTable, let window = table.window,
              let note = names.firstIndex(of: "Note.txt"), let extra = names.firstIndex(of: extraName) else {
            throw UIVerification.Failure(message: "Archive name selection fixture is incomplete")
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
        let previous = table.selectedRowIndexes
        defer { table.selectRowIndexes(previous, byExtendingSelection: false) }
        let originalMenu = NSApp.mainMenu
        if originalMenu?.item(withTitle: "Edit") == nil { NSApp.mainMenu = BrowserMenus.applicationMenu(target: browser) }
        defer { if NSApp.mainMenu !== originalMenu { NSApp.mainMenu = originalMenu } }
        guard let menu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu else {
            throw UIVerification.Failure(message: "The native Edit menu is unavailable")
        }
        let action = BrowserCommand.selectByName.selector
        func choose(_ text: String, mode: NameSelectionPrompt.Mode, expected: IndexSet) async throws {
            try await UIVerification.waitUntil("Archive selection command is available") { table.canSelectByName }
            BrowserShortcutMenus.refresh(menu, browser: browser)
            guard let item = BrowserMenus.commandItem(action, in: menu), let target = item.target as? NSMenuItemValidation,
                  (embedded ? target as AnyObject === browser : target as AnyObject === table), target.validateMenuItem(item),
                  NSApp.sendAction(action, to: target, from: item) else {
                throw UIVerification.Failure(message: "The archive's native Edit menu did not invoke Select by Name")
            }
            try await UIVerification.completeNameSelection(in: window, text: text, mode: mode)
            try await UIVerification.waitUntil("Archive name selection completed") { table.canSelectByName }
            try UIVerification.require(table.selectedRowIndexes == expected, "The archive selected different visible names")
        }
        try await choose("Note*.txt", mode: .replace, expected: IndexSet(integer: note))
        try await choose(extraName, mode: .add, expected: IndexSet([note, extra]))
    }

    private static func verifyEmbeddedShortcuts(browser: BrowserViewController, table: FileTableView) async throws {
        guard let owner = browser.currentArchive, let window = browser.view.window else { throw Failure.check(#line) }
        let settings = browser.settings
        let profile = settings.keyboardProfile, custom = settings.customBehavior
        let shortcuts = settings.shortcutPreferences, hidden = settings.showsHiddenFiles
        let selected = table.selectedRowIndexes, location = browser.location
        defer {
            settings.shortcutPreferences = .init(); settings.customBehavior = custom
            settings.shortcutPreferences = shortcuts; settings.keyboardProfile = profile
            settings.showsHiddenFiles = hidden
            table.selectRowIndexes(selected, byExtendingSelection: false)
        }
        settings.keyboardProfile = .explorer; settings.customizeBehavior()
        func send(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { throw Failure.check(#line) }
            guard let folder = owner.zipModelForVerification?.visibleItems.firstIndex(where: { $0.path == "Folder" && $0.folder != nil })
                ?? owner.tarModelForVerification?.items.firstIndex(where: { $0.path == "Folder" && $0.folder != nil }) else { throw Failure.check(#line) }
            table.selectRowIndexes(IndexSet(integer: folder), byExtendingSelection: false)
            let exactSelection: Bool
            if let zip = owner.zipModelForVerification { exactSelection = zip.selection == [zip.visibleItems[folder].id] }
            else if let tar = owner.tarModelForVerification { exactSelection = tar.selection == [tar.items[folder].id] }
            else { exactSelection = false }
            try UIVerification.require(exactSelection && owner.hasRenderedCurrentRowsForVerification,
                "Generated shortcut event lacks its exact current Folder selection")
            try require(window.makeFirstResponder(table))
            table.keyDown(with: event)
        }
        settings.shortcutPreferences = .init(overrides: [.open: [], .hiddenFiles: [.init(.special(.returnKey))]])
        try require(settings.shortcutMap.issues.isEmpty)
        try send("\r", code: 36)
        try UIVerification.require(settings.showsHiddenFiles != hidden && browser.location == location,
            "Archive Return ignored its remapped shared binding")
        try await wait { owner.current && !owner.busy && owner.hasRenderedCurrentRowsForVerification }

        let beforeFind = settings.showsHiddenFiles
        settings.shortcutPreferences = .init(overrides: [.filter: [], .hiddenFiles: [.init(.character("f"), .command)]])
        try require(settings.shortcutMap.issues.isEmpty)
        try send("f", code: 3, flags: .command)
        try UIVerification.require(settings.showsHiddenFiles != beforeFind && browser.filterField.currentEditor() == nil,
            "Archive Find ignored its remapped shared binding")
        try await wait { owner.current && !owner.busy && owner.hasRenderedCurrentRowsForVerification }

        settings.shortcutPreferences = .init(overrides: [.open: [], .filter: [], .quickLook: []])
        try send("\r", code: 36)
        try send("f", code: 3, flags: .command)
        try await Task.sleep(for: .milliseconds(40))
        try UIVerification.require(browser.location == location && browser.filterField.currentEditor() == nil,
            "Cleared archive Open or Find binding still dispatched")

        guard let preview = owner.zipModelForVerification?.textPreviewForVerification
                ?? owner.tarModelForVerification?.textPreviewForVerification,
              let note = owner.zipModelForVerification?.visibleItems.firstIndex(where: { $0.name == "Note.txt" })
                ?? owner.tarModelForVerification?.items.firstIndex(where: { $0.name == "Note.txt" }) else { throw Failure.check(#line) }
        table.selectRowIndexes(IndexSet(integer: note), byExtendingSelection: false)
        let space = UIVerification.key(" ", code: 49, flags: [], window: window)
        table.keyDown(with: space)
        try await Task.sleep(for: .milliseconds(40))
        try UIVerification.require(!preview.retainsPresentation && !browser.quickLook.isActive,
            "Cleared archive Preview binding still read a member")
        settings.shortcutPreferences = .init()
        try await wait { owner.current && !owner.busy && owner.hasRenderedCurrentRowsForVerification }
        guard let currentNote = owner.zipModelForVerification?.visibleItems.firstIndex(where: { $0.name == "Note.txt" })
                ?? owner.tarModelForVerification?.items.firstIndex(where: { $0.name == "Note.txt" }) else { throw Failure.check(#line) }
        table.selectRowIndexes(IndexSet(integer: currentNote), byExtendingSelection: false)
        try require(window.makeFirstResponder(table))
        try UIVerification.require(owner.canPreview && browser.commandEnabled(#selector(BrowserViewController.showQuickLook(_:)))
            && settings.shortcutMap.resolve(.init(.special(.space)), fileSurface: true) == .quickLook,
            "Archive text-Preview fixture lacks its exact selection or configured action")
        table.keyDown(with: space)
        try await wait { !preview.isReading && preview.windowForVerification != nil }
        try UIVerification.require(preview.textForVerification?.isEmpty == false && !browser.quickLook.isActive,
            "Archive Space did not use its bounded in-app preview")
        preview.windowForVerification?.performClose(nil)
        try await wait { !preview.retainsPresentation }
        await preview.drain()
    }

    private static func write(_ value:[String:Any],root:URL)throws{
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/native-tar-archive.json"),options:.withoutOverwriting)
    }
}
#endif
