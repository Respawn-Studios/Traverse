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
                else { window.center() }
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
                browser.navigate(to: .directory(source.deletingLastPathComponent()))
                try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
                show(main)
                checks.append("Current ZIP row Properties uses recorded compression and size; exact text Copy and empty-selection refusal do not open any content")
            }
            browser.setFileSelection([source]);browser.fileSelectionDidChange();try require(browser.selectedTARURL==source)
            if compressed {
                // Exercise the ordinary double-click/Open route as well as
                // explicit Browse (used for the damaged input below).
                browser.openSelection(nil)
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
                checks.append("Opening/restoration shows Prepare without decoding or creating cache; native Prepare command explicitly admits the bounded body operation")
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
            let clipboardHistoryCount = compressed || inline ? 2 : 0
            if clipboardHistoryCount > 0 {
                try await verifyFolderPaste(owner: controller, browser: browser, model: model, rows: rows,
                    board: board, destination: location.appendingPathComponent("source/Paste Destination", isDirectory: true))
                checks.append("TAR Copy/Paste and shared native row-drop callbacks each copy a folder directly with nested text/empty child and ordinary Undo; stale selection, ZIP Move and duplicate-drop admission refuse")
            }
            if compressed || inline {
                let previousItems = model.items.map(\.id)
                browser.navigate(to: .directory(source.deletingLastPathComponent()))
                try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
                try await Task.detached {
                    let bytes = try Data(contentsOf: source)
                    try bytes.write(to: source, options: .atomic)
                }.value
                browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.openSelection(nil)
                if compressed {
                    try await wait { browser.currentArchive?.tarModelForVerification?.requiresPreparation == true
                        && browser.currentArchive?.tarModelForVerification?.busy == false }
                    guard let reopened = browser.currentArchive?.tarModelForVerification else { throw Failure.check(#line) }
                    try require(!reopened.current && reopened.summary == nil)
                    reopened.prepareCompressed()
                }
                try await wait { model.current && !model.busy && model.items.map(\.id) != previousItems }
                try require(model.items.map(\.name) == ["Folder", "Note.txt"])
                checks.append("A replaced source invalidates retained rows on ordinary reopen; compressed TAR returns to explicit Prepare before a new catalog")
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
            model.openSelection()
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
            checks.append("Ordinary file Open and Text/Hex commands show exact read-only member bytes through one preview owner, then close and drain")
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
            try require(history.records.count == clipboardHistoryCount + 1 && history.records.allSatisfy { $0.operation == "Extract TAR" })
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
        try require(window.makeFirstResponder(rows.table) && rows.table.validateMenuItem(copy) && !rows.table.validateMenuItem(cut)
            && NSApp.sendAction(copy.action!, to: rows.table, from: copy))
        try require(board.types == [ScopedItemClipboardIntent.pasteboardType] && !rows.table.validateMenuItem(paste))
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
        try require(ArchiveMemberDragSource.capture(drop) != nil
            && ArchiveMemberDragSource.capture(drop, for: .moveWithinArchive) == nil)
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
    private static func write(_ value:[String:Any],root:URL)throws{
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/native-tar-archive.json"),options:.withoutOverwriting)
    }
}
#endif
