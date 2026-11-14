import Foundation

/// Experimental presentation of one durably committed prefix, never a final
/// result or a source of authority. Fixed, revision-bound filename-type groups.
public struct CommittedAnalysisPrefix: Sendable {
    public let entries: UInt64
    public let elapsedNanoseconds: UInt64
    public let sequence: UInt64
    public let checkpointRows: UInt64
    public let classificationRevision: AnalysisClassificationRevision
    public let value: StoredAnalysisValue
    public let fileTypes: [StoredAnalysisValue]

    /// Small metadata-only presentation. No result handle or browse targets.
    public func attributionReport() -> AnalysisAttributionReport {
        let groups = classificationRevision.fileTypes.map { type in
            let value = fileTypes[type.rawValue]
            return AnalysisAttributionSlice(title: type.title, explanation: "Filename hints in committed observations so far; no file contents were read.",
                bytes: value.bytes, files: value.counts.regularFiles, folder: nil)
        }
        var report = AnalysisAttributionReport(categories: [], fileTypes: groups, projects: [], projectCount: 0,
            isComplete: false, crossFolderHardlinkObjects: 0)
        report.hasLayoutAttribution = false; report.crossFolderHardlinkCountIsKnown = false; report.isProvisional = true
        return report
    }

    static func decode(_ frame: [String: Any], session: UUID, policy: AnalysisMetadataPolicy,
                       wireSchema: Int, committed: UInt64, previous: Self?, checkpointRows: UInt64 = 1024,
                       classificationRevision: AnalysisClassificationRevision = .v2) throws -> Self {
        let checkpoint = try AnalysisCheckpointContract(rows: checkpointRows, classification: classificationRevision)
        guard frame["kind"] as? String == "committed_totals", strictInteger(frame["prefix_revision"]) == checkpoint.prefixRevision,
              strictInteger(frame["schema"]) == wireSchema, checkpoint.acceptsSchema(wireSchema),
              frame["session"] as? String == session.uuidString,
              frame["policy_revision"] as? String == policy.rawValue,
              let rows = frame["types"] as? [[String: Any]], rows.count == classificationRevision.fileTypes.count else {
            throw StorageScanFailure.invalidOutput
        }
        let entries = try storedNumber(frame["committed"]), elapsed = try storedNumber(frame["elapsed_ns"])
        let sequence = try storedNumber(frame["seq"])
        guard entries == committed, checkpoint.acceptsSnapshotCount(entries),
              elapsed >= 250_000_000, elapsed < UInt64(Int64.max) else { throw StorageScanFailure.invalidOutput }
        if let previous {
            guard previous.classificationRevision == classificationRevision, previous.checkpointRows == checkpointRows, entries > previous.entries, sequence > previous.sequence,
                  elapsed >= previous.elapsedNanoseconds, elapsed - previous.elapsedNanoseconds >= 250_000_000 else {
                throw StorageScanFailure.invalidOutput
            }
        }
        let value = try StoredAnalysisValue(encoded: storedBlob(frame["value"], length: 140))
        guard value.counts.total == entries else { throw StorageScanFailure.invalidOutput }
        var types: [StoredAnalysisValue] = [], bytes = AnalysisByteSubtotals(), files: UInt64 = 0
        for (index, row) in rows.enumerated() {
            guard strictInteger(row["id"]) == index else { throw StorageScanFailure.invalidOutput }
            let item = try StoredAnalysisValue(encoded: storedBlob(row["value"], length: 140))
            guard item.counts.total == item.counts.regularFiles else { throw StorageScanFailure.invalidOutput }
            let (sum, overflow) = files.addingReportingOverflow(item.counts.regularFiles)
            guard !overflow else { throw StorageScanFailure.invalidOutput }; files = sum
            bytes.merge(item.bytes); types.append(item)
        }
        guard files == value.counts.regularFiles, bytes == value.bytes else { throw StorageScanFailure.invalidOutput }
        if let previous {
            try requireGrowth(previous.value, value)
            for (old, new) in zip(previous.fileTypes, types) { try requireGrowth(old, new) }
        }
        return .init(entries: entries, elapsedNanoseconds: elapsed, sequence: sequence, checkpointRows: checkpointRows, classificationRevision: classificationRevision, value: value, fileTypes: types)
    }

    private static func requireGrowth(_ old: StoredAnalysisValue, _ new: StoredAnalysisValue) throws {
        guard new.counts.regularFiles >= old.counts.regularFiles, new.counts.directories >= old.counts.directories,
              new.counts.symbolicLinks >= old.counts.symbolicLinks, new.counts.other >= old.counts.other,
              new.counts.unknown >= old.counts.unknown else { throw StorageScanFailure.invalidOutput }
        for metric in AnalysisByteMetric.allCases {
            let a = old.bytes[metric], b = new.bytes[metric]
            guard b.notReturnedCount >= a.notReturnedCount, b.failedCount >= a.failedCount,
                  !a.overflowed || b.overflowed,
                  b.overflowed || (b.knownBytes ?? 0) >= (a.knownBytes ?? 0) else { throw StorageScanFailure.invalidOutput }
        }
    }
}
