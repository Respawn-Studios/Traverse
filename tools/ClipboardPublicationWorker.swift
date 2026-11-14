import AppKit
import Darwin
import Foundation

/// Standalone native helper regression. Never touches the general pasteboard.
@main
struct ClipboardPublicationWorker {
    struct Failure: Error { let code: String }
    @MainActor static func main() async {
        var stage = "arguments"
        do {
            let args = CommandLine.arguments
            guard args.count == 4, let count = Int(args[3]), [1, 2, 33, 1024, 1025].contains(count),
                  ["owned", "nativeFirst", "rawFirst", "largeUnowned", "semantics"].contains(args[1]) else {
                throw Failure(code: "arguments")
            }
            let root = URL(fileURLWithPath: args[2], isDirectory: true)
            stage = "fixture"
            try await Task.detached { try fixture(root, count: count) }.value
            let urls = (0..<count).map { root.appendingPathComponent("source", isDirectory: true)
                .appendingPathComponent("generated-\($0).dat") }
            stage = args[1]
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            var assertions = 0
            var ownedReceipt = false
            var unownedNativePublication = false
            func require(_ value: Bool, _ code: String) throws {
                guard value else { throw Failure(code: code) }; assertions += 1
            }
            func receipt(_ value: BrowserClipboard.Publication) throws -> BrowserClipboard.FilePublication {
                guard case .files(let file) = value else { throw Failure(code: "noReceipt") }
                return file
            }
            if args[1] == "owned" {
                let publication = try receipt(BrowserClipboard.publish(nil, urls: urls, to: board))
                ownedReceipt = true
                let revision = UUID(), feedback = UUID()
                let owned = BrowserClipboard.OwnedCopy(publication: publication, revision: revision, feedbackID: feedback)
                let feedbackRead = owned.read(from: board, revision: revision, feedbackID: feedback)
                let pasteRead = owned.read(from: board, revision: revision, feedbackID: feedback)
                try require(feedbackRead?.urls == urls && pasteRead?.urls == urls, "ownedOrder")
                try require(feedbackRead?.isCurrent(on: board) == true, "ownedCurrent")
                try require(board.changeCount == publication.changeCount, "ownedNoRewrite")
            } else if args[1] == "largeUnowned" {
                guard count == 1025 else { throw Failure(code: "largeCount") }
                let publication = BrowserClipboard.publish(nil, urls: urls, to: board)
                guard case .unownedFiles(let proof) = publication else { throw Failure(code: "largeOwnedOrFailed") }
                unownedNativePublication = true
                try require(proof.isCurrent(on: board), "largeNativePublication")
                let result = BrowserClipboard.readFiles(from: board, isCurrent: { true })
                try require(result?.urls.count == 1025 && result?.urls == urls, "largeNativeExactOrder")
                try require(result?.changeCount == proof.changeCount && proof.isCurrent(on: board), "largeNativeGeneration")
            } else if args[1] == "nativeFirst" {
                try require(BrowserClipboard.write(nil, urls: urls, to: board), "nativeWrite")
                let result = BrowserClipboard.readFiles(from: board, isCurrent: { true })
                try require(result?.urls == urls, "nativeReferences")
            } else if args[1] == "rawFirst" {
                try require(BrowserClipboard.write(nil, urls: urls, to: board), "nativeWrite")
                let materialized = board.pasteboardItems?.compactMap { $0.string(forType: .fileURL) } ?? []
                try require(materialized.count == count, "rawReferences")
            } else {
                let publication = try receipt(BrowserClipboard.publish(nil, urls: urls, to: board))
                ownedReceipt = true
                let revision = UUID(), feedback = UUID()
                let owned = BrowserClipboard.OwnedCopy(publication: publication, revision: revision, feedbackID: feedback)
                try require(owned.read(from: board, revision: UUID(), feedbackID: feedback) == nil, "oldRevision")
                try require(owned.read(from: board, revision: revision, feedbackID: UUID()) == nil, "oldFeedback")
                try require(owned.read(from: board, revision: revision, feedbackID: nil) == nil, "dismissed")
                let other = NSPasteboard.withUniqueName()
                defer { other.releaseGlobally() }
                _ = BrowserClipboard.write(nil, urls: urls, to: other)
                try require(owned.read(from: other, revision: revision, feedbackID: feedback) == nil, "foreignBoard")
                _ = BrowserClipboard.write(nil, urls: urls, to: board)
                try require(owned.read(from: board, revision: revision, feedbackID: feedback) == nil, "newIdenticalGeneration")
                let fallback = BrowserClipboard.readFiles(from: board, isCurrent: { true })
                try require(fallback?.urls == urls, "nativeFallbackExact")
                // Real native decoding followed by a deterministic other publisher.
                let changed = BrowserClipboard.readFilesForVerification(from: board, isCurrent: { true }) { value in
                    let result = (value.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                        as? [NSURL])?.map { $0 as URL } ?? []
                    _ = BrowserClipboard.write("generated newer text", urls: [], to: value)
                    return result
                }
                try require(changed == nil, "readGenerationFence")
                var active = board
                let switched = BrowserClipboard.readFilesForVerification(from: board, isCurrent: { active === board }) { _ in
                    active = other; return urls
                }
                try require(switched == nil, "readIdentityFence")
                let beforeRefusal = board.changeCount
                if case .failed = BrowserClipboard.publish(nil, urls: [], to: board) {
                    try require(board.changeCount == beforeRefusal, "emptyPreservesBoard")
                } else { throw Failure(code: "empty") }
                if case .failed = BrowserClipboard.publish(nil, urls: [URL(string: "https://example.invalid")!], to: board) {
                    try require(board.changeCount == beforeRefusal, "nonFilePreservesBoard")
                } else { throw Failure(code: "nonFile") }
                let failed = BrowserClipboard.publishForVerification(nil, urls: urls, to: board, failWrite: true)
                if case .failed = failed { assertions += 1 } else { throw Failure(code: "nativeFailureReceipt") }
                let beforeWrite = BrowserClipboard.publishForVerification(nil, urls: urls, to: board, afterClear: { value in
                    _ = BrowserClipboard.write("generated intervening text", urls: [], to: value)
                })
                if case .failed = beforeWrite { assertions += 1 } else { throw Failure(code: "interveningClearReceipt") }
                try require(board.string(forType: .string) == "generated intervening text", "noOverwriteAfterClearRace")
                let afterWrite = BrowserClipboard.publishForVerification(nil, urls: urls, to: board, afterWrite: { value in
                    _ = BrowserClipboard.write("generated intervening text", urls: [], to: value)
                })
                if case .failed = afterWrite { assertions += 1 } else { throw Failure(code: "interveningWriteReceipt") }
                // A capture-only writer explicitly cannot return file provenance.
                let noOp: (String?, [URL]) -> BrowserClipboard.Publication = { _, _ in .failed }
                if case .failed = noOp(nil, urls) { assertions += 1 } else { throw Failure(code: "noOp") }
                let literal = [urls[0].deletingLastPathComponent().appendingPathComponent("cafe\u{301} %#.dat")]
                let literalReceipt = try receipt(BrowserClipboard.publish(nil, urls: literal, to: board))
                try require(literalReceipt.urls == literal, "originalValues")
            }
            emit(["ok": true, "stage": stage, "count": count, "assertions": assertions,
                  "nativeDecoderRoute": ["nativeFirst", "largeUnowned", "semantics"].contains(args[1]),
                  "ownedReceipt": ownedReceipt, "unownedNativePublication": unownedNativePublication])
        } catch {
            emit(["ok": false, "stage": stage, "error": (error as? Failure)?.code ?? "unexpected"])
            exit(1)
        }
    }

    static func fixture(_ root: URL, count: Int) throws {
        // Parent runner owns exact repository topology and source/binary provenance.
        // Child independently refuses symlinks, wrong owner/mode and unexpected files.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let run = sources.deletingLastPathComponent()
        let base = run.deletingLastPathComponent()
        guard sources.lastPathComponent == "sources",
              UUID(uuidString: run.lastPathComponent)?.uuidString.lowercased() == run.lastPathComponent,
              base.lastPathComponent == "clipboard-publication-qualification",
              base.deletingLastPathComponent().lastPathComponent == ".build",
              root.deletingLastPathComponent() == run.appendingPathComponent("fixtures", isDirectory: true),
              UUID(uuidString: root.lastPathComponent)?.uuidString.lowercased() == root.lastPathComponent else {
            throw Failure(code: "fixtureTopology")
        }
        var path = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            path.appendPathComponent(component, isDirectory: true)
            var info = stat()
            guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure(code: "fixtureComponent") }
        }
        for directory in [root, root.appendingPathComponent("source", isDirectory: true)] {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
                throw Failure(code: "fixtureDirectory")
            }
        }
        guard try names(in: root, maximum: 2) == Set(["source", ".clipboard-publication-fixture"]),
              try names(in: root.appendingPathComponent("source", isDirectory: true), maximum: count)
                == Set((0..<count).map { "generated-\($0).dat" }) else { throw Failure(code: "fixtureInventory") }
        for (name, size) in [(".clipboard-publication-fixture", Int64(38))] {
            var info = stat()
            guard lstat(root.appendingPathComponent(name).path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_size == size else { throw Failure(code: "fixtureMarker") }
        }
        let marker = try Data(contentsOf: root.appendingPathComponent(".clipboard-publication-fixture"))
        guard marker == Data("mac-explorer-clipboard-publication-v1\n".utf8) else { throw Failure(code: "fixtureMarkerBytes") }
        for ordinal in 0..<count {
            var info = stat()
            let url = root.appendingPathComponent("source", isDirectory: true).appendingPathComponent("generated-\(ordinal).dat")
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_size == 1 else { throw Failure(code: "fixturePayload") }
        }
    }

    static func names(in url: URL, maximum: Int) throws -> Set<String> {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure(code: "fixtureOpen") }
        guard let cursor = fdopendir(descriptor) else { close(descriptor); throw Failure(code: "fixtureCursor") }
        defer { closedir(cursor) }
        var result: Set<String> = []
        while true {
            errno = 0
            guard let entry = readdir(cursor) else {
                guard errno == 0 else { throw Failure(code: "fixtureRead") }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw Failure(code: "fixtureName") }
            if name == "." || name == ".." { continue }
            guard result.count < maximum, result.insert(name).inserted else { throw Failure(code: "fixtureNodeBound") }
        }
    }

    static func emit(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }
}
