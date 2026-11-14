#if DEBUG
import Darwin
import Foundation
import StorageAnalysis

@MainActor enum AppComponentAccountingVerification {
    static func run(root: URL) async throws -> [String: Any] {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        guard root.deletingLastPathComponent() == repository.appendingPathComponent(".build/b06-app-components"),
              root.resolvingSymlinksInPath() == root, UUID(uuidString: root.lastPathComponent) != nil,
              FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path) else {
            throw UIVerification.Failure(message: "App-component check requires its owned generated root")
        }
        let checks = try await Task.detached { try verify(root) }.value
        return ["passed": true, "checks": checks, "personalStateOpened": false, "databaseOpened": false,
                "fileBodyProcessing": false, "fullDriveScan": false]
    }

    nonisolated private static func verify(_ root: URL) throws -> [String] {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw UIVerification.Failure(message: message) }; try Task.checkCancellation()
        }
        let fm = FileManager(), state = root.appendingPathComponent("State")
        try fm.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in ["folder-views", "drive-protection", "profile-workspaces"] {
            let dir = state.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data(repeating: 42, count: 2048).write(to: dir.appendingPathComponent("generated.json"), options: .withoutOverwriting)
            try Data(repeating: 43, count: 512).write(to: dir.appendingPathComponent(".snapshot-retained.tmp"), options: .withoutOverwriting)
            try Data().write(to: dir.appendingPathComponent("generated.writer-lock"), options: .withoutOverwriting)
        }
        try Data(repeating: 44, count: 513).write(to: state.appendingPathComponent("launch-profiles-v1.json"), options: .withoutOverwriting)
        func identity(_ path: URL) throws -> AnalysisObjectIdentity {
            var info = stat()
            try require(lstat(path.path, &info) == 0, "Generated metadata unavailable")
            return .init(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino)
        }
        let rootIdentity = try identity(state)
        var accumulator = StorageAnalysisAccumulator(rootIdentity: rootIdentity)
        for name in ["folder-views", "drive-protection", "profile-workspaces"] {
            let dir = state.appendingPathComponent(name)
            try require(accumulator.consume(.init(relativePath: Data(name.utf8), kind: .directory,
                                                   identity: .returned(try identity(dir)))) == .accepted, "Generated folder rejected")
            for leaf in ["generated.json", ".snapshot-retained.tmp", "generated.writer-lock"] {
                var info = stat(); let file = dir.appendingPathComponent(leaf)
                try require(lstat(file.path, &info) == 0 && info.st_size >= 0 && info.st_blocks >= 0, "Generated file metadata unavailable")
                let bytes = AnalysisByteObservation(dataLogical: .returned(UInt64(info.st_size)),
                    allForkLogical: .returned(UInt64(info.st_size)), dataAllocated: .returned(UInt64(info.st_blocks) * 512),
                    allForkAllocated: .returned(UInt64(info.st_blocks) * 512))
                try require(accumulator.consume(.init(relativePath: Data((name + "/" + leaf).utf8), kind: .regularFile,
                    identity: .returned(try identity(file)), linkCount: .returned(1), flags: .returned(0), bytes: bytes)) == .accepted,
                    "Generated file rejected")
            }
        }
        let snapshot = accumulator.finish(), rows = try AppStorageInventory.inspect(root: state, snapshot: snapshot)
        for title in ["Saved folder views", "Drive protection", "Remembered profile workspaces"] {
            try require(rows.first { $0.title == title }?.logical == FileSizeText.string(2560), "Saved component omitted observed files")
            try require(rows.first { $0.title == title }?.note.contains("lock/temporary") == true, "Retained metadata note missing")
        }
        try require(rows.first { $0.title == "Saved launch profiles" }?.logical == FileSizeText.string(513), "Launch profile metadata missing")
        try require(rows.first { $0.title == "Operation history" }?.logical == "Not created"
            && !fm.fileExists(atPath: state.appendingPathComponent("operation-recovery").path), "Inventory created history")
        var empty = StorageAnalysisAccumulator(rootIdentity: rootIdentity)
        let unobserved = try AppStorageInventory.inspect(root: state, snapshot: empty.finish())
        try require(unobserved.first { $0.title == "Saved folder views" }?.logical == "Not observed", "Existing unobserved component became zero")
        try require(unobserved.first { $0.title == "Remembered profile workspaces" }?.logical == "Not observed", "Unobserved profile workspaces became zero")
        let moved = root.appendingPathComponent("Retained folder views")
        try fm.moveItem(at: state.appendingPathComponent("folder-views"), to: moved)
        try fm.createDirectory(at: state.appendingPathComponent("folder-views"), withIntermediateDirectories: false)
        let changed = try AppStorageInventory.inspect(root: state, snapshot: snapshot)
        try require(changed.first { $0.title == "Saved folder views" }?.logical == "Changed / unavailable", "Replacement inherited old totals")
        let protection = state.appendingPathComponent("drive-protection")
        try fm.moveItem(at: protection, to: root.appendingPathComponent("Retained drive protection"))
        try fm.createSymbolicLink(at: protection, withDestinationURL: moved)
        let linked = try AppStorageInventory.inspect(root: state, snapshot: snapshot)
        try require(linked.first { $0.title == "Drive protection" }?.logical == "Changed / unavailable", "Component symlink inherited totals")
        let workspaces = state.appendingPathComponent("profile-workspaces")
        try fm.moveItem(at: workspaces, to: root.appendingPathComponent("Retained profile workspaces"))
        try fm.createSymbolicLink(at: workspaces, withDestinationURL: moved)
        let linkedWorkspace = try AppStorageInventory.inspect(root: state, snapshot: snapshot)
        try require(linkedWorkspace.first { $0.title == "Remembered profile workspaces" }?.logical == "Changed / unavailable", "Workspace symlink inherited totals")
        try fm.removeItem(at: workspaces)
        var absentSnapshot = StorageAnalysisAccumulator(rootIdentity: rootIdentity)
        let absent = try AppStorageInventory.inspect(root: state, snapshot: absentSnapshot.finish())
        try require(absent.first { $0.title == "Remembered profile workspaces" }?.logical == "Not created", "Missing workspaces were not distinguished from unobserved")
        try fm.moveItem(at: state, to: root.appendingPathComponent("Retained State"))
        try fm.createDirectory(at: state, withIntermediateDirectories: false)
        let changedRoot = try AppStorageInventory.inspect(root: state, snapshot: snapshot)
        try require(changedRoot.count == 1 && changedRoot[0].logical == "Unavailable", "Replacement state root inherited old totals")
        return ["Saved profiles are shallow metadata; saved views/protection/profile workspaces include accepted lock and retained temporary bytes",
                "Absent and existing-but-unobserved components stay distinct; inventory creates no history",
                "Replaced folders and component symlinks cannot inherit accepted totals",
                "A replaced state root refuses the entire earlier snapshot; no document or database is opened"]
    }
}
#endif
