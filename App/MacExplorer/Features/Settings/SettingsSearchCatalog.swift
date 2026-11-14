import Foundation

/// A finite authored catalog, never a file/query/content index. Search text is
/// session-only and is not written to settings, diagnostics or autocomplete.
enum SettingsSearchCatalog {
    struct Entry: Sendable {
        let page: BrowserSettingsView.Page
        let terms: String
    }
    static let entries: [Entry] = [
        .init(page: .general, terms: "general community support developers donation tips reminder updates free open source gpl rename selected filename click setup personalize window startup new tabs archive zip tar folder default application search scope filter address completion visits history summaries storage analysis saved recent keep forget cache refresh changed folders full scan"),
        .init(page: .appearance, terms: "appearance interface size sizing 100 150 font light dark system glass solid transparency navigation sidebar status columns rows extensions sort focus outline motion animation full reduced off"),
        .init(page: .tools, terms: "tools editor editing defaults text code syntax language theme colors colour palette adaptive vivid monochrome swift python json jsonc javascript typescript rust shell sql toml css yaml html xml markdown wrap lines line numbers gutter font opening file type extension default app external open with indent indentation outdent backspace block blocks tab tabs windows documents separate width spaces continue return newline bracket brackets brace braces complete completion find highlights matches native icons opening indicator blue purple teal orange drives health smart monitoring live refresh interval seconds temperature benchmark"),
        .init(page: .keyboard, terms: "keyboard shortcuts explorer finder mac custom keys command control option return delete function"),
        .init(page: .operations, terms: "operations files transfers copy move conflict replace skip merge metadata recovery undo versions journal retention history progress dock queue preview archives zip tar extract paste drag always review trash delete confirmation confirm ask before moving items"),
        .init(page: .privacy, terms: "privacy private names remembrance nickname labels saved descriptions following storage forget export import support diagnostic logs"),
        .init(page: .permissions, terms: "permissions access remembered folders drives full disk sandbox network server connections sftp smb keychain")
    ]
    static func pages(matching input: String) -> [BrowserSettingsView.Page] {
        let words = normalizedWords(input)
        guard !words.isEmpty else { return BrowserSettingsView.Page.ordered }
        return entries.filter { entry in words.allSatisfy { entry.terms.contains($0) } }.map(\.page)
    }
    static func normalizedWords(_ input: String) -> [String] {
        // Read a bounded prefix without retaining a second arbitrary-size input.
        String(input.prefix(160)).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).prefix(12).map(String.init)
    }
}
