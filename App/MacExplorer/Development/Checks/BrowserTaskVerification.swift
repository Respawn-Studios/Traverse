#if DEBUG
import AppKit
import CryptoKit
import Darwin
import ExplorerCore
import FileOperations
import LocalStorage

@MainActor enum BrowserTaskVerification {
    @MainActor private final class Pulse {
        var previous = CACurrentMediaTime(), gap = 0.0, ticks = 0
        var phase = "bootstrap", gaps:[String:Double] = [:]
        func tick() {let now = CACurrentMediaTime(),elapsed = now-previous;gap = max(gap,elapsed);gaps[phase] = max(gaps[phase] ?? 0,elapsed);previous = now;ticks += 1}
    }
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {exit(2)}
        let root = URL(fileURLWithPath:path)
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),root.resolvingSymlinksInPath() == root,
            UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent,
            let bytes = try? Data(contentsOf:root.appendingPathComponent("reservation.json")),
            let marker = try? JSONSerialization.jsonObject(with:bytes)as?[String:Any],marker["action"]as?String == "traverse-browser-tasks" else {exit(2)}
        let baseline = ProcessInfo.processInfo.arguments.contains("--task-action-baseline")
        let settings = BrowserSettings(persist:false)
        settings.autoRefreshFolders = false;settings.reviewsRecoveryAtStartup = false;settings.folderSummariesEnabled = false
        settings.showsDockProgress = false;settings.motion.mode = .off;settings.appearance = .dark
        settings.navigationStyle = .glass;settings.glassFileContent = true
        let owner = BrowserWindowController(settings:settings),pulse = Pulse()
        let privateBoard = NSPasteboard.withUniqueName()
        owner.browser.transferPasteboard = privateBoard
        var clipboardPublications = 0
        owner.browser.clipboardWriter = {_,_ in clipboardPublications += 1;return .failed}
        let timer = Timer(timeInterval:0.016,repeats:true) {_ in MainActor.assumeIsolated {pulse.tick()}}
        RunLoop.main.add(timer,forMode:.common)
        var checks:[String] = [],failures:[String] = [],metrics:[String:Any] = [:]
        do {try await verify(root:root,owner:owner,settings:settings,baseline:baseline,pulse:pulse,checks:&checks,metrics:&metrics)}
        catch {failures.append(String(describing:error))}
        owner.suspendBrowsing();await owner.flushSession();owner.window?.close();timer.invalidate()
        privateBoard.releaseGlobally()
        var usage = rusage();getrusage(RUSAGE_SELF,&usage)
        if usage.ru_maxrss>256*1024*1024 {failures.append("Native memory gate failed")}
        if pulse.gap>0.4 || pulse.ticks<10 {failures.append("Native response gate failed")}
        if ApplicationFileActivity.gate.activeCount != 0 {failures.append("Actual file work remains")}
        if clipboardPublications != 0 {failures.append("Unexpected clipboard command")}
        metrics["phaseMaximumGapsSeconds"] = pulse.gaps
        try? JSONSerialization.data(withJSONObject:["passed":failures.isEmpty,"baseline":baseline,"checks":checks,"failures":failures,"metrics":metrics,
            "peakRSSBytes":usage.ru_maxrss,"maximumMainActorGapSeconds":pulse.gap,"activityCount":ApplicationFileActivity.gate.activeCount,
            "generatedOnly":true,"clipboardReads":0,"clipboardWrites":0,"network":0,"personalFiles":0,"spokenVoiceOver":false,
            "nativeActionsNotPhysicalInput":true],options:[.prettyPrinted,.sortedKeys])
            .write(to:root.appendingPathComponent("result.json"),options:.withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root:URL,owner:BrowserWindowController,settings:BrowserSettings,baseline:Bool,pulse:Pulse,
        checks:inout[String],metrics:inout[String:Any]) async throws {
        try UIVerification.require(owner.isWorkspacePresentation,"Tasks require actual workspace composition")
        guard let window = owner.window else {throw UIVerification.Failure(message:"Workspace missing")}
        window.title = "Keyboard tasks · generated review";window.setFrame(.init(x:-12000,y:-12000,width:1140,height:760),display:true)
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        let browser = owner.browser,source = root.appendingPathComponent("source/Source"),folder = source.appendingPathComponent("Folder")
        browser.permitsBackgroundVerification = true;browser.folderAccess = FolderAccessController(stateDirectory:nil)
        browser.operationErrorPresenter = {_ in};browser.operationResultPresenter = {_ in}
        owner.beginBrowsing();try await wait("workspace") {owner.workspace.sessionReady}
        browser.navigate(to:.directory(source));try await settled(browser)
        browser.newTab(nil);try await settled(browser);browser.newTab(nil);try await settled(browser)
        guard let id = browser.tabs.dropFirst().first?.id,
            let button = browser.tabStrip.selectionButton(for:id)as?TabSelectionButton,
            let duplicate = button.accessibilityCustomActions()?.first(where:{$0.name == "Duplicate Tab"}),
            let left = button.accessibilityCustomActions()?.first(where:{$0.name == "Move Tab Left"}),
            let right = button.accessibilityCustomActions()?.first(where:{$0.name == "Move Tab Right"}) else {throw UIVerification.Failure(message:"Actual tab actions missing")}
        var observations:[[String:Any]] = []
        for hidden in [false,true] {
            for name in ["left","right","duplicate"] {
                button.isEnabled = hidden;button.isHidden = hidden
                let before = browser.tabs.map(\.id)
                let admitted = name == "left" ? button.accessibleMoveLeft(left) : name == "right" ? button.accessibleMoveRight(right) : button.accessibleDuplicate(duplicate)
                observations.append(["surface":"tab","state":hidden ? "hidden":"disabled","action":name,"accepted":admitted,"modelChanged":before != browser.tabs.map(\.id)])
                button.isEnabled = true;button.isHidden = false;try await settled(browser)
            }
        }
        browser.navigate(to:.directory(source));try await settled(browser)
        browser.setPaneViewMode(.icons);try await settled(browser)
        browser.iconBrowser.layoutSubtreeIfNeeded();browser.iconBrowser.collectionView.layoutSubtreeIfNeeded()
        try await wait("actual folder icon") {browser.iconBrowser.visibleItems.contains {$0.entry?.url == folder}}
        guard let icon = browser.iconBrowser.visibleItems.first(where:{$0.entry?.url == folder}),
            let open = icon.view.accessibilityCustomActions()?.first(where:{$0.name == "Open"}) else {throw UIVerification.Failure(message:"Actual icon Open missing")}
        icon.view.isHidden = true
        let iconAccepted = icon.accessibleOpen(open)
        icon.view.isHidden = false;try await settled(browser)
        observations.append(["surface":"icon","state":"hidden","action":"open","accepted":iconAccepted,"modelChanged":browser.location != .directory(source)])
        browser.navigate(to:.directory(source));try await settled(browser)

        // A detached retained item must refuse before it calls even an injected
        // callback. This component-only control is separate from the actual
        // browser navigation above and never implies physical pointer delivery.
        let detached = FileIconItem();detached.configure(.init(url:folder,name:"Folder",kind:.directory),showsExtensions:true,cut:false,emphasized:true)
        var detachedCalls = 0;detached.onAccessibleOpen = {_ in detachedCalls += 1;return true}
        guard let detachedAction = detached.view.accessibilityCustomActions()?.first else {throw UIVerification.Failure(message:"Detached icon action missing")}
        let detachedAccepted = detached.accessibleOpen(detachedAction)
        observations.append(["surface":"icon","state":"detached","action":"open","accepted":detachedAccepted,"modelChanged":detachedCalls != 0])
        let drive = VolumeTileItem();drive.configure(.init(url:folder,name:"Generated Drive",kind:.externalDisk),emphasized:true)
        var driveCalls = 0;drive.onOpen = {_ in driveCalls += 1}
        guard let driveAction = drive.view.accessibilityCustomActions()?.first else {throw UIVerification.Failure(message:"Detached drive action missing")}
        let driveAccepted = drive.performAccessibleOpen(driveAction)
        observations.append(["surface":"drive","state":"detached","action":"open","accepted":driveAccepted,"modelChanged":driveCalls != 0])
        metrics["actionLifetimeObservations"] = observations
        let unexpected = observations.filter {($0["accepted"]as?Bool == true)||($0["modelChanged"]as?Bool == true)}
        metrics["unexpectedActionCount"] = unexpected.count
        if baseline {
            try UIVerification.require(!unexpected.isEmpty,"Baseline did not reproduce a retained-control admission")
            checks.append("Generated baseline characterizes retained custom-action admission without file mutation; this is not a passed feature gate")
            return
        }
        try UIVerification.require(unexpected.isEmpty,"Hidden, disabled or detached controls retain custom-action authority")
        checks.append("Actual hidden icon/disabled and hidden tab actions plus detached icon/drive controls refuse before command callbacks")

        pulse.phase = "tabs"
        let workspace = owner.workspace
        try UIVerification.require(workspace.splitActive(at:.trailing),"Second task pane missing")
        let peer = workspace.activeBrowser,destination = root.appendingPathComponent("source/Destination")
        peer.clipboardWriter = browser.clipboardWriter
        peer.permitsBackgroundVerification = true;peer.folderAccess = FolderAccessController(stateDirectory:nil)
        peer.navigate(to:.directory(destination));try await settled(peer)
        try UIVerification.require(workspace.activeBrowser === peer && browser !== peer,"Task did not start in the other pane")
        guard let activeButton = browser.tabStrip.selectionButton(for:id)as?TabSelectionButton else {throw UIVerification.Failure(message:"Current background tab missing")}
        try UIVerification.require(activeButton.accessibilityPerformPress(),"Visible background-pane tab press refused")
        try await settled(browser)
        try UIVerification.require(workspace.activeBrowser === browser && browser.activeID == id && browser.hasFileCommandFocus,
            "Accessible tab press changed a tab without activating its own pane/focus")
        for (index,pane) in workspace.layout.paneIDs.enumerated() {
            let expected = "Pane \(index+1)"+(pane == workspace.activePaneID ? ", active":"")
            try UIVerification.require(workspace.paneHosts[pane]?.accessibilityLabel() == expected,"Native pane active label is stale")
        }
        let oldVisit = browser.sessionID
        guard let visibleRight = activeButton.accessibilityCustomActions()?.first(where:{$0.name == "Move Tab Right"}),
            let visibleDuplicate = activeButton.accessibilityCustomActions()?.first(where:{$0.name == "Duplicate Tab"}) else {throw UIVerification.Failure(message:"Visible custom actions missing")}
        try UIVerification.require(activeButton.accessibleMoveRight(visibleRight) && browser.activeID == id && browser.sessionID == oldVisit,
            "Visible accessible tab reorder refused or changed the active visit")
        let beforeDuplicate = Set(browser.tabs.map(\.id))
        try UIVerification.require(activeButton.accessibleDuplicate(visibleDuplicate),"Visible accessible duplicate refused")
        try await settled(browser)
        let duplicateIDs = Set(browser.tabs.map(\.id)).subtracting(beforeDuplicate)
        try UIVerification.require(duplicateIDs.count == 1 && browser.location == .directory(source),"Accessible duplicate lost its location")
        let duplicateID = duplicateIDs.first!
        guard let removedButton = browser.tabStrip.selectionButton(for:duplicateID)as?TabSelectionButton,
            let removedAction = removedButton.accessibilityCustomActions()?.first(where:{$0.name == "Duplicate Tab"}) else {throw UIVerification.Failure(message:"Removed-action control missing")}
        browser.closeTab(id:duplicateID);try await settled(browser)
        try UIVerification.require(!removedButton.accessibilityPerformPress() && !removedButton.accessibleDuplicate(removedAction),"Removed tab retained accessible commands")
        checks.append("Visible background-pane tab activation focuses the right pane, accessible reorder preserves the visit, duplicate keeps location and removed controls refuse")

        pulse.phase = "keys"
        for profile in [KeyboardProfile.explorer,.mac] {
            settings.keyboardProfile = profile
            for mode in BrowserViewMode.allCases {
                browser.navigate(to:.directory(source));try await settled(browser)
                browser.setPaneViewMode(mode);try await settled(browser)
                try select(folder,in:browser);browser.focusBrowserContent()
                let enter = profile == .explorer ? UIVerification.key("\r",code:36,flags:[],window:window)
                    : UIVerification.key(String(UnicodeScalar(0xF701)!),code:125,flags:.command,window:window)
                browser.activeFileView.keyDown(with:enter);try await settled(browser)
                try UIVerification.require(browser.location == .directory(folder),"Profile/mode folder key did not enter its selected folder")
                browser.activeFileView.keyDown(with:UIVerification.key(String(UnicodeScalar(0xF702)!),code:123,flags:.option,window:window))
                try await settled(browser)
                try UIVerification.require(browser.location == .directory(source) && browser.selectedURLs == [folder],"Back lost generated folder selection")
                browser.activeFileView.keyDown(with:UIVerification.key("\t",code:48,flags:[.command,.option],window:window))
                try UIVerification.require(workspace.activeBrowser === peer && peer.hasFileCommandFocus,"Native next-pane key lost its destination")
                peer.activeFileView.keyDown(with:UIVerification.key("\t",code:48,flags:[.command,.option],window:window))
                try UIVerification.require(workspace.activeBrowser === browser && browser.hasFileCommandFocus,"Native next-pane cycle did not restore its source")
            }
        }
        checks.append("Actual Details/List/Icons folder navigation and Back preserve selection in Mac/Explorer profiles; native next-pane shortcuts cycle focus without file commands")

        pulse.phase = "address-and-sheet"
        try select(folder,in:browser);browser.focusLocation(nil)
        try UIVerification.require(window.firstResponder is NSTextView,"Typed address did not get native text focus")
        let editingSelection = browser.selectedURLs
        for event in [UIVerification.key("c",code:8,flags:.command,window:window),UIVerification.key("x",code:7,flags:.command,window:window),
            UIVerification.key("v",code:9,flags:.command,window:window),UIVerification.key("z",code:6,flags:.command,window:window),
            UIVerification.key("a",code:0,flags:.command,window:window)] {
            try UIVerification.require(!browser.routeBrowserShortcut(event),"File dispatcher intercepted native address text editing")
        }
        try UIVerification.require(browser.selectedURLs == editingSelection,"Text-editing precedence changed file selection")
        browser.focusBrowserContent()
        let sheet = NSWindow(contentRect:.init(x:0,y:0,width:260,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed = false
        let sheetBegan = CACurrentMediaTime()
        window.beginSheet(sheet,completionHandler:{_ in})
        metrics["sheetBeginSeconds"] = CACurrentMediaTime()-sheetBegan
        try await wait("generated sheet attachment") {window.attachedSheet === sheet}
        // The native sheet calls each synchronously run their own ~270ms
        // presentation. Separate the user's later dismissal by a sampled UI
        // turn, rather than manufacture one combined open/close task stall.
        let sheetPulse = pulse.ticks
        try await wait("sampled sheet presentation turn") {pulse.ticks>sheetPulse}
        guard let blocked = browser.tabStrip.selectionButton(for:browser.activeID)as?TabSelectionButton,
            let blockedDuplicate = blocked.accessibilityCustomActions()?.first(where:{$0.name == "Duplicate Tab"}) else {throw UIVerification.Failure(message:"Blocked tab missing")}
        let sheetTabs = browser.tabs.map(\.id)
        try UIVerification.require(!blocked.accessibilityPerformPress() && !blocked.accessibleDuplicate(blockedDuplicate)
            && browser.tabs.map(\.id) == sheetTabs,"Underlying tab acted through an attached sheet")
        let sheetEnded = CACurrentMediaTime()
        window.endSheet(sheet);sheet.orderOut(nil)
        metrics["sheetEndSeconds"] = CACurrentMediaTime()-sheetEnded
        try await wait("sheet drain") {window.attachedSheet == nil}
        checks.append("Native address editing keeps text/IME routing ahead of file shortcuts; an attached sheet blocks underlying custom tab commands")

        pulse.phase = "retained-tools"
        browser.setPaneViewMode(.icons);try await settled(browser)
        browser.iconBrowser.layoutSubtreeIfNeeded();browser.iconBrowser.collectionView.layoutSubtreeIfNeeded()
        try await wait("visible accessible icon") {browser.iconBrowser.visibleItems.contains {$0.entry?.url == folder}}
        guard let visibleIcon = browser.iconBrowser.visibleItems.first(where:{$0.entry?.url == folder}),
            let visibleOpen = visibleIcon.view.accessibilityCustomActions()?.first else {throw UIVerification.Failure(message:"Visible icon missing")}
        workspace.activate(peer)
        try UIVerification.require(visibleIcon.accessibleOpen(visibleOpen),"Visible folder icon Open refused")
        try await settled(browser)
        try UIVerification.require(workspace.activeBrowser === browser && browser.location == .directory(folder),"Accessible icon opened without its correct pane")
        browser.navigate(to:.directory(source));try await settled(browser)
        browser.showSettings(nil)
        try await wait("retained Settings") {workspace.settingsWindow?.isVisible == true}
        browser.propertiesController.show(urls:[folder]);try await wait("retained Properties") {browser.propertiesController.window?.isVisible == true}
        // Press a different live tab so this exercises a command as well as focus.
        guard let other = browser.tabs.first(where:{$0.id != browser.activeID}),
            let otherButton = browser.tabStrip.selectionButton(for:other.id)as?TabSelectionButton else {throw UIVerification.Failure(message:"Background tab missing")}
        try UIVerification.require(otherButton.accessibilityPerformPress(),"Retained tools prevent explicit tab interaction")
        try await settled(browser)
        try UIVerification.require(window.isKeyWindow && workspace.activeBrowser === browser && browser.hasFileCommandFocus
            && workspace.settingsWindow?.isVisible == true && browser.propertiesController.window?.isVisible == true,"Returning from retained tools lost input or closed a tool")
        browser.propertiesController.cancel();browser.propertiesController.close();workspace.settingsWindow?.close()
        checks.append("Visible accessible icon Open activates its actual pane; explicit tab input returns to the browser while Settings and Properties remain open in the background")

        pulse.phase = "pane-copy-and-undo"
        browser.navigate(to:.directory(source));try await settled(browser);browser.setPaneViewMode(.details);try await settled(browser)
        workspace.activate(browser);try select(source.appendingPathComponent("Generated.txt"),in:browser);browser.focusBrowserContent()
        let engine = browser.operationCoordinator.engine(at:root.appendingPathComponent("history"))
        browser.recoverableFileOperations = engine;peer.recoverableFileOperations = engine
        let queue = browser.operationCoordinator.transfers,beforeCopy = Set(browser.operationCoordinator.transfers.results.map(\.id))
        browser.copyToOtherPane(nil)
        try await wait("native pane Copy") {!queue.hasOutstandingWork && queue.results.contains {!beforeCopy.contains($0.id)}}
        guard let copied = queue.results.first(where:{!beforeCopy.contains($0.id)}),let operation = copied.outcome.recordID else {throw UIVerification.Failure(message:"Native Copy result missing")}
        try UIVerification.require(copied.outcome.result.disposition == .succeeded,"Native pane Copy failed")
        let payload = destination.appendingPathComponent("Generated.txt")
        metrics["copiedSHA256"] = try await Task.detached {SHA256.hash(data:try Data(contentsOf:payload)).map {String(format:"%02x",$0)}.joined()}.value
        let undone = await engine.undo(recordID:operation)
        try UIVerification.require(undone.result.disposition == .succeeded && !FileManager().fileExists(atPath:payload.path),"Exact pane Copy Undo failed")
        let retained = try await engine.retentionRecord(recordID:operation)
        try UIVerification.require(retained.areas.count == 1 && retained.areas[0].verified,"Copy Undo retention is unverified")
        metrics["retainedUndoArea"] = retained.areas[0].url.lastPathComponent;metrics["retainedUndoOperation"] = operation.uuidString
        checks.append("After native focus transitions, existing Copy to Other Pane and exact engine Undo preserve the generated payload without using the clipboard")

        if ProcessInfo.processInfo.arguments.contains("--record-motion") {
            pulse.phase = "motion-recording"
            window.title = "Keyboard tasks · generated review";window.setFrame(.init(x:100,y:130,width:1140,height:760),display:true)
            let backdrop = GlassVerification.makeBrowserBackdropWindow(behind:window);defer {backdrop.close()}
            for mode in BrowserMotionMode.allCases {
                settings.motion.mode = mode;browser.navigate(to:.directory(source));try await settled(browser)
                workspace.activate(browser);try select(folder,in:browser);browser.focusBrowserContent()
                window.title = "Keyboard tasks · generated review"
                let report = try await NativeMotionRecorder.record(window:window,root:root,label:"browser-task-"+mode.rawValue) {
                    browser.activeFileView.keyDown(with:UIVerification.key(String(UnicodeScalar(0xF701)!),code:125,flags:.command,window:window))
                }
                try JSONEncoder().encode(report).write(to:root.appendingPathComponent("evidence/browser-task-"+mode.rawValue+".json"),options:.withoutOverwriting)
                try await settled(browser);try UIVerification.require(browser.location == .directory(folder),"Recorded native folder key did not navigate")
            }
        }
    }
    private static func select(_ url:URL,in browser:BrowserViewController) throws {
        if browser.usesFileIcons {browser.iconBrowser.setSelection([url])}
        else {
            guard let row = browser.rowsByURL[url] else {throw UIVerification.Failure(message:"Generated selection missing")}
            browser.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        }
        browser.fileSelectionDidChange()
    }
    private static func settled(_ browser:BrowserViewController) async throws {
        try await wait("native browser") {!browser.isLoading && browser.orderingTask == nil && browser.canvasTransition == nil}
        browser.view.window?.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(for:.milliseconds(16))
    }
    private static func wait(_ name:String,_ condition:()->Bool) async throws {
        let end = CACurrentMediaTime()+12
        while !condition() {try UIVerification.require(CACurrentMediaTime()<end,name);try await Task.sleep(for:.milliseconds(10))}
    }
}
#endif
