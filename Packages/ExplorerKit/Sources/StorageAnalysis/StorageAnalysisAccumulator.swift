import Foundation

/// Pure metadata accounting for a parent-first, already-scoped observation
/// stream. It performs no I/O, schedules no worker and owns no access lease.
public struct StorageAnalysisAccumulator: Sendable {
    private struct Fingerprint: Equatable, Sendable {
        let kind: AnalysisEntryKind
        let identity: AnalysisMetadata<AnalysisObjectIdentity>
    }
    private struct Folder: Sendable {
        let path: Data
        let parent: Int?
        let identity: AnalysisMetadata<AnalysisObjectIdentity>
        let ownSlot: Int
        let acceptsChildren: Bool
        var metricSlot = -1
        var counts = AnalysisEntryCounts()
        var issueCount: UInt64 = 0
    }
    private struct Object: Sendable {
        let bytes: AnalysisByteObservation
        let linkCount: AnalysisMetadata<UInt64>
        let flags: AnalysisMetadata<UInt32>
        let firstFolder: Int
        var edges: UInt64 = 1
        var crossFolder = false
    }

    private var sealedSnapshot: StorageAnalysisSnapshot?
    private var sealedProgress: StorageAnalysisProgress?

    public let limits: AnalysisLimits
    private var inputState = AnalysisInputState.accepting
    private var processedRecords: UInt64 = 0
    private var rejectedRecords: UInt64 = 0
    private var retainedRawPathBytes = 0
    private var folders: [Folder]
    private var folderMetrics: [AnalysisByteSubtotals] = []
    private var ownMetadata: [AnalysisByteObservation] = []
    private var folderByPath: [Data: Int] = [Data(): 0]
    private var seen: [Data: Fingerprint] = [:]
    private var directoryIdentities: Set<AnalysisObjectIdentity>
    private var objects: [AnalysisObjectIdentity: Object] = [:]
    private var namespaceCounts = AnalysisEntryCounts()
    private var namespaceBytes = AnalysisByteSubtotals()
    private var objectBytes = AnalysisByteSubtotals()
    private var identityMissingEntries: UInt64 = 0
    private var crossFolderObjects: UInt64 = 0
    private var outsideLinkObjects: UInt64 = 0
    private var unknownLinkCountObjects: UInt64 = 0
    private var issueCount: UInt64 = 0
    private var issues: [AnalysisIssue] = []
    private var projectMarkers: [AnalysisFolderID: AnalysisProjectMarker] = [:]
    private var typeBytes = Array(repeating: AnalysisByteSubtotals(), count: AnalysisClassificationRevision.v2.fileTypes.count)
    private var typeFiles = Array(repeating: UInt64(0), count: AnalysisClassificationRevision.v2.fileTypes.count)

    public init(rootIdentity: AnalysisObjectIdentity, limits: AnalysisLimits = .standard) {
        self.limits = limits
        folders = [Folder(path: Data(), parent: nil, identity: .returned(rootIdentity),
                          ownSlot: -1, acceptsChildren: true)]
        directoryIdentities = [rootIdentity]
    }

    public var progress: StorageAnalysisProgress {
        if let sealedProgress { return sealedProgress }
        return StorageAnalysisProgress(inputState: inputState, processedRecords: processedRecords,
                                rejectedRecords: rejectedRecords, acceptedCounts: namespaceCounts,
                                namespaceSubtotals: namespaceBytes, knownObjectCount: UInt64(objects.count),
                                folderCount: folders.count, retainedRawPathBytes: retainedRawPathBytes,
                                issueCount: issueCount)
    }

    /// Parents must have appeared as directories earlier in this stream. An
    /// invalid/orphan/duplicate record is not charged and makes coverage partial.
    @discardableResult
    public mutating func consume(_ observation: AnalysisEntryObservation) -> AnalysisAdmission {
        guard inputState == .accepting else { return .closed }
        guard admitInput() else { return .resourceLimited(.records) }
        let parentPath: Data
        switch validate(observation.relativePath) {
        case .success(let parent): parentPath = parent
        case .failure(let problem): return reject(.invalidPath(problem), folder: 0)
        }
        if let previous = seen[observation.relativePath] {
            let code: AnalysisIssueCode
            if previous.kind != observation.kind { code = .entryKindChanged }
            else if let first = previous.identity.value, let second = observation.identity.value, first != second {
                code = .entryIdentityChanged
            } else if previous.identity != observation.identity { code = .entryIdentityUncertain }
            else { code = .duplicatePath }
            return reject(code, folder: folderByPath[parentPath] ?? 0)
        }
        guard let parent = folderByPath[parentPath] else {
            return reject(seen[parentPath] == nil ? .parentMissing : .parentNotDirectory, folder: 0)
        }
        guard folders[parent].acceptsChildren else { return reject(.parentNotDirectory, folder: parent) }
        guard observation.relativePath.count <= limits.maximumRetainedRawPathBytes - retainedRawPathBytes else {
            rejectedRecords += 1
            closeForLimit(.retainedRawPathBytes)
            return .resourceLimited(.retainedRawPathBytes)
        }

        retainedRawPathBytes += observation.relativePath.count
        // A small Data slice can otherwise retain a much larger caller buffer.
        // Retain only an owned copy of the admitted bytes, shared by our indexes.
        let ownedPath = observation.relativePath.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        seen[ownedPath] = Fingerprint(kind: observation.kind, identity: observation.identity)
        namespaceCounts.add(observation.kind)
        folders[parent].counts.add(observation.kind)
        var issueFolder = parent
        if observation.kind == .directory {
            let duplicateIdentity = observation.identity.value.map { !directoryIdentities.insert($0).inserted } ?? false
            let index = folders.count
            let ownSlot = observation.bytes == AnalysisByteObservation() ? -1 : ownMetadata.count
            if ownSlot >= 0 { ownMetadata.append(observation.bytes) }
            folders.append(Folder(path: ownedPath, parent: parent, identity: observation.identity,
                                  ownSlot: ownSlot, acceptsChildren: !duplicateIdentity))
            folderByPath[ownedPath] = index
            issueFolder = index
            if duplicateIdentity { appendIssue(.directoryIdentityRepeated, folder: index) }
        }
        if let marker = AnalysisProjectMarker.match(ownedPath, kind: observation.kind) {
            let id = AnalysisFolderID(rawValue: parent)
            projectMarkers[id] = min(projectMarkers[id] ?? marker, marker)
        }
        noteMetadata(observation, folder: issueFolder)
        if observation.kind == .unknown { appendIssue(.unknownKind, folder: parent) }
        if observation.kind == .regularFile { addRegularFile(observation, folder: parent) }
        return .accepted
    }

    /// Fixed-code backend coverage gaps can be supplied without paths or logs.
    /// They count against the same bounded input-event allowance as observations.
    @discardableResult
    public mutating func recordCoverageGap(_ gap: AnalysisCoverageGap, in folder: AnalysisFolderID = .root) -> Bool {
        guard inputState == .accepting, admitInput() else { return false }
        let index = folder.rawValue
        guard folders.indices.contains(index) else {
            appendIssue(.invalidFolderReference, folder: 0); return false
        }
        appendIssue(.coverage(gap), folder: index)
        return true
    }

    /// Terminal compaction. The immutable snapshot outlives input
    /// validation indexes, without implying worker or access-lease drain.
    @discardableResult
    public mutating func finish(_ completion: AnalysisInputCompletion = .completed) -> StorageAnalysisSnapshot {
        if let sealedSnapshot { return sealedSnapshot }
        if inputState == .accepting {
            if case .failed(let gap) = completion { appendIssue(.coverage(gap), folder: 0) }
            inputState = .closed(completion)
        }
        sealedProgress = progress
        let distinct = distinctSummary()
        // These indexes have no meaning after input closes. Retire them before
        // allocating the final folder array, rather than retaining both stages.
        seen = [:]
        folderByPath = [:]
        directoryIdentities = []
        objects = [:]
        let result = makeSnapshot(distinct: distinct)
        sealedSnapshot = result
        folders = []
        folderMetrics = []
        ownMetadata = []
        projectMarkers = [:]
        return result
    }

    /// A live snapshot remains independent of later input. A terminal snapshot
    /// shares only immutable result storage, so repeated reads do not reroll it.
    public func snapshot() -> StorageAnalysisSnapshot {
        sealedSnapshot ?? makeSnapshot(distinct: distinctSummary())
    }

    private func distinctSummary() -> AnalysisDistinctObjects {
        AnalysisDistinctObjects(knownObjectCount: UInt64(objects.count),
                                identityMissingEntries: identityMissingEntries, byteSubtotals: objectBytes,
                                observedCrossFolderHardlinkObjects: crossFolderObjects,
                                potentialOutsideLinkObjects: outsideLinkObjects,
                                objectsWithUnknownLinkCount: unknownLinkCountObjects)
    }

    private func makeSnapshot(distinct: AnalysisDistinctObjects) -> StorageAnalysisSnapshot {
        let completed = inputState == .closed(.completed) && issueCount == 0
        // Fold into the final result itself. Do not create an intermediate
        // full-size Rollup array alongside the accumulator and result arrays.
        var summaries = folders.indices.map { index in
            let folder = folders[index]
            let bytes = folder.metricSlot < 0 ? AnalysisByteSubtotals() : folderMetrics[folder.metricSlot]
            return AnalysisFolderSummary(id: AnalysisFolderID(rawValue: index),
                                         parent: folder.parent.map(AnalysisFolderID.init(rawValue:)),
                                         relativePath: folder.path, identity: folder.identity,
                                         ownMetadataBytes: folder.ownSlot < 0 ? AnalysisByteObservation() : ownMetadata[folder.ownSlot], counts: folder.counts,
                                         namespaceSubtotals: bytes, issueCount: folder.issueCount,
                                         isComplete: completed && folder.issueCount == 0 && !bytes.hasUnavailableValues)
        }
        if folders.count > 1 {
            for index in stride(from: folders.count - 1, through: 1, by: -1) {
                let child = summaries[index]
                let parentIndex = folders[index].parent!
                let parent = summaries[parentIndex]
                var counts = parent.counts
                var bytes = parent.namespaceSubtotals
                counts.merge(child.counts)
                bytes.merge(child.namespaceSubtotals)
                let count = parent.issueCount + child.issueCount
                summaries[parentIndex] = AnalysisFolderSummary(
                    id: parent.id, parent: parent.parent, relativePath: parent.relativePath,
                    identity: parent.identity, ownMetadataBytes: parent.ownMetadataBytes,
                    counts: counts, namespaceSubtotals: bytes, issueCount: count,
                    isComplete: completed && count == 0 && !bytes.hasUnavailableValues)
            }
        }
        var result = StorageAnalysisSnapshot(inputState: inputState, processedRecords: processedRecords,
                                       rejectedRecords: rejectedRecords, retainedRawPathBytes: retainedRawPathBytes,
                                       folders: summaries, distinctObjects: distinct, issueCount: issueCount,
                                       issues: issues, isComplete: completed && issueCount == 0)
        result.projectMarkers = projectMarkers
        result.fileTypes = AnalysisClassificationRevision.v2.fileTypes.map {
            AnalysisFileTypeSummary(type: $0, bytes: typeBytes[$0.rawValue], files: typeFiles[$0.rawValue])
        }
        return result
    }

    private mutating func admitInput() -> Bool {
        guard processedRecords < UInt64(limits.maximumRecords) else { closeForLimit(.records); return false }
        processedRecords += 1
        return true
    }

    private mutating func closeForLimit(_ limit: AnalysisResourceLimit) {
        appendIssue(.resourceLimit(limit), folder: 0)
        inputState = .closed(.resourceLimited(limit))
    }

    private mutating func reject(_ code: AnalysisIssueCode, folder: Int) -> AnalysisAdmission {
        rejectedRecords += 1
        appendIssue(code, folder: folder)
        return .rejected(code)
    }

    private mutating func appendIssue(_ code: AnalysisIssueCode, folder: Int) {
        // Input events <=220k, a fixed number of fields/event, one terminal issue.
        // These counts and entry counts therefore remain far below UInt64.max.
        issueCount += 1
        folders[folder].issueCount += 1
        if issues.count < limits.maximumDetailedIssues {
            issues.append(AnalysisIssue(code: code, folder: AnalysisFolderID(rawValue: folder),
                                        recordOrdinal: processedRecords == 0 ? nil : processedRecords))
        }
    }

    private mutating func noteMetadata(_ observation: AnalysisEntryObservation, folder: Int) {
        switch observation.identity {
        case .notReturned: appendIssue(.missingIdentity, folder: folder)
        case .failed(let code): appendIssue(.failedIdentity(code: code), folder: folder)
        case .returned: break
        }
        switch observation.linkCount {
        case .notReturned: appendIssue(.missingLinkCount, folder: folder)
        case .failed(let code): appendIssue(.failedLinkCount(code: code), folder: folder)
        case .returned: break
        }
        switch observation.flags {
        case .notReturned: appendIssue(.missingFlags, folder: folder)
        case .failed(let code): appendIssue(.failedFlags(code: code), folder: folder)
        case .returned: break
        }
    }

    private mutating func addRegularFile(_ observation: AnalysisEntryObservation, folder: Int) {
        let type = AnalysisFileType.match(observation.relativePath).rawValue
        typeFiles[type] += 1
        if folders[folder].metricSlot < 0 {
            folders[folder].metricSlot = folderMetrics.count
            folderMetrics.append(AnalysisByteSubtotals())
        }
        let slot = folders[folder].metricSlot
        for metric in AnalysisByteMetric.allCases {
            let value = observation.bytes[metric]
            _ = typeBytes[type][metric].add(value)
            if namespaceBytes[metric].add(value) { appendIssue(.overflow(.namespaceEntries, metric), folder: 0) }
            _ = folderMetrics[slot][metric].add(value)
            switch value {
            case .notReturned: appendIssue(.missingMetric(metric), folder: folder)
            case .failed(let code): appendIssue(.failedMetric(metric, code: code), folder: folder)
            case .returned: break
            }
        }
        guard let identity = observation.identity.value else { identityMissingEntries += 1; return }
        if var object = objects[identity] {
            let previousOutside = object.linkCount.value.map { $0 > object.edges } ?? false
            object.edges += 1
            if object.bytes != observation.bytes || object.linkCount != observation.linkCount || object.flags != observation.flags
                || object.linkCount.value.map({ object.edges > $0 }) == true {
                appendIssue(.objectMetadataChanged, folder: folder)
            }
            if !object.crossFolder && object.firstFolder != folder { object.crossFolder = true; crossFolderObjects += 1 }
            let outside = object.linkCount.value.map { $0 > object.edges } ?? false
            if previousOutside && !outside { outsideLinkObjects -= 1 }
            objects[identity] = object
        } else {
            objects[identity] = Object(bytes: observation.bytes, linkCount: observation.linkCount,
                                       flags: observation.flags, firstFolder: folder)
            if let links = observation.linkCount.value {
                if links > 1 { outsideLinkObjects += 1 }
                if links == 0 { appendIssue(.objectMetadataChanged, folder: folder) }
            } else { unknownLinkCountObjects += 1 }
            for metric in AnalysisByteMetric.allCases {
                if objectBytes[metric].add(observation.bytes[metric]) { appendIssue(.overflow(.distinctObjects, metric), folder: 0) }
            }
        }
    }

    private func validate(_ path: Data) -> Result<Data, AnalysisPathProblem> {
        guard !path.isEmpty else { return .failure(.rootEntry) }
        guard path.count <= limits.maximumPathBytes else { return .failure(.tooLong) }
        guard path.first != 47 else { return .failure(.absolute) }
        var componentLength = 0, depth = 1, offset = 0, lastSlash: Int?
        var first: UInt8 = 0, second: UInt8 = 0
        func componentProblem() -> AnalysisPathProblem? {
            if componentLength == 0 { return .emptyComponent }
            if first == 46 && (componentLength == 1 || (componentLength == 2 && second == 46)) { return .traversalComponent }
            return nil
        }
        for byte in path {
            if byte == 0 { return .failure(.nul) }
            if byte == 47 {
                if let problem = componentProblem() { return .failure(problem) }
                depth += 1
                guard depth <= limits.maximumDepth else { return .failure(.tooDeep) }
                lastSlash = offset; componentLength = 0
            } else {
                if componentLength == 0 { first = byte }
                if componentLength == 1 { second = byte }
                componentLength += 1
            }
            offset += 1
        }
        if let problem = componentProblem() { return .failure(problem) }
        return .success(lastSlash.map { Data(path.prefix($0)) } ?? Data())
    }
}
