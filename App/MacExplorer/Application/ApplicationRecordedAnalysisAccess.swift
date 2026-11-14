import Foundation
@_spi(ApplicationOwnership) import StorageAnalysis

/// App-only access adapter. A recorded root selects no permission by itself.
/// Explicit requests carry their originating controller across actor hops.
struct ApplicationRecordedAnalysisAccess: RecordedAnalysisAccessProvider {
    func acquireSingle(recordedRoot: URL) async throws -> RecordedSingleRootAccess {
        guard let context = RecordedAnalysisRequestAccess.current else {
            throw StorageScanFailure.accessDenied
        }
        return try await context.single(recordedRoot)
    }

    func acquireStartup() async throws -> RecordedStartupRootAccess {
        guard let context = RecordedAnalysisRequestAccess.current else {
            throw StorageScanFailure.accessDenied
        }
        return try await context.startup()
    }

    @MainActor
    static func withFolder<T: Sendable>(_ root: URL, using controller: FolderAccessController,
        operation: @MainActor @Sendable () async throws -> T) async rethrows -> T {
        let context = RecordedAnalysisAccessContext(folder: root, controller: controller)
        defer { context.close() }
        return try await RecordedAnalysisRequestAccess.$current.withValue(context) {
            try await operation()
        }
    }

    @MainActor
    static func withStartup<T: Sendable>(using controller: FolderAccessController,
        discovery: StartupVolumeDiscovery,
        operation: @MainActor @Sendable () async throws -> T) async rethrows -> T {
        let context = RecordedAnalysisAccessContext(startup: discovery, controller: controller)
        defer { context.close() }
        return try await RecordedAnalysisRequestAccess.$current.withValue(context) {
            try await operation()
        }
    }
}

private enum RecordedAnalysisRequestAccess {
    @TaskLocal static var current: RecordedAnalysisAccessContext?
}

/// Leases own their native scope lifetimes; lexical roots and matching fences
/// are not substitutes for the backend's native identity/readability checks.
private struct RecordedAnalysisAccessLifetime: Sendable {
    let preparation: FolderAccessPreparation
    let leases: [FolderAccessLease]
}

@MainActor
private final class RecordedAnalysisAccessContext {
    private enum Scope {
        case folder(URL)
        case startup(StartupVolumeDiscovery)
    }
    private let scope: Scope
    private var controller: FolderAccessController?
    private let requiresSelection: Bool
    private var isOpen = true

    init(folder: URL, controller: FolderAccessController) {
        scope = .folder(folder); self.controller = controller
        requiresSelection = FolderAccessController.requiresAnalysisSelection
    }

    init(startup: StartupVolumeDiscovery, controller: FolderAccessController) {
        scope = .startup(startup); self.controller = controller
        requiresSelection = FolderAccessController.requiresAnalysisSelection
    }

    func close() {
        isOpen = false
        controller = nil
    }

    func single(_ requested: URL) async throws -> RecordedSingleRootAccess {
        try Task.checkCancellation()
        guard isOpen else { throw StorageScanFailure.changed }
        guard case .folder(let selected) = scope, requested.isFileURL, selected.isFileURL,
              selected.standardizedFileURL.path.utf8.elementsEqual(requested.standardizedFileURL.path.utf8) else {
            throw StorageScanFailure.accessDenied
        }
        let lifetime = try await acquire([requested])
        // A Home/drive grant can cover this root. Keep the actual recorded
        // root here; lease.url may be its ancestor and is never substituted.
        return .init(root: requested, retainingAccess: lifetime)
    }

    func startup() async throws -> RecordedStartupRootAccess {
        try Task.checkCancellation()
        guard isOpen else { throw StorageScanFailure.changed }
        guard case .startup(let discovery) = scope else { throw StorageScanFailure.accessDenied }
        let plan = try await discovery.discover()
        try Task.checkCancellation()
        guard isOpen else { throw StorageScanFailure.changed }
        let lifetime = try await acquire([plan.dataRoot, plan.systemRoot])
        return .init(plan: plan, retainingAccess: lifetime)
    }

    private func acquire(_ roots: [URL]) async throws -> RecordedAnalysisAccessLifetime {
        try Task.checkCancellation()
        guard isOpen, let controller else { throw StorageScanFailure.changed }
        let preparation = controller.prepareAccess(to: roots)
        let identities = roots.map { controller.analysisReuseIdentity(for: $0, requiringSelection: requiresSelection) }
        guard identities.allSatisfy({ $0 != nil }) else { throw StorageScanFailure.accessDenied }
        var leases: [FolderAccessLease] = []
        for root in roots {
            let lease = await controller.acquireAccess(to: root)
            try Task.checkCancellation()
            guard isOpen, controller.isCurrent(preparation),
                  roots.enumerated().allSatisfy({ index, root in
                      controller.analysisReuseIdentity(for: root, requiringSelection: requiresSelection) == identities[index]
                  }) else { throw StorageScanFailure.changed }
            if let lease { leases.append(lease) }
            else if requiresSelection { throw StorageScanFailure.accessDenied }
        }
        return .init(preparation: preparation, leases: leases)
    }
}
