#if DEBUG
import AppKit
import Foundation
import ExplorerCore
import LocalStorage
@_spi(ApplicationOwnership) import StorageAnalysis

/// Deterministic grant-publication backend only. Actual scanner/browser reads
/// still use real local descriptors. This qualifies no macOS security scope,
/// TCC/FDA state or signed selection prompt and persists no bookmark.
private struct AnalysisReuseGrantBackend: FolderAccessBackend {
    func startAccess(to url: URL) -> Bool { true }
    func stopAccess(to url: URL) {}
    func bookmark(for url: URL) throws -> Data { Data("generated-grant".utf8) }
    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { throw StorageScanFailure.unsupportedLocation }
}
@MainActor enum AnalysisReuseScopeControls {
    static func run(_ a: AnalysisReuseFixtureAuthority, host: AnalysisReuseNativeBrowser) async throws -> [String] {
        let owner = ApplicationStorageAnalysis.shared, backend = AnalysisReuseGrantBackend()
        let access = FolderAccessController(stateDirectory: nil, backend: backend)
        host.browser.folderAccess = access
        owner.configurePicker(from: host.browser)
        owner.enablePagedForQualification(storage: a.storage, workerURL: a.worker)
        owner.requiresAnalysisSelectionForVerification = true
        var held: [StorageAnalysisResult] = []
        do {
            let firstLease = FolderAccessLease(url: a.roots[0], backend: backend)
            try UIVerification.require(access.acceptOpenedFolder(a.roots[0], retaining: firstLease), "reuse-exact-grant-accept")
            try await scan(a, owner: owner)
            guard let first = owner.sessionSnapshotForVerification, let id = access.locations.first?.id else { throw StorageScanFailure.invalidOutput }
            held.append(first.result)
            owner.verificationBegin(root: a.roots[0]) { FileAccessLifetimes(leases: []) }
            try await UIVerification.waitUntil("reuse-grant-cache-hit") { !owner.hasWork && owner.sessionPresentationIsPreviousForVerification }
            let starts = owner.allScanStartsForSessionReuseVerification
            _ = await access.forget(id: id)
            try await UIVerification.waitUntil("reuse-forget-revokes-current-cache-and-ui-owner") {
                !owner.hasWork && owner.sessionReuseCountForVerification == 0 && owner.pagedResultForVerification == nil
            }
            let restoredAfterForget = owner.restoreProperties(owner: UUID(), root: a.roots[0], metadataPolicy: .standard,
                access: { FileAccessLifetimes(leases: []) }, onChange: { _, _ in })
            try UIVerification.require(!restoredAfterForget && owner.allScanStartsForSessionReuseVerification == starts,
                "reuse-forgotten-grant-has-no-cache-hit-or-automatic-scan")
            _ = try await first.result.summary() // Independent shared observation remains readable.
            let secondLease = FolderAccessLease(url: a.roots[0], backend: backend)
            try UIVerification.require(access.acceptOpenedFolder(a.roots[0], retaining: secondLease), "reuse-regrant-accept")
            try await scan(a, owner: owner)
            guard let second = owner.sessionSnapshotForVerification else { throw StorageScanFailure.invalidOutput }
            held.append(second.result)
            owner.verificationBegin(root: a.roots[0]) { FileAccessLifetimes(leases: []) }
            try await UIVerification.waitUntil("reuse-policy-cache-hit") { !owner.hasWork && owner.sessionPresentationIsPreviousForVerification }
            host.browser.settings.analysisIncludesApplicationDataByDefault = true
            try await UIVerification.waitUntil("reuse-real-preference-publication-invalidates-cache-and-ui") {
                !owner.hasWork && owner.sessionReuseCountForVerification == 0 && owner.pagedResultForVerification == nil
            }
            let restoredAfterPolicy = owner.restoreProperties(owner: UUID(), root: a.roots[0], metadataPolicy: .applicationData,
                access: { FileAccessLifetimes(leases: []) }, onChange: { _, _ in })
            try UIVerification.require(!restoredAfterPolicy && owner.allScanStartsForSessionReuseVerification == starts + 1,
                "reuse-changed-policy-cannot-reuse-or-start-automatic-scan")
        } catch {
            await owner.stopAndDrain(shuttingDown: true)
            for result in held { await result.closeAfterRevokingApplicationConsumersAndDrain() }
            await StorageAnalysisResult.waitForScheduledStoreDiscardsAndDrain()
            throw error
        }
        await owner.stopAndDrain(shuttingDown: true)
        for result in held { await result.closeAfterRevokingApplicationConsumersAndDrain() }
        await StorageAnalysisResult.waitForScheduledStoreDiscardsAndDrain()
        return ["Actual App Forget publication revokes exact grant/cache/UI ownership without automatic scan", "Actual Settings policy publication revokes cache and dated UI; broader policy never inherits it", "Independent shared observation still readable; macOS TCC/security scopes NOT EXERCISED"]
    }
    private static func scan(_ a: AnalysisReuseFixtureAuthority, owner: ApplicationStorageAnalysis) async throws {
        owner.verificationBegin(root: a.roots[0]) { FileAccessLifetimes(leases: []) }
        try await UIVerification.waitUntil("reuse-scope-real-scan") { !owner.hasWork && owner.sessionSnapshotForVerification != nil }
        try UIVerification.require(owner.sessionReuseCountForVerification == 1, "reuse-scope-actual-sealed-cache-required")
    }
}
#endif
