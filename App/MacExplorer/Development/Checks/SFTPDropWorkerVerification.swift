#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Current signed parent/worker and independently implemented OpenSSH server.
/// Test-only generated challenge answers; no Keychain or personal endpoint.
@MainActor enum SFTPDropWorkerVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool, _ line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(30)
        while !predicate() { try require(.now < end, line); try await Task.sleep(for: .milliseconds(5)) }
    }
    static func run() async {
        var root: URL?, browser: BrowserViewController?, window: NSWindow?, tab: SFTPTabController?, setup: SFTPConnectionCoordinator?
        var observer: Task<Bool, Error>?, ticker: Task<Void, Never>?, close: SFTPWorkerClose?
        var failure: UInt?, kind: String?, code: Int64?, phase = "scope", checks: [String] = []
        var history: SFTPUploadStorage?, recorder: DiagnosticRecorder?, poolEmpty = false, stopSeconds: Double?, gap = 0.0
        let activity = FileActivityGate(), calls = Calls()
        SFTPDropUploadFeature.qualifying = true; SFTPFolderUploadFeature.qualifying = true
        defer { SFTPDropUploadFeature.qualifying = false; SFTPFolderUploadFeature.qualifying = false }
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let area = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String:Any]
            func argument(_ flag: String) throws -> String {
                let args = ProcessInfo.processInfo.arguments
                guard let at = args.firstIndex(of: flag), args.indices.contains(at + 1) else { throw Failure.scope }; return args[at + 1]
            }
            guard area.resolvingSymlinksInPath() == area, area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
                  marker?["action"] as? String == "native-sftp-drop-worker", Bundle.main.bundleIdentifier == "local.macexplorer.development",
                  let port = UInt16(try argument("--generated-port")), port > 0 else { throw Failure.scope }
            root = area
            let scenario = try argument("--generated-scenario"), fingerprint = try argument("--generated-fingerprint")
            try require(["success","conflict","stop","disconnect"].contains(scenario))
            let destination = scenario == "success" ? "/fixture/Uploads/Prompts/Native" : scenario == "conflict" ? "/fixture/Uploads/MFA" : "/fixture/Uploads/Prompts"
            let second = scenario == "conflict" ? "Conflict" : scenario == "stop" ? "Stopped Folder" : scenario == "disconnect" ? "Disconnected Folder" : "Folder"
            let first = scenario == "stop" ? "Stopped First.txt" : scenario == "disconnect" ? "Disconnected First.txt" : "First.txt"
            let urls = [first,second,"Last.txt"].map { area.appendingPathComponent("source/Local/" + $0) }
            let logger = DiagnosticRecorder(directory: area.appendingPathComponent("state/diagnostics"), limits: try .init(bytes:128 << 10,segmentBytes:16 << 10),recording:true)
            recorder = logger; ApplicationDiagnostics.shared.configureForVerification(logger)
            let settings = BrowserSettings(persist:false); settings.autoRefreshFolders=false; settings.folderSummariesEnabled=false; settings.reviewsRecoveryAtStartup=false
            settings.navigationStyle = .glass; settings.glassFileContent=true; settings.appearance = .dark
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserViewController(settings:settings); browser=owner; owner.permitsBackgroundVerification=true; owner.readVolumesForVerification={ [] }
            let host = NSWindow(contentRect:.init(x:160,y:150,width:1000,height:640),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window=host; host.isReleasedWhenClosed=false; host.contentViewController=owner; host.title="SFTP worker group · generated review"; host.makeKeyAndOrderFront(nil)
            let catalogs = try SMBTemporaryStorage(directory:area.appendingPathComponent("state/catalogs")), state = SFTPRememberedState(settings:.init(directory:area.appendingPathComponent("state/servers")),passwords:.refusingQualification { calls.increment() })
            let coordinator = SFTPConnectionCoordinator(bundleURL:Bundle.main.bundleURL,storage:catalogs,remembered:state,activity:activity,requestedDownloads:true,requestedFolderDownloads:true)
            setup=coordinator
            var previous=ProcessInfo.processInfo.systemUptime
            ticker=Task { while !Task.isCancelled {
                let now=ProcessInfo.processInfo.systemUptime; gap=max(gap,now-previous); previous=now
                do { try await Task.sleep(for:.milliseconds(10)) } catch { return }
            } }
            phase="authenticate"
            let address = try SFTPConnectionAddress(server:"127.0.0.1",port:port,startingFolder:destination)
            let outcome = try await coordinator.connect(.init(name:"Generated group",address:address,account:"generated"),authentication:.serverPrompts,savedServerID:nil,
                rememberServer:false,rememberPassword:false,freshUploads:true,freshFolderUploads:true,
                serverPrompts:{ _,challenge in try? .init(challenge.prompts.map { _ in "123456" }) },
                review:{ worker,_ in
                    guard worker.review.current.fingerprint == fingerprint, worker.review.kind == .first else { return .init(verified:false) }
                    do { try await worker.approve(.connectOnce); return .init(verified:true) } catch { return .init(verified:false) }
                })
            let storage=SFTPUploadStorage(directory:area.appendingPathComponent("state/upload-history")); history=storage
            let remote=SFTPTabController(session:outcome.session,address:address,title:"Generated OpenSSH",uploads:storage,reviewsUploads:false); tab=remote
            owner.installSFTPTab(remote)
            try await wait { remote.rows.cache.snapshot?.state == .complete && !remote.hasPendingPages }
            try require(owner.sftpDropUpload.canRequest(from:remote) && calls.count == 0)
            checks.append("Exact signed worker authenticated against the generated independent host and captured a complete destination")
            phase="group-upload"
            if scenario == "stop" || scenario == "disconnect" {
                observer=Task {
                    let end=ContinuousClock.now + .seconds(20)
                    while true {
                        try Task.checkCancellation(); try require(.now < end)
                        let snapshot=try await storage.inspect()
                        if snapshot.records.contains(where:{ $0.folder?.rootAcknowledged == true && $0.active }) { break }
                        try await Task.sleep(for:.milliseconds(5))
                    }
                    try await Task.detached { try Data("Generated root acknowledged\n".utf8).write(to:area.appendingPathComponent("state/Pause.ready"),options:.withoutOverwriting) }.value
                    let began=ProcessInfo.processInfo.systemUptime
                    try await wait { FileManager().fileExists(atPath:area.appendingPathComponent("state/Paused.control").path) }
                    // A disconnected transport may finish before this observer
                    // resumes. Only Stop requires a still-active user command.
                    if scenario == "stop" { try require(owner.sftpDropUpload.work != nil); owner.cancelFileOperation(nil) }
                    try await wait { owner.sftpDropUpload.work == nil }
                    stopSeconds=ProcessInfo.processInfo.systemUptime-began
                    return true
                }
            }
            let source=LocalFileDropSource(key:.init(sequence:1,board:.init("traverse.generated.worker."+area.lastPathComponent),changeCount:1),urls:urls,access:.init(leases:[]))
            try require(owner.sftpDropUpload.request(source,owner:remote))
            try await wait { owner.sftpDropUpload.work == nil }
            if let observer { try require(try await observer.value) }
            observer=nil
            let records=try await storage.inspect()
            if scenario == "success" {
                try require(owner.sftpDropUpload.lastCompleted?.completed.count == 3 && records.records.count == 3
                    && records.records.allSatisfy { !$0.active && $0.outcome == .verified })
                try require(records.records.filter { $0.folder != nil }.count == 1)
                checks.append("Actual G-H-G commands share one captured generation and all three durable outcomes verify")
            } else {
                guard let partial=owner.sftpDropUpload.lastInterruption else { throw Failure.scope }
                try require(partial.completed.count == 1 && partial.notSubmitted == 1 && partial.currentMayHaveStarted && records.records.count == 2
                    && records.records.allSatisfy { !$0.active } && records.records.filter { $0.outcome == .verified }.count == 1)
                try require(records.records.first(where:{ $0.id == partial.completed[0].id })?.outcome == .verified)
                if scenario == "conflict" { try require((partial.cause as? SFTPFolderUploadInterruption)?.rootMayExist == false) }
                else { try require(records.records.first(where:{ $0.folder != nil })?.folder?.rootAcknowledged == true && stopSeconds != nil && stopSeconds! < 3) }
                checks.append("The verified first root stays exact, the interrupted second stays reviewable, and the last has no command or history record")
            }
            phase="drain"
            close=await remote.close().value; await coordinator.drain()
            try require(close?.localResourcesEnded == true && close?.contained == false && close?.temporaryStoreRemoved == true
                && close?.terminal?.tasksAfterRuntimeDrop == 0 && close?.terminal?.catalogWriterEnd == .closed && activity.activeCount == 0 && calls.count == 0)
            poolEmpty=try await SMBTemporaryCatalogPool(storage:catalogs).inspect().isEmpty; try require(poolEmpty)
            checks.append("Actual worker exit, IPC EOF, catalog/writer cleanup and source/history work drain before completion")
            try require(await storage.close())
            let cold=try await SFTPUploadStorage(directory:area.appendingPathComponent("state/upload-history")).inspect()
            try require(cold.records.map(\.id) == records.records.map(\.id) && cold.records.allSatisfy { !$0.active })
            checks.append("Cold local outcome inspection retains the same verified/uncertain prefix without inventing batch resume")
            await logger.flush()
            let logged=try await logger.page(limit:256).events
            let encoded=try JSONEncoder().encode(logged), text=String(decoding:encoded,as:UTF8.self)
            try require(!text.contains(area.path) && !text.contains(first) && !text.contains(second) && !text.contains("123456"))
            try encoded.write(to:area.appendingPathComponent("evidence/generated-transfer-diagnostics.json"),options:.withoutOverwriting)
            checks.append("Transfer diagnostic events retain technical causes/counts without generated paths, names or challenge answers")
            ticker?.cancel(); await ticker?.value; ticker=nil; try require(gap < 0.5)
        } catch {
            if case let Failure.check(line)=error { failure=line } else { failure=0 }
            kind=String(reflecting:type(of:error)); code=DiagnosticErrors.project(error).code
        }
        browser?.cancelFileOperation(nil); await browser?.operationTask?.value; await browser?.operationPreparationTask?.value
        observer?.cancel(); _=try? await observer?.value
        if let tab { close=await tab.close().value }; await setup?.drain()
        ticker?.cancel(); await ticker?.value; _=await history?.close()
        await recorder?.closeAndDrain(); ApplicationDiagnostics.shared.configureForVerification(nil)
        browser?.suspendBrowser(); window?.close()
        if let root {
            let report:[String:Any] = ["passed":failure == nil,"checks":checks,"phase":phase,"line":failure.map { $0 as Any } ?? NSNull(),"failureType":kind.map { $0 as Any } ?? NSNull(),"errorCode":code.map { $0 as Any } ?? NSNull(),
                "actualExit":close?.actualExit ?? false,"exitStatus":close?.exitStatus.map { $0 as Any } ?? NSNull(),"ipcEOF":close?.ipcEOF ?? false,"contained":close?.contained ?? false,"catalogRemoved":close?.temporaryStoreRemoved ?? false,
                "poolEmpty":poolEmpty,"activityDrained":activity.activeCount == 0,"keychainCalls":calls.count,"stopSeconds":stopSeconds.map { $0 as Any } ?? NSNull(),"maximumMainActorGapSeconds":gap,"physicalInputExercised":false]
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/native-sftp-drop-worker.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
}
#endif
