import ExplorerCore
import Foundation

/// The complete permitted search grammar. No predicate strings, arbitrary metadata
/// keys, snippets, document attributes, or filesystem handles cross this boundary.
public struct SearchRequest: Sendable, Equatable {
    public enum FilenameMatch: String, Sendable { case contains, exact }
    public enum DateField: String, Sendable { case modified, created, accessed }
    public let filename: String
    public let filenameMatch: FilenameMatch
    public let kind: FileKind?
    public let filenameExtension: String?
    public let byteRange: ClosedRange<Int64>?
    public let dateField: DateField
    public let dateRange: ClosedRange<Date>?
    public let symbolTolerant: Bool
    private let normalizedFilename: String

    public init(filename: String, filenameMatch: FilenameMatch = .contains, kind: FileKind? = nil,
                filenameExtension: String? = nil, byteRange: ClosedRange<Int64>? = nil,
                dateField: DateField = .modified, dateRange: ClosedRange<Date>? = nil,
                symbolTolerant: Bool = true) throws {
        guard filename.utf8.count <= 2_048, !filename.utf8.contains(0),
              !filename.contains("/"), !filename.contains("\n"),
              byteRange.map({ $0.lowerBound >= 0 }) ?? true else { throw SearchValidationError.invalidRequest }
        if let suffix = filenameExtension {
            guard !suffix.isEmpty, suffix.utf8.count <= 128,
                  !suffix.contains("/"), !suffix.contains("."), !suffix.utf8.contains(0) else {
                throw SearchValidationError.invalidRequest
            }
        }
        self.filename = filename
        self.filenameMatch = filenameMatch
        self.kind = kind
        self.filenameExtension = filenameExtension
        self.byteRange = byteRange
        self.dateField = dateField
        self.dateRange = dateRange
        self.symbolTolerant = symbolTolerant
        normalizedFilename = FilenameMatching.folded(filename, symbolTolerant: symbolTolerant)
    }

    /// Unicode-aware filename matching with optional separator equivalence for
    /// contains queries; '*', quotes and predicate syntax
    /// remain ordinary characters. Unknown facts cannot satisfy a metadata filter.
    public func matches(_ entry: FileEntry) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let locale = Locale(identifier: "en_US_POSIX")
        if !filename.isEmpty {
            switch filenameMatch {
            case .contains:
                guard FilenameMatching.folded(entry.name, symbolTolerant: symbolTolerant).contains(normalizedFilename) else { return false }
            case .exact:
                guard entry.name.compare(filename, options: options, locale: locale) == .orderedSame else { return false }
            }
        }
        if let kind, kind != entry.kind { return false }
        if let filenameExtension {
            guard let observed = entry.filenameExtension,
                  observed.compare(filenameExtension, options: [.caseInsensitive], locale: locale) == .orderedSame else {
                return false
            }
        }
        if let byteRange {
            guard let bytes = entry.byteCount, byteRange.contains(bytes) else { return false }
        }
        if let dateRange {
            let date: Date?
            switch dateField {
            case .modified: date = entry.modifiedAt
            case .created: date = entry.createdAt
            case .accessed: date = entry.accessedAt
            }
            guard let date, dateRange.contains(date) else { return false }
        }
        return true
    }
}

public enum SearchValidationError: Error, Sendable {
    case invalidRequest, invalidScope, invalidExclusion
}

/// An explicit folder only; no implicit whole-machine/home default. Exclusions are
/// lexical descendant boundaries and are checked before opening an excluded item.
public struct SearchScope: Sendable, Equatable {
    public let root: URL
    public let showHidden: Bool
    public let excludedSubroots: [URL]

    public init(root: URL, showHidden: Bool = false, excludedSubroots: [URL] = []) throws {
        guard Self.localURL(root), root.standardizedFileURL.path != "/",
              root.standardizedFileURL.path != "/Volumes", excludedSubroots.count <= 128 else {
            throw SearchValidationError.invalidScope
        }
        let normalized = root.standardizedFileURL
        for exclusion in excludedSubroots {
            guard Self.localURL(exclusion), Self.contains(exclusion.standardizedFileURL, inside: normalized),
                  exclusion.standardizedFileURL.path != normalized.path else { throw SearchValidationError.invalidExclusion }
        }
        self.root = normalized
        self.showHidden = showHidden
        self.excludedSubroots = excludedSubroots.map(\.standardizedFileURL)
    }

    public func permits(_ url: URL) -> Bool {
        guard Self.localURL(url), Self.contains(url.standardizedFileURL, inside: root) else { return false }
        let candidate = url.standardizedFileURL.path.lowercased(with: Locale(identifier: "en_US_POSIX"))
        return !excludedSubroots.contains {
            // A conservative exclusion must not be bypassed by spelling case
            // differently on the default case-insensitive macOS filesystem.
            let excluded = $0.path.lowercased(with: Locale(identifier: "en_US_POSIX"))
            return candidate == excluded || candidate.hasPrefix(excluded + "/")
        }
    }

    private static func contains(_ candidate: URL, inside root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private static func localURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
            && !url.path.utf8.contains(0) && url.absoluteString.utf8.count <= 8_192
    }
}

/// Finite on-demand work; this policy has no option to enable body access,
/// symlink/package/volume traversal, persistence, or cloud materialization.
public struct SearchPolicy: Sendable, Equatable {
    public let revision: UInt64
    public let maximumResults: Int
    public let maximumVisitedEntries: Int
    public let maximumDepth: Int
    public let batchSize: Int
    public let maximumIssues: Int
    public let maximumDuration: TimeInterval

    public init(revision: UInt64 = 1, maximumResults: Int = 2_000, maximumVisitedEntries: Int = 100_000,
                maximumDepth: Int = 64, batchSize: Int = 128, maximumIssues: Int = 100,
                maximumDuration: TimeInterval = 20) {
        self.revision = revision
        self.maximumResults = min(max(1, maximumResults), 10_000)
        self.maximumVisitedEntries = min(max(1, maximumVisitedEntries), 1_000_000)
        self.maximumDepth = min(max(0, maximumDepth), 128)
        self.batchSize = min(max(1, batchSize), 256)
        self.maximumIssues = min(max(1, maximumIssues), 100)
        self.maximumDuration = maximumDuration.isFinite ? min(max(0.1, maximumDuration), 60) : 20
    }
}

public enum SearchSource: String, Sendable { case recursiveMetadata, spotlightIndex }
public struct SearchMatch: Identifiable, Sendable, Equatable {
    public var id: URL { entry.url }
    public let entry: FileEntry
    public let source: SearchSource
    init(entry: FileEntry, source: SearchSource = .recursiveMetadata) { self.entry = entry; self.source = source }
}

public enum SearchBoundary: String, Sendable {
    case excluded, hidden, symbolicLink, package, nestedVolume, cloudItem, credentialLocation
    case denied, unavailable, metadataUnavailable, depthLimit, changedDuringSearch
}
public struct SearchIssue: Sendable, Equatable {
    public let url: URL
    public let reason: SearchBoundary
    init(url: URL, reason: SearchBoundary) { self.url = url; self.reason = reason }
}
public enum SearchCompletion: String, Sendable { case completed, cancelled, resultLimit, traversalLimit, timedOut, failed }
public struct SearchCoverage: Sendable, Equatable {
    public internal(set) var requestedRoots: [URL]
    public var root: URL? { requestedRoots.first }
    public let source: SearchSource
    public internal(set) var visitedEntries = 0
    public internal(set) var searchedDirectories = 0
    public internal(set) var matchedEntries = 0
    public internal(set) var boundaryCounts: [SearchBoundary: Int] = [:]
    public internal(set) var issues: [SearchIssue] = []
    public internal(set) var omittedIssues = 0
    public internal(set) var completion: SearchCompletion = .completed
    public internal(set) var finishedAt: Date?

    /// An index query cannot establish filesystem coverage, even when gathering ends.
    public var indexedCoverageUnverified: Bool { source == .spotlightIndex }
    public var isComplete: Bool { finishedAt != nil && source == .recursiveMetadata && completion == .completed && boundaryCounts.isEmpty }
    init(roots: [URL], source: SearchSource = .recursiveMetadata) { requestedRoots = roots; self.source = source }
}

public struct SearchEvent: Sendable {
    public enum Payload: Sendable { case batch([SearchMatch]), progress(SearchCoverage), finished(SearchCoverage) }
    public let sessionID: UUID
    public let policyRevision: UInt64
    public let payload: Payload
}

/// A view captures one generation; it must invalidate it on cancellation, scope,
/// query or policy changes before accepting asynchronous results.
public struct SearchGeneration: Sendable, Equatable {
    public let sessionID: UUID
    public let policyRevision: UInt64
    public init(sessionID: UUID, policyRevision: UInt64) {
        self.sessionID = sessionID; self.policyRevision = policyRevision
    }
    public func accepts(_ event: SearchEvent) -> Bool {
        event.sessionID == sessionID && event.policyRevision == policyRevision
    }
}
