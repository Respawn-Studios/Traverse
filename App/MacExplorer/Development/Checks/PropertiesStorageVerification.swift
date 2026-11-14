#if DEBUG
import AppKit
import Darwin
import ExplorerCore

@MainActor enum PropertiesStorageVerification {
    @MainActor private final class Pulse {
        var previous = CACurrentMediaTime(),gap = 0.0,ticks = 0
        func tick() {let now = CACurrentMediaTime();gap = max(gap,now-previous);previous = now;ticks += 1}
    }
    private final class Counter:@unchecked Sendable {
        private let lock = NSLock();private var live = 0,starts = 0,ends = 0
        func begin() {lock.withLock {live += 1;starts += 1}}
        func end() {lock.withLock {live -= 1;ends += 1}}
        var values:[String:Int] {lock.withLock {["live":live,"acquired":starts,"released":ends]}}
    }
    private final class Lease:@unchecked Sendable {
        let counter:Counter
        init(_ counter:Counter) {self.counter = counter;counter.begin()}
        deinit {counter.end()}
    }
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {exit(2)}
        let root = URL(fileURLWithPath:path)
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),root.resolvingSymlinksInPath() == root,
            UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent,
            let marker = try? object(root.appendingPathComponent("reservation.json")),marker["action"]as?String == "traverse-properties-storage" else {exit(2)}
        let settings = BrowserSettings(persist:false)
        settings.autoRefreshFolders = false;settings.folderSummariesEnabled = false;settings.reviewsRecoveryAtStartup = false;settings.showsDockProgress = false
        settings.appearance = .dark;settings.navigationStyle = .glass;settings.glassFileContent = true;settings.motion.mode = .off
        let owner = BrowserWindowController(settings:settings),counter = Counter(),pulse = Pulse()
        let reader = FilePropertiesReader(retainAccess:{_ in Lease(counter)})
        let controller = FilePropertiesWindowController(reader:reader,settings:settings,copyPaths:{_ in})
        let timer = Timer(timeInterval:0.016,repeats:true) {_ in MainActor.assumeIsolated {pulse.tick()}}
        RunLoop.main.add(timer,forMode:.common)
        var checks:[String] = [],failures:[String] = [],metrics:[String:Any] = [:]
        do {try await verify(root:root,repo:repo,owner:owner,controller:controller,reader:reader,settings:settings,checks:&checks,metrics:&metrics)}
        catch {failures.append(String(describing:error))}
        controller.cancel();controller.close();owner.suspendBrowsing();await owner.flushSession()
        do {try await wait("actual Properties access drain") {counter.values["live"] == 0 && ApplicationFileActivity.gate.activeCount == 0}}
        catch {failures.append(String(describing:error))}
        owner.window?.close();timer.invalidate();var usage = rusage();getrusage(RUSAGE_SELF,&usage)
        if usage.ru_maxrss>256*1024*1024 {failures.append("Native memory gate failed")}
        if pulse.gap>0.4 || pulse.ticks<10 {failures.append("Native response gate failed")}
        metrics["accessLeases"] = counter.values
        try? JSONSerialization.data(withJSONObject:["passed":failures.isEmpty,"checks":checks,"failures":failures,"metrics":metrics,
            "peakRSSBytes":usage.ru_maxrss,"maximumMainActorGapSeconds":pulse.gap,"activityCount":ApplicationFileActivity.gate.activeCount,
            "generatedOnly":true,"privateSizeAPI":false,"bodyReads":false,"clipboard":false,"network":false,"physicalPointer":false,"spokenVoiceOver":false],options:[.prettyPrinted,.sortedKeys])
            .write(to:root.appendingPathComponent("result.json"),options:.withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root:URL,repo:URL,owner:BrowserWindowController,controller:FilePropertiesWindowController,reader:FilePropertiesReader,
        settings:BrowserSettings,checks:inout[String],metrics:inout[String:Any])async throws {
        try UIVerification.require(owner.isWorkspacePresentation,"Properties check requires actual workspace composition")
        guard let window = owner.window else {throw UIVerification.Failure(message:"Browser missing")}
        window.setFrame(.init(x:-12000,y:-12000,width:960,height:640),display:true);window.orderFront(nil)
        owner.browser.permitsBackgroundVerification = true
        owner.beginBrowsing();try await wait("workspace") {owner.workspace.sessionReady}
        let oracle = try object(root.appendingPathComponent("metadata-oracles.json"))
        guard let token = oracle["matrix"]as?String,UUID(uuidString:token)?.uuidString == token,
            let rows = oracle["rows"]as?[[String:Any]],rows.count == 11 else {throw UIVerification.Failure(message:"Borrowed generated oracle missing")}
        let matrix = repo.appendingPathComponent(".build/traverse-release/"+token)
        let marker = try object(matrix.appendingPathComponent("reservation.json")),result = try object(matrix.appendingPathComponent("result.json"))
        try UIVerification.require(matrix.resolvingSymlinksInPath() == matrix && marker["action"]as?String == "traverse-private-allocation" && result["passed"]as?Bool == true,"Only a passed generated matrix may be borrowed")
        let files = matrix.appendingPathComponent("source/Files")
        let allowed:Set<String> = ["Plain.bin","Clone A.bin","Clone B.bin","Hardlink.bin","Independent.bin","Sparse.bin","Empty.bin","Fork.bin","Link.bin",".","Missing.bin"]
        let names = rows.compactMap {$0["name"]as?String}
        try UIVerification.require(Set(names) == allowed,"Oracle requested a different metadata scope")
        let urls = names.map {$0 == "." ? files : files.appendingPathComponent($0)}
        let report = try await reader.read(urls)
        var actual:[[String:Any]] = []
        for (index,row)in rows.enumerated() {
            let observation = report.observations[index]
            if let expected = row["allocated"]as?NSNumber {
                try UIVerification.require(observation.allocatedByteCount == expected.uint64Value
                    && observation.byteCount == (row["logical"]as?NSNumber)?.int64Value
                    && observation.linkedNameCount == (row["links"]as?NSNumber)?.uint64Value,"Actual Properties allocation/logical/link facts differ from independent stat oracle")
            } else {
                try UIVerification.require(observation.allocatedByteCount == nil && observation.linkedNameCount == nil,"Non-regular/missing item acquired regular allocation facts")
            }
            actual.append(["name":names[index],"logical":observation.byteCount.map {NSNumber(value:$0)as Any} ?? NSNull(),
                "allocated":observation.allocatedByteCount.map {NSNumber(value:$0)as Any} ?? NSNull(),"links":observation.linkedNameCount.map {NSNumber(value:$0)as Any} ?? NSNull(),
                "allocationText":observation.allocatedSizeDescription])
        }
        metrics["observations"] = actual
        checks.append("Actual Properties matches independent plain/clone/diverged/hardlink/sparse/empty/resource-fork metadata; folders, links and missing paths stay outside regular allocation")
        try UIVerification.require(FilePropertiesReader.allocatedBytes(blocks:-1) == nil && FilePropertiesReader.allocatedBytes(blocks:0) == 0
            && FilePropertiesReader.allocatedBytes(blocks:1) == 512 && FilePropertiesReader.allocatedBytes(blocks:Int64.max) == nil
            && FilePropertiesReader.allocatedBytes(blocks:Int64.max/512) == UInt64(Int64.max/512)*512,"Allocation overflow/negative/known-zero contract failed")
        let capped = try await reader.read(Array(repeating:files.appendingPathComponent("Empty.bin"),count:257))
        try UIVerification.require(capped.observations.count == 256 && capped.omittedCount == 1 && capped.observations.allSatisfy {$0.allocatedByteCount == 0},"Properties cap or empty-file allocation failed")
        let cancelled = Task {try await reader.read(urls)};cancelled.cancel()
        do {_ = try await cancelled.value;throw UIVerification.Failure(message:"Pre-admission cancellation was ignored")}catch is CancellationError {}
        checks.append("Checked block conversion preserves unknown/zero/overflow, actual256-item bound holds and pre-admission cancellation refuses")

        let original = root.appendingPathComponent("source/Original")
        owner.browser.navigate(to:.directory(original));try await wait("original fixture") {!owner.browser.isLoading && owner.browser.orderingTask == nil}
        try await UIVerification.verifyProperties(owner.browser,fixture:original,output:root.appendingPathComponent("evidence"))
        checks.append("Original Properties metadata, unsupported URL, cap, cancellation, stale completion, native window, injected Copy Path and Light/Dark appearance regressions pass")
        BrowserAppearanceController.apply(.dark)

        let selected = [files.appendingPathComponent("Sparse.bin"),files.appendingPathComponent("Fork.bin")]
        controller.show(urls:selected)
        try await wait("actual Properties report") {!controller.model.isLoading && controller.model.report?.observations.count == 2}
        guard let panel = controller.window else {throw UIVerification.Failure(message:"Actual Properties panel missing")}
        panel.setFrame(.init(x:100,y:130,width:960,height:640),display:true);panel.makeKeyAndOrderFront(nil)
        let backdrop = GlassVerification.makeBrowserBackdropWindow(behind:panel);defer {backdrop.close()}
        var nativeModes:[[String:Any]] = []
        for mode in BrowserMotionMode.allCases {
            settings.motion.mode = mode;controller.model.selectedObservationID = 0
            try await Task.sleep(for:.milliseconds(350))
            try UIVerification.require(controller.model.selectedObservation?.allocatedByteCount == 8192,"Loaded sparse detail lost its allocation")
            guard let chrome = panel.contentViewController as?ToolWindowChrome else {throw UIVerification.Failure(message:"Native shared chrome missing")}
            ToolContentMotion.reveal(chrome.contentHost);ToolContentMotion.reveal(chrome.contentHost)
            let group = chrome.contentHost.layer?.animation(forKey:"tool-content-entrance")as?CAAnimationGroup
            let opacity = group?.animations?.compactMap {$0 as?CABasicAnimation}.first(where:{$0.keyPath == "opacity"})
            let animated = mode != .off && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            try UIVerification.require(animated ? group?.duration == 0.2*mode.durationScale : group == nil,"Native page reveal ignored its mode")
            if animated {
                let start = (opacity?.fromValue as?NSNumber)?.doubleValue ?? 0
                try UIVerification.require(start>=0.72 && start<1,"Native page starts unreadable")
                nativeModes.append(["mode":mode.rawValue,"initialOpacity":start])
            } else {nativeModes.append(["mode":mode.rawValue,"animated":false])}
            settings.motion.pages = false
            try await wait("native preference update") {!chrome.motion.pages}
            try UIVerification.require(chrome.contentHost.layer?.animation(forKey:"tool-content-entrance") == nil,"Disabling page motion left its native reveal running")
            settings.motion.pages = true;try await wait("restored native preference") {chrome.motion.pages}
            if ProcessInfo.processInfo.arguments.contains("--record-motion") {
                panel.title = "Storage details · generated review"
                let recording = try await NativeMotionRecorder.record(window:panel,root:root,label:"properties-storage-"+mode.rawValue) {controller.model.selectedObservationID = 1}
                try JSONEncoder().encode(recording).write(to:root.appendingPathComponent("evidence/properties-storage-"+mode.rawValue+".json"),options:.withoutOverwriting)
            } else {controller.model.selectedObservationID = 1}
            try UIVerification.require(controller.model.selectedObservation?.allocatedByteCount == 81920 && controller.model.selectedObservation?.byteCount == 16384,"Loaded resource-fork detail disagrees with native oracle")
        }
        metrics["nativeMotionModes"] = nativeModes
        if ProcessInfo.processInfo.arguments.contains("--check-shared-tool-motion") {
            let originalMotion = try await MotionModesVerification.run(root:root,controller:owner)
            try UIVerification.require(originalMotion["passed"]as?Bool == true,"Original full/reduced/off cross-component regression failed")
            metrics["originalMotionRegression"] = originalMotion
            checks.append("Original three-mode model/save-reopen/tab/pane/chart/native-window regression passes in its separately admitted generated release root")
        }
        controller.close();try await wait("actual Properties close") {controller.window?.isVisible == false}
        checks.append("Actual loaded Properties details retain amounts through Full/Reduced/Off page changes; native reveal starts readable, replaces its own layer effect and immediately drains on preference disable")
    }
    private static func object(_ url:URL)throws->[String:Any] {
        let data = try Data(contentsOf:url)
        guard data.count<=1<<20,let value = try JSONSerialization.jsonObject(with:data)as?[String:Any] else {throw UIVerification.Failure(message:"Bounded generated receipt missing")}
        return value
    }
    private static func wait(_ name:String,_ condition:()->Bool)async throws {
        let end = CACurrentMediaTime()+12
        while !condition() {try UIVerification.require(CACurrentMediaTime()<end,name);try await Task.sleep(for:.milliseconds(10))}
    }
}
#endif
