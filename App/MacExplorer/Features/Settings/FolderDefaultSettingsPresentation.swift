import AppKit
import Combine
import SwiftUI

/// One actual Settings root/window. General's retained outgoing tree owns no
/// presentation token or disappearance callback.
@MainActor final class FolderDefaultSettingsPresentation: ObservableObject {
    @Published private(set) var isActive = false
    let owner: ApplicationFolderDefaults
    private var selectedGeneral: Bool
    private weak var window: NSWindow?
    private var closed = false
    private var token: UUID?
    private var observation: FolderDefaultSettingsWindowObservation?
    private var alert: NSAlert?, consent: FolderDefaultCoordinator.Consent?
    init(owner: ApplicationFolderDefaults, initialGeneral: Bool) { self.owner = owner; selectedGeneral = initialGeneral }
    func selectGeneral(_ value: Bool) {
        // Called BEFORE Settings assigns its selected page or starts the fade.
        selectedGeneral = value
        if value { activateIfEligible() } else { revoke() }
    }
    func bind(_ candidate: NSWindow?) {
        guard window !== candidate else { return }
        revoke(); observation = nil; window = candidate; closed = false
        guard let candidate else { return }
        observation = FolderDefaultSettingsWindowObservation(window: candidate, close: { [weak self, weak candidate] in
            guard let self, self.window === candidate else { return }; self.closed = true; self.revoke()
        }, visible: { [weak self, weak candidate] in
            guard let self, let candidate, self.window === candidate else { return }
            if candidate.isVisible && !candidate.isMiniaturized && !self.closed { self.activateIfEligible() } else { self.revoke() }
        })
        activateIfEligible()
    }
    func windowWillHide(_ candidate: NSWindow) {
        guard window === candidate else { return }; closed = true; revoke()
    }
    func windowDidShow(_ candidate: NSWindow) {
        guard window === candidate, candidate.isVisible, !candidate.isMiniaturized else { return }
        closed = false; activateIfEligible()
    }
    private func activateIfEligible() {
        guard selectedGeneral, !closed, !owner.isTerminating, token == nil,
              let window, window.isVisible, !window.isMiniaturized, let coordinator = owner.coordinator else { return }
        token = coordinator.attach(); isActive = true
    }
    private func revoke() {
        let previous = token; token = nil; isActive = false
        if let previous { owner.coordinator?.detach(previous) }
        if let consent { owner.coordinator?.discard(consent) }; consent = nil
        let old = alert; alert = nil
        if let window, let old, window.attachedSheet === old.window { window.endSheet(old.window, returnCode: .cancel) }
    }
    func suspendForTermination() { revoke() }
    func resumeAfterCancelledTermination() { activateIfEligible() }
    func refresh() { if isActive, owner.coordinator?.isBusy == false { owner.coordinator?.refresh() } }
    func present(_ direction: FolderDefaultRecoveryRecord.Direction) {
        guard isActive, selectedGeneral, !owner.isTerminating, let token, let window, window.isVisible,
              window.attachedSheet == nil, let coordinator = owner.coordinator,
              let issued = coordinator.consent(for: direction, in: token) else { return }
        let sheet = NSAlert(); sheet.messageText = issued.title; sheet.informativeText = issued.explanation
        sheet.addButton(withTitle: issued.button); sheet.addButton(withTitle: "Cancel")
        sheet.buttons[0].keyEquivalent = ""; sheet.buttons[1].keyEquivalent = "\u{1b}"
        alert = sheet; consent = issued
        sheet.beginSheetModal(for: window) { [weak self, weak sheet, weak window, weak coordinator] reply in
            guard let coordinator else { return }
            guard let self, let sheet, self.alert === sheet, self.consent == issued else { coordinator.discard(issued); return }
            self.alert = nil; self.consent = nil
            guard reply == .alertFirstButtonReturn, self.token == token, self.selectedGeneral,
                  self.isActive, !self.owner.isTerminating, window?.isVisible == true else { coordinator.discard(issued); return }
            _ = coordinator.confirm(issued)
        }
    }
}

private final class FolderDefaultSettingsWindowObservation {
    private var tokens: [NSObjectProtocol] = []
    @MainActor init(window: NSWindow, close: @escaping @MainActor @Sendable () -> Void, visible: @escaping @MainActor @Sendable () -> Void) {
        tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in MainActor.assumeIsolated { close() } })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in MainActor.assumeIsolated { visible() } })
        }
    }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

struct FolderDefaultSettingsWindowReader: NSViewRepresentable {
    let changed: @MainActor (NSWindow?) -> Void
    func makeNSView(context: Context) -> Reader { Reader(changed) }
    func updateNSView(_ view: Reader, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: Reader, coordinator: ()) { view.changed(nil) }
    final class Reader: NSView {
        var changed: @MainActor (NSWindow?) -> Void
        init(_ changed: @escaping @MainActor (NSWindow?) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); changed(window) }
    }
}

/// Exact retained Settings-window show/close boundaries. Key/occlusion events
/// alone cannot reopen a token during endSheet/close reentrancy.
@MainActor final class FolderDefaultSettingsWindow: ToolMotionWindow {
    private let folderDefaults: ApplicationFolderDefaults
    private var hidingDepth = 0
    private var userClose = false
    init(contentRect: NSRect, folderDefaults: ApplicationFolderDefaults) {
        self.folderDefaults = folderDefaults
        super.init(contentRect: contentRect, styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
    }
    required init?(coder: NSCoder) { nil }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        ToolWindowCloseMotion.cancel(self)
        super.makeKeyAndOrderFront(sender)
        if hidingDepth == 0 { folderDefaults.settingsWindowDidShow(self) }
    }
    override func orderOut(_ sender: Any?) {
        hidingDepth += 1; defer { hidingDepth -= 1 }
        folderDefaults.settingsWindowWillHide(self); super.orderOut(sender)
    }
    override func close() {
        hidingDepth += 1; defer { hidingDepth -= 1 }
        folderDefaults.settingsWindowWillHide(self)
        if userClose, !ToolWindowCloseMotion.shouldClose(self) { return }
        super.close()
    }
    override func performClose(_ sender: Any?) {
        userClose = true; defer { userClose = false }
        super.performClose(sender)
    }
    override func miniaturize(_ sender: Any?) {
        hidingDepth += 1; defer { hidingDepth -= 1 }
        folderDefaults.settingsWindowWillHide(self); super.miniaturize(sender)
    }
    override func deminiaturize(_ sender: Any?) {
        super.deminiaturize(sender)
        if hidingDepth == 0 { folderDefaults.settingsWindowDidShow(self) }
    }
}
