#if DEBUG
import AppKit
import FileOperations

/// Compose into a Root-admitted actual app verifier. Memory-only preference
/// profiles; no disk file, application launch, body read or association write.
@MainActor
enum EditorSettingsAppChecks {
    enum Failure: Error { case check(String) }
    private static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure.check(label) }
    }
    private static func sourceHighlightChecks() throws -> String {
        let samples: [(TextSyntaxLanguage, String, [(String, TextSyntaxToken.Kind)])] = [
            (.jsonc, "{\"🧭\" /* key */ // line\r\n: \"Orion\", \"enabled\": true, \"count\": -1.25e+2,}",
             [("\"🧭\"", .property), ("/* key */", .comment), ("// line", .comment), ("\"Orion\"", .string), ("true", .literal), ("-1.25e+2", .number)]),
            (.xml, "🧭 <item title='a>b'>&amp;<!-- keep --><![CDATA[<raw>]]></item>",
             [("item", .keyword), ("title", .property), ("'a>b'", .string), ("&amp;", .literal), ("<!-- keep -->", .comment), ("<![CDATA[<raw>]]>", .string)]),
            (.html, "<p data-label=\"Orion\">Text</p>", [("p", .keyword), ("data-label", .property), ("\"Orion\"", .string)]),
            (.markdown, "# Orion 🧭\nUse `let x = 1` and [docs](https://example.invalid).\n```swift\nlet x = 1\n```\nAfter\n",
             [("# Orion 🧭", .keyword), ("`let x = 1`", .string), ("https://example.invalid", .string), ("let x = 1", .string)]),
            (.ini, "; generated\r\nbefore: off\r\n[Clock🧭]\r\ntick = 10\r\nlabel = \"demo\"\r\n",
             [("; generated", .comment), ("[Clock🧭]", .keyword), ("tick", .property),
              ("10", .number), ("off", .literal), ("\"demo\"", .string)]),
            (.go, "package example\nvar raw = `func InsideString() { }\n\\`\n/* func InsideComment() {} */\ntype Worker struct{}\nfunc (w *Worker) Run() rune { return '🧭' }\nfunc Total[T comparable]() int { return 1 }\n",
             [("package", .keyword), ("`func InsideString() { }\n\\`", .string),
              ("/* func InsideComment() {} */", .comment), ("rune", .type), ("'🧭'", .string)])
        ]
        for (language, source, expected) in samples {
            let value = try TextDocumentValue.original(Data(source.utf8))
            guard case .tokens(let tokens) = TextSyntax.color(value, language: language) else { throw Failure.check("markup-unexpected-fallback") }
            var priorEnd = 0
            for token in tokens {
                try require(token.range.location >= priorEnd && token.range.length > 0
                    && NSMaxRange(token.range) <= value.utf16Count, "markup-ordered-utf16-ranges")
                priorEnd = NSMaxRange(token.range)
            }
            let text = value.text as NSString
            for (fragment, role) in expected {
                try require(tokens.contains { $0.kind == role && text.substring(with: $0.range) == fragment }, "markup-source-role")
            }
            if case .plain(.cancelled) = TextSyntax.color(value, language: language, cancelled: { true }) {} else {
                throw Failure.check("markup-cancel-refusal")
            }
            try require(value.encoded == Data(source.utf8), "markup-styling-changed-source")
            if language == .ini || language == .go {
                let outline = EditorDocumentOutline.prepare(text: value.text, syntax: .tokens(tokens),
                    language: language, lines: EditorLineIndex(value.text), cancelled: { false })
                if language == .ini {
                    try require(outline.entries.map(\.title) == ["before", "Clock🧭", "tick", "label"]
                        && outline.entries.map(\.depth) == [0, 0, 1, 1], "INI-section-and-key-outline")
                } else {
                    try require(outline.entries.map(\.title) == ["Worker", "Run", "Total"], "Go-type-and-function-outline")
                }
            }
        }
        let busy = try TextDocumentValue.original(Data(String(repeating: "<a b='c'/>\n", count: 14_000).utf8))
        if case .plain(.tokenBudget) = TextSyntax.color(busy, language: .xml) {} else { throw Failure.check("markup-token-budget") }
        try require(TextSyntaxLanguage.inferred(extension: "MD") == .markdown
            && TextSyntaxLanguage.inferred(extension: "htm") == .html
            && TextSyntaxLanguage.inferred(extension: "xml") == .xml
            && TextSyntaxLanguage.inferred(extension: "JSONC") == .jsonc
            && TextSyntaxLanguage.inferred(extension: "json") == .json
            && EditorOpeningSupport.syntax(for: EditorOpeningSupport.key(forFilename: ".editorconfig")) == .ini
            && EditorOpeningSupport.syntax(for: EditorOpeningSupport.key(forFilename: "worker.go")) == .go,
            "source-extension-inference")
        return "JSONC, HTML/XML, Markdown, INI and Go highlighting and outlines preserve source text and bounded Unicode ranges"
    }
    private static func languageDetectionChecks() throws -> String {
        for (source, expected) in [("{\"🧭\":true}", TextSyntaxLanguage.json), ("[1,2,3]", .json),
            ("#!/usr/bin/env -S python3 -u\nprint('ready')\n", .python),
            ("#!/bin/zsh\necho ready\n", .shell), ("#!/usr/bin/env node\nconst ready = true;", .javascript),
            ("<?xml version=\"1.0\"?><root/>", .xml), ("<!DOCTYPE html><html></html>", .html)] {
            try require(TextSyntaxLanguage.detected(in: source) == expected, "clear-editor-language-detection")
        }
        for source in ["Ordinary text", "{unfinished", "123", "#!/usr/bin/env unknown\n{}", "\n#!/bin/bash\necho ready"] {
            try require(TextSyntaxLanguage.detected(in: source) == nil, "ambiguous-editor-text-stays-plain")
        }
        try require(TextSyntaxLanguage.detected(in: "{}", cancelled: { true }) == nil
            && TextSyntaxLanguage.detected(in: "{\"value\":\"" + String(repeating: "a", count: 32 * 1024) + "\"}") == nil,
            "language-detection-cancellation-and-byte-bound")
        var value = EditorPreferences()
        try require(value.canDetectLanguage(forFilename: "Untitled")
            && !value.canDetectLanguage(forFilename: "notes.txt")
            && !value.canDetectLanguage(forFilename: "Dockerfile"), "language-detection-filename-priority")
        value.defaultLanguage = .plain
        try require(!value.canDetectLanguage(forFilename: "Untitled"), "manual-default-language-wins")
        value.defaultLanguage = nil; value.detectsLanguageWithoutExtension = false
        try require(!value.canDetectLanguage(forFilename: "Untitled")
            && (try JSONDecoder().decode(EditorPreferences.self, from: JSONEncoder().encode(value))) == value,
            "language-detection-opt-out-roundtrip")
        return "Clear extensionless language hints respect known filenames, manual defaults, opt-out, cancellation and bounded JSON input"
    }
    private static func lineCommentChecks() throws -> String {
        func apply(_ style: EditorLineCommentStyle, _ source: String, _ selection: NSRange) throws -> (String, NSRange) {
            guard case .replace(let edit) = EditorLineCommands.plan(.toggleLineComment(style), text: source,
                selection: selection, maximumBytes: TextDocumentValue.maximumBytes) else { throw Failure.check("comment-edit-plan") }
            return ((source as NSString).replacingCharacters(in: edit.range, with: edit.text), edit.selection)
        }
        let source = "  let compass = \"🧭\"\n\tlet value = 2\n\n"
        let marked = try apply(.slash, source, .init(location: 0, length: source.utf16.count))
        try require(marked.0 == "  // let compass = \"🧭\"\n\t// let value = 2\n\n", "comment-keeps-indentation-unicode-and-blank-lines")
        try require(try apply(.slash, marked.0, marked.1).0 == source, "comment-toggle-restores-exact-source")
        let mixed = "// first\nsecond\n"
        let nested = try apply(.slash, mixed, .init(location: 0, length: mixed.utf16.count))
        try require(nested.0 == "// // first\n// second\n"
            && (try apply(.slash, nested.0, nested.1).0) == mixed, "mixed-comments-toggle-one-layer")
        try require(try apply(.hash, "a\nb", .init(location: 0, length: 2)).0 == "# a\nb", "comment-next-line-start-excluded")
        let caret = try apply(.dash, "🧭", .init(location: 2, length: 0))
        try require(caret.0 == "-- 🧭" && caret.1 == .init(location: 5, length: 0), "comment-caret-utf16")
        try require(try apply(.slash, "", .init(location: 0, length: 0)).0 == "// ", "comment-empty-caret-ready-for-typing")
        try require(EditorLineCommands.plan(.toggleLineComment(.slash), text: "a", selection: .init(location: 0, length: 0), maximumBytes: 3) == .refused(.tooLarge), "comment-size-refuses-before-growth")
        try require(EditorLineCommands.plan(.toggleLineComment(.hash), text: "🧭", selection: .init(location: 1, length: 0), maximumBytes: 64) == .refused(.invalidSelection), "comment-refuses-surrogate-split")
        try require(TextSyntaxLanguage.json.lineCommentStyle == nil && TextSyntaxLanguage.xml.lineCommentStyle == nil
            && TextSyntaxLanguage.jsonc.lineCommentStyle == .slash
            && TextSyntaxLanguage.python.lineCommentStyle == .hash && TextSyntaxLanguage.sql.lineCommentStyle == .dash,
            "comment-language-policy")
        return "Language-aware comments preserve indentation, Unicode and native selection bounds; mixed/blank lines and byte refusal have focused regression coverage"
    }
    private static func newlineChecks() throws -> String {
        func plan(_ source: String, _ caret: Int, _ preferences: EditorIndentationPreferences = .fresh,
                  language: TextSyntaxLanguage = .json, maximumBytes: Int = 1024,
                  indentsJSONBlocks: Bool = true, indentsCodeBlocks: Bool = true) -> EditorIndentationPlan {
            EditorIndentation.plan(.newline, text: source, selection: .init(location: caret, length: 0),
                preferences: preferences, maximumBytes: maximumBytes, language: language,
                indentsJSONBlocks: indentsJSONBlocks, indentsCodeBlocks: indentsCodeBlocks)
        }
        func result(_ source: String, _ caret: Int, _ expected: String, _ expectedCaret: Int,
                    preferences: EditorIndentationPreferences = .fresh, language: TextSyntaxLanguage = .json,
                    indentsJSONBlocks: Bool = true) throws {
            guard case .replace(let edit) = plan(source, caret, preferences, language: language, indentsJSONBlocks: indentsJSONBlocks) else {
                throw Failure.check("smart-newline-replacement")
            }
            try require((source as NSString).replacingCharacters(in: edit.range, with: edit.text).utf16.elementsEqual(expected.utf16)
                && edit.selection == .init(location: expectedCaret, length: 0), "smart-newline-buffer-and-inner-caret")
        }
        try result("{}", 1, "{\n    \n}", 6)
        try result("  \"🧭\": [   ]", 9, "  \"🧭\": [\n      \n  ]", 16)
        try result("\t{}", 2, "\t{\n\t\t\n\t}", 5,
            preferences: .init(columns: 8, insertion: .tabs, continuesIndentation: true))
        try result("  {", 3, "  {\n      ", 10)
        try result("  text", 6, "  text\n  ", 9, language: .plain)
        try result(" \ttext", 6, " \ttext\n \t", 9, language: .swift)
        try require(plan("\"{}\"", 2) == .native, "json-string-delimiters-are-text")
        try require(plan("// {}", 4, language: .jsonc) == .native, "jsonc-line-comment-delimiters-are-text")
        try require(plan("/*\n{}", 4, language: .jsonc) == .native, "jsonc-multiline-comment-delimiters-are-text")
        let escaped = "{\"name\":\"quote \\\" {}\"}"
        try require(plan(escaped, (escaped as NSString).range(of: "{}").location + 1) == .native,
            "escaped-quote-does-not-end-JSON-string")
        try require(plan("{}", 1, language: .plain) == .native, "plain-mode-keeps-native-Return")
        var disabled = EditorIndentationPreferences.fresh; disabled.continuesIndentation = false
        try result("  {}", 3, "  {\n      \n  }", 10, preferences: disabled)
        try result("{}", 1, "{\n\t\n}", 3, preferences: .legacy)
        try require(plan("  {}", 3, disabled, indentsJSONBlocks: false) == .native,
            "explicit-JSON-opt-out-and-continuation-off-keep-native-Return")
        try require(plan("  text", 6, disabled, language: .plain) == .native,
            "new-JSON-default-preserves-existing-plain-continuation-opt-out")
        try result("  {}", 3, "  {\n  }", 6, indentsJSONBlocks: false)
        try require(plan("{}", 1, maximumBytes: 8) == .replace(.init(range: .init(location: 1, length: 0),
            text: "\n    \n", selection: .init(location: 6, length: 0))), "smart-Return-exact-byte-cap")
        try require(plan("{}", 1, maximumBytes: 7) == .refused(.tooLarge), "smart-Return-refuses-growth")
        try require(plan("{   }", 1, maximumBytes: 8) == .replace(.init(range: .init(location: 1, length: 3),
            text: "\n    \n", selection: .init(location: 6, length: 0))), "smart-Return-credits-replaced-whitespace")
        try require(plan("🧭{}", 1) == .refused(.invalidSelection), "smart-Return-refuses-surrogate-split")
        try require(EditorIndentation.plan(.newline, text: "{}", selection: .init(location: 1, length: 1),
            preferences: .fresh, maximumBytes: 1024, language: .json) == .native, "selected-Return-keeps-native-replacement")
        let distant = String(repeating: " ", count: 65_536) + "{}"
        guard case .replace(let continued) = plan(distant, 65_537, maximumBytes: 200_000) else {
            throw Failure.check("bounded-context-keeps-indentation-continuation")
        }
        try require(continued.text.utf16.count == 65_537, "bounded-context-does-not-guess-delimiters")

        let swift = "    if ready {"
        try result(swift + "    }", swift.utf16.count, swift + "\n        \n    }",
                   swift.utf16.count + 9, language: .swift)
        try require(plan(swift, swift.utf16.count, disabled, language: .swift, indentsCodeBlocks: false) == .native,
                    "swift-Return-opt-out")
        for source in ["// {", "/* /* nested */ {", "let raw = #\"not code {", "let pattern = /text{"] {
            try require(plan(source, source.utf16.count, language: .swift) == .native, "swift-Return-skips-comment-literal-or-ambiguous-slash")
        }
        for (language, source) in [(TextSyntaxLanguage.javascript, "const test = / {"), (.typescript, "const value = `literal {"),
                                   (.cpp, "auto raw = R\"test(literal {"), (.objectiveC, "NSString *value = @\"literal {"),
                                   (.css, ".card { background: url(data:generated{"), (.css, ".escaped\\{")] {
            try require(plan(source, source.utf16.count, language: language) == .native,
                "\(language.rawValue)-Return-keeps-literal-or-ambiguous-opening-native")
        }
        let type = "  const typed = (a: number) => {"
        try result(type + " }", type.utf16.count, type + "\n      \n  }", type.utf16.count + 7, language: .typescript)
        try require(plan(type, type.utf16.count, disabled, language: .typescript, indentsCodeBlocks: false) == .native,
            "typescript-Return-honors-shared-code-preference")
        let python = "    async def fetch(\n        name: str,\n    ) -> str:"
        try result(python, python.utf16.count, python + "\n        ", python.utf16.count + 9, language: .python)
        let pythonSuite = "  if ready:"
        try result(pythonSuite, pythonSuite.utf16.count, pythonSuite + "\n  \t", pythonSuite.utf16.count + 4,
                   preferences: .legacy, language: .python)
        for source in ["value:", "match:", "values[1:", "if values[1:", "if True: # comment:", "s = '''\nif ignored:"] {
            try require(plan(source, source.utf16.count, language: .python) == .native, "python-Return-skips-annotation-slice-comment-or-string")
        }
        return "Return expands JSON and supported code delimiters and indents Python suites, respecting lexical context, Unicode offsets, native selection and byte limits"
    }
    private static func bracketChecks() throws -> String {
        func plan(_ typed: String, _ prefix: String?, next: UInt16? = nil, owned: Bool = false,
                  language: TextSyntaxLanguage = .json, enabled: Bool = true) -> EditorBracketPairing.Plan {
            EditorBracketPairing.plan(typed, prefix: prefix, next: next, ownsNextClose: owned,
                language: language, enabled: enabled)
        }
        try require(plan("{", "") == .insert("{}", 125)
            && plan("[", "{\"🧭\": ", next: 125) == .insert("[]", 93), "JSON-opening-bracket-pairs")
        try require(plan("{", "/* closed */ ", language: .jsonc) == .insert("{}", 125), "JSONC-code-after-comment-pairs")
        try require(plan("{", "\"inside ") == .native && plan("[", "// ", language: .jsonc) == .native
            && plan("{", "/*\n ", language: .jsonc) == .native, "brackets-in-strings-and-comments-are-native")
        try require(plan("{", nil) == .native && plan("{", "", enabled: false) == .native
            && plan("{", "", language: .plain) == .native, "completion-bounds-language-and-opt-out")
        try require(plan("{", "", next: 34) == .native && plan("{}", "") == .native
            && plan("\"", "") == .native, "completion-does-not-wrap-content-paste-or-quotes")
        try require(plan("}", "{", next: 125, owned: true) == .skip
            && plan("]", "[", next: 93, owned: true) == .skip
            && plan("}", "{", next: 125) == .native
            && plan("}", "[", next: 93, owned: true) == .native
            && plan("}", "{\"", next: 125, owned: true) == .native,
            "closing-skip-requires-code-context-and-exact-inserted-provenance")
        try require(plan("(", "render", language: .swift) == .insert("()", 41)
            && plan("[", "render(", next: 41, language: .typescript) == .insert("[]", 93)
            && plan("{", "struct Generated ", language: .rust, enabled: false) == .native
            && plan("(", "", language: .json) == .native && plan(")", "render(", next: 41, language: .python) == .native,
            "code-bracket-pair-admission-and-language-boundaries")
        for (language, prefix) in [(TextSyntaxLanguage.swift, "let s = #\"literal "), (.python, "# comment "),
                                   (.javascript, "const r = /"), (.typescript, "const s = `literal "),
                                   (.rust, "let character = '"), (.cpp, "auto s = R\"gen(literal "),
                                   (.objectiveC, "NSString *s = @\"literal "), (.css, ".escaped\\")] {
            try require(plan("(", prefix, language: language) == .native,
                "\(language.rawValue)-completion-keeps-literal-comment-and-ambiguous-input-native")
        }
        try require(plan("(", String(repeating: " ", count: EditorIndentation.lexicalInputLimit), language: .swift) == .native,
            "code-pair-keeps-the-bounded-context-budget")
        return "JSON and optional code bracket proposals share native closing provenance, lexical context and finite lookbehind"
    }
    static func check() throws -> [String] {
        var named = EditorPreferences()
        for type in EditorOpeningSupport.fileTypes where !type.filenames.isEmpty {
            for name in type.filenames {
                try require(named.route(forFilename: name, command: .ordinaryOpen) == .traverse
                    && named.route(forFilename: name.uppercased(), command: .ordinaryOpen) == .traverse,
                    "named-text-types-use-the-shared-native-default")
            }
            try named.setTarget(.systemDefault, forExtension: type.fileExtension)
            try require(named.target(forFilename: type.sampleFilename) == .systemDefault,
                "named-type-explicit-system-choice-is-honored")
            try named.clearTarget(forExtension: type.fileExtension)
        }
        try require(named.target(forFilename: "Dockerfile.zip") == .systemDefault
            && named.target(forFilename: "README.pdf") == .systemDefault
            && named.target(forFilename: "folder/Dockerfile") == .systemDefault,
            "named-text-policy-does-not-use-prefixes-or-paths")
        let original = BrowserSettings(persist: false)
        var preferences = original.editorPreferences
        preferences.palette = .vivid; preferences.theme = .dark
        preferences.defaultLanguage = .jsonc; preferences.showsLineNumbers = false
        preferences.wrapsLines = false; preferences.basePointSize = 18
        preferences.windowArrangement = .separateWindows
        preferences.indentation = .init(columns: 8, insertion: .tabs, continuesIndentation: true)
        preferences.indentsJSONBlocks = false
        preferences.indentsCodeBlocks = false
        preferences.completesJSONBrackets = false
        preferences.completesCodeBrackets = true
        preferences.showsMatchingBrackets = false
        preferences.includesGeneratedProjectFolders = true
        try preferences.setTarget(.traverse, forExtension: "json")
        original.updateEditorPreferences(preferences)
        original.showsGitFileBadges = true
        let encoded = try original.encodedSnapshot()
        let restored = BrowserSettings(persist: false, restoredData: encoded)
        try require(restored.editorPreferences == preferences, "actual-settings-preferences-roundtrip")
        try require(restored.showsGitFileBadges, "browser-git-badges-preference-roundtrip")
        var prior = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var healthSnapshot = prior
        healthSnapshot["driveHealthLiveUpdates"] = true
        healthSnapshot.removeValue(forKey: "driveHealthPrivateBetaLiveOptIn")
        let olderHealth = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: healthSnapshot))
        try require(olderHealth.driveHealthLiveUpdates && !olderHealth.driveHealthPrivateBetaLiveOptIn,
                    "older-live-default-does-not-supply-beta-opt-in")
        healthSnapshot["driveHealthPrivateBetaLiveOptIn"] = true
        let optedInHealth = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: healthSnapshot))
        let healthRoundtrip = BrowserSettings(persist: false, restoredData: try optedInHealth.encodedSnapshot())
        try require(healthRoundtrip.driveHealthPrivateBetaLiveOptIn && healthRoundtrip.driveHealthLiveUpdates,
                    "explicit-beta-live-opt-in-roundtrips")
        healthRoundtrip.setDriveHealthLiveUpdates(false)
        try require(!healthRoundtrip.driveHealthLiveUpdatesSelected,
                    "turning-live-off-stops-the-effective-selection")
        guard var oldEditor = prior["editorPreferences"] as? [String: Any] else { throw Failure.check("encoded-editor-preferences-object") }
        oldEditor.removeValue(forKey: "indentation")
        oldEditor.removeValue(forKey: "indentsJSONBlocks")
        oldEditor.removeValue(forKey: "indentsCodeBlocks")
        oldEditor.removeValue(forKey: "completesJSONBrackets")
        oldEditor.removeValue(forKey: "completesCodeBrackets")
        oldEditor.removeValue(forKey: "showsMatchingBrackets")
        oldEditor.removeValue(forKey: "includesGeneratedProjectFolders")
        oldEditor.removeValue(forKey: "openingIndicator")
        oldEditor.removeValue(forKey: "findHighlightColor")
        oldEditor.removeValue(forKey: "windowArrangement")
        var legacySnapshot = prior; legacySnapshot["editorPreferences"] = oldEditor
        legacySnapshot.removeValue(forKey: "showsGitFileBadges")
        let legacy = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: legacySnapshot))
        var expectedLegacy = preferences; expectedLegacy.indentation = .legacy; expectedLegacy.windowArrangement = .tabs
        expectedLegacy.indentsJSONBlocks = true
        expectedLegacy.indentsCodeBlocks = true
        expectedLegacy.completesJSONBrackets = true
        expectedLegacy.completesCodeBrackets = false
        expectedLegacy.showsMatchingBrackets = true
        expectedLegacy.includesGeneratedProjectFolders = false
        try require(legacy.editorPreferences == expectedLegacy && !legacy.showsGitFileBadges,
                    "older-settings-keep-their-editor-options-and-browser-badges-opt-in")
        var inheritedEditor = oldEditor
        inheritedEditor["indentation"] = ["columns": 4, "insertion": "tabs", "continuesIndentation": false] as [String: Any]
        var inheritedSnapshot = prior; inheritedSnapshot["editorPreferences"] = inheritedEditor
        let inherited = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: inheritedSnapshot))
        try require(inherited.editorPreferences.indentation == .legacy && inherited.editorPreferences.indentsJSONBlocks,
            "persisted-legacy-continuation-false-gets-independent-JSON-default")
        var explicitOptOut = inherited.editorPreferences; explicitOptOut.indentsJSONBlocks = false
        inherited.updateEditorPreferences(explicitOptOut)
        let optedOut = BrowserSettings(persist: false, restoredData: try inherited.encodedSnapshot())
        try require(optedOut.editorPreferences.indentation == .legacy && !optedOut.editorPreferences.indentsJSONBlocks,
            "explicit-new-JSON-opt-out-persists-with-old-continuation-choice")
        try require(EditorPreferences().indentation == .fresh, "fresh-indentation-defaults")
        prior["version"] = 19; prior.removeValue(forKey: "editorPreferences")
        let migrated = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: prior))
        try require(migrated.editorPreferences == .init() && migrated.preferencesPersistenceStatus.isEmpty,
                    "old-version-migrates-editor-defaults-without-losing-other-preferences")
        prior["version"] = BrowserSettings.preferencesVersion + 1
        let newer = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: prior))
        try require(!newer.preferencesPersistenceStatus.isEmpty, "future-preferences-preserved-session-only")
        var invalid = preferences; invalid.basePointSize = 200
        original.updateEditorPreferences(invalid)
        try require(original.editorPreferences == preferences, "invalid-live-preferences-refused")
        invalid = preferences; invalid.indentation.columns = 3
        original.updateEditorPreferences(invalid)
        try require(original.editorPreferences == preferences, "invalid-live-indentation-refused")
        for query in ["json", "SyNtAx", "editor theme", "default app", "line numbers", "external", "tab width", "spaces", "continue line indentation", "JSON blocks Return", "bracket completion", "find highlight", "native icon"] {
            try require(SettingsSearchCatalog.pages(matching: query).contains(.tools), "authored-search-tools-route")
        }
        try require(SettingsSearchCatalog.pages(matching: "saved names").contains(.privacy), "authored-search-privacy-route")
        try require(SettingsSearchCatalog.pages(matching: "json keyboard").isEmpty, "query-terms-match-one-category")
        try require(SettingsSearchCatalog.pages(matching: "  ") == BrowserSettingsView.Page.ordered, "empty-search-retains-category-order")
        try require(SettingsSearchCatalog.normalizedWords(String(repeating: "a", count: 400)).joined().count == 160,
                    "finite-search-prefix")
        return [try sourceHighlightChecks(), try languageDetectionChecks(), try lineCommentChecks(), try newlineChecks(), try bracketChecks(), "Actual BrowserSettings roundtrip and version19 migration", "Older Live defaults do not supply private-beta opt-in; explicit choice roundtrips and turning Live off clears its effective selection", "Nested indentation roundtrip, legacy migration and invalid choices", "Future version and invalid live value refusal", "Actual finite authored catalog result routes"]
    }
}
#endif
