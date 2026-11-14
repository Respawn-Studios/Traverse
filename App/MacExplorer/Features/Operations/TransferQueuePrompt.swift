import AppKit

/// An owned operation sheet ends exactly once on response, cancellation or
/// parent close. Unrelated sheets are never dismissed or treated as consent.
@MainActor
final class OperationWindowPrompt {
    private weak var window: NSWindow?
    private var alert: NSAlert?
    private var token: UUID?
    private var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
    private var closeObservation: BrowserNotificationObservation?

    func present(_ alert: NSAlert, in window: NSWindow) async throws -> NSApplication.ModalResponse {
        let id = UUID()
        while window.attachedSheet != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .abort); return }
                self.window = window; self.alert = alert; self.token = id
                self.continuation = continuation
                self.closeObservation = BrowserNotificationObservation(name: NSWindow.willCloseNotification, object: window) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.cancel(token: id) }
                }
                alert.beginSheetModal(for: window) { [weak self] response in
                    self?.finish(token: id, response: response)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(token: id) }
        }
    }

    func cancel() {
        guard let token else { return }
        cancel(token: token)
    }

    private func cancel(token: UUID) {
        guard self.token == token else { return }
        if let window, let alert, window.attachedSheet === alert.window {
            window.endSheet(alert.window, returnCode: .abort)
        }
        finish(token: token, response: .abort)
    }

    private func finish(token: UUID, response: NSApplication.ModalResponse) {
        guard self.token == token else { return }
        let continuation = continuation
        self.token = nil; self.continuation = nil; alert = nil; window = nil; closeObservation = nil
        continuation?.resume(returning: response)
    }
}

typealias TransferQueuePrompt = OperationWindowPrompt
