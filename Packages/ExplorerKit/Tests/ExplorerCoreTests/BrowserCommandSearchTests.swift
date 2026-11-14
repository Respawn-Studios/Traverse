import Testing
@testable import ExplorerCore

@Suite struct BrowserCommandSearchTests {
    private var catalog: [BrowserCommandSearch.Entry] { BrowserCommand.allCases.map { .init(command: $0) } }
    @Test func plainLanguageAliasesAndNormalization() throws {
        #expect(try BrowserCommandSearch.matches("disk usage", entries: catalog).first?.command == .storageAnalysis)
        #expect(try BrowserCommandSearch.matches("nicknames", entries: catalog).contains { $0.command == .rememberedItems })
        #expect(try BrowserCommandSearch.matches("ＳＰＬＩＴ RIGHT", entries: catalog).first?.command == .splitRight)
        #expect(try BrowserCommandSearch.matches("Ánalyze", entries: catalog).contains { $0.command == .storageAnalysis })
        #expect(try BrowserCommandSearch.matches("unzip", entries: catalog).first?.command == .extractArchive)
        #expect(try BrowserCommandSearch.matches("deleted items", entries: catalog).first?.command == .openTrash)
        #expect(try BrowserCommandSearch.matches("Traverse Trash", entries: catalog).first?.command == .openTrash)
    }
    @Test func rankingIsStableAndAvailabilityIsPreserved() throws {
        let values: [BrowserCommandSearch.Entry] = [.init(command: .copy, enabled: false), .init(command: .copyToPane), .init(command: .copyPath)]
        let direct = try BrowserCommandSearch.matches("Copy Files", entries: values)
        #expect(direct.first?.command == .copy && direct.first?.enabled == false)
        #expect(try BrowserCommandSearch.matches("copy", entries: values) == BrowserCommandSearch.matches("copy", entries: values.reversed()))
        #expect(try BrowserCommandSearch.matches("", entries: catalog).count == 20)
        #expect(try BrowserCommandSearch.matches("nonexistent command", entries: catalog).isEmpty)
    }
    @Test func currentShortcutCanBeFoundWithoutFileSearch() throws {
        let value = BrowserCommandSearch.Entry(command: .newTab, shortcut: "⌘T")
        #expect(try BrowserCommandSearch.matches("⌘t", entries: [value]) == [value])
        #expect(try BrowserCommandSearch.matches("~/Documents", entries: catalog).isEmpty)
        #expect(try BrowserCommandSearch.matches("smb sftp", entries: catalog).contains { $0.command == .connectServer })
    }
    @Test func boundedInputAndUniqueFiniteCatalog() throws {
        #expect(throws: BrowserCommandSearch.Failure.queryLimit) { try BrowserCommandSearch.matches(String(repeating: "a", count: 257), entries: catalog) }
        #expect(throws: BrowserCommandSearch.Failure.queryLimit) { try BrowserCommandSearch.matches("a b c d e f g h i", entries: catalog) }
        #expect(throws: BrowserCommandSearch.Failure.queryLimit) { try BrowserCommandSearch.matches("copy\0", entries: catalog) }
        #expect(throws: BrowserCommandSearch.Failure.catalogLimit) { try BrowserCommandSearch.matches("", entries: catalog, limit: 21) }
        #expect(throws: BrowserCommandSearch.Failure.catalogLimit) { try BrowserCommandSearch.matches("", entries: [.init(command: .copy, shortcut: String(repeating: "x", count: 129))]) }
        #expect(throws: BrowserCommandSearch.Failure.catalogLimit) { try BrowserCommandSearch.matches("", entries: [.init(command: .copy, shortcut: "⌘\0")]) }
        #expect(throws: BrowserCommandSearch.Failure.duplicateCommand) { try BrowserCommandSearch.matches("", entries: [.init(command: .copy), .init(command: .copy)]) }
    }
}
