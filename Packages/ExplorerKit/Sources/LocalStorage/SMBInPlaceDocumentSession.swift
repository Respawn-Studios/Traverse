import Foundation
import FileOperations

private final class SMBInPlaceBufferPresence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var installed: Bool { lock.withLock { value } }
    func install() { lock.withLock { value = true } }
}

/// One original-file document. Each Save durably captures both versions before
/// the browser can submit a write. A failed or ambiguous Save never advances
/// the baseline or retries the remote mutation.
@_spi(Qualification) public actor SMBInPlaceDocumentSession {
    public nonisolated let id = UUID()
    public let initialContents: TextDocumentValue
    private let browser: SMBBrowserSession, storage: SMBInPlaceWorkingCopyStorage
    private let recoveryReader = SMBInPlaceRecoveryReadOwner()
    private let selection: SMBDownloadSelection, server: SMBServerDraft
    private let bufferPresence = SMBInPlaceBufferPresence()
    private var before: TextDocumentValue?, baseline: SMBRemoteFileSnapshot?
    private var saving: Task<SMBInPlaceSaveResult, Never>?
    private var saveDiagnostic: (generation: UUID, checkpoint: UInt8)?
    private var stopping: Task<SMBBrowserDrainResult, Never>?
    private var disconnected = false, needsReview = false, hasRecovery = false
    private var closeRequested = false, bufferClosed = false
    private var sourceReleased = false
    private var closedResult: SMBInPlaceCloseResult?

    init(browser: SMBBrowserSession, storage: SMBInPlaceWorkingCopyStorage,
         selection: SMBDownloadSelection, server: SMBServerDraft,
         initialContents: TextDocumentValue, baseline: SMBRemoteFileSnapshot) {
        self.browser = browser; self.storage = storage; self.selection = selection; self.server = server
        self.initialContents = initialContents; before = initialContents; self.baseline = baseline
    }
    /// Called synchronously only after the App installs this exact native text
    /// buffer. Save and close handoff refuse an uninstalled buffer.
    public nonisolated func nativeBufferDidInstall() { bufferPresence.install() }

    public func save(contents: TextDocumentValue, generation: UUID) async -> SMBInPlaceSaveResult {
        guard bufferPresence.installed, SFTPWire.validToken(generation),
              contents.encoded.count <= TextDocumentValue.maximumBytes,
              !disconnected, !needsReview, !closeRequested, !bufferClosed,
              closedResult == nil, saving == nil, let baseline, let before else {
            return .refusedBeforeSubmission(.sessionUnavailable)
        }
        saveDiagnostic = nil
        let work = Task { await self.saveCaptured(contents, generation: generation, baseline: baseline, before: before) }
        saving = work
        let result = await work.value
        saving = nil
        return result
    }
    /// A fixed boundary for this exact Save capture, never a success receipt.
    public func diagnosticCheckpoint(for generation: UUID) -> UInt8? {
        saveDiagnostic?.generation == generation ? saveDiagnostic?.checkpoint : nil
    }
    private func saveCaptured(_ contents: TextDocumentValue, generation: UUID,
                              baseline: SMBRemoteFileSnapshot, before: TextDocumentValue) async -> SMBInPlaceSaveResult {
        var attempt: SMBInPlaceEditAttempt?
        defer {
            if let attempt, let checkpoint = browser.editDiagnosticCheckpoint(for: attempt.request.id) {
                saveDiagnostic = (generation, checkpoint)
            }
        }
        do {
            guard browser.allowsInPlaceTextEdit else { return .refusedBeforeSubmission(.sessionUnavailable) }
            let staged = try await storage.prepareSave(selection: selection, session: id, generation: generation,
                                                       baseline: baseline, before: before, edited: contents, server: server)
            attempt = staged; hasRecovery = true
            guard !disconnected else {
                await staged.endAfterActualDrain()
                return .refusedBeforeSubmission(.disconnected)
            }
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { browser.owner.edit(staged, continuation: $0) }
            } onCancel: { browser.owner.cancelEdit(staged) }
            switch result {
            case .changed:
                await staged.endAfterActualDrain()
                needsReview = true; self.baseline = nil
                return .refusedBeforeSubmission(.changed)
            case .verified(let after):
                await staged.endAfterActualDrain()
                self.baseline = after; self.before = contents
                return .saved(.init(generation: generation, recordID: staged.record.id))
            case .verifiedRecoveryNeedsAttention:
                _ = await browser.close()
                await staged.endAfterActualDrain()
                disconnected = true; needsReview = true; self.baseline = nil; self.before = nil
                return .savedRemotelyRecoveryNeedsAttention(recordID: staged.record.id)
            }
        } catch {
            if let attempt {
                if attempt.admitted {
                    let closed = await browser.close()
                    await attempt.endAfterActualDrain()
                    disconnected = true; needsReview = true; self.baseline = nil; self.before = nil
                    _ = closed
                    return .needsReview(recordID: attempt.record.id)
                }
                await attempt.endAfterActualDrain()
            }
            if let interruption = error as? SMBInPlaceStagingInterruption {
                hasRecovery = true; needsReview = true
                return .needsReview(recordID: interruption.recordID)
            }
            switch error {
            case RemoteSettingsFailure.capacity, RemoteDownloadStorageFailure.capacity,
                 RemoteDownloadStorageFailure.io(ENOSPC), RemoteDownloadStorageFailure.io(EDQUOT):
                return .refusedBeforeSubmission(.stagingCapacity)
            case RemoteSettingsFailure.busy, RemoteDownloadStorageFailure.busy:
                return .refusedBeforeSubmission(.stagingBusy)
            case SMBBrowserFailure.busy: return .refusedBeforeSubmission(.browserBusy)
            case SMBBrowserFailure.unavailable, SMBBrowserFailure.stopped:
                disconnected = true; return .refusedBeforeSubmission(.disconnected)
            case SMBTextFailure.unsupported: return .refusedBeforeSubmission(.unsupportedSource)
            default: return .refusedBeforeSubmission(.stagingFailed)
            }
        }
    }
    /// Stop is connection scoped. The native buffer and retained versions stay
    /// available until the App makes its explicit close/recovery decision.
    public func requestStop() {
        disconnected = true
        if stopping == nil { let browser = self.browser; stopping = Task { await browser.close() } }
    }
    public func stopAndDrain() async -> SMBBrowserDrainResult {
        requestStop()
        await recoveryReader.stopAndDrain()
        if let saving { _ = await saving.value }
        return await stopping!.value
    }
    public func recoveryChoicesAfterExplicitRequest() async throws -> [SMBInPlaceRecoveryChoice] {
        if let saving { _ = await saving.value }
        guard !bufferClosed else { throw SMBTextFailure.closed }
        return try await recoveryReader.discoverPrepared { [storage] in storage }
    }
    public func closeAfterExplicitBufferDecision() async -> SMBInPlaceCloseResult {
        if let closedResult { return closedResult }
        closeRequested = true
        if let saving { _ = await saving.value }
        if bufferPresence.installed && !bufferClosed { return .readyToCloseBuffer }
        return await nativeBufferDidClose()
    }
    public func nativeBufferDidClose() async -> SMBInPlaceCloseResult {
        if let closedResult { return closedResult }
        guard closeRequested else { return .needsReview }
        if let saving { _ = await saving.value }
        recoveryReader.seal()
        guard await recoveryReader.sealAndDrain() else { return .needsReview }
        if !sourceReleased {
            if disconnected {
                let drained: SMBBrowserDrainResult
                if let stopping { drained = await stopping.value }
                else { drained = await browser.close() }
                guard drained.ownerReleased else { return .needsReview }
            } else {
                do { try await browser.releaseEditSource(selection.request) }
                catch {
                    disconnected = true
                    guard (await browser.close()).ownerReleased else { return .needsReview }
                }
            }
            sourceReleased = true
        }
        bufferClosed = true; before = nil; baseline = nil
        let value: SMBInPlaceCloseResult = disconnected ? .disconnectedRecoveryRetained
            : hasRecovery ? .closedVersionsRetained : .closedUnusedCopyRemoved
        closedResult = value
        return value
    }
}
