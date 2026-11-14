import AppKit
import Combine
import SwiftUI
@_spi(Qualification) import LocalStorage

enum SFTPInteractiveFeature { static let available = true }

@MainActor final class SFTPInteractiveModel: ObservableObject {
    enum Phase { case input, submitting, closing, uncertain, ended }
    @Published private(set) var challenge: SFTPInteractiveChallenge
    @Published var answers: [String]
    @Published private(set) var phase: Phase = .input
    @Published private(set) var remaining: Int
    @Published private(set) var message = ""
    var onSubmit: ((SFTPInteractiveAnswers) -> Void)?
    var onCancel: (() -> Void)?
    private let now: () -> TimeInterval
    private var expires: TimeInterval
    init(challenge: SFTPInteractiveChallenge, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.challenge = challenge; self.now = now; expires = now() + Double(challenge.responseSeconds)
        answers = Array(repeating:"",count:challenge.prompts.count); remaining = Int(challenge.responseSeconds)
    }
    func install(_ challenge: SFTPInteractiveChallenge) {
        self.challenge = challenge; answers = Array(repeating:"",count:challenge.prompts.count)
        expires = now() + Double(challenge.responseSeconds); remaining = Int(challenge.responseSeconds); message = ""; phase = .input
    }
    func submit() {
        tick(); guard phase == .input else { return }
        do {
            let response = try SFTPInteractiveAnswers(answers)
            answers = Array(repeating:"",count:challenge.prompts.count); phase = .submitting; message = "Checking your response…"
            onSubmit?(response)
        } catch { message = "That response is too long or contains an unsupported character. Use the answer requested by this server." }
    }
    func cancel() { guard phase != .ended && phase != .closing else { return }; onCancel?() }
    func closing() { answers = Array(repeating:"",count:challenge.prompts.count); phase = .closing; message = "Closing this connection…" }
    func uncertain() { phase = .uncertain; message = "Connection closure needs another check. Try closing again; this connection remains reserved." }
    func ended() { answers = Array(repeating:"",count:challenge.prompts.count); phase = .ended }
    func tick() {
        guard phase == .input else { return }; remaining = max(0,Int(ceil(expires-now())))
        if remaining == 0 { cancel() }
    }
}

@MainActor private struct SFTPInteractiveForm: View {
    @ObservedObject var model: SFTPInteractiveModel
    @ObservedObject var settings: BrowserSettings
    @Environment(\.colorScheme) private var systemColorScheme
    @FocusState private var focused: Int?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:12) {
                Image(systemName:"lock.shield").interfaceFont(.system(size:28)).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:4) {
                    Text("Finish signing in").interfaceFont(.title2.weight(.semibold))
                    Text(verbatim:model.challenge.host + (model.challenge.port == 22 ? "" : ":\(model.challenge.port)"))
                        .interfaceFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Label("Server verified",systemImage:"checkmark.shield").interfaceFont(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    if !model.challenge.name.isEmpty {
                        Text(verbatim:SFTPInteractiveChallenge.displayText(model.challenge.name)).interfaceFont(.headline)
                    }
                    if !model.challenge.instructions.isEmpty {
                        Text(verbatim:SFTPInteractiveChallenge.displayText(model.challenge.instructions)).interfaceFont(.callout)
                            .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                    }
                    ForEach(Array(model.challenge.prompts.enumerated()),id:\.offset) { index,prompt in
                        let title = prompt.text.isEmpty ? "Response" : SFTPInteractiveChallenge.displayText(prompt.text)
                        VStack(alignment:.leading,spacing:7) {
                            Text(verbatim:title).interfaceFont(.callout).fixedSize(horizontal:false,vertical:true)
                            if prompt.echo {
                                TextField("Response",text:answer(index,round:model.challenge.id)).focused($focused,equals:index).accessibilityLabel(title)
                            } else {
                                SecureField("Response",text:answer(index,round:model.challenge.id)).focused($focused,equals:index).accessibilityLabel(title)
                                    .textContentType(.oneTimeCode)
                            }
                        }
                    }
                    if model.challenge.prompts.isEmpty {
                        Text("The server is ready for your confirmation. Choose Continue to proceed.").interfaceFont(.callout).foregroundStyle(.secondary)
                    }
                }.id(model.challenge.id).textFieldStyle(ToolTextEntryStyle()).disabled(model.phase != .input)
                    .padding(15).frame(maxWidth:.infinity,alignment:.leading)
                    .background(.quaternary.opacity(0.25),in:RoundedRectangle(cornerRadius:12))
            }.scrollBounceBehavior(.basedOnSize)
            Text("Only enter credentials for this server. Never enter your Mac login password here. Answers aren’t saved.")
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack(spacing:8) {
                if model.phase == .submitting || model.phase == .closing { ProgressView().controlSize(.small) }
                Text(model.message).interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.frame(minHeight:24,alignment:.leading)
            HStack {
                Text(model.phase == .input && model.remaining <= 30 ? "Expires in \(model.remaining)s" : "Encrypted SFTP connection")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.phase == .uncertain ? "Try Closing Again" : "Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction).disabled(model.phase == .closing || model.phase == .ended)
                Button("Continue") { model.submit() }.keyboardShortcut(.defaultAction).disabled(model.phase != .input)
            }
        }.padding(22)
            .toolPageCrossfade(model.challenge.id,motion:settings.motion)
            .environment(\.colorScheme,settings.appearance == .system ? systemColorScheme : settings.appearance == .dark ? .dark : .light)
            .onAppear { focused = model.challenge.prompts.isEmpty ? nil : 0 }
            .onChange(of:model.challenge.id) { _,_ in focused = model.challenge.prompts.isEmpty ? nil : 0 }
            .task { while !Task.isCancelled && model.phase != .ended { model.tick(); try? await Task.sleep(for:.milliseconds(250)) } }
    }
    private func answer(_ index:Int,round:String)->Binding<String> {
        Binding(get:{ model.challenge.id == round && model.answers.indices.contains(index) ? model.answers[index] : "" },
            set:{ value in
                guard model.phase == .input,model.challenge.id == round,model.answers.indices.contains(index) else { return }
                model.answers[index] = value
            })
    }
}

@MainActor final class SFTPInteractiveWindowController: NSWindowController,NSWindowDelegate {
    let model: SFTPInteractiveModel
    var permitsClose = false
    init(settings: BrowserSettings,model: SFTPInteractiveModel) {
        self.model = model
        let window = ToolWindowChrome.makeWindow(title: "Sign in to Server",
            size: .init(width:600,height:480), minimumSize: .zero, styleMask:[.titled,.closable,.resizable])
        window.contentMinSize = .init(width:540,height:380)
        super.init(window:window); window.delegate = self
        let host = InterfaceHostingController(rootView:SFTPInteractiveForm(model:model,settings:settings)); host.sizingOptions = []
        window.contentViewController = host; ToolWindowChrome.install(in:window,settings:settings); window.setContentSize(.init(width:600,height:480))
    }
    required init?(coder:NSCoder) { nil }
    func present(relativeTo owner:NSWindow?) {
        guard let window else { return }
        ToolWindowChrome.position(window, relativeTo:owner)
        showWindow(nil);window.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender:NSWindow)->Bool { if permitsClose { return true };model.cancel();return false }
}

/// One continuation and one serial liveness check span all server rounds. The
/// window stays visible while the next reply is in flight; closing always stops
/// the connection, including the gap between two challenge callbacks.
@MainActor final class SFTPSetupInteractive {
    static func isSilentEmptyRound(_ challenge:SFTPInteractiveChallenge)->Bool {
        challenge.prompts.isEmpty && challenge.name.isEmpty && challenge.instructions.isEmpty
    }
    private(set) var controller:SFTPInteractiveWindowController?
    private var continuation:CheckedContinuation<SFTPInteractiveAnswers?,Never>?
    private var session:(any SFTPAuthenticationReviewControl)?
    private var monitor:Task<Void,Never>?,submission:Task<Void,Never>?,closing:Task<Bool,Never>?
    private var generation = UUID()
    private(set) var stopped = false
    private(set) var lastClosure:SFTPWorkerClose?
    func beginConnection() throws {
        guard controller == nil,continuation == nil,monitor == nil,submission == nil,closing == nil else { throw SFTPSessionFailure.busy }
        stopped = false;session = nil;lastClosure = nil
    }
    func review(_ session:any SFTPAuthenticationReviewControl,challenge:SFTPInteractiveChallenge,settings:BrowserSettings,owner:NSWindow?) async -> SFTPInteractiveAnswers? {
        guard !stopped,!Task.isCancelled,continuation == nil,closing == nil,
              self.session == nil || self.session?.review.session == session.review.session else { return nil }
        self.session = session
        return await withTaskCancellationHandler {
            await withCheckedContinuation { pending in
                continuation = pending
                let token = UUID();generation = token
                if Self.isSilentEmptyRound(challenge) {
                    // The server supplied no text or question to review. Keep
                    // the same continuation, liveness check and close barrier.
                    // A preceding visible round stays in its submitting state.
                    let expires = ProcessInfo.processInfo.systemUptime + Double(challenge.responseSeconds)
                    monitor = Task { [weak self] in
                        guard let self else { return }
                        do { try await session.checkInteractiveChallenge(challenge) }
                        catch { cancel(); return }
                        guard generation == token,!stopped,!Task.isCancelled,closing == nil,continuation != nil,
                              self.session?.review.session == session.review.session,
                              ProcessInfo.processInfo.systemUptime < expires,
                              let response = try? SFTPInteractiveAnswers([]) else { cancel(); return }
                        submit(response)
                    }
                } else {
                    if let controller { controller.model.install(challenge) }
                    else {
                        let model = SFTPInteractiveModel(challenge:challenge)
                        model.onSubmit = { [weak self] in self?.submit($0) };model.onCancel = { [weak self] in self?.cancel() }
                        let window = SFTPInteractiveWindowController(settings:settings,model:model);controller = window;window.present(relativeTo:owner)
                    }
                    monitor = Task { [weak self] in
                        guard let self else { return }
                        while generation == token && !stopped && controller?.model.phase == .input {
                            do { try await session.checkInteractiveChallenge(challenge) }
                            catch { cancel(); return }
                            try? await Task.sleep(for:.milliseconds(100))
                        }
                    }
                }
                if Task.isCancelled { cancel() }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    private func submit(_ answers:SFTPInteractiveAnswers) {
        guard !stopped,submission == nil,continuation != nil else { return };generation = UUID()
        let pending = monitor;monitor = nil
        submission = Task { [weak self] in
            await pending?.value;guard let self else { return }
            guard !stopped,!Task.isCancelled else { submission = nil;return }
            let callback = continuation;continuation = nil;submission = nil;callback?.resume(returning:answers)
        }
    }
    func cancel() {
        guard closing == nil,session != nil else { return };stopped = true;generation = UUID();controller?.model.closing()
        let pending = monitor;monitor = nil;let submitting = submission;submission = nil;submitting?.cancel()
        closing = Task { [weak self,session] in
            await pending?.value;await submitting?.value
            let outcome = await session?.close(),ended = outcome?.localResourcesEnded ?? true
            guard let self else { return ended }
            lastClosure = outcome
            let callback = continuation;continuation = nil;callback?.resume(returning:nil)
            if ended { controller?.model.ended();controller?.permitsClose = true;controller?.close();controller = nil;self.session = nil }
            else { controller?.model.uncertain() }
            closing = nil;return ended
        }
    }
    func dismissAuthenticated() async -> Bool {
        generation = UUID();let pending = monitor;monitor = nil;await pending?.value
        guard !stopped,closing == nil,continuation == nil,submission == nil else { return false }
        controller?.model.ended();controller?.permitsClose = true;controller?.close();controller = nil;session = nil;return true
    }
    func closeAndDrain() async -> Bool {
        cancel();if let closing { return await closing.value };return session == nil
    }
}
