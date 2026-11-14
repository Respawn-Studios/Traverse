import AppKit
import Combine
import SwiftUI

/// Presentation only. These strings never establish verification evidence or
/// authorize password lookup; the connection owner must check its real challenge.
struct SFTPTrustPresentation: Sendable {
    enum Kind: Sendable { case first, matching, changed }
    let host: String, port: UInt16, fingerprint: String
    let previousFingerprint: String?
    var algorithm: String = "Ed25519"
    var heading: String? = nil
    var kind: Kind { previousFingerprint.map { $0 == fingerprint ? .matching : .changed } ?? .first }
}
enum SFTPTrustIntent: Sendable { case connectOnce, rememberVerified, useMatching, replaceVerified }
enum SFTPTrustRemembering: Sendable { case notRequested, saved, incomplete }
enum SFTPTrustFinish: Sendable { case verified, cancelled, expired }

@MainActor final class SFTPTrustModel: ObservableObject {
    enum Page: Sendable { case identity, replacement }
    typealias Decision = @MainActor (SFTPTrustIntent) async throws -> SFTPTrustRemembering
    let review: SFTPTrustPresentation
    let allowsRemembering: Bool
    let rememberKeyPrefilled: Bool
    @Published private(set) var page = Page.identity
    @Published var rememberKey = false
    @Published var replacementCompared = false
    @Published private(set) var busy = false
    @Published private(set) var remaining = 120
    @Published private(set) var message = ""
    @Published private(set) var finished: SFTPTrustFinish?
    @Published private(set) var closureNeedsAttention = false
    private(set) var remembering = SFTPTrustRemembering.notRequested
    var onFinish: ((SFTPTrustFinish) -> Void)?
    var onClosureAttention: (() -> Void)?
    var onCopy: (String) -> Void
    private let decision: Decision
    private let drain: @MainActor () async -> Bool
    private let now: @MainActor () -> TimeInterval
    private let expires: TimeInterval
    private var action: Task<Void, Never>?, closing: Task<Void, Never>?
    private var verificationFailed = false
    init(review: SFTPTrustPresentation, lifetime: TimeInterval = 120, allowsRemembering: Bool = true,
         prefillRememberKey: Bool = false,
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         copy: @escaping (String) -> Void = { value in
             NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
         }, decision: @escaping Decision, drain: @escaping @MainActor () async -> Bool) {
        precondition(lifetime > 0 && lifetime <= 120)
        self.review = review; self.now = now; expires = now() + lifetime; onCopy = copy
        self.allowsRemembering = allowsRemembering
        rememberKeyPrefilled = allowsRemembering && review.kind == .first && prefillRememberKey
        self.decision = decision; self.drain = drain; remaining = Int(ceil(lifetime))
        rememberKey = rememberKeyPrefilled
    }
    func copyFingerprint(previous: Bool = false) {
        guard !busy, finished == nil else { return }
        if previous { if let old = review.previousFingerprint { onCopy(old) } }
        else { onCopy(review.fingerprint) }
    }
    func showReplacement() {
        tick(); guard !busy, !closureNeedsAttention, finished == nil, closing == nil, review.kind == .changed else { return }
        replacementCompared = false; page = .replacement
    }
    func back() {
        guard !busy, !closureNeedsAttention, finished == nil else { return }; replacementCompared = false; page = .identity
    }
    func proceed() {
        tick(); guard !busy, !closureNeedsAttention, finished == nil, closing == nil else { return }
        let intent: SFTPTrustIntent
        switch review.kind {
        case .first: intent = allowsRemembering && rememberKey ? .rememberVerified : .connectOnce
        case .matching: intent = .useMatching
        case .changed:
            guard page == .replacement, replacementCompared else { return }; intent = .replaceVerified
        }
        busy = true; message = "Verifying this connection…"
        action = Task { [self] in
            do {
                remembering = try await decision(intent)
                guard !Task.isCancelled, closing == nil else { return }
                busy = false; finished = .verified
                message = remembering == .incomplete ? "Verified. Saving the key needs review." : "Server identity verified."
                onFinish?(.verified)
            } catch {
                guard closing == nil else { return }
                verificationFailed = true; cancel()
            }
        }
    }
    func tick() {
        guard finished == nil else { return }
        remaining = max(0, Int(ceil(expires - now())))
        if remaining == 0 && !busy && !closureNeedsAttention && closing == nil { cancel(expired: true) }
    }
    func cancel(expired: Bool = false) {
        guard finished == nil, closing == nil else { return }
        busy = true; message = expired ? "Review expired. Closing this connection…" : "Closing this connection…"
        let pending = action; pending?.cancel()
        closing = Task { [self] in
            let ended = await drain(); _ = await pending?.result
            guard ended else {
                busy = false; closureNeedsAttention = true; closing = nil
                message = "Connection closure could not be verified. Try closing again; this connection remains reserved."
                if remembering == .saved { message += " The verified key was saved." }
                if remembering == .incomplete { message += " Saving the key needs review." }
                onClosureAttention?()
                return
            }
            closureNeedsAttention = false
            busy = false; finished = expired ? .expired : .cancelled
            message = expired ? "Review expired. Start a new connection to verify again." : "Connection cancelled."
            if verificationFailed { message = "Server identity could not be verified. Start a new connection." }
            if remembering == .saved { message += " The verified key was saved." }
            if remembering == .incomplete { message += " Saving the key needs review." }
            onFinish?(expired ? .expired : .cancelled)
        }
    }
    @discardableResult func cancelAndDrain() async -> Bool { cancel(); _ = await closing?.result; _ = await action?.result; return finished != nil }
}

@MainActor private struct SFTPTrustForm: View {
    @ObservedObject var model: SFTPTrustModel
    @ObservedObject var settings: BrowserSettings
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.review.kind == .changed ? "exclamationmark.shield" : "checkmark.shield")
                    .interfaceFont(.system(size: 30)).foregroundStyle(model.review.kind == .changed ? Color.orange : Color.accentColor).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.page == .replacement ? "Verify the replacement key" : model.review.heading ?? "Verify server identity").interfaceFont(.title2.weight(.semibold))
                    Text("\(model.review.host) · port \(String(model.review.port))").foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.review.kind == .changed ? "This server’s key has changed. Stop unless you can verify the new fingerprint with the server owner."
                    : model.review.kind == .matching ? "This key matches the verified key saved for this exact host and port."
                    : "Compare this fingerprint with the server owner or another trusted source before continuing.")
                    .interfaceFont(.callout).fixedSize(horizontal: false, vertical: true)
                fingerprint("Current fingerprint · \(model.review.algorithm)", value: model.review.fingerprint, previous: false)
                if let previous = model.review.previousFingerprint, model.review.kind == .changed {
                    fingerprint("Previously saved fingerprint", value: previous, previous: true)
                }
                if model.page == .replacement {
                    Toggle("I verified the new fingerprint with the server owner", isOn: $model.replacementCompared).toggleStyle(.checkbox)
                    Text("Replacing it changes trust only for this exact host and port. Password choices remain separate.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                } else if model.review.kind == .first && model.allowsRemembering {
                    Toggle("Remember this verified server key", isOn: $model.rememberKey).toggleStyle(.checkbox)
                    Text(model.rememberKeyPrefilled
                        ? "Preselected from Remember server. Uncheck to connect once. Saved keys stay on this Mac; this choice does not save a password."
                        : "Off by default. Saved keys stay on this Mac; no password is saved by this choice.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
            }.disabled(model.busy || model.closureNeedsAttention || model.finished != nil)
                .toolPageEntrance(model.page, enabled: settings.motion.allows(.pages), mode: settings.motion.mode)
            }.scrollBounceBehavior(.basedOnSize)
            HStack(alignment: .top, spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.message.isEmpty ? "Identity review expires in \(model.remaining)s. No password has been requested." : model.message)
                    .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(minHeight: 34, alignment: .topLeading)
            HStack {
                if model.page == .replacement { Button("Back") { model.back() }.disabled(model.busy || model.closureNeedsAttention || model.finished != nil) }
                Spacer()
                Button(model.closureNeedsAttention ? "Try Closing Again" : model.finished == nil ? "Cancel" : "Done") { if model.finished == nil { model.cancel() } else { dismiss() } }.keyboardShortcut(.cancelAction).disabled(model.busy)
                if model.finished == nil && !model.closureNeedsAttention {
                    if model.review.kind == .changed && model.page == .identity {
                        Button("Review Replacement…") { model.showReplacement() }.disabled(model.busy)
                    } else {
                        Button(model.review.kind == .changed ? (model.allowsRemembering ? "Replace Verified Key & Continue" : "Use Verified Key & Continue") : model.review.kind == .matching ? "Continue" : model.allowsRemembering && model.rememberKey ? "Remember & Continue" : "Connect Once") { model.proceed() }
                            .keyboardShortcut(.defaultAction).disabled(model.busy || model.review.kind == .changed && !model.replacementCompared)
                    }
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, settings.appearance == .system ? systemColorScheme : settings.appearance == .dark ? .dark : .light)
            .transaction { if reduceMotion || !settings.motion.allows(.pages) { $0.disablesAnimations = true } }
            .task { while !Task.isCancelled && model.finished == nil {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }; model.tick()
            }}
    }
    private func fingerprint(_ title: String, value: String, previous: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(title).interfaceFont(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer()
                Button { model.copyFingerprint(previous: previous) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy fingerprint").accessibilityLabel(previous ? "Copy previous fingerprint" : "Copy current fingerprint")
            }
            Text(value).interfaceFont(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(12).background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor final class SFTPTrustWindowController: NSWindowController, NSWindowDelegate {
    let model: SFTPTrustModel
    private var positioned = false
    var onVerified: (() -> Void)?
    var onFinished: ((SFTPTrustFinish) -> Void)?
    init(settings: BrowserSettings, model: SFTPTrustModel) {
        self.model = model
        let window = ToolWindowChrome.makeWindow(title: "Verify Server Identity",
            size: .init(width: 660, height: 570), minimumSize: .zero,
            styleMask: [.titled, .closable, .resizable])
        window.contentMinSize = .init(width: 660, height: 570)
        super.init(window: window); window.delegate = self
        let host = InterfaceHostingController(rootView: SFTPTrustForm(model: model, settings: settings) { [weak self] in self?.window?.close() }); host.sizingOptions = []
        window.contentViewController = host; ToolWindowChrome.install(in: window, settings: settings)
        window.setContentSize(.init(width: 660, height: 570))
        model.onFinish = { [weak self] outcome in
            guard let self else { return }
            if outcome == .verified { self.onVerified?() }
            self.onFinished?(outcome)
            if self.model.remembering == .notRequested { self.window?.close() }
        }
    }
    required init?(coder: NSCoder) { nil }
    func present(relativeTo owner: NSWindow? = nil) {
        guard let window else { return }
        if !positioned {
            ToolWindowChrome.position(window, relativeTo: owner); positioned = true
        }
        showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.finished != nil { return true }; model.cancel(); return false
    }
}
