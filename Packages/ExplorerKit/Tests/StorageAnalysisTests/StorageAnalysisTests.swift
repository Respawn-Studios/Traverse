import Foundation
import Testing
@testable import StorageAnalysis

private let generatedRoot = AnalysisObjectIdentity(device: 1, inode: 1)

private func bytes(_ data: UInt64, _ all: UInt64? = nil, _ allocated: UInt64? = nil,
                   _ allAllocated: UInt64? = nil) -> AnalysisByteObservation {
    AnalysisByteObservation(dataLogical: .returned(data), allForkLogical: .returned(all ?? data),
                            dataAllocated: .returned(allocated ?? data),
                            allForkAllocated: .returned(allAllocated ?? allocated ?? data))
}

private func entry(_ path: String, _ kind: AnalysisEntryKind, _ inode: UInt64,
                   links: UInt64 = 1, values: AnalysisByteObservation = AnalysisByteObservation()) -> AnalysisEntryObservation {
    AnalysisEntryObservation(relativePath: Data(path.utf8), kind: kind,
                             identity: .returned(AnalysisObjectIdentity(device: 1, inode: inode)),
                             linkCount: .returned(links), flags: .returned(0), bytes: values)
}

private func folder(_ snapshot: StorageAnalysisSnapshot, _ path: String) throws -> AnalysisFolderSummary {
    try #require(snapshot.folders.first { $0.relativePath == Data(path.utf8) })
}

@Test func storageAnalysisEmptyAndCollectingAreDistinct() {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    #expect(!accumulator.snapshot().isComplete)
    let complete = accumulator.finish()
    #expect(complete.isComplete)
    #expect(complete.folders.count == 1)
    #expect(complete.root.counts.total == 0)
    #expect(complete.root.namespaceSubtotals.dataLogical.knownBytes == 0)
    #expect(complete.distinctObjects.knownObjectCount == 0)
}

@Test func storageAnalysisCrossFolderHardlinksHaveOverlappingNamespaceBytes() throws {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    #expect(accumulator.consume(entry("a", .directory, 2)) == .accepted)
    #expect(accumulator.consume(entry("b", .directory, 3)) == .accepted)
    #expect(accumulator.consume(entry("a/first", .regularFile, 10, links: 3, values: bytes(7, 11, 4096, 8192))) == .accepted)
    #expect(accumulator.consume(entry("b/second", .regularFile, 10, links: 3, values: bytes(7, 11, 4096, 8192))) == .accepted)
    #expect(accumulator.consume(entry("b/unique", .regularFile, 11, values: bytes(13, 17, 32, 64))) == .accepted)
    let result = accumulator.finish()
    #expect(result.isComplete)
    #expect(result.root.counts.regularFiles == 3)
    #expect(result.root.counts.directories == 2)
    #expect(result.root.namespaceSubtotals.dataLogical.knownBytes == 27)
    #expect(result.root.namespaceSubtotals.allForkLogical.knownBytes == 39)
    #expect(result.root.namespaceSubtotals.dataAllocated.knownBytes == 8224)
    #expect(result.root.namespaceSubtotals.allForkAllocated.knownBytes == 16448)
    #expect(result.distinctObjects.knownObjectCount == 2)
    #expect(result.distinctObjects.byteSubtotals.dataLogical.knownBytes == 20)
    #expect(result.distinctObjects.byteSubtotals.allForkLogical.knownBytes == 28)
    #expect(result.distinctObjects.byteSubtotals.dataAllocated.knownBytes == 4128)
    #expect(result.distinctObjects.byteSubtotals.allForkAllocated.knownBytes == 8256)
    #expect(result.distinctObjects.observedCrossFolderHardlinkObjects == 1)
    #expect(result.distinctObjects.potentialOutsideLinkObjects == 1)
    #expect(try folder(result, "a").namespaceSubtotals.dataLogical.knownBytes == 7)
    #expect(try folder(result, "b").namespaceSubtotals.dataLogical.knownBytes == 20)
}

@Test func storageAnalysisFoldersPackagesAndLinksDoNotInventRegularBytes() throws {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    accumulator.consume(entry("Example.app", .directory, 2))
    accumulator.consume(entry("Example.app/Contents", .directory, 3, values: bytes(900, 901, 902, 903)))
    accumulator.consume(entry("Example.app/Contents/sparse", .regularFile, 4, values: bytes(256 << 20, 256 << 20, 0, 0)))
    accumulator.consume(entry("Example.app/Contents/forked", .regularFile, 5, values: bytes(4, 40, 4096, 8192)))
    accumulator.consume(entry("loop", .symbolicLink, 6, values: bytes(999)))
    let result = accumulator.finish()
    #expect(result.isComplete)
    #expect(result.root.counts.symbolicLinks == 1)
    #expect(result.root.counts.directories == 2)
    #expect(result.root.namespaceSubtotals.dataLogical.knownBytes == (256 << 20) + 4)
    #expect(result.root.namespaceSubtotals.allForkLogical.knownBytes == (256 << 20) + 40)
    #expect(result.root.namespaceSubtotals.dataAllocated.knownBytes == 4096)
    #expect(result.root.namespaceSubtotals.allForkAllocated.knownBytes == 8192)
    #expect(try folder(result, "Example.app/Contents").ownMetadataBytes.dataLogical == .returned(900))
    #expect(result.distinctObjects.knownObjectCount == 2)
}

@Test func storageAnalysisClonesStaySeparateObjectsWithoutExclusiveSpaceClaim() {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    accumulator.consume(entry("clone-a", .regularFile, 2, values: bytes(100, 100, 4096, 4096)))
    accumulator.consume(entry("clone-b", .regularFile, 3, values: bytes(100, 100, 4096, 4096)))
    let result = accumulator.finish()
    #expect(result.distinctObjects.knownObjectCount == 2)
    #expect(result.distinctObjects.byteSubtotals.dataAllocated.knownBytes == 8192)
    #expect(result.isComplete) // Complete API observations; not an extent-sharing claim.
}

@Test func storageAnalysisMissingFailedAndZeroRemainDifferent() {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    let values = AnalysisByteObservation(dataLogical: .returned(0), allForkLogical: .notReturned,
                                        dataAllocated: .failed(code: 13), allForkAllocated: .returned(0))
    accumulator.consume(entry("partial", .regularFile, 2, values: values))
    let result = accumulator.finish()
    #expect(!result.isComplete)
    #expect(result.root.namespaceSubtotals.dataLogical.knownBytes == 0)
    #expect(result.root.namespaceSubtotals.dataLogical.notReturnedCount == 0)
    #expect(result.root.namespaceSubtotals.allForkLogical.notReturnedCount == 1)
    #expect(result.root.namespaceSubtotals.dataAllocated.failedCount == 1)
    #expect(result.distinctObjects.byteSubtotals.dataAllocated.failedCount == 1)
    #expect(result.issues.contains { $0.code == .failedMetric(.dataAllocated, code: 13) })
}

@Test func storageAnalysisUnknownIdentityDoesNotGuessAnObject() {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    let unknown = AnalysisEntryObservation(relativePath: Data("unknown".utf8), kind: .regularFile,
                                           identity: .notReturned, linkCount: .notReturned, flags: .returned(0), bytes: bytes(7))
    accumulator.consume(unknown)
    let result = accumulator.finish()
    #expect(!result.isComplete)
    #expect(result.root.namespaceSubtotals.dataLogical.knownBytes == 7)
    #expect(result.distinctObjects.knownObjectCount == 0)
    #expect(result.distinctObjects.identityMissingEntries == 1)
    #expect(result.distinctObjects.byteSubtotals.dataLogical.knownBytes == 0)
}

@Test func storageAnalysisByteOverflowIsUnavailableWithoutLosingOtherMetrics() throws {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    accumulator.consume(entry("a", .directory, 2))
    accumulator.consume(entry("b", .directory, 3))
    accumulator.consume(entry("a/max", .regularFile, 4, values: bytes(UInt64.max, 1, 2, 3)))
    accumulator.consume(entry("b/one", .regularFile, 5, values: bytes(1, 4, 5, 6)))
    let result = accumulator.finish()
    #expect(!result.isComplete)
    #expect(result.root.namespaceSubtotals.dataLogical.knownBytes == nil)
    #expect(result.root.namespaceSubtotals.dataLogical.overflowed)
    #expect(result.distinctObjects.byteSubtotals.dataLogical.overflowed)
    #expect(result.root.namespaceSubtotals.allForkLogical.knownBytes == 5)
    #expect(result.root.namespaceSubtotals.dataAllocated.knownBytes == 7)
    #expect(try folder(result, "a").namespaceSubtotals.dataLogical.knownBytes == UInt64.max)
    #expect(try folder(result, "b").namespaceSubtotals.dataLogical.knownBytes == 1)
}

@Test func storageAnalysisDuplicateAndChangedIdentityDoNotDoubleCharge() {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    let first = entry("same", .regularFile, 2, values: bytes(10))
    accumulator.consume(first)
    #expect(accumulator.consume(first) == .rejected(.duplicatePath))
    #expect(accumulator.consume(entry("same", .regularFile, 3, values: bytes(99))) == .rejected(.entryIdentityChanged))
    let result = accumulator.finish()
    #expect(!result.isComplete)
    #expect(result.processedRecords == 3)
    #expect(result.rejectedRecords == 2)
    #expect(result.root.counts.regularFiles == 1)
    #expect(result.root.namespaceSubtotals.dataLogical.knownBytes == 10)
    #expect(result.distinctObjects.knownObjectCount == 1)
}

@Test func storageAnalysisChangingHardlinkMetadataRetainsFirstObjectObservation() {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    accumulator.consume(entry("first", .regularFile, 2, links: 2, values: bytes(10)))
    accumulator.consume(entry("second", .regularFile, 2, links: 2, values: bytes(20)))
    let result = accumulator.finish()
    #expect(!result.isComplete)
    #expect(result.root.namespaceSubtotals.dataLogical.knownBytes == 30)
    #expect(result.distinctObjects.byteSubtotals.dataLogical.knownBytes == 10)
    #expect(result.issues.contains { $0.code == .objectMetadataChanged })
}

@Test func storageAnalysisOrphansAndLinkDescendantsAreExplicitlyRejected() {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    #expect(accumulator.consume(entry("absent/child", .regularFile, 2, values: bytes(7))) == .rejected(.parentMissing))
    accumulator.consume(entry("link", .symbolicLink, 3))
    #expect(accumulator.consume(entry("link/child", .regularFile, 4, values: bytes(9))) == .rejected(.parentNotDirectory))
    let result = accumulator.finish()
    #expect(!result.isComplete)
    #expect(result.root.counts.total == 1)
    #expect(result.root.namespaceSubtotals.dataLogical.knownBytes == 0)
    #expect(result.rejectedRecords == 2)
}

@Test func storageAnalysisPathEscapeAndRawNames() {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    let invalid: [(Data, AnalysisPathProblem)] = [
        (Data(), .rootEntry), (Data("/absolute".utf8), .absolute), (Data("a//b".utf8), .emptyComponent),
        (Data("a/../b".utf8), .traversalComponent), (Data("./b".utf8), .traversalComponent),
        (Data("trailing/".utf8), .emptyComponent), (Data([97, 0, 98]), .nul),
    ]
    for (path, reason) in invalid {
        let observation = AnalysisEntryObservation(relativePath: path, kind: .regularFile)
        #expect(accumulator.consume(observation) == .rejected(.invalidPath(reason)))
    }
    let raw = AnalysisEntryObservation(relativePath: Data([255]), kind: .regularFile,
                                       identity: .returned(AnalysisObjectIdentity(device: 1, inode: 2)),
                                       linkCount: .returned(1), flags: .returned(0), bytes: bytes(5))
    #expect(accumulator.consume(raw) == .accepted)
    #expect(accumulator.finish().root.namespaceSubtotals.dataLogical.knownBytes == 5)
}

@Test func storageAnalysisResourceLimitsSealInputAndBoundIssueDetails() throws {
    let limits = try AnalysisLimits(maximumRecords: 5, maximumRetainedRawPathBytes: 3, maximumDetailedIssues: 1)
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot, limits: limits)
    accumulator.consume(entry("a", .regularFile, 2, values: bytes(1)))
    #expect(accumulator.consume(entry("long", .regularFile, 3, values: bytes(2))) == .resourceLimited(.retainedRawPathBytes))
    #expect(accumulator.consume(entry("b", .regularFile, 4, values: bytes(3))) == .closed)
    let result = accumulator.finish()
    #expect(result.inputState == .closed(.resourceLimited(.retainedRawPathBytes)))
    #expect(result.retainedRawPathBytes == 1)
    #expect(result.issues.count == 1)
    #expect(!result.isComplete)
    var recordBound = StorageAnalysisAccumulator(rootIdentity: generatedRoot, limits: try AnalysisLimits(maximumRecords: 1))
    recordBound.consume(entry("a", .regularFile, 2, values: bytes(1)))
    #expect(recordBound.consume(entry("b", .regularFile, 3, values: bytes(1))) == .resourceLimited(.records))
    #expect(recordBound.progress.processedRecords == 1)
}

@Test func storageAnalysisCoverageAndCancellationAreInputLifecycleOnly() throws {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    accumulator.consume(entry("folder", .directory, 2))
    let id = try #require(accumulator.snapshot().folders.last?.id)
    let acceptedGap = accumulator.recordCoverageGap(.truncated, in: id)
    #expect(acceptedGap)
    let cancelled = accumulator.finish(.cancelled)
    #expect(!cancelled.isComplete)
    #expect(try folder(cancelled, "folder").issueCount == 1)
    #expect(accumulator.consume(entry("late", .regularFile, 3, values: bytes(99))) == .closed)
    let acceptedLateGap = accumulator.recordCoverageGap(.disconnected)
    #expect(!acceptedLateGap)
    let again = accumulator.finish(.completed)
    #expect(again.inputState == .closed(.cancelled))
    #expect(again.processedRecords == cancelled.processedRecords)
    #expect(again.root.counts.total == 1)
}

@Test func storageAnalysisDeepPostorderMatchesIndependentPrefixOracle() throws {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    var paths: [(String, UInt64)] = []
    var directory = ""
    for level in 0..<40 {
        directory += directory.isEmpty ? "d" : "/d"
        accumulator.consume(entry(directory, .directory, UInt64(2 + level)))
        let path = directory + "/value"
        let value = UInt64(level + 1)
        paths.append((path, value))
        accumulator.consume(entry(path, .regularFile, UInt64(100 + level), values: bytes(value)))
    }
    let result = accumulator.finish()
    #expect(result.isComplete)
    #expect(result.root.counts.regularFiles == 40)
    for summary in result.folders {
        let prefix = summary.relativePath.isEmpty ? "" : String(decoding: summary.relativePath, as: UTF8.self) + "/"
        let independentlySummed = paths.filter { $0.0.hasPrefix(prefix) }.reduce(UInt64(0)) { $0 + $1.1 }
        #expect(summary.namespaceSubtotals.dataLogical.knownBytes == independentlySummed)
    }
}

@Test func storageAnalysisDirectoryCountIsNotA4096TotalLimit() {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    for index in 0..<4100 { accumulator.consume(entry("folder-\(index)", .directory, UInt64(2 + index))) }
    let result = accumulator.finish()
    #expect(result.isComplete)
    #expect(result.folders.count == 4101)
    #expect(result.root.counts.directories == 4100)
}

@Test func storageAnalysisRootGapDoesNotMakePreviouslySeenFoldersLookComplete() {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    accumulator.consume(entry("seen", .directory, 2))
    accumulator.recordCoverageGap(.truncated)
    let result = accumulator.finish()
    #expect(!result.isComplete)
    #expect(result.folders.allSatisfy { !$0.isComplete })
}

@Test func storageAnalysisPathBoundsAndIssueRetentionAreEnforced() throws {
    let limits = try AnalysisLimits(maximumPathBytes: 4, maximumDepth: 2, maximumDetailedIssues: 2)
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot, limits: limits)
    #expect(accumulator.consume(entry("longer", .regularFile, 2)) == .rejected(.invalidPath(.tooLong)))
    let depthLimited = try AnalysisLimits(maximumDepth: 2)
    var depth = StorageAnalysisAccumulator(rootIdentity: generatedRoot, limits: depthLimited)
    #expect(depth.consume(entry("a/b/c", .regularFile, 2)) == .rejected(.invalidPath(.tooDeep)))
    for index in 0..<10 { accumulator.consume(entry("/\(index)", .regularFile, UInt64(index + 10))) }
    let result = accumulator.finish()
    #expect(result.issueCount == 11)
    #expect(result.issues.count == 2)
    #expect(result.retainedRawPathBytes == 0)
    #expect(result.root.counts.total == 0)
}

@Test func storageAnalysisRepeatedDirectoryIdentityCannotAdmitAliasDescendants() throws {
    var accumulator = StorageAnalysisAccumulator(rootIdentity: generatedRoot)
    accumulator.consume(entry("first", .directory, 2))
    accumulator.consume(entry("alias", .directory, 2))
    #expect(accumulator.consume(entry("alias/child", .regularFile, 3, values: bytes(50))) == .rejected(.parentNotDirectory))
    let result = accumulator.finish()
    #expect(!result.isComplete)
    #expect(result.root.counts.directories == 2)
    #expect(result.root.counts.regularFiles == 0)
    #expect(try folder(result, "alias").issueCount == 2)
    #expect(result.issues.contains { $0.code == .directoryIdentityRepeated })
}
