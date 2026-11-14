#if DEBUG
import AppKit
import Foundation
import StorageAnalysis

@MainActor
enum StorageScopePreferenceVerification {
    private struct GeneratedReader: FilePropertiesReading {
        func read(_ urls: [URL]) async throws -> FilePropertiesReport {
            .init(selectedCount: urls.count, observations: urls.prefix(1).enumerated().map { index, root in
                .init(id: index, url: root, kind: "Folder", byteCount: nil, createdAt: nil, modifiedAt: nil, accessedAt: nil,
                    mode: 0o700, ownerID: nil, groupID: nil, isSymbolicLink: false, isDirectory: true,
                    isImmutable: false, isVolumeReadOnly: false, failure: nil)
            })
        }
    }
    static func run() async throws -> [String] {
        let root = URL(fileURLWithPath: "/generated/AnalysisChoice", isDirectory: true)
        let child = root.appendingPathComponent("Child"), peer = URL(fileURLWithPath: "/generated/Peer")
        let settings = BrowserSettings(persist: false)
        try UIVerification.require(settings.analysisRefreshesChangedFolders, "Changed-folder refresh is not the default")
        settings.analysisRefreshesChangedFolders = false
        try UIVerification.require(settings.analysisPolicy(for: root) == .standard && !settings.hasAnalysisChoice(for: root), "Analysis defaults broadened")
        settings.rememberAnalysisPolicy(.applicationData, for: root, remember: true)
        try UIVerification.require(settings.analysisPolicy(for: root) == .applicationData && settings.analysisPolicy(for: child) == .standard && settings.analysisPolicy(for: peer) == .standard, "Remembered analysis scope inherited into another location")
        let captured = settings.analysisPolicy(for: root)
        settings.analysisIncludesApplicationDataByDefault = true
        settings.rememberAnalysisPolicy(.standard, for: peer, remember: true)
        let restored = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
        try UIVerification.require(!restored.analysisRefreshesChangedFolders, "Full-scan refresh preference did not round-trip")
        try UIVerification.require(restored.analysisPolicy(for: root) == .applicationData && restored.analysisPolicy(for: peer) == .standard
            && restored.analysisPolicy(for: child) == .applicationData, "Default/override round-trip changed scope")
        restored.clearAnalysisLocationChoices(); restored.analysisIncludesApplicationDataByDefault = false
        try UIVerification.require(restored.analysisPolicy(for: root) == .standard && captured == .applicationData, "Clearing locations changed a captured request or retained consent")
        settings.rememberAnalysisPolicy(.applicationData, for: root, remember: false)
        try UIVerification.require(!settings.hasAnalysisChoice(for: root) && settings.analysisPolicy(for: URL(string: "https://example.test/")!) == .standard, "Removed/invalid location acquired broader scope")
        let legacy = BrowserSettings(persist: false, restoredData: Data(#"{"version":14}"#.utf8))
        try UIVerification.require(legacy.analysisRefreshesChangedFolders, "Older preferences did not receive the refresh default")
        try UIVerification.require(legacy.analysisPolicy(for: root) == .standard && legacy.analysisLocationChoices.isEmpty, "Older preferences gained consent")
        let invalid = BrowserSettings(persist: false, restoredData: Data(#"{"version":15,"analysisIncludesApplicationDataByDefault":true,"analysisLocationChoices":{"/generated/../private":true}}"#.utf8))
        try UIVerification.require(!invalid.preferencesPersistenceStatus.isEmpty && invalid.analysisPolicy(for: root) == .standard, "Invalid saved scope failed open")
        let bounded = BrowserSettings(persist: false)
        for index in 0..<65 { bounded.rememberAnalysisPolicy(.applicationData, for: root.appendingPathComponent(String(index)), remember: true) }
        try UIVerification.require(bounded.analysisLocationChoices.count == 64 && !bounded.hasAnalysisChoice(for: root.appendingPathComponent("64")), "Analysis location bound silently evicted consent")
        let live = BrowserSettings(persist: false)
        live.rememberAnalysisPolicy(.applicationData, for: root, remember: true)
        let model = FilePropertiesModel(reader: GeneratedReader(), settings: live, copyPaths: { _ in })
        model.update(urls: [root]); try await Task.sleep(for: .milliseconds(20))
        try UIVerification.require(model.includeApplicationData && model.rememberAnalysisScope, "Properties ignored the saved location")
        let capturedPolicy = live.analysisPolicy(for: root)
        live.clearAnalysisLocationChoices(); try await Task.sleep(for: .milliseconds(20))
        try UIVerification.require(!model.includeApplicationData && !model.rememberAnalysisScope && capturedPolicy == .applicationData,
            "Clear left stale broader controls or changed captured scope")
        live.analysisIncludesApplicationDataByDefault = true; try await Task.sleep(for: .milliseconds(20))
        try UIVerification.require(model.includeApplicationData && !model.rememberAnalysisScope, "Open Properties ignored the new explicit-scan default")
        model.cancel()
        let tool = StorageAnalysisWindowController(onChooseFolder: {}, onRefresh: {}, onStop: {}, onAppStorage: {})
        defer { tool.close() }
        tool.setRequestPolicy(.standard, available: true)
        tool.configureNextScope(.applicationData, remember: true, canRemember: true)
        try UIVerification.require(tool.metadataPolicyLabel.stringValue.contains(AnalysisMetadataPolicy.standard.title)
            && tool.takeNextMetadataPolicy() == .applicationData, "Next preference relabeled the current observation")
        tool.includeApplicationDataButton.state = .off
        try UIVerification.require(tool.takeNextMetadataPolicy() == .standard, "One-request override was ignored")
        tool.setRequestPolicy(.standard, available: false)
        tool.configureNextScope(.applicationData, remember: true, canRemember: true)
        try UIVerification.require(tool.takeNextMetadataPolicy() == .standard && !tool.rememberApplicationDataButton.isEnabled, "App Storage inherited broader policy")
        return ["analysis default/explicit override", "exact-location scope/clear", "analysis preference round-trip and legacy consent", "invalid/bounded preference refusal", "live default/clear controls without changing captured scope", "native next-scope/current-result separation"]
    }
}
#endif
