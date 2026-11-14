#if DEBUG
import AppKit
import ExplorerCore

@MainActor
enum BehaviorPinsVerification {
    static func run(in testRoot: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw UIVerification.Failure(message: "Pin verification requires its explicit unredirected fixture root.")
        }
        var checks: [String] = []
        for preset in ["Explorer", "Mac"] {
            let old = Data("{\"version\":7,\"keyboardProfile\":\"\(preset)\"}".utf8)
            let settings = BrowserSettings(persist: false, restoredData: old)
            try require(settings.keyboardProfile.rawValue == preset, "Existing keyboard profile failed migration")
            try require(settings.behavior == (preset == "Explorer" ? .explorer : .mac), "Existing effective behavior changed")
            settings.customizeBehavior()
            try require(settings.keyboardProfile == .custom && settings.customBehavior == settings.behavior,
                        "Customize did not retain the effective preset")
            settings.customBehavior.returnAction = .open
            settings.customBehavior.backspaceGoesBack = false
            settings.customBehavior.controlAliasesEnabled = true
            settings.customBehavior.explorerFunctionKeysEnabled = false
            let restored = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
            try require(restored.keyboardProfile == .custom && restored.behavior == settings.behavior, "Custom choices did not round trip")
            let document = try JSONSerialization.jsonObject(with: settings.encodedSnapshot()) as? [String: Any]
            try require(document?["version"] as? Int == BrowserSettings.preferencesVersion,
                        "Settings migration failed to write current version")
        }
        for invalid in ["{\"version\":999}", "{\"version\":8,\"keyboardProfile\":\"Unknown\"}", "corrupt"] {
            let settings = BrowserSettings(persist: false, restoredData: Data(invalid.utf8))
            try require(settings.behavior == .explorer && !settings.preferencesPersistenceStatus.isEmpty,
                        "Invalid/future preferences did not fail safely")
        }
        checks.append("Explorer/Mac preferences migrate to the current format; independent Custom choices round trip and future/corrupt preferences fail safely")

        let owned = testRoot.appendingPathComponent("behavior-pins-\(UUID().uuidString)", isDirectory: true)
        let state = owned.appendingPathComponent("state", isDirectory: true)
        let sentinel = state.appendingPathComponent("folder-access-bookmarks-v1.json")
        let missing = owned.appendingPathComponent("uncreated-target", isDirectory: true)
        try await Task.detached {
            try FileManager().createDirectory(at: state, withIntermediateDirectories: true)
            try Data("mac-explorer-behavior-pins-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            try Data("unrelated-bookmark-sentinel".utf8).write(to: sentinel, options: .withoutOverwriting)
        }.value
        let controller = BrowserPinsController(stateDirectory: state)
        await controller.restoreIfNeeded()
        try require(controller.canEdit, "Empty pin store was not editable")
        controller.edit { _ = try $0.add(url: missing, label: "Missing Café") }
        guard let id = controller.collection.pins.first?.id else { throw UIVerification.Failure(message: "Add pin failed") }
        for index in 0..<25 { controller.edit { try $0.relabel(id: id, label: "Label \(index)") } }
        controller.edit { try $0.relabel(id: id, label: "Latest label") }
        try require(await controller.flush() == nil, "Pin FIFO persistence failed")
        let fresh = BrowserPinsController(stateDirectory: state)
        await fresh.restoreIfNeeded()
        try require(fresh.collection == controller.collection, "Fresh pin restore lost the latest label")
        let noAccessSideEffects = try await Task.detached {
            let file = state.appendingPathComponent("browser-pins-v1.json")
            let mode = (try FileManager().attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
            let sentinelData = try Data(contentsOf: sentinel)
            return mode == 0o600 && !FileManager().fileExists(atPath: missing.path)
                && sentinelData == Data("unrelated-bookmark-sentinel".utf8)
        }.value
        try require(noAccessSideEffects, "Pinning changed target/bookmark state or produced a nonprivate store")
        try require(fresh.availability.isEmpty, "Restoring pins fabricated successful access")
        fresh.recordNavigation(to: missing, successful: false)
        try require(fresh.availability[id] == .unavailable, "Explicit failed navigation did not retain unavailable state")
        fresh.recordNavigation(to: missing, successful: true)
        try require(fresh.availability[id] == .opened, "Explicit navigation retry did not update pin state")
        checks.append("Private bounded pin store restores latest FIFO edits separately from access grants; explicit navigation alone updates availability")

        let settings = BrowserSettings(persist: false)
        let first = BrowserViewController(settings: settings)
        let second = BrowserViewController(settings: settings)
        first.pinsController = fresh
        second.pinsController = fresh
        _ = first.view
        _ = second.view
        first.rebuildSidebar()
        second.rebuildSidebar()
        guard let firstGroup = first.sidebarRoots.first(where: { $0.title == "Pinned Folders" }),
              let secondGroup = second.sidebarRoots.first(where: { $0.title == "Pinned Folders" }),
              let firstPin = firstGroup.children?.first, let secondPin = secondGroup.children?.first else {
            throw UIVerification.Failure(message: "Shared pin did not appear in both sidebars")
        }
        try require(first.pinnedSidebar.id(for: firstPin) == id && second.pinnedSidebar.id(for: secondPin) == id,
                    "Shared pane pin mapping lost record identity")
        try require(firstPin.children?.isEmpty == true && secondPin.children?.isEmpty == true && !firstPin.loading && !secondPin.loading,
                    "Rendering pins started target enumeration")
        fresh.edit { try $0.remove(id: id) }
        _ = await fresh.flush()
        first.rebuildSidebar()
        second.rebuildSidebar()
        try require(!first.sidebarRoots.contains(where: { $0.title == "Pinned Folders" })
                    && !second.sidebarRoots.contains(where: { $0.title == "Pinned Folders" }), "Shared Remove failed to update both sidebars")
        first.suspendBrowser()
        second.suspendBrowser()
        checks.append("Two native file browsers share one pin controller; display maps stable record IDs without enumeration and Remove updates both")

        let file = state.appendingPathComponent("browser-pins-v1.json")
        let future = Data("{\"version\":999,\"pins\":[]}".utf8)
        try await Task.detached { try future.write(to: file, options: .atomic) }.value
        let refused = BrowserPinsController(stateDirectory: state)
        await refused.restoreIfNeeded()
        refused.edit { _ = try $0.add(url: missing, label: "Do not overwrite") }
        _ = await refused.flush()
        try require(!refused.canEdit && !refused.status.isEmpty, "Future pin state was not protected")
        try require(try await Task.detached { try Data(contentsOf: file) == future }.value, "Future pin data was overwritten")

        let redirectedState = owned.appendingPathComponent("redirected-state", isDirectory: true)
        try await Task.detached {
            try FileManager().createDirectory(at: redirectedState, withIntermediateDirectories: false)
            try FileManager().createSymbolicLink(at: redirectedState.appendingPathComponent("browser-pins-v1.json"), withDestinationURL: sentinel)
        }.value
        let redirected = BrowserPinsController(stateDirectory: redirectedState)
        await redirected.restoreIfNeeded()
        try require(!redirected.canEdit, "Redirected pin file was accepted")
        try require(try await Task.detached { try Data(contentsOf: sentinel) == Data("unrelated-bookmark-sentinel".utf8) }.value,
                    "Redirected pin state affected unrelated file")
        checks.append("Future/corrupt or symlink-redirected pin storage is preserved and disables persistent edits without touching unrelated records")
        return checks
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UIVerification.Failure(message: message) }
    }
}
#endif
