import ExplorerCore
import Foundation

#if DEBUG
@testable import StorageAnalysis

/// Build separately from the generated test with -enable-testing. It prints
/// bounded metadata only; no source child or file-content reader is launched.
private struct ProbeAccess: RetainedFreshAccessProvider {
    let root: URL
    func acquire(for record: RetainedAnalysisRecord) async throws -> RetainedCurrentRootAccess {
        guard case .single(let saved) = record.scope,
              saved.locator == root.standardizedFileURL.path else { throw StorageScanFailure.accessDenied }
        return .single(root, UUID())
    }
}
@main struct RetainedColdProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let catalogID = UUID(uuidString: args[5]),
              args[1...4].allSatisfy({ $0.hasPrefix("/") && !$0.contains("..") }) else {
            throw StorageScanFailure.invalidOutput
        }
        let root = URL(fileURLWithPath: args[1]), pool = URL(fileURLWithPath: args[2])
        let state = URL(fileURLWithPath: args[3]), helper = URL(fileURLWithPath: args[4])
        let storage = try AnalysisResultStorage(directory: pool, sessionByteLimit: 2 << 30,
            poolByteLimit: 8 << 30, retentionStateDirectory: state)
        let backend = try RetainedNativeBackend(storage: storage, indexDirectory: state,
            workerURL: helper, activityGate: FileActivityGate(), accessProvider: ProbeAccess(root: root))
        let index = try await backend.loadCanonicalIndex()
        guard let record = index.visibleRecords.first(where: { $0.catalogID == catalogID }) else {
            throw StorageScanFailure.changed
        }
        let opened = await backend.openCatalog(record, expectedEpoch: index.epoch)
        if case .refused(.busy) = opened {
            let data = try JSONSerialization.data(withJSONObject: ["refusal": "busy"], options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            return
        }
        guard case .opened(let handle) = opened,
              let result = await backend.result(for: handle) else { throw StorageScanFailure.changed }
        let snapshot = try await RetainedNativeQualificationSnapshot.capture(result)
        let queryLaunches = result.queryWorkerLaunchCountForQualification
        guard case .closed(let closed) = await backend.closeRead(handle), closed == handle else {
            throw StorageScanFailure.changed
        }
        let output: [String: Any] = [
            "resultID": catalogID.uuidString,
            "snapshot": snapshot,
            "queryLaunches": queryLaunches,
            "traversalLaunches": ScannerWorkerProcess.qualificationTraversalLaunchCount
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
#else
/// This test companion has no authority in production builds. Running a
/// Release image fails explicitly instead of silently claiming a cold proof.
@main struct RetainedColdProbe {
    static func main() throws {
        throw NSError(domain: "Traverse.RetainedColdProbe", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Debug qualification only"])
    }
}
#endif
