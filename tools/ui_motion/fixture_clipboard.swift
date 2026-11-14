// Metadata-only generated clipboard inspection. Never submits Copy or Paste.
// Compile with the existing repository module cache; see tools/README.md.
import AppKit
import Darwin

enum Refusal: Error { case guardFailed(String) }
func require(_ condition: Bool, _ code: String) throws {
    if !condition { throw Refusal.guardFailed(code) }
}

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL

struct FixtureIdentity: Equatable {
    let device: Int32, inode: UInt64, bytes: Int64
    let modifiedSeconds: Int, modifiedNanoseconds: Int
    let changedSeconds: Int, changedNanoseconds: Int

    init(_ file: URL, maximumBytes: UInt64 = 1 << 20) throws {
        try require(file.isFileURL && file.standardizedFileURL.path == file.path &&
            file.resolvingSymlinksInPath().path == file.path, "fixture.path")
        var observed = stat(), pinned = stat()
        try require(lstat(file.path, &observed) == 0 &&
            observed.st_mode & S_IFMT == S_IFREG && observed.st_nlink == 1 &&
            observed.st_uid == getuid(), "fixture.kind")
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try require(descriptor >= 0, "fixture.open")
        defer { close(descriptor) }
        try require(fstat(descriptor, &pinned) == 0 &&
            pinned.st_dev == observed.st_dev && pinned.st_ino == observed.st_ino &&
            pinned.st_size == observed.st_size && pinned.st_mode == observed.st_mode &&
            pinned.st_mtimespec.tv_sec == observed.st_mtimespec.tv_sec &&
            pinned.st_mtimespec.tv_nsec == observed.st_mtimespec.tv_nsec &&
            pinned.st_ctimespec.tv_sec == observed.st_ctimespec.tv_sec &&
            pinned.st_ctimespec.tv_nsec == observed.st_ctimespec.tv_nsec &&
            file.resolvingSymlinksInPath().path == file.path, "fixture.identity")
        try require(pinned.st_size >= 0 && UInt64(pinned.st_size) <= maximumBytes, "fixture.size")
        device = pinned.st_dev; inode = pinned.st_ino; bytes = pinned.st_size
        modifiedSeconds = pinned.st_mtimespec.tv_sec; modifiedNanoseconds = pinned.st_mtimespec.tv_nsec
        changedSeconds = pinned.st_ctimespec.tv_sec; changedNanoseconds = pinned.st_ctimespec.tv_nsec
    }
}

// The count check precedes every offer read. Rejected URLs are never returned,
// printed, persisted, or opened. This tool never reads a file body.
func verifyOffer(_ board: NSPasteboard, before: Int, copied: Int,
                 file: URL, identity: FixtureIdentity) throws {
    try require(copied != before && board.changeCount == copied, "clipboard.stale")
    guard let items = board.pasteboardItems, items.count == 1,
          let value = items[0].string(forType: .fileURL),
          let offered = URL(string: value), offered.isFileURL else {
        throw Refusal.guardFailed("clipboard.offer")
    }
    try require(offered.standardizedFileURL == file, "clipboard.foreign")
    guard let native = board.readObjects(forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [NSURL], native.count == 1 else {
        throw Refusal.guardFailed("clipboard.nativeOffer")
    }
    try require((native[0] as URL).standardizedFileURL == file, "clipboard.nativeForeign")
    try require(try FixtureIdentity(file) == identity, "fixture.changed")
    try require(board.changeCount == copied, "clipboard.changed")
}

// A post-Copy check is not an atomic Copy/Paste transaction. The tool never
// submits Paste: a later caller must still bind its actual generated destination
// and input. The general pasteboard is not read until its revision changes.
func checkCopiedFixture(before: Int, file: URL) throws {
    let development = repository.appendingPathComponent(".build/traverse-development/").path + "/"
    try require(file.path.hasPrefix(development), "fixture.root")
    let components = String(file.path.dropFirst(development.count)).split(separator: "/")
    try require(components.count >= 3 && UUID(uuidString: String(components[0])) != nil &&
        components[1] == "source", "fixture.source")
    let marker = URL(fileURLWithPath: development).appendingPathComponent(String(components[0]))
        .appendingPathComponent("reservation.json")
    let reservation = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any]
    try require(reservation?["packet"] as? String == "traverse-development-v1", "fixture.reservation")
    let identity = try FixtureIdentity(file)
    let board = NSPasteboard.general
    try verifyOffer(board, before: before, copied: board.changeCount, file: file, identity: identity)
    print("{\"matchingFixtureOfferObserved\":true,\"pasteSubmitted\":false,\"laterPasteNotQualified\":true}")
}

func selfCheck() throws {
    let root = repository.appendingPathComponent(".build/tmp/fixture-paste-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Expected.txt"), other = root.appendingPathComponent("Other.txt")
    try Data("generated\n".utf8).write(to: file, options: .withoutOverwriting)
    try Data("other\n".utf8).write(to: other, options: .withoutOverwriting)
    let identity = try FixtureIdentity(file)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    func reject(_ code: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch Refusal.guardFailed(let actual) {
            try require(actual == code, "selfCheck.wrongRefusal"); return
        }
        throw Refusal.guardFailed("selfCheck.acceptedUnsafeOffer")
    }
    var before = board.changeCount
    try reject("clipboard.stale") { try verifyOffer(board, before: before, copied: before, file: file, identity: identity) }
    board.clearContents(); board.writeObjects([other as NSURL])
    try reject("clipboard.foreign") { try verifyOffer(board, before: before, copied: board.changeCount, file: file, identity: identity) }
    before = board.changeCount
    board.clearContents(); board.writeObjects([file as NSURL, other as NSURL])
    try reject("clipboard.offer") { try verifyOffer(board, before: before, copied: board.changeCount, file: file, identity: identity) }
    before = board.changeCount
    board.clearContents(); board.writeObjects([file as NSURL])
    let copied = board.changeCount
    try verifyOffer(board, before: before, copied: copied, file: file, identity: identity)
    // A different writer intervenes between successive offer observations.
    board.clearContents()
    try reject("clipboard.stale") { try verifyOffer(board, before: before, copied: copied, file: file, identity: identity) }
    before = board.changeCount
    board.clearContents(); board.writeObjects([file as NSURL])
    let recopied = board.changeCount
    try verifyOffer(board, before: before, copied: recopied, file: file, identity: identity)
    try Data("changed fixture\n".utf8).write(to: file)
    try reject("fixture.changed") { try verifyOffer(board, before: before, copied: recopied, file: file, identity: identity) }
    print("{\"passed\":true,\"privatePasteboardOnly\":true,\"nativeInputNotExercised\":true}")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--self-check"] { try selfCheck() }
    else {
        try require(args.count == 3 && args[0] == "--check-after-copy", "arguments.beforeCountFixture")
        guard let before = Int(args[1]), before >= 0 else { throw Refusal.guardFailed("arguments.count") }
        try checkCopiedFixture(before: before, file: URL(fileURLWithPath: args[2]).standardizedFileURL)
    }
} catch Refusal.guardFailed(let code) {
    fputs("Fixture clipboard refused: \(code)\n", stderr); exit(1)
} catch {
    // Foundation errors can contain filenames. Keep this diagnostic closed.
    fputs("Fixture clipboard refused: native.error\n", stderr); exit(1)
}
