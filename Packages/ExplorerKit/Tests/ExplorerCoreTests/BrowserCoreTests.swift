import ExplorerCore
import Foundation
import Testing

private func folder(_ path: String) -> BrowserLocation { .directory(URL(fileURLWithPath: path)) }
private func entry(_ name: String, kind: FileKind = .file, size: Int64? = nil) -> FileEntry {
    FileEntry(url: URL(fileURLWithPath: "/fixture/" + name), name: name, kind: kind, byteCount: size)
}

@Test func historyRestoresEachVisitsViewState() {
    var tab = BrowserTab()
    tab.navigate(to: folder("/fixture/a"))
    let selected = URL(fileURLWithPath: "/fixture/a/selected")
    tab.state = NavigationState(selection: [selected], scrollOffset: 81)
    tab.sort = DirectorySort(field: .size, ascending: false)
    tab.filter = "chosen"
    tab.navigate(to: folder("/fixture/b"))
    #expect(tab.state == NavigationState())
    #expect(tab.filter.isEmpty)
    #expect(tab.sort.field == .size)
    tab.state.scrollOffset = 42
    tab.goBack()
    #expect(tab.location == folder("/fixture/a"))
    #expect(tab.state == NavigationState(selection: [selected], scrollOffset: 81))
    #expect(tab.filter == "chosen")
    #expect(tab.sort == DirectorySort(field: .size, ascending: false))
    tab.goForward()
    #expect(tab.state.scrollOffset == 42)
}

@Test func navigationTruncatesForwardBranchAndIgnoresDuplicate() {
    var tab = BrowserTab()
    tab.navigate(to: folder("/fixture/a"))
    tab.navigate(to: folder("/fixture/b"))
    tab.goBack()
    tab.navigate(to: folder("/fixture/a"))
    #expect(tab.canGoForward)
    tab.navigate(to: folder("/fixture/c"))
    #expect(!tab.canGoForward)
    tab.goBack()
    #expect(tab.location == folder("/fixture/a"))
    tab.goBack()
    tab.goBack()
    #expect(tab.location == .computer)
    #expect(!tab.canGoBack)
}

@Test func independentTabsAndUpNavigation() {
    var first = BrowserTab(location: folder("/fixture/a"))
    let second = BrowserTab(location: folder("/fixture/a"))
    #expect(first.id != second.id)
    first.state.scrollOffset = 100
    first.filter = "one"
    first.goUp()
    #expect(first.location == folder("/fixture"))
    #expect(second.location == folder("/fixture/a"))
    #expect(second.state.scrollOffset == 0)
    #expect(second.filter.isEmpty)
    #expect(folder("/").parent == .computer)
    #expect(folder("/Volumes/Fixture").parent == .computer)
    #expect(BrowserLocation.computer.parent == nil)
}

@Test func naturalSortingKeepsFoldersFirstBothDirections() {
    let items = [entry("file10"), entry("file2"), entry("z-folder", kind: .directory), entry("a.app", kind: .package)]
    let ascending = orderedEntries(items, sort: DirectorySort())
    #expect(ascending.map(\.name) == ["z-folder", "a.app", "file2", "file10"])
    let descending = orderedEntries(items, sort: DirectorySort(ascending: false))
    #expect(descending.map(\.name) == ["z-folder", "file10", "file2", "a.app"])
}

@Test func caseSensitiveTiesAndUnknownMetadataAreDeterministic() {
    let items = [entry("alpha", size: 3), entry("Alpha", size: 3), entry("unknown")]
    let sort = DirectorySort(field: .size)
    let expected = ["Alpha", "alpha", "unknown"]
    #expect(orderedEntries(items, sort: sort).map(\.name) == expected)
    #expect(orderedEntries(items.reversed(), sort: sort).map(\.name) == expected)
    #expect(orderedEntries(items, sort: DirectorySort(field: .size, ascending: false)).last?.name == "unknown")
}

@Test func filterUsesOnlyNamesAndHandlesUnicode() {
    let items = [entry("Café.txt"), entry("CAFETERIA"), entry("unrelated")]
    #expect(Set(orderedEntries(items, sort: DirectorySort(), filter: "cafe").map(\.name)) == ["Café.txt", "CAFETERIA"])
    #expect(orderedEntries(items, sort: DirectorySort(), filter: "/fixture").isEmpty)
}

@Test func modifiedAndKindSortingUseDeterministicNameTies() {
    let old = FileEntry(url: URL(fileURLWithPath: "/fixture/old"), name: "old", kind: .file,
                        modifiedAt: Date(timeIntervalSince1970: 1))
    let recent = FileEntry(url: URL(fileURLWithPath: "/fixture/recent"), name: "recent", kind: .file,
                           modifiedAt: Date(timeIntervalSince1970: 2))
    let unknown = entry("unknown")
    #expect(orderedEntries([recent, unknown, old], sort: DirectorySort(field: .modified)).map(\.name)
            == ["old", "recent", "unknown"])
    #expect(orderedEntries([old, unknown, recent], sort: DirectorySort(field: .modified, ascending: false)).map(\.name)
            == ["recent", "old", "unknown"])
    let kinds = [entry("link", kind: .symbolicLink), entry("z"), entry("a")]
    #expect(orderedEntries(kinds, sort: DirectorySort(field: .kind)).map(\.name) == ["a", "z", "link"])
}

@Test func directoryHintsAndLexicalAliasesDoNotDuplicateVisits() {
    let plain = BrowserLocation.directory(URL(fileURLWithPath: "/fixture/a", isDirectory: false))
    let hinted = BrowserLocation.directory(URL(fileURLWithPath: "/fixture/a", isDirectory: true))
    let lexical = BrowserLocation.directory(URL(fileURLWithPath: "/fixture/./a"))
    #expect(plain == hinted)
    #expect(plain == lexical)
    #expect(Set([plain, hinted, lexical]).count == 1)
    #expect(plain != folder("/fixture/A"))
    #expect(folder("/fixture/..") == folder("/"))
    var tab = BrowserTab(location: plain)
    tab.navigate(to: hinted)
    #expect(!tab.canGoBack)
}

@Test func kindSortingGroupsFileExtensionsCaseInsensitively() {
    let items = [entry("a.txt"), entry("z.pdf"), entry("b.PDF"), entry("z.TXT"), entry("folder", kind: .directory)]
    #expect(orderedEntries(items, sort: DirectorySort(field: .kind)).map(\.name)
            == ["folder", "b.PDF", "z.pdf", "a.txt", "z.TXT"])
    #expect(orderedEntries(items.reversed(), sort: DirectorySort(field: .kind)).map(\.name)
            == ["folder", "b.PDF", "z.pdf", "a.txt", "z.TXT"])
    #expect(orderedEntries(items, sort: DirectorySort(field: .kind, ascending: false)).map(\.name)
            == ["folder", "z.TXT", "a.txt", "z.pdf", "b.PDF"])
}

@Test func createdAndAccessedSortKeepUnknownLastAndDeterministicTies() {
    let early = Date(timeIntervalSince1970: 1)
    let late = Date(timeIntervalSince1970: 2)
    let items = [
        FileEntry(url: URL(fileURLWithPath: "/fixture/z"), name: "z", kind: .file, createdAt: early, accessedAt: late),
        FileEntry(url: URL(fileURLWithPath: "/fixture/A"), name: "A", kind: .file, createdAt: late, accessedAt: early),
        FileEntry(url: URL(fileURLWithPath: "/fixture/a"), name: "a", kind: .file, createdAt: late, accessedAt: early),
        entry("unknown"), entry("folder", kind: .directory),
    ]
    for (field, ascending, descending) in [
        (SortField.created, ["folder", "z", "A", "a", "unknown"], ["folder", "a", "A", "z", "unknown"]),
        (.accessed, ["folder", "A", "a", "z", "unknown"], ["folder", "z", "a", "A", "unknown"]),
    ] {
        #expect(orderedEntries(items, sort: DirectorySort(field: field)).map(\.name) == ascending)
        #expect(orderedEntries(items.reversed(), sort: DirectorySort(field: field)).map(\.name) == ascending)
        #expect(orderedEntries(items, sort: DirectorySort(field: field, ascending: false)).map(\.name) == descending)
        #expect(orderedEntries(items, sort: DirectorySort(field: field, foldersFirst: false)).suffix(2).allSatisfy {
            $0.name == "folder" || $0.name == "unknown"
        })
    }
    #expect(entry("legacy").createdAt == nil)
    #expect(entry("legacy").accessedAt == nil)
}

@Test func extensionSortMatchesLexicalDisplayAndKeepsMissingSuffixLast() {
    let items = [entry("a.txt"), entry("z.PDF"), entry("b.pdf"), entry("Example.app", kind: .package),
                 entry("link.ZIP", kind: .symbolicLink), entry("Folder.pdf", kind: .directory),
                 entry("README"), entry(".hidden")]
    #expect(items.first { $0.name == "z.PDF" }?.filenameExtension == "PDF")
    #expect(items.first { $0.kind == .directory }?.filenameExtension == nil)
    #expect(items.first { $0.kind == .package }?.filenameExtension == "app")
    #expect(items.first { $0.kind == .symbolicLink }?.filenameExtension == "ZIP")
    #expect(entry(".hidden").filenameExtension == nil)
    let ascending = ["Folder.pdf", "Example.app", "b.pdf", "z.PDF", "a.txt", "link.ZIP", ".hidden", "README"]
    #expect(orderedEntries(items, sort: DirectorySort(field: .extension)).map(\.name) == ascending)
    #expect(orderedEntries(items.reversed(), sort: DirectorySort(field: .extension)).map(\.name) == ascending)
    #expect(orderedEntries(items, sort: DirectorySort(field: .extension, ascending: false)).map(\.name)
        == ["Folder.pdf", "link.ZIP", "a.txt", "z.PDF", "b.pdf", "Example.app", "README", ".hidden"])
    #expect(orderedEntries(items, sort: DirectorySort(field: .extension, ascending: false, foldersFirst: false))
        .suffix(3).allSatisfy { $0.filenameExtension == nil })
    let distinct = [entry("a.app"), entry("b.PDF"), entry("c.txt"), entry("d.ZIP")]
    for left in distinct {
        for right in distinct where left != right {
            let expected = [left, right].sorted { $0.filenameExtension!.lowercased() < $1.filenameExtension!.lowercased() }
            #expect(orderedEntries([left, right], sort: DirectorySort(field: .extension)) == expected)
            #expect(orderedEntries([right, left], sort: DirectorySort(field: .extension)) == expected)
        }
    }
}

@Test func archiveAddressPreservesItsSourceAndResolvesOnlyVirtualDescendants() throws {
    let source = URL(fileURLWithPath: "/fixture/Café Review.zip")
    for format in ArchiveFormat.allCases {
        let root = try ArchiveLocation(source: source, format: format)
        let deep = try ArchiveLocation(source: source, format: format, folderPath: ["Folder", "Deep"])
        #expect(deep.editablePath == source.path + "/Folder/Deep")
        #expect(try root.resolvingAddress(deep.editablePath) == deep)
        #expect(try deep.resolvingAddress(source.path + "/") == root)
        #expect(try deep.resolvingAddress("../日本語/./")?.folderPath == ["Folder", "日本語"])
        #expect(try root.resolvingAddress("Folder//Deep/") == deep)
        #expect(try deep.resolvingAddress("../../") == root)
        #expect(try root.resolvingAddress("%2e%2e")?.folderPath == ["%2e%2e"])
        for local in ["/fixture/Elsewhere", "~/Downloads", "~", "This Mac"] {
            #expect(try deep.resolvingAddress(local) == nil)
        }
        #expect(throws: ArchiveNavigationFailure.invalidFolderPath) { try root.resolvingAddress("../Elsewhere") }
        #expect(throws: ArchiveNavigationFailure.invalidFolderPath) { try deep.resolvingAddress("../../../") }
        #expect(throws: ArchiveNavigationFailure.invalidFolderPath) { try deep.resolvingAddress("bad\nfolder") }
        #expect(throws: ArchiveNavigationFailure.invalidFolderPath) { try root.resolvingAddress("C:/Other") }
    }
}
