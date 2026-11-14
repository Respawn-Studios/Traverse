import AppKit

@MainActor
extension BrowserViewController {
    /// Keep the existing status/spinner immediate, but avoid a full-canvas
    /// announcement for a folder that is ready within a few frames.
    func beginFolderLoadingFeedback() {
        folderLoadingFeedbackTask?.cancel(); folderLoadingFeedbackTask = nil
        folderLoadingFeedbackDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        guard location.directoryURL != nil else { return }
        let visit = sessionID
        folderLoadingFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.sessionID == visit, !self.isBrowserSuspended,
                  !self.metadataSearch.isShowingResults else { return }
            self.folderLoadingFeedbackTask = nil
            if self.isLoading || self.orderingTask != nil { self.refreshStatus() }
        }
    }
}
