import AppKit
import Combine
import FileOperations
import LocalStorage

enum ZIPTextEditorFeature {
    static var available: Bool {
        if GeneratedSandboxReview.publicationOnlyReviewAdmitted || GeneratedSandboxReview.archiveInternalAdmitted { return false }
        if GeneratedSandboxReview.admitted { return ZIPOriginalUpdateFeature.available }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-editor-preferences") { return true }
        #endif
        return AppFeatureAvailability.allows(.authoredZIPChanges) && ZIPOriginalUpdateFeature.available
    }
}

@MainActor extension BrowserViewController {
    var canOpenZIPTextEditor: Bool {
        ZIPTextEditorFeature.available && !isBrowserSuspended
            && !isReadOnlyFileSession && recoverableFileOperations != nil
    }
}

/// A concrete local-document child of ApplicationLocalTextEditors. It shares
/// that owner's capacity, Quit decisions and mutation admission; no new writer
/// queue, temp-file editor or application lifetime is introduced.
@MainActor final class ApplicationArchiveTextEditors {
    private struct Key: Hashable { let source: URL; let path: String }
    private struct Entry {
        let document: ArchiveTextDocumentController
        let preferences: AnyCancellable
    }
    private var documents: [UUID: Entry] = [:]
    private var opening: [Key: Task<Void, Never>] = [:]
    private var reviewingTermination = false
    var documentCount: Int { documents.count }
    var reservationCount: Int { documentCount + opening.count }
    var hasManagedDocuments: Bool { reservationCount != 0 }
    var hasFileWork: Bool { !opening.isEmpty || documents.values.contains { $0.document.isBusy } }

    func showExisting(source: URL, path: String) -> Bool {
        guard let entry = documents.values.first(where: {
            $0.document.opened.archiveURL == source && $0.document.opened.archivePath == path
        }) else { return false }
        entry.document.show(); return true
    }
    func open(_ selection: ZIPTextPreviewSelection, source: URL, path: String, reader: ZIPArchiveReader,
              engine: RecoverableFileOperations, access: FileAccessLifetimes, settings: BrowserSettings,
              interactions: ArchiveEditorInteractions, report: @escaping (String) -> Void) {
        let key = Key(source: source, path: path)
        guard !reviewingTermination, opening[key] == nil, !showExisting(source: source, path: path) else { return }
        report("Opening text from ZIP…")
        opening[key] = Task { [self] in
            let trace = UUID()
            var inspection: UUID?
            defer {
                if let inspection { ApplicationOperationCoordinator.shared.finishInspection(inspection) }
                opening.removeValue(forKey: key)
                withExtendedLifetime(access) {}
            }
            ApplicationDiagnostics.shared.event(.open, .reading, trace: trace)
            do {
                guard let token = ApplicationOperationCoordinator.shared.beginInspection() else { throw FileOperationFailure.unavailable }
                inspection = token
                let value = try await reader.openTextForEdit(selection, retaining: access)
                try Task.checkCancellation()
                guard !reviewingTermination, value.archiveURL == source, value.archivePath == path else { throw CancellationError() }
                let document = ArchiveTextDocumentController(opened: value, reader: reader, engine: engine,
                    access: access, interactions: interactions, installChrome: {
                        $0.isRestorable = false; ToolWindowChrome.install(in: $0, settings: settings)
                    })
                document.window.bindKeyboardBehavior(to: settings)
                document.window.surface.find.motion = { [weak preferenceOwner = settings] in preferenceOwner?.motion ?? .init() }
                let observation = settings.$editorPreferences.removeDuplicates().sink { [weak document] preferences in
                    guard let document else { return }
                    document.applyPreferences(preferences, pointSize: CGFloat(preferences.basePointSize) * InterfaceMetrics.scale)
                    InterfaceMetrics.setFont(document.window.surface.textView,
                        base: .monospacedSystemFont(ofSize: CGFloat(preferences.basePointSize), weight: .regular))
                }
                documents[document.id] = .init(document: document, preferences: observation)
                document.didClose = { [weak self] id in self?.documents.removeValue(forKey: id) }
                InterfacePresentation.shared.register(document.window.surface)
                document.show()
                report("Opened in Traverse Editor")
                ApplicationDiagnostics.shared.event(.open, .completed, trace: trace, relatedTrace: document.id)
            } catch {
                report(error is CancellationError ? "Opening stopped." : ArchiveTextDocumentController.message(error))
                ApplicationDiagnostics.shared.event(.open, error is CancellationError ? .cancelled : .failed,
                    trace: trace, error: DiagnosticErrors.project(error))
            }
        }
    }
    func prepareForTermination() async -> Bool {
        reviewingTermination = true
        let pending = Array(opening.values); pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        let current = documents.values.map(\.document)
        for document in current where !document.isClosed {
            guard await document.closeForTermination() else { return false }
        }
        return documents.isEmpty && opening.isEmpty
    }
    func resumeAfterCancelledTermination() { reviewingTermination = false }
    #if DEBUG
    func documentForVerification(source: URL, path: String) -> ArchiveTextDocumentController? {
        documents.values.first { $0.document.opened.archiveURL == source && $0.document.opened.archivePath == path }?.document
    }
    #endif
}
