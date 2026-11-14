#if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
import CryptoKit
import Darwin
import ExplorerCore
import Foundation

/// The failure is before rename. The canonical servers.json retains
/// releasePending while pending.json contains the attempted cleanupPending.
/// This oracle reads those exact bytes and the selected original body through
/// no-follow opens; it never asks RemoteSettingsFile to discard or retry.
struct GateBGeneratedGraphSnapshot: Equatable, Sendable {
    let identitiesAndDigests: [String: String]
}
enum GateBGeneratedGraphOracle {
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid
            && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink
            && a.st_size == b.st_size && a.st_blocks == b.st_blocks
            && a.st_flags == b.st_flags
            && a.st_birthtimespec.tv_sec == b.st_birthtimespec.tv_sec
            && a.st_birthtimespec.tv_nsec == b.st_birthtimespec.tv_nsec
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
            && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func stamp(_ value: stat) -> String {
        "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_nlink):\(value.st_size):\(value.st_blocks):\(value.st_flags):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }
    /// Complete generated backend namespaces. Descend only from anchored
    /// directory FDs; every named child is compared before and after reading.
    /// This catches a new pending/intent/metadata leaf as well as altered bytes.
    private static func namespace(_ layout: ApplicationStorageLayout) throws -> [String: String] {
        var result: [String: String] = [:], entries = 0
        var charged: UInt64 = 0
        func account(_ facts: stat) throws {
            guard facts.st_uid == geteuid(), facts.st_size >= 0, facts.st_blocks >= 0,
                  facts.st_blocks <= (64 << 20) / 512,
                  entries < 1024 else { throw GateBGeneratedFailure(stage: "graph-namespace-bound") }
            let size = UInt64(max(facts.st_size, facts.st_blocks * 512))
            guard size <= 64 << 20, charged <= (64 << 20) - size else {
                throw GateBGeneratedFailure(stage: "graph-namespace-bytes")
            }
            entries += 1; charged += size
        }
        func visit(_ parent: Int32, _ name: String, _ key: String, _ device: dev_t) throws {
            var named = stat()
            guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_dev == device else { throw GateBGeneratedFailure(stage: "graph-named-entry") }
            try account(named)
            if named.st_mode & S_IFMT == S_IFDIR {
                guard named.st_mode & 0o7777 == 0o700 else { throw GateBGeneratedFailure(stage: "graph-directory-mode") }
                let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
                guard fd >= 0 else { throw GateBGeneratedFailure(stage: "graph-directory-open") }
                defer { Darwin.close(fd) }
                var opened = stat(), after = stat(), current = stat()
                guard fstat(fd, &opened) == 0, same(named, opened) else {
                    throw GateBGeneratedFailure(stage: "graph-directory-replaced")
                }
                result[key] = "directory:" + stamp(opened)
                for child in try DownloadDisk.names(fd, maximum: 1024) {
                    try visit(fd, child, key + "/" + child, device)
                }
                guard fstat(fd, &after) == 0, fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      same(opened, after), same(after, current) else {
                    throw GateBGeneratedFailure(stage: "graph-directory-changed")
                }
            } else {
                guard named.st_mode & S_IFMT == S_IFREG, named.st_mode & 0o7777 == 0o600,
                      named.st_nlink == 1, named.st_size <= 1 << 20 else {
                    throw GateBGeneratedFailure(stage: "graph-file-kind-mode-or-bound")
                }
                let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
                guard fd >= 0 else { throw GateBGeneratedFailure(stage: "graph-file-open") }
                defer { Darwin.close(fd) }
                var opened = stat(), after = stat(), current = stat()
                guard fstat(fd, &opened) == 0, same(named, opened) else {
                    throw GateBGeneratedFailure(stage: "graph-file-replaced")
                }
                var bytes = Data(count: Int(opened.st_size)), offset = 0
                while offset < bytes.count {
                    let remaining = bytes.count - offset
                    let count = bytes.withUnsafeMutableBytes {
                        pread(fd, $0.baseAddress!.advanced(by: offset), remaining, off_t(offset))
                    }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw GateBGeneratedFailure(stage: "graph-file-read") }
                    offset += count
                }
                guard fstat(fd, &after) == 0, fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      same(opened, after), same(after, current) else {
                    throw GateBGeneratedFailure(stage: "graph-file-changed")
                }
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                result[key] = "file:" + stamp(opened) + ":" + digest
            }
        }
        for (key, url) in [("state", layout.stateDirectory), ("cache", layout.cacheDirectory)] {
            let parentURL = url.deletingLastPathComponent()
            let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard parent >= 0 else { throw GateBGeneratedFailure(stage: "graph-root-parent") }
            defer { Darwin.close(parent) }
            var facts = stat()
            guard fstat(parent, &facts) == 0 else { throw GateBGeneratedFailure(stage: "graph-root-parent-stat") }
            try visit(parent, url.lastPathComponent, key, facts.st_dev)
        }
        return result
    }
    private static func read(_ url: URL, maximum: Int) throws -> (Data, String) {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw GateBGeneratedFailure(stage: "graph-leaf-open") }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o7777 == 0o600,
              before.st_size >= 0, before.st_size <= Int64(maximum) else {
            throw GateBGeneratedFailure(stage: "graph-leaf-kind-or-bound")
        }
        var bytes = Data(count: Int(before.st_size)), offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: offset),
                remaining, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw GateBGeneratedFailure(stage: "graph-leaf-read") }
            offset += count
        }
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw GateBGeneratedFailure(stage: "graph-leaf-changed")
        }
        let identity = "\(before.st_dev):\(before.st_ino):\(before.st_birthtimespec.tv_sec):\(before.st_birthtimespec.tv_nsec):\(before.st_size):\(before.st_mtimespec.tv_sec):\(before.st_mtimespec.tv_nsec):\(before.st_ctimespec.tv_sec):\(before.st_ctimespec.tv_nsec)"
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (bytes, identity + ":" + digest)
    }
    static func capture(layout: ApplicationStorageLayout, storage: SFTPInPlaceWorkingCopyStorage,
                        editorID: UUID, reference: SFTPOriginalSpoolReference) async throws -> GateBGeneratedGraphSnapshot {
        try await Task.detached {
            let allBefore = try namespace(layout)
            guard storage.layout.bodies == layout.persistentConnectionWorkspaceDirectory.appendingPathExtension("original-bodies"),
                  reference.logicalBytes == 7 else { throw GateBGeneratedFailure(stage: "graph-layout-or-reference") }
            let pool = open(storage.layout.bodies.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard pool >= 0 else { throw GateBGeneratedFailure(stage: "graph-body-pool-open") }
            defer { Darwin.close(pool) }
            let bodyName = "download-" + reference.id.uuidString
            let record = try DownloadDisk.record(pool, name: bodyName)
            guard record.summary.id == reference.id, !record.summary.active,
                  record.summary.expectedBytes == reference.logicalBytes,
                  record.files["owner.lock"] != nil, record.files["payload"] != nil,
                  record.files["session.meta"] != nil else { throw GateBGeneratedFailure(stage: "graph-body-record") }
            let editorRoot = storage.layout.editors
            let bodyRoot = storage.layout.bodies.appendingPathComponent(bodyName, isDirectory: true)
            let (serversBytes, serversID) = try read(editorRoot.appendingPathComponent("servers.json"), maximum: 256 << 10)
            let (pendingBytes, pendingID) = try read(editorRoot.appendingPathComponent("pending.json"), maximum: 256 << 10)
            let servers = try SFTPOriginalEditorCatalogDocument.decode(serversBytes)
            let pending = try SFTPOriginalEditorCatalogDocument.decode(pendingBytes)
            guard servers.records.count == 1, pending.records.count == 1,
                  servers.records[0].id == editorID, pending.records[0].id == editorID,
                  servers.records[0].phase == .releasePending,
                  pending.records[0].phase == .cleanupPending,
                  servers.records[0].body == reference, pending.records[0].body == reference,
                  servers.records[0].journals.isEmpty, pending.records[0].journals.isEmpty,
                  servers.records[0].recovery.isEmpty, pending.records[0].recovery.isEmpty,
                  pending.revision == servers.revision + 1 else {
                throw GateBGeneratedFailure(stage: "graph-exact-post-fault-catalog")
            }
            let (body, payloadID) = try read(bodyRoot.appendingPathComponent("payload"), maximum: 1 << 20)
            guard body == Data("before\n".utf8), Data(SHA256.hash(data: body)) == reference.digest else {
                throw GateBGeneratedFailure(stage: "graph-original-body-changed")
            }
            let (_, leaseID) = try read(bodyRoot.appendingPathComponent("owner.lock"), maximum: 0)
            let (_, markerID) = try read(bodyRoot.appendingPathComponent("session.meta"), maximum: 2048)
            let (_, ledgerID) = try read(storage.layout.ledger.appendingPathComponent("servers.json"), maximum: 256 << 10)
            let allAfter = try namespace(layout)
            guard allBefore == allAfter else { throw GateBGeneratedFailure(stage: "graph-namespace-changed-during-capture") }
            var graph: [String: String] = [:]
            for (key, value) in allAfter { graph["namespace." + key] = value }
            graph.merge([
                "editor.servers": serversID, "editor.pending": pendingID,
                "body.payload": payloadID, "body.owner": leaseID,
                "body.marker": markerID, "budget.servers": ledgerID]) { _, newer in newer }
            return GateBGeneratedGraphSnapshot(identitiesAndDigests: graph)
        }.value
    }
    /// A successful fresh Remove must prove the actual whole-document terminal
    /// graph, including the catalog and shared-budget charges. Body absence by
    /// itself cannot be reported as valid progress.
    static func requireProgress(layout: ApplicationStorageLayout, storage: SFTPInPlaceWorkingCopyStorage,
                                editorID: UUID, reference: SFTPOriginalSpoolReference,
                                before: GateBGeneratedGraphSnapshot) async throws {
        try await Task.detached {
            let allBefore = try namespace(layout)
            let prior = before.identitiesAndDigests.reduce(into: [String: String]()) { result, item in
                if item.key.hasPrefix("namespace.") {
                    result[String(item.key.dropFirst("namespace.".count))] = item.value
                }
            }
            guard !prior.isEmpty else { throw GateBGeneratedFailure(stage: "progress-prior-graph-unavailable") }
            let bodyKey = "state/connection-workspace.original-bodies/download-" + reference.id.uuidString
            let mutable = Set([
                "state/connection-workspace.original-bodies",
                "state/connection-workspace.original-bodies.original-editors",
                "state/connection-workspace.original-bodies.original-editors/servers.json",
                "state/connection-workspace.original-bodies.original-editors/pending.json",
                "state/connection-workspace.original-budget",
                "state/connection-workspace.original-budget/servers.json"
            ])
            for key in Set(prior.keys).union(allBefore.keys) {
                guard mutable.contains(key) || key == bodyKey || key.hasPrefix(bodyKey + "/")
                    || prior[key] == allBefore[key] else {
                    throw GateBGeneratedFailure(stage: "progress-unrelated-backend-entry-changed")
                }
            }
            let body = storage.layout.bodies.appendingPathComponent("download-" + reference.id.uuidString, isDirectory: true)
            var facts = stat()
            errno = 0
            guard lstat(body.path, &facts) != 0, errno == ENOENT else {
                throw GateBGeneratedFailure(stage: "progress-body-not-absent")
            }
            let (editorBytes, _) = try read(storage.layout.editors.appendingPathComponent("servers.json"), maximum: 256 << 10)
            let (budgetBytes, _) = try read(storage.layout.ledger.appendingPathComponent("servers.json"), maximum: 256 << 10)
            let editors = try SFTPOriginalEditorCatalogDocument.decode(editorBytes)
            let budget = try SFTPSharedBudgetDocument.decode(budgetBytes)
            guard let bodyOwner = budget.bodies.first?.owner else {
                throw GateBGeneratedFailure(stage: "progress-body-owner-missing")
            }
            guard editors.records.count == 1, editors.records[0].id == editorID,
                  editors.records[0].phase == .closedUnused,
                  editors.records[0].body == nil, editors.records[0].bodyID == nil,
                  editors.records[0].recovery.isEmpty, editors.records[0].journals.isEmpty,
                  budget.format == 2, budget.retirements?.isEmpty == true,
                  budget.bodies.count == 1, budget.bodies[0].id == reference.id,
                  budget.bodies[0].phase == .removed,
                  budget.metadata.contains(where: { $0.kind == .original && $0.id == bodyOwner }) else {
                throw GateBGeneratedFailure(stage: "progress-catalog-or-budget-not-retired")
            }
            for parent in [storage.layout.editors, storage.layout.ledger] {
                errno = 0
                guard lstat(parent.appendingPathComponent("pending.json").path, &facts) != 0,
                      errno == ENOENT else { throw GateBGeneratedFailure(stage: "progress-pending-stage-remains") }
            }
            guard allBefore == (try namespace(layout)) else {
                throw GateBGeneratedFailure(stage: "progress-namespace-changed-during-capture")
            }
        }.value
    }
}
#endif
