#if DEBUG
import AppKit
import CryptoKit
import Darwin
import ExplorerCore
import FileOperations
import LocalStorage

@MainActor enum ArchiveMemberDragVerification {
    @MainActor private final class Hold {
        var entered = false, released = false
        private var continuation: CheckedContinuation<Void,Never>?
        func pause() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    @MainActor private final class Info: NSObject,NSDraggingInfo {
        let board: NSPasteboard, draggingSource: Any?, draggingSequenceNumber: Int, draggingSourceOperationMask: NSDragOperation
        var onRead: (() -> Void)?
        var draggingPasteboard: NSPasteboard { onRead?(); return board }
        var draggingDestinationWindow: NSWindow?
        var draggingLocation: NSPoint = .zero
        var draggedImageLocation: NSPoint { .zero }
        nonisolated var draggedImage: NSImage? { nil }
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 0
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        init(_ board: NSPasteboard,source: Any?,sequence: Int,allowed: NSDragOperation = .copy) {
            self.board = board; draggingSource = source; draggingSequenceNumber = sequence; draggingSourceOperationMask = allowed
        }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,for view: NSView?,classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey:Any],using block: @escaping (NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void) {}
    }
    private final class LeaseCounter: FolderAccessBackend,@unchecked Sendable {
        private let lock = NSLock(); private var started = 0, stopped = 0
        var active: Int { lock.withLock { started-stopped } }
        var totals: [Int] { lock.withLock { [started,stopped] } }
        func startAccess(to url: URL) -> Bool { lock.withLock { started += 1 }; return true }
        func stopAccess(to url: URL) { lock.withLock { stopped += 1 } }
        func bookmark(for url: URL) throws -> Data { throw CancellationError() }
        func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { throw CancellationError() }
    }
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let arguments = ProcessInfo.processInfo.arguments
        guard root.resolvingSymlinksInPath() == root, UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let marker = try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String:Any],
              (root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release") && marker["action"] as? String == "traverse-archive-member-drag") ||
                (root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development") &&
                 marker["packet"] as? String == "traverse-development-v1" &&
                 ((marker["action"] as? String == "archive-human-gesture-review" && arguments.contains("--human-gesture-review") && arguments.contains("--gesture-review")) ||
                  (["archive-native-regression", "archive-promise-internal-regression"].contains(marker["action"] as? String ?? "") && arguments.contains("--offscreen") && !arguments.contains("--gesture-review")))) else { exit(2) }
        if arguments.contains("--qualify-external-promises") { ArchivePromiseExportFeature.qualifying = true }
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
        settings.showsDockProgress = false; settings.motion.mode = .off; settings.appearance = .dark
        settings.navigationStyle = .glass; settings.glassFileContent = true
        let owner = BrowserWindowController(settings: settings)
        var checks: [String] = [], failures: [String] = [], metrics: [String:Any] = [:]
        let heartbeat = Heartbeat()
        let ticker = Timer(timeInterval:0.016,repeats:true) { _ in MainActor.assumeIsolated { heartbeat.tick() } }
        RunLoop.main.add(ticker,forMode:.common)
        do { try await verify(root: root,owner: owner,settings: settings,checks: &checks,metrics: &metrics) }
        catch { failures.append(String(describing: error)) }
        await ApplicationArchiveExports.shared.closeAndDrain()
        await ApplicationArchiveExtraction.shared.closeAndDrain(); await ApplicationZIPBrowser.shared.stopAndDrain()
        owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
        ticker.invalidate()
        ArchivePromiseExportFeature.qualifying = false
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        if usage.ru_maxrss > 256*1024*1024 { failures.append("Native memory gate failed") }
        if heartbeat.gap > 0.4 || heartbeat.ticks < 10 { failures.append("Native responsiveness gate failed") }
        if ApplicationFileActivity.gate.activeCount != 0 { failures.append("Actual filesystem work remains") }
        try? JSONSerialization.data(withJSONObject: ["passed":failures.isEmpty,"checks":checks,"failures":failures,"metrics":metrics,
            "maximumMainActorGapSeconds":heartbeat.gap,"ticks":heartbeat.ticks,"samplingIncludesNativeTracking":true,"peakRSSBytes":usage.ru_maxrss,"activityCount":ApplicationFileActivity.gate.activeCount,
            "generatedOnly":true,"network":0,"personalArchives":0,"nativeCallbacksNotPhysicalGesture":!arguments.contains("--gesture-review")],options:[.prettyPrinted,.sortedKeys])
            .write(to: root.appendingPathComponent("result.json"),options:.withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root: URL,owner: BrowserWindowController,settings: BrowserSettings,
        checks: inout [String],metrics: inout [String:Any]) async throws {
        try UIVerification.require(owner.isWorkspacePresentation,"Archive drag requires actual workspace")
        guard let window = owner.window else { throw UIVerification.Failure(message:"Workspace window missing") }
        window.setFrame(.init(x:100,y:130,width:1140,height:760),display:true)
        window.title = "Archive destinations · generated review"
        if ProcessInfo.processInfo.arguments.contains("--offscreen") { window.setFrameOrigin(.init(x:-12000,y:-12000)) }
        let source = root.appendingPathComponent("source/Source/Generated.zip"), destination = root.appendingPathComponent("source/Destination")
        let originalDestinationNames = Set(try FileManager().contentsOfDirectory(atPath:destination.path))
        let alternative = root.appendingPathComponent("source/Alternative"), workspace = owner.workspace, origin = owner.browser
        let engine = origin.operationCoordinator.engine(at:root.appendingPathComponent("state/history"))
        origin.permitsBackgroundVerification = true; origin.operationErrorPresenter = {_ in}; origin.operationResultPresenter = {_ in}
        origin.recoverableFileOperations = engine
        let sourceLeases = LeaseCounter(), targetLeases = LeaseCounter()
        origin.folderAccess = FolderAccessController(backend:sourceLeases)
        let sourceChoice = await origin.folderAccess.acceptChosenFolder(source.deletingLastPathComponent()); sourceChoice?.lease.close()
        owner.beginBrowsing(); try await wait("workspace") { workspace.sessionReady }
        origin.navigate(to:.directory(source.deletingLastPathComponent())); try await wait("source listing") { settled(origin) }
        try UIVerification.require(workspace.splitActive(at:.trailing),"Destination pane missing")
        let peer = workspace.activeBrowser
        peer.permitsBackgroundVerification = true; peer.operationErrorPresenter = {_ in}; peer.operationResultPresenter = {_ in}
        peer.recoverableFileOperations = engine; peer.dragDrop.permitsVerification = true
        peer.folderAccess = FolderAccessController(backend:targetLeases)
        let targetChoice = await peer.folderAccess.acceptChosenFolder(destination); targetChoice?.lease.close()
        peer.navigate(to:.directory(destination)); try await wait("destination listing") { settled(peer) }
        workspace.activate(peer); peer.focusBrowserContent(); peer.dragDrop.selectionDidChange()
        try await wait("prepared destination") { peer.dragDrop.hasPreparedDestinationForVerification(destination) }
        ApplicationZIPBrowser.shared.show(source,from:origin)
        guard let archive = ApplicationZIPBrowser.shared.controller, let archiveWindow = archive.window else { throw UIVerification.Failure(message:"Archive window missing") }
        let model = archive.model
        archiveWindow.title = "Archive members · generated review"
        if ProcessInfo.processInfo.arguments.contains("--offscreen") { archiveWindow.setFrameOrigin(.init(x:-12000,y:-12000)) }
        try await wait("archive metadata") { !model.isLoading && !model.isPaging && model.viewIsCurrent && model.rowsForVerification != nil }
        guard let rows = model.rowsForVerification, let drag = rows.memberDragSource else { throw UIVerification.Failure(message:"Actual native archive source missing") }
        try UIVerification.require(rows.responds(to:#selector(NSTableViewDataSource.tableView(_:pasteboardWriterForRow:))),"Native source callback is not exposed")
        let board = NSPasteboard(name:.init("Traverse.ArchiveDrag.Generated."+UUID().uuidString))
        defer { drag.retire(); board.releaseGlobally() }
        var sequence = 200
        func select(_ ids: Set<ZIPItemID>) async throws {
            model.selection = ids
            try await wait("native archive selection") { rows.selectedIDs == ids }
        }
        func offer(_ ids: Set<ZIPItemID>) async throws -> Info {
            // These synthetic gestures have no external consumer. End the
            // preceding unconsumed gesture as cancelled before a fresh source.
            drag.end(sequence: sequence, operation: [])
            try await select(ids); board.clearContents()
            if ArchivePromiseExportFeature.available && ids.count <= 128 && model.canExtractSelection(ids) {
                try await wait("prepared native promise metadata") { model.externalExportReady }
            }
            var writers: [any NSPasteboardWriting] = []
            for row in rows.table.selectedRowIndexes {
                guard let writer = rows.tableView(rows.table,pasteboardWriterForRow:row) else { throw UIVerification.Failure(message:"Actual archive row did not offer drag metadata") }
                writers.append(writer)
            }
            try UIVerification.require(board.writeObjects(writers),"Private generated pasteboard write failed")
            sequence += 1; drag.begin(sequence:sequence,ids:ids,board:board)
            return Info(board,source:rows.table,sequence:sequence)
        }
        func accept(_ info: Info) -> Bool { peer.dragDrop.acceptDrop(info,row:-1,operation:.on) }
        func review() async throws -> ArchiveExtractionWindowController {
            try await wait("actual extraction review") { ApplicationArchiveExtraction.shared.controller != nil && !model.isPreparingSelection }
            guard let panel = ApplicationArchiveExtraction.shared.controller else { throw UIVerification.Failure(message:"Extraction owner missing") }
            try await wait("actual extraction preview") { !panel.model.isPreparing && panel.model.notice != "Checking the archive and destination…" }
            try UIVerification.require(panel.model.plan != nil, "Actual archive preview refused: \(panel.model.notice)")
            return panel
        }
        func readyDestination() async throws {
            try await wait("current destination listing") { settled(peer) }
            peer.focusBrowserContent(); peer.dragDrop.selectionDidChange()
            try await wait("current destination ownership and observation") {
                peer.canStartArchiveExtraction && peer.dragDrop.hasPreparedDestinationForVerification(destination)
            }
        }
        model.nameScope = .archive; model.filter = "Item"; model.applyFilter()
        try await wait("bounded selection metadata") { !model.isPaging && model.viewIsCurrent && model.visibleItems.count == 130 }
        let maximum = Set(model.visibleItems.prefix(128).map(\.id)), tooMany = Set(model.visibleItems.prefix(129).map(\.id))
        try await select(tooMany)
        try UIVerification.require(drag.writer(ids:tooMany) == nil && model.captureMemberDrag(tooMany) == nil,"Oversized selection was silently truncated")
        let full = try await offer(maximum)
        try UIVerification.require(ArchiveMemberDragSource.capture(full)?.ids.count == 128,"128-item boundary cannot negotiate")
        let written = board.pasteboardItems ?? []
        try UIVerification.require(written.count == 128 && written.allSatisfy({
            $0.types.contains(ArchiveMemberDragSource.pasteboardType)
                && (ArchivePromiseExportFeature.available || $0.types == [ArchiveMemberDragSource.pasteboardType])
                && $0.string(forType:ArchiveMemberDragSource.pasteboardType).flatMap(UUID.init(uuidString:)) != nil
        }),"Native writer serialized something other than bounded opaque markers")
        drag.end(sequence:full.draggingSequenceNumber-1)
        try UIVerification.require(ArchiveMemberDragSource.capture(full) != nil,"A late older end invalidated the new source")
        drag.end(sequence:full.draggingSequenceNumber, operation: [])
        try UIVerification.require(ArchiveMemberDragSource.capture(full) == nil,"Ended source retained authority")
        checks.append("Actual native writer retains bounded opaque private markers alongside qualified native promise flavors;128 selected roots negotiate,129 refuse, and sequence/end checks are exact")

        model.filter = "Report.txt"; model.applyFilter()
        try await wait("global duplicate-basename matches") { !model.isPaging && model.viewIsCurrent && model.visibleItems.count == 2 }
        let ids = Set(model.visibleItems.map(\.id))
        if ProcessInfo.processInfo.arguments.contains("--drag-hit-test-control") {
            try await select(ids); rows.table.layoutSubtreeIfNeeded()
            let indexes = rows.table.selectedRowIndexes, rect = rows.table.rect(ofRow:try required(indexes.first,"Selected row missing"))
            metrics["publicDragHitTests"] = [10.0,35,65,110,200].map { x in
                ["x":x,"y":rect.midY,"allowed":rows.table.canDragRows(with:indexes,at:.init(x:x,y:rect.midY))] as [String:Any]
            }
            metrics["nativeSourceConfiguration"] = ["enabled":rows.table.isEnabled,"verticalDrag":rows.table.verticalMotionCanBeginDrag,
                "selected":indexes.count,"rowHeight":rows.table.rowHeight,"dataSourceWriter":rows.responds(to:#selector(NSTableViewDataSource.tableView(_:pasteboardWriterForRow:)))]
            checks.append("Public native row-drag hit regions characterized without a pointer or file write")
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--gesture-review") {
            try await select(ids)
            try await gesture(root:root,owner:owner,archiveWindow:archiveWindow,model:model,rows:rows,peer:peer,destination:destination,
                checks:&checks,metrics:&metrics)
            return
        }
        let current = try await offer(ids)
        try UIVerification.require(ArchiveMemberDragSource.capture(current) != nil,"Current source is unavailable")
        try UIVerification.require(ArchiveMemberDragSource.capture(Info(board,source:nil,sequence:sequence)) == nil
            && ArchiveMemberDragSource.capture(Info(board,source:rows.table,sequence:sequence+1)) == nil
            && ArchiveMemberDragSource.capture(Info(board,source:rows.table,sequence:sequence,allowed:.move)) == nil,"A forged/external/move marker authorized extraction")
        let firstToken = board.pasteboardItems?.first?.string(forType:ArchiveMemberDragSource.pasteboardType)
        board.setString(firstToken ?? "",forType:.string)
        try UIVerification.require(ArchiveMemberDragSource.capture(current) == nil,"Changed pasteboard revision retained authority")
        let stale = try await offer(ids)
        try await select([try required(model.visibleItems.first?.id,"First member missing")])
        try UIVerification.require(ArchiveMemberDragSource.capture(stale) == nil,"Changed selection retained old authority")
        checks.append("External/copied markers, wrong sequence, move-only masks, changed pasteboard and changed selection cannot authorize a drop")

        let cancel = try await offer(ids)
        try UIVerification.require(peer.dragDrop.validateDrop(cancel,row:-1,operation:.on) == .copy && accept(cancel),"Current destination did not admit review")
        try UIVerification.require(!accept(cancel),"Repeated native callback admitted the same drop twice")
        let cancelled = try await review()
        try UIVerification.require(cancelled.model.parent == destination && cancelled.model.summary?.files == 2
            && sourceLeases.active > 0 && targetLeases.active > 0,"Review lost selected roots, destination or source/target access")
        let waiting = try await offer(ids)
        cancelled.model.name = "Keep this review"
        try UIVerification.require(!accept(waiting) && ApplicationArchiveExtraction.shared.controller === cancelled
            && cancelled.model.name == "Keep this review","A drop replaced an existing review")
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        try UIVerification.require(try Set(FileManager().contentsOfDirectory(atPath:destination.path)) == originalDestinationNames,"Cancel changed the destination listing")
        checks.append("Native drop admits one existing selected-extraction review, retains both real access owners, refuses duplicate/busy replacement and Cancel creates no output")

        let extract = try await offer(ids)
        try UIVerification.require(accept(extract),"Confirmed extraction drop did not admit")
        let panel = try await review(), chosen = try required(panel.model.plan,"Prepared extraction missing").destination
        peer.navigate(to:.directory(alternative)); try await wait("navigation after review ownership") { settled(peer) }
        try UIVerification.require(panel.model.parent == destination && panel.model.plan?.destination == chosen && targetLeases.active > 0,
            "Navigation redirected the owned review or released its destination access")
        panel.model.extract(); try await wait("actual selected extraction") { !panel.model.isRunning && panel.model.outcome != nil }
        try UIVerification.require(panel.model.outcome?.result.disposition == .succeeded,"Selected extraction failed")
        let extracted = try await Task.detached { () throws -> [String:String] in
            var values: [String:String] = [:]
            for name in ["Group A/Report.txt","Group B/Report.txt"] {
                values[name] = SHA256.hash(data:try Data(contentsOf:chosen.appendingPathComponent(name))).map { String(format:"%02x",$0) }.joined()
            }
            return values
        }.value
        metrics["extractedHashes"] = extracted
        try UIVerification.require(extracted.count == 2 && Set(extracted.values).count == 2,"Duplicate basenames lost distinct payloads")
        panel.model.undo(); try await wait("exact archive Undo") { !panel.model.isRunning && panel.model.undoOutcome != nil }
        try UIVerification.require(panel.model.undoOutcome?.result.disposition == .succeeded && !FileManager().fileExists(atPath:chosen.path),"Exact selected extraction Undo failed")
        let operation = try required(panel.model.outcome?.recordID,"Exact extraction history missing")
        let retained = try await engine.retentionRecord(recordID:operation)
        try UIVerification.require(retained.areas.count == 1
            && retained.areas[0].url.deletingLastPathComponent().path.utf8.elementsEqual(destination.path.utf8),
            "Undo retained only its exact destination-owned area")
        if ArchiveExtractionActivation.qualifiesPublicZIPTree {
            try UIVerification.require(!retained.canCleanup && !retained.areas[0].verified
                && retained.protectionReason == "This produced tree retains its private recovery area until cleanup is separately qualified.",
                "The v16 recovery area stays protected from unqualified cleanup")
        } else {
            try UIVerification.require(retained.canCleanup && retained.areas[0].verified, "Legacy Undo retention did not verify")
        }
        metrics["retainedCleanupHeld"] = !retained.canCleanup
        metrics["retainedUndoArea"] = retained.areas[0].url.lastPathComponent
        metrics["retainedUndoOperation"] = operation.uuidString
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        checks.append("Archive-wide duplicate basenames retain both recorded paths and independent bytes through the ordinary verified extraction and exact Undo")
        try await wait("review-owned destination access released") { targetLeases.active == 0 }
        peer.navigate(to:.directory(destination))
        try await readyDestination()

        let folder = destination.appendingPathComponent("Existing Folder")
        guard let folderRow = peer.displayedEntries.firstIndex(where:{$0.url == folder}) else { throw UIVerification.Failure(message:"Existing folder row missing") }
        let rowDrop = try await offer(ids)
        try UIVerification.require(peer.tableView(peer.table,validateDrop:rowDrop,proposedRow:folderRow,proposedDropOperation:.on) == .copy
            && peer.tableView(peer.table,acceptDrop:rowDrop,row:folderRow,dropOperation:.on),"Native folder-row destination refused")
        let rowReview = try await review()
        try UIVerification.require(rowReview.model.parent == folder,"Native folder row selected the current folder instead")
        await ApplicationArchiveExtraction.shared.closeAndDrain()

        peer.setPaneViewMode(.icons); try await wait("native icon destination") { peer.activeFileView === peer.iconBrowser.collectionView }
        peer.dragDrop.selectionDidChange()
        try await wait("icon folder observation") { peer.dragDrop.hasPreparedDestinationForVerification(folder) }
        peer.view.layoutSubtreeIfNeeded(); peer.iconBrowser.layoutSubtreeIfNeeded(); peer.iconBrowser.collectionView.layoutSubtreeIfNeeded()
        guard let icon = peer.iconBrowser.visibleItems.first(where:{$0.entry?.url == folder}) else { throw UIVerification.Failure(message:"Native destination icon missing") }
        let iconDrop = try await offer(ids), collection = peer.iconBrowser.collectionView
        iconDrop.draggingDestinationWindow = peer.view.window
        iconDrop.draggingLocation = icon.view.convert(.init(x:icon.view.bounds.midX,y:icon.view.bounds.midY),to:nil)
        try UIVerification.require(collection.draggingEntered(iconDrop) == .copy && collection.prepareForDragOperation(iconDrop)
            && collection.performDragOperation(iconDrop),"Actual native icon callback refused archive members")
        let iconReview = try await review()
        try UIVerification.require(iconReview.model.parent == folder,"Icon drop retargeted extraction")
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        peer.setPaneViewMode(.list); try await readyDestination()
        let listDrop = try await offer(ids)
        try UIVerification.require(peer.tableView(peer.table,validateDrop:listDrop,proposedRow:-1,proposedDropOperation:.on) == .copy
            && peer.tableView(peer.table,acceptDrop:listDrop,row:-1,dropOperation:.on),"Native List destination refused")
        _ = try await review(); await ApplicationArchiveExtraction.shared.closeAndDrain()
        peer.setPaneViewMode(.details); try await readyDestination()

        let oldRoots = peer.sidebarRoots, node = SidebarNode("Generated archive destination",location:.directory(alternative),children:[])
        let group = SidebarNode("Generated destinations",group:true,children:[node])
        peer.sidebarRoots = [group]; peer.outline.reloadData(); peer.outline.expandItem(group); peer.view.layoutSubtreeIfNeeded()
        peer.dragDrop.destinationsChanged()
        let sidebarDrop = try await offer(ids)
        _ = peer.outlineView(peer.outline,validateDrop:sidebarDrop,proposedItem:node,proposedChildIndex:NSOutlineViewDropOnItemIndex)
        try await wait("hovered sidebar directory observation") { peer.dragDrop.hasPreparedDestinationForVerification(alternative) }
        try UIVerification.require(peer.outlineView(peer.outline,validateDrop:sidebarDrop,proposedItem:node,proposedChildIndex:NSOutlineViewDropOnItemIndex) == .copy
            && peer.outlineView(peer.outline,acceptDrop:sidebarDrop,item:node,childIndex:NSOutlineViewDropOnItemIndex),"Actual sidebar destination refused")
        let sidebarReview = try await review()
        try UIVerification.require(sidebarReview.model.parent == alternative,"Sidebar destination retargeted extraction")
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        peer.sidebarRoots = oldRoots; peer.outline.reloadData(); peer.dragDrop.destinationsChanged()
        let oldVolumes = peer.volumes
        peer.navigate(to:.computer); try await wait("generated drive overview") { settled(peer) }
        peer.volumes = [.init(url:destination,name:"Generated Drive",kind:.externalDisk,isReadOnly:false),
            .init(url:alternative,name:"Generated Read Only",kind:.externalDisk,isReadOnly:true)]
        peer.renderVolumes(); peer.view.layoutSubtreeIfNeeded(); peer.volumeBrowser.layoutSubtreeIfNeeded()
        peer.volumeBrowser.collectionView.layoutSubtreeIfNeeded(); peer.dragDrop.destinationsChanged()
        try UIVerification.require(!peer.dragDrop.navigationCandidatesForVerification.contains(alternative),"Known read-only drive became writable")
        guard let tile = peer.volumeBrowser.visibleTiles.first(where:{$0.volume?.url == destination}) else { throw UIVerification.Failure(message:"Generated drive tile missing") }
        let driveDrop = try await offer(ids), drives = peer.volumeBrowser.collectionView
        driveDrop.draggingLocation = tile.view.convert(.init(x:tile.view.bounds.midX,y:tile.view.bounds.midY),to:nil)
        _ = drives.draggingEntered(driveDrop)
        try await wait("hovered drive observation") { peer.dragDrop.hasPreparedDestinationForVerification(destination) }
        try UIVerification.require(drives.draggingUpdated(driveDrop) == .copy && drives.performDragOperation(driveDrop),"Actual drive tile callback refused")
        let driveReview = try await review()
        try UIVerification.require(driveReview.model.parent == destination,"Drive tile retargeted extraction")
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        peer.volumes = oldVolumes; peer.navigate(to:.directory(destination)); try await readyDestination()
        checks.append("Actual folder-row, Icons, List, sidebar and generated drive-tile callbacks retain the chosen directory; known read-only drive refuses, and cancelled reviews leave files unchanged")

        let hold = Hold(); defer { hold.release() }
        model.beforeSelectionForVerification = { await hold.pause() }
        let moving = try await offer(ids)
        try UIVerification.require(accept(moving),"Held destination capture did not admit")
        try await wait("held metadata selection") { hold.entered }
        peer.navigate(to:.directory(alternative)); try await wait("new target visit") { settled(peer) }
        hold.release(); await model.drain(); model.beforeSelectionForVerification = nil
        try UIVerification.require(ApplicationArchiveExtraction.shared.controller == nil,"A changed destination visit received a late review")
        peer.navigate(to:.directory(destination)); try await readyDestination()
        checks.append("An admitted metadata handoff rechecks the receiving tab/visit and cannot redirect extraction after destination navigation")

        if ProcessInfo.processInfo.arguments.contains("--record-motion") {
            for mode in BrowserMotionMode.allCases {
                settings.motion.mode = mode
                let info = try await offer(ids); try UIVerification.require(accept(info),"Recorded drop did not admit")
                let recorded = try await review()
                guard let reviewWindow = recorded.window else { throw UIVerification.Failure(message:"Recorded review window missing") }
                reviewWindow.title = "Archive drag · generated review"; reviewWindow.setFrameOrigin(.init(x:100,y:130))
                reviewWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
                let report = try await NativeMotionRecorder.record(window:reviewWindow,root:root,label:"archive-drag-"+mode.rawValue) {
                    recorded.model.name = "Generated Selected Review"
                }
                try JSONEncoder().encode(report).write(to:root.appendingPathComponent("evidence/archive-drag-"+mode.rawValue+".json"),options:.withoutOverwriting)
                if mode == .full { try await GlassVerification.captureOwnedWindow(reviewWindow,to:root.appendingPathComponent("evidence/archive-drag.png")) }
                await ApplicationArchiveExtraction.shared.closeAndDrain()
            }
        }
        let closeHold = Hold(); defer { closeHold.release() }
        model.beforeSelectionForVerification = { await closeHold.pause() }
        let closing = try await offer(ids); try UIVerification.require(accept(closing),"Closing source handoff missing")
        try await wait("held closing source") { closeHold.entered }
        var closed = false
        let close = Task { await ApplicationZIPBrowser.shared.stopAndDrain(); closed = true }
        try await Task.sleep(for:.milliseconds(40))
        try UIVerification.require(!closed,"Source close returned before actual metadata preparation drained")
        closeHold.release(); await close.value
        try UIVerification.require(ApplicationArchiveExtraction.shared.controller == nil && ArchiveMemberDragSource.capture(closing) == nil,"Closed source published a late extraction review")
        checks.append("Closing an actual source waits for its held metadata preparation, invalidates its drag and produces no late review")
        ApplicationZIPBrowser.shared.show(root.appendingPathComponent("source/Source/Unsupported.zip"),from:origin)
        guard let unsupported = ApplicationZIPBrowser.shared.controller else { throw UIVerification.Failure(message:"Unsupported metadata review missing") }
        try await wait("unsupported member metadata") { !unsupported.model.isLoading && unsupported.model.viewIsCurrent && unsupported.model.visibleItems.count == 1 }
        let unsupportedIDs = Set(unsupported.model.visibleItems.map(\.id)); unsupported.model.selection = unsupportedIDs
        try UIVerification.require(unsupported.model.visibleItems[0].method == 12 && unsupported.model.captureMemberDrag(unsupportedIDs) == nil,
            "Known unsupported codec advertised an extractable drag")
        await ApplicationZIPBrowser.shared.stopAndDrain()
        checks.append("A known unsupported ZIP codec remains metadata-only and offers no drag authority")
        origin.dragDrop.windowWillClose(); peer.dragDrop.windowWillClose()
        metrics["liveBrowserSourceAccessStartsStops"] = sourceLeases.totals
        metrics["liveBrowserTargetAccessStartsStops"] = targetLeases.totals
        owner.suspendBrowsing(); await owner.flushSession()
        try await wait("actual source and destination access drain") { sourceLeases.active == 0 && targetLeases.active == 0 }
        metrics["sourceAccessStartsStops"] = sourceLeases.totals; metrics["targetAccessStartsStops"] = targetLeases.totals
    }
    private static func settled(_ browser: BrowserViewController) -> Bool { !browser.isLoading && browser.orderingTask == nil }
    @MainActor private final class Heartbeat {
        var ticks = 0, gap = 0.0
        private var previous = CACurrentMediaTime()
        func tick() { let now = CACurrentMediaTime(); gap = max(gap,now-previous); previous = now; ticks += 1 }
    }
    private static func gesture(root: URL,owner: BrowserWindowController,archiveWindow: NSWindow,model: ArchiveBrowserModel,
        rows: ArchiveMetadataRows,peer: BrowserViewController,destination: URL,checks: inout [String],metrics: inout [String:Any]) async throws {
        guard let screen = NSScreen.main, let main = owner.window else { throw UIVerification.Failure(message:"Native gesture screen unavailable") }
        let bounds = screen.visibleFrame
        main.setFrame(.init(x:max(bounds.minX,bounds.maxX-1160),y:bounds.minY+20,width:1140,height:760),display:true)
        main.makeKeyAndOrderFront(nil)
        archiveWindow.setFrame(.init(x:bounds.minX+20,y:bounds.maxY-560,width:760,height:540),display:true)
        archiveWindow.title = "Archive drag gesture · generated review"
        archiveWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); archiveWindow.makeFirstResponder(rows.table)
        main.contentView?.layoutSubtreeIfNeeded(); archiveWindow.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(150))
        ArchiveMemberDragSource.resetDiagnosticsForVerification()
        guard let first = rows.table.selectedRowIndexes.first else { throw UIVerification.Failure(message:"Native gesture selection missing") }
        let rect = rows.table.rect(ofRow:first)
        let from = archiveWindow.convertPoint(toScreen:rows.table.convert(.init(x:65,y:rect.midY),to:nil))
        let targetRect = peer.table.visibleRect
        let to = main.convertPoint(toScreen:peer.table.convert(.init(x:targetRect.midX,y:targetRect.minY+min(100,targetRect.height/2)),to:nil))
        func point(_ value: NSPoint) -> [String:Double] { ["x":value.x,"y":screen.frame.maxY-value.y] }
        func relative(_ value: NSPoint) -> [String:Double] { ["x":value.x-archiveWindow.frame.minX,"y":archiveWindow.frame.maxY-value.y] }
        try JSONSerialization.data(withJSONObject:["pid":getpid(),"bundleID":Bundle.main.bundleIdentifier ?? "",
            "generatedOnly":true,"fromScreenTopLeft":point(from),"toScreenTopLeft":point(to),"selectedItems":model.selection.count,
            "fromWindowTopLeft":relative(from),"toWindowTopLeft":relative(to),"expiresAtUnixSeconds":Date().timeIntervalSince1970+150,
            "windowFrame":["x":archiveWindow.frame.minX,"y":screen.frame.maxY-archiveWindow.frame.maxY,
                "width":archiveWindow.frame.width,"height":archiveWindow.frame.height],
            "sourceWindowTitle":archiveWindow.title,"targetWindowTitle":main.title],options:[.prettyPrinted,.sortedKeys])
            .write(to:root.appendingPathComponent("evidence/gesture-ready.json"),options:.withoutOverwriting)
        let deadline = CACurrentMediaTime()+150
        var lastDiagnostics = ""
        while ApplicationArchiveExtraction.shared.controller == nil {
            let state: [String:Any] = ["pid":getpid(),"selectedCount":model.selection.count,"nativeSelectedCount":rows.selectedIDs.count,
                "writerRequests":rows.memberDragSource?.writerRequestsForVerification ?? -1,"beginCount":rows.memberDragSource?.beginCountForVerification ?? -1,
                "endCount":rows.memberDragSource?.endCountForVerification ?? -1,"lastCaptureReason":ArchiveMemberDragSource.lastCaptureReasonForVerification,
                "lastSourceKind":ArchiveMemberDragSource.lastSourceKindForVerification,"sourcePreparing":model.isPreparingSelection,
                "mouseDowns":rows.table.mouseDownsForVerification,"lastMouseRow":rows.table.lastMouseRowForVerification,
                "lastMousePoint":rows.table.lastMousePointForVerification,"dragHitCalls":rows.table.dragHitCallsForVerification,
                "lastDragHit":rows.table.lastDragHitForVerification,"captureCalls":ArchiveMemberDragSource.captureCallsForVerification,
                "lastMask":ArchiveMemberDragSource.lastMaskForVerification,"lastEndPoint":rows.table.lastDragEndPointForVerification,
                "lastEndOperation":rows.table.lastDragEndOperationForVerification]
            let data = try JSONSerialization.data(withJSONObject:state,options:.sortedKeys), digest = String(decoding:data,as:UTF8.self)
            if digest != lastDiagnostics {
                try data.write(to:root.appendingPathComponent("evidence/gesture-state.json"),options:.atomic); lastDiagnostics = digest
            }
            guard CACurrentMediaTime()<deadline else { metrics["nativeGestureDiagnostics"] = state; throw UIVerification.Failure(message:"Native gesture did not reach extraction review") }
            try await Task.sleep(for:.milliseconds(50))
        }
        guard let review = ApplicationArchiveExtraction.shared.controller else { throw UIVerification.Failure(message:"Gesture review disappeared") }
        try await wait("native gesture extraction preview") { !review.model.isPreparing && review.model.plan != nil }
        try UIVerification.require(review.model.parent == destination && review.model.members?.count == 2 && review.model.summary?.files == 2,
            "Actual gesture changed selected roots or destination")
        metrics["nativeGestureReview"] = true; metrics["nativeGestureSelectedRoots"] = review.model.members?.count ?? 0
        review.window?.title = "Archive drag gesture result · generated review"
        if let window = review.window { try await GlassVerification.captureOwnedWindow(window,to:root.appendingPathComponent("evidence/gesture-review.png")) }
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        checks.append("A real native drag from two selected archive rows reaches the existing exact destination review; Cancel performs no extraction")
    }
    private static func required<T>(_ value: T?,_ message: String) throws -> T {
        guard let value else { throw UIVerification.Failure(message:message) }; return value
    }
    private static func wait(_ message: String,_ condition: () -> Bool) async throws {
        let end = CACurrentMediaTime()+12
        while !condition() { guard CACurrentMediaTime()<end else { throw UIVerification.Failure(message:message) }; try await Task.sleep(for:.milliseconds(10)) }
    }
}
#endif
