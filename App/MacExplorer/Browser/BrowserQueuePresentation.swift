import AppKit
import Combine

/// One queued presentation update per window. File-operation ownership and
/// progress delivery remain in the application coordinator and its worker.
@MainActor
final class BrowserQueuePresentationController {
    private weak var workspace: BrowserWorkspaceController?
    private var observation: AnyCancellable?
    private var pending: Task<Void, Never>?
    private var ticket: UUID?

    init(workspace: BrowserWorkspaceController) {
        self.workspace = workspace
        observation = workspace.primaryBrowser.operationCoordinator.transfers.$revision.sink { [weak self] _ in
            self?.schedule()
        }
    }

    func schedule() {
        guard let workspace, workspace.isViewLoaded, !workspace.isClosing, ticket == nil else { return }
        let token = UUID()
        ticket = token
        // Published emits before assigning. Read the latest state on the next
        // actor turn and coalesce all revisions already waiting for this window.
        pending = Task { @MainActor [weak self] in
            guard let self, self.ticket == token, !Task.isCancelled else { return }
            self.ticket = nil
            self.pending = nil
            guard let workspace = self.workspace, !workspace.isClosing else { return }
            // Clear the ticket first: a revision emitted during native rendering
            // must be able to schedule a subsequent refresh, not be lost.
            #if DEBUG
            self.beforeRefreshForVerification?()
            #endif
            workspace.renderQueuedPresentation()
        }
    }

    func cancel() {
        ticket = nil
        pending?.cancel()
        pending = nil
    }

    #if DEBUG
    var beforeRefreshForVerification: (() -> Void)?
    var isPendingForVerification: Bool { ticket != nil }
    #endif
}
