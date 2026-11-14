#if DEBUG
import AppKit
import CryptoKit
import Darwin
import ExplorerCore
import FileOperations
import LocalStorage

@MainActor enum ArchiveSortingVerification {
    @MainActor private final class Pulse { var last = CACurrentMediaTime(), gap = 0.0, ticks = 0
        func tick() { let now = CACurrentMediaTime(); gap = max(gap,now-last); last = now; ticks += 1 }
    }
    @MainActor private final class Hold {
        var entered = false, released = false
        private var continuation: CheckedContinuation<Void,Never>?
        func pause() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath:path)
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),root.resolvingSymlinksInPath() == root,
            UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent,
            let data = try? Data(contentsOf:root.appendingPathComponent("reservation.json")),
            let marker = try? JSONSerialization.jsonObject(with:data) as? [String:Any],marker["action"] as? String == "traverse-archive-sorting" else { exit(2) }
        let settings = BrowserSettings(persist:false)
        settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
        settings.showsDockProgress = false; settings.motion.mode = .off; settings.appearance = .dark
        settings.navigationStyle = .glass; settings.glassFileContent = true
        let owner = BrowserWindowController(settings:settings), pulse = Pulse()
        let ticker = Timer(timeInterval:0.016,repeats:true) {_ in MainActor.assumeIsolated { pulse.tick() } }
        RunLoop.main.add(ticker,forMode:.common)
        var checks: [String] = [], failures: [String] = [], metrics: [String:Any] = [:]
        do { try await verify(root:root,owner:owner,settings:settings,checks:&checks,metrics:&metrics) }
        catch { failures.append(String(describing:error)) }
        await ApplicationArchiveExtraction.shared.closeAndDrain(); await ApplicationZIPBrowser.shared.stopAndDrain()
        owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close(); ticker.invalidate()
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        if usage.ru_maxrss > 256*1024*1024 { failures.append("Native256MiB memory gate failed") }
        if pulse.gap > 0.4 || pulse.ticks < 10 { failures.append("Native400ms response gate failed") }
        if ApplicationFileActivity.gate.activeCount != 0 { failures.append("Actual filesystem work remains") }
        try? JSONSerialization.data(withJSONObject:["passed":failures.isEmpty,"checks":checks,"failures":failures,"metrics":metrics,
            "peakRSSBytes":usage.ru_maxrss,"maximumMainActorGapSeconds":pulse.gap,"ticks":pulse.ticks,"activityCount":ApplicationFileActivity.gate.activeCount,
            "generatedOnly":true,"metadataOnlyOrdering":true,"explicitSelectedPreviewAndExtraction":true,"nativeInputNotPhysicalPointer":true,
            "spokenVoiceOver":false,"osGrantAcceptance":false,"ordinaryOrderingEnabled":ArchiveOrderingActivation.enabled,"network":0],options:[.prettyPrinted,.sortedKeys])
            .write(to:root.appendingPathComponent("result.json"),options:.withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root: URL,owner: BrowserWindowController,settings: BrowserSettings,
        checks: inout [String],metrics: inout [String:Any]) async throws {
        try UIVerification.require(owner.isWorkspacePresentation,"Ordering requires actual workspace composition")
        guard let main = owner.window else { throw UIVerification.Failure(message:"Workspace missing") }
        main.setFrame(.init(x:-12000,y:-12000,width:1140,height:760),display:true)
        let origin = owner.browser, workspace = owner.workspace, source = root.appendingPathComponent("source")
        origin.permitsBackgroundVerification = true; origin.operationErrorPresenter = {_ in}; origin.operationResultPresenter = {_ in}
        origin.folderAccess = FolderAccessController(stateDirectory:nil)
        let engine = origin.operationCoordinator.engine(at:root.appendingPathComponent("history")); origin.recoverableFileOperations = engine
        owner.beginBrowsing(); try await wait("workspace") { workspace.sessionReady }
        origin.navigate(to:.directory(source)); try await wait("source") { !origin.isLoading && origin.orderingTask == nil }
        try UIVerification.require(workspace.splitActive(at:.trailing),"Destination pane missing")
        let peer = workspace.activeBrowser, destination = root.appendingPathComponent("source/Destination")
        peer.permitsBackgroundVerification = true; peer.folderAccess = FolderAccessController(stateDirectory:nil)
        peer.navigate(to:.directory(destination)); try await wait("destination") { !peer.isLoading && peer.orderingTask == nil }
        workspace.activate(origin)
        let small = source.appendingPathComponent("Small.zip")
        ApplicationZIPBrowser.shared.show(small,from:origin)
        guard let archive = ApplicationZIPBrowser.shared.controller, let window = archive.window else { throw UIVerification.Failure(message:"Archive missing") }
        window.title = "Archive sorting · generated review"
        window.setFrame(.init(x:-12000,y:-12000,width:960,height:640),display:true)
        let model = archive.model
        try await settled(model)
        guard let rows = model.rowsForVerification, let header = rows.table.headerView as? FileTableHeaderView,
            let folder = model.visibleItems.first(where:{$0.name == "Folder"})?.folder else { throw UIVerification.Failure(message:"Native folder/table missing") }
        model.navigate(folder); try await settled(model)
        var actual: [String:[String]] = [:], observations: [[String:Any]] = []
        for field in ZIPArchiveOrder.Field.allCases {
            for descending in [false,true] {
                let key = field == .logical ? "size" : field.rawValue
                guard let index = rows.table.tableColumns.firstIndex(where:{$0.identifier.rawValue == key}) else { throw UIVerification.Failure(message:"Sort column missing") }
                if model.ordering.field != field || model.ordering.descending != descending {
                    try click(index:index,header:header,window:window)
                    try await settled(model)
                    if model.ordering.descending != descending { try click(index:index,header:header,window:window); try await settled(model) }
                }
                try UIVerification.require(model.ordering == ZIPArchiveOrder(field,descending:descending) && model.visibleOffset == 0,"Native header did not request the chosen complete order")
                header.layoutSubtreeIfNeeded(); header.displayIfNeeded()
                for column in rows.table.tableColumns where !column.isHidden && column.sortDescriptorPrototype != nil {
                    let active = column.identifier.rawValue == key
                    let expected: NSAccessibilitySortDirection = active ? descending ? .descending : .ascending : .unknown
                    try UIVerification.require(column.headerCell.accessibilitySortDirection() == expected,"Native accessibility sort direction is stale")
                }
                var paths = model.visibleItems.map(\.path)
                while model.hasNextPage { model.nextPage(); try await settled(model); paths += model.visibleItems.map(\.path) }
                let label = field.rawValue+(descending ? "-descending" : "-ascending")
                actual[label] = paths
                observations.append(["field":field.rawValue,"descending":descending,"rows":paths.count,"lastOffset":model.visibleOffset])
            }
        }
        try JSONSerialization.data(withJSONObject:actual,options:[.sortedKeys]).write(to:root.appendingPathComponent("evidence/ordered-pages.json"),options:.withoutOverwriting)
        metrics["headerOrders"] = observations
        checks.append("Real native header tracking orders complete600-member folders in all eight field/direction combinations; primary accessibility arrows clear and every page remains bounded")

        guard let sortMenu = rows.table.menu?.items.first(where:{$0.title == "Sort By"})?.submenu,
            let sizeItem = sortMenu.items.first(where:{$0.title == "Size"}),let reverse = sortMenu.items.first(where:{$0.title == "Descending Order"}),
            let sizeAction = sizeItem.action, let reverseAction = reverse.action else { throw UIVerification.Failure(message:"Keyboard-accessible Sort menu missing") }
        try UIVerification.require(rows.validateMenuItem(sizeItem) && NSApp.sendAction(sizeAction,to:rows,from:sizeItem),"Size menu refused")
        try await settled(model)
        try UIVerification.require(model.ordering == .init(.logical,descending:true),"Size menu did not choose its useful descending default")
        try UIVerification.require(rows.validateMenuItem(sizeItem) && sizeItem.state == .on,"Sort menu checkmark differs")
        try UIVerification.require(rows.validateMenuItem(reverse) && reverse.state == .on && NSApp.sendAction(reverseAction,to:rows,from:reverse),"Reverse menu refused")
        try await settled(model)
        try UIVerification.require(model.ordering == .init(.logical),"Reverse menu failed")
        checks.append("Native Sort By and direction menu actions use the same typed ordering and truthful checkmarks")

        _ = model.order(by:.init(.logical,descending:true)); try await settled(model)
        model.nameScope = .archive; model.filter = "Entry 017.txt"; model.applyFilter(); try await settled(model)
        guard let selected = model.visibleItems.first else { throw UIVerification.Failure(message:"Selected member missing") }
        model.selection = [selected.id]; model.showInArchive(); try await settled(model)
        try UIVerification.require(model.visibleOffset == 512 && model.selection == [selected.id] && model.visibleItems.contains {$0.id == selected.id},"Sorted containing-page reveal lost the member")
        model.back(); try await settled(model)
        try UIVerification.require(model.isSearchResults && model.filter == "Entry 017.txt" && model.ordering == .init(.logical,descending:true),"Back lost criteria or order")
        model.forward(); try await settled(model)
        try UIVerification.require(!model.isSearchResults && model.visibleOffset == 512 && model.ordering.descending,"Forward lost sorted cursor")
        checks.append("Show in Archive locates the selected member beyond the first two pages under the chosen order; Back/Forward retain order, criteria and cursor")

        model.selection = [selected.id]; model.previewSelected(); await model.drain()
        guard let text = model.textPreviewForVerification.textForVerification else { throw UIVerification.Failure(message:"Explicit selected text preview missing") }
        metrics["previewSHA256"] = SHA256.hash(data:Data(text.utf8)).map {String(format:"%02x",$0)}.joined()
        model.textPreviewForVerification.stop(closeWindow:true); await model.textPreviewForVerification.drain()
        model.selection = [selected.id]; model.extractSelected()
        try await wait("selected review") { !model.isPreparingSelection && ApplicationArchiveExtraction.shared.controller != nil }
        guard let panel = ApplicationArchiveExtraction.shared.controller,
            let candidate = LocalPaneDestination.available(from:origin).first(where:{$0.pane == peer.paneID}) else { throw UIVerification.Failure(message:"Reviewed destination missing") }
        panel.model.chooseDestination(candidate)
        try await wait("selected destination preview") { !panel.model.isChoosing && !panel.model.isPreparing && panel.model.parent == destination && panel.model.plan != nil }
        guard let plan = panel.model.plan else { throw UIVerification.Failure(message:"Selected plan missing") }
        try UIVerification.require(plan.files == 1,"Reordering widened the extraction selection")
        panel.model.extract(); try await wait("selected extract") { !panel.model.isRunning && panel.model.outcome != nil }
        try UIVerification.require(panel.model.outcome?.result.disposition == .succeeded,"Sorted selected extraction failed")
        let output = plan.destination.appendingPathComponent("Folder/Entry 017.txt")
        metrics["extractedSHA256"] = try await Task.detached { SHA256.hash(data:try Data(contentsOf:output)).map {String(format:"%02x",$0)}.joined() }.value
        panel.model.undo(); try await wait("exact Undo") { !panel.model.isRunning && panel.model.undoOutcome != nil }
        try UIVerification.require(panel.model.undoOutcome?.result.disposition == .succeeded && !FileManager().fileExists(atPath:plan.destination.path),"Sorted selection Undo failed")
        guard let operation = panel.model.outcome?.recordID else { throw UIVerification.Failure(message:"Exact history missing") }
        let retained = try await engine.retentionRecord(recordID:operation)
        try UIVerification.require(retained.areas.count == 1 && retained.areas[0].verified,"Undo payload is unverified")
        metrics["retainedUndoArea"] = retained.areas[0].url.lastPathComponent; metrics["retainedUndoOperation"] = operation.uuidString
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        checks.append("Sorted identities drive explicit checked text preview, one exact selected extraction and guarded Undo through the existing engine")

        let stale = selected.id
        model.refresh(); try await settled(model)
        try UIVerification.require(model.ordering == .init(.logical,descending:true) && !model.canPreviewSelection([stale]) && !model.canExtractSelection([stale]),"Refresh lost the active order or accepted prior identities")
        guard let refreshedFolder = model.visibleItems.first(where:{$0.name == "Folder"})?.folder else { throw UIVerification.Failure(message:"Refreshed folder missing") }
        model.navigate(refreshedFolder); try await settled(model)
        let hold = Hold(); defer {hold.release()}
        let starts = model.pageRequestsForVerification
        model.beforePageForVerification = {await hold.pause()}
        _ = model.order(by:.init(.name)); try await wait("held sort owner") {hold.entered}
        for value in [ZIPArchiveOrder(.packed),.init(.method,descending:true),.init(.logical)] { _ = model.order(by:value) }
        try UIVerification.require(model.pageRequestsForVerification == starts+1 && !model.viewIsCurrent && model.selection.isEmpty && !model.canExtractSelected,"Pending sort retained old selection authority or admitted multiple owners")
        hold.release(); try await settled(model); model.beforePageForVerification = nil
        try UIVerification.require(model.pageRequestsForVerification == starts+2 && model.ordering == .init(.logical),"Sort requests did not coalesce to one latest demand")
        model.filter = String(repeating:"é",count:65); model.applyFilter()
        try UIVerification.require(!model.order(by:.init(.packed)) && !model.viewIsCurrent && model.selection.isEmpty,"Invalid search criteria admitted a sort of old rows")
        model.filter = ""; model.applyFilter(); try await settled(model)
        checks.append("Refresh retains the chosen order with new IDs; one active plus one latest sort rejects stale selection and invalid name drafts")

        let stopHold = Hold(); defer {stopHold.release()}
        model.beforePageForVerification = {await stopHold.pause()}
        _ = model.order(by:.init(.packed)); try await wait("held Stop owner") {stopHold.entered}
        model.stop()
        var stopDrained = false
        let stopping = Task {await model.drain();stopDrained = true}
        try await Task.sleep(for:.milliseconds(40))
        try UIVerification.require(!stopDrained && !model.viewIsCurrent && model.selection.isEmpty,"Stop escaped the held owner or retained old action authority")
        stopHold.release(); await stopping.value; model.beforePageForVerification = nil
        try UIVerification.require(!model.viewIsCurrent && model.notice.contains("stopped"),"Stopped ordering published late rows")
        try UIVerification.require(model.order(by:model.ordering),"Stopped view cannot retry its chosen order")
        try await settled(model)
        checks.append("Stop withdraws selection immediately, joins its actual held owner and permits a fresh same-order retry without late publication")

        metrics["scaleExercised"] = !ProcessInfo.processInfo.arguments.contains("--record-motion")
        if !ProcessInfo.processInfo.arguments.contains("--record-motion") {
            let began = CACurrentMediaTime()
            model.open(source.appendingPathComponent("Large.zip"),from:origin); try await settled(model)
            metrics["scaleFirstFolderMilliseconds"] = (CACurrentMediaTime()-began)*1000
            try UIVerification.require(model.summary?.files == 100_000 && model.visibleItems.count == 256,"Complete100k catalog missing")
            let ascending = CACurrentMediaTime(); _ = model.order(by:.init(.logical,descending:true)); try await settled(model)
            metrics["scaleSizeSortToRowsMilliseconds"] = (CACurrentMediaTime()-ascending)*1000
            var ranked: [String] = model.visibleItems.map(\.name)
            let pageStart = CACurrentMediaTime(); model.nextPage(); try await settled(model)
            metrics["scaleCachedPageToRowsMilliseconds"] = (CACurrentMediaTime()-pageStart)*1000
            ranked += model.visibleItems.map(\.name)
            metrics["scaleFirst512Names"] = ranked
            model.nameScope = .archive; model.filter = ".txt"; model.applyFilter()
            let searchStart = CACurrentMediaTime(); try await settled(model)
            metrics["scaleGlobalSortedQueryToRowsMilliseconds"] = (CACurrentMediaTime()-searchStart)*1000
            metrics["scaleGlobalFirst256Names"] = model.visibleItems.map(\.name)
            try UIVerification.require(model.visibleTotal == 100_000 && model.visibleItems.count == 256,"Sorted global query is not bounded")
            for key in ["scaleFirstFolderMilliseconds","scaleSizeSortToRowsMilliseconds","scaleGlobalSortedQueryToRowsMilliseconds"] {
                try UIVerification.require((metrics[key] as? Double ?? .infinity)<=5_000,"Complete-workload ordering latency gate failed: "+key)
            }
            try UIVerification.require((metrics["scaleCachedPageToRowsMilliseconds"] as? Double ?? .infinity)<=250,"Cached sorted-page latency gate failed")
            checks.append("Actual100k directory and global name results sort off the UI actor with bounded native rows and independent complete-result rank oracles")

        }
        model.open(small,from:origin); try await settled(model)
        guard let motionFolder = model.visibleItems.first(where:{$0.name == "Folder"})?.folder else { throw UIVerification.Failure(message:"Motion folder missing") }
        model.navigate(motionFolder); try await settled(model)
        if ProcessInfo.processInfo.arguments.contains("--record-motion") {
            window.title = "Archive sorting · generated review"
            window.setFrameOrigin(.init(x:100,y:130)); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
            metrics["recordWindowGeometry"] = ["width":window.frame.width,"height":window.frame.height]
            let backdrop = GlassVerification.makeBrowserBackdropWindow(behind:window); defer {backdrop.close()}
            for mode in BrowserMotionMode.allCases {
                settings.motion.mode = mode; _ = model.order(by:.init(.name)); try await settled(model)
                let report = try await NativeMotionRecorder.record(window:window,root:root,label:"archive-order-"+mode.rawValue) {
                    _ = model.order(by:.init(.logical,descending:true))
                }
                try JSONEncoder().encode(report).write(to:root.appendingPathComponent("evidence/archive-order-"+mode.rawValue+".json"),options:.withoutOverwriting)
                try await settled(model)
            }
            try await GlassVerification.captureOwnedWindow(window,to:root.appendingPathComponent("evidence/archive-order.png"))
        }
        let closeHold = Hold(); defer {closeHold.release()}
        model.beforePageForVerification = {await closeHold.pause()}; _ = model.order(by:.init(.packed)); try await wait("held closing sort") {closeHold.entered}
        var closed = false
        let closing = Task {await ApplicationZIPBrowser.shared.stopAndDrain(); closed = true}
        try await Task.sleep(for:.milliseconds(40)); try UIVerification.require(!closed,"Close escaped actual sort ownership")
        closeHold.release(); await closing.value
        try UIVerification.require(ApplicationZIPBrowser.shared.controller == nil && ApplicationFileActivity.gate.activeCount == 0,"Closed sort retained actual work")
        checks.append("Closing joins the actual held native query owner and retires its catalog without late rows or file work")
    }
    private static func settled(_ model: ArchiveBrowserModel) async throws {
        await model.drain()
        try await wait("ordered native rows") {!model.isLoading && !model.isPaging && !model.isQueryPending && !model.isPreparingSelection}
        try await Task.sleep(for:.milliseconds(16))
        model.window?.contentView?.layoutSubtreeIfNeeded(); model.window?.displayIfNeeded()
    }
    private static func wait(_ name: String,_ condition: () -> Bool) async throws {
        let end = CACurrentMediaTime()+20
        while !condition() {try UIVerification.require(CACurrentMediaTime()<end,name);try await Task.sleep(for:.milliseconds(10))}
    }
    private static func click(index: Int,header: FileTableHeaderView,window: NSWindow) throws {
        let point = header.convert(.init(x:header.headerRect(ofColumn:index).midX,y:header.bounds.midY),to:nil)
        let stamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:stamp,windowNumber:window.windowNumber,
                context:nil,eventNumber:957,clickCount:1,pressure:0) else {throw UIVerification.Failure(message:"Native header event missing")};return e
        }
        let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        NSApp.postEvent(up,atStart:true);header.mouseDown(with:down)
        if let pending = NSApp.nextEvent(matching:.leftMouseUp,until:.distantPast,inMode:.default,dequeue:false),
           pending.windowNumber == up.windowNumber && pending.timestamp == up.timestamp && pending.eventNumber == up.eventNumber,
           let release = NSApp.nextEvent(matching:.leftMouseUp,until:.distantPast,inMode:.default,dequeue:true) {NSApp.sendEvent(release)}
    }
}
#endif
