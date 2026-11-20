import AppKit
import FileOperations
import LocalStorage

@MainActor enum GitIndexEditFlow {
    enum Outcome: Sendable {
        case changed, alreadyCurrent, cancelled

        func notice(for action: GitIndexEditAction) -> String? {
            switch self {
            case .changed:
                if action == .unstage { return "File unstaged." }
                if case .stageReviewedChange = action { return "Selected change staged." }
                if case .unstageReviewedChange = action { return "Selected change unstaged." }
                return action.stagesRemoval ? "File removal staged." : "Saved file staged."
            case .alreadyCurrent:
                if case .unstageReviewedChange = action { return "This file has no index change to apply." }
                return action == .unstage || action.stagesRemoval
                    ? "This file has no index change to apply." : "The saved bytes already match the index."
            case .cancelled: return nil
            }
        }
    }

    static func run(_ action: GitIndexEditAction, path: GitSnapshotPath, using access: GitReviewAccess,
                    in parent: NSWindow, hasUnsavedEdits: () -> Bool = { false },
                    matchingSavedText: LocalTextReadToken? = nil,
                    acceptsPlan: (GitIndexEditPlan) -> Bool = { _ in true },
                    isCurrent: () -> Bool) async throws -> Outcome {
        let plan = try await access.prepareIndexEdit(action, path: path, matchingSavedText: matchingSavedText)
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        guard acceptsPlan(plan) else { throw GitInspectionFailure.changed }
        guard plan.hasChange else { return .alreadyCurrent }
        let alert = NSAlert()
        let name = String(path.display.prefix(240))
        let from = plan.before.map { $0.object.short } ?? "No index entry"
        let to = plan.after.map { $0.object.short } ?? "Remove index entry"
        switch action {
        case .stageReviewedPath(let selection) where selection.isRemoval:
            alert.messageText = "Stage this file’s removal?"
            alert.informativeText = "\(name)\n\nThe file is missing on disk. Remove its entry from the Git index."
            alert.addButton(withTitle: "Stage Removal")
        case .stageSavedFile, .stageReviewedPath:
            alert.messageText = "Stage the saved file?"
            let source = hasUnsavedEdits() ? "\nUnsaved edits stay in the editor." : ""
            alert.informativeText = "\(name)\n\nIndex: \(from) → \(to)\nStage the bytes saved on disk.\(source)"
            alert.addButton(withTitle: "Stage File")
        case .stageReviewedChange:
            alert.messageText = "Stage the selected change?"
            alert.informativeText = "\(name)\n\nIndex: \(from) → \(to)\nStage the selected block from the saved file."
            alert.addButton(withTitle: "Stage Change")
        case .unstage:
            alert.messageText = "Unstage this file?"
            alert.informativeText = "\(name)\n\nIndex: \(from) → \(to)\nUse the entry at HEAD (\(plan.head.short))."
            alert.addButton(withTitle: "Unstage File")
        case .unstageReviewedChange:
            alert.messageText = "Unstage the selected change?"
            alert.informativeText = "\(name)\n\nIndex: \(from) → \(to)\nUse the version at HEAD for this block."
            alert.addButton(withTitle: "Unstage Change")
        }
        alert.addButton(withTitle: "Cancel")
        let choice = await withTaskCancellationHandler {
            await alert.beginSheetModal(for: parent)
        } onCancel: {
            Task { @MainActor in
                if parent.attachedSheet === alert.window { parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
            }
        }
        guard choice == .alertFirstButtonReturn else { return .cancelled }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        try await access.applyIndexEdit(plan)
        return .changed
    }

    static func message(for error: Error) -> String {
        if let failure = error as? GitIndexEditFailure { return failure.userMessage }
        if let failure = error as? GitInspectionFailure, failure == .changed {
            return "The file, checkout or index changed. Review the file again."
        }
        if let failure = error as? GitInspectionFailure, failure == .limitExceeded {
            return "The file or index exceeds the limits for this Git action."
        }
        return GitReviewAccess.message(for: error)
    }
}
