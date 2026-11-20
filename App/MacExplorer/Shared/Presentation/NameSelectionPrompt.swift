import AppKit
import ExplorerCore

/// A native sheet for choosing names. The file surface owns the item snapshot
/// and applies the answer only while that snapshot is current.
@MainActor enum NameSelectionPrompt {
    enum Mode: Int, CaseIterable, Sendable {
        case replace, add, remove

        var title: String {
            switch self {
            case .replace: "Replace Selection"
            case .add: "Add to Selection"
            case .remove: "Remove from Selection"
            }
        }
    }

    struct Choice: Sendable {
        let pattern: FilenameMatching.SelectionPattern
        let mode: Mode

        func selection<ID: Hashable & Sendable>(from old: Set<ID>, matching: Set<ID>) -> Set<ID> {
            switch mode {
            case .replace: return matching
            case .add: return old.union(matching)
            case .remove: return old.subtracting(matching)
            }
        }
    }

    static let title = "Select by Name"
    static func choose(in parent: NSWindow, scope: String) async -> Choice? {
        let mode = NSPopUpButton()
        mode.addItems(withTitles: Mode.allCases.map(\.title))
        mode.setAccessibilityLabel("How to apply matches")
        InterfaceMetrics.setFont(mode, base: .systemFont(ofSize: NSFont.systemFontSize))
        let sheet = NativeTextInputSheet(title: title, confirmTitle: "Apply",
            message: scope + " Use * for any text, as in *.pdf.",
            initial: "", fieldLabel: "Filename or pattern", additionalControl: mode) { input in
            if input.isEmpty { return "Enter part of a name or a pattern." }
            if input.utf8.count > 255 { return "Use a shorter pattern." }
            return FilenameMatching.SelectionPattern(input) == nil ? "Enter a valid filename pattern." : nil
        }
        guard let answer = await sheet.choose(in: parent), let pattern = FilenameMatching.SelectionPattern(answer),
              let selected = Mode(rawValue: mode.indexOfSelectedItem) else { return nil }
        return .init(pattern: pattern, mode: selected)
    }
}

/// The visible file surface keeps its own identity and selection. This request
/// owns the common sheet and a single cancellable pass over the captured names.
@MainActor final class NameSelectionRequest {
    private var work: Task<Void, Never>?
    var isIdle: Bool { work == nil }

    isolated deinit { work?.cancel() }

    func cancel() { work?.cancel() }

    func present<Item: Sendable, ID: Hashable & Sendable>(in parent: NSWindow, scope: String,
        entries: [Item], selected: Set<ID>, name: @escaping @Sendable (Item) -> String,
        id: @escaping @Sendable (Item) -> ID, isCurrent: @escaping @MainActor () -> Bool,
        apply: @escaping @MainActor (Set<ID>?) -> Void) {
        guard isIdle, parent.attachedSheet == nil, !entries.isEmpty else { return }
        work = Task { [weak self, weak parent] in
            defer { self?.work = nil }
            guard let parent, let choice = await NameSelectionPrompt.choose(in: parent, scope: scope),
                  !Task.isCancelled, isCurrent() else { return }
            let matcher = Task.detached(priority: .userInitiated) {
                var matches = Set<ID>()
                for entry in entries {
                    try Task.checkCancellation()
                    if choice.pattern.matches(name(entry)) { matches.insert(id(entry)) }
                }
                return matches
            }
            let matches = await withTaskCancellationHandler {
                try? await matcher.value
            } onCancel: { matcher.cancel() }
            guard let matches, !Task.isCancelled, parent.attachedSheet == nil, isCurrent() else { return }
            apply(matches.isEmpty ? nil : choice.selection(from: selected, matching: matches))
        }
    }
}
