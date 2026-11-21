import Foundation
import ExplorerCore
import SwiftUI

/// The catalog describes controls and sections that can be revealed in the
/// form. Queries and results exist only while the Settings window is open.
enum SettingsSearchCatalog {
    typealias Page = BrowserSettingsView.Page

    struct Anchor: Hashable, Sendable {
        let page: Page
        let key: String
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id: Anchor
        let section: String
        let title: String
        let aliases: String
        var shortcut: BrowserCommand? = nil
        var page: Page { id.page }
        var revealAnchor: Anchor { shortcut == nil ? id : .init(page: .keyboard, key: SettingsSearchCatalog.shortcutEditorKey) }
    }

    static let shortcutEditorKey = "Custom shortcuts"

    private static func controls(_ page: Page, _ section: String, _ names: [String],
                                 aliases: [String: String] = [:]) -> [Entry] {
        names.map { .init(id: .init(page: page, key: $0), section: section, title: $0, aliases: aliases[$0] ?? "") }
    }

    static func openingKey(for type: EditorOpeningSupport.FileType) -> String { "opening-" + type.fileExtension }

    private static func openingEntry(_ type: EditorOpeningSupport.FileType) -> Entry {
        .init(id: .init(page: .tools, key: openingKey(for: type)), section: "Open Files With",
              title: type.title, aliases: type.matchLabel + " open with external file type")
    }

    static let entries: [Entry] = [
        controls(.general, "Setup", ["Default Folder App", "Personalize Traverse…", "Manage Permissions & Folder Access…"],
                 aliases: ["Default Folder App": "Finder system integration choose default application"]),
        controls(.general, "Crash Reports", ["Capture crashes locally on next launch", "Crash Reports & Feedback…"],
                 aliases: ["Crash Reports & Feedback…": "diagnostics logs support report GitHub"]),
        controls(.general, "Community", ["Show support message after updates"],
                 aliases: ["Show support message after updates": "donation tip developers update reminder"]),
        controls(.general, "Window", ["Open supported archives in Traverse", "New tabs open", "Click a selected filename to rename",
            "Show menus in the window title bar", "Finder-style bottom address", "Show Open Terminal in the navigation bar",
            "Show Git tools in local repositories", "Show Git badges in file lists and icons", "Compare selected files with",
            "Show Eject buttons beside external drives", "Show Eject Buttons on All Drives", "Show quick drive controls in the status bar",
            "Start with", "Launch Profiles…"],
                 aliases: ["Open supported archives in Traverse": "zip tar gz bzip2 browse archive",
                    "Compare selected files with": "diff external Kaleidoscope Beyond VSCode Visual Studio Code FileMerge Xcode",
                    "Show Eject Buttons on All Drives": "restore reset hidden eject volume buttons",
                    "Finder-style bottom address": "breadcrumbs path bar", "Start with": "startup restore recent workspace session"]),
        controls(.general, "Search", ["Default search sources", "Suggest saved folder names in the address bar",
            "Document following", "Treat spaces, hyphens and underscores as equivalent", "Open System Settings…", "Default folder scope"],
                 aliases: ["Default folder scope": "indexed search spotlight loaded items",
                    "Document following": "remember file move native flags",
                    "Open System Settings…": "Spotlight indexing privacy", "Treat spaces, hyphens and underscores as equivalent": "symbol tolerant filename"]),
        controls(.general, "Address Suggestions", ["Show suggestions", "Dropdown limit", "Improve suggestions using folder visits",
            "Visit history size", "Visit history retention", "Clear Visit History"],
                 aliases: ["Show suggestions": "address completion dropdown autocomplete inline", "Dropdown limit": "number of suggestions results",
                    "Visit history size": "keep folders history count", "Visit history retention": "forget visits after days expiry"]),
        controls(.general, "Folder Summaries and Storage", ["Keep recent analyses on this Mac", "Forget Saved Analyses",
            "Repair Saved Analyses", "Refresh changed folders when possible", "Storage chart style", "Include application data by default in explicit scans",
            "Clear Location Choices", "Analysis folder picker", "Show folder summaries on hover", "Hover delay",
            "Clear Cached Folder Summaries", "Inspect Traverse Storage…"],
                 aliases: ["Storage chart style": "Analyzer pie rings bar", "Refresh changed folders when possible": "Analyzer incremental full scan",
                    "Hover delay": "folders summaries timing tooltip wait seconds"]),
        controls(.general, "Files and Folders", ["Refresh open folders when their contents change", "Show hidden files and folders",
            "Show filename extensions", "Show thumbnails in Icons view", "Folders first by default"],
            aliases: ["Show hidden files and folders": "dotfiles invisible", "Show thumbnails in Icons view": "image pdf previews tiles"]),
        controls(.appearance, "Appearance", ["Theme", "Surface style", "Glass navigation", "Glass sidebar", "Glass status bar",
            "Translucent file content (Experimental)", "Interface size"], aliases: ["Theme": "light dark system appearance", "Surface style": "glass solid transparency",
                "Interface size": "scale interface zoom font size 100 150"]),
        controls(.appearance, "File List", ["Default view", "Details/List row spacing"],
                 aliases: ["Default view": "details list icons columns", "Details/List row spacing": "compact density height rows"]),
        controls(.appearance, "Motion", ["Animations"] + BrowserMotionEffect.allCases.map(\.rawValue),
                 aliases: ["Animations": "animation reduced motion full off transitions fade speed"]),
        controls(.appearance, "Active Pane", ["Focus indication", "Outline thickness", "Outline color", "Show Active pane caption"],
                 aliases: ["Focus indication": "active pane focus halo border accent"]),
        controls(.tools, "Drives", ["Live SMART readings while Drives is visible", "Update readings every"],
                 aliases: ["Live SMART readings while Drives is visible": "health monitor temperature benchmark", "Update readings every": "smart refresh interval seconds"]),
        controls(.tools, "Editor Defaults", ["Open documents in", "Show the Files sidebar in new local editors", "Include generated folders in project searches",
            "Highlight on-disk changes in Git projects", "Wrap lines", "Show line numbers", "Show indent guides", "Highlight matching brackets",
            "Show whitespace marks", "Mark unsaved lines", "Show scope while scrolling", "Show JSON issues while editing",
            "Link scrolling in new text comparisons",
            "Text size", "Indent width", "Indent using", "Continue line indentation", "Backspace removes one indent level",
            "Indent code blocks on Return", "Indent JSON blocks on Return", "Complete JSON brackets", "Complete code brackets",
            "Suggest local names inline"],
                 aliases: ["Open documents in": "editor tabs separate windows", "Show line numbers": "editor gutter",
                    "Wrap lines": "word wrap text", "Indent width": "tab width columns spaces", "Indent using": "spaces tabs insertion",
                    "Indent code blocks on Return": "smart indentation newline braces python swift rust",
                    "Indent JSON blocks on Return": "newline smart brace jsonc indentation", "Complete JSON brackets": "bracket completion brace pair jsonc",
                    "Complete code brackets": "bracket completion parentheses braces",
                    "Suggest local names inline": "code autocomplete local name suggestion tab"]),
        controls(.tools, "Syntax & Theme", ["Editor theme", "Syntax colors", "Default syntax", "Detect language in files without an extension", "Find highlight"],
                 aliases: ["Syntax colors": "syntax color palette adaptive vivid monochrome", "Default syntax": "language swift python json jsonc javascript typescript rust shell sql toml css yaml html xml markdown",
                    "Find highlight": "search match colors accent blue purple teal orange"]),
        controls(.tools, "Open Files With", ["Open Files With", "Additional File Types", "File icons"],
                 aliases: ["Open Files With": "file type extension external default app system macos launch", "File icons": "native icon opening indicator"]),
        EditorOpeningSupport.fileTypes.map(openingEntry),
        controls(.keyboard, "File-browser Keyboard", ["Preset", "Customize These Choices", "Return", "Backspace goes back",
            "Control shortcut aliases", "Explorer function keys and Delete", "Reset All Custom Choices to Explorer"],
                 aliases: ["Preset": "keyboard shortcuts mac explorer windows custom mode",
                    "Explorer function keys and Delete": "F2 F4 F5 F6 rename address refresh focus trash"]),
        controls(.keyboard, "Custom Shortcuts", [shortcutEditorKey], aliases: [shortcutEditorKey: "key bindings remap commands conflict find action hotkey"]),
        controls(.operations, "Trash", ["Ask before moving items to Trash"], aliases: ["Ask before moving items to Trash": "trash confirmation delete prompt"]),
        controls(.operations, "Copy and Cross-volume Move", ["Preview faster Copy", "Metadata"], aliases: ["Metadata": "file properties preserve strict usb copy transfer"]),
        controls(.operations, "Archives", ["Quick Compress format", "Always review archive copies"],
                 aliases: ["Quick Compress format": "zip tar gzip bzip2 compression", "Always review archive copies": "archive export extract confirmation"]),
        controls(.operations, "Existing Names", ["Files", "Folders"], aliases: ["Files": "conflict overwrite replace skip copy names", "Folders": "conflict merge replace skip copy names"]),
        controls(.operations, "Drives", ["While eject is waiting"], aliases: ["While eject is waiting": "operation safe eject usb external drive new work"]),
        controls(.operations, "Progress", ["Progress indicator", "Show phase progress in the Dock"], aliases: ["Progress indicator": "transfer queue footer window status"]),
        controls(.operations, "Recovery and Retention", ["Show in-window recovery attention", "Review Recovery Backups…", "Prepare History for Review…", "Compact Journal Metadata"],
                 aliases: ["Review Recovery Backups…": "undo operations incomplete interrupted copies restore"]),
        controls(.privacy, "Private Saved Names", ["Default search sources", "Suggest saved folder names in addresses", "Refresh Storage Figures"],
                 aliases: ["Default search sources": "private saved names nicknames labels remembrance"]),
        controls(.privacy, "Storage and Backups", ["Open App Storage Analysis"], aliases: ["Open App Storage Analysis": "app metadata saved names local database disk size"]),
        controls(.privacy, "Export and Restore", ["Include last-known locations", "Import Saved Names…", "Forget All Saved Names…"],
                 aliases: ["Include last-known locations": "export saved names paths backup", "Forget All Saved Names…": "delete local nicknames labels"]),
        controls(.permissions, "Folder Access", ["Folders and drives", "Additional access"],
                 aliases: ["Folders and drives": "remember folder grant volumes access bookmarks", "Additional access": "full disk files folders network sftp smb keychain servers"])
    ].flatMap { $0 }

    private static func index(_ entry: Entry) -> (entry: Entry, title: String, keywords: String) {
        let title = normalize(entry.title)
        let keywords = title + " " + normalize(entry.section + " " + entry.aliases + " " + entry.page.title)
        return (entry: entry, title: title, keywords: keywords)
    }

    private static let indexedEntries = entries.map(index)

    static func matches(_ input: String, additionalTypes: [EditorOpeningSupport.FileType] = []) -> [Entry] {
        let words = normalizedWords(input)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")
        let entries = indexedEntries + additionalTypes.map { index(openingEntry($0)) }
        return entries.enumerated().compactMap { position, record -> (Entry, Int, Int)? in
            let (entry, title, keywords) = record
            guard words.allSatisfy(keywords.contains) else { return nil }
            let rank = title == phrase ? 0 : title.hasPrefix(phrase) ? 1 : title.contains(phrase) ? 2
                : words.allSatisfy(title.contains) ? 3 : 4
            return (entry, rank, position)
        }.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }

    static func pages(matching input: String) -> [Page] {
        guard !normalizedWords(input).isEmpty else { return Page.ordered }
        let pages = Set(matches(input).map(\.page))
        return Page.ordered.filter(pages.contains)
    }

    @MainActor static func shortcutMatches(_ input: String) -> [Entry] {
        let words = normalizedWords(input)
        let shortcutWords: Set<String> = ["shortcut", "shortcuts", "hotkey", "hotkeys"]
        guard words.contains(where: shortcutWords.contains) else { return [] }
        let terms = words.filter { !shortcutWords.contains($0) && $0 != "keyboard" && $0 != "for" }
        guard !terms.isEmpty else { return [] }
        let commands = BrowserCommand.allCases.filter(\.isPresentedInBuild).map { BrowserCommandSearch.Entry(command: $0) }
        let matches = (try? BrowserCommandSearch.matches(terms.joined(separator: " "), entries: commands, limit: 8)) ?? []
        return matches.map { match in
            .init(id: .init(page: .keyboard, key: "shortcut-" + match.command.rawValue), section: "Custom Shortcuts",
                  title: match.title, aliases: "", shortcut: match.command)
        }
    }

    static func normalizedWords(_ input: String) -> [String] {
        normalize(String(input.prefix(160))).split(whereSeparator: \.isWhitespace).prefix(12).map(String.init)
    }

    private static func normalize(_ input: String) -> String {
        input.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}

struct SettingsSearchPresentation: Equatable {
    let matches: Set<SettingsSearchCatalog.Anchor>
    let revealed: SettingsSearchCatalog.Entry?
}

extension EnvironmentValues {
    @Entry var settingsSearchPresentation = SettingsSearchPresentation(matches: [], revealed: nil)
    @Entry var settingsSearchPage = BrowserSettingsView.Page.general
}

extension View {
    func settingsSearchAnchor(_ key: String) -> some View { modifier(SettingsSearchMark(key: key)) }
}

@MainActor func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn).settingsSearchAnchor(title)
}

@MainActor func settingPicker<Selection: Hashable, Options: View>(_ title: String, selection: Binding<Selection>,
                                                               @ViewBuilder content: () -> Options) -> some View {
    Picker(title, selection: selection, content: content).settingsSearchAnchor(title)
}

@MainActor func settingButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
    Button(title, role: role, action: action).settingsSearchAnchor(title)
}

private struct SettingsSearchMark: ViewModifier {
    @Environment(\.settingsSearchPresentation) private var search
    @Environment(\.settingsSearchPage) private var page
    let key: String

    func body(content: Content) -> some View {
        let anchor = SettingsSearchCatalog.Anchor(page: page, key: key)
        let selected = search.revealed?.id == anchor
        content.id(anchor).background {
            if search.matches.contains(anchor) {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(selected ? 0.23 : 0.10))
                    .overlay { if selected { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.7)) } }
                    .padding(-4).accessibilityHidden(true).allowsHitTesting(false)
            }
        }
    }
}
