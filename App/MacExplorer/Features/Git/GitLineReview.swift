import AppKit
import LocalStorage

/// One deliberate lookup from an exact editor and line. Both the checked-out
/// editor and a pinned Git snapshot use the same commit sheet and history reader.
@MainActor final class GitLineReview {
    private enum Source {
        case revision(GitReviewAccess, GitSnapshotMember, GitObjectID)
        case working(LocalFileSystem, FolderAccessController)
    }

    private struct LocatedLine: Sendable {
        let access: GitReviewAccess
        let member: GitSnapshotMember
        let commit: GitObjectID
        let line: Int
        let origin: GitLineOrigin
    }

    private weak var editor: NativeTextEditorWindow?
    private let source: Source
    private let settings: BrowserSettings
    private let request = GitReviewRequest()
    private var alert: NSAlert?
    private var original: NativeTextSnapshotController?

    init(editor: NativeTextEditorWindow, access: GitReviewAccess, member: GitSnapshotMember,
         commit: GitObjectID, settings: BrowserSettings) {
        self.editor = editor; self.source = .revision(access, member, commit); self.settings = settings
    }

    init(editor: NativeTextEditorWindow, fileSystem: LocalFileSystem, folders: FolderAccessController, settings: BrowserSettings) {
        self.editor = editor; self.source = .working(fileSystem, folders); self.settings = settings
    }

    var isSnapshot: Bool {
        if case .revision = source { return true }
        return false
    }
    var isAvailable: Bool { settings.showsGitControls && (isSnapshot || currentFile != nil) }
    var isRunning: Bool { request.isRunning }
    var canLookUp: Bool { isAvailable && !isRunning && currentLine != nil && editor?.window?.attachedSheet == nil }

    private var currentFile: URL? { editor?.fileSidebar?.files?.currentHistoryFile }

    private var currentLine: Int? {
        guard let surface = editor?.surface, let index = surface.lineIndex,
              !surface.textView.hasMarkedText(), surface.textView.selectedRanges.count == 1 else { return nil }
        let range = surface.textView.selectedRange()
        let end = range.length > 0 ? NSMaxRange(range) - 1 : range.location
        guard let location = index.location(at: range.location), index.location(at: end)?.line == location.line,
              let start = index.start(ofLine: location.line), start < index.length else { return nil }
        return location.line
    }

    func lookUp() {
        guard canLookUp, let line = currentLine, let editor, let parent = editor.window, parent.isKeyWindow else { return }
        let file = currentFile, generation = editor.surface.generation
        let working = isSnapshot ? nil : editor.surface.textView.string
        let navigator = editor.fileSidebar?.files
        let prior = editor.navigationStatus
        let reading = "Finding the Git commit for line \(line.formatted())…"
        editor.reportNavigation(reading)
        request.start({ [source, settings, weak navigator] in
            await navigator?.pauseGitBadges()
            defer { navigator?.resumeGitBadges() }
            try Task.checkCancellation()
            switch source {
            case .revision(let access, let member, let commit):
                let origin = try await access.lineOrigin(of: member, at: commit, line: line)
                return LocatedLine(access: access, member: member, commit: commit, line: line, origin: origin)
            case .working(let fileSystem, let folders):
                guard let file, let working else { throw GitInspectionFailure.lineUnavailable }
                return try await Self.workingLine(line, file: file, text: working, fileSystem: fileSystem, folders: folders,
                    settings: settings)
            }
        }) { [weak self, weak parent] result in
            guard let self, let parent, let editor = self.editor else { return }
            let ownsStatus = editor.navigationStatus == reading
            if ownsStatus { editor.reportNavigation(prior) }
            guard isAvailable, parent.isKeyWindow, parent.attachedSheet == nil, currentLine == line,
                  editor.surface.generation == generation, currentFile == file else { return }
            switch result {
            case .success(let location): present(location, editorLine: line, in: parent)
            case .failure(let error):
                if ownsStatus { editor.reportNavigation(GitReviewAccess.message(for: error)) }
            }
        }
    }

    private static func workingLine(_ line: Int, file: URL, text: String, fileSystem: LocalFileSystem,
                                    folders: FolderAccessController, settings: BrowserSettings) async throws -> LocatedLine {
        guard settings.showsGitControls,
              let checkout = try await GitReviewAccess.discover(in: file.deletingLastPathComponent(), fileSystem: fileSystem, access: folders),
              let path = checkout.location.filePath(for: file),
              let access = GitReviewAccess(location: checkout.location, fileSystem: fileSystem, access: folders) else {
            throw GitInspectionFailure.lineUnavailable
        }
        let location = try await access.headLineOrigin(of: path) { contents, cancelled in
            let match = try EditorTextComparison.committedLine(line, in: text, comparedWith: contents.text, cancelled: cancelled)
            switch match {
            case .exact(let number): return number
            case .changed: throw EditorComparisonLoadFailure.unavailable("This line differs from HEAD.")
            case .ambiguous: throw EditorComparisonLoadFailure.unavailable("This line has more than one possible match in Git.")
            case .limited: throw EditorComparisonLoadFailure.unavailable("This comparison is too large to identify the exact line.")
            }
        }
        guard let location, let member = location.version.editorTextSource?.member else {
            throw EditorComparisonLoadFailure.unavailable("HEAD has no text version at this path.")
        }
        return .init(access: access, member: member, commit: location.version.commit, line: location.line, origin: location.origin)
    }

    private func present(_ location: LocatedLine, editorLine: Int, in parent: NSWindow) {
        let origin = location.origin
        let result = NSAlert()
        result.alertStyle = .informational
        result.messageText = "Commit for Line " + editorLine.formatted()
        let revision = origin.commit.object.short + " · " + origin.author + " · " + origin.commit.date.formatted(date: .abbreviated, time: .omitted)
        let path = origin.path.display + " · Line " + origin.line.formatted()
        let mapped = location.line != editorLine ? "\nMatched line \(location.line.formatted()) at \(location.commit.short)." : ""
        let boundary = origin.isBoundary ? "\n\nOldest available history for this line." : ""
        result.informativeText = "\(origin.commit.subject)\n\(revision)\n\n\(path)\(mapped)\(boundary)"
        result.addButton(withTitle: "Done").keyEquivalent = "\u{1b}"
        if !isSnapshot || origin.commit.object != location.commit || origin.path != location.member.path || origin.line != location.line {
            result.addButton(withTitle: "Open Original Line")
        }
        alert = result
        result.beginSheetModal(for: parent) { [weak self, weak result, weak parent] response in
            guard let self, let result, alert === result else { return }
            alert = nil
            if response == .alertSecondButtonReturn, let parent { open(location, in: parent) }
        }
    }

    private func open(_ location: LocatedLine, in parent: NSWindow) {
        guard !isRunning, parent.isVisible, let editor else { return }
        let origin = location.origin, access = location.access
        let prior = editor.navigationStatus, reading = "Opening the original line…"
        editor.reportNavigation(reading)
        request.start({ [prior = original] in
            await prior?.closeAndDrain()
            try Task.checkCancellation()
            return try await access.versionText(path: origin.path, at: .object(origin.commit.object))
        }) { [weak self, weak parent] result in
            guard let self, let parent, let editor = self.editor else { return }
            let ownsStatus = editor.navigationStatus == reading
            if ownsStatus { editor.reportNavigation(prior) }
            guard isAvailable, parent.isVisible, parent.isKeyWindow else { return }
            switch result {
            case .success(let (version, text)):
                guard let text, let member = version.editorTextSource?.member else {
                    if ownsStatus { editor.reportNavigation("The original line’s file could not be opened as text.") }
                    return
                }
                let viewer = NativeTextSnapshotController.gitVersion(text: text, member: member, commit: version.commit,
                    access: access, settings: settings, parent: parent)
                viewer.initialLine = origin.line
                original = viewer
                viewer.didClose = { [weak self, weak viewer] _ in if self?.original === viewer { self?.original = nil } }
                viewer.show()
            case .failure(let error):
                if ownsStatus { editor.reportNavigation(GitReviewAccess.message(for: error)) }
            }
        }
    }

    func stop() { request.stop() }

    func closeAndDrain() async {
        if let alert, let parent = editor?.window {
            self.alert = nil
            if parent.attachedSheet === alert.window { parent.endSheet(alert.window) }
        }
        await request.closeAndDrain()
        await original?.closeAndDrain()
    }

    #if DEBUG
    var alertForVerification: NSAlert? { alert }
    var originalForVerification: NativeTextSnapshotController? { original }
    #endif
}
