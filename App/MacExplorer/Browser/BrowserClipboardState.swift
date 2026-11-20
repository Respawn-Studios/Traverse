import AppKit
import FileOperations

/// One clipboard intent across every pane of a window. Sharing only the native
/// pasteboard would turn a Cut in one pane into an ordinary Copy in another.
@MainActor
final class BrowserClipboardState {
    var didChange: (() -> Void)?
    var revision = UUID() { didSet { ownedCopy = nil; scopedItem = nil; scopedItemChangeCount = nil; changed() } }
    var pendingCut: FileOperationSelection? { didSet { changed() } }
    var pendingCutChangeCount: Int? { didSet { changed() } }
    var cutURLs: Set<URL> = [] { didSet { changed() } }
    var scopedItem: ScopedItemClipboardIntent? { didSet { changed() } }
    var scopedItemChangeCount: Int?
    var feedback: TransferClipboardFeedback? {
        didSet {
            if feedback?.id != ownedCopy?.feedbackID { ownedCopy = nil }
            if feedback?.scopedItem == nil { scopedItem = nil; scopedItemChangeCount = nil }
            changed()
        }
    }
    var cutPreparation: Task<Void, Never>?
    var observationTask: Task<Void, Never>?
    var pasteboard = NSPasteboard.general {
        didSet { if pasteboard !== oldValue { clear() } }
    }
    private var ownedCopy: BrowserClipboard.OwnedCopy?
    private var notificationScheduled = false
    private var observers: [UUID: () -> Void] = [:]

    /// Auxiliary file windows observe the same intent without replacing the
    /// workspace's existing presentation callback.
    func observe(_ changed: @escaping () -> Void) -> UUID {
        let token = UUID(); observers[token] = changed; return token
    }
    func removeObserver(_ token: UUID) { observers[token] = nil }

    func clear() {
        revision = UUID()
        cutPreparation?.cancel(); cutPreparation = nil
        pendingCut = nil; pendingCutChangeCount = nil; cutURLs = []
        observationTask?.cancel(); observationTask = nil
        feedback = nil
    }

    /// Only an explicit successful Copy publication establishes local provenance.
    /// Larger native publications remain usable, without an owned fast path.
    func acceptCopy(_ publication: BrowserClipboard.Publication, urls: [URL], revision: UUID) -> Bool {
        acceptCopy(publication, urls: urls, revision: revision, afterNativeValidation: nil)
    }

    private func acceptCopy(_ publication: BrowserClipboard.Publication, urls: [URL], revision: UUID,
                            afterNativeValidation: (() -> Void)?) -> Bool {
        guard self.revision == revision, pendingCut == nil, scopedItem == nil else { return false }
        let board = pasteboard
        let previousFeedbackID = feedback?.id
        switch publication {
        case .files(let receipt):
            guard receipt.urls == urls, receipt.isCurrent(on: board) else { return false }
            afterNativeValidation?()
            // No native IPC follows this final local fence before installation.
            guard pasteboard === board, self.revision == revision, pendingCut == nil,
                  feedback?.id == previousFeedbackID else { return false }
            let feedback = TransferClipboardFeedback(intent: .copy, urls: urls, changeCount: receipt.changeCount)
            self.feedback = feedback
            ownedCopy = BrowserClipboard.OwnedCopy(publication: receipt, revision: revision, feedbackID: feedback.id)
            return true
        case .unownedFiles(let proof):
            guard urls.count > 1024, proof.isCurrent(on: board),
                  let capture = readFiles(allowOwnedCopy: false), capture.urls == urls,
                  capture.changeCount == proof.changeCount, capture.isCurrent(on: board) else { return false }
            afterNativeValidation?()
            guard pasteboard === board, self.revision == revision, pendingCut == nil,
                  feedback?.id == previousFeedbackID else { return false }
            feedback = TransferClipboardFeedback(intent: .copy, urls: urls, changeCount: capture.changeCount)
            ownedCopy = nil
            return true
        case .text, .failed:
            return false
        }
    }

    func readFiles(allowOwnedCopy: Bool) -> BrowserClipboard.FileRead? {
        readFiles(allowOwnedCopy: allowOwnedCopy, afterOwnedValidation: nil)
    }

    private func readFiles(allowOwnedCopy: Bool, afterOwnedValidation: (() -> Void)?) -> BrowserClipboard.FileRead? {
        synchronize()
        guard scopedItem == nil else { return nil }
        let board = pasteboard
        let markerGeneration = board.changeCount
        guard board.availableType(from: [ScopedItemClipboardIntent.pasteboardType]) == nil,
              board.changeCount == markerGeneration else { return nil }
        let revision = self.revision
        let feedbackID = feedback?.id
        if allowOwnedCopy, pendingCut == nil, feedback?.intent == .copy, let ownedCopy {
            guard let capture = ownedCopy.read(from: board, revision: revision, feedbackID: feedbackID) else { return nil }
            afterOwnedValidation?()
            // Do not retry a stale owned capture through the native fallback.
            guard capture.changeCount == markerGeneration, pasteboard === board, self.revision == revision, self.feedback?.id == feedbackID,
                  self.ownedCopy?.feedbackID == feedbackID, pendingCut == nil, self.feedback?.intent == .copy else { return nil }
            return capture
        }
        guard let capture = BrowserClipboard.readFiles(from: board, isCurrent: {
            self.pasteboard === board && self.revision == revision
        }), capture.changeCount == markerGeneration else { return nil }
        return capture
    }

    #if DEBUG
    var hasOwnedCopyForVerification: Bool { ownedCopy != nil }

    // Per-call boundary seams only, never ambient interception or native success.
    func acceptCopyForVerification(_ publication: BrowserClipboard.Publication, urls: [URL], revision: UUID,
                                   afterNativeValidation: @escaping () -> Void) -> Bool {
        acceptCopy(publication, urls: urls, revision: revision, afterNativeValidation: afterNativeValidation)
    }

    func readFilesForVerification(allowOwnedCopy: Bool, afterOwnedValidation: @escaping () -> Void) -> BrowserClipboard.FileRead? {
        readFiles(allowOwnedCopy: allowOwnedCopy, afterOwnedValidation: afterOwnedValidation)
    }

    func synchronizeForVerification(afterNativeObservation: @escaping () -> Void) {
        synchronize(afterNativeObservation: afterNativeObservation)
    }
    #endif

    func synchronize() {
        synchronize(afterNativeObservation: nil)
    }

    private func synchronize(afterNativeObservation: (() -> Void)?) {
        guard let feedback else { return }
        let board = pasteboard
        let revision = self.revision
        let observedChangeCount = board.changeCount
        afterNativeObservation?()
        // The observation may invalidate only the intent captured before the
        // native call. A newer local Copy/Cut must survive a stale observation.
        guard pasteboard === board, self.revision == revision,
              self.feedback?.id == feedback.id else { return }
        if observedChangeCount != feedback.changeCount || scopedItem?.isAlive == false { clear() }
    }

    /// Dismiss only the captured app intent. Native clipboard representations
    /// remain available to Finder, clipboard managers and later ordinary Paste.
    @discardableResult
    func dismiss(feedbackID: UUID) -> Bool {
        synchronize()
        guard feedback?.id == feedbackID else { return false }
        clear()
        return true
    }

    func beginObservation() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                self.synchronize()
                if self.feedback == nil { return }
            }
        }
    }

    private func changed() {
        guard !notificationScheduled else { return }
        notificationScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.notificationScheduled = false
            self.didChange?()
            for changed in Array(self.observers.values) { changed() }
        }
    }
}
