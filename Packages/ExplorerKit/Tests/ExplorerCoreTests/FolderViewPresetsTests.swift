import Foundation
import Testing
@testable import ExplorerCore

struct FolderViewPresetsTests {
    private let one = FolderViewChoice(mode: .icons, sort: .init(field: .size, ascending: false, foldersFirst: false))
    private let two = FolderViewChoice(mode: .details, sort: .init(field: .modified))

    @Test func explicitSaveUpdateForgetAndRoundTripHaveNoBrowsingHistory() throws {
        var library = FolderViewPresets(); let first = library.revision
        try library.save(path: "/generated/Photos", choice: one)
        let id = try #require(library.record(for: "/generated/Photos")?.id)
        #expect(library.revision != first && library.records.count == 1)
        try library.save(path: "/generated/Photos", choice: two)
        #expect(library.record(for: "/generated/Photos")?.id == id)
        #expect(library.record(for: "/generated/Photos")?.choice == two)
        let data = try JSONEncoder().encode(library), decoded = try JSONDecoder().decode(FolderViewPresets.self, from: data)
        try decoded.validate(); #expect(decoded == library)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(fields.keys) == ["version", "revision", "records"])
        try library.forget(id); #expect(library.records.isEmpty)
        #expect(throws: FolderViewPresets.Failure.self) { try library.forget(id) }
    }
    @Test func exactKeysSeparateCaseUnicodeSpellingAndParentFromDescendant() throws {
        var library = FolderViewPresets()
        for path in ["/generated/A", "/generated/a", "/generated/caf\u{e9}", "/generated/cafe\u{301}"] { try library.save(path: path, choice: one) }
        #expect(library.records.count == 4)
        #expect(library.record(for: "/generated/A/Child") == nil)
        #expect(library.record(for: "/generated") == nil)
    }
    @Test func invalidLocationsNeverBecomeRulesOrResolveFilesystemPaths() {
        for path in ["", "relative", "file:///generated", "/generated/", "/generated//a", "/generated/../a", "/./a", "/a\0b", "/" + String(repeating: "x", count: 4096)] {
            #expect(throws: FolderViewPresets.Failure.self) { var library = FolderViewPresets(); try library.save(path: path, choice: one) }
        }
    }
    @Test func rootAndLiteralSymbolsAreValidWithoutAnyFileAccess() throws {
        var library = FolderViewPresets()
        for path in ["/", "/not-present/Photos #1", "/not-present/%20", "/not-present/with\nnewline"] { try library.save(path: path, choice: one) }
        #expect(library.records.count == 4)
    }
    @Test func recordLimitAllowsUpdatesAndForgetReleasesOneSlot() throws {
        var library = FolderViewPresets()
        for index in 0..<512 { try library.save(path: "/generated/\(index)", choice: one) }
        #expect(throws: FolderViewPresets.Failure.self) { try library.save(path: "/generated/overflow", choice: one) }
        try library.save(path: "/generated/0", choice: two)
        try library.forget(try #require(library.records.last?.id))
        try library.save(path: "/generated/after-forget", choice: two)
        #expect(library.records.count == 512)
        library.forgetAll(); #expect(library.records.isEmpty)
    }
    @Test func incompatibleMalformedOrDuplicateRulesAreRefused() throws {
        var library = FolderViewPresets(); try library.save(path: "/generated", choice: one)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as? [String: Any])
        object["version"] = 2
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(FolderViewPresets.self, from: JSONSerialization.data(withJSONObject: object)) }
        object["version"] = 1
        let records = try #require(object["records"] as? [[String: Any]]); object["records"] = records + records
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(FolderViewPresets.self, from: JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func rejectedMutationLeavesTheAlreadyValidatedValueUnchanged() throws {
        var library = FolderViewPresets(); try library.save(path: "/generated/A", choice: one)
        let before = library
        #expect(throws: FolderViewPresets.Failure.self) { try library.save(path: "relative", choice: two) }
        #expect(library == before)
        try library.validate()
    }
    @Test func viewModeRawValuesRetainExistingSettingsCompatibility() throws {
        for mode in DirectoryViewMode.allCases {
            let legacy = Data(("\"" + mode.rawValue + "\"").utf8)
            #expect(try JSONDecoder().decode(DirectoryViewMode.self, from: legacy) == mode)
        }
        #expect(DirectoryViewMode.allCases.map(\.rawValue) == ["Details", "List", "Icons"])
    }
    @Test func visitsRetainIndependentModesAndSortAndFreshNavigationIsUnresolved() {
        var tab = BrowserTab(location: .directory(URL(fileURLWithPath: "/generated/A")))
        #expect(!tab.folderViewResolved && tab.presentationMode == nil)
        tab.resolveFolderView(mode: one.mode, sort: one.sort)
        tab.navigate(to: .directory(URL(fileURLWithPath: "/generated/B")))
        #expect(!tab.folderViewResolved && tab.presentationMode == nil)
        tab.resolveFolderView(mode: two.mode, sort: two.sort)
        tab.goBack(); #expect(tab.presentationMode == one.mode && tab.sort == one.sort && tab.folderViewResolved)
        tab.goForward(); #expect(tab.presentationMode == two.mode && tab.sort == two.sort)
        let transferred = tab; #expect(transferred.presentationMode == .details)
    }
    @Test func resolvingNoSavedDefaultDoesNotInventAnExplicitMode() {
        var tab = BrowserTab(); tab.resolveFolderView()
        #expect(tab.folderViewResolved && tab.presentationMode == nil)
        tab.navigate(to: .directory(URL(fileURLWithPath: "/missing")))
        #expect(!tab.folderViewResolved)
        tab.resolveFolderView(sort: one.sort)
        #expect(tab.sort == one.sort && tab.presentationMode == nil)
    }
}
