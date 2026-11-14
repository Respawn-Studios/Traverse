import Foundation

/// Bounded summaries from a versioned temporary result. Namespace sizes count
/// names; allocation is neither exclusive physical space nor reclaimable space.
public struct StoredAnalysisValue: Equatable, Sendable {
    public let counts: AnalysisEntryCounts
    public let bytes: AnalysisByteSubtotals

    init(encoded data: Data) throws {
        guard data.count == 140 else { throw StorageScanFailure.invalidOutput }
        var counts = AnalysisEntryCounts(), bytes = AnalysisByteSubtotals()
        let numbers = (0..<5).map { storedUnsigned(data, at: $0 * 8) }
        var total: UInt64 = 0
        for count in numbers {
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard !overflow, sum < UInt64(Int64.max) else { throw StorageScanFailure.invalidOutput }; total = sum
        }
        counts.regularFiles = numbers[0]; counts.directories = numbers[1]
        counts.symbolicLinks = numbers[2]; counts.other = numbers[3]; counts.unknown = numbers[4]
        for metric in AnalysisByteMetric.allCases {
            let offset = 40 + metric.rawValue * 25
            guard data[offset + 24] <= 1 else { throw StorageScanFailure.invalidOutput }
            var value = AnalysisMetricSubtotal()
            value.overflowed = data[offset + 24] == 1
            let known = storedUnsigned(data, at: offset)
            guard !value.overflowed || known == 0 else { throw StorageScanFailure.invalidOutput }
            value.knownBytes = value.overflowed ? nil : known
            value.notReturnedCount = storedUnsigned(data, at: offset + 8)
            value.failedCount = storedUnsigned(data, at: offset + 16)
            let (unavailable, overflow) = value.notReturnedCount.addingReportingOverflow(value.failedCount)
            guard !overflow, unavailable <= counts.regularFiles else { throw StorageScanFailure.invalidOutput }
            bytes[metric] = value
        }
        self.counts = counts; self.bytes = bytes
    }

    init(kind: Int, payload: Data) throws {
        guard (0..<5).contains(kind), payload.count == 52 else { throw StorageScanFailure.invalidOutput }
        var encoded = Data(repeating: 0, count: 140)
        encoded[kind * 8 + 7] = 1
        for metric in 0..<4 {
            let offset = metric * 13, state = payload[offset]
            let number = storedUnsigned(payload, at: offset + 1)
            let code = payload[(offset + 9)..<(offset + 13)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard state <= 2, code <= Int32.max, state == 1 || number == 0,
                  state == 2 || code == 0 else { throw StorageScanFailure.invalidOutput }
            if kind == 0 {
                let target = 40 + metric * 25
                switch state {
                case 1: encoded.replaceSubrange(target..<(target + 8), with: payload[(offset + 1)..<(offset + 9)])
                case 0: encoded[target + 15] = 1
                default: encoded[target + 23] = 1
                }
            }
        }
        try self.init(encoded: encoded)
    }
}

func storedUnsigned(_ data: Data, at offset: Int) -> UInt64 {
    data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
}

public struct StoredAnalysisRow: Identifiable, Sendable {
    public let id: UInt64
    public let rawName: Data
    public let kind: AnalysisEntryKind
    public let value: StoredAnalysisValue
    public var title: String { String(bytes: rawName, encoding: .utf8) ?? "Name cannot be displayed as UTF-8" }
}

public struct StoredAnalysisSummary: Sendable {
    public let value: StoredAnalysisValue
    public let complete: Bool
    public let classificationReady: Bool
    public internal(set) var sources: [StoredAnalysisSource] = []
    public internal(set) var verifiedAliases: UInt64 = 0
    public internal(set) var unresolvedAliases: UInt64 = 0
}

public struct StoredAnalysisSource: Sendable {
    public let id: UInt64
    public let value: StoredAnalysisValue
    public let traversalFinished: Bool
    public var title: String { id == 1 ? "Data" : "System" }
}

public enum StoredAnalysisFacet: Int, CaseIterable, Sendable {
    case fileTypes, storageRoles, projects, applicationLayouts
    public var title: String {
        switch self { case .fileTypes: "File Types"; case .storageRoles: "Storage Roles"; case .projects: "Projects"; case .applicationLayouts: "Applications & Layouts" }
    }
}

public struct StoredAnalysisGroup: Identifiable, Sendable {
    public let id: UInt64
    public let rawName: Data
    public let value: StoredAnalysisValue
}

public struct StoredAnalysisGroups: Sendable {
    public let facet: StoredAnalysisFacet
    public let groups: [StoredAnalysisGroup]
    public let remainder: StoredAnalysisValue
    public let groupCount: UInt64
    public let projectCount: UInt64

    /// The group-to-query contract is shared by every native chart/legend.
    /// These are stored-result targets, with no source traversal or UI state.
    public func attributionSlices(scopeName: String) -> [AnalysisAttributionSlice] {
        var rows = groups.map { group -> AnalysisAttributionSlice in
            let title: String, explanation: String
            switch facet {
            case .fileTypes:
                let type = AnalysisFileType(rawValue: Int(group.id))!
                title = type.title; explanation = type.explanation
            case .storageRoles:
                let role = AnalysisCategory(rawValue: Int(group.id))!
                title = role.title; explanation = role.explanation
            case .projects:
                title = group.id == 0 ? "Unassigned / shared" : group.rawName.isEmpty ? scopeName
                    : String(data: group.rawName, encoding: .utf8) ?? "Project name is not UTF-8"
                explanation = "Observed project-marker filename only; generated and dependency markers are excluded. Nested projects retain their own totals."
            case .applicationLayouts:
                let layout = AnalysisApplicationLayout(rawValue: Int(group.id))!
                title = layout.title
                explanation = "Observed directory and filename layout, across all file types. No manifests or file contents were read; this does not establish ownership, active use or cleanup safety."
            }
            var slice = AnalysisAttributionSlice(title: title, explanation: explanation, bytes: group.value.bytes,
                files: group.value.counts.regularFiles, folder: nil)
            // Zero means unassigned; a project key is its folder ID + 1.
            // Other facet keys span the complete scan rather than a folder.
            let folder = facet == .projects && group.id > 0 ? group.id - 1 : 0
            slice.storedTarget = .filtered(folder: folder, facet: facet, key: group.id)
            if facet == .storageRoles, let role = AnalysisCategory(rawValue: Int(group.id)) { slice.purposeTarget = .projects(role: role) }
            if facet == .storageRoles, group.id == UInt64(AnalysisCategory.steamLibrary.rawValue) { slice.storedTarget = .steamLibraries }
            return slice
        }
        if remainder.counts.regularFiles > 0 {
            rows.append(.init(title: "Remaining groups", explanation: "All remaining observed groups combined; not omitted from totals.",
                bytes: remainder.bytes, files: remainder.counts.regularFiles, folder: nil))
        }
        return rows
    }
}

public struct PagedStorageScanUpdate: Sendable {
    public let session: UUID
    public let status: StorageScanStatus
    public let committedEntries: UInt64
    public let result: StorageAnalysisResult?
    public let elapsed: TimeInterval
    public let workerPeakResidentBytes: UInt64?
    public let coverage: AnalysisScanCoverage
    public let workerDrained: Bool
    public let isStartupPair: Bool
    public internal(set) var provisionalFileTypes: CommittedAnalysisPrefix? = nil
    public internal(set) var diagnostics: AnalysisScanDiagnostics? = nil
}

func storedNumber(_ value: Any?) throws -> UInt64 {
    guard let text = value as? String, !text.isEmpty, text.count <= 20,
          text.utf8.allSatisfy({ (48...57).contains($0) }), text == "0" || !text.hasPrefix("0"),
          let number = UInt64(text) else { throw StorageScanFailure.invalidOutput }
    return number
}

func storedBlob(_ value: Any?, length: Int? = nil) throws -> Data {
    guard let text = value as? String, text.utf8.count <= 1024,
          let data = Data(base64Encoded: text), data.base64EncodedString() == text,
          length == nil || data.count == length else { throw StorageScanFailure.invalidOutput }
    return data
}
