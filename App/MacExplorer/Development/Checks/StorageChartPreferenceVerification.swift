#if DEBUG
import Foundation

@MainActor
enum StorageChartPreferenceVerification {
    struct Checked {
        let settings: BrowserSettings
        let file: URL
        let checks: [String]
    }
    static func run(evidence: URL) async throws -> Checked {
        let file = evidence.appendingPathComponent("chart-style-preferences-" + UUID().uuidString + ".json")
        let settings = BrowserSettings(persist: false, persistenceFile: file)
        try UIVerification.require(settings.analysisChartStyle == .tilted, "Fresh chart preference is not Tilted")
        settings.showsHiddenFiles = true
        for style in StorageChartStyle.allCases {
            settings.analysisChartStyle = style
            let copy = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
            try UIVerification.require(copy.analysisChartStyle == style && copy.showsHiddenFiles
                && !copy.analysisIncludesApplicationDataByDefault && !copy.groupedCopyPreview,
                "Chart style round-trip lost another preference or changed scan/operation defaults")
        }
        for version in [1, 14, 15] {
            let old = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: ["version": version]))
            try UIVerification.require(old.analysisChartStyle == .tilted && old.preferencesPersistenceStatus.isEmpty,
                "An older preference file lost its default chart style")
        }
        settings.analysisChartStyle = .orbitable
        await settings.drainPreferencesForVerification()
        let saved = try await Task.detached(priority: .utility) { try Data(contentsOf: file) }.value
        let reopened = BrowserSettings(persist: false, restoredData: saved)
        try UIVerification.require(reopened.analysisChartStyle == .orbitable && reopened.showsHiddenFiles,
            "Saved chart style did not survive actual file reopening")
        let invalid = evidence.appendingPathComponent("chart-style-invalid-" + UUID().uuidString + ".json")
        let invalidBytes = Data(#"{"version":15,"analysisChartStyle":"future-style","showsHiddenFiles":true}"#.utf8)
        try await Task.detached(priority: .utility) { try invalidBytes.write(to: invalid, options: .withoutOverwriting) }.value
        let refused = BrowserSettings(persist: false, persistenceFile: invalid)
        refused.analysisChartStyle = .flat; await refused.drainPreferencesForVerification()
        let retained = try await Task.detached(priority: .utility) { try Data(contentsOf: invalid) }.value
        try UIVerification.require(!refused.preferencesPersistenceStatus.isEmpty && retained == invalidBytes,
            "Unknown chart preference was overwritten")
        StorageChartIntegration.configure(settings: settings)
        let peer = BrowserSettings(persist: false); peer.analysisChartStyle = .flat
        StorageChartIntegration.configure(settings: peer)
        settings.analysisChartStyle = .tilted
        try UIVerification.require(StorageChartIntegration.appearance.style == .flat, "Superseded settings retained the appearance subscription")
        StorageChartIntegration.configure(settings: settings)
        StorageChartIntegration.appearance.choose(.orbitable)
        try UIVerification.require(settings.analysisChartStyle == .orbitable && StorageChartIntegration.appearance.style == .orbitable,
            "Menu-to-preference binding failed")
        settings.analysisChartStyle = .tilted; await settings.drainPreferencesForVerification()
        return .init(settings: settings, file: file, checks: ["Tilted default and legacy preferences", "three-style snapshot round-trip",
            "other settings/scope preserved", "actual saved-file reopen", "unknown preference preserved",
            "superseded subscription detached", "menu/settings two-way binding"])
    }
}
#endif
