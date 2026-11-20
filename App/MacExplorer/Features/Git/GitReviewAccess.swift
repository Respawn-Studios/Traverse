import FileOperations
import Foundation
import LocalStorage

extension GitWorktree.Head {
    var displayName: String {
        switch self {
        case .branch(let name): name
        case .detached(let commit): "Detached at \(commit.short)"
        }
    }
}

extension GitFileVersion {
    var editorTextSource: (member: GitSnapshotMember?, label: String)? {
        switch state {
        case .absent: (nil, commit.short + " · Absent")
        case .member(let member) where member.isTextCandidate: (member, commit.short + " · " + path.display)
        default: nil
        }
    }
}

struct GitStatusBadge: Equatable {
    let text: String
    let details: [String]

    init?(_ status: GitFileStatus?) {
        guard let status else { return nil }
        var text = "", details: [String] = []
        if status.isConflicted { text += "!"; details.append("Git conflict") }
        if status.hasStagedChange { text += "S"; details.append("Git change staged") }
        if status.workingCopy == .differentBytes { text += "M"; details.append("On-disk bytes differ from the Git index") }
        if status.isUntracked { text += "?"; details.append("Untracked by Git") }
        guard !text.isEmpty else { return nil }
        self.text = text; self.details = details
    }
}

/// One cancellable status read per visible listing. A caller supplies only
/// current visible file URLs and its listing generation. No status crosses a
/// repository, visit or preference change.
@MainActor final class GitViewportBadges {
    static let maximumVisibleFiles = 96
    fileprivate static let indexChanged = Notification.Name("Traverse.GitIndexChanged")
    struct Request {
        let access: GitReviewAccess
        let urls: [URL]
        let generation: UUID
        let inspectWorkingBytes: Bool
        fileprivate var key: Key {
            .init(repository: access.location, urls: urls, generation: generation, inspectWorkingBytes: inspectWorkingBytes)
        }
    }
    fileprivate struct Key: Equatable {
        let repository: GitRepositoryLocation
        let urls: [URL]
        let generation: UUID
        let inspectWorkingBytes: Bool
    }
    private let request: @MainActor () -> Request?
    private let delivered: @MainActor (Set<URL>, Bool) -> Void
    private var settled: Key?
    private var running: Key?
    private var work: Task<Void, Never>?
    private var values: [URL: GitStatusBadge] = [:]
    private var indexObservation: BrowserNotificationObservation?
    private(set) var paused = false
    var isReading: Bool { work != nil }
    var inspectedCount: Int { settled?.urls.count ?? 0 }
    var markedCount: Int { values.count }

    init(request: @escaping @MainActor () -> Request?, delivered: @escaping @MainActor (Set<URL>, Bool) -> Void) {
        self.request = request; self.delivered = delivered
        indexObservation = BrowserNotificationObservation(name: Self.indexChanged) { [weak self] event in
            guard let edited = event.object as? GitRepositoryLocation else { return }
            MainActor.assumeIsolated { self?.indexDidChange(in: edited) }
        }
    }
    isolated deinit { work?.cancel() }

    func badge(for url: URL) -> GitStatusBadge? { values[url] }

    func invalidate(clear: Bool) {
        settled = nil
        work?.cancel()
        if clear { install([:], available: true) }
    }

    private func indexDidChange(in edited: GitRepositoryLocation) {
        let visible = request()?.access.location ?? running?.repository ?? settled?.repository
        guard visible?.isSameRepository(as: edited) == true else { return }
        invalidate(clear: false)
        update()
    }

    func pauseAndDrain() async {
        paused = true
        work?.cancel()
        await work?.value
    }

    func resume() {
        paused = false
        invalidate(clear: false)
        update()
    }

    func update() {
        let next = paused ? nil : request()
        if work != nil {
            if next?.key != running { work?.cancel() }
            return
        }
        guard let next, !next.urls.isEmpty, next.key != settled else { return }
        let key = next.key
        running = key
        work = Task { [weak self] in
            defer { if let self { work = nil; running = nil; update() } }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, !Task.isCancelled, request()?.key == key else { return }
            let result = try? await next.access.statuses(for: next.urls, inspectWorkingBytes: next.inspectWorkingBytes)
            guard !Task.isCancelled, request()?.key == key else { return }
            settled = key
            guard let result, result.count == next.urls.count else { install([:], available: false); return }
            let badges = zip(next.urls, result).compactMap { url, status in
                GitStatusBadge(status).map { (url, $0) }
            }
            install(Dictionary(uniqueKeysWithValues: badges), available: true)
        }
    }

    private func install(_ badges: [URL: GitStatusBadge], available: Bool) {
        let changed = Set(values.keys).union(badges.keys).filter { values[$0] != badges[$0] }
        values = badges
        delivered(changed, available)
    }
}

/// Git inspection uses the exact repository found by the browser and the
/// existing folder access owner. The package retains the leases until I/O and
/// its read-only child process have drained.
@MainActor struct GitReviewAccess {
    let location: GitRepositoryLocation
    let fileSystem: LocalFileSystem
    let access: FolderAccessController
    let scratch: URL

    init?(location: GitRepositoryLocation, fileSystem: LocalFileSystem, access: FolderAccessController) {
        guard let scratch = AppStorageLocations.layout?.cacheDirectory.appendingPathComponent("Git Reviews", isDirectory: true) else { return nil }
        self.location = location
        self.fileSystem = fileSystem
        self.access = access
        self.scratch = scratch
    }

    static func discover(in directory: URL, fileSystem: LocalFileSystem, access: FolderAccessController) async throws -> GitCheckoutObservation? {
        let prepared = access.prepareAccess(to: [directory])
        let lifetime = await access.retainAccess(for: [directory])
        try Task.checkCancellation()
        guard access.isCurrent(prepared) else { return nil }
        let requiresSelection = TraverseAccessPolicy.requiresFolderSelection
        if requiresSelection, !lifetime.covers(directory) { return nil }
        var boundary = requiresSelection ? lifetime.leases.first?.url : nil
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] {
            let fixture = URL(fileURLWithPath: root, isDirectory: true)
            if boundary?.pathComponents.starts(with: fixture.pathComponents) != true { boundary = fixture }
        }
        #endif
        return try await fileSystem.locateGitCheckout(at: directory, within: boundary, retaining: lifetime)
    }

    private func retainRepository() async throws -> FileAccessLifetimes {
        let roots = location.readAccessRoots
        let prepared = access.prepareAccess(to: roots)
        let lifetime = await access.retainAccess(for: roots)
        try Task.checkCancellation()
        guard access.isCurrent(prepared) else { throw GitInspectionFailure.changed }
        if TraverseAccessPolicy.requiresFolderSelection, !roots.allSatisfy(lifetime.covers) {
            throw GitInspectionFailure.unavailable
        }
        return lifetime
    }

    private func read<Value: Sendable>(_ work: (FileAccessLifetimes) async throws -> Value) async throws -> Value {
        let lifetime = try await retainRepository()
        return try await work(lifetime)
    }

    private func worktreeRoots(_ lifetime: FileAccessLifetimes) -> [URL]? {
        var roots = TraverseAccessPolicy.requiresFolderSelection ? lifetime.leases.map(\.url) : nil
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] {
            let fixture = URL(fileURLWithPath: root, isDirectory: true)
            roots = roots?.compactMap { root in
                if root.pathComponents.starts(with: fixture.pathComponents) { return root }
                return fixture.pathComponents.starts(with: root.pathComponents) ? fixture : nil
            } ?? [fixture]
        }
        #endif
        return roots
    }

    func worktrees() async throws -> GitWorktreeListing {
        try await read { try await fileSystem.readGitWorktrees(in: location, allowedRoots: worktreeRoots($0), retaining: $0) }
    }

    func verifiedURL(for worktree: GitWorktree, matching folder: GitSnapshotPath?) async throws -> URL {
        try await read { try await fileSystem.verifyGitWorktree(worktree, in: location, matching: folder,
            allowedRoots: worktreeRoots($0), retaining: $0) }
    }

    func worktreeFile(_ path: GitSnapshotPath, in worktree: GitWorktree, readingText: Bool = false) async throws -> GitWorktreeFile {
        try await read { lifetime in
            // Acquire a lease for the selected checkout as well as the
            // originating repository and its common object store.
            let prepared = access.prepareAccess(to: [worktree.url])
            let selected = await access.retainAccess(for: [worktree.url])
            try Task.checkCancellation()
            guard access.isCurrent(prepared) else { throw GitInspectionFailure.changed }
            let combined = FileAccessLifetimes(leases: lifetime.leases + selected.leases)
            if TraverseAccessPolicy.requiresFolderSelection && !combined.covers(worktree.url) {
                throw GitInspectionFailure.unavailable
            }
            return try await fileSystem.inspectGitWorktreeFile(path, in: worktree, from: location,
                allowedRoots: worktreeRoots(combined), readingText: readingText, retaining: combined)
        }
    }

    func catalog(pairedWith peer: Self? = nil) async throws -> GitRevisionCatalog {
        try await read { lifetime in
            let retained: FileAccessLifetimes
            if let peer {
                let other = try await peer.retainRepository()
                retained = .init(leases: lifetime.leases + other.leases)
            } else { retained = lifetime }
            return try await fileSystem.gitRevisionCatalog(in: location, pairedWith: peer?.location, scratch: scratch, retaining: retained)
        }
    }

    func compare(left: GitRevisionSelection, right: GitRevisionSelection, basis: GitTreeComparison.Basis,
                 wholeRepository: Bool) async throws -> GitTreeComparison {
        try await read {
            try await fileSystem.compareGitRevisions(in: location, left: left, right: right, basis: basis,
                wholeRepository: wholeRepository, scratch: scratch, retaining: $0)
        }
    }

    func compareIndex(against revision: GitRevisionSelection?, wholeRepository: Bool) async throws -> GitStagedComparison {
        try await read {
            try await fileSystem.compareGitIndex(in: location, against: revision,
                wholeRepository: wholeRepository, scratch: scratch, retaining: $0)
        }
    }

    func prepareIndexEdit(_ action: GitIndexEditAction, path: GitSnapshotPath,
                          matchingSavedText: LocalTextReadToken? = nil) async throws -> GitIndexEditPlan {
        try await read {
            try await fileSystem.prepareGitIndexEdit(action, path: path, in: location, scratch: scratch,
                matchingSavedText: matchingSavedText, retaining: $0)
        }
    }

    func applyIndexEdit(_ plan: GitIndexEditPlan) async throws {
        try await read { try await fileSystem.applyGitIndexEdit(plan, scratch: scratch, retaining: $0) }
        NotificationCenter.default.post(name: GitViewportBadges.indexChanged, object: location)
    }

    func commitRange(left: GitObjectID, right: GitObjectID) async throws -> GitCommitRange {
        try await read { try await fileSystem.readGitCommitRange(in: location, left: left, right: right, scratch: scratch, retaining: $0) }
    }

    func folderHistory(from revision: GitRevisionSelection, wholeRepository: Bool) async throws -> GitFolderHistory {
        try await read { try await fileSystem.readGitFolderHistory(in: location, from: revision,
            wholeRepository: wholeRepository, scratch: scratch, retaining: $0) }
    }

    func commitChanges(_ commit: GitRangeCommit, parent: GitObjectID?, wholeRepository: Bool) async throws -> GitCommitChanges {
        try await read { try await fileSystem.readGitCommitChanges(in: location, commit: commit, parent: parent,
            wholeRepository: wholeRepository, scratch: scratch, retaining: $0) }
    }

    func folders(left: GitObjectID, right: GitObjectID, at path: GitSnapshotPath?) async throws -> GitRevisionFolders {
        try await read { try await fileSystem.readGitFolders(in: location, left: left, right: right, at: path,
            scratch: scratch, retaining: $0) }
    }

    func workingFolder(at path: GitSnapshotPath?, baseline: GitWorkingFolder.Baseline, showHidden: Bool) async throws -> GitWorkingFolder {
        try await read {
            try await fileSystem.readGitWorkingFolder(in: location, at: path, baseline: baseline,
                showHidden: showHidden, scratch: scratch, retaining: $0)
        }
    }

    func workingComparison(_ selection: GitWorkingFolder.TextSelection) async throws -> EditorComparisonCapture {
        do {
            let pair = try await read { try await fileSystem.readGitWorkingFolderText(selection, scratch: scratch, retaining: $0) }
            let language = TextSyntaxLanguage.inferred(extension: EditorOpeningSupport.key(forFilename: selection.path.name) ?? "")
            return .init(documents: pair, leftLanguage: language, rightLanguage: language)
        } catch is CancellationError {
            throw CancellationError()
        } catch GitInspectionFailure.changed, TextComparisonReadFailure.changed {
            throw EditorComparisonLoadFailure.unavailable("A compared file or the Git index changed. Reload the folder review and select the file again.")
        } catch let failure as GitInspectionFailure {
            throw EditorComparisonLoadFailure.unavailable(failure.userMessage)
        } catch {
            throw EditorComparisonLoadFailure.unavailable("These versions could not both be opened as supported UTF-8 text.")
        }
    }

    func workingReference(_ selection: GitWorkingFolder.TextSelection) async throws -> EditorComparisonCapture.Side {
        do {
            let value = try await read { try await fileSystem.readGitWorkingFolderReference(selection, scratch: scratch, retaining: $0) }
            return .init(text: value.text, format: value.format, language: language(for: selection.referenceMember))
        } catch is CancellationError { throw CancellationError() }
        catch GitInspectionFailure.changed {
            throw EditorComparisonLoadFailure.unavailable("The compared Git version changed. Reload the folder review and select the file again.")
        } catch { throw EditorComparisonLoadFailure.unavailable(Self.message(for: error)) }
    }

    func checkWorkingContents(_ folder: GitWorkingFolder) async throws -> GitWorkingFolder.ContentReview {
        try await read { try await fileSystem.checkGitWorkingFolderContents(folder, retaining: $0) }
    }

    func openHistory(path: GitSnapshotPath, from revision: GitRevisionSelection) async throws -> (GitRevisionCatalog, GitFileHistory) {
        try await read { try await fileSystem.openGitFileHistory(in: location, path: path, from: revision, scratch: scratch, retaining: $0) }
    }

    func history(path: GitSnapshotPath, from revision: GitRevisionSelection) async throws -> GitFileHistory {
        try await read { try await fileSystem.gitFileHistory(in: location, path: path, from: revision, scratch: scratch, retaining: $0) }
    }

    func versions(path: GitSnapshotPath, left: GitRevisionSelection, right: GitRevisionSelection) async throws -> (GitFileVersion, GitFileVersion) {
        try await read { try await fileSystem.gitFileVersions(in: location, path: path, left: left, right: right, scratch: scratch, retaining: $0) }
    }

    func version(path: GitSnapshotPath, at revision: GitRevisionSelection) async throws -> GitFileVersion {
        try await read { try await fileSystem.gitFileVersion(in: location, path: path, at: revision, scratch: scratch, retaining: $0) }
    }

    func versionText(path: GitSnapshotPath, at revision: GitRevisionSelection) async throws -> (GitFileVersion, TextDocumentValue?) {
        try await read { try await fileSystem.readGitFileVersion(in: location, path: path, at: revision, scratch: scratch, retaining: $0) }
    }

    func text(_ member: GitSnapshotMember) async throws -> TextDocumentValue {
        try await read { try await fileSystem.readGitText(in: location, member: member, scratch: scratch, retaining: $0) }
    }

    func lineOrigin(of member: GitSnapshotMember, at commit: GitObjectID, line: Int) async throws -> GitLineOrigin {
        try await read {
            try await fileSystem.gitLineOrigin(in: location, member: member, at: commit, line: line, scratch: scratch, retaining: $0)
        }
    }

    func headLineOrigin(of path: GitSnapshotPath,
                        matchingLine: @escaping @Sendable (TextDocumentValue, @Sendable () -> Bool) throws -> Int)
        async throws -> (version: GitFileVersion, line: Int, origin: GitLineOrigin)? {
        try await read {
            try await fileSystem.gitHEADLineOrigin(in: location, path: path, scratch: scratch, retaining: $0, matchingLine: matchingLine)
        }
    }

    func statuses(for urls: [URL], inspectWorkingBytes: Bool) async throws -> [GitFileStatus] {
        try await read { try await fileSystem.gitFileStatuses(in: location, urls: urls, inspectWorkingBytes: inspectWorkingBytes,
            scratch: scratch, retaining: $0) }
    }

    func indexText(for url: URL) async throws -> TextDocumentValue {
        try await read { try await fileSystem.readGitIndexText(in: location, url: url, scratch: scratch, retaining: $0) }
    }

    func workingText(for url: URL) async throws -> TextDocumentValue {
        try await read { try await fileSystem.readGitWorkingText(in: location, url: url, retaining: $0) }
    }

    func committedSide(_ member: GitSnapshotMember?) async throws -> EditorComparisonCapture.Side {
        do {
            let value: TextDocumentValue
            if let member { value = try await text(member) }
            else { value = try .original(Data()) }
            return .init(text: value.text, format: value.format, language: language(for: member))
        } catch is CancellationError { throw CancellationError() }
        catch { throw EditorComparisonLoadFailure.unavailable(Self.message(for: error)) }
    }

    func textComparison(left: GitSnapshotMember?, right: GitSnapshotMember?) async throws -> EditorComparisonCapture {
        let documents: TextComparisonDocuments
        do {
            documents = try await read {
                try await fileSystem.readGitTextComparison(in: location, left: left, right: right, scratch: scratch, retaining: $0)
            }
        } catch let failure as GitInspectionFailure {
            throw EditorComparisonLoadFailure.unavailable(failure.userMessage)
        } catch is TextDocumentFailure {
            throw EditorComparisonLoadFailure.unavailable("These versions are outside Traverse’s supported UTF-8 text limits.")
        } catch let failure as LocalStorageError {
            throw EditorComparisonLoadFailure.unavailable(failure.userMessage)
        }
        return .init(documents: documents, leftLanguage: language(for: left), rightLanguage: language(for: right))
    }

    private func language(for member: GitSnapshotMember?) -> TextSyntaxLanguage {
        let name = member?.path.display.split(separator: "/").last.map(String.init) ?? ""
        return .inferred(extension: EditorOpeningSupport.key(forFilename: name) ?? "")
    }

    static func message(for error: Error) -> String {
        if error is CancellationError { return "Git review stopped." }
        if let failure = error as? EditorComparisonLoadFailure, case .unavailable(let message) = failure { return message }
        if error is TextDocumentFailure { return "This version is outside Traverse’s supported UTF-8 text limits." }
        if let error = error as? GitInspectionFailure { return error.userMessage }
        if let error = error as? LocalStorageError { return error.userMessage }
        return "The repository could not be read. Refresh to try again."
    }
}
