import AppKit

/// Native publication provenance only; never filesystem or access authority.
@MainActor
enum BrowserClipboard {
    enum Publication {
        case files(FilePublication)
        case unownedFiles(NativeFilePublication)
        case text
        case failed
    }

    struct FilePublication {
        fileprivate let board: NSPasteboard
        fileprivate let name: NSPasteboard.Name
        let changeCount: Int
        let urls: [URL]

        func isCurrent(on candidate: NSPasteboard) -> Bool {
            board === candidate && name == candidate.name && changeCount == candidate.changeCount
        }
    }

    /// Successful native publication with no retained URL array or owned fast path.
    struct NativeFilePublication {
        fileprivate let board: NSPasteboard
        fileprivate let name: NSPasteboard.Name
        let changeCount: Int

        func isCurrent(on candidate: NSPasteboard) -> Bool {
            board === candidate && name == candidate.name && changeCount == candidate.changeCount
        }
    }

    struct FileRead {
        fileprivate let board: NSPasteboard
        fileprivate let name: NSPasteboard.Name
        let changeCount: Int
        let urls: [URL]

        func isCurrent(on candidate: NSPasteboard) -> Bool {
            board === candidate && name == candidate.name && changeCount == candidate.changeCount
        }
    }

    struct OwnedCopy {
        let publication: FilePublication
        let revision: UUID
        let feedbackID: UUID

        func read(from board: NSPasteboard, revision: UUID, feedbackID: UUID?) -> FileRead? {
            guard revision == self.revision, feedbackID == self.feedbackID,
                  publication.isCurrent(on: board) else { return nil }
            return FileRead(board: board, name: publication.name, changeCount: publication.changeCount,
                            urls: publication.urls)
        }
    }

    /// Compatibility primitive for direct native controls and external fixtures.
    /// Its return remains the native Bool, independent of receipt eligibility.
    @discardableResult
    static func write(_ text: String?, urls: [URL], to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return nativeWrite(text, urls: urls, to: pasteboard)
    }

    static func publish(_ text: String?, urls: [URL], to pasteboard: NSPasteboard = .general) -> Publication {
        publication(text, urls: urls, to: pasteboard, afterClear: nil, afterWrite: nil, failWrite: false)
    }

    static func readFiles(from board: NSPasteboard, isCurrent: () -> Bool) -> FileRead? {
        captureFiles(from: board, isCurrent: isCurrent, decode: nativeRead)
    }

    private static func nativeWrite(_ text: String?, urls: [URL], to board: NSPasteboard) -> Bool {
        if let text { return board.setString(text, forType: .string) }
        return board.writeObjects(urls.map { $0 as NSURL })
    }

    private static func nativeRead(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [NSURL])?.map { $0 as URL } ?? []
    }

    private static func publication(_ text: String?, urls: [URL], to board: NSPasteboard,
                                    afterClear: ((NSPasteboard) -> Void)?,
                                    afterWrite: ((NSPasteboard) -> Void)?,
                                    failWrite: Bool) -> Publication {
        // Validate before clearing: rejected input must preserve the native board.
        guard text != nil || (!urls.isEmpty && urls.allSatisfy(\.isFileURL)) else { return .failed }
        let generation = board.clearContents()
        afterClear?(board)
        guard board.changeCount == generation else { return .failed }
        let success = !failWrite && nativeWrite(text, urls: urls, to: board)
        afterWrite?(board)
        guard success, board.changeCount == generation else { return .failed }
        if text != nil { return .text }
        // Preserve native Copy-to-other-app behavior beyond the cache bound.
        guard urls.count <= 1024 else {
            return .unownedFiles(NativeFilePublication(board: board, name: board.name, changeCount: generation))
        }
        return .files(FilePublication(board: board, name: board.name, changeCount: generation, urls: urls))
    }

    private static func captureFiles(from board: NSPasteboard, isCurrent: () -> Bool,
                                     decode: (NSPasteboard) -> [URL]) -> FileRead? {
        let generation = board.changeCount
        let name = board.name
        guard isCurrent() else { return nil }
        let urls = decode(board)
        guard isCurrent(), board.name == name, board.changeCount == generation, isCurrent() else { return nil }
        return FileRead(board: board, name: name, changeCount: generation, urls: urls)
    }

    #if DEBUG
    // Per-call deterministic seams. No global interceptor or native swizzling.
    static func publishForVerification(_ text: String?, urls: [URL], to board: NSPasteboard,
                                       afterClear: ((NSPasteboard) -> Void)? = nil,
                                       afterWrite: ((NSPasteboard) -> Void)? = nil,
                                       failWrite: Bool = false) -> Publication {
        publication(text, urls: urls, to: board, afterClear: afterClear,
                    afterWrite: afterWrite, failWrite: failWrite)
    }

    static func readFilesForVerification(from board: NSPasteboard, isCurrent: () -> Bool,
                                        decode: (NSPasteboard) -> [URL]) -> FileRead? {
        captureFiles(from: board, isCurrent: isCurrent, decode: decode)
    }
    #endif
}
