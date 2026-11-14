import AppKit
import Combine

/// Deferred app messages share the same readiness rules. Setup, native sheets
/// and active file work keep priority; becoming active/key schedules a recheck.
@MainActor final class IdleBrowserPresentation {
    private weak var originatingBrowser: BrowserViewController?
    private weak var workspace: BrowserWorkspaceController?
    private let action: @MainActor (BrowserViewController) -> Void
    private var observations: [BrowserNotificationObservation] = []
    private var preferences: AnyCancellable?
    private var workState: AnyCancellable?
    private var pending: Task<Void, Never>?

    init(browser: BrowserViewController, action: @escaping @MainActor (BrowserViewController) -> Void) {
        originatingBrowser = browser; workspace = browser.workspace; self.action = action
        observations = [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification].map { name in
            BrowserNotificationObservation(name: name, object: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.consider() }
            }
        }
        preferences = browser.settings.$initialSetupCompleted.dropFirst().sink { [weak self] _ in self?.consider() }
        let operations = browser.operationCoordinator
        workState = operations.$activeOwner.combineLatest(operations.$preparationOwner,
            operations.$copyPreviewOwner, operations.$volumeBarrierOwner)
            .dropFirst().sink { [weak self] _ in self?.consider() }
        consider()
    }

    func consider() {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { self.pending = nil }
            guard !Task.isCancelled, NSApp.isActive, NSApp.modalWindow == nil,
                  let browser = self.workspace?.activeBrowser ?? self.originatingBrowser,
                  browser.isViewLoaded, !browser.isBrowserSuspended,
                  let window = browser.view.window, window.isKeyWindow, window.attachedSheet == nil,
                  browser.settings.initialSetupCompleted else { return }
            let operations = browser.operationCoordinator
            guard operations.activeOwner == nil, operations.preparationOwner == nil,
                  operations.copyPreviewOwner == nil, operations.volumeBarrierOwner == nil else { return }
            self.action(browser)
        }
    }
}
