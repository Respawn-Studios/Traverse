#if DEBUG
import AppKit
@_spi(Qualification) @testable import LocalStorage

/// Real native fields/pages on generated challenges only; no worker/credential
/// backend is connected to this motion fixture.
@MainActor enum SFTPInteractiveVerification {
    struct Outcome {
        let controller:SFTPInteractiveWindowController
        let clips:[[String:Any]]
        let checks:[String:Any]
    }
    private enum Failure:Error { case generated }
    private actor ReviewDouble:SFTPAuthenticationReviewControl {
        nonisolated let review:SFTPHostChallenge
        private let expected:SFTPInteractiveChallenge
        private let holdCheck:Bool
        private var pending:CheckedContinuation<Void,Never>?
        private var released = false
        private var checked = 0,closed = 0
        init(review:SFTPHostChallenge,expected:SFTPInteractiveChallenge,holdCheck:Bool = false) {
            self.review = review;self.expected = expected;self.holdCheck = holdCheck
        }
        func approve(_ action:SFTPTrustAction) async throws { throw Failure.generated }
        func checkInteractiveChallenge(_ challenge:SFTPInteractiveChallenge) async throws {
            checked += 1
            guard challenge == expected,closed == 0 else { throw SFTPSessionFailure.stopped }
            if holdCheck && !released { await withCheckedContinuation { pending = $0 } }
            guard closed == 0 else { throw SFTPSessionFailure.stopped }
        }
        func close() async -> SFTPWorkerClose {
            closed += 1
            let waiting = pending;pending = nil;waiting?.resume()
            return .init(actualExit:true,exitStatus:0,ipcEOF:true,contained:false,
                protocolValid:true,terminal:nil,temporaryStoreRemoved:true)
        }
        func releaseCheck() { released = true;let waiting = pending;pending = nil;waiting?.resume() }
        func checkCount() -> Int { checked }
        func closeCount() -> Int { closed }
    }
    static func run(root:URL,settings:BrowserSettings) async throws -> Outcome {
        let session = UUID();var round:UInt8 = 1
        func challenge(_ round:UInt8,count:Int)->SFTPInteractiveChallenge {
            try! .init(session:session,round:round,host:"generated.example",port:22,name:"Generated verification",
                instructions:round % 2 == 0 ? "Confirm this connection with the second code." : "Enter the generated account and code. No server is connected.",
                prompts:(0..<count).map { try! .init(text:$0 == 0 && count > 1 ? "Account" : "One-time code",echo:$0 == 0 && count > 1) },responseSeconds:120)
        }
        func emptyRound(name:String = "",instructions:String = "",prompts:[SFTPInteractivePrompt] = []) throws -> SFTPInteractiveChallenge {
            try .init(session:session,round:1,host:"generated.example",port:22,name:name,
                instructions:instructions,prompts:prompts,responseSeconds:120)
        }
        guard SFTPSetupInteractive.isSilentEmptyRound(try emptyRound()),
              !SFTPSetupInteractive.isSilentEmptyRound(try emptyRound(name:"Announcement")),
              !SFTPSetupInteractive.isSilentEmptyRound(try emptyRound(instructions:" ")),
              !SFTPSetupInteractive.isSilentEmptyRound(try emptyRound(instructions:"Read this notice")),
              !SFTPSetupInteractive.isSilentEmptyRound(try emptyRound(prompts:[.init(text:"",echo:false)])) else {
            throw Failure.generated
        }
        let silent = try emptyRound()
        var keyBytes = Data()
        try SFTPWire.field(Data("ssh-ed25519".utf8),into:&keyBytes)
        try SFTPWire.field(Data(repeating:1,count:32),into:&keyBytes)
        let key = try SFTPHostKey(keyBytes)
        let host = SFTPHostChallenge(session:session,host:"generated.example",port:22,current:key,previous:nil)
        let automatic = SFTPSetupInteractive();try automatic.beginConnection()
        let responding = ReviewDouble(review:host,expected:silent)
        let answer = await automatic.review(responding,challenge:silent,settings:settings,owner:nil)
        guard answer != nil,automatic.controller == nil,await responding.checkCount() == 1,
              await responding.closeCount() == 0,await automatic.dismissAuthenticated(),
              await automatic.closeAndDrain() else { throw Failure.generated }
        let cancelling = SFTPSetupInteractive();try cancelling.beginConnection()
        let held = ReviewDouble(review:host,expected:silent,holdCheck:true)
        let pendingReview = Task { await cancelling.review(held,challenge:silent,settings:settings,owner:nil) }
        let until = ProcessInfo.processInfo.systemUptime + 3
        while await held.checkCount() == 0 {
            if ProcessInfo.processInfo.systemUptime >= until {
                pendingReview.cancel();await held.releaseCheck();_ = await pendingReview.value;throw Failure.generated
            }
            try await Task.sleep(for:.milliseconds(10))
        }
        pendingReview.cancel()
        let cancelUntil = ProcessInfo.processInfo.systemUptime + 3
        while !cancelling.stopped {
            if ProcessInfo.processInfo.systemUptime >= cancelUntil {
                await held.releaseCheck();_ = await pendingReview.value;throw Failure.generated
            }
            try await Task.sleep(for:.milliseconds(10))
        }
        await held.releaseCheck()
        let cancelled = await pendingReview.value
        guard cancelled == nil,cancelling.controller == nil,cancelling.lastClosure?.localResourcesEnded == true,
              await held.closeCount() == 1,await cancelling.closeAndDrain() else { throw Failure.generated }
        var submits = 0,cancels = 0
        let model = SFTPInteractiveModel(challenge:challenge(round,count:2))
        model.onSubmit = { value in
            guard !String(reflecting:value).contains("generated-code") else { return }
            submits += 1
        }
        model.onCancel = { cancels += 1;model.closing() }
        let controller = SFTPInteractiveWindowController(settings:settings,model:model)
        guard let window = controller.window else { throw Failure.generated }
        window.title = "Server prompts · generated review · motion audit"
        window.setContentSize(.init(width:660,height:570));controller.present(relativeTo:nil)
        NSApplication.shared.activate(ignoringOtherApps:true)
        var clips:[[String:Any]] = []
        for index in 0..<4 {
            try await Task.sleep(for:.milliseconds(250))
            guard let field = fields(window).first(where:{$0 is NSSecureTextField}),
                  window.makeFirstResponder(field),let editor = field.currentEditor() as? NSTextView else { throw Failure.generated }
            editor.insertText("generated-code",replacementRange:NSRange(location:0,length:0))
            guard field.stringValue == "generated-code",model.answers.last == "generated-code" else { throw Failure.generated }
            model.submit()
            guard model.phase == .submitting,model.answers.allSatisfy(\.isEmpty),window.isVisible else { throw Failure.generated }
            round += 1;let next = challenge(round,count:round % 2 == 0 ? 1 : 2),label = "ssh-prompt-round-\(index)"
            let report = try await NativeMotionRecorder.record(window:window,root:root,label:label,sampling:.diagnostic(for:window)) { model.install(next) }
            guard let secure = fields(window).first(where:{$0 is NSSecureTextField}),secure.stringValue.isEmpty,
                  model.answers.count == next.prompts.count else { throw Failure.generated }
            clips.append(DevelopmentMotionVerification.clip(label,report:report,field:secure,window:window))
            try JSONEncoder().encode(report).write(to:root.appendingPathComponent("evidence/\(label).json"),options:.withoutOverwriting)
        }
        var now = 0.0
        let expiry = SFTPInteractiveModel(challenge:challenge(1,count:0),now:{now});expiry.onCancel = { cancels += 1;expiry.closing() }
        now = 121;expiry.tick();guard expiry.phase == .closing,cancels == 1,submits == 4 else { throw Failure.generated }
        controller.permitsClose = true
        return .init(controller:controller,clips:clips,checks:["nativeSecureTyping":true,"differentPromptCounts":true,
            "answersClearedBeforeNextRound":true,"oneWindowAcrossRounds":true,"emptyChallengeExpiry":true,
            "strictEmptyRoundOnly":true,"silentRoundAutomaticallyAnswered":true,"silentRoundCancellationDrained":true,
            "announcementsAndPromptsRemainVisible":true,
            "submissions":submits,"networkRequests":0,"keychainCalls":0])
    }
    private static func fields(_ window:NSWindow)->[NSTextField] {
        func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
        guard let content = window.contentView else { return [] };return descendants(content).compactMap{$0 as? NSTextField}
    }
}
#endif
