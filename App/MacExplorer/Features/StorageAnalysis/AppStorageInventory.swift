import Darwin
import Foundation
import ExplorerCore
import StorageAnalysis

// Metadata preparation for the shared app-storage presentation. The existing
// application owner runs inspect off-main; this file owns no window or mutation.
struct AppStorageComponent: Sendable {
    let title: String
    let logical: String
    let allocation: String
    let note: String
}

/// Declared app-owned paths only. Opening this inventory never opens SQLite,
/// activates a bookmark, imports history, creates state or reads a file body.
enum AppStorageInventory {
    /// Separate declared cache root; never creates it or opens its databases.
    static func temporaryPool(reader: AnalysisTemporaryStorageReader, directory: URL? = nil) async -> AppStorageComponent {
        let title = "Saved and temporary analyses"
        do {
            let root: URL
            if let directory { root = directory }
            else {
                root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                    .appendingPathComponent("MacExplorer-Analysis", isDirectory: true).standardizedFileURL
            }
            let value = try await reader.read(directory: root)
            guard value.exists else {
                return .init(title: title, logical: "Not created", allocation: "—", note: "No temporary-analysis pool was observed. This inventory did not create one.")
            }
            func bytes(_ value: UInt64?) -> String {
                guard let value else { return "Unavailable" }
                return value <= UInt64(Int64.max) ? FileSizeText.string(Int64(value)) : "\(value) bytes"
            }
            let prefix = value.isComplete ? "" : "Known: "
            let changes = value.gaps.values.reduce(0, +)
            let note = "\(value.sessions) sessions · \(value.openSessions) open or retained · \(value.unheldSessions) with no held owner lease. "
                + (value.isComplete ? "Shallow metadata observation." : "Incomplete observation · \(changes) unavailable, changed or unrecognized items/checks.")
                + " Unheld results are not necessarily safe to discard. Allocation is observed POSIX blocks, not reserved quota, exclusive or reclaimable space; active results may grow. No database was opened."
            return .init(title: title, logical: prefix + bytes(value.logicalFileBytes), allocation: prefix + bytes(value.allocatedNameBytes), note: note)
        } catch is CancellationError {
            return .init(title: title, logical: "Stopped", allocation: "—", note: "The temporary-storage observation was cancelled; no result was removed.")
        } catch StorageScanFailure.busy {
            return .init(title: title, logical: "Busy", allocation: "—", note: "The temporary pool is changing or another inventory is finishing. Refresh to observe it; no result was removed.")
        } catch {
            return .init(title: title, logical: "Unavailable", allocation: "—", note: "The declared temporary pool could not be verified or accessed. Its size is unknown; no database was opened and no result was removed.")
        }
    }

    static func inspect(root: URL, snapshot: StorageAnalysisSnapshot) throws -> [AppStorageComponent] {
        try Task.checkCancellation()
        let activity = try ApplicationFileActivity.gate.begin()
        defer { withExtendedLifetime(activity) {} }
        let descriptor = root.withUnsafeFileSystemRepresentation {
            $0.map { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) } ?? -1
        }
        guard descriptor >= 0 else { return unavailable("App state could not be opened without following links.") }
        defer { close(descriptor) }
        var observed = stat()
        guard fstat(descriptor, &observed) == 0,
              snapshot.root.identity.value == AnalysisObjectIdentity(device: UInt64(UInt32(bitPattern: observed.st_dev)), inode: observed.st_ino)
        else { return unavailable("App state changed since the scan. Refresh before comparing components.") }
        var rows: [AppStorageComponent] = []
        for (name, title) in [("preferences.json", "Preferences"), ("directory-visits-v1.json", "Optional visit ranking"),
            ("folder-access-bookmarks-v1.json", "Remembered access"), ("browser-pins-v1.json", "Pinned locations"),
            ("browser-workspace-v2.json", "Saved tabs and panes"), ("launch-profiles-v1.json", "Saved launch profiles")] {
            try Task.checkCancellation()
            var file = stat()
            let result = name.withCString { fstatat(descriptor, $0, &file, AT_SYMLINK_NOFOLLOW) }
            if result != 0 {
                rows.append(.init(title: title, logical: errno == ENOENT ? "Not created" : "Unavailable",
                    allocation: "—", note: errno == ENOENT ? "No file observed at its declared path." : "Metadata access failed."))
            } else if file.st_mode & S_IFMT != S_IFREG || file.st_size < 0 || file.st_blocks < 0 {
                rows.append(.init(title: title, logical: "Uncertain", allocation: "—", note: "Declared path is not an ordinary file; links are not followed."))
            } else {
                let (allocated, overflow) = UInt64(file.st_blocks).multipliedReportingOverflow(by: 512)
                rows.append(.init(title: title, logical: FileSizeText.string(file.st_size),
                    allocation: overflow ? "Unavailable" : allocated > UInt64(Int64.max) ? "\(allocated) bytes" : FileSizeText.string(Int64(allocated)),
                    note: "Shallow POSIX metadata observed after the scan; allocated blocks are not exclusive or reclaimable space."))
            }
        }
        if let history = snapshot.folders.first(where: { $0.relativePath == Data("operation-recovery".utf8) }) {
            var live = stat()
            let same = "operation-recovery".withCString { fstatat(descriptor, $0, &live, AT_SYMLINK_NOFOLLOW) } == 0
                && live.st_mode & S_IFMT == S_IFDIR
                && history.identity.value == AnalysisObjectIdentity(device: UInt64(UInt32(bitPattern: live.st_dev)), inode: live.st_ino)
            rows.append(.init(title: "Operation history and local retained files",
                logical: same ? storageMetricText(history.namespaceSubtotals.dataLogical, files: history.counts.regularFiles) : "Changed / unavailable",
                allocation: same ? storageMetricText(history.namespaceSubtotals.allForkAllocated, files: history.counts.regularFiles) : "—",
                note: "Scan-time namespace subtotal, \(history.isComplete ? "complete observation" : "partial observation"). No database was opened. Recovery payloads elsewhere are excluded."))
        } else {
            var history = stat()
            let result = "operation-recovery".withCString { fstatat(descriptor, $0, &history, AT_SYMLINK_NOFOLLOW) }
            rows.append(.init(title: "Operation history", logical: result != 0 && errno == ENOENT ? "Not created" : "Not observed",
                allocation: "—", note: "No accepted history-folder subtotal is available. No database was opened."))
        }
        rows.append(contentsOf: [
            savedComponent("folder-views", title: "Saved folder views", root: descriptor, snapshot: snapshot),
            savedComponent("drive-protection", title: "Drive protection", root: descriptor, snapshot: snapshot),
            savedComponent("profile-workspaces", title: "Remembered profile workspaces", root: descriptor, snapshot: snapshot),
            savedComponent(ApplicationStorageLayout.smbInPlaceRecoveryDirectory(
                metadata: root.appendingPathComponent("connection-workspace", isDirectory: true)).lastPathComponent,
                title: "SMB editor saved versions", root: descriptor, snapshot: snapshot),
            privateNames(descriptor),
            .init(title: "Content index", logical: "Not created", allocation: "—", note: "Saved-name search keys are reported with the private catalog above. No file-content index exists. Spotlight storage belongs to macOS and is not included."),
            .init(title: "Folder-summary cache", logical: "Session memory only", allocation: "—", note: "Bounded in-memory observations; no disk cache is created by this feature."),
            .init(title: "Installed app / developer tooling", logical: "Outside this scan", allocation: "—", note: "The app bundle, repo fixtures, compiler/toolchain caches and build products are separate from local app state."),
            .init(title: "Recovery files on other volumes", logical: "Not measured", allocation: "—", note: "Historical locations do not grant scan access. No additional root or saved bookmark was activated.")])
        return rows
    }

    private static func savedComponent(_ name: String, title: String, root: Int32,
                                       snapshot: StorageAnalysisSnapshot) -> AppStorageComponent {
        var current = stat()
        let result = name.withCString { fstatat(root, $0, &current, AT_SYMLINK_NOFOLLOW) }
        let missing = result != 0 && errno == ENOENT
        let observed = snapshot.folders.first { $0.relativePath == Data(name.utf8) }
        guard let observed else {
            return .init(title: title, logical: missing ? "Not created" : "Not observed",
                         allocation: "—", note: "No accepted component subtotal is available. This inventory did not create or open its documents.")
        }
        let same = result == 0 && current.st_mode & S_IFMT == S_IFDIR
            && observed.identity.value == AnalysisObjectIdentity(device: UInt64(UInt32(bitPattern: current.st_dev)), inode: current.st_ino)
        return .init(title: title,
                     logical: same ? storageMetricText(observed.namespaceSubtotals.dataLogical, files: observed.counts.regularFiles) : "Changed / unavailable",
                     allocation: same ? storageMetricText(observed.namespaceSubtotals.allForkAllocated, files: observed.counts.regularFiles) : "—",
                     note: "Scan-time namespace subtotal, \(observed.isComplete ? "complete observation" : "partial observation"). Includes observed lock/temporary files; no document was opened. Current saves can change size after this scan. Allocation is not exclusive or reclaimable space.")
    }

    private static func privateNames(_ root: Int32) -> AppStorageComponent {
        let title = "Private names and direct-search index"
        let directory = openat(root, "private-names", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard directory >= 0 else {
            return .init(title: title, logical: errno == ENOENT ? "Not created" : "Unavailable", allocation: "—",
                note: "Only the declared private catalog is measured. No database or source file was opened.")
        }
        defer { close(directory) }
        var logical: Int64 = 0, allocated: Int64 = 0
        for name in ["names.sqlite", "names.sqlite-journal", "initialization", "ready", "owner.lock"] {
            var file = stat()
            if fstatat(directory, name, &file, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                return .init(title: title, logical: "Unavailable", allocation: "—", note: "A declared catalog component could not be observed.")
            }
            guard file.st_mode & S_IFMT == S_IFREG, file.st_size >= 0, file.st_blocks >= 0,
                  file.st_size <= 1_024 * 1_024 * 1_024, file.st_blocks <= 2_097_152 else {
                return .init(title: title, logical: "Uncertain", allocation: "—", note: "Links and unexpected component metadata are not followed.")
            }
            logical += file.st_size; allocated += Int64(file.st_blocks) * 512
        }
        return .init(title: title, logical: FileSizeText.string(logical), allocation: FileSizeText.string(allocated),
            note: "Names, native references and rebuildable search keys share a normally backed-up database. These are live shallow observations, not exclusive or reclaimable bytes. Settings → Privacy provides numeric counts and page estimates; no database was opened here.")
    }

    private static func unavailable(_ note: String) -> [AppStorageComponent] {
        [.init(title: "Declared app state", logical: "Unavailable", allocation: "—", note: note)]
    }
}

