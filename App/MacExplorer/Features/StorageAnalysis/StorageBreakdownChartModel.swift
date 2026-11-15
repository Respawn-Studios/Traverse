@_spi(ApplicationOwnership) import StorageAnalysis
import SwiftUI

/// One query plus one replaceable pending intent. Sixteen small chart levels,
/// no source walk, detached view queue or complete hierarchy in memory.
@MainActor
final class StorageBreakdownChartModel: ObservableObject {
    struct Level {
        enum Route { case recorded(StoredAnalysisDrillTarget), purpose(StoredPurposeJourneyTarget) }
        let id = UUID()
        let route: Route
        var target: StoredAnalysisDrillTarget? { if case .recorded(let target) = route { target } else { nil } }
        var purposeTarget: StoredPurposeJourneyTarget? { if case .purpose(let target) = route { target } else { nil } }
        let title: String
        let value: StoredAnalysisBreakdown
        var composition: StoredProjectComposition? = nil
        var otherExplanation: StoredAnalysisOtherExplanation?
        let purposeProjects: StoredPurposeProjects?
        let purposeLocations: StoredPurposeLocations?
        init(target: StoredAnalysisDrillTarget, title: String, value: StoredAnalysisBreakdown, composition: StoredProjectComposition? = nil, otherExplanation: StoredAnalysisOtherExplanation? = nil) {
            route = .recorded(target); self.title = title; self.value = value; self.composition = composition; self.otherExplanation = otherExplanation
            purposeProjects = nil; purposeLocations = nil
        }
        init(projects: StoredPurposeProjects, title: String) {
            route = .purpose(.projects(role: projects.role)); self.title = title; value = projects.overview
            purposeProjects = projects; purposeLocations = nil
        }
        init(locations: StoredPurposeLocations, title: String) {
            route = .purpose(.locations(role: locations.role, project: locations.project)); self.title = title; value = locations.overview
            purposeProjects = nil; purposeLocations = locations
        }
    }
    @Published private(set) var levels: [Level] = []
    @Published private(set) var loading = false
    @Published private(set) var message = ""
    @Published private(set) var canBrowse = false
    @Published private(set) var canShowApplicationLayouts = false
    @Published private(set) var applicationLayouts: StoredAnalysisGroups?
    @Published private(set) var canUsePurposeJourney = false
    @Published private(set) var locationActionRunning = false
    @Published private(set) var locationMessage = ""
    @Published private(set) var selectedPurposeLocationID: UInt64?
    @Published private var knownTrashes: [UUID: UInt64] = [:]
    var onLocationAction: ((StorageAnalysisResult, UInt64, StoredLocationAction, @escaping (String) -> Void) -> Void)?
    var onCancelLocationAction: ((UUID) -> Void)?
    private var locationActionID: UUID?
    struct PurposeLocationSelection {
        let resultID: UUID, levelID: UUID
        let location: StoredPurposeLocation
    }
    private weak var result: (any AnalysisStoredReadView)?
    private weak var liveLocationResult: StorageAnalysisResult?
    private var viewID: UUID?
    private var resultID: UUID?
    private var generation = UUID()
    private var metric = AnalysisByteMetric.dataLogical
    // Only the bounded root folder breakdown is reused across group changes.
    // A new read view revokes this cache along with Application Layouts.
    private var folderRoots: [AnalysisByteMetric: StoredAnalysisBreakdown] = [:]
    private var request: Task<Void, Never>?
    private enum Intent {
        case breakdown(StoredAnalysisDrillTarget, title: String, replace: Bool)
        case composition(StoredAnalysisDrillTarget, title: String, replace: Bool)
        case explainOther(folder: UInt64, level: UUID)
        case applicationLayouts
        case purpose(StoredPurposeJourneyTarget, title: String, replace: Bool)
    }
    private var pending: Intent?
    var current: Level? { levels.last }
    var parent: Level? { levels.count > 1 ? levels[levels.count - 2] : nil }
    var scopeIdentity: UUID? { viewID }
    deinit { request?.cancel() }

    func configure(_ result: StorageAnalysisResult?, metric: AnalysisByteMetric = .dataLogical) {
        configureReadView(result, liveLocationResult: result, metric: metric)
    }
    /// Recorded reads carry a separately revocable view. They never supply a
    /// live result to the existing current-location action callbacks.
    func configureRecorded(_ queries: any AnalysisStoredReadView, metric: AnalysisByteMetric = .dataLogical) {
        configureReadView(queries, liveLocationResult: nil, metric: metric)
    }
    private func configureReadView(_ queries: (any AnalysisStoredReadView)?,
                                   liveLocationResult: StorageAnalysisResult?, metric: AnalysisByteMetric) {
        // A repeated render of the same view preserves its chosen size metric.
        // Explicit size changes go through setMetric, as in the existing model.
        guard viewID != queries?.viewID || self.liveLocationResult?.id != liveLocationResult?.id else { return }
        reset(); applicationLayouts = nil; folderRoots = [:]
        self.result = queries; self.liveLocationResult = liveLocationResult
        resultID = queries?.catalogID; viewID = queries?.viewID
        self.metric = metric; canBrowse = queries != nil
        canShowApplicationLayouts = queries?.supportsApplicationLayouts == true
        canUsePurposeJourney = queries?.supportsPurposeJourney == true && StoragePurposeJourneyFeature.isEnabled
        knownTrashes = [:]
    }
    var hasCurrentLocationActions: Bool { liveLocationResult?.supportsStoredLocations == true }
    func reset() {
        cancelLocationAction()
        selectedPurposeLocationID = nil
        generation = UUID(); pending = nil; request?.cancel()
        levels = []; loading = false; message = ""
    }
    func close() { reset(); result = nil; liveLocationResult = nil; viewID = nil; resultID = nil; canBrowse = false; canShowApplicationLayouts = false; canUsePurposeJourney = false; applicationLayouts = nil; folderRoots = [:]; knownTrashes = [:]; onLocationAction = nil; onCancelLocationAction = nil }
    /// A cancelled task may not yet have entered the result's reader queue.
    /// Wait for this owner before interpreting a zero shared reader count.
    func waitUntilQueriesDrained() async { await request?.value }
    func loadApplicationLayouts() {
        guard canShowApplicationLayouts, applicationLayouts == nil else { return }
        generation = UUID(); pending = .applicationLayouts
        loading = true; message = ""; request?.cancel(); pump()
    }
    func openRootFolder(title: String) {
        guard canBrowse, result != nil else { return }
        if let value = folderRoots[metric] {
            // A cached root is a new navigation intent too: reject any older
            // in-flight response before publishing it, even for direct callers.
            reset()
            levels = [.init(target: .folder(0), title: title, value: value)]
        } else { open(.folder(0), title: title) }
    }
    func open(_ target: StoredAnalysisDrillTarget, title: String) {
        guard levels.count < 16 else { message = "Use the folder browser below to explore deeper."; return }
        enqueue(target, title: title, replace: false)
    }
    func openProject(_ target: StoredAnalysisDrillTarget, title: String) {
        generation = UUID(); pending = .composition(target, title: title, replace: false)
        loading = true; message = ""; request?.cancel(); pump()
    }
    func openPurpose(_ target: StoredPurposeJourneyTarget, title: String) {
        guard canUsePurposeJourney, !loading, !locationActionRunning else { return }
        switch target {
        case .projects: guard levels.isEmpty else { return }
        case .locations(let role, let project):
            guard let projects = current?.purposeProjects, projects.role == role, projects.projects.contains(where: { $0.id == project }) else { return }
        }
        enqueuePurpose(target, title: title, replace: false)
    }
    private func enqueuePurpose(_ target: StoredPurposeJourneyTarget, title: String, replace: Bool) {
        selectedPurposeLocationID = nil
        generation = UUID(); pending = .purpose(target, title: title, replace: replace)
        loading = true; message = ""; request?.cancel(); pump()
    }
    func browseRecordedProjectFolders() {
        guard let current, current.composition != nil, let target = current.target else { return }
        enqueue(target, title: current.title, replace: true)
    }
    func back() {
        returnToLevelCount(max(0, levels.count - 1))
    }
    /// One publication and generation change, including a multi-level return.
    /// Cached levels retain their original stored targets and query ownership.
    func returnToLevelCount(_ count: Int) {
        guard count >= 0 && count <= levels.count && (count < levels.count || count == 0) else { return }
        cancelLocationAction(); selectedPurposeLocationID = nil; generation = UUID(); pending = nil; request?.cancel(); loading = false
        levels = Array(levels.prefix(count))
        if let level = current, level.value.rankingMetric != metric { reload(level) }
    }
    func setMetric(_ value: AnalysisByteMetric) {
        guard metric != value else { return }
        metric = value
        if let level = current { reload(level) }
    }
    private func reload(_ level: Level) {
        if let target = level.purposeTarget { enqueuePurpose(target, title: level.title, replace: true); return }
        guard let target = level.target else { return }
        guard level.composition != nil else { enqueue(target, title: level.title, replace: true); return }
        generation = UUID(); pending = .composition(target, title: level.title, replace: true)
        loading = true; message = ""; request?.cancel(); pump()
    }
    var canExplainOther: Bool {
        if case .filtered(_, .fileTypes, 0) = current?.target { return true }
        return false
    }
    func explainOther() {
        guard !loading, let current, current.otherExplanation == nil,
              case .filtered(let folder, .fileTypes, 0) = current.target else { return }
        generation = UUID(); pending = .explainOther(folder: folder, level: current.id)
        loading = true; message = ""; request?.cancel(); pump()
    }
    private func enqueue(_ target: StoredAnalysisDrillTarget, title: String, replace: Bool) {
        generation = UUID(); pending = .breakdown(target, title: title, replace: replace); loading = true; message = ""
        request?.cancel(); pump()
    }
    var visiblePurposeLocations: [StoredPurposeLocation] {
        let removed = Set(knownTrashes.values)
        return current?.purposeLocations?.locations.filter { !removed.contains($0.id) } ?? []
    }
    var hasConfirmedPurposeChanges: Bool { !knownTrashes.isEmpty }
    var selectedPurposeLocation: PurposeLocationSelection? {
        guard let resultID, let current, let id = selectedPurposeLocationID,
              let location = visiblePurposeLocations.first(where: { $0.id == id }) else { return nil }
        return .init(resultID: resultID, levelID: current.id, location: location)
    }
    func selectPurposeLocation(_ id: UInt64) {
        guard !loading, !locationActionRunning, visiblePurposeLocations.contains(where: { $0.id == id }) else { return }
        selectedPurposeLocationID = id; locationMessage = ""
    }
    func canActOnPurposeLocation(_ selection: PurposeLocationSelection, action: StoredLocationAction) -> Bool {
        guard action.availableInCurrentBuild, !loading, !locationActionRunning,
              liveLocationResult?.supportsStoredLocations == true, onLocationAction != nil,
              selection.resultID == resultID, selection.levelID == current?.id, selectedPurposeLocationID == selection.location.id,
              let row = visiblePurposeLocations.first(where: { $0.id == selection.location.id }) else { return false }
        return action != .reviewTrash || row.matchesWholeRecordedLocation && !row.isSourceRoot && knownTrashes.count < 1024
    }
    func actOnPurposeLocation(_ selection: PurposeLocationSelection, action: StoredLocationAction) {
        guard canActOnPurposeLocation(selection, action: action), let result = liveLocationResult else { return }
        let token = UUID(); locationActionID = token; locationActionRunning = true; locationMessage = "Checking the recorded location…"
        onLocationAction?(result, selection.location.id, action) { [weak self] message in
            guard let self, self.locationActionID == token else { return }
            self.locationActionID = nil; self.locationActionRunning = false; self.locationMessage = message
        }
    }
    private func cancelLocationAction() {
        if locationActionRunning, let resultID { onCancelLocationAction?(resultID) }
        locationActionID = nil; locationActionRunning = false; locationMessage = ""
    }
    func recordTrash(node: UInt64, recordID: UUID) {
        if knownTrashes.count < 1024 { knownTrashes[recordID] = node }
        if selectedPurposeLocationID == node { selectedPurposeLocationID = nil }
    }
    func recordUndo(recordID: UUID) { knownTrashes.removeValue(forKey: recordID) }
    private func pump() {
        guard request == nil, let pending else { return }
        self.pending = nil
        guard let result else {
            loading = false; canBrowse = false; message = "The stored result is no longer available. Analyze Again to refresh it."; return
        }
        let token = generation, metric = metric
        request = Task { [weak self] in
            do {
                try Task.checkCancellation()
                switch pending {
                case .purpose(let target, let title, let replace):
                    let level: Level
                    switch target {
                    case .projects(let role): level = try await .init(projects: result.purposeProjects(role, metric: metric), title: title)
                    case .locations(let role, let project): level = try await .init(locations: result.purposeLocations(role: role, project: project, metric: metric), title: title)
                    }
                    if let self, self.generation == token, !Task.isCancelled {
                        if replace, !self.levels.isEmpty { self.levels.removeLast() }
                        self.levels.append(level); self.loading = false
                    }
                case .composition(let target, let title, let replace):
                    let value = try await result.projectComposition(target, metric: metric)
                    if let self, self.generation == token, !Task.isCancelled {
                        if replace, !self.levels.isEmpty { self.levels.removeLast() }
                        self.levels.append(.init(target: target, title: title, value: value.overview, composition: value))
                        self.loading = false
                    }
                case .applicationLayouts:
                    let value = try await result.groups(.applicationLayouts)
                    if let self, self.generation == token, !Task.isCancelled {
                        self.applicationLayouts = value; self.loading = false
                    }
                case .breakdown(let target, let title, let replace):
                    let value = try await result.breakdown(target, metric: metric)
                    if let self, self.generation == token, !Task.isCancelled {
                        if target == .folder(0) { self.folderRoots[metric] = value }
                        let explanation = replace && self.current?.target == target ? self.current?.otherExplanation : nil
                        if replace, !self.levels.isEmpty { self.levels.removeLast() }
                        self.levels.append(.init(target: target, title: title, value: value, otherExplanation: explanation)); self.loading = false
                    }
                case .explainOther(let folder, let level):
                    let explanation = try await result.explainOther(folder: folder)
                    if let self, self.generation == token, !Task.isCancelled, self.current?.id == level,
                       self.current?.value.value == explanation.value {
                        self.levels[self.levels.count - 1].otherExplanation = explanation; self.loading = false
                    } else if let self, self.generation == token, !Task.isCancelled {
                        self.loading = false; self.message = "The explanation no longer matches this chart. Select Other again."
                    }
                }
            } catch {
                if let self, self.generation == token, !Task.isCancelled {
                    self.loading = false
                    self.message = (error as? StorageScanFailure) == .busy ? "Storage details are busy. Select this section again." : "This breakdown is unavailable. Analyze Again to refresh it."
                }
            }
            guard let self else { return }; self.request = nil; self.pump()
        }
    }
}
