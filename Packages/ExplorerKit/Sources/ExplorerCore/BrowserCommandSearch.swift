import Foundation

/// Searches only the finite, app-owned command vocabulary. It accepts no file
/// provider, path resolver, model, history store or executable command string.
public enum BrowserCommandSearch {
    public enum Failure: Error, Equatable { case queryLimit, catalogLimit, duplicateCommand }
    public struct Entry: Equatable, Sendable, Identifiable {
        public let command: BrowserCommand
        public let shortcut: String
        public let enabled: Bool
        public var id: BrowserCommand { command }
        public var title: String { command.title }
        public var category: String { BrowserCommandVocabulary.category(command) }
        public init(command: BrowserCommand, shortcut: String = "", enabled: Bool = true) {
            self.command = command; self.shortcut = shortcut; self.enabled = enabled
        }
    }
    public static func matches(_ query: String, entries: [Entry], limit: Int = 20) throws -> [Entry] {
        guard entries.count <= 256, (1...20).contains(limit),
              entries.allSatisfy({ $0.shortcut.unicodeScalars.prefix(129).count <= 128
                  && !$0.shortcut.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        else { throw Failure.catalogLimit }
        guard Set(entries.map(\.command)).count == entries.count else { throw Failure.duplicateCommand }
        guard query.unicodeScalars.prefix(257).count <= 256,
              !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) })
        else { throw Failure.queryLimit }
        let needle = normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard terms.count <= 8 else { throw Failure.queryLimit }
        var found: [(Entry, Int)] = []
        for entry in entries {
            let title = normalize(entry.title), shortcut = normalize(entry.shortcut)
            let aliases = normalize(BrowserCommandVocabulary.aliases(entry.command))
            let words = title.split(whereSeparator: \.isWhitespace)
            let searchable = title + " " + aliases + " " + shortcut
            guard terms.allSatisfy(searchable.contains) else { continue }
            let rank: Int
            if needle.isEmpty { rank = 50 }
            else if title == needle || shortcut == needle { rank = 0 }
            else if title.hasPrefix(needle) { rank = 10 }
            else if terms.allSatisfy({ term in words.contains(where: { $0.hasPrefix(term) }) }) { rank = 20 }
            else if title.contains(needle) { rank = 30 }
            else { rank = 40 }
            found.append((entry, rank))
        }
        return found.sorted { left, right in
            if left.1 != right.1 { return left.1 < right.1 }
            if left.0.enabled != right.0.enabled { return left.0.enabled }
            if needle.isEmpty {
                let a = BrowserCommandVocabulary.priority(left.0.command), b = BrowserCommandVocabulary.priority(right.0.command)
                if a != b { return a < b }
            }
            return left.0.command.rawValue < right.0.command.rawValue
        }.prefix(limit).map(\.0)
    }
    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

private enum BrowserCommandVocabulary {
    static func aliases(_ command: BrowserCommand) -> String {
        switch command {
        case .storageAnalysis: "disk space usage storage chart analyze analyse"
        case .driveManagement: "devices volumes disk management partitions topology storage"
        case .driveBenchmark: "disk drive benchmark speed performance read write test storage"
        case .computer: "this mac my computer drives devices volumes"
        case .address: "go to path location folder address"
        case .splitRight: "dual pane split vertical side by side"
        case .splitBelow: "dual pane split horizontal bottom"
        case .copyToPane: "copy other pane transfer"
        case .copyNames: "copy filenames filename names selected"
        case .copyRelativePaths: "copy relative path project folder paths"
        case .moveToPane: "move other pane transfer"
        case .moveOnServer: "move remote smb server folder destination transfer"
        case .copyOnServer: "copy duplicate remote smb server folder destination"
        case .namesAndLabels: "nickname alias tags labels remember"
        case .rememberedItems: "private names labels library nicknames aliases"
        case .connectServer: "smb sftp ssh network connect connection"
        case .disconnectServer: "smb sftp network disconnect connection"
        case .launchProfiles, .switchLaunchProfile: "startup layouts workspace profiles"
        case .createZIP: "compress archive zip pack"
        case .extractArchive: "unzip archive extract unpack"
        case .browseArchive: "archive zip explore compressed"
        case .batchRename: "bulk multiple rename"
        case .newFolderWithSelection: "group organize organise move selection new folder"
        case .newTextFile: "new create text document file empty editor"
        case .editText: "edit text code source editor mini ide syntax save"
        case .sendViaAirDrop: "share nearby send airdrop apple devices"
        case .duplicate: "copy duplicate numbered"
        case .queue: "queue jobs transfers"
        case .recovery: "history unfinished recovery recover"
        case .openTrash: "open deleted items bin restore trash"
        case .results: "history latest operation outcome results"
        case .undo: "undo restore reverse"
        case .rememberFolder: "folder access permission choose remember"
        case .pinFolder: "favorite favourites favorites sidebar pin bookmark"
        case .hiddenFiles: "hidden dotfiles invisible"
        case .previewPane: "preview quick look inspector"
        default: ""
        }
    }
    static func category(_ command: BrowserCommand) -> String {
        switch command {
        case .newTab, .closeTab, .duplicateTab, .reopenTab, .tabLeft, .tabRight, .nextTab, .previousTab,
             .splitRight, .splitBelow, .closePane, .nextPane, .launchProfiles, .switchLaunchProfile: "Workspace"
        case .connectServer, .disconnectServer, .moveOnServer, .copyOnServer: "Connections"
        case .storageAnalysis, .drives, .driveManagement, .driveBenchmark: "Storage"
        case .namesAndLabels, .rememberedItems: "Private names"
        case .back, .forward, .up, .computer, .home, .refresh, .address, .filter, .search,
             .directFilter, .searchFolder, .searchThisMac: "Navigation"
        case .hiddenFiles, .pathBar, .compactRows, .extensions, .foldersFirst, .details, .list, .icons, .previewPane: "View"
        default: "Files and actions"
        }
    }
    static func priority(_ command: BrowserCommand) -> Int {
        [.newTab, .splitRight, .copyToPane, .storageAnalysis, .connectServer, .namesAndLabels, .switchLaunchProfile, .queue]
            .firstIndex(of: command) ?? 100
    }
}
