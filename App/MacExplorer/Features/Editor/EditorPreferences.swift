import Foundation

enum EditorSyntaxPalette: String, Codable, CaseIterable, Sendable, Identifiable {
    case adaptive, vivid, monochrome
    var id: Self { self }
    var title: String {
        switch self { case .adaptive: "Adaptive"; case .vivid: "Vivid"; case .monochrome: "Monochrome" }
    }
}

enum EditorTheme: String, Codable, CaseIterable, Sendable, Identifiable {
    case followApp, light, dark
    var id: Self { self }
    var title: String { switch self { case .followApp: "Follow App"; case .light: "Light"; case .dark: "Dark" } }
}

enum EditorWindowArrangement: String, Codable, CaseIterable, Sendable, Identifiable {
    case tabs, separateWindows, system
    var id: Self { self }
    var title: String {
        switch self { case .tabs: "Tabs"; case .separateWindows: "Separate Windows"; case .system: "Use macOS Preference" }
    }
}

/// Traverse's ordinary Open consults these choices. Remote text Open uses only
/// the native choice; other apps still need a downloaded local file. Explicit
/// Edit in Traverse / Open in Default App / Open With retain their own intent.
/// This value never grants file access, launches an app or changes macOS defaults.
enum EditorOpeningTarget: Equatable, Sendable, Codable {
    case systemDefault, traverse, externalApplication(URL)
}

struct EditorOpeningRule: Equatable, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    let fileExtension: String
    let target: EditorOpeningTarget
    var description: String { "<Traverse file-opening preference>" }
    var debugDescription: String { description }
}

enum EditorOpeningIndicator: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, subtle, badge
    var id: Self { self }
    var title: String {
        switch self { case .off: "Off"; case .subtle: "Brighter Native Icons"; case .badge: "Native Opening Badge" }
    }
}

enum EditorFindHighlightColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case blue, accent, purple, teal, orange
    var id: Self { self }
    var title: String {
        switch self { case .blue: "Blue"; case .accent: "App Accent"; case .purple: "Purple"; case .teal: "Teal"; case .orange: "Orange" }
    }
}

enum EditorOpeningCommand: Sendable { case ordinaryOpen, editInTraverse, openInDefaultApp }

enum EditorPreferenceFailure: Error { case invalid, tooManyRules }

struct EditorPreferences: Equatable, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumOpeningRules = 64
    var wrapsLines = true
    var showsLineNumbers = true
    var showsUnsavedLineChanges = true
    var showsScrollContext = true
    var showsIndentGuides = true
    var showsMatchingBrackets = true
    var showsWhitespaceMarks = false
    var basePointSize = 13
    var palette = EditorSyntaxPalette.adaptive
    var theme = EditorTheme.followApp
    var windowArrangement = EditorWindowArrangement.tabs
    var opensFileSidebar = false
    var includesGeneratedProjectFolders = false
    var showsWorkingGitChanges = false
    var linksComparisonScrolling = true
    var indentation = EditorIndentationPreferences.fresh
    var indentsJSONBlocks = true
    var indentsCodeBlocks = true
    var completesJSONBrackets = true
    var completesCodeBrackets = false
    var backspaceUnindents = true
    var detectsLanguageWithoutExtension = true
    var openingIndicator = EditorOpeningIndicator.subtle
    var findHighlightColor = EditorFindHighlightColor.blue
    /// nil uses the filename, then optional bounded hints from extensionless text.
    var defaultLanguage: TextSyntaxLanguage?
    private(set) var openingRules: [EditorOpeningRule] = []
    var description: String { "<Traverse editor preferences>" }
    var debugDescription: String { description }
    var isValid: Bool {
        (11...22).contains(basePointSize) && indentation.isValid && openingRules.count <= Self.maximumOpeningRules
            && Set(openingRules.map(\.fileExtension)).count == openingRules.count
            && openingRules.allSatisfy { Self.extensionKey($0.fileExtension) == $0.fileExtension && Self.validTarget($0.target) }
    }
    func language(forExtension value: String) -> TextSyntaxLanguage {
        defaultLanguage ?? .inferred(extension: value)
    }
    func language(forFilename name: String) -> TextSyntaxLanguage {
        defaultLanguage ?? EditorOpeningSupport.syntax(for: EditorOpeningSupport.key(forFilename: name))
    }
    func canDetectLanguage(forFilename name: String) -> Bool {
        detectsLanguageWithoutExtension && defaultLanguage == nil
            && (name as NSString).pathExtension.isEmpty
            && EditorOpeningSupport.key(forFilename: name) == nil
    }
    func explicitTarget(forExtension value: String) -> EditorOpeningTarget? {
        guard let key = Self.extensionKey(value) else { return nil }
        return openingRules.first { $0.fileExtension == key }?.target
    }
    func target(forExtension value: String) -> EditorOpeningTarget {
        guard let key = Self.extensionKey(value) else { return .systemDefault }
        return explicitTarget(forExtension: key) ?? EditorOpeningSupport.recommendedTarget(for: key)
    }
    func target(forFilename name: String) -> EditorOpeningTarget {
        EditorOpeningSupport.key(forFilename: name).map { target(forExtension: $0) } ?? .systemDefault
    }
    func explicitTarget(forFilename name: String) -> EditorOpeningTarget? {
        EditorOpeningSupport.key(forFilename: name).flatMap { explicitTarget(forExtension: $0) }
    }
    func route(forFilename name: String, command: EditorOpeningCommand,
               editorAvailable: Bool = true) -> EditorOpeningTarget {
        route(forExtension: EditorOpeningSupport.key(forFilename: name) ?? "", command: command,
              editorAvailable: editorAvailable)
    }
    func route(forExtension value: String, command: EditorOpeningCommand,
               editorAvailable: Bool = true) -> EditorOpeningTarget {
        switch command {
        case .ordinaryOpen:
            let requested = target(forExtension: value)
            // An unavailable build must not break ordinary Open merely because
            // the recommended default is native. Explicit choices keep intent.
            let hasOverride = Self.extensionKey(value).map { key in
                openingRules.contains { $0.fileExtension == key }
            } ?? false
            if requested == .traverse && !editorAvailable && !hasOverride { return .systemDefault }
            return requested
        case .editInTraverse: return .traverse
        case .openInDefaultApp: return .systemDefault
        }
    }
    mutating func setTarget(_ target: EditorOpeningTarget, forExtension value: String) throws {
        guard let key = Self.extensionKey(value), Self.validTarget(target) else { throw EditorPreferenceFailure.invalid }
        var proposed = openingRules.filter { $0.fileExtension != key }
        // Store every explicit choice, even when it currently matches the
        // recommendation. Future format support must not erase a user's opt-out.
        guard proposed.count < Self.maximumOpeningRules else { throw EditorPreferenceFailure.tooManyRules }
        proposed.append(.init(fileExtension: key, target: target))
        openingRules = proposed.sorted { $0.fileExtension < $1.fileExtension }
    }
    mutating func clearTarget(forExtension value: String) throws {
        guard let key = Self.extensionKey(value) else { throw EditorPreferenceFailure.invalid }
        openingRules.removeAll { $0.fileExtension == key }
    }
    static func extensionKey(_ value: String) -> String? {
        // Extension only: no path, filename, query, wildcard or shell grammar.
        guard !value.isEmpty, value.utf8.count <= 24,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return value.lowercased()
    }
    static func validTarget(_ target: EditorOpeningTarget) -> Bool {
        guard case .externalApplication(let url) = target else { return true }
        return url.isFileURL && url.path.hasPrefix("/") && url.pathExtension.lowercased() == "app"
            && url.absoluteString.utf8.count <= 8192 && !url.path.utf8.contains(0)
            && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
            && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.standardizedFileURL == url
    }

    enum CodingKeys: String, CodingKey {
        case wrapsLines, showsLineNumbers, showsUnsavedLineChanges, showsScrollContext, showsIndentGuides, showsWhitespaceMarks
        case showsMatchingBrackets
        case basePointSize, palette, theme, windowArrangement, opensFileSidebar, includesGeneratedProjectFolders
        case showsWorkingGitChanges, linksComparisonScrolling, indentation, indentsJSONBlocks, indentsCodeBlocks
        case completesJSONBrackets, completesCodeBrackets, backspaceUnindents, detectsLanguageWithoutExtension, openingIndicator
        case findHighlightColor, defaultLanguage, openingRules
    }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        wrapsLines = try values.decodeIfPresent(Bool.self, forKey: .wrapsLines) ?? true
        showsLineNumbers = try values.decodeIfPresent(Bool.self, forKey: .showsLineNumbers) ?? true
        showsUnsavedLineChanges = try values.decodeIfPresent(Bool.self, forKey: .showsUnsavedLineChanges) ?? true
        showsScrollContext = try values.decodeIfPresent(Bool.self, forKey: .showsScrollContext) ?? true
        showsIndentGuides = try values.decodeIfPresent(Bool.self, forKey: .showsIndentGuides) ?? true
        showsMatchingBrackets = try values.decodeIfPresent(Bool.self, forKey: .showsMatchingBrackets) ?? true
        showsWhitespaceMarks = try values.decodeIfPresent(Bool.self, forKey: .showsWhitespaceMarks) ?? false
        basePointSize = try values.decodeIfPresent(Int.self, forKey: .basePointSize) ?? 13
        palette = try values.decodeIfPresent(EditorSyntaxPalette.self, forKey: .palette) ?? .adaptive
        theme = try values.decodeIfPresent(EditorTheme.self, forKey: .theme) ?? .followApp
        windowArrangement = try values.decodeIfPresent(EditorWindowArrangement.self, forKey: .windowArrangement) ?? .tabs
        opensFileSidebar = try values.decodeIfPresent(Bool.self, forKey: .opensFileSidebar) ?? false
        includesGeneratedProjectFolders = try values.decodeIfPresent(Bool.self, forKey: .includesGeneratedProjectFolders) ?? false
        showsWorkingGitChanges = try values.decodeIfPresent(Bool.self, forKey: .showsWorkingGitChanges) ?? false
        linksComparisonScrolling = try values.decodeIfPresent(Bool.self, forKey: .linksComparisonScrolling) ?? true
        indentation = try values.decodeIfPresent(EditorIndentationPreferences.self, forKey: .indentation) ?? .legacy
        indentsJSONBlocks = try values.decodeIfPresent(Bool.self, forKey: .indentsJSONBlocks) ?? true
        indentsCodeBlocks = try values.decodeIfPresent(Bool.self, forKey: .indentsCodeBlocks) ?? true
        completesJSONBrackets = try values.decodeIfPresent(Bool.self, forKey: .completesJSONBrackets) ?? true
        completesCodeBrackets = try values.decodeIfPresent(Bool.self, forKey: .completesCodeBrackets) ?? false
        backspaceUnindents = try values.decodeIfPresent(Bool.self, forKey: .backspaceUnindents) ?? true
        detectsLanguageWithoutExtension = try values.decodeIfPresent(Bool.self, forKey: .detectsLanguageWithoutExtension) ?? true
        openingIndicator = try values.decodeIfPresent(EditorOpeningIndicator.self, forKey: .openingIndicator) ?? .subtle
        findHighlightColor = try values.decodeIfPresent(EditorFindHighlightColor.self, forKey: .findHighlightColor) ?? .blue
        // Newer language choices must not invalidate unrelated editor settings
        // when the reader does not recognize that optional choice.
        defaultLanguage = try values.decodeIfPresent(String.self, forKey: .defaultLanguage)
            .flatMap(TextSyntaxLanguage.init(rawValue:))
        openingRules = try values.decodeIfPresent([EditorOpeningRule].self, forKey: .openingRules) ?? []
        guard indentation.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .indentation, in: values, debugDescription: "Invalid indentation preferences")
        }
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .openingRules, in: values, debugDescription: "Invalid editor preferences")
        }
    }
}
