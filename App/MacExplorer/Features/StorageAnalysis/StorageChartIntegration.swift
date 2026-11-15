import AppKit
import Combine
import StorageAnalysis
import SwiftUI

/// Loaded-data projection for the ordinary native chart. Appearance binding is
/// app-local; neither style changes nor rendering acquire a scan/query owner.
@MainActor
enum StorageChartIntegration {
    #if DEBUG
    static var startAtStorageRolesForQualification = false
    static var startAtFileTypesForQualification = false
    static let groupSelectionForQualification = PassthroughSubject<(UUID, String), Never>()
    #endif
    static let appearance = StorageChartAppearance()
    static func configure(settings: BrowserSettings) { appearance.bind(settings) }
    static func key(_ target: StoredAnalysisDrillTarget) -> String {
        switch target {
        case .folder(let id): "folder-\(id)"
        case .steamLibraries: "steam"
        case .filtered(let folder, let facet, let key): "filtered-\(folder)-\(facet.rawValue)-\(key)"
        }
    }
    static func key(_ target: StoredPurposeJourneyTarget) -> String {
        switch target {
        case .projects(let role): "purpose-\(role.rawValue)-projects"
        case .locations(let role, let project): "purpose-\(role.rawValue)-project-\(project)"
        }
    }
    static func bounded(_ frame: StorageChartFrame) -> StorageChartFrame {
        guard frame.slices.count > 15 else { return frame }
        var frame = frame, amount: UInt64? = 0
        for slice in frame.slices.dropFirst(14) {
            guard let current = amount, let bytes = slice.bytes else { amount = nil; continue }
            let (sum, overflow) = current.addingReportingOverflow(bytes); amount = overflow ? nil : sum
        }
        frame.slices = Array(frame.slices.prefix(14)) + [.init(id: "remaining", title: "Remaining observed groups",
            amount: amount.map { "\($0.formatted()) observed bytes" } ?? "Combined size unavailable", bytes: amount,
            canOpen: false, tint: .init(red: 0.5, green: 0.5, blue: 0.5))]
        return frame
    }
    static func colored(_ frames: [StorageChartFrame]) -> [StorageChartFrame] {
        var result: [StorageChartFrame] = []
        for input in frames {
            let inherited = result.last?.slices.first { $0.id == input.id }?.tint
            result.append(StorageChartPalette.color(bounded(input), inheriting: inherited, previous: result))
        }
        return result
    }
}

@MainActor enum StoragePurposeJourneyFeature {
    static let enabled = true
    #if DEBUG
    static var qualifying = false
    static var isEnabled: Bool { enabled || qualifying }
    #else
    static var isEnabled: Bool { enabled }
    #endif
}

@MainActor
final class StorageChartAppearance: ObservableObject {
    @Published private(set) var style = StorageChartStyle.tilted
    @Published private(set) var motion = BrowserMotionPreferences()
    private weak var settings: BrowserSettings?
    private var subscription: AnyCancellable?
    func bind(_ settings: BrowserSettings) {
        guard self.settings !== settings else { return }
        subscription?.cancel(); self.settings = settings; style = settings.analysisChartStyle; motion = settings.motion
        subscription = Publishers.CombineLatest(settings.$analysisChartStyle, settings.$motion).dropFirst().sink { [weak self] style, motion in
            if self?.style != style { self?.style = style }
            if self?.motion != motion { self?.motion = motion }
        }
    }
    func choose(_ value: StorageChartStyle) {
        if let settings { if settings.analysisChartStyle != value { settings.analysisChartStyle = value } }
        else if style != value { style = value }
    }
}
