import Darwin
import ExplorerCore
import FileOperations
import Foundation

public struct ListingIssue: Sendable {
    public let message: String
    public let url: URL?

    public init(message: String, url: URL? = nil) {
        self.message = message
        self.url = url
    }
}

public enum ListingEvent: Sendable {
    case batch([FileEntry])
    case finished(issues: [ListingIssue])
}

public struct BoundedFolderListing: Sendable {
    public let entries: [FileEntry]
    public let isComplete: Bool
    public let hasUnavailableItems: Bool
}

public enum VolumeKind: String, Sendable {
    case internalDisk, externalDisk, network, unknown
}

public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let kind: VolumeKind
    public let totalBytes: Int64?
    public let availableBytes: Int64?
    public let isReadOnly: Bool?

    public init(url: URL, name: String, kind: VolumeKind, totalBytes: Int64? = nil,
                availableBytes: Int64? = nil, isReadOnly: Bool? = nil) {
        self.url = url
        self.name = name
        self.kind = kind
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isReadOnly = isReadOnly
    }
}

public enum LocalStorageError: Error, Sendable {
    case accessDenied, notFound, notDirectory, unavailable, busy, other(String)

    public var userMessage: String {
        switch self {
        case .accessDenied: "Access to this location was denied."
        case .notFound: "This location could not be found."
        case .notDirectory: "This location is not a folder."
        case .unavailable: "This location is currently unavailable."
        case .busy: "Location inspection is busy. Wait for the current checks to finish, then try again."
        case .other: "This location could not be read."
        }
    }
}

public struct LocalProjectTextScope: Sendable {
    fileprivate let root: URL
    fileprivate let identity: EntrySnapshot
}

public struct LocalProjectTextBatch: Sendable {
    public struct File: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let entry: FileEntry
        public let contents: TextDocumentValue
        public var description: String { "<project text snapshot>" }
        public var debugDescription: String { description }
    }
    public let files: [File]
    /// The consumed prefix includes refusals. Work beyond it needs another
    /// explicit request, with a fresh budget and the same directory identity.
    public let consumed: Int
    public let skipped: Int
    public static let maximumFiles = 64
}

/// Bounded local browsing and review. Listings read metadata. Text and content
/// comparisons require explicit requests, and this service never writes user files.
public final class LocalFileSystem: @unchecked Sendable {
    private let queue: OperationQueue
    private let batchSize: Int
    private let activityGate: FileActivityGate?
    internal static let maximumLocationReads = 8
    private let readAdmissionLock = NSLock()
    private var pendingLocationReads = 0
    private var comparisonPending = false
    internal var outstandingLocationReads: Int { readAdmissionLock.withLock { pendingLocationReads } }

    public init(batchSize: Int = 256, maximumConcurrentReads: Int = 2, activityGate: FileActivityGate? = nil) {
        self.batchSize = max(1, batchSize)
        self.activityGate = activityGate
        queue = OperationQueue()
        queue.name = "MacExplorer.LocalStorage"
        queue.maxConcurrentOperationCount = max(1, maximumConcurrentReads)
        queue.qualityOfService = .userInitiated
    }

    /// Retains a caller-supplied access lease through actual filesystem-worker
    /// completion, including after the consumer cancels its stream.
    public func entries(in url: URL, showHidden: Bool = false, retaining lifetime: (any Sendable)? = nil,
                        didDrain: (@Sendable () -> Void)? = nil) -> AsyncThrowingStream<ListingEvent, Error> {
        let batchSize = batchSize
        let activityGate = activityGate
        return AsyncThrowingStream { continuation in
            let cancellation = ReadCancellation()
            let operation = BlockOperation {
                defer { withExtendedLifetime(lifetime) {} }
                do {
                    let activity = try activityGate?.begin()
                    defer { withExtendedLifetime(activity) {} }
                    _ = try Self.enumerate(url, showHidden: showHidden, batchSize: batchSize, cancellation: cancellation) {
                        if case .terminated = continuation.yield($0) { return false }
                        return true
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Completion also runs for a cancelled queued operation. Consumers
            // can coalesce new demand until actual worker/lease completion,
            // rather than mistaking stream cancellation for an I/O drain.
            operation.completionBlock = didDrain
            continuation.onTermination = { @Sendable _ in
                cancellation.cancel()
                // A cancelled queued operation never begins filesystem work.
                operation.cancel()
            }
            queue.addOperation(operation)
        }
    }

    /// A small, one-level listing for consumers that expand a selected folder
    /// in place. The same metadata reader serves the regular browser listing.
    public func boundedEntries(in url: URL, within scope: URL, maximum: Int = 512, showHidden: Bool = false,
                               retaining lifetime: (any Sendable)? = nil) async throws -> BoundedFolderListing {
        guard (1...2_048).contains(maximum) else { throw LocalStorageError.unavailable }
        return try await enqueueRead(retaining: lifetime, didDrain: {}) { cancellation in
            try withoutMaterialization {
                guard !AutomaticMetadataPolicy.excludes(url), !AutomaticMetadataPolicy.excludes(scope) else {
                    throw LocalStorageError.unavailable
                }
                let root = try DirectoryAnchor(scope, resolve: false)
                let folder = try DirectoryAnchor(url, resolve: false)
                guard root.contains(folder), folder.isOnLocalVolume else { throw LocalStorageError.unavailable }
                var entries: [FileEntry] = []
                var issues = false
                let complete = try Self.enumerate(folder.url, showHidden: showHidden, batchSize: maximum,
                    cancellation: cancellation, anchor: folder, maximum: maximum) { event in
                    switch event {
                    case .batch(let batch): entries += batch
                    case .finished(let found): issues = !found.isEmpty
                    }
                    return true
                }
                try root.validate()
                try folder.validate()
                try cancellation.check()
                let ordered = entries.sorted { a, b in
                    if a.kind == .directory && b.kind != .directory { return true }
                    if b.kind == .directory && a.kind != .directory { return false }
                    let order = a.name.localizedStandardCompare(b.name)
                    return order == .orderedSame ? a.name.utf8.lexicographicallyPrecedes(b.name.utf8) : order == .orderedAscending
                }
                return .init(entries: ordered, isComplete: complete, hasUnavailableItems: issues)
            }
        }
    }

    public func volumes() async throws -> [VolumeInfo] {
        let cancellation = ReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    do {
                        try cancellation.check()
                        let activity = try self.activityGate?.begin()
                        defer { withExtendedLifetime(activity) {} }
                        let keys: Set<URLResourceKey> = [
                            .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
                            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsReadOnlyKey,
                        ]
                        guard let urls = FileManager().mountedVolumeURLs(
                            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]
                        ) else { throw LocalStorageError.unavailable }
                        var result: [VolumeInfo] = []
                        for url in urls {
                            try cancellation.check()
                            // A disconnected or inaccessible mount remains visible with unknown facts.
                            let values: URLResourceValues
                            do { values = try url.resourceValues(forKeys: keys) }
                            catch {
                                result.append(VolumeInfo(url: url, name: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,
                                                         kind: .unknown))
                                continue
                            }
                            let kind: VolumeKind
                            if values.volumeIsLocal == false { kind = .network }
                            else if values.volumeIsInternal == true { kind = .internalDisk }
                            else if values.volumeIsLocal == true && values.volumeIsInternal == false { kind = .externalDisk }
                            else { kind = .unknown }
                            result.append(VolumeInfo(
                                url: url, name: values.volumeName ?? url.lastPathComponent,
                                kind: kind, totalBytes: values.volumeTotalCapacity.map(Int64.init),
                                availableBytes: values.volumeAvailableCapacity.map(Int64.init),
                                isReadOnly: values.volumeIsReadOnly
                            ))
                        }
                        try cancellation.check()
                        continuation.resume(returning: result.sorted { $0.url.path < $1.url.path })
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Finds the reported entry or its nearest existing ancestor with at most
    /// 64 metadata-only probes. The final entry's symlink is not followed.
    /// Denied/disconnected observations throw instead of claiming absence.
    /// Cancellation never frees a worker slot or access lease before a blocked
    /// probe has returned; canceled queued requests perform no filesystem read.
    public func nearestExistingLocation(to url: URL, retaining lifetime: (any Sendable)? = nil) async throws -> URL? {
        try await nearestExistingLocation(to: url, retaining: lifetime, afterProbe: nil, didEnqueue: nil)
    }

    /// Reserve bounded admission before acquiring access. The exact resulting
    /// lifetime transfers to the worker and remains held through actual drain.
    public func nearestExistingLocation(to url: URL,
        acquiring lifetime: @Sendable () async throws -> (any Sendable)?) async throws -> URL? {
        guard url.isFileURL else { throw LocalStorageError.unavailable }
        try reserveLocationRead()
        let retained: (any Sendable)?
        do {
            try Task.checkCancellation()
            retained = try await lifetime()
            try Task.checkCancellation()
        } catch { releaseLocationRead(); throw error }
        return try await enqueueNearestRead(to: url, retaining: retained, afterProbe: nil, didEnqueue: nil)
    }

    // Gates surround actual metadata observations in focused worker-drain tests.
    internal func nearestExistingLocation(to url: URL, retaining lifetime: (any Sendable)?,
                                          afterProbe: (@Sendable (URL) -> Void)?,
                                          didEnqueue: (@Sendable () -> Void)?) async throws -> URL? {
        guard url.isFileURL else { throw LocalStorageError.unavailable }
        try reserveLocationRead()
        return try await enqueueNearestRead(to: url, retaining: lifetime, afterProbe: afterProbe, didEnqueue: didEnqueue)
    }

    private func reserveLocationRead() throws {
        try readAdmissionLock.withLock {
            guard pendingLocationReads < Self.maximumLocationReads else { throw LocalStorageError.busy }
            pendingLocationReads += 1
        }
    }
    private func releaseLocationRead() { readAdmissionLock.withLock { pendingLocationReads -= 1 } }

    /// The default compares metadata. An explicit content request checks a
    /// bounded set of paired files. Access stays alive until the worker drains.
    public func compareFolders(left: URL, right: URL, includingHidden: Bool, checkingContents: Bool = false,
                               retaining lifetime: (any Sendable)? = nil) async throws -> FolderComparisonReport {
        try await comparisonRead(retaining: lifetime) { cancellation in
            try FolderMetadataComparison.read(left: left, right: right, includingHidden: includingHidden, checkingContents: checkingContents,
                                              checkCancellation: cancellation.check)
        }
    }

    public func linkFolderNavigation(_ first: URL, _ second: URL,
                                     retaining lifetime: (any Sendable)? = nil) async throws -> LinkedFolderRoots {
        try await locationRead(retaining: lifetime) { cancellation in
            try withoutMaterialization { try LinkedFolderRoots(first, second, check: cancellation.check) }
        }
    }

    public func correspondingFolder(in pair: LinkedFolderRoots, from root: URL, visited: URL,
                                    retaining lifetime: (any Sendable)? = nil) async throws -> URL {
        try await locationRead(retaining: lifetime) { cancellation in
            try withoutMaterialization { try pair.correspondingFolder(from: root, visited: visited, check: cancellation.check) }
        }
    }

    public func readTextComparison(left: URL, right: URL,
                                   retaining lifetime: (any Sendable)? = nil) async throws -> TextComparisonDocuments {
        try await comparisonRead(retaining: lifetime) { cancellation in
            try LocalTextComparisonRead.read(left: left, right: right, checkCancellation: cancellation.check)
        }
    }

    public func readFolderComparisonText(_ selection: FolderComparisonReport.TextSelection,
                                         retaining lifetime: (any Sendable)? = nil) async throws -> TextComparisonDocuments {
        try await comparisonRead(retaining: lifetime) { cancellation in
            try LocalTextComparisonRead.read(selection, checkCancellation: cancellation.check)
        }
    }

    public func prepareFolderComparisonEditor(_ selection: FolderComparisonReport.EditorSelection,
                                              retaining lifetime: (any Sendable)? = nil) async throws -> LocalTextOpenSelection {
        try await comparisonRead(retaining: lifetime) { cancellation in
            try LocalTextComparisonRead.editorSelection(selection, checkCancellation: cancellation.check)
        }
    }

    public func prepareProjectText(in rootURL: URL, within projectURL: URL? = nil,
                                   retaining lifetime: (any Sendable)? = nil) async throws -> LocalProjectTextScope {
        let rootURL = rootURL.standardizedFileURL
        guard !AutomaticMetadataPolicy.excludesProjectText(rootURL) else { throw LocalStorageError.accessDenied }
        return try await locationRead(retaining: lifetime) { cancellation in
            try cancellation.check()
            return try withoutMaterialization {
                let root = try DirectoryAnchor(rootURL, resolve: false)
                guard root.isOnLocalVolume else { throw LocalStorageError.unavailable }
                if let projectURL, projectURL != rootURL {
                    let project = try DirectoryAnchor(projectURL, resolve: false)
                    guard project.contains(root) else { throw LocalStorageError.unavailable }
                    try project.validate()
                    try root.validate()
                }
                return .init(root: rootURL, identity: root.identity)
            }
        }
    }

    public func validateProjectTextScope(_ scope: LocalProjectTextScope, retaining lifetime: (any Sendable)? = nil) async throws {
        let current = try await prepareProjectText(in: scope.root, retaining: lifetime)
        guard current.identity.sameObject(as: scope.identity) else { throw TextComparisonReadFailure.changed }
    }

    /// One explicit, bounded body read below a verified local project folder. The
    /// caller keeps folder access alive through this worker and its results.
    public func readProjectText(_ candidates: ArraySlice<FileEntry>, within scope: LocalProjectTextScope,
                                retaining lifetime: (any Sendable)? = nil) async throws -> LocalProjectTextBatch {
        try await comparisonRead(retaining: lifetime) { cancellation in
            try withoutMaterialization {
                let root = try DirectoryAnchor(scope.root, resolve: false)
                guard root.identity.sameObject(as: scope.identity), root.isOnLocalVolume else { throw TextComparisonReadFailure.changed }
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var budget = FileContentsReviewBudget(), files: [LocalProjectTextBatch.File] = []
                var consumed = 0, skipped = 0
                candidateLoop: for entry in candidates.prefix(LocalProjectTextBatch.maximumFiles) {
                    try cancellation.check()
                    if ContinuousClock.now >= deadline { break }
                    guard entry.kind == .file, let size = entry.byteCount,
                          !AutomaticMetadataPolicy.excludesProjectText(entry.url) else { consumed += 1; skipped += 1; continue }
                    switch budget.admit(size: size, copies: 1) {
                    case .accepted(let maximum):
                        consumed += 1
                        do {
                            let bytes = try LocalTextComparisonRead.fileBytes(at: entry.url, within: root,
                                maximumBytes: maximum, checkCancellation: cancellation.check)
                            guard bytes.count == maximum else { skipped += 1; continue }
                            files.append(.init(entry: entry, contents: try .original(bytes)))
                        } catch is CancellationError { throw CancellationError() }
                        catch { skipped += 1 }
                    case .fileTooLarge: consumed += 1; skipped += 1
                    case .exhaustedBytes, .exhaustedPairs: break candidateLoop
                    }
                }
                try cancellation.check()
                try root.validate()
                return .init(files: files, consumed: consumed, skipped: skipped)
            }
        }
    }

    /// The browser coalesces these stat-only probes to the latest visit. Git
    /// itself is launched only for a separately requested revision read.
    public func locateGitRepository(at directory: URL, within scope: URL? = nil,
                                    retaining lifetime: (any Sendable)? = nil) async throws -> GitRepositoryLocation? {
        try await enqueueRead(retaining: lifetime, didDrain: {}) { cancellation in
            try GitRepositoryLocation.find(at: directory, within: scope, check: cancellation.check)
        }
    }

    public func locateGitCheckout(at directory: URL, within scope: URL? = nil,
                                  retaining lifetime: (any Sendable)? = nil) async throws -> GitCheckoutObservation? {
        try await enqueueRead(retaining: lifetime, didDrain: {}) { cancellation in
            try withoutMaterialization {
                guard let location = try GitRepositoryLocation.find(at: directory, within: scope, check: cancellation.check) else { return nil }
                let anchors = try location.openAnchors(check: cancellation.check)
                let head = try? GitWorktree.readHead(anchors.metadata, check: cancellation.check)
                try anchors.validate(check: cancellation.check)
                return .init(location: location, head: head)
            }
        }
    }

    public func readGitWorktrees(in location: GitRepositoryLocation, allowedRoots: [URL]? = nil,
                                 retaining lifetime: (any Sendable)? = nil) async throws -> GitWorktreeListing {
        try await comparisonRead(retaining: lifetime) { cancellation in
            try GitWorktree.list(from: location, allowedRoots: allowedRoots, check: cancellation.check)
        }
    }

    public func verifyGitWorktree(_ worktree: GitWorktree, in location: GitRepositoryLocation, matching folder: GitSnapshotPath? = nil,
                                  allowedRoots: [URL]? = nil,
                                  retaining lifetime: (any Sendable)? = nil) async throws -> URL {
        try await comparisonRead(retaining: lifetime) { cancellation in
            try worktree.validate(from: location, matching: folder, allowedRoots: allowedRoots, check: cancellation.check)
        }
    }

    public func inspectGitWorktreeFile(_ path: GitSnapshotPath, in worktree: GitWorktree, from location: GitRepositoryLocation,
                                       allowedRoots: [URL]? = nil, readingText: Bool = false,
                                       retaining lifetime: (any Sendable)? = nil) async throws -> GitWorktreeFile {
        try await comparisonRead(retaining: lifetime) { cancellation in
            try worktree.file(at: path, from: location, allowedRoots: allowedRoots, readingText: readingText, check: cancellation.check)
        }
    }

    public func gitRevisionCatalog(in location: GitRepositoryLocation, pairedWith peer: GitRepositoryLocation? = nil, scratch: URL,
                                   retaining lifetime: (any Sendable)? = nil) async throws -> GitRevisionCatalog {
        if let peer, !location.canCompareCheckedOutRevisions(with: peer) { throw GitInspectionFailure.changed }
        return try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.catalog(pairedWith: peer, check: cancellation.check)
        }
    }

    public func compareGitRevisions(in location: GitRepositoryLocation, left: GitRevisionSelection,
                                    right: GitRevisionSelection, basis: GitTreeComparison.Basis = .selectedRevisions,
                                    wholeRepository: Bool = false, scratch: URL,
                                    retaining lifetime: (any Sendable)? = nil) async throws -> GitTreeComparison {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.compare(left: left, right: right, basis: basis, relativeFolder: wholeRepository ? "" : location.relativeFolder,
                             check: cancellation.check)
        }
    }

    public func compareGitIndex(in location: GitRepositoryLocation, against revision: GitRevisionSelection? = nil,
                                wholeRepository: Bool = false, scratch: URL,
                                retaining lifetime: (any Sendable)? = nil) async throws -> GitStagedComparison {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.stagedComparison(relativeFolder: wholeRepository ? "" : location.relativeFolder,
                against: revision, check: cancellation.check)
        }
    }

    public func openGitFileHistory(in location: GitRepositoryLocation, path: GitSnapshotPath,
                                   from revision: GitRevisionSelection = .head, scratch: URL,
                                   retaining lifetime: (any Sendable)? = nil) async throws -> (GitRevisionCatalog, GitFileHistory) {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            let catalog = try view.catalog(check: cancellation.check)
            let history = try view.history(of: path, from: revision, check: cancellation.check)
            return (catalog, history)
        }
    }

    public func gitFileHistory(in location: GitRepositoryLocation, path: GitSnapshotPath, from revision: GitRevisionSelection,
                               scratch: URL, retaining lifetime: (any Sendable)? = nil) async throws -> GitFileHistory {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.history(of: path, from: revision, check: cancellation.check)
        }
    }

    public func gitFileVersion(in location: GitRepositoryLocation, path: GitSnapshotPath, at revision: GitRevisionSelection,
                               scratch: URL, retaining lifetime: (any Sendable)? = nil) async throws -> GitFileVersion {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, _ in
            try view.fileVersion(of: path, at: revision)
        }
    }

    public func readGitFileVersion(in location: GitRepositoryLocation, path: GitSnapshotPath, at revision: GitRevisionSelection,
                                  scratch: URL, retaining lifetime: (any Sendable)? = nil) async throws -> (GitFileVersion, TextDocumentValue?) {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            let version = try view.fileVersion(of: path, at: revision)
            try cancellation.check()
            guard case .member(let member) = version.state, member.isTextCandidate else { return (version, nil) }
            return (version, try view.text(member))
        }
    }

    public func readGitText(in location: GitRepositoryLocation, member: GitSnapshotMember,
                            scratch: URL, retaining lifetime: (any Sendable)? = nil) async throws -> TextDocumentValue {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, _ in try view.text(member) }
    }

    public func gitLineOrigin(in location: GitRepositoryLocation, member: GitSnapshotMember, at commit: GitObjectID,
                              line: Int, scratch: URL, retaining lifetime: (any Sendable)? = nil) async throws -> GitLineOrigin {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, _ in
            try view.lineOrigin(of: member, at: commit, line: line)
        }
    }

    /// Keep the HEAD version and its origin within one isolated Git read. The
    /// caller may map an independently held buffer to the exact committed text.
    public func gitHEADLineOrigin(in location: GitRepositoryLocation, path: GitSnapshotPath, scratch: URL,
                                  retaining lifetime: (any Sendable)? = nil,
                                  matchingLine: @escaping @Sendable (TextDocumentValue, @Sendable () -> Bool) throws -> Int)
        async throws -> (version: GitFileVersion, line: Int, origin: GitLineOrigin)? {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.headLineOrigin(of: path) { text in
                let line = try matchingLine(text, { (try? cancellation.check()) == nil })
                try cancellation.check()
                return line
            }
        }
    }

    public func gitFileStatuses(in location: GitRepositoryLocation, urls: [URL], inspectWorkingBytes: Bool = false, scratch: URL,
                                retaining lifetime: (any Sendable)? = nil) async throws -> [GitFileStatus] {
        let paths = urls.compactMap { location.filePath(for: $0) }
        guard paths.count == urls.count else { throw GitInspectionFailure.unsupportedRepository }
        return try await inspectGit(location, scratch: scratch, retaining: lifetime,
                                    metadataOnly: !inspectWorkingBytes) { view, cancellation in
            try view.fileStatus(paths: paths, inspectWorkingBytes: inspectWorkingBytes, check: cancellation.check)
        }
    }

    public func readGitIndexText(in location: GitRepositoryLocation, url: URL, scratch: URL,
                                 retaining lifetime: (any Sendable)? = nil) async throws -> TextDocumentValue {
        guard let path = location.filePath(for: url) else { throw GitInspectionFailure.unsupportedRepository }
        return try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.indexText(path, check: cancellation.check)
        }
    }

    public func prepareGitIndexEdit(_ action: GitIndexEditAction, path: GitSnapshotPath,
                                    in location: GitRepositoryLocation, scratch: URL,
                                    matchingSavedText: LocalTextReadToken? = nil,
                                    retaining lifetime: (any Sendable)? = nil) async throws -> GitIndexEditPlan {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.prepareIndexEdit(action, path: path, location: location, matchingSavedText: matchingSavedText,
                check: cancellation.check)
        }
    }

    public func applyGitIndexEdit(_ plan: GitIndexEditPlan, scratch: URL,
                                  retaining lifetime: (any Sendable)? = nil) async throws {
        try await comparisonRead(retaining: lifetime, checkAfterWork: false) { cancellation in
            try withoutMaterialization {
                let view = try GitReadView(location: plan.location, scratch: scratch, check: cancellation.check)
                try view.applyIndexEdit(plan, check: cancellation.check)
            }
        }
    }

    public func readGitWorkingText(in location: GitRepositoryLocation, url: URL,
                                   retaining lifetime: (any Sendable)? = nil) async throws -> TextDocumentValue {
        guard location.filePath(for: url) != nil else { throw GitInspectionFailure.unsupportedRepository }
        return try await comparisonRead(retaining: lifetime) { cancellation in
            try withoutMaterialization {
                let anchors = try location.openAnchors(check: cancellation.check)
                let bytes = try LocalTextComparisonRead.fileBytes(at: url, within: anchors.root,
                    maximumBytes: TextDocumentValue.maximumBytes, checkCancellation: cancellation.check)
                try anchors.validate(check: cancellation.check)
                return try TextDocumentValue.original(bytes)
            }
        }
    }

    public func gitFileVersions(in location: GitRepositoryLocation, path: GitSnapshotPath, left: GitRevisionSelection,
                                right: GitRevisionSelection, scratch: URL,
                                retaining lifetime: (any Sendable)? = nil) async throws -> (GitFileVersion, GitFileVersion) {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            let first = try view.fileVersion(of: path, at: left)
            try cancellation.check()
            return (first, try view.fileVersion(of: path, at: right))
        }
    }

    public func readGitCommitRange(in location: GitRepositoryLocation, left: GitObjectID, right: GitObjectID, scratch: URL,
                                   retaining lifetime: (any Sendable)? = nil) async throws -> GitCommitRange {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.commitRange(left: left, right: right, check: cancellation.check)
        }
    }

    public func readGitFolderHistory(in location: GitRepositoryLocation, from revision: GitRevisionSelection,
                                     wholeRepository: Bool, scratch: URL,
                                     retaining lifetime: (any Sendable)? = nil) async throws -> GitFolderHistory {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.folderHistory(from: revision, relativeFolder: wholeRepository ? "" : location.relativeFolder,
                                   check: cancellation.check)
        }
    }

    public func readGitCommitChanges(in location: GitRepositoryLocation, commit: GitRangeCommit, parent: GitObjectID?,
                                     wholeRepository: Bool, scratch: URL,
                                     retaining lifetime: (any Sendable)? = nil) async throws -> GitCommitChanges {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.commitChanges(commit, against: parent, relativeFolder: wholeRepository ? "" : location.relativeFolder,
                check: cancellation.check)
        }
    }

    public func readGitFolders(in location: GitRepositoryLocation, left: GitObjectID, right: GitObjectID,
                               at path: GitSnapshotPath?, scratch: URL,
                               retaining lifetime: (any Sendable)? = nil) async throws -> GitRevisionFolders {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.folders(left: left, right: right, at: path, check: cancellation.check)
        }
    }

    public func readGitWorkingFolder(in location: GitRepositoryLocation, at path: GitSnapshotPath?,
                                     revision: GitRevisionSelection, showHidden: Bool, scratch: URL,
                                     retaining lifetime: (any Sendable)? = nil) async throws -> GitWorkingFolder {
        try await readGitWorkingFolder(in: location, at: path, baseline: .revision(revision), showHidden: showHidden,
            scratch: scratch, retaining: lifetime)
    }

    public func readGitWorkingFolder(in location: GitRepositoryLocation, at path: GitSnapshotPath?,
                                     baseline: GitWorkingFolder.Baseline, showHidden: Bool, scratch: URL,
                                     retaining lifetime: (any Sendable)? = nil) async throws -> GitWorkingFolder {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.workingFolder(location: location, at: path, baseline: baseline, showHidden: showHidden, check: cancellation.check)
        }
    }

    public func readGitWorkingFolderText(_ selection: GitWorkingFolder.TextSelection, scratch: URL,
                                         retaining lifetime: (any Sendable)? = nil) async throws -> TextComparisonDocuments {
        try await inspectGit(selection.location, scratch: scratch, retaining: lifetime) { view, cancellation in
            try view.workingComparison(selection, check: cancellation.check)
        }
    }

    public func readGitWorkingFolderReference(_ selection: GitWorkingFolder.TextSelection, scratch: URL,
                                              retaining lifetime: (any Sendable)? = nil) async throws -> TextDocumentValue {
        try await inspectGit(selection.location, scratch: scratch, retaining: lifetime) { view, _ in
            try view.workingReference(selection)
        }
    }

    public func checkGitWorkingFolderContents(_ folder: GitWorkingFolder,
                                              retaining lifetime: (any Sendable)? = nil) async throws -> GitWorkingFolder.ContentReview {
        try await comparisonRead(retaining: lifetime) { cancellation in
            try withoutMaterialization { try folder.checkContents(check: cancellation.check) }
        }
    }

    public func readGitTextComparison(in location: GitRepositoryLocation, left: GitSnapshotMember?,
                                      right: GitSnapshotMember?, scratch: URL,
                                      retaining lifetime: (any Sendable)? = nil) async throws -> TextComparisonDocuments {
        try await inspectGit(location, scratch: scratch, retaining: lifetime) { view, cancellation in
            let first = try view.text(left)
            try cancellation.check()
            return .init(left: first, right: try view.text(right))
        }
    }

    private func inspectGit<Value: Sendable>(_ location: GitRepositoryLocation, scratch: URL,
        retaining lifetime: (any Sendable)?, metadataOnly: Bool = false,
        _ read: @escaping @Sendable (GitReadView, ReadCancellation) throws -> Value) async throws -> Value {
        let inspect: @Sendable (ReadCancellation) throws -> Value = { cancellation in
            try withoutMaterialization {
                let view = try GitReadView(location: location, scratch: scratch, check: cancellation.check)
                return try read(view, cancellation)
            }
        }
        // Browser badges read the index and folder metadata. They use the
        // bounded location queue while an explicit comparison owns its slot.
        if metadataOnly { return try await locationRead(retaining: lifetime, inspect) }
        return try await comparisonRead(retaining: lifetime, inspect)
    }

    private func comparisonRead<Value: Sendable>(retaining lifetime: (any Sendable)?, checkAfterWork: Bool = true,
        _ read: @escaping @Sendable (ReadCancellation) throws -> Value) async throws -> Value {
        try readAdmissionLock.withLock {
            guard !comparisonPending else { throw LocalStorageError.busy }
            comparisonPending = true
        }
        return try await enqueueRead(retaining: lifetime, checkAfterWork: checkAfterWork, didDrain: { [self] in
            readAdmissionLock.withLock { comparisonPending = false }
        }, read)
    }

    private func locationRead<Value: Sendable>(retaining lifetime: (any Sendable)?,
        _ read: @escaping @Sendable (ReadCancellation) throws -> Value) async throws -> Value {
        try reserveLocationRead()
        return try await enqueueRead(retaining: lifetime, didDrain: { [self] in releaseLocationRead() }, read)
    }

    private func enqueueNearestRead(to url: URL, retaining lifetime: (any Sendable)?,
                                    afterProbe: (@Sendable (URL) -> Void)?,
                                    didEnqueue: (@Sendable () -> Void)?) async throws -> URL? {
        try await enqueueRead(retaining: lifetime, didEnqueue: didEnqueue, didDrain: { [self] in
            releaseLocationRead()
        }) { cancellation in
            guard url.isFileURL else { throw LocalStorageError.unavailable }
            var candidate = url
            for _ in 0..<64 {
                try cancellation.check()
                var observation = stat()
                let (status, failure) = candidate.withUnsafeFileSystemRepresentation { pointer -> (Int32, Int32) in
                    guard let pointer else { return (-1, EINVAL) }
                    let status = lstat(pointer, &observation)
                    return (status, errno)
                }
                afterProbe?(candidate)
                try cancellation.check()
                if status == 0 {
                    // Deleting a component adds a directory hint, even if
                    // the resulting ancestor is a regular file.
                    let isDirectory = observation.st_mode & S_IFMT == S_IFDIR
                    return candidate.hasDirectoryPath == isDirectory ? candidate
                        : URL(fileURLWithPath: candidate.path, isDirectory: isDirectory)
                }
                guard failure == ENOENT || failure == ENOTDIR else { throw Self.storageError(errno: failure) }
                let parent = candidate.deletingLastPathComponent()
                if parent == candidate { return nil }
                candidate = parent
            }
            return nil
        }
    }

    private func enqueueRead<Value: Sendable>(retaining lifetime: (any Sendable)?,
        checkAfterWork: Bool = true, didEnqueue: (@Sendable () -> Void)? = nil, didDrain: @escaping @Sendable () -> Void,
        _ read: @escaping @Sendable (ReadCancellation) throws -> Value
    ) async throws -> Value {
        let cancellation = ReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation { [activityGate] in
                    let result = Result {
                        defer { withExtendedLifetime(lifetime) {} }
                        try cancellation.check()
                        let activity = try activityGate?.begin()
                        defer { withExtendedLifetime(activity) {} }
                        let value = try read(cancellation)
                        if checkAfterWork { try cancellation.check() }
                        return value
                    }
                    didDrain()
                    continuation.resume(with: result)
                }
                didEnqueue?()
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func enumerate(
        _ url: URL, showHidden: Bool, batchSize: Int, cancellation: ReadCancellation,
        anchor: DirectoryAnchor? = nil, maximum: Int? = nil,
        yield: (ListingEvent) -> Bool
    ) throws -> Bool {
        try cancellation.check()
        guard url.isFileURL else { throw LocalStorageError.unavailable }
        let directory: UnsafeMutablePointer<DIR>?
        if let anchor {
            let fd = openat(anchor.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw storageError(errno: errno) }
            directory = fdopendir(fd)
            if directory == nil { close(fd) }
        } else {
            directory = url.withUnsafeFileSystemRepresentation { pointer in
                pointer.flatMap { opendir($0) }
            }
        }
        guard let directory else { throw storageError(errno: errno) }
        defer { closedir(directory) }
        var batch: [FileEntry] = []
        var issues: [ListingIssue] = []
        var omittedIssues = 0
        var complete = true
        var visited = 0
        var accepted = 0
        func recordIssue(_ entryURL: URL) {
            // Avoid unbounded diagnostics and never include the user's path in message text.
            if issues.count < 100 {
                issues.append(ListingIssue(message: "Some metadata could not be read for this item.", url: entryURL))
            } else { omittedIssues += 1 }
        }
        while true {
            try cancellation.check()
            errno = 0
            guard let item = readdir(directory) else {
                let failure = errno
                if failure != 0 { throw storageError(errno: failure) }
                break
            }
            if let maximum {
                visited += 1
                if visited > maximum * 8 + 2 { complete = false; break }
            }
            let name: String = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || (!showHidden && name.hasPrefix(".")) { continue }
            let entryURL = url.appendingPathComponent(name)
            var observation = stat()
            let status = fstatat(dirfd(directory), name, &observation, AT_SYMLINK_NOFOLLOW)
            var kind: FileKind = .other
            var byteCount: Int64?
            var modifiedAt: Date?
            var createdAt: Date?
            var accessedAt: Date?
            if status == 0 {
                if !showHidden && observation.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                if let anchor, observation.st_dev != anchor.device ||
                    observation.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) != 0 || AutomaticMetadataPolicy.excludes(entryURL) {
                    recordIssue(entryURL)
                    continue
                }
                let mode = observation.st_mode & S_IFMT
                if mode == S_IFLNK {
                    // lstat observes the link itself; never ask Foundation for target metadata.
                    kind = .symbolicLink
                } else if mode == S_IFDIR { kind = .directory }
                else if mode == S_IFREG { kind = .file }
                if kind == .file || kind == .symbolicLink { byteCount = Int64(observation.st_size) }
                modifiedAt = Date(timeIntervalSince1970: Double(observation.st_mtimespec.tv_sec)
                    + Double(observation.st_mtimespec.tv_nsec) / 1_000_000_000)
                createdAt = observedCreationDate(observation.st_birthtimespec)
                accessedAt = Date(timeIntervalSince1970: Double(observation.st_atimespec.tv_sec)
                    + Double(observation.st_atimespec.tv_nsec) / 1_000_000_000)
                if kind != .symbolicLink {
                    do {
                        // Package and Finder-hidden flags need public URL resource metadata.
                        let values = try entryURL.resourceValues(forKeys: [.isPackageKey, .isHiddenKey])
                        if !showHidden && values.isHidden == true { continue }
                        if kind == .directory && values.isPackage == true { kind = .package }
                    } catch { recordIssue(entryURL) }
                }
            } else { recordIssue(entryURL) }
            try cancellation.check()
            if let maximum {
                if accepted == maximum { complete = false; break }
                accepted += 1
            }
            batch.append(FileEntry(url: entryURL, name: name, kind: kind,
                                   byteCount: byteCount, modifiedAt: modifiedAt,
                                   createdAt: createdAt, accessedAt: accessedAt))
            if batch.count >= batchSize {
                if !yield(.batch(batch)) { return false }
                batch.removeAll(keepingCapacity: true)
            }
        }
        try cancellation.check()
        if !batch.isEmpty, !yield(.batch(batch)) { return false }
        if omittedIssues > 0 {
            issues.append(ListingIssue(message: "Metadata was unavailable for additional items."))
        }
        _ = yield(.finished(issues: issues))
        return complete
    }

    private static func storageError(errno code: Int32) -> LocalStorageError {
        switch code {
        case EACCES, EPERM: .accessDenied
        case ENOENT: .notFound
        case ENOTDIR: .notDirectory
        case ENODEV, ENXIO, ESTALE, ENOTCONN, ETIMEDOUT, EIO: .unavailable
        default: .other("Filesystem metadata read failed.")
        }
    }

    private static func storageError(_ error: Error) -> LocalStorageError {
        let cocoa = error as NSError
        if cocoa.domain == NSPOSIXErrorDomain { return storageError(errno: Int32(cocoa.code)) }
        switch cocoa.code {
        case NSFileReadNoPermissionError: return .accessDenied
        case NSFileReadNoSuchFileError: return .notFound
        default: return .unavailable
        }
    }
}

/// Some filesystems report an all-zero birth time when creation metadata is unavailable.
/// Negative seconds and positive subsecond values at the Unix epoch remain valid dates.
internal func observedCreationDate(_ time: timespec) -> Date? {
    guard time.tv_nsec >= 0, time.tv_nsec < 1_000_000_000,
          time.tv_sec != 0 || time.tv_nsec != 0 else { return nil }
    return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
}

private final class ReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}
