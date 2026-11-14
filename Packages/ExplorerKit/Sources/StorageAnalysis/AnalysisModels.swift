import Foundation

/// A field observation. Missing and failed metadata never become a returned zero.
public enum AnalysisMetadata<Value: Equatable & Sendable>: Equatable, Sendable {
    case returned(Value)
    case notReturned
    case failed(code: Int32)

    public var value: Value? {
        if case .returned(let value) = self { return value }
        return nil
    }
}

public struct AnalysisObjectIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public enum AnalysisEntryKind: Equatable, Sendable {
    case regularFile, directory, symbolicLink, other, unknown
}

public enum AnalysisByteMetric: Int, CaseIterable, Hashable, Sendable {
    case dataLogical, allForkLogical, dataAllocated, allForkAllocated
}

/// Source fields remain distinct; allocation is not exclusive physical usage.
public struct AnalysisByteObservation: Equatable, Sendable {
    public var dataLogical: AnalysisMetadata<UInt64>
    public var allForkLogical: AnalysisMetadata<UInt64>
    public var dataAllocated: AnalysisMetadata<UInt64>
    public var allForkAllocated: AnalysisMetadata<UInt64>

    public init(dataLogical: AnalysisMetadata<UInt64> = .notReturned,
                allForkLogical: AnalysisMetadata<UInt64> = .notReturned,
                dataAllocated: AnalysisMetadata<UInt64> = .notReturned,
                allForkAllocated: AnalysisMetadata<UInt64> = .notReturned) {
        self.dataLogical = dataLogical
        self.allForkLogical = allForkLogical
        self.dataAllocated = dataAllocated
        self.allForkAllocated = allForkAllocated
    }

    public subscript(metric: AnalysisByteMetric) -> AnalysisMetadata<UInt64> {
        switch metric {
        case .dataLogical: return dataLogical
        case .allForkLogical: return allForkLogical
        case .dataAllocated: return dataAllocated
        case .allForkAllocated: return allForkAllocated
        }
    }
}

/// A caller-supplied metadata record. The accumulator validates raw path bytes
/// internally. This value grants no filesystem access and contains no file body.
public struct AnalysisEntryObservation: Sendable {
    public let relativePath: Data
    public let kind: AnalysisEntryKind
    public let identity: AnalysisMetadata<AnalysisObjectIdentity>
    public let linkCount: AnalysisMetadata<UInt64>
    public let flags: AnalysisMetadata<UInt32>
    public let bytes: AnalysisByteObservation

    public init(relativePath: Data, kind: AnalysisEntryKind,
                identity: AnalysisMetadata<AnalysisObjectIdentity> = .notReturned,
                linkCount: AnalysisMetadata<UInt64> = .notReturned,
                flags: AnalysisMetadata<UInt32> = .notReturned,
                bytes: AnalysisByteObservation = AnalysisByteObservation()) {
        self.relativePath = relativePath
        self.kind = kind
        self.identity = identity
        self.linkCount = linkCount
        self.flags = flags
        self.bytes = bytes
    }
}

public struct AnalysisLimits: Equatable, Sendable {
    public let maximumRecords: Int
    public let maximumRetainedRawPathBytes: Int
    public let maximumPathBytes: Int
    public let maximumDepth: Int
    public let maximumDetailedIssues: Int

    public static let standard = AnalysisLimits(uncheckedRecords: 220_000, rawPathBytes: 64 << 20,
                                               pathBytes: 8192, depth: 64, issues: 100)

    public init(maximumRecords: Int = 220_000, maximumRetainedRawPathBytes: Int = 64 << 20,
                maximumPathBytes: Int = 8192, maximumDepth: Int = 64,
                maximumDetailedIssues: Int = 100) throws {
        guard (1...220_000).contains(maximumRecords), (1...(64 << 20)).contains(maximumRetainedRawPathBytes),
              (1...8192).contains(maximumPathBytes), (1...64).contains(maximumDepth),
              (0...100).contains(maximumDetailedIssues) else { throw AnalysisConfigurationError.invalidLimits }
        self.init(uncheckedRecords: maximumRecords, rawPathBytes: maximumRetainedRawPathBytes,
                  pathBytes: maximumPathBytes, depth: maximumDepth, issues: maximumDetailedIssues)
    }

    private init(uncheckedRecords: Int, rawPathBytes: Int, pathBytes: Int, depth: Int, issues: Int) {
        maximumRecords = uncheckedRecords
        maximumRetainedRawPathBytes = rawPathBytes
        maximumPathBytes = pathBytes
        maximumDepth = depth
        maximumDetailedIssues = issues
    }
}

public enum AnalysisConfigurationError: Error { case invalidLimits }
public enum AnalysisPathProblem: Error, Hashable, Sendable {
    case rootEntry, absolute, emptyComponent, traversalComponent, nul, tooLong, tooDeep
}
public enum AnalysisResourceLimit: Hashable, Sendable { case records, retainedRawPathBytes }
public enum AnalysisCoverageGap: Hashable, Sendable {
    case enumerationFailed(code: Int32), unavailable, disconnected, boundaryExcluded, changing, truncated
}
public enum AnalysisAccountingKind: Hashable, Sendable { case namespaceEntries, distinctObjects }

/// Fixed codes and numeric identifiers only. No paths, body strings or logger.
public enum AnalysisIssueCode: Hashable, Sendable {
    case invalidPath(AnalysisPathProblem), parentMissing, parentNotDirectory
    case duplicatePath, entryIdentityChanged, entryIdentityUncertain, entryKindChanged
    case directoryIdentityRepeated, objectMetadataChanged, unknownKind
    case missingIdentity, failedIdentity(code: Int32), missingLinkCount, failedLinkCount(code: Int32)
    case missingFlags, failedFlags(code: Int32)
    case missingMetric(AnalysisByteMetric), failedMetric(AnalysisByteMetric, code: Int32)
    case overflow(AnalysisAccountingKind, AnalysisByteMetric)
    case coverage(AnalysisCoverageGap), resourceLimit(AnalysisResourceLimit), invalidFolderReference
}

public struct AnalysisFolderID: Hashable, Sendable {
    public let rawValue: Int
    public static let root = AnalysisFolderID(rawValue: 0)
    init(rawValue: Int) { self.rawValue = rawValue }
}

public struct AnalysisIssue: Equatable, Sendable {
    public let code: AnalysisIssueCode
    public let folder: AnalysisFolderID
    public let recordOrdinal: UInt64?
}

/// This is input-model lifecycle only. Closing input does not mean an external
/// scanner, native call, access lease or worker has drained.
public enum AnalysisInputCompletion: Equatable, Sendable {
    case completed, cancelled, failed(AnalysisCoverageGap), resourceLimited(AnalysisResourceLimit)
}
public enum AnalysisInputState: Equatable, Sendable {
    case accepting
    case closed(AnalysisInputCompletion)
}
public enum AnalysisAdmission: Equatable, Sendable {
    case accepted, rejected(AnalysisIssueCode), resourceLimited(AnalysisResourceLimit), closed
}

/// For observed records only. A nonzero missing/failed count makes knownBytes a
/// subtotal. Overflow is unavailable, rather than a wrapped or saturated byte sum.
public struct AnalysisMetricSubtotal: Equatable, Sendable {
    public internal(set) var knownBytes: UInt64? = 0
    public internal(set) var notReturnedCount: UInt64 = 0
    public internal(set) var failedCount: UInt64 = 0
    public internal(set) var overflowed = false

    public init() {}

    mutating func add(_ value: AnalysisMetadata<UInt64>) -> Bool {
        switch value {
        case .returned(let bytes):
            guard !overflowed else { return false }
            let (sum, overflow) = knownBytes!.addingReportingOverflow(bytes)
            knownBytes = overflow ? nil : sum
            overflowed = overflow
            return overflow
        case .notReturned: notReturnedCount += 1
        case .failed: failedCount += 1
        }
        return false
    }

    mutating func merge(_ other: Self) {
        notReturnedCount += other.notReturnedCount
        failedCount += other.failedCount
        guard !overflowed && !other.overflowed else { overflowed = true; knownBytes = nil; return }
        let (sum, overflow) = knownBytes!.addingReportingOverflow(other.knownBytes!)
        knownBytes = overflow ? nil : sum
        overflowed = overflow
    }
}

public struct AnalysisByteSubtotals: Equatable, Sendable {
    public internal(set) var dataLogical = AnalysisMetricSubtotal()
    public internal(set) var allForkLogical = AnalysisMetricSubtotal()
    public internal(set) var dataAllocated = AnalysisMetricSubtotal()
    public internal(set) var allForkAllocated = AnalysisMetricSubtotal()
    public init() {}

    public internal(set) subscript(metric: AnalysisByteMetric) -> AnalysisMetricSubtotal {
        get {
            switch metric {
            case .dataLogical: return dataLogical
            case .allForkLogical: return allForkLogical
            case .dataAllocated: return dataAllocated
            case .allForkAllocated: return allForkAllocated
            }
        }
        set {
            switch metric {
            case .dataLogical: dataLogical = newValue
            case .allForkLogical: allForkLogical = newValue
            case .dataAllocated: dataAllocated = newValue
            case .allForkAllocated: allForkAllocated = newValue
            }
        }
    }

    var hasUnavailableValues: Bool {
        AnalysisByteMetric.allCases.contains { self[$0].overflowed || self[$0].notReturnedCount > 0 || self[$0].failedCount > 0 }
    }

    mutating func merge(_ other: Self) {
        for metric in AnalysisByteMetric.allCases { self[metric].merge(other[metric]) }
    }
}

public struct AnalysisEntryCounts: Equatable, Sendable {
    public internal(set) var regularFiles: UInt64 = 0
    public internal(set) var directories: UInt64 = 0
    public internal(set) var symbolicLinks: UInt64 = 0
    public internal(set) var other: UInt64 = 0
    public internal(set) var unknown: UInt64 = 0
    public var total: UInt64 { regularFiles + directories + symbolicLinks + other + unknown }
    public init() {}

    mutating func add(_ kind: AnalysisEntryKind) {
        switch kind {
        case .regularFile: regularFiles += 1
        case .directory: directories += 1
        case .symbolicLink: symbolicLinks += 1
        case .other: other += 1
        case .unknown: unknown += 1
        }
    }
    mutating func merge(_ other: Self) {
        regularFiles += other.regularFiles; directories += other.directories
        symbolicLinks += other.symbolicLinks; self.other += other.other; unknown += other.unknown
    }
}

/// Descendant namespace edges, excluding the folder's own edge. Hardlink bytes
/// can overlap another folder; clone allocation is not exclusive or reclaimable.
public struct AnalysisFolderSummary: Sendable {
    public let id: AnalysisFolderID
    public let parent: AnalysisFolderID?
    public let relativePath: Data
    public let identity: AnalysisMetadata<AnalysisObjectIdentity>
    public let ownMetadataBytes: AnalysisByteObservation
    public let counts: AnalysisEntryCounts
    public let namespaceSubtotals: AnalysisByteSubtotals
    public let issueCount: UInt64
    public let isComplete: Bool
}

public struct AnalysisDistinctObjects: Sendable {
    public let knownObjectCount: UInt64
    public let identityMissingEntries: UInt64
    public let byteSubtotals: AnalysisByteSubtotals
    public let observedCrossFolderHardlinkObjects: UInt64
    public let potentialOutsideLinkObjects: UInt64
    public let objectsWithUnknownLinkCount: UInt64
}

public struct StorageAnalysisSnapshot: Sendable {
    public let inputState: AnalysisInputState
    public let processedRecords: UInt64
    public let rejectedRecords: UInt64
    public let retainedRawPathBytes: Int
    public let folders: [AnalysisFolderSummary]
    public let distinctObjects: AnalysisDistinctObjects
    public let issueCount: UInt64
    public let issues: [AnalysisIssue]
    public let isComplete: Bool
    /// Sparse observed marker filenames. No manifests or file bodies are read.
    public internal(set) var projectMarkers: [AnalysisFolderID: AnalysisProjectMarker] = [:]
    /// Constant-size regular-file type partition. It retains no file names.
    public internal(set) var fileTypes: [AnalysisFileTypeSummary] = []
    public var root: AnalysisFolderSummary { folders[0] }
}

/// Constant-work observation progress. Folder rollups are produced on demand by
/// snapshot(); raw-path payload accounting is not a process RSS guarantee.
public struct StorageAnalysisProgress: Sendable {
    public let inputState: AnalysisInputState
    public let processedRecords: UInt64
    public let rejectedRecords: UInt64
    public let acceptedCounts: AnalysisEntryCounts
    public let namespaceSubtotals: AnalysisByteSubtotals
    public let knownObjectCount: UInt64
    public let folderCount: Int
    public let retainedRawPathBytes: Int
    public let issueCount: UInt64
}
