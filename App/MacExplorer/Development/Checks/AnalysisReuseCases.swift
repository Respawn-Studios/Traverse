#if DEBUG
import AppKit
import ExplorerCore
import StorageAnalysis

@MainActor extension AnalysisReuseVerification {
    static func perform(_ a: AnalysisReuseFixtureAuthority, host: AnalysisReuseNativeBrowser?, entry: FileEntry?) async throws -> [String] {
        switch a.selected {
        case .retention:
            return try await SessionAnalysisReuseControls.retention(roots: Array(a.roots.prefix(3)), storage: a.storage, worker: a.worker)
        case .application:
            return try await SessionAnalysisReuseControls.application(root: a.roots[0], worker: a.worker, storage: a.storage)
        case .scope:
            guard let host else { throw UIVerification.Failure(message: "reuse-native-host-required") }
            return try await AnalysisReuseScopeControls.run(a, host: host)
        case .replacedRoot:
            return try await SessionAnalysisReuseControls.replacedRoot(root: a.roots[0], backup: a.fixture.appendingPathComponent("Replaced-Root-0"), storage: a.storage, worker: a.worker)
        case .clearAdmission, .negativeClear:
            guard let host, let entry else { throw UIVerification.Failure(message: "reuse-native-hover-row-required") }
            return try await SessionAnalysisReuseRegressionControls.clearAdmission(browser: host.browser, entry: entry, storage: a.storage, worker: a.worker)
        case .successfulProjection:
            var checks = try await SessionAnalysisReuseRegressionControls.heldProjection(root: a.roots[0], storage: a.storage, worker: a.worker,
                failRead: false, cancel: false, propertiesHandoff: false)
            // A second actual scan epoch refuses optional caching; it must still
            // own the displayed chart. Same bounded fixture and drained pool.
            checks += try await SessionAnalysisReuseRegressionControls.cacheDisabledFallback(root: a.roots[0], extraRoot: a.roots[1],
                storage: a.storage, worker: a.worker, refuseAtEightGiB: true)
            return checks
        case .failedProjection:
            return try await SessionAnalysisReuseRegressionControls.heldProjection(root: a.roots[0], storage: a.storage, worker: a.worker,
                failRead: true, cancel: false, propertiesHandoff: true)
        case .stoppedProjection:
            return try await SessionAnalysisReuseRegressionControls.heldProjection(root: a.roots[0], storage: a.storage, worker: a.worker,
                failRead: false, cancel: true, propertiesHandoff: true)
        case .fallbackFour, .negativeFallback:
            return try await SessionAnalysisReuseRegressionControls.cacheDisabledFallback(root: a.roots[0], extraRoot: a.roots[1], storage: a.storage, worker: a.worker)
        case .failedProjectionFour:
            var checks = try await SessionAnalysisReuseRegressionControls.heldProjection(root: a.roots[0], storage: a.storage, worker: a.worker,
                failRead: true, cancel: false, propertiesHandoff: false)
            checks += try await SessionAnalysisReuseRegressionControls.heldProjection(root: a.roots[0], storage: a.storage, worker: a.worker,
                failRead: false, cancel: true, propertiesHandoff: false)
            return checks
        case .saturationSix:
            return try await SessionAnalysisReuseRegressionControls.poolBoundary(roots: Array(a.roots.prefix(4)), storage: a.storage, worker: a.worker)
        case .saturationEight:
            return try await SessionAnalysisReuseRegressionControls.poolBoundary(roots: a.roots, storage: a.storage, worker: a.worker)
        case .negativeDate:
            return try await SessionAnalysisReuseRegressionControls.heldProjection(root: a.roots[0], storage: a.storage, worker: a.worker,
                failRead: false, cancel: false, propertiesHandoff: false)
        case .negativeHandoff:
            return try await SessionAnalysisReuseRegressionControls.heldProjection(root: a.roots[0], storage: a.storage, worker: a.worker,
                failRead: true, cancel: false, propertiesHandoff: true)
        }
    }
}
#endif
