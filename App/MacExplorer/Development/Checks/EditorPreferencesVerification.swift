#if DEBUG
import AppKit
import Darwin
import ExplorerCore
@_spi(ArchiveProduction) import FileOperations
import LocalStorage

/// Actual app composition with generated documents and intercepted launches.
/// No default application, association, network or personal profile is changed.
@MainActor enum EditorPreferencesVerification {
    private struct Failure: Error { let stage: String }
    private final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        var entered: Bool { lock.withLock { continuation != nil } }
        func pause() async { await withCheckedContinuation { value in lock.withLock { continuation = value } } }
        func release() { let old = lock.withLock { let old = continuation; continuation = nil; return old }; old?.resume() }
    }
    private struct Fixture: Sendable {
        let directory: URL, first: URL, second: URL, application: URL, ownApplication: URL
        let nativeFiles: [URL]
    }
    private static func need(_ condition: Bool, _ stage: String) throws { if !condition { throw Failure(stage: stage) } }
    private static func wait(_ stage: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() { try need(.now < deadline, stage); try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func fixture(_ root: URL) async throws -> Fixture {
        try await Task.detached {
            let directory = root.appendingPathComponent("source/Generated Documents")
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let first = directory.appendingPathComponent("Generated.json"), second = directory.appendingPathComponent("Other.json")
            try Data("{\"project\":\"Generated\",\"enabled\":true,\"count\":123}\n".utf8).write(to: first, options: .withoutOverwriting)
            try Data("{\"other\":false}\n".utf8).write(to: second, options: .withoutOverwriting)
            var nativeFiles = [first]
            for type in EditorOpeningSupport.fileTypes where type.fileExtension != "json" {
                let text: String
                switch type.fileExtension {
                case "c", "h": text = "#include <stdio.h>\n/* Generated source 🧭 */\nint main(void) { printf(\"Orion\"); return 42 + 2; }\n"
                case "cc", "cpp", "cxx", "hh", "hpp", "hxx": text = "#include <string>\n// Generated source 🧭\ntemplate <typename T> struct Box { T value; };\nconstexpr auto count = 1'024ULL;\nauto note = R\"orion(// String content 🧭)orion\";\n"
                case "m": text = "#import <Foundation/Foundation.h>\n@interface Generated : NSObject\n@property(nonatomic) NSInteger count;\n@end\n@implementation Generated\n- (NSString *)title { return @\"Orion 🧭\"; }\n@end\n"
                case "mm": text = "#include <string>\n#import <Foundation/Foundation.h>\n// Generated source 🧭\nauto note = R\"orion(/* String content */)orion\";\nNSString *title = @\"Orion 🧭\";\n"
                case "swift": text = "let generated = 123\n"
                case "css": text = ".generated { color: #123abc; }\n"
                case "jsonc": text = "{\n  // Generated configuration only\n  \"project\" /* label */: \"Orion 🧭\",\n  \"enabled\": true,\n  \"count\": 123,\n}\n"
                case "htm", "html": text = "<!DOCTYPE html>\n<!-- Generated text only -->\n<html lang=\"en\">\n  <body><h1>Orion 🧭</h1><p class=\"note\">Source &amp; text.</p></body>\n</html>\n"
                case "xml": text = "<?xml version=\"1.0\"?>\n<!-- Generated text only -->\n<project name=\"Orion 🧭\">\n  <item kind=\"note\">Source &amp; text.</item>\n</project>\n"
                case "md", "markdown": text = "# Orion 🧭\n\nA generated note with `inline code` and [documentation](https://example.invalid).\n\n```swift\nlet generated = 123\n```\n"
                case "dockerfile": text = "# Generated build file 🧭\nFROM alpine:3 AS base\nARG MODE=debug\nENV APP_NAME=\"Orion\"\nCOPY --from=base /source /app\nRUN <<'SCRIPT'\nFROM is content here\nSCRIPT\nEXPOSE 8080\n"
                case "makefile": text = "# Generated build file 🧭\nNAME := Orion\n.PHONY: build\nbuild: input.txt\n\t@echo \"$(NAME)\" $@\ninclude generated.mk\n"
                default: text = "Generated Orion text 🧭\n"
                }
                let file = directory.appendingPathComponent(type.sampleFilename)
                try Data(text.utf8).write(to: file, options: .withoutOverwriting)
                nativeFiles.append(file)
            }
            let application = directory.appendingPathComponent("Generated External.app"), own = directory.appendingPathComponent("Generated Traverse.app")
            for (url, id) in [(application, "com.traverse.generated.neverlaunch"), (own, "com.respawnstudios.traverse")] {
                let contents = url.appendingPathComponent("Contents"), binaries = contents.appendingPathComponent("MacOS")
                try FileManager().createDirectory(at: binaries, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let info = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleName": "Generated Application", "CFBundleExecutable": "NeverLaunch"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"), options: .withoutOverwriting)
                try Data("Never launch this generated fixture.\n".utf8).write(to: binaries.appendingPathComponent("NeverLaunch"), options: .withoutOverwriting)
            }
            return Fixture(directory: directory, first: first, second: second, application: application, ownApplication: own, nativeFiles: nativeFiles)
        }.value
    }
    @MainActor private final class Context {
        let owner: BrowserWindowController, settings: BrowserSettings, files: Fixture, root: URL
        var browser: BrowserViewController { owner.browser }
        var externalLaunches = 0, defaultLaunches = 0
        init(root: URL, files: Fixture) {
            self.files = files; self.root = root
            settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
            settings.showsHiddenFiles = true
            let large = ProcessInfo.processInfo.arguments.contains("--large-interface")
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = large ? .light : .dark
            settings.interfaceSize = .init(large ? 150 : 125)
            InterfacePresentation.shared.bind(settings)
            owner = BrowserWindowController(settings: settings)
            configureHost()
        }
        func configureHost() {
            let host = owner.browser
            host.permitsBackgroundVerification = true
            host.readVolumesForVerification = { [] }
            host.folderAccess = FolderAccessController(stateDirectory: nil)
            host.pinsController = BrowserPinsController(stateDirectory: nil)
            host.privateNames = ApplicationPrivateNames(directory: root.appendingPathComponent("state/names"), settings: settings)
            let nativeZIPUpdate = ProcessInfo.processInfo.arguments.contains("--native-original-update")
            let tarEditor = ProcessInfo.processInfo.arguments.contains("--tar-editor")
            if tarEditor {
                host.recoverableFileOperations = host.operationCoordinator.engine(at: root.appendingPathComponent("state/history"))
            } else if ProcessInfo.processInfo.arguments.contains("--interrupt-native-original-update") {
                host.recoverableFileOperations = RecoverableFileOperations(
                    journalDirectory: root.appendingPathComponent("state/history"),
                    qualifyingNativeZIPRetainedOriginalCheckpoint: GeneratedZIPRetainedCheckpoint.shared.afterRetainedOriginal,
                    protecting: [root.appendingPathComponent("state")], activity: ApplicationFileActivity.beginOperation,
                    authoredZIPMetadataPolicy: .nativeCreate)
            } else {
                host.recoverableFileOperations = RecoverableFileOperations(
                    journalDirectory: root.appendingPathComponent("state/history"),
                    protecting: [root.appendingPathComponent("state")], activity: ApplicationFileActivity.beginOperation,
                    authoredZIPMetadataPolicy: nativeZIPUpdate ? .nativeCreate : .exactSource,
                    authoredZIPOriginalUpdateNativePolicy: nativeZIPUpdate ? .qualifiedNativeStage : .held,
                    zipOneFilePublicExtractionPolicy: ArchiveExtractionActivation.qualifiedZIPFileAvailable
                        ? .sourceQualification : .held)
            }
            host.openAndShare.permitsVerification = true
            host.defaultOpenForVerification = { [weak self] url in
                guard let self, url == self.files.first else { return false }
                self.defaultLaunches += 1; return true
            }
            host.openAndShare.hooks.launch = { [weak self] urls, application, done in
                guard let self, urls == [self.files.first], application == self.files.application else {
                    done(CocoaError(.fileReadNoPermission)); return
                }
                self.externalLaunches += 1; done(nil)
            }
        }
        func select(_ url: URL) {
            owner.window?.makeKeyAndOrderFront(nil)
            browser.setFileSelection([url]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
        }
        func target(_ value: EditorOpeningTarget) throws {
            var p = settings.editorPreferences; try p.setTarget(value, forExtension: "json"); settings.updateEditorPreferences(p)
        }
        func open() { select(files.first); browser.openSelection(nil) }
        func drainOpen() async throws {
            try await EditorPreferencesVerification.wait("preferred-opening-real-preparation-drain") { !browser.openAndShare.verificationState.preparing && browser.openAndShare.verificationState.launches == 0 }
        }
    }
    private static func nativeDefaultChecks(_ c: Context) async throws -> [String] {
        try need(c.settings.editorPreferences.openingRules.isEmpty, "fresh-native-default-needs-no-rule")
        let editors = ApplicationLocalTextEditors.shared
        for url in c.files.nativeFiles {
            c.select(url)
            guard let row = c.browser.rowsByURL[url], c.browser.displayedEntries.indices.contains(row) else {
                throw Failure(stage: "native-default-listed-file")
            }
            let entry = c.browser.displayedEntries[row]
            try need(c.browser.fileOpeningAppearance(entry).cue == .editor, "ordinary-native-file-indicator")
            let column = c.browser.table.tableColumns.firstIndex { $0.identifier.rawValue == "name" }!
            c.browser.table.scrollRowToVisible(row)
            guard let cell = c.browser.table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView else {
                throw Failure(stage: "native-default-visible-name-cell")
            }
            try need(cell.imageView?.contentTintColor == .labelColor
                && cell.accessibilityHelp() == "Opens in Traverse Editor", "actual-native-opening-icon-and-accessible-reason")
            c.browser.openSelection(nil)
            try await wait("recommended-native-file-open") { editors.documentForVerification(at: url)?.window.surface.textView.isEditable == true }
            guard let doc = editors.documentForVerification(at: url) else { throw Failure(stage: "recommended-native-editor-missing") }
            let surface = doc.window.surface, text = surface.textView
            let body = text.string, generation = surface.generation
            let inferred = c.settings.editorPreferences.language(forFilename: url.lastPathComponent)
            if [.html, .xml, .markdown, .jsonc, .dockerfile, .makefile, .c, .cpp, .objectiveC, .objectiveCPP].contains(inferred) {
                let language = inferred
                try need(doc.window.language.titleOfSelectedItem == language.title, "native-markup-language-inference")
                if !ProcessInfo.processInfo.arguments.contains("--offscreen"), CGPreflightScreenCaptureAccess(), let window = doc.window.window {
                    window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(for: .milliseconds(120))
                    let evidence = c.files.directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("evidence")
                    try await GlassVerification.captureOwnedWindow(window, to: evidence.appendingPathComponent("editor-" + language.rawValue + ".png"))
                }
            }
            try need(!doc.isDirty && c.defaultLaunches == 0 && c.externalLaunches == 0
                && text.findHighlightColor == .systemBlue, "recommended-open-is-native-with-blue-find")
            var p = c.settings.editorPreferences; p.findHighlightColor = .purple
            c.settings.updateEditorPreferences(p)
            try await wait("live-find-color-binding") { text.findHighlightColor == .systemPurple }
            try need(text.string == body && surface.generation == generation && !doc.isDirty, "live-find-color-keeps-loaded-document")
            p.findHighlightColor = .blue; c.settings.updateEditorPreferences(p)
            doc.requestClose()
            try await wait("recommended-native-editor-closes") { doc.isClosed && editors.documentCount == 0 }
        }
        return ["Actual ordinary Open uses Traverse for supported text types and named configuration files with no per-type setup",
                "Actual name cells expose the native-opening cue; live Find color preserves the document"]
    }
    private static func overviewStartupChecks(_ c: Context, root: URL) async throws {
        try need(c.owner.isWorkspacePresentation, "ordinary-workspace-editor-acceptance-required")
        let workspace = c.owner.workspace
        c.settings.interfaceSize = .init(100); c.settings.appearance = .system
        let id = UUID()
        let saved = try (0..<4).map { index in
            try WorkspaceConnectionBookmark(kind: .sftpServer, serverID: UUID(), binding: Data(repeating: UInt8(index + 1), count: 32),
                title: "Generated server \(index + 1)", relativeToHome: true)
        }
        let tabs = [BrowserTab(location: .directory(c.files.directory)), BrowserTab(location: .directory(c.files.directory)),
            BrowserTab(location: .directory(c.files.directory)), BrowserTab(location: .computer),
            BrowserTab(location: .directory(c.files.directory)), BrowserTab(location: .computer), try saved[0].disconnectedTab()]
        let snapshot = PaneWorkspaceSnapshot(layout: PaneLayout(paneID: id), activePane: id,
            panes: [.init(id: id, tabs: try WorkspaceSession.capture(tabs, activeID: tabs[6].id), viewMode: BrowserViewMode.details.rawValue)])
        workspace.restoringSession = true
        try workspace.applyRestoredSnapshot(snapshot)
        workspace.restoringSession = false
        c.configureHost()
        let volumes = (0..<3).map { index in
            VolumeInfo(url: c.files.directory.appendingPathComponent("Generated Drive \(index)"), name: "Generated drive \(index)",
                kind: index == 0 ? .internalDisk : .externalDisk, totalBytes: 512 << 30, availableBytes: 256 << 30)
        }
        c.browser.volumes = volumes; c.browser.readVolumesForVerification = { volumes }
        c.browser.loadLocation()
        guard let overview = c.browser.tabs.last(where: { $0.location == .computer }) else {
            throw Failure(stage: "restored-overview-tab-missing")
        }
        c.browser.selectTab(overview.id)
        try await wait("ordinary-overview-ready") { !c.browser.isLoading }
        try need(c.browser.location == .computer && !c.browser.volumeBrowser.isHidden, "restored-overview-tab-visible")
        try await wait("ordinary-overview-transition-drained") { c.browser.canvasTransition == nil }
        c.browser.volumeBrowser.updateConnections([], saved: saved)
        c.owner.window?.contentView?.layoutSubtreeIfNeeded()
        c.browser.volumeBrowser.layoutSubtreeIfNeeded()
        let split = c.browser.splitController.splitView, volume = c.browser.volumeBrowser
        let body = split.arrangedSubviews.first
        let clip = volume.scrollView.contentView
        let value: [String: Any] = ["workspace": c.browser.workspace != nil,
            "browserWidth": c.browser.view.bounds.width,
            "stackWidth": c.browser.paneBody?.bounds.width ?? -1,
            "splitX": split.frame.minX,
            "splitIsControllerView": split === c.browser.splitController.view,
            "stackWidths": c.browser.paneBody?.arrangedSubviews.map { $0.frame.width } ?? [],
            "splitWidth": split.bounds.width, "splitItems": split.arrangedSubviews.count,
            "bodyX": body?.frame.minX ?? -1, "bodyWidth": body?.frame.width ?? -1,
            "surfaceX": c.browser.contentSurface?.frame.minX ?? -1,
            "surfaceWidth": c.browser.contentSurface?.frame.width ?? -1,
            "glassContentX": c.browser.contentSurface?.contentView.frame.minX ?? -1,
            "glassContentWidth": c.browser.contentSurface?.contentView.frame.width ?? -1,
            "volumeX": volume.frame.minX,
            "visibleX": volume.convert(volume.bounds, to: c.browser.view).minX,
            "volumeWidth": volume.bounds.width, "scrollX": volume.scrollView.frame.minX,
            "clipX": clip.bounds.minX, "clipWidth": clip.bounds.width,
            "documentX": clip.documentView?.frame.minX ?? -1, "documentWidth": clip.documentView?.frame.width ?? -1,
            "transparent": volume.contentBackgroundIsTransparent, "scrollPaints": volume.scrollView.drawsBackground,
            "clipPaints": clip.drawsBackground]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/overview-startup-geometry.json"), options: .withoutOverwriting)
        try need(split.arrangedSubviews.count == 1 && abs(body?.frame.minX ?? -1) < 1
            && abs((body?.frame.width ?? 0) - c.browser.view.bounds.width) < 1
            && abs(volume.convert(volume.bounds, to: c.browser.view).minX) < 1,
            "ordinary-overview-content-fills-workspace")
        try need(abs(clip.bounds.minX) < 1 && volume.contentBackgroundIsTransparent && !clip.drawsBackground,
            "ordinary-overview-startup-material-and-origin")
        if !ProcessInfo.processInfo.arguments.contains("--offscreen"), CGPreflightScreenCaptureAccess(), let window = c.owner.window {
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/overview-restored.png"))
        }
        c.settings.interfaceSize = .init(125); c.settings.appearance = .dark
        c.browser.navigate(to: .directory(c.files.directory))
        try await wait("ordinary-listing-after-overview") { !c.browser.isLoading && c.browser.orderingTask == nil }
    }
    private static func buildSyntaxChecks() throws {
        let docker = "# Generated 🧭\r\nFROM alpine AS base\r\nENV NAME=\"Orion\"\r\nCOPY --from=base /a /b\r\nRUN <<'SCRIPT'\r\nFROM literal\r\nSCRIPT\r\nEXPOSE 8080\r\n"
        let make = "# Generated 🧭\r\nNAME := Orion\r\nbuild: input\r\n\t@echo $(name#part) $@ # shell note\r\ninclude generated.mk\r\n"
        for (body, language) in [(docker, TextSyntaxLanguage.dockerfile), (make, .makefile)] {
            let value = try TextDocumentValue.original(Data(body.utf8))
            guard case .tokens(let tokens) = TextSyntax.color(value, language: language) else { throw Failure(stage: "build-language-tokenization") }
            let text = value.text as NSString
            var previousEnd = 0
            for token in tokens {
                try need(token.range.location >= previousEnd && token.range.length > 0 && NSMaxRange(token.range) <= text.length,
                         "build-language-utf16-ranges")
                previousEnd = NSMaxRange(token.range)
            }
            func has(_ fragment: String, _ kind: TextSyntaxToken.Kind) -> Bool {
                tokens.contains { $0.kind == kind && text.substring(with: $0.range) == fragment }
            }
            if language == .dockerfile {
                try need(has("FROM", .keyword) && has("--from", .property) && has("NAME", .property)
                    && has("\"Orion\"", .string) && has("FROM literal", .string) && has("8080", .number),
                    "dockerfile-directives-arguments-and-heredoc-content")
            } else {
                try need(has("NAME", .property) && has("build", .function) && has("$(name#part)", .property)
                    && has("$@", .property) && has("include", .keyword) && has("# shell note", .comment),
                    "makefile-rules-variables-and-comment-context")
            }
            if case .plain(.cancelled) = TextSyntax.color(value, language: language, cancelled: { true }) {} else {
                throw Failure(stage: "build-language-cancellation")
            }
        }
    }
    private static func cFamilySyntaxChecks() throws {
        let fixtures: [(String, TextSyntaxLanguage, [(String, TextSyntaxToken.Kind)])] = [
            ("#include <stdio.h>\r\n/* Generated 🧭 */\r\nint main(void) { printf(\"https://orion\"); return 42+2; }\r\n", .c,
             [("#include", .keyword), ("<stdio.h>", .string), ("/* Generated 🧭 */", .comment),
              ("int", .type), ("main", .function), ("printf", .function), ("\"https://orion\"", .string),
              ("return", .keyword), ("42", .number), ("+", .punctuation), ("2", .number)]),
            ("#include <string>\nconstexpr auto count = 1'024ULL;\nauto note = u8R\"orion(// not a comment\n/* text */ \"quoted\" 🧭)orion\";\nbool ready = true;\n", .cpp,
             [("constexpr", .keyword), ("1'024ULL", .number),
              ("u8R\"orion(// not a comment\n/* text */ \"quoted\" 🧭)orion\"", .string),
              ("bool", .type), ("true", .literal)]),
            ("#import <Foundation/Foundation.h>\n@interface Generated : NSObject\n@property(nonatomic) NSInteger count;\n@end\nNSString *title = @\"Orion 🧭\"; BOOL ready = YES;\n", .objectiveC,
             [("#import", .keyword), ("<Foundation/Foundation.h>", .string), ("@interface", .keyword),
              ("@property", .keyword), ("NSInteger", .type), ("@end", .keyword),
              ("@\"Orion 🧭\"", .string), ("YES", .literal)]),
            ("auto raw = R\"(// text)\"; NSString *title = @\"Orion\";\n", .objectiveCPP,
             [("R\"(// text)\"", .string), ("NSString", .type), ("@\"Orion\"", .string)]),
            ("#include \\\n    <stdio.h>\n", .c, [("#include", .keyword), ("<stdio.h>", .string)]),
            ("#include \\\r\n    <string>\r\n", .cpp, [("#include", .keyword), ("<string>", .string)])
        ]
        for (body, language, expected) in fixtures {
            let value = try TextDocumentValue.original(Data(body.utf8))
            guard case .tokens(let tokens) = TextSyntax.color(value, language: language) else {
                throw Failure(stage: "c-family-syntax-unavailable")
            }
            let text = value.text as NSString
            var end = 0
            for token in tokens {
                try need(token.range.location >= end && token.range.length > 0
                    && NSMaxRange(token.range) <= text.length, "c-family-ordered-utf16-ranges")
                end = NSMaxRange(token.range)
            }
            for (lexeme, kind) in expected {
                try need(tokens.contains { $0.kind == kind && text.substring(with: $0.range) == lexeme },
                    "c-family-distinct-lexical-role")
            }
            try need(tokens.filter { $0.kind == .comment }.count == expected.filter { $0.1 == .comment }.count,
                "c-family-string-content-is-not-comment")
        }
        let incomplete = try TextDocumentValue.original(Data("auto s = R\"tag(unfinished 🧭\n// content".utf8))
        guard case .tokens(let raw) = TextSyntax.color(incomplete, language: .cpp) else {
            throw Failure(stage: "c-family-incomplete-raw-string")
        }
        guard let last = raw.last else { throw Failure(stage: "c-family-incomplete-raw-string-token") }
        try need(last.kind == .string && NSMaxRange(last.range) == (incomplete.text as NSString).length,
            "c-family-incomplete-source-visible")
        guard case .plain(.cancelled) = TextSyntax.color(incomplete, language: .cpp, cancelled: { true }) else {
            throw Failure(stage: "c-family-cancellation")
        }
        let dense = try TextDocumentValue.original(Data(String(repeating: String(repeating: ";", count: 4096) + "\n", count: 17).utf8))
        guard case .plain(.tokenBudget) = TextSyntax.color(dense, language: .cpp) else {
            throw Failure(stage: "c-family-token-budget")
        }
        guard var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditorPreferences())) as? [String: Any] else {
            throw Failure(stage: "editor-preferences-json-object")
        }
        encoded["defaultLanguage"] = "future-language"; encoded["palette"] = "vivid"; encoded["basePointSize"] = 17
        let decoded = try JSONDecoder().decode(EditorPreferences.self, from: JSONSerialization.data(withJSONObject: encoded))
        try need(decoded.defaultLanguage == nil && decoded.palette == .vivid && decoded.basePointSize == 17,
            "unknown-optional-language-retains-preferences")
        encoded.removeValue(forKey: "backspaceUnindents")
        let oldPreferences = try JSONDecoder().decode(EditorPreferences.self, from: JSONSerialization.data(withJSONObject: encoded))
        try need(oldPreferences.backspaceUnindents, "older-preferences-get-smart-Backspace-default")
        encoded["backspaceUnindents"] = false
        let optedOut = try JSONDecoder().decode(EditorPreferences.self, from: JSONSerialization.data(withJSONObject: encoded))
        try need(!optedOut.backspaceUnindents
            && !JSONDecoder().decode(EditorPreferences.self, from: JSONEncoder().encode(optedOut)).backspaceUnindents,
            "explicit-Backspace-opt-out-survives-round-trip")
        try need(EditorOpeningSupport.fileTypes.count <= EditorPreferences.maximumOpeningRules,
            "every-supported-opening-type-fits-explicit-preferences")
    }

    private static func initialLayoutChecks(_ c: Context) async throws -> [String] {
        let previousSize = c.settings.interfaceSize
        c.settings.interfaceSize = .init(ProcessInfo.processInfo.arguments.contains("--large-interface") ? 150 : 100)
        defer { c.settings.interfaceSize = previousSize }
        let editor = NativeTextEditorWindow(displayName: "Generated first text layout", installChrome: {
            ToolWindowChrome.install(in: $0, settings: c.settings)
        })
        defer { editor.finishClose() }
        // Match the small, multiline shape of the reported remote Open without
        // retaining or processing that file's authored contents in the test.
        let generated = "# Generated Dockerfile layout →\n" + (1...29).map {
            "ENV GENERATED_\($0)=value\n"
        }.joined()
        let value = try TextDocumentValue.original(Data(generated.utf8))
        editor.surface.install(value)
        editor.applyEditorPreferences(c.settings.editorPreferences, pointSize: 13)
        InterfaceMetrics.setFont(editor.surface.textView, base: .monospacedSystemFont(ofSize: 13, weight: .regular))
        InterfacePresentation.shared.register(editor.surface)
        let text = editor.surface.textView
        try need((text.textContainer?.containerSize.width ?? 0) > 2 * text.textContainerInset.width + 10,
            "first-editor-layout-has-no-usable-text-width")
        let started = ContinuousClock.now
        let group = NativeTextEditorWindow.Group.connection(UUID())
        editor.presentEditor(in: group, arrangement: .tabs)
        try need(started.duration(to: .now) < .seconds(2), "first-editor-presentation-stalled")
        try need(text.string == value.text && editor.window?.isVisible == true,
            "first-editor-presentation-lost-text")
        let second = NativeTextEditorWindow(displayName: "Generated second layout", installChrome: {
            ToolWindowChrome.install(in: $0, settings: c.settings)
        })
        defer { second.finishClose() }
        second.surface.install(value)
        second.applyEditorPreferences(c.settings.editorPreferences, pointSize: 13)
        InterfaceMetrics.setFont(second.surface.textView, base: .monospacedSystemFont(ofSize: 13, weight: .regular))
        InterfacePresentation.shared.register(second.surface)
        second.presentEditor(in: group, arrangement: .tabs)
        try need(second.surface.textView.string == value.text && second.window?.isVisible == true,
            "second-editor-tab-presentation-lost-text")
        let largeText = String(repeating: "# Generated document line with a finite layout width.\n", count: 10_000)
        let large = try TextDocumentValue.original(Data(largeText.utf8))
        let surface = second.surface
        surface.install(large)
        let distant = ContinuousClock.now
        try need(surface.goToLine(10_000, generation: surface.generation), "large-editor-distant-line-refused")
        surface.setWrapping(false)
        surface.setPointSize(22)
        try need(surface.goToLine(1, generation: surface.generation), "large-editor-first-line-refused")
        surface.setWrapping(true)
        try need(surface.goToLine(10_000, generation: surface.generation)
            && surface.textView.string == large.text, "large-editor-font-wrap-scroll-changed-text")
        let layoutTime = distant.duration(to: .now)
        try need(layoutTime < .seconds(2), "large-editor-distant-layout-stalled")
        if !ProcessInfo.processInfo.arguments.contains("--offscreen"), CGPreflightScreenCaptureAccess(), let window = second.window {
            for line in [5_000, 10_000] {
                try need(surface.goToLine(line, generation: surface.generation), "gutter-scroll-line-refused")
                let clip = surface.scrollView.contentView
                let offset = min(max(0, surface.textView.bounds.height - clip.bounds.height), clip.bounds.minY + 7)
                clip.scroll(to: .init(x: clip.bounds.minX, y: offset))
                surface.scrollView.reflectScrolledClipView(clip)
                window.makeKeyAndOrderFront(nil)
                try await UIVerification.snapshot(window, to: c.root.appendingPathComponent("evidence/editor-gutter-\(line).png"))
            }
        }
        return ["Generated multiline documents present at\(c.settings.interfaceSize.percent)% through shared font/surface registration and native connection-tab grouping without changing text",
                "A10,000-line generated document scrolls to distant lines through font/wrap changes without changing text (\(layoutTime))"]
    }

    private static func extensionlessChecks(_ c: Context) async throws -> [String] {
        let url = c.files.directory.appendingPathComponent("Untitled")
        try await Task.detached {
            try Data("{}\n".utf8).write(to: url, options: .withoutOverwriting)
            guard chmod(url.path, 0o600) == 0 else { throw Failure(stage: "extensionless-source-mode") }
        }.value
        let original = c.settings.editorPreferences
        defer { c.settings.updateEditorPreferences(original) }
        var preferences = original
        preferences.defaultLanguage = nil; preferences.detectsLanguageWithoutExtension = true
        c.settings.updateEditorPreferences(preferences)
        let editors = ApplicationLocalTextEditors.shared
        editors.open(url, from: c.browser)
        try await wait("extensionless-detected-editor-open") {
            editors.documentForVerification(at: url)?.window.language.titleOfSelectedItem == TextSyntaxLanguage.json.title
        }
        guard let first = editors.documentForVerification(at: url) else { throw Failure(stage: "extensionless-editor-missing") }
        defer { if !first.isClosed { first.requestClose() } }
        let plain = TextSyntaxLanguage.allCases.firstIndex(of: .plain)!
        first.window.language.selectItem(at: plain)
        try need(first.window.language.sendAction(first.window.language.action, to: first.window.language.target), "extensionless-manual-mode-action")
        preferences.palette = preferences.palette == .vivid ? .adaptive : .vivid; c.settings.updateEditorPreferences(preferences)
        try await wait("extensionless-manual-choice-kept") { first.window.language.titleOfSelectedItem == TextSyntaxLanguage.plain.title }
        try need(!first.isDirty && first.window.surface.textView.string == "{}\n", "language-choice-does-not-edit")
        first.requestClose()
        try await wait("extensionless-first-document-drain") { first.isClosed && editors.documentForVerification(at: url) == nil }
        preferences.detectsLanguageWithoutExtension = false; c.settings.updateEditorPreferences(preferences)
        editors.open(url, from: c.browser)
        try await wait("extensionless-opt-out-open") { editors.documentForVerification(at: url)?.window.surface.textView.isEditable == true }
        guard let second = editors.documentForVerification(at: url) else { throw Failure(stage: "extensionless-second-editor") }
        defer { if !second.isClosed { second.requestClose() } }
        try need(second.window.language.titleOfSelectedItem == TextSyntaxLanguage.plain.title, "extensionless-opt-out-stays-plain")
        preferences.detectsLanguageWithoutExtension = true; c.settings.updateEditorPreferences(preferences)
        try await wait("extensionless-live-detection") { second.window.language.titleOfSelectedItem == TextSyntaxLanguage.json.title }
        let text = second.window.surface.textView
        text.setSelectedRange(.init(location: 1, length: 0)); text.insertNewline(nil); text.breakUndoCoalescing()
        try await wait("extensionless-smart-Return") { text.string == "{\n    \n}\n" && second.isDirty }
        text.undoManager?.undo()
        try await wait("extensionless-native-Undo") { text.string == "{}\n" && !second.isDirty }
        if !ProcessInfo.processInfo.arguments.contains("--offscreen"), CGPreflightScreenCaptureAccess(), let window = second.window.window {
            try await UIVerification.snapshot(window, to: c.root.appendingPathComponent("evidence/extensionless-editor.png"))
        }
        let unchanged = try await Task.detached { try Data(contentsOf: url) == Data("{}\n".utf8) }.value
        try need(unchanged && second.currentURL == url && c.defaultLaunches == 0 && c.externalLaunches == 0,
            "extensionless-source-and-filename-preserved-without-launch")
        return ["Extensionless JSON selects syntax through the shared background owner; manual choice and live opt-out win; smart Return/Undo leaves the source and filename unchanged"]
    }

    private static func documentChecks(_ c: Context) async throws -> [String] {
        var p = c.settings.editorPreferences
        p.palette = .vivid; p.basePointSize = 16; p.defaultLanguage = .json
        try p.setTarget(.traverse, forExtension: "json"); c.settings.updateEditorPreferences(p)
        c.open()
        let editors = ApplicationLocalTextEditors.shared
        try await wait("configured-native-editor-open") { editors.documentForVerification(at: c.files.first)?.window.surface.textView.isEditable == true }
        guard let doc = editors.documentForVerification(at: c.files.first) else { throw Failure(stage: "managed-native-editor-missing") }
        defer { if !doc.isClosed { doc.requestClose() } }
        let surface = doc.window.surface, text = surface.textView
        try need(!doc.isDirty && c.defaultLaunches == 0 && c.externalLaunches == 0, "configured-editor-open-never-external")
        try need(abs((text.font?.pointSize ?? 0) - 16 * InterfaceMetrics.scale) < 0.01, "editor-default-size-scaled-exactly-once")
        let contents = text.string, generation = surface.generation
        text.setSelectedRange(.init(location: 2, length: 5)); let selection = text.selectedRange()
        let undo = text.undoManager?.canUndo
        try await keyboardChecks(c, document: doc)
        p.wrapsLines = false; p.showsLineNumbers = false; p.basePointSize = 17; p.theme = .light
        c.settings.updateEditorPreferences(p)
        try await wait("live-native-editor-preferences") { !surface.wrapsLines && !surface.showsLineNumbers && abs((text.font?.pointSize ?? 0) - 17 * InterfaceMetrics.scale) < 0.01 }
        try need(text.string == contents && surface.generation == generation && text.selectedRange() == selection && text.undoManager?.canUndo == undo && !doc.isDirty,
                 "live-presentation-preserves-buffer-generation-selection-and-undo")
        doc.window.wrapping.performClick(nil)
        let plain = TextSyntaxLanguage.allCases.firstIndex(of: .plain)!
        doc.window.language.selectItem(at: plain)
        try need(doc.window.language.sendAction(doc.window.language.action, to: doc.window.language.target), "native-syntax-choice-action")
        p.defaultLanguage = .python; p.palette = .adaptive; p.theme = .dark; p.basePointSize = 18
        c.settings.updateEditorPreferences(p)
        try await wait("native-local-override-precedence") { surface.wrapsLines && doc.window.language.indexOfSelectedItem == plain && abs((text.font?.pointSize ?? 0) - 18 * InterfaceMetrics.scale) < 0.01 }
        doc.reload()
        try await wait("reload-keeps-local-presentation-choices") { !doc.hasPendingFileWork && text.isEditable }
        try need(surface.wrapsLines && doc.window.language.indexOfSelectedItem == plain && text.string == contents, "reload-lost-wrap-or-syntax-override")
        // Presentation and dispatch only: this local editor does not create a
        // remote refusal or grant retained-version read authority.
        if !ProcessInfo.processInfo.arguments.contains("--offscreen"), let native = doc.window.window {
            let previousCallback = doc.window.onRefusedVersion
            let previousTitle = doc.window.recoveryButton.title
            let beforeText = text.string, beforeGeneration = surface.generation
            let beforeDirty = doc.isDirty, beforeEdited = native.isDocumentEdited
            var requested: [RemoteRetainedTextChoice.Version] = []
            doc.window.onRefusedVersion = { requested.append($0) }
            defer {
                doc.window.onRefusedVersion = previousCallback
                doc.window.configureRefusedReview(available: false, enabled: false)
                doc.window.recoveryButton.title = previousTitle
            }
            doc.window.configureRefusedReview(available: true, enabled: true)
            native.makeKeyAndOrderFront(nil)
            try await wait("refused-review-presentation-key-window") { native.isKeyWindow }
            doc.window.beforeSaveButton.performClick(nil)
            doc.window.editedSaveButton.performClick(nil)
            try need(requested == [.before, .edited] && text.string == beforeText
                && surface.generation == beforeGeneration && doc.isDirty == beforeDirty
                && native.isDocumentEdited == beforeEdited,
                "refused-review-buttons-change-text-dirty-state-or-dispatch-wrong-version")
            if ProcessInfo.processInfo.arguments.contains("--large-interface"), !ProcessInfo.processInfo.arguments.contains("--offscreen"),
               let window = doc.window.window, let content = window.contentView {
                let previousSize = content.bounds.size
                window.setContentSize(.init(width: 720, height: 520)); content.layoutSubtreeIfNeeded()
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(300))
                let controls = [doc.window.saveButton, doc.window.saveAsButton, doc.window.reloadButton,
                    doc.window.recoveryButton, doc.window.beforeSaveButton, doc.window.editedSaveButton,
                    doc.window.wrapping, doc.window.language] as [NSView]
                for control in controls where !control.isHidden {
                    let frame = control.convert(control.bounds, to: content)
                    try need(frame.width > 0 && frame.height > 0 && content.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                        "enlarged-editor-controls-leave-narrow-content")
                }
                if CGPreflightScreenCaptureAccess() {
                    let evidence = c.files.directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("evidence")
                    try await GlassVerification.captureOwnedWindow(window, to: evidence.appendingPathComponent("editor-150-narrow.png"))
                }
                window.setContentSize(previousSize)
            }
        }
        try await tabPresentationChecks(c, first: doc)
        doc.requestClose(); try await wait("native-document-and-observer-closed") { doc.isClosed && editors.documentCount == 0 }
        return ["Actual ordinary Open uses the configured Traverse editor without an external launch", "Live preferences scale once and preserve buffer, generation, selection and Undo", "Per-window Wrap/Syntax choices survive preference changes and Reload; actual close drains"]
            + (ProcessInfo.processInfo.arguments.contains("--offscreen") ? [] : ["Refused-review presentation dispatches Before/Edited native buttons without changing text or dirty state; no backend refusal is inferred"])
            + (ProcessInfo.processInfo.arguments.contains("--offscreen") ? [] : ["Actual editor tabs keep separate buffers and Save menus, native Next/Previous and detach work, connection groups stay separate, and the separate-window preference preserves existing groups", "Explorer editor Control aliases follow the live preference through native menus; Mac Command actions remain and no clipboard/file write is made"])
    }
    private static func keyboardChecks(_ c: Context, document: LocalTextDocumentController) async throws {
        guard !ProcessInfo.processInfo.arguments.contains("--offscreen"), let window = document.window.window else { return }
        let native = document.window, text = native.surface.textView
        let original = text.string, generation = native.surface.generation, selection = text.selectedRange()
        let save = native.onSave
        var saves = 0
        native.onSave = { saves += 1 }
        defer { native.onSave = save; text.setSelectedRange(selection) }
        func hasControlSave() -> Bool {
            NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu?.items.contains {
                $0.title == "Save" && $0.isHidden && $0.allowsKeyEquivalentWhenHidden && $0.keyEquivalentModifierMask == .control
            } == true
        }
        func key(_ character: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
            NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key(character, code: code, flags: flags, window: window)) == true
        }
        try await wait("explorer-editor-control-menu") { hasControlSave() }
        try need(key("s", 1, .control) && saves == 1 && key("s", 1, .command) && saves == 2,
            "editor-control-save-and-command-save-dispatch")
        try need(key("f", 3, .control) && native.surface.find.isShown, "editor-control-find")
        native.surface.find.hide(); window.makeFirstResponder(text)
        try need(key("a", 0, .control) && text.selectedRange() == NSRange(location: 0, length: text.string.utf16.count),
            "editor-control-select-all")
        c.settings.keyboardProfile = .mac
        try await wait("mac-editor-control-alias-removal") { !hasControlSave() }
        try need(!key("s", 1, .control) && saves == 2 && key("s", 1, .command) && saves == 3,
            "mac-editor-keeps-native-command-menu-only")
        c.settings.keyboardProfile = .explorer
        try await wait("explorer-editor-control-alias-restored") { hasControlSave() }
        try need(text.string == original && native.surface.generation == generation && !document.isDirty,
            "editor-keyboard-preference-changed-document")
    }
    private static func tabPresentationChecks(_ c: Context, first: LocalTextDocumentController) async throws {
        guard !ProcessInfo.processInfo.arguments.contains("--offscreen") else { return }
        let editors = ApplicationLocalTextEditors.shared
        c.owner.window?.makeKeyAndOrderFront(nil)
        c.browser.setFileSelection([c.files.first, c.files.second]); c.browser.fileSelectionDidChange(); c.browser.focusBrowserContent()
        try need(c.browser.canEditTextInTraverse, "explicit-editor-selection-disabled")
        c.browser.editTextInTraverse(nil)
        try await wait("second-editor-tab-open") { editors.documentForVerification(at: c.files.second)?.window.surface.textView.isEditable == true }
        guard let second = editors.documentForVerification(at: c.files.second), let one = first.window.window,
              let two = second.window.window else { throw Failure(stage: "editor-tab-window-missing") }
        defer { if !second.isClosed { second.requestClose() } }
        try await wait("native-editor-tab-group") { one.tabGroup === two.tabGroup && two.tabGroup?.windows.count == 2 }
        let firstText = first.window.surface.textView.string, secondText = second.window.surface.textView.string
        try need(firstText != secondText, "editor-tabs-need-distinct-buffers")
        two.selectPreviousTab(nil)
        try await wait("previous-editor-tab-selected") { one.isKeyWindow }
        try need(NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu?.item(withTitle: "Save")?.target as AnyObject? === first.window,
            "first-tab-save-menu-owner")
        one.selectNextTab(nil)
        try await wait("next-editor-tab-selected") { two.isKeyWindow }
        try need(NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu?.item(withTitle: "Save")?.target as AnyObject? === second.window,
            "second-tab-save-menu-owner")
        if CGPreflightScreenCaptureAccess() {
            let evidence = c.files.directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("evidence")
            try await Task.sleep(for: .milliseconds(300))
            try await GlassVerification.captureOwnedWindow(two, to: evidence.appendingPathComponent("editor-native-tabs.png"))
        }
        let remote = NativeTextEditorWindow(displayName: "Generated connection group", installChrome: {
            ToolWindowChrome.install(in: $0, settings: c.settings)
        })
        defer { if remote.window?.isVisible == true { remote.finishClose() } }
        remote.presentEditor(in: .connection(UUID()), arrangement: .tabs)
        try need(remote.window?.tabbingIdentifier != one.tabbingIdentifier && remote.window?.tabGroup !== one.tabGroup,
            "connection-editor-joined-local-group")
        two.mergeAllWindows(nil)
        try need(remote.window?.tabGroup !== one.tabGroup, "native-merge-crossed-editor-connection-group")
        remote.finishClose(); two.makeKeyAndOrderFront(nil)
        c.owner.window?.makeKeyAndOrderFront(nil)
        let overCapacity = Array(c.files.nativeFiles.prefix(4))
        c.browser.setFileSelection(Set(overCapacity)); c.browser.fileSelectionDidChange(); c.browser.focusBrowserContent()
        c.browser.editTextInTraverse(nil)
        try need(editors.documentReservationCount == 2 && c.browser.status.stringValue.contains("this selection"),
            "over-capacity-selection-opened-partially")
        two.makeKeyAndOrderFront(nil)
        var preferences = c.settings.editorPreferences; preferences.windowArrangement = .separateWindows
        c.settings.updateEditorPreferences(preferences)
        try need(one.tabGroup === two.tabGroup, "preference-change-rearranged-open-documents")
        two.moveTabToNewWindow(nil)
        try await wait("editor-tab-detached") { one.tabGroup !== two.tabGroup }
        try need(first.window.surface.textView.string == firstText && second.window.surface.textView.string == secondText
            && !first.isDirty && !second.isDirty, "tab-navigation-or-detach-changed-document")
        guard let thirdURL = c.files.nativeFiles.first(where: { $0.pathExtension == "swift" }) else { throw Failure(stage: "third-editor-fixture-missing") }
        c.select(thirdURL); c.browser.openSelection(nil)
        try await wait("separate-editor-open") { editors.documentForVerification(at: thirdURL)?.window.surface.textView.isEditable == true }
        guard let third = editors.documentForVerification(at: thirdURL) else { throw Failure(stage: "separate-editor-missing") }
        defer { if !third.isClosed { third.requestClose() } }
        try need((third.window.window?.tabbedWindows?.count ?? 1) == 1, "separate-editor-preference-ignored")
        third.requestClose()
        try await wait("separate-editor-closed") { third.isClosed && editors.documentCount == 2 }
        second.requestClose()
        try await wait("detached-editor-closed-independently") { second.isClosed && !first.isClosed && editors.documentCount == 1 }
    }
    private static func openingChecks(_ c: Context) async throws -> [String] {
        try c.target(.externalApplication(c.files.application)); c.open(); try await c.drainOpen()
        try need(c.externalLaunches == 1 && c.defaultLaunches == 0, "guarded-configured-external-handoff")
        let fileMenu = BrowserMenus.menu(.file, target: c.browser)
        let contextMenu = BrowserMenus.fileContextMenu(target: c.browser)
        try need(fileMenu.items.contains { $0.action == #selector(BrowserViewController.openSelectedFileInDefaultApp(_:)) }
            && contextMenu.item(withTitle: "Open With")?.submenu != nil,
            "explicit-default-and-context-open-with-reachable")
        c.select(c.files.first); c.browser.openSelectedFileInDefaultApp(nil)
        try need(c.defaultLaunches == 1 && c.externalLaunches == 1, "explicit-default-app-bypasses-saved-rule")
        try c.target(.externalApplication(c.files.directory.appendingPathComponent("Missing.app"))); c.open(); try await c.drainOpen()
        try need(c.externalLaunches == 1 && c.defaultLaunches == 1 && c.browser.status.stringValue.contains("unavailable"), "unavailable-application-no-silent-fallback")
        try c.target(.externalApplication(c.files.ownApplication)); c.open(); try await c.drainOpen()
        try need(c.externalLaunches == 1 && c.defaultLaunches == 1, "recursive-traverse-rule-refused")
        try c.target(.systemDefault); c.open(); try await c.drainOpen()
        try need(c.defaultLaunches == 2 && c.externalLaunches == 1,
                 "ordinary-open-honors-explicit-macos-rule-without-changing-association")
        return ["Guarded app-specific handoff, explicit bypass and ordinary per-type macOS-default choice", "Unavailable and recursive Traverse app choices refuse without fallback or system preference changes"]
    }
    private static func staleChecks(_ c: Context) async throws -> [String] {
        // The preceding ZIP journey may leave this pane inside an archive.
        // Establish this local-opening scenario's own directory before arming
        // its preparation hold; selecting a local URL cannot change the route.
        c.browser.navigate(to: .directory(c.files.directory))
        try await wait("preferred-opening-local-directory-restored") {
            c.browser.currentArchive == nil && !c.browser.isLoading && c.browser.orderingTask == nil
                && c.browser.rowsByURL[c.files.first] != nil && c.browser.rowsByURL[c.files.second] != nil
        }
        for mode in ["selection", "preference", "file"] {
            try c.target(.externalApplication(c.files.application))
            let hold = Hold(); defer { hold.release() }
            c.browser.openAndShare.hooks.preferredOpeningBeforeRevalidation = { await hold.pause() }
            c.open(); try await wait("held-preferred-opening-" + mode) { hold.entered }
            switch mode {
            case "selection": c.select(c.files.second)
            case "preference": try c.target(.systemDefault)
            default:
                let file = c.files.first
                try await Task.detached { try Data("{\"changed\":true}\n".utf8).write(to: file, options: .atomic) }.value
            }
            hold.release(); try await c.drainOpen()
            try need(c.externalLaunches == 1 && c.defaultLaunches == 2, "stale-preferred-opening-was-launched-" + mode)
        }
        c.browser.openAndShare.hooks.preferredOpeningBeforeRevalidation = nil
        return ["Actual changed selection, preference and file observations refuse stale handoff and keep all preparations owned until drain"]
    }
    private static func openEditorSearchChecks(_ c: Context) async throws -> [String] {
        guard !ProcessInfo.processInfo.arguments.contains("--offscreen") else { return [] }
        let initialSize = c.settings.interfaceSize
        c.settings.interfaceSize = .init(100)
        defer { c.settings.interfaceSize = initialSize }
        let first = NativeTextEditorWindow(displayName: "Generated.json", installChrome: { ToolWindowChrome.install(in: $0, settings: c.settings) })
        let second = NativeTextEditorWindow(displayName: "Other.md", installChrome: { ToolWindowChrome.install(in: $0, settings: c.settings) })
        defer { first.finishClose(); second.finishClose() }
        let firstText = "{\n  \"name\": \"🧭 Orion\"\n}\n", secondText = "# Orion\nGenerated text only.\n"
        for (native, name, text) in [(first, "Generated.json", firstText), (second, "Other.md", secondText)] {
            native.bindKeyboardBehavior(to: c.settings)
            native.surface.install(try TextDocumentValue.original(Data(text.utf8)))
            native.update(displayName: name, dirty: false, status: "Generated search review",
                documentFormat: .init(bom: false, lineEnding: .lf), canSave: false, working: false,
                canReload: false, needsRecovery: false)
            native.presentEditor(in: .local, arrangement: .tabs)
        }
        second.configureReadOnlyPresentation()
        let search = second.openSearch
        try await wait("open-search-key-editor") { second.window?.isKeyWindow == true }
        let command = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: "Find in Open Editors…")
        try need(command?.target as AnyObject? === second && command?.keyEquivalentModifierMask == [.command, .shift],
            "open-search-native-menu-and-keyboard")
        try need(second.discoverableCommands().contains { $0.0.title == "Find in Open Editors…" }, "open-search-command-discovery")
        second.findInOpenEditors(nil)
        guard let panel = search.window else { throw Failure(stage: "open-search-native-panel") }
        try await wait("open-search-key-panel") { panel.isKeyWindow }
        search.query.stringValue = "orion"; search.updateMatches()
        try await wait("open-search-both-buffers") { !search.isWorking && search.matches.count == 2 }
        try need(search.matches.contains { $0.id == first.openSearchID && $0.line == 2 }
            && search.matches.contains { $0.id == second.openSearchID && $0.line == 1 }, "open-search-inactive-tab-and-readonly-buffer")
        search.matchesCase.state = .on; search.updateMatches()
        try await wait("open-search-case-filter") { !search.isWorking }
        try need(search.matches.isEmpty, "open-search-case-sensitive")
        search.matchesCase.state = .off
        search.query.stringValue = "Or"; search.matchMode.selectItem(at: 2); search.updateMatches()
        try await wait("open-search-word-filter") { !search.isWorking }
        try need(search.matches.isEmpty, "open-search-whole-word")
        search.query.stringValue = "Orion"; search.matchMode.selectItem(at: 0); search.updateMatches()
        try await wait("open-search-captured-result") { !search.isWorking && search.matches.count == 2 }
        guard let old = search.matches.firstIndex(where: { $0.id == first.openSearchID }) else { throw Failure(stage: "open-search-target-row") }
        search.table.selectRowIndexes(IndexSet(integer: old), byExtendingSelection: false)
        first.surface.install(try TextDocumentValue.original(Data(("New line\n" + firstText).utf8)))
        search.activateSelection(nil)
        try need(search.window === panel, "open-search-stale-result-must-not-jump")
        try await wait("open-search-stale-refresh") { !search.isWorking && search.matches.contains { $0.id == first.openSearchID && $0.line == 3 } }
        if CGPreflightScreenCaptureAccess() {
            try await Task.sleep(for: .milliseconds(250))
            try await GlassVerification.captureOwnedWindow(panel, to: c.root.appendingPathComponent("evidence/editor-open-search.png"))
            c.settings.interfaceSize = .init(150)
            try await Task.sleep(for: .milliseconds(250))
            try await GlassVerification.captureOwnedWindow(panel, to: c.root.appendingPathComponent("evidence/editor-open-search-150.png"))
            panel.title = "Find in Open Editors · generated review"
            let motion = try await NativeMotionRecorder.record(window: panel, root: c.root,
                label: "editor-open-search-entrance", sampling: .diagnostic(for: panel)) {
                CommandDiscoveryPresentation.animateEntrance(panel, motion: c.settings.motion)
            }
            try JSONEncoder().encode(motion).write(to: c.root.appendingPathComponent("evidence/editor-open-search-motion.json"), options: .withoutOverwriting)
        }
        guard let current = search.matches.firstIndex(where: { $0.id == first.openSearchID }) else { throw Failure(stage: "open-search-current-row") }
        let expected = search.matches[current].range
        search.table.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false)
        search.activateSelection(nil)
        try await wait("open-search-exact-target-tab") { first.window?.isKeyWindow == true && search.window == nil }
        try need(first.surface.textView.selectedRange() == expected
            && (first.surface.textView.string as NSString).substring(with: expected) == "Orion"
            && second.surface.textView.string == secondText, "open-search-unicode-selection-keeps-text")
        first.findInOpenEditors(nil)
        let currentSearch = first.openSearch
        try await wait("open-search-repeat-key") { currentSearch.window?.isKeyWindow == true }
        try need(currentSearch.query.stringValue == "Orion", "open-search-selected-text-prefill")
        currentSearch.query.stringValue = "Orion"; currentSearch.updateMatches()
        try await wait("open-search-repeat-result") { !currentSearch.isWorking && currentSearch.matches.count == 2 }
        guard let closing = currentSearch.matches.firstIndex(where: { $0.id == second.openSearchID }) else { throw Failure(stage: "open-search-closing-row") }
        currentSearch.table.selectRowIndexes(IndexSet(integer: closing), byExtendingSelection: false)
        await second.closeComparisonAndDrain(); second.finishClose()
        currentSearch.activateSelection(nil)
        try await wait("open-search-closed-result-refresh") { !currentSearch.isWorking && currentSearch.matches.count == 1 }
        try need(currentSearch.window != nil && currentSearch.matches.allSatisfy { $0.id == first.openSearchID }, "open-search-closed-document-not-reopened")
        currentSearch.query.stringValue = "o"; currentSearch.updateMatches()
        await currentSearch.closeAndDrain()
        try need(!currentSearch.isWorking && currentSearch.query.stringValue.isEmpty && currentSearch.matches.isEmpty,
            "open-search-dismiss-joins-and-clears-private-text")
        await first.closeComparisonAndDrain(); first.finishClose()
        return ["Find in Open Editors reuses the native command panel and bounded Unicode Find engine; active/inactive tabs and a read-only buffer share results, case/word filters and exact Unicode navigation",
            "Changed and closed results refresh instead of navigating stale ranges; dismissal joins pending work and clears transient queries/results without file, server, Save or export actions"]
    }
    private static func comparisonChecks(_ c: Context) async throws -> [String] {
        try await Task.detached {
            for (before, after) in [("", ""), ("", "new\n"), ("old\n", ""),
                ("é 🧭\n", "e\u{301} 🧭\n"), ("one\ntwo\n", "one\ntwo"),
                ("head\nold\nmiddle\nremoved\nend\n", "head\nnew\nmiddle\nend\nadded\n")] {
                let capture = EditorComparisonCapture(baseline: before, current: after,
                    format: .init(bom: false, lineEnding: .lf), language: .plain)
                let result = try EditorTextComparison.prepare(capture, cancelled: { false })
                var rebuilt = before as NSString
                for change in result.changes.reversed() {
                    let replacement = (after as NSString).substring(with: change.currentRange)
                    rebuilt = rebuilt.replacingCharacters(in: change.beforeRange, with: replacement) as NSString
                }
                guard (rebuilt as String).utf8.elementsEqual(after.utf8),
                      before.utf8.elementsEqual(after.utf8) == result.changes.isEmpty else { throw Failure(stage: "comparison-exact-reconstruction") }
            }
            let large = EditorComparisonCapture(baseline: (0..<1_100).map { "old\($0)\n" }.joined(),
                current: (0..<1_100).map { "new\($0)\n" }.joined(),
                format: .init(bom: false, lineEnding: .lf), language: .plain)
            let bounded = try EditorTextComparison.prepare(large, cancelled: { false })
            guard bounded.grouped, bounded.changes.count == 1 else { throw Failure(stage: "comparison-bounded-coarse-overview") }
            do {
                _ = try EditorTextComparison.prepare(large, cancelled: { true })
                throw Failure(stage: "comparison-cancellation")
            } catch is CancellationError {}
        }.value

        let original = try await Task.detached { try Data(contentsOf: c.files.first) }.value
        try c.target(.traverse); c.open()
        let editors = ApplicationLocalTextEditors.shared
        try await wait("comparison-editor-open") {
            guard let document = editors.documentForVerification(at: c.files.first) else { return false }
            return !document.hasPendingFileWork && !document.hasPendingSave
                && document.window.saveAsButton.isEnabled && document.window.surface.textView.isEditable
        }
        guard let document = editors.documentForVerification(at: c.files.first), let native = document.window.window else { throw Failure(stage: "comparison-real-document") }
        let text = document.window.surface.textView, before = text.string
        text.breakUndoCoalescing()
        text.setSelectedRange(.init(location: text.string.utf16.count, length: 0)); text.insertText("\nGenerated comparison 🧭\n", replacementRange: text.selectedRange())
        text.breakUndoCoalescing()
        let after = text.string
        native.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("comparison-editor-key-window") { NSApp.isActive && native.isKeyWindow }
        let editorWindowMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        try need(editorWindowMenu != nil && NSApp.windowsMenu === editorWindowMenu
            && editorWindowMenu?.item(withTitle: "Minimize")?.action == #selector(NSWindow.performMiniaturize(_:))
            && editorWindowMenu?.items.contains(where: { ($0.target as? NSWindow) === c.owner.window }) == true,
            "editor-native-Window-menu-reaches-browser")
        document.window.compareChanges(nil)
        guard let comparison = document.window.comparisonForVerification, let window = comparison.window else { throw Failure(stage: "comparison-native-command") }
        try await wait("comparison-real-preparation") { comparison.planForVerification != nil && !comparison.hasWorkForVerification }
        try need(comparison.beforeSurface.textView.string == before && comparison.currentSurface.textView.string == after
            && !comparison.beforeSurface.textView.isEditable && !comparison.currentSurface.textView.isEditable,
            "comparison-readonly-exact-captured-pair")
        let comparisonFile = NSApp.mainMenu?.item(withTitle: "File")?.submenu
        let comparisonEdit = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu
        try need(EditorMenuOwnership.owns(comparison) && comparisonFile?.item(withTitle: "Save") == nil
            && comparisonEdit?.item(withTitle: "Copy")?.target == nil,
            "comparison-native-copy-menu-has-no-file-writing-command")
        try need(NSApp.windowsMenu === NSApp.mainMenu?.item(withTitle: "Window")?.submenu
            && NSApp.windowsMenu?.items.contains(where: { ($0.target as? NSWindow) === native }) == true,
            "comparison-native-Window-menu-keeps-editor")
        guard let windows = NSApp.windowsMenu,
              let browserIndex = windows.items.firstIndex(where: { ($0.target as? NSWindow) === c.owner.window }) else {
            throw Failure(stage: "comparison-native-browser-window-entry")
        }
        windows.performActionForItem(at: browserIndex)
        try await wait("comparison-native-Window-returns-to-browser") { c.owner.window?.isKeyWindow == true }
        try need(!EditorMenuOwnership.owns(comparison)
            && NSApp.windowsMenu === NSApp.mainMenu?.item(withTitle: "Window")?.submenu,
            "comparison-browser-restores-window-menu-owner")
        guard let restored = NSApp.windowsMenu,
              let comparisonIndex = restored.items.firstIndex(where: { ($0.target as? NSWindow) === window }) else {
            throw Failure(stage: "comparison-native-comparison-window-entry")
        }
        restored.performActionForItem(at: comparisonIndex)
        try await wait("comparison-native-Window-returns-to-comparison") { window.isKeyWindow && EditorMenuOwnership.owns(comparison) }
        try need(text.string == after && comparison.currentSurface.textView.string == after,
            "native-window-switch-preserves-editor-and-comparison-text")
        comparison.navigate(1); comparison.navigate(-1)
        let oldFrame = window.frame
        try need(oldFrame.width > 1000 && oldFrame.height < 850,
            "comparison-default-viewport-is-paired-and-bounded")
        window.setContentSize(.init(width: 680, height: 680)); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        try need(comparison.beforeSurface.window === window && comparison.currentSurface.window === window,
            "comparison-adaptive-keeps-native-surfaces")
        try need(window.frame.height < 850 && window.frame.width < 850,
            "comparison-stacked-viewport-does-not-grow-to-document-height")
        if !ProcessInfo.processInfo.arguments.contains("--offscreen"), CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(window, to: c.root.appendingPathComponent("evidence/editor-comparison-stacked.png"))
            window.setFrame(oldFrame, display: true); try await Task.sleep(for: .milliseconds(400))
            let first = comparison.beforeSurface.convert(comparison.beforeSurface.bounds, to: window.contentView)
            let second = comparison.currentSurface.convert(comparison.currentSurface.bounds, to: window.contentView)
            try need(first.maxX < second.minX && abs(first.minY - second.minY) < 2,
                "comparison-wide-panes-actually-paired")
            try await GlassVerification.captureOwnedWindow(window, to: c.root.appendingPathComponent("evidence/editor-comparison-paired.png"))
        }
        if ProcessInfo.processInfo.arguments.contains("--check-development-motion"),
           !ProcessInfo.processInfo.arguments.contains("--offscreen") {
            window.makeKeyAndOrderFront(nil)
            let originalTitle = window.title
            window.title = "Compare Changes · generated review"
            var clips: [String: NativeMotionRecorder.Report] = [:]
            clips["editor-comparison-stack"] = try await NativeMotionRecorder.record(window: window, root: c.root,
                label: "editor-comparison-stack", sampling: .diagnostic(for: window)) { c.settings.interfaceSize = .init(150) }
            try await wait("comparison-live-large-font") {
                abs((comparison.currentSurface.textView.font?.pointSize ?? 0) - CGFloat(c.settings.editorPreferences.basePointSize) * 1.5) < 0.01
            }
            let top = comparison.beforeSurface.convert(comparison.beforeSurface.bounds, to: window.contentView)
            let bottom = comparison.currentSurface.convert(comparison.currentSurface.bounds, to: window.contentView)
            try need(abs(top.minX - bottom.minX) < 2 && top.intersection(bottom).isEmpty,
                "comparison-large-interface-stacks-real-native-panes")
            clips["editor-comparison-pair"] = try await NativeMotionRecorder.record(window: window, root: c.root,
                label: "editor-comparison-pair", sampling: .diagnostic(for: window)) { c.settings.interfaceSize = .init(125) }
            try JSONEncoder().encode(clips).write(to: c.root.appendingPathComponent("evidence/comparison-motion.json"), options: .withoutOverwriting)
            window.title = originalTitle
        }
        native.makeKeyAndOrderFront(nil)
        try need(EditorMenuOwnership.owns(document.window)
            && NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Save") != nil,
            "comparison-return-restores-the-exact-editor-menu")
        text.breakUndoCoalescing()
        text.insertText("Later edit\n", replacementRange: .init(location: text.string.utf16.count, length: 0))
        text.breakUndoCoalescing()
        try need(comparison.currentSurface.textView.string == after, "comparison-snapshot-does-not-follow-later-edit")
        comparison.refresh()
        try await wait("comparison-explicit-refresh") { !comparison.hasWorkForVerification }
        try need(comparison.currentSurface.textView.string == text.string && comparison.beforeSurface.textView.string == before,
            "comparison-explicit-refresh-uses-existing-owner-baseline")
        await document.window.closeComparisonAndDrain()
        try need(comparison.closed && comparison.beforeSurface.textView.string.isEmpty && comparison.currentSurface.textView.string.isEmpty,
            "comparison-close-drains-and-clears-captured-text")
        text.undoManager?.undo(); text.undoManager?.undo()
        try await wait("comparison-native-undo") { text.string == before && !document.isDirty }
        native.makeKeyAndOrderFront(nil); document.window.compareChanges(nil)
        guard let pending = document.window.comparisonForVerification else { throw Failure(stage: "comparison-parent-close-reopens") }
        document.requestClose(); try await wait("comparison-document-close") { document.isClosed && editors.documentCount == 0 }
        try need(pending.closed && !pending.hasWorkForVerification && pending.beforeSurface.textView.string.isEmpty
            && pending.currentSurface.textView.string.isEmpty, "comparison-parent-close-joins-pending-preparation")
        let retained = try await Task.detached { try Data(contentsOf: c.files.first) }.value
        try need(retained == original, "comparison-never-writes-original")
        return ["Native Compare Changes uses the real local document baseline, Unicode-exact bounded line differences, paired/stacked read-only views and explicit snapshot refresh",
            "Native Window commands switch between the open browser, editor and comparison without closing documents; main/Window menu ownership follows the key window",
            "Comparison cancellation/close drains actual work and clears both buffers; native Undo and the unchanged generated original remain intact"]
    }
    static func run() async {
        var root: URL?, context: Context?, checks: [String] = [], failure: String?
        let coldTAR = ProcessInfo.processInfo.arguments.contains("--tar-editor-cold-undo")
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "scope") }
            let area = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String: Any]
            try need(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: area.lastPathComponent)?.uuidString == area.lastPathComponent
                && marker?["action"] as? String == "native-editor-preferences" && Bundle.main.bundleIdentifier == "local.macexplorer.development", "exact-generated-editor-preferences-scope")
            let archiveOnly = ProcessInfo.processInfo.arguments.contains("--archive-editor-only")
            root = area
            if coldTAR {
                try need(archiveOnly && ProcessInfo.processInfo.arguments.contains("--tar-editor"), "cold-tar-check-profile")
                checks += try await ArchiveTextEditorVerification.coldTAR(root: area)
            } else {
            if !archiveOnly { checks += try EditorSettingsAppChecks.check() }
            let files = try await fixture(area), c = Context(root: area, files: files); context = c
            c.owner.showWindow(nil); c.owner.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if ProcessInfo.processInfo.arguments.contains("--offscreen") { c.owner.window?.setFrameOrigin(.init(x: -12000, y: -12000)) }
            c.browser.navigate(to: .directory(files.directory))
            try await wait("generated-preferences-listing") { !c.browser.isLoading && c.browser.orderingTask == nil && c.browser.displayedEntries.count == EditorOpeningSupport.fileTypes.count + 3 }
            if !archiveOnly {
                try buildSyntaxChecks()
                checks += ["Dockerfile/Makefile lexical roles preserve UTF-16 ranges, heredoc content and cancellation"]
                try cFamilySyntaxChecks()
                checks += ["C/C++/Objective-C source and headers use bounded lexical roles for directives, comments, ordinary/raw strings, numbers, types and functions; incomplete text and unknown optional language preferences remain readable"]
                try await overviewStartupChecks(c, root: area)
                checks += ["Populated seven-tab workspace restoration keeps the disconnected-server card bounded without shrinking the pane; switching to This Mac fills its width and preserves Glass"]
                checks += try await initialLayoutChecks(c)
                checks += try await nativeDefaultChecks(c)
                checks += try await extensionlessChecks(c)
                checks += try await comparisonChecks(c)
                checks += try await openEditorSearchChecks(c)
                checks += try await documentChecks(c)
                checks += try await openingChecks(c)
            }
            checks += try await ArchiveTextEditorVerification.check(root: area, browser: c.browser, sources: [files.first, files.second])
            if !archiveOnly { checks += try await staleChecks(c) }
            }
        } catch {
            if case EditorSettingsAppChecks.Failure.check(let label) = error { failure = label }
            else if let error = error as? ArchiveTextEditorVerification.Failure { failure = error.stage }
            else if let error = error as? NativeMotionRecorder.Failure { failure = "editor-motion-" + error.rawValue }
            else { failure = (error as? Failure)?.stage
                ?? "editor-error-" + String(reflecting: type(of: error)) + "-" + String((error as NSError).code) }
        }
        context?.browser.openAndShare.windowWillClose()
        context?.browser.suspendBrowser(); context?.owner.window?.performClose(nil)
        let drains = await ApplicationNativeSharing.cancelPreparationsAndDrain()
        if let root {
            let value: [String: Any] = ["passed": failure == nil && drains && ApplicationLocalTextEditors.shared.documentCount == 0,
                "checks": checks, "failure": failure as Any? ?? NSNull(), "externalLaunchesIntercepted": context?.externalLaunches ?? 0,
                "defaultLaunchesIntercepted": context?.defaultLaunches ?? 0, "actualExternalLaunches": 0, "systemAssociationsChanged": 0,
                "networkRequests": 0, "keychainCalls": 0, "actualOwnerDrain": drains && ApplicationFileActivity.gate.activeCount == 0,
                "offscreenFunctionalFlow": ProcessInfo.processInfo.arguments.contains("--offscreen"),
                "focusedArchiveEditor": ProcessInfo.processInfo.arguments.contains("--archive-editor-only"),
                "interfacePercent": context?.settings.interfaceSize.percent ?? 0,
                "nativeWindowsClosed": NSApp.windows.filter { $0.isVisible }.isEmpty]
            let report = coldTAR ? "native-editor-preferences-cold.json" : "native-editor-preferences.json"
            try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/" + report), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
}
#endif
