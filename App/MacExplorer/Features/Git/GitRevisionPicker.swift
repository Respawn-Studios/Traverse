import AppKit
import LocalStorage
import SwiftUI

struct GitCommitLabel: View {
    let commit: GitCommitSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject.isEmpty ? "Untitled commit" : commit.subject).lineLimit(1).truncationMode(.tail)
            Text(commit.object.short).interfaceFont(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.help(commit.subject + "\n" + commit.object.hex)
    }
}

struct GitCommitDateLabel: View {
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits))
            .interfaceFont(.caption.monospacedDigit()).lineLimit(1)
            .help(date.formatted(date: .complete, time: .shortened))
    }
}

struct GitRevisionOption: Identifiable, Hashable, Sendable {
    let id: Data
    let title: String
    let detail: String
    let revision: GitRevisionSelection
    private(set) var isPinned = false

    func refreshed(in options: [Self]) -> Self? {
        options.first { $0.id == id } ?? (isPinned ? self : nil)
    }

    func resolved(to object: GitObjectID) -> Self {
        guard case .abbreviated = revision else { return self }
        return .init(id: id, title: title, detail: "Commit · " + object.short, revision: .object(object), isPinned: true)
    }

    static func choices(_ catalog: GitRevisionCatalog) -> [Self] {
        var result: [Self] = []
        if let head = catalog.head {
            result.append(.init(id: Data("HEAD".utf8), title: catalog.headName.map { "HEAD · " + $0 } ?? "HEAD",
                                detail: head.short, revision: .object(head)))
        }
        result += catalog.references.map { reference in
            let kind: String
            switch reference.kind {
            case .branch: kind = "Local branch"
            case .remoteTracking: kind = "Remote-tracking branch"
            case .tag: kind = "Tag"
            }
            return .init(id: reference.id, title: reference.name,
                         detail: kind + " · " + reference.object.short, revision: .object(reference.object))
        }
        result += catalog.recentCommits.map(commit)
        return result
    }

    static func commit(_ commit: GitCommitSummary) -> Self {
        .init(id: commitID(commit.object), title: commit.subject.isEmpty ? commit.object.short : commit.subject,
              detail: commit.object.short + " · " + commit.date.formatted(date: .abbreviated, time: .omitted),
              revision: .object(commit.object), isPinned: true)
    }

    static func pinnedCommit(_ object: GitObjectID, in choices: [Self]) -> Self {
        let id = commitID(object)
        return choices.first { $0.id == id } ?? .init(id: id, title: object.short, detail: "Pinned commit",
                                                        revision: .object(object), isPinned: true)
    }

    private static func commitID(_ object: GitObjectID) -> Data { Data(("commit/" + object.hex).utf8) }

    static func checkedOut(_ revision: GitCheckoutRevisionPair.Revision) -> Self {
        .init(id: Data(("checkout/" + revision.commit.hex + "/" + revision.head.displayName).utf8),
              title: revision.head.displayName, detail: "Checked out · " + revision.commit.short,
              revision: .object(revision.commit), isPinned: true)
    }

    static func entered(_ text: String) -> Self? {
        let hash = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (4...64).contains(hash.utf8.count),
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return .init(id: Data(("entered/" + hash).utf8), title: hash, detail: "Commit hash", revision: .abbreviated(hash), isPinned: true)
    }
}

struct GitRevisionPicker: View {
    struct Action {
        let title: String
        var enabled = true
        let perform: (GitRevisionOption) -> Void
    }

    struct ActionGroup {
        let title: String
        let items: [Action]
    }

    let label: String
    let selected: GitRevisionOption?
    let choices: [GitRevisionOption]
    var submitTitle = "Choose"
    var alternate: Action?
    var group: ActionGroup?
    let onSelection: (GitRevisionOption) -> Void
    @State private var shown = false
    @State private var presentation = UUID()

    var body: some View {
        Button {
            presentation = UUID()
            shown = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).interfaceFont(.caption).foregroundStyle(.secondary)
                    Text(selected?.title ?? "Choose revision…").interfaceFont(.callout.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").interfaceFont(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }
        .accessibilityLabel(label)
        .accessibilityValue(selected.map { $0.title + ", " + $0.detail } ?? "Choose revision")
        .help(selected.map { $0.title + " · " + $0.detail } ?? "Choose a branch, tag or commit")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            GitRevisionChoices(selected: selected, choices: choices, submitTitle: submitTitle,
                alternate: alternate, group: group, beforeSelection: { shown = false },
                onSelection: onSelection) { shown = false }
                .id(presentation)
        }
    }
}

/// The same focused query, native list and keyboard commands are used for
/// revision popovers and an explicit file revision sheet.
struct GitRevisionChoices: View {
    let choices: [GitRevisionOption]
    let submitTitle: String
    let alternate: GitRevisionPicker.Action?
    let group: GitRevisionPicker.ActionGroup?
    let showsCancel: Bool
    let back: (() -> Void)?
    let beforeSelection: () -> Void
    let onSelection: (GitRevisionOption) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var highlighted: GitRevisionOption.ID?

    init(selected: GitRevisionOption?, choices: [GitRevisionOption], submitTitle: String,
         alternate: GitRevisionPicker.Action? = nil, group: GitRevisionPicker.ActionGroup? = nil,
         showsCancel: Bool = false, back: (() -> Void)? = nil, beforeSelection: @escaping () -> Void = {},
         onSelection: @escaping (GitRevisionOption) -> Void, dismiss: @escaping () -> Void) {
        self.choices = choices
        self.submitTitle = submitTitle
        self.alternate = alternate
        self.group = group
        self.showsCancel = showsCancel
        self.back = back
        self.beforeSelection = beforeSelection
        self.onSelection = onSelection
        self.dismiss = dismiss
        _highlighted = State(initialValue: selected?.id)
    }

    private func options(for trimmed: String) -> (visible: [GitRevisionOption], limited: Bool) {
        let matches = trimmed.isEmpty ? choices
            : choices.filter { $0.title.localizedStandardContains(trimmed) || $0.detail.localizedStandardContains(trimmed) }
        let entered = GitRevisionOption.entered(trimmed)
        return ((entered.map { [$0] } ?? []) + matches.prefix(120), matches.count > 120)
    }

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let (visible, limited) = options(for: trimmed)
        let selection = visible.first { $0.id == highlighted } ?? visible.first
        return VStack(alignment: .leading, spacing: 9) {
            NativeQueryField(text: Binding(get: { query }, set: { value in
                if query != value { highlighted = nil; query = value }
            }), identifier: "git-revision-search", placeholder: "Find a branch, tag or commit", style: .focusedSearch,
                onCommand: handleKey)
            if visible.isEmpty {
                ContentUnavailableView.search(text: trimmed)
            } else {
                ScrollViewReader { scroller in
                    List(visible, selection: Binding(get: { selection?.id }, set: { highlighted = $0 })) { option in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title).interfaceFont(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Text(option.detail).interfaceFont(.caption).foregroundStyle(.secondary)
                        }
                        .tag(option.id)
                        .help(option.title + " · " + option.detail)
                        .onTapGesture(count: 2) { choose(option) }
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: selection?.id) { _, value in if let value { scroller.scrollTo(value) } }
                }
            }
            if limited {
                Text("Showing the first 120 matches").interfaceFont(.caption).foregroundStyle(.secondary)
            }
            if let group {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title).interfaceFont(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(group.items, id: \.title) { action in
                            Button { choose(selection, using: action.perform) } label: {
                                Text(action.title).interfaceFont(.caption)
                            }.disabled(selection == nil || !action.enabled)
                        }
                    }
                }
            }
            HStack {
                if showsCancel { Button("Cancel", role: .cancel, action: dismiss) }
                if let back { Button("Back", action: back) }
                Spacer()
                if let alternate {
                    Button { choose(selection, using: alternate.perform) } label: {
                        Text(alternate.title).interfaceFont(.caption)
                    }.disabled(selection == nil || !alternate.enabled)
                }
                Button { choose(selection) } label: { Text(submitTitle).interfaceFont(.caption) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(12)
        .frame(width: 394, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: dismiss)
    }

    private func handleKey(_ key: NativeQueryField.Key) -> Bool {
        let current = options(for: query.trimmingCharacters(in: .whitespacesAndNewlines)).visible
        switch key {
        case .submit: choose(current.first { $0.id == highlighted } ?? current.first); return true
        case .cancel: dismiss(); return true
        case .up: return moveHighlight(-1, through: current)
        case .down: return moveHighlight(1, through: current)
        }
    }

    private func moveHighlight(_ offset: Int, through options: [GitRevisionOption]) -> Bool {
        guard !options.isEmpty else { return false }
        let current = options.firstIndex { $0.id == highlighted } ?? 0
        highlighted = options[min(options.count - 1, max(0, current + offset))].id
        return true
    }

    private func choose(_ option: GitRevisionOption?, using action: ((GitRevisionOption) -> Void)? = nil) {
        guard let option else { return }
        beforeSelection()
        (action ?? onSelection)(option)
    }
}

@MainActor struct GitWorktreeSheet<Destination: Sendable> {
    struct Action {
        let title: String
        let destination: Destination
        let identifier: String
        var enabled = true
    }
    struct Choice: Sendable {
        let worktree: GitWorktree
        let destination: Destination
        let folder: GitSnapshotPath?
    }

    static func choose(_ listing: GitWorktreeListing, title: String = "Browse Git Worktrees", file: String? = nil,
                       matchingFolder: GitSnapshotPath? = nil,
                       primary: Action, alternate: Action? = nil, in parent: NSWindow) async -> Choice? {
        let rows = listing.worktrees.map { tree -> NativeChoiceSheet<Choice>.Row in
            let role = tree.isCurrent ? "Current checkout" : tree.isPrimary ? "Main checkout" : ""
            let detail = [tree.head.displayName, role].filter { !$0.isEmpty }.joined(separator: " · ")
            return .init(title: tree.url.lastPathComponent, detail: detail,
                value: .init(worktree: tree, destination: primary.destination, folder: matchingFolder),
                isEnabled: !tree.isCurrent, help: tree.url.path)
        }
        func button(_ action: Action) -> NativeChoiceSheet<Choice>.Button {
            .init(title: action.title, identifier: action.identifier, isEnabled: action.enabled) { choice, includeFolder in
                .init(worktree: choice.worktree, destination: action.destination, folder: includeFolder ? choice.folder : nil)
            }
        }
        let option = matchingFolder.map { path in
            NativeChoiceSheet<Choice>.Option(title: "Open matching folder",
                help: "Open \(path.display) when it exists in the chosen checkout.", initial: true)
        }
        let note = listing.isIncomplete ? "Some worktrees could not be read with the current access or inspection limit."
            : listing.worktrees.count == 1 ? "This repository has one available checkout." : nil
        let sheet = NativeChoiceSheet<Choice>(title: title, heading: file ?? "Choose a Git checkout", rows: rows,
            primary: button(primary), alternate: alternate.map(button), option: option, note: note,
            size: .init(width: 510, height: 330))
        return await sheet.choose(in: parent)
    }
}

@MainActor struct GitFileRevisionSheet<Intent: Sendable> {
    struct Choice: Sendable {
        let revision: GitRevisionOption
        let intent: Intent
    }

    struct Command {
        let title: String
        let intent: Intent
    }

    private let sheet: NativeChoiceSheet<Choice>

    init(filename: String, choices: [GitRevisionOption], primary: Command, alternate: Command? = nil) {
        sheet = NativeChoiceSheet(title: "Git Revision") { finish in
            VStack(alignment: .leading, spacing: 0) {
                Text(filename).interfaceFont(.headline).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 12).padding(.top, 12)
                GitRevisionChoices(selected: choices.first, choices: choices, submitTitle: primary.title, alternate:
                    alternate.map { command in .init(title: command.title) { finish(.init(revision: $0, intent: command.intent)) } },
                    showsCancel: true, onSelection: { finish(.init(revision: $0, intent: primary.intent)) }) { finish(nil) }
            }.padding(10)
        }
    }

    func choose(in parent: NSWindow) async -> Choice? { await sheet.choose(in: parent) }
}

enum EditorGitRevisionIntent: Int { case openOrCompare, comparePair, compareHead, compareIndex }

struct GitFileRevisionPair: Sendable {
    let left: GitRevisionOption
    let right: GitRevisionOption

    @MainActor static func choose(filename: String, choices: [GitRevisionOption], in parent: NSWindow) async -> Self? {
        await NativeChoiceSheet<Self>(title: "Compare Git Revisions") {
            GitFileRevisionPairChoices(filename: filename, choices: choices, finish: $0)
        }.choose(in: parent)
    }

    @MainActor func resolve(path: GitSnapshotPath, using access: GitReviewAccess) async throws -> EditorComparisonWindow.Source {
        let (first, second) = try await access.versions(path: path, left: left.revision, right: right.revision)
        guard let firstSource = first.editorTextSource, let secondSource = second.editorTextSource else {
            throw EditorComparisonLoadFailure.unavailable("One revision contains a folder, symbolic link or submodule at this path.")
        }
        guard firstSource.member != nil || secondSource.member != nil else {
            throw EditorComparisonLoadFailure.unavailable("This path is absent in both revisions. Git File History can show earlier names.")
        }
        let leftLabel = left.title + " · " + first.commit.short + (firstSource.member == nil ? " · Absent" : "")
        let rightLabel = right.title + " · " + second.commit.short + (secondSource.member == nil ? " · Absent" : "")
        return .init(labels: .init(title: "Git Text Diff", source: path.display, left: leftLabel, right: rightLabel,
            detail: "Text from two pinned Git revisions.", refresh: "Refresh"), read: {
            try await access.textComparison(left: firstSource.member, right: secondSource.member)
        })
    }
}

private struct GitFileRevisionPairChoices: View {
    let filename: String
    let choices: [GitRevisionOption]
    let finish: (GitFileRevisionPair?) -> Void
    @State private var left: GitRevisionOption?

    var body: some View {
        let choosingLeft = left == nil
        VStack(alignment: .leading, spacing: 0) {
            Text((choosingLeft ? "Left · " : "Right · ") + filename)
                .interfaceFont(.headline).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 12).padding(.top, 12)
                .help(left.map { "Left revision · " + $0.title + " · " + $0.detail } ?? filename)
            let preferred = choices.first { $0.revision != left?.revision }
            GitRevisionChoices(selected: preferred, choices: choices,
                submitTitle: choosingLeft ? "Choose Left" : "Compare", showsCancel: true,
                back: choosingLeft ? nil : { left = nil }, onSelection: { option in
                    if let left { finish(.init(left: left, right: option)) }
                    else { left = option }
                }) { finish(nil) }
                .id(choosingLeft)
        }.padding(10)
    }
}
