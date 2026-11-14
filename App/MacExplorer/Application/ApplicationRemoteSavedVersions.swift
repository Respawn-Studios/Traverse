import AppKit
import FileOperations
@_spi(Qualification) import LocalStorage

/// Exactly one already-owned persistent workspace. Captured closures retain its
/// validated owner; the UI has no root/path/UUID lookup or admission constructor.
final class RemoteSavedVersionsLoader: Sendable {
    let load: @Sendable () async throws -> [SFTPInPlaceRecoveryChoice]
    let listing: (@Sendable () async throws -> SFTPInPlaceRecoveryListing)?
    let documents: (@Sendable () async throws -> [SFTPRetainedDocumentChoice])?
    let removeDocument: (@Sendable (SFTPRetainedDocumentChoice) async throws -> Void)?
    let smbLoad: (@Sendable () async throws -> [SMBInPlaceRecoveryChoice])?
    let stopAndDrain: @Sendable () async -> Void
    init(load: @escaping @Sendable () async throws -> [SFTPInPlaceRecoveryChoice],
         listing: (@Sendable () async throws -> SFTPInPlaceRecoveryListing)? = nil,
         documents: (@Sendable () async throws -> [SFTPRetainedDocumentChoice])? = nil,
         removeDocument: (@Sendable (SFTPRetainedDocumentChoice) async throws -> Void)? = nil,
         smbLoad: (@Sendable () async throws -> [SMBInPlaceRecoveryChoice])? = nil,
         stopAndDrain: @escaping @Sendable () async -> Void) {
        self.load = load; self.listing = listing; self.documents = documents; self.removeDocument = removeDocument
        self.smbLoad = smbLoad; self.stopAndDrain = stopAndDrain
    }
}

@MainActor struct RemoteSavedVersionsContext {
    let settings: BrowserSettings
    let acquire: () async throws -> UUID, finish: (UUID) -> Void
    let choose: (NSWindow) async -> EditorSaveDestination?
    let publish: (TextDocumentValue, UUID, EditorSaveDestination, NSWindow) async throws -> LocalTextSaveAsResult
    let showResult: (UUID) -> Void
}

@MainActor final class ApplicationRemoteSavedVersions: NSObject {
    static let shared = ApplicationRemoteSavedVersions()
    private var loader: RemoteSavedVersionsLoader?
    #if DEBUG
    var gateAInstalledLoader: RemoteSavedVersionsLoader? { loader }
    #endif
    private weak var browser: BrowserViewController?
    private var boundContext: RemoteSavedVersionsContext?
    private(set) var controller: RemoteSavedVersionsWindow?
    private var terminating = false
    private(set) var reservationCount = 0
    var acceptsDemand: Bool { RemoteTextEditorFeature.available && !terminating }
    var hasManagedWork: Bool { controller != nil || reservationCount != 0 }

    /// Bootstrap must receive the concrete persistent module's owned loader.
    /// Replacing a source while a window/read exists would abandon its owner.
    func install(loader: RemoteSavedVersionsLoader) -> Bool {
        guard !terminating, controller == nil, reservationCount == 0 else { return false }
        self.loader = loader; return true
    }
    func bind(browser: BrowserViewController) {
        self.browser = browser
        if let context = ApplicationLocalTextEditors.shared.savedVersionsContext(from: browser) { boundContext = context }
    }
    @objc func showSavedVersions(_ sender: Any?) {
        guard acceptsDemand else { return }
        if let controller { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        if let browser, let context = ApplicationLocalTextEditors.shared.savedVersionsContext(from: browser) {
            boundContext = context
        }
        guard let context = boundContext else {
            let alert = NSAlert(); alert.messageText = "Saved Versions is not ready"
            alert.informativeText = "The local copy service is unavailable. Existing retained data stays protected."
            alert.runModal(); return
        }
        let value = RemoteSavedVersionsWindow(source: loader, context: context, owner: self)
        controller = value
        value.didClose = { [weak self, weak value] in
            guard let self, controller === value else { return }; controller = nil
        }
        value.showWindow(nil); value.window?.makeKeyAndOrderFront(nil)
        // Opening this global command is explicit metadata discovery only.
        value.refreshChoices()
    }
    func reserveBody() -> Bool {
        guard acceptsDemand, reservationCount == 0,
              ApplicationLocalTextEditors.shared.documentReservationCount
                + ApplicationRemoteTextEditors.shared.reservationCount < 4 else { return false }
        reservationCount = 1; return true
    }
    func releaseBody() { precondition(reservationCount == 1); reservationCount = 0 }
    func workspaceDidChange() { controller?.workspaceDidChange() }
    func prepareForTermination() async -> Bool {
        terminating = true
        if let controller { await controller.closeAndDrain() }
        if let loader { await loader.stopAndDrain() }
        return controller == nil && reservationCount == 0
    }
    func resumeAfterCancelledTermination() { terminating = false }

    #if DEBUG
    func showGenerated(source: RemoteSavedVersionsLoader, context: RemoteSavedVersionsContext,
                       visible: Bool) -> RemoteSavedVersionsWindow? {
        guard acceptsDemand, controller == nil, reservationCount == 0 else { return nil }
        let value = RemoteSavedVersionsWindow(source: source, context: context, owner: self)
        controller = value
        value.didClose = { [weak self, weak value] in
            guard let self, controller === value else { return }; controller = nil
        }
        if visible { value.showWindow(nil); value.window?.makeKeyAndOrderFront(nil) }
        value.refreshChoices(); return value
    }
    #endif
}
