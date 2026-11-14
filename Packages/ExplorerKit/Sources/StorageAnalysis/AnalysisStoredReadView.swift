import Foundation

/// The analysis models' read-only surface. Catalog identity describes the
/// stored result; view identity describes one consumer's query authority.
/// Location resolution and native closure deliberately remain outside it.
@_spi(ApplicationOwnership) public protocol AnalysisStoredReadView: AnyObject, Sendable {
    var catalogID: UUID { get }
    var viewID: UUID { get }
    var classificationRevision: AnalysisClassificationRevision { get }
    var metadataPolicy: AnalysisMetadataPolicy { get }
    var maximumStoredHierarchyDepth: Int { get }
    var supportsApplicationLayouts: Bool { get }
    var supportsSortedPages: Bool { get }
    var supportsPurposeJourney: Bool { get }
    var supportsLargestFiles: Bool { get }

    func summary() async throws -> StoredAnalysisSummary
    func page(parent: UInt64, after: UInt64) async throws -> [StoredAnalysisRow]
    func sortedPage(parent: UInt64, after: UInt64,
                    order: StoredAnalysisSortOrder) async throws -> StoredAnalysisSortedPage
    func groups(_ facet: StoredAnalysisFacet) async throws -> StoredAnalysisGroups
    func attribution(scopeName: String, summary: StoredAnalysisSummary) async throws -> AnalysisAttributionReport?
    func breakdown(_ target: StoredAnalysisDrillTarget,
                   metric: AnalysisByteMetric) async throws -> StoredAnalysisBreakdown
    func projectComposition(_ target: StoredAnalysisDrillTarget,
                            metric: AnalysisByteMetric) async throws -> StoredProjectComposition
    func largestFiles(metric: AnalysisLargestFileMetric) async throws -> StoredLargestFiles
    func purposeProjects(_ role: AnalysisCategory,
                         metric: AnalysisByteMetric) async throws -> StoredPurposeProjects
    func purposeLocations(role: AnalysisCategory, project: UInt64,
                          metric: AnalysisByteMetric) async throws -> StoredPurposeLocations
    func explainOther(folder: UInt64) async throws -> StoredAnalysisOtherExplanation
}

// Existing live models can consume their result through the same narrow seam.
// For a separately revocable live model use RecordedAnalysisQueries.live(...).
@_spi(ApplicationOwnership) extension StorageAnalysisResult: AnalysisStoredReadView {
    public var catalogID: UUID { id }
    public var viewID: UUID { id }
}

@_spi(ApplicationOwnership) extension RecordedAnalysisQueries: AnalysisStoredReadView {}
