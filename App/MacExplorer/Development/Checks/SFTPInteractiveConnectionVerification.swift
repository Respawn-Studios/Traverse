#if DEBUG
import AppKit
import Darwin
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum SFTPInteractiveConnectionVerification {
    private enum Failure:Error { case scope,check(UInt) }
    private final class Count:@unchecked Sendable {
        private let lock = NSLock();private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value:Int { lock.withLock { count } }
    }
    private static func require(_ value:Bool,line:UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate:()->Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < deadline);try await Task.sleep(for:.milliseconds(10)) }
    }
    static func run() async {
        var root:URL?,stage = "scope",form:SMBConnectWindowController?,active:SFTPBrowserSession?,coordinator:SFTPConnectionCoordinator?
        let trust = SFTPSetupTrust(),prompts = SFTPSetupInteractive(),calls = Count()
        var ticker:Task<Void,Never>?,maximumGap = 0.0,lastTick = ProcessInfo.processInfo.systemUptime
        do {
            let args = ProcessInfo.processInfo.arguments
            func value(_ name:String)throws->String {
                guard let index = args.firstIndex(of:name),args.indices.contains(index+1) else { throw Failure.scope };return args[index+1]
            }
            guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let location = URL(fileURLWithPath:path)
            let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:location.appendingPathComponent("reservation.json"))) as? [String:Any]
            try require(location.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && location.resolvingSymlinksInPath() == location && UUID(uuidString:location.lastPathComponent)?.uuidString == location.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "ssh-native-interactive"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
            root = location
            guard let port = UInt16(try value("--generated-port")),port > 0 else { throw Failure.scope }
            let fingerprint = try value("--generated-fingerprint"),method = try value("--generated-auth-method"),action = try value("--generated-action")
            try require(["interactive","key"].contains(method) && ["complete","cancel","between-rounds-close","frozen-worker-close"].contains(action))
            let independent = args.contains("--independent-openssh")
            let settings = BrowserSettings(persist:false);settings.appearance = .dark;settings.navigationStyle = .glass;settings.glassFileContent = true
            InterfacePresentation.shared.bind(settings)
            let storage = try SMBTemporaryStorage(directory:location.appendingPathComponent("state/Native/catalogs"))
            let activity = FileActivityGate(),pool = SMBTemporaryCatalogPool(storage:storage)
            let state = SFTPRememberedState(settings:.init(directory:location.appendingPathComponent("state/Native/settings")),
                passwords:.refusingQualification { calls.increment() })
            let connection = SFTPConnectionCoordinator(bundleURL:Bundle.main.bundleURL,storage:storage,remembered:state,activity:activity);coordinator = connection
            try prompts.beginConnection()
            let window = SMBConnectWindowController(settings:settings) { _,_ in throw Failure.scope };form = window
            let model = window.model;model.profileFeaturesAvailable = true;model.serverPromptsAvailable = true
            model.sftpHandler = { submission,_ in
                guard let authentication = submission.authentication else { throw Failure.scope }
                let outcome:SFTPConnectionOutcome
                do {
                    outcome = try await connection.connect(submission.draft,authentication:authentication,savedServerID:nil,
                        rememberServer:true,rememberPassword:false,profileFeatures:true,
                        serverPrompts:{ session,challenge in await prompts.review(session,challenge:challenge,settings:settings,owner:window.window) },
                        review:{ session,remembered in await trust.review(session,remembered:remembered,settings:settings,owner:window.window) })
                    guard await prompts.dismissAuthenticated() else { _ = await outcome.session.close();throw SFTPSessionFailure.stopped }
                } catch { _ = await prompts.closeAndDrain();throw error }
                active = outcome.session
                return .init(server:outcome.remembering.server == .complete ? .saved : .incomplete,password:.notRequested,
                    host:outcome.remembering.host == .complete ? .saved : .notRequested,
                    keyAccess:outcome.remembering.keyAccess == .incomplete ? .incomplete : outcome.remembering.keyAccess == .complete ? .saved : .notRequested,
                    open:{},discard:{await outcome.session.close().localResourcesEnded})
            }
            model.onConnected = {};model.onCancelled = {};model.connectionProtocol = .sftp
            model.address = "sftp://127.0.0.1:\(port)";model.account = "generated";model.name = "Generated interactive server";model.rememberServer = true
            if method == "key" {
                model.sftpAuthentication = .keyFile;model.extraServerPrompts = true
                model.useSSHKey(location.appendingPathComponent("source/client-key"))
                model.keyPassphrase = "generated-only-not-a-secret";model.rememberKeyAccess = true
            } else { model.sftpAuthentication = .serverPrompts }
            window.present();NSApplication.shared.activate(ignoringOtherApps:true)
            ticker = Task {
                while !Task.isCancelled { let now = ProcessInfo.processInfo.systemUptime;maximumGap = max(maximumGap,now-lastTick);lastTick = now
                    do { try await Task.sleep(for:.milliseconds(10)) } catch { return } }
            }
            stage = "host";model.connect();try await wait { trust.controller != nil || !model.busy }
            guard let review = trust.controller else { throw Failure.scope }
            try require(review.model.review.fingerprint == fingerprint);review.model.rememberKey = true;review.model.proceed()
            stage = "first-prompt";try await wait { prompts.controller?.model.phase == .input || !model.busy }
            try await wait { prompts.controller.map { fieldsReady($0) } == true || !model.busy }
            guard let first = prompts.controller,let firstWindow = first.window else { throw Failure.scope }
            let number = firstWindow.windowNumber
            try require(first.model.challenge.round == 1 && (independent ? first.model.challenge.prompts.count <= 1 : first.model.challenge.prompts.count == 2) && model.keyPassphrase.isEmpty)
            if action == "cancel" { firstWindow.performClose(nil) }
            else if action == "frozen-worker-close" {
                stage = "freeze-ready"
                try JSONSerialization.data(withJSONObject:["nativePID":ProcessInfo.processInfo.processIdentifier,"generatedCase":location.lastPathComponent])
                    .write(to:location.appendingPathComponent("evidence/native-freeze-ready.json"),options:.withoutOverwriting)
                let acknowledgement = location.appendingPathComponent("evidence/native-freeze-ack.json")
                try await wait { FileManager().fileExists(atPath:acknowledgement.path) }
                let frozen = try JSONSerialization.jsonObject(with:Data(contentsOf:acknowledgement)) as? [String:Any]
                try require(frozen?["nativePID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) && frozen?["generatedCase"] as? String == location.lastPathComponent && frozen?["stopped"] as? Bool == true)
                firstWindow.performClose(nil)
            }
            else {
                for (index,prompt) in first.model.challenge.prompts.enumerated() {
                    let text = independent ? "123456" : prompt.echo ? "generated" : "123456"
                    try enterResponse(text,at:index,in:first)
                }
                if action == "between-rounds-close" { first.model.submit();firstWindow.performClose(nil) }
                else {
                    stage = "first-submit"
                    try pressReturn(firstWindow);try await wait { first.model.phase != .input }
                    if !independent {
                        stage = "second-prompt";try await wait { first.model.challenge.round == 2 && first.model.phase == .input || !model.busy }
                        try require(model.busy && first.window?.windowNumber == number && first.model.answers == [""])
                        try await wait { fieldsReady(first) }
                        try enterResponse("654321",at:0,in:first);try pressReturn(firstWindow)
                    } else {
                        // Only exactly silent empty rounds auto-answer. A
                        // displayed announcement or prompt still needs Continue.
                        for round in 2...8 {
                            try await wait { !model.busy || first.model.challenge.round >= UInt8(round) && first.model.phase == .input }
                            if !model.busy { break }
                            try require(first.window?.windowNumber == number && first.model.challenge.prompts.count <= 1)
                            if first.model.challenge.round > UInt8(round) { continue }
                            try await wait { fieldsReady(first) }
                            for index in first.model.challenge.prompts.indices { try enterResponse("123456",at:index,in:first) }
                            try pressReturn(firstWindow);try await wait { first.model.phase != .input }
                        }
                    }
                }
            }
            stage = "result";try await wait { !model.busy }
            try require(calls.value == 0)
            var rows = 0
            if action == "complete" {
                try require(model.connected && !model.rememberingIncomplete && prompts.controller == nil)
                guard let session = active else { throw Failure.scope }
                _ = try await session.navigate(pathUTF8:Data((independent ? "/fixture" : "/generated").utf8))
                try await wait { session.latest.snapshot?.state == .complete };let page = try await session.page(offset:0);rows = page.rows.count
                let names = Set(page.rows.map{$0.entry.name.displayName})
                try require(names == Set(independent ? ["Folder","Generated.txt"] : ["Generated first.txt","Generated second.txt"]))
                let saved = try await state.inspect();let item = saved?.visibleServers.first
                try require(saved?.visibleServers.count == 1 && saved?.credentials.isEmpty == true)
                if method == "key" { try require(item?.keyAuthentication?.requiresServerPrompts == true && item?.keyAuthentication?.reference != nil) }
                else { try require(item?.usesServerPrompts == true && item?.keyAuthentication == nil) }
                let ended = await session.close();active = nil;try require(ended.localResourcesEnded && ended.temporaryStoreRemoved == true)
            } else { try require(!model.connected && prompts.controller == nil && prompts.stopped) }
            stage = "forget";let forgotten = await state.forget(.all);try require(forgotten.server == .complete)
            await connection.drain();coordinator = nil
            let stores = try await pool.inspect()
            let frozen = action == "frozen-worker-close"
            try require((frozen ? stores.count == 1 : stores.isEmpty) && activity.activeCount == 0 && calls.value == 0)
            if frozen {
                try require(prompts.lastClosure?.localResourcesEnded == true && prompts.lastClosure?.contained == true
                    && prompts.lastClosure?.terminal == nil
                    && prompts.lastClosure?.temporaryStoreRemoved == false
                    && (prompts.lastClosure?.exitStatus == -SIGTERM || prompts.lastClosure?.exitStatus == -SIGKILL)
                    && (prompts.lastClosure?.drainElapsedSeconds ?? 0) >= 1.2 && (prompts.lastClosure?.drainElapsedSeconds ?? 4) < 3)
            }
            ticker?.cancel();await ticker?.value;ticker = nil;try require(maximumGap < 0.5)
            let report:[String:Any] = ["passed":true,"method":method,"action":action,"nativeSecureTyping":action != "cancel" && !frozen,
                "nativeReturnKey":action == "complete","oneWindowAcrossRounds":!independent && action == "complete",
                "keychainCalls":calls.value,"rows":rows,"allChildrenEnded":true,"allChildrenAndCatalogsDrained":!frozen,"catalogRetainedForReview":frozen,"maximumMainActorGapSeconds":maximumGap,
                "formatThreeMethodRemembered":action == "complete","forgetCompleted":true,"independentOpenSSH":independent,
                "closeDrainSeconds":prompts.lastClosure?.drainElapsedSeconds ?? 0,"closeRequiredContainment":prompts.lastClosure?.contained ?? false]
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:location.appendingPathComponent("evidence/native-interactive.json"),options:.withoutOverwriting)
        } catch {
            if let active { _ = await active.close() };_ = await prompts.closeAndDrain();_ = await trust.closeAndDrain();await coordinator?.drain()
            ticker?.cancel();await ticker?.value
            var line:UInt = 0;if case let Failure.check(found) = error { line = found }
            let closure:[String:Any] = prompts.lastClosure.map { ["actualExit":$0.actualExit,"ipcEOF":$0.ipcEOF,"contained":$0.contained,
                "protocolValid":$0.protocolValid,"temporaryStoreRemoved":$0.temporaryStoreRemoved == true,"terminalOutcome":Int($0.terminal?.outcome ?? 255),
                "writerEnd":Int($0.terminal?.catalogWriterEnd?.rawValue ?? 255),"drainSeconds":$0.drainElapsedSeconds,"exitStatus":$0.exitStatus ?? 255] } ?? [:]
            if let root { try? JSONSerialization.data(withJSONObject:["passed":false,"stage":stage,"checkLine":line,"closure":closure,
                "errorType":String(reflecting:type(of:error)),"generatedFormMessage":form?.model.message ?? "","keychainCalls":calls.value,
                "maximumMainActorGapSeconds":maximumGap]).write(to:root.appendingPathComponent("evidence/native-interactive.json"),options:.withoutOverwriting) }
        }
        form?.model.sftpHandler = nil;form?.close();NSApplication.shared.terminate(nil)
    }
    static func fieldsReady(_ controller:SFTPInteractiveWindowController)->Bool {
        guard let view = controller.window?.contentView else { return false }
        func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
        let fields = descendants(view).compactMap{$0 as? NSTextField}.filter{$0.placeholderString == "Response"}
        return fields.count == controller.model.challenge.prompts.count && fields.allSatisfy(\.isEnabled)
    }
    static func enterResponse(_ value:String,at index:Int,in controller:SFTPInteractiveWindowController)throws {
        guard let window = controller.window else { throw Failure.scope }
        func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
        guard let view = window.contentView else { throw Failure.scope }
        let echo = controller.model.challenge.prompts[index].echo
        let candidates = descendants(view).compactMap{$0 as? NSTextField}.filter{$0.placeholderString == "Response" && (($0 is NSSecureTextField) != echo)}
        guard let field = candidates.first,window.makeFirstResponder(field),let editor = field.currentEditor() as? NSTextView else { throw Failure.scope }
        editor.insertText(value,replacementRange:NSRange(location:0,length:0));try require(controller.model.answers[index] == value)
    }
    static func pressReturn(_ window:NSWindow)throws {
        guard let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
            windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36) else { throw Failure.scope }
        try require(window.performKeyEquivalent(with:event))
    }
}
#endif
