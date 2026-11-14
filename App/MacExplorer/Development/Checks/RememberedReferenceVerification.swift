#if DEBUG
import AppKit
import Darwin

/// Controlled reference/sidebar checks only. No real bookmark, TCC request,
/// protected-folder enumeration or manual scope lease is used.
@MainActor
enum RememberedReferenceVerification {
    static func run(in testRoot: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw UIVerification.Failure(message: "Remembered reference checks require explicit unredirected fixtures.")
        }
        let owned = testRoot.appendingPathComponent("remembered-references-\(UUID().uuidString)", isDirectory: true)
        try await Task.detached {
            try FileManager().createDirectory(at: owned, withIntermediateDirectories: true)
            try Data("mac-explorer-reference-verification-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
        }.value
        let state = owned.appendingPathComponent("state", isDirectory: true)
        let original = owned.appendingPathComponent("original", isDirectory: true)
        let replacement = owned.appendingPathComponent("replacement", isDirectory: true)
        let backend = ReferenceVerificationBackend()
        let first = FolderAccessController(stateDirectory: state, backend: backend)
        guard let chosen = await first.acceptChosenFolder(original, remember: true), case .saved = chosen.remembering else {
            throw UIVerification.Failure(message: "Controlled reference creation failed")
        }
        let id = chosen.selection.id
        backend.mode = .missing
        let reopened = FolderAccessController(stateDirectory: state, backend: backend)
        let unavailable = await reopened.resolveRememberedFolders()
        try require(unavailable.count == 1 && unavailable[0].id == id && unavailable[0].url == nil,
                    "Unavailable reference lost its exact renewal ID")
        try require(await reopened.acquireAccess(to: original) == nil, "Unavailable reference activated a grant")
        let wrongID = await reopened.acceptChosenFolder(replacement, remember: true, replacingReference: UUID())
        try require(wrongID == nil, "Unknown renewal ID was accepted")
        guard let renewed = await reopened.acceptChosenFolder(replacement, remember: true, replacingReference: id),
              case .saved = renewed.remembering, renewed.selection.id == id else {
            throw UIVerification.Failure(message: "Explicit unavailable-reference renewal did not preserve its selected ID")
        }
        backend.mode = .fresh
        let restored = await reopened.resolveRememberedFolders()
        try require(restored.count == 1 && restored[0].id == id && restored[0].url == replacement,
                    "Reference replacement created duplicates or retained the wrong URL")
        let references = restored + [
            FolderAccessRestoreResult(id: UUID(), url: original, state: .needsRenewal),
            FolderAccessRestoreResult(id: UUID(), url: nil, state: .unavailable(.missing)),
        ]
        let sidebar = RememberedFolderSidebar()
        let group = sidebar.group(for: references)
        try require(group.group && group.children?.count == 3, "Remembered sidebar group did not preserve all states")
        for (node, reference) in zip(group.children ?? [], references) {
            try require(node.children?.isEmpty == true && node.location == nil && sidebar.referenceID(for: node) == reference.id,
                        "Displaying saved references can expand/enumerate a target or use the wrong ID")
        }
        try require(await reopened.forget(id: id) == nil, "Explicit reference forget failed")
        try require(await reopened.acceptChosenFolder(original, remember: true, replacingReference: id) == nil,
                    "Forgotten renewal lookup remained active")
        return ["Controlled unavailable-reference renewal preserves the selected ID without granting access or accumulating duplicates",
                "Remembered sidebar shows fresh/stale/unavailable references without expandable target nodes; Forget removes renewal lookup"]
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw UIVerification.Failure(message: message) }
    }
}

private final class ReferenceVerificationBackend: FolderAccessBackend, @unchecked Sendable {
    enum Mode: Sendable { case fresh, missing }
    private let lock = NSLock()
    private var value: Mode = .fresh
    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
    func startAccess(to url: URL) -> Bool { false }
    func stopAccess(to url: URL) {}
    func bookmark(for url: URL) throws -> Data { Data(url.absoluteString.utf8) }
    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution {
        if case .missing = mode { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
        guard let text = String(data: bookmark, encoding: .utf8), let url = URL(string: text), url.isFileURL else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        }
        return FolderBookmarkResolution(url: url, isStale: false)
    }
}
#endif
