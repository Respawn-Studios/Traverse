import Foundation

@MainActor
enum ArchiveAutomaticAction {
    /// Fast actions finish in the browser. Longer work and actionable failures
    /// reveal the same workbench, retaining its real progress and Stop owner.
    static func run<Model: ArchiveAutomaticActionModel>(_ model: Model,
        isCurrent: @escaping @MainActor () -> Bool,
        reveal: @escaping @MainActor () -> Void,
        close: @escaping @MainActor () -> Void) async {
        let progress = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, isCurrent(), model.automaticActionShouldReveal else { return }
            reveal()
        }
        defer { progress.cancel() }
        let ready = await model.prepareAutomaticAction()
        guard !Task.isCancelled, isCurrent() else { return }
        if ready, model.automaticActionCanSubmit {
            model.performAutomaticAction()
            await model.waitForOperation()
        }
        guard !Task.isCancelled, isCurrent() else { return }
        if model.automaticActionSucceeded || !model.automaticActionShouldReveal { close() }
        else { reveal() }
    }
}
