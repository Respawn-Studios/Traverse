import AppKit
import ExplorerCore
import Foundation
import LocalStorage

/// One process owner; presentations cannot own/cancel submitted system work.
@MainActor final class ApplicationFolderDefaults {
    static let shared = makeShared()
    let coordinator: FolderDefaultCoordinator?
    private let store: ApplicationFolderDefaultStore?
    private let presentations = NSHashTable<FolderDefaultSettingsPresentation>.weakObjects()
    private var terminationID: UUID?, drainedTerminationID: UUID?
    var isTerminating: Bool { terminationID != nil }
    var isVisible: Bool { coordinator != nil }
    var needsTerminationDrain: Bool { coordinator != nil && terminationID != nil && drainedTerminationID != terminationID }
    private init(coordinator: FolderDefaultCoordinator?, store: ApplicationFolderDefaultStore?) {
        self.coordinator = coordinator; self.store = store
    }
    private static func makeShared() -> ApplicationFolderDefaults {
        let info = Bundle.main.infoDictionary ?? [:]
        let preview: Bool
        #if !MAC_EXPLORER_DISTRIBUTION
        preview = Bundle.main.bundleIdentifier == DevelopmentReviewProfile.identifier
            && info["MacExplorerDistributionChannel"] as? String == DevelopmentReviewProfile.channel
            && FolderDefaultIdentityPolicy.hasPreviewFolderDeclaration(info)
        #else
        preview = false
        #endif
        // The beta exposes the same folder-opening status and Service guidance.
        // Only the already-reviewed Preview can submit a native Make/Restore.
        let beta = Bundle.main.bundleIdentifier == FolderDefaultFeature.shippingBundleIdentifier
            && AppFeatureAvailability.policy.edition.isDeveloperID
            && FolderDefaultIdentityPolicy.hasFolderDeclaration(info)
        guard preview || beta,
              let root = AppStorageLocations.stateDirectory, let leaf = AppStorageLocations.folderDefaultRestoreDirectory,
              AppStorageLocations.layout != nil else { return .init(coordinator: nil, store: nil) }
        do {
            let activity = ApplicationFileActivity.gate
            let parent = try AppStoragePreparation.owner(for: root)
            let child = try PrivateStateDirectorySequence(directories: [leaf], activity: activity)
            let native = NativeFolderDefaultRecoveryStore(directory: leaf, preparation: child, activity: activity)
            let store = ApplicationFolderDefaultStore(root: parent, native: native)
            let owner = FolderDefaultCoordinator(system: NativeFolderDefaultSystem(activity: activity), store: store,
                activity: activity, permitsChanges: preview && FolderDefaultIdentityPolicy.permitsPreviewBuild)
            return .init(coordinator: owner, store: store)
        } catch { return .init(coordinator: nil, store: nil) }
    }
    func makePresentation(initialGeneral: Bool) -> FolderDefaultSettingsPresentation {
        let value = FolderDefaultSettingsPresentation(owner: self, initialGeneral: initialGeneral)
        presentations.add(value); return value
    }
    func settingsWindowWillHide(_ window: NSWindow) {
        for value in presentations.allObjects { value.windowWillHide(window) }
    }
    func settingsWindowDidShow(_ window: NSWindow) {
        for value in presentations.allObjects { value.windowDidShow(window) }
    }
    func beginTermination() {
        guard terminationID == nil else { return }
        terminationID = UUID(); drainedTerminationID = nil
        // Synchronous MainActor revocation precedes any async quit work.
        for value in presentations.allObjects { value.suspendForTermination() }
    }
    func prepareForTermination() async -> Bool {
        beginTermination()
        if let coordinator { await coordinator.stopAndDrain() }
        // This fixed owner has physically joined ALL its work. A still-desired
        // newer Quit can share that drain; a cancelled Quit has no current ID.
        guard let current = terminationID else { return false }
        drainedTerminationID = current; return true
    }
    func resumeAfterCancelledTermination() {
        terminationID = nil; drainedTerminationID = nil
        coordinator?.resumeAfterCancelledTermination()
        for value in presentations.allObjects { value.resumeAfterCancelledTermination() }
    }
    #if DEBUG
    static func forQualification(system: any FolderDefaultSystem, stateDirectory: URL,
                                 rootPreparation: PrivateStateDirectorySequence, activity: FileActivityGate,
                                 permitsChanges: Bool = true) throws -> ApplicationFolderDefaults {
        let leaf = stateDirectory.appendingPathComponent("folder-opening", isDirectory: true)
        let child = try PrivateStateDirectorySequence(directories: [leaf], activity: activity)
        let native = NativeFolderDefaultRecoveryStore(directory: leaf, preparation: child, activity: activity)
        let store = ApplicationFolderDefaultStore(root: rootPreparation, native: native)
        return .init(coordinator: FolderDefaultCoordinator(system: system, store: store, activity: activity,
            permitsChanges: permitsChanges), store: store)
    }
    var storeForQualification: (any FolderDefaultRecoveryStore)? { store }
    var presentationCountForQualification: Int { presentations.allObjects.filter(\.isActive).count }
    #endif
}

/// Keeps the actual shared root pins. The private leaf owns its own bounded
/// sequence; passive reads never invoke either preparation/create path.
private final class ApplicationFolderDefaultStore: FolderDefaultRecoveryStore, @unchecked Sendable {
    private let root: PrivateStateDirectorySequence, native: NativeFolderDefaultRecoveryStore
    init(root: PrivateStateDirectorySequence, native: NativeFolderDefaultRecoveryStore) { self.root = root; self.native = native }
    func load() async throws -> FolderDefaultRecoveryRecord? { try await native.load() }
    func replace(expected: FolderDefaultRecoveryRecord?, with next: FolderDefaultRecoveryRecord) async throws {
        try await root.prepare()
        try await native.replace(expected: expected, with: next)
    }
}
