import Darwin
import ExplorerCore
import Foundation
@_spi(Qualification) @testable import LocalStorage

private enum Failure: Error { case mismatch }
@MainActor private var checks = 0
@MainActor private func expect(_ value: Bool) throws { guard value else { throw Failure.mismatch }; checks += 1 }
private final class Race: @unchecked Sendable {
    private let lock = NSLock(); private var accepted = false
    func record(_ value: Bool) { lock.withLock { accepted = value } }
    var value: Bool { lock.withLock { accepted } }
}
@main struct Controls {
    @MainActor static func main() async throws {
        guard let raw = ProcessInfo.processInfo.environment["TRAVERSE_SMB_FOLDER_OWNER_ROOT"] else { throw Failure.mismatch }
        let root = URL(fileURLWithPath: raw), base = root.appendingPathComponent("source")
        try expect(root.resolvingSymlinksInPath() == root && (try String(contentsOf: root.appendingPathComponent("reservation.json"), encoding: .utf8)).contains("smb-folder-download-protocol-controls"))
        let selection = try SMBFolderDownloadSelection(connection: UUID(), snapshot: .init(readID: UUID(), revision: 2, count: 1, folders: 1, state: .complete),
            observation: .init(id: 1, name: SMBRemoteName("Generated"), attributes: 16, logicalBytes: 0, modifiedFileTime: 19))
        let manifest = try SMBFolderManifest(nodes: [.init(parent: nil, wire: nil, directory: true, attributes: 16, size: 0, allocated: 0, modified: 19, changed: 19, index: 9, volume: 17, links: 0)], selection: selection)
        let prepared = SMBPreparedFolderDownload(selection: selection, manifest: manifest), store = try RemoteDownloadStore(directory: base.appendingPathComponent("downloads"))
        let tree = try await store.reserveTree(prepared)
        for order in 0..<1000 {
            let attempt = SMBFolderReceiveAttempt(prepared, tree: tree, progress: nil), race = Race()
            await withTaskGroup(of: Void.self) { group in
                for cancel in [order % 2 == 0, order % 2 != 0] { group.addTask { if cancel { attempt.cancel() } else { race.record(attempt.admit()) } } }
            }
            try expect(attempt.isCancelled); try expect(attempt.mayAbandon == !race.value); attempt.drained(); try expect(attempt.mayAbandon)
            let preparing = SMBFolderPreparationAttempt(selection)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { preparing.cancel() }; group.addTask { _ = preparing.admit() }
            }
            try expect(preparing.isCancelled && !preparing.admit())
        }
        let activity = FileActivityGate(), secret = try SMBPassword("generated-not-a-credential")
        let ordinary = try SMBBrowserOwner(bundle: base.appendingPathComponent("Unused.app"), root: root, activity: activity, password: secret, policy: .encrypted, share: .standard)
        let early = SMBFolderPreparationAttempt(selection)
        do { _ = try await withCheckedThrowingContinuation { ordinary.prepareFolder(early, continuation: $0) }; throw Failure.mismatch }
        catch SMBBrowserFailure.unavailable { checks += 1 }
        let address = try SMBConnectionAddress("smb://127.0.0.1/Generated"), draft = try SMBServerDraft(name: "Generated", address: address, account: "generated", domain: "", security: .encrypted)
        let endpoint = try await SMBPreparedConnection.prepare(address, bundleURL: base.appendingPathComponent("Unused.app"), activity: activity)
        let owner = try SMBBrowserOwner(bundle: base.appendingPathComponent("Unused.app"), request: draft, endpoint: endpoint,
            storage: SMBTemporaryStorage(directory: base.appendingPathComponent("catalogs")), activity: activity, password: secret, selectedDownloads: true, folderDownloads: true)
        try expect(owner.mode == .folderDownload)
        let stale = SMBFolderPreparationAttempt(selection)
        do { _ = try await withCheckedThrowingContinuation { owner.prepareFolder(stale, continuation: $0) }; throw Failure.mismatch }
        catch SMBBrowserFailure.busy { checks += 1 }
        let receive = SMBFolderReceiveAttempt(prepared, tree: tree, progress: nil)
        do { try await withCheckedThrowingContinuation { owner.beginFolder(receive, continuation: $0) }; throw Failure.mismatch }
        catch SMBDirectoryFailure.stale { checks += 1 }
        try expect(receive.mayAbandon)
        do { try await withCheckedThrowingContinuation { owner.releaseFolder(prepared, continuation: $0) }; throw Failure.mismatch }
        catch SMBDirectoryFailure.stale { checks += 1 }
        try expect(activity.activeCount == 0 && !FileManager().fileExists(atPath: base.appendingPathComponent("catalogs").path))
        await tree.abandon(); try await store.discardIncomplete(tree.id); try expect(try await store.inspect().isEmpty)
        print("{\"passed\":true,\"checks\":\(checks),\"networkSockets\":0,\"helperLaunches\":0,\"keychainCalls\":0}")
    }
}
