#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor final class SMBGeneratedRows: NSObject, NSTableViewDataSource {
    var entries: [SMBWorkerEntry] = []
    var firstDisplay: TimeInterval?
    let table = NSTableView()
    override init() {
        super.init(); table.dataSource = self
        for (key,title,width) in [("name","Name",280.0),("kind","Kind",160.0),("size","Size",120.0)] {
            let column = NSTableColumn(identifier: .init(key)); column.title=title; column.width=width; table.addTableColumn(column)
        }
        table.rowHeight=28; table.usesAlternatingRowBackgroundColors=true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard entries.indices.contains(row) else { return nil }; let item=entries[row]
        switch tableColumn?.identifier.rawValue {
        case "name": return item.name
        case "kind": return item.isDirectory ? "Remote folder" : "Remote file"
        default: return "\(item.logicalBytes) bytes"
        }
    }
    func append(_ page: SMBWorkerPage) {
        entries += page.entries; table.reloadData(); table.layoutSubtreeIfNeeded(); table.displayIfNeeded()
        if firstDisplay == nil { firstDisplay=ProcessInfo.processInfo.systemUptime }
    }
}

@MainActor enum SMBWorkerVerification {
    static func run(root: URL, run: Int, settings: BrowserSettings) async throws -> [String: Any] {
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require(root.deletingLastPathComponent()==repo.appendingPathComponent(".build/b10-network-reader")
            && root.resolvingSymlinksInPath()==root && UUID(uuidString:root.lastPathComponent) != nil
            && (0..<32).contains(run),"SMB worker review requires its exact generated packet")
        let evidence=root.appendingPathComponent("evidence")
        let planData=try Data(contentsOf:evidence.appendingPathComponent(String(format:"plan-%02d.json",run)))
        guard let plan=try JSONSerialization.jsonObject(with:planData) as? [String:String],
              let action=plan["action"], ["baseline","stop","disconnect","deadline"].contains(action) else {
            throw UIVerification.Failure(message:"Unknown SMB review action")
        }
        let rows=SMBGeneratedRows(), scroll=NSScrollView(frame:.init(x:0,y:0,width:620,height:320))
        scroll.hasVerticalScroller=true; scroll.documentView=rows.table
        let window=NSWindow(contentRect:.init(x:0,y:0,width:620,height:320),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="SMB worker · generated qualification"; window.isReleasedWhenClosed=false
        let content=NSViewController(); content.view=scroll; window.contentViewController=content
        ToolWindowChrome.install(in:window,settings:settings)
        window.setContentSize(.init(width:620,height:320))
        window.contentView?.layoutSubtreeIfNeeded()
        window.setFrameOrigin(.init(x:-12000,y:-12000)); window.orderFront(nil)
        defer { window.close() }
        let activity=FileActivityGate(maximumActivities:1)
        let began=ProcessInfo.processInfo.systemUptime
        var held: SMBWorkerSession?
        var closeResult: SMBWorkerCloseResult?
        var counts:[Int]=[]
        let operation=Task { @MainActor () -> String in
            do {
                let session=try await SMBWorkerSession.connectGenerated(bundleURL:Bundle.main.bundleURL,activity:activity)
                held=session
                counts.append(try await session.readGeneratedDirectory { page in
                    Task { @MainActor in
                        guard session.allowsPublication(page.readID) else { return }
                        rows.append(page)
                    }
                })
                if action=="baseline" {
                    try await wait { rows.entries.count==1 }
                    try require(rows.entries.first?.name=="One" && rows.entries.first?.logicalBytes==123,"Native first page metadata differs")
                    counts.append(try await session.readGeneratedDirectory(nested:true) { page in
                        Task { @MainActor in
                            guard session.allowsPublication(page.readID) else { return }
                            rows.append(page)
                        }
                    })
                    try await wait { rows.entries.count==2 }
                }
                closeResult=await session.close()
                return "complete"
            } catch let error as SMBWorkerFailure {
                if let held { closeResult=await held.close() }
                return error.rawValue
            } catch {
                if let held { closeResult=await held.close() }
                return "unexpected"
            }
        }
        if action=="stop" {
            let ready=evidence.appendingPathComponent(String(format:"ready-%02d.json",run))
            try await waitAsync { await Task.detached { FileManager.default.fileExists(atPath:ready.path) }.value }
            operation.cancel()
        }
        let outcome=await operation.value
        let elapsed=ProcessInfo.processInfo.systemUptime-began
        try require(activity.activeCount==0,"Native helper lifetime/lease did not actually drain")
        let expected=["baseline":"complete","stop":"stopped","disconnect":"remote","deadline":"deadline"][action]
        try require(outcome==expected,"Native helper outcome differs: \(outcome)")
        if let result=closeResult {
            try require(result.actualExit && result.localDrainProved && !result.forcedContainment,"Native close confused containment with graceful local drain")
        }
        if action=="baseline" {
            try require(counts==[1,1] && rows.entries.count==2,"Sequential native reads lost/duplicated a page")
            try require((rows.firstDisplay ?? began+2)-began<1,"Native first-page presentation exceeded one second")
            try await UIVerification.snapshot(window,to:evidence.appendingPathComponent("native-worker.png"))
        }
        return ["action":action,"outcome":outcome,"readCounts":counts,"displayedRows":rows.entries.count,
            "firstNativeDisplayMilliseconds":rows.firstDisplay.map { ($0-began)*1000 } ?? -1,
            "elapsedSeconds":elapsed,"activityAfterActualExit":activity.activeCount,
            "actualExit":closeResult?.actualExit ?? true,"localDrainProved":closeResult?.localDrainProved ?? true,
            "connectFailureEvidence":held == nil ? "Failed connect returned only after module drain; independent peer records socket EOF" : "not needed",
            "forcedContainment":closeResult?.forcedContainment ?? false]
    }
    private static func require(_ value: Bool,_ message: String) throws {
        if !value { throw UIVerification.Failure(message:message) }
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for:.milliseconds(10)) }
        throw UIVerification.Failure(message:"Native SMB presentation did not settle")
    }
    private static func waitAsync(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1200 { if await predicate() { return }; try await Task.sleep(for:.milliseconds(10)) }
        throw UIVerification.Failure(message:"Controlled peer never confirmed an in-flight request")
    }
}
#endif
