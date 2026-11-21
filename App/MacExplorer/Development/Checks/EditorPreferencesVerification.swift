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
    private nonisolated static func need(_ condition: Bool, _ stage: String) throws { if !condition { throw Failure(stage: stage) } }
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
                case "swift": text = "public struct Orion {\n    public func chart() {}\n}\n"
                case "py": text = "class Orion:\n    async def chart(self):\n        pass\n"
                case "rs": text = "pub(crate) mod orion {\n    pub(super) fn chart() {}\n}\n"
                case "js": text = "export class Orion {}\nexport const chart = async (label = \")\") => label;\n"
                case "ts": text = "export interface Orion { label: string }\nexport const chart = (track: Orion): string => track.label;\n"
                case "css": text = ".generated { color: #123abc; }\n"
                case "jsonc": text = "{\n  // Generated configuration only\n  \"project\" /* label */: \"Orion 🧭\",\n  \"enabled\": true,\n  \"count\": 123,\n}\n"
                case "jsonl", "ndjson": text = "{\"project\":\"Orion 🧭\"}\n{\"done\":true}\n"
                case "yaml", "yml": text = "orion:\n  chart: star\n"
                case "htm", "html": text = "<!DOCTYPE html>\n<!-- Generated text only -->\n<html lang=\"en\">\n  <body><h1>Orion 🧭</h1><p class=\"note\">Source &amp; text.</p></body>\n</html>\n"
                case "xml": text = "<?xml version=\"1.0\"?>\n<!-- Generated text only -->\n<project name=\"Orion 🧭\">\n  <item kind=\"note\">Source &amp; text.</item>\n</project>\n"
                case "md", "markdown": text = "# Orion 🧭\n\nA generated note with `inline code` and [documentation](https://example.invalid).\n\n## Chart\n\n```swift\nlet generated = 123\n```\n"
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
        let zipRecoveryCheckpoint: GeneratedZIPRetainedCheckpoint?
        var browser: BrowserViewController { owner.browser }
        var externalLaunches = 0, defaultLaunches = 0
        init(root: URL, files: Fixture) {
            self.files = files; self.root = root
            zipRecoveryCheckpoint = ProcessInfo.processInfo.arguments.contains("--interrupt-native-original-update")
                ? GeneratedZIPRetainedCheckpoint() : nil
            settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
            settings.showsHiddenFiles = true
            let large = ProcessInfo.processInfo.arguments.contains("--large-interface")
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = large ? .light : .dark
            settings.interfaceSize = .init(large ? 150 : 125)
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--motion-mode"),
               let value = arguments.dropFirst(index + 1).first, let mode = BrowserMotionMode(rawValue: value) {
                settings.motion.mode = mode
            }
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
            } else if let zipRecoveryCheckpoint {
                host.recoverableFileOperations = RecoverableFileOperations(
                    journalDirectory: root.appendingPathComponent("state/history"),
                    qualifyingNativeZIPRetainedOriginalCheckpoint: zipRecoveryCheckpoint.afterRetainedOriginal,
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
        encoded.removeValue(forKey: "showsWhitespaceMarks")
        let oldPreferences = try JSONDecoder().decode(EditorPreferences.self, from: JSONSerialization.data(withJSONObject: encoded))
        try need(oldPreferences.backspaceUnindents && !oldPreferences.showsWhitespaceMarks, "older-preferences-get-editing-defaults")
        encoded["backspaceUnindents"] = false
        encoded["showsWhitespaceMarks"] = true
        let optedOut = try JSONDecoder().decode(EditorPreferences.self, from: JSONSerialization.data(withJSONObject: encoded))
        let roundTrip = try JSONDecoder().decode(EditorPreferences.self, from: JSONEncoder().encode(optedOut))
        try need(!roundTrip.backspaceUnindents && roundTrip.showsWhitespaceMarks,
            "explicit-Backspace-and-whitespace-preferences-survive-round-trip")
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
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let native = doc.window.window {
            c.settings.motion = .init(mode: .full)
            let retainedText = text.string, retainedGeneration = surface.generation
            doc.window.showWindow(nil); native.makeKeyAndOrderFront(nil)
            try await wait("local-editor-close-foreground") { native.isKeyWindow && native.isOnActiveSpace
                && native.occlusionState.contains(.visible) }
            doc.window.window?.performClose(nil)
            let interruptedQuit = Task { await doc.closeForTermination() }
            try await wait("local-editor-accepted-close-gate") { ToolWindowCloseMotion.isClosing(native) }
            // A direct unexpected native dismissal is distinct from a second
            // user Close, which the view correctly refuses during the fade.
            native.close()
            try need(!(await interruptedQuit.value), "local-editor-interrupted-close-reported-success")
            try await wait("local-editor-retained-buffer-reopened") { native.isVisible && text.isEditable }
            try need(!doc.isClosed && text.string == retainedText && surface.generation == retainedGeneration
                && editors.documentCount == 1, "local-editor-interrupted-close-lost-owned-text")
        }
        doc.window.window?.performClose(nil)
        async let firstQuit = doc.closeForTermination()
        async let secondQuit = doc.closeForTermination()
        let joined = await (firstQuit, secondQuit)
        try need(joined.0 && joined.1, "local-editor-concurrent-quit-did-not-join-close")
        try await wait("native-document-and-observer-closed") { doc.isClosed && editors.documentCount == 0 }
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
        func hasControlComment() -> Bool {
            UIVerification.menuItem("Edit", "Lines")?.submenu?.items.contains {
                $0.title == "Toggle Line Comment" && $0.isHidden && $0.allowsKeyEquivalentWhenHidden
                    && $0.keyEquivalentModifierMask == .control && $0.keyEquivalent == "/"
            } == true
        }
        func key(_ character: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
            NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key(character, code: code, flags: flags, window: window)) == true
        }
        try await wait("explorer-editor-control-menu") { hasControlSave() && hasControlComment() }
        try need(key("s", 1, .control) && saves == 1 && key("s", 1, .command) && saves == 2,
            "editor-control-save-and-command-save-dispatch")
        let sentFind = key("f", 3, .control)
        try need(sentFind && native.surface.find.isShown,
            "editor-control-find dispatched=\(sentFind) opensEditorSearch=\(native.openSearch.window != nil) key=\(window.isKeyWindow)")
        native.surface.find.hide(); window.makeFirstResponder(text)
        try need(key("a", 0, .control) && text.selectedRange() == NSRange(location: 0, length: text.string.utf16.count),
            "editor-control-select-all")
        c.settings.keyboardProfile = .mac
        try await wait("mac-editor-control-alias-removal") { !hasControlSave() && !hasControlComment() }
        try need(!key("s", 1, .control) && saves == 2 && key("s", 1, .command) && saves == 3,
            "mac-editor-keeps-native-command-menu-only")
        c.settings.keyboardProfile = .explorer
        try await wait("explorer-editor-control-alias-restored") { hasControlSave() && hasControlComment() }
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
        let firstText = "{\n  \"name\": \"🧭 Orion\"\n}\n"
        let secondText = "# Orion\n" + String(repeating: "Generated text only.\n", count: 120)
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
        try await wait("open-search-key-editor") { second.window?.isKeyWindow == true && second.surface.canGoToLine }
        let originalCaret = NSRange(location: "# Orion\n".utf16.count + "Generated text only.\n".utf16.count * 66, length: 9)
        second.surface.textView.setSelectedRange(originalCaret)
        second.surface.textView.scrollRangeToVisible(originalCaret)
        guard let originalViewport = second.surface.navigationPosition()?.anchor, originalViewport.line > 0 else {
            throw Failure(stage: "open-search-origin-viewport")
        }
        let command = UIVerification.menuItem("Edit", "Find in Open Editors…")
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
                NativeMotionRecorder.replayToolWindowEntrance(panel)
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
        try visitTextLocation("Previous Text Location", from: first)
        try await wait("open-search-previous-document-focus") { second.window?.isKeyWindow == true }
        try need(second.surface.textView.selectedRange() == originalCaret, "open-search-previous-restores-selection")
        let restoredViewport = second.surface.navigationPosition()?.anchor
        try need(restoredViewport?.line == originalViewport.line && restoredViewport?.column == originalViewport.column
            && abs((restoredViewport?.fragmentProgress ?? 1) - originalViewport.fragmentProgress) <= 0.06,
            "open-search-previous-restores-viewport-\(originalViewport.line)-to-\(restoredViewport?.line ?? -1)")
        try visitTextLocation("Next Text Location", from: second)
        try await wait("open-search-next-document-focus") { first.window?.isKeyWindow == true }
        try need(first.surface.textView.selectedRange() == expected, "open-search-next-restores-exact-unicode-match")
        second.surface.install(try TextDocumentValue.original(Data((secondText + "Replacement generation\n").utf8)))
        let previous = UIVerification.menuItem("Go", "Previous Text Location")
        try need(previous.map(first.validateUserInterfaceItem) == false, "open-search-text-location-refuses-replaced-generation")
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
        try await verifyOpenEditorComparison(first, c: c)
        await first.closeComparisonAndDrain(); first.finishClose()
        return ["Find in Open Editors reuses the native command panel and bounded Unicode Find engine; active/inactive tabs and a read-only buffer share results, case/word filters and exact Unicode navigation",
            "Previous and Next Text Location return across native editor tabs to the original selection and viewport, and discard a replaced buffer generation",
            "Changed and closed results refresh instead of navigating stale ranges; dismissal joins pending work and clears transient queries/results without file, server, Save or export actions",
            "Compare with Open Editor uses the native File menu, exact open-buffer snapshots, format and generation checks, and keeps the prior comparison after a peer closes"]
    }

    private static func verifyOpenEditorComparison(_ first: NativeTextEditorWindow, c: Context) async throws {
        let peer = NativeTextEditorWindow(displayName: "Generated peer.md", installChrome: {
            ToolWindowChrome.install(in: $0, settings: c.settings)
        })
        peer.shouldClose = { true }
        defer { peer.finishClose() }
        peer.bindKeyboardBehavior(to: c.settings)
        let current = try TextDocumentValue.original(Data([0xef, 0xbb, 0xbf]) + Data("Peer first\r\n".utf8))
        let changed = try TextDocumentValue.original(Data([0xef, 0xbb, 0xbf]) + Data("Peer changed\r\n".utf8))
        peer.surface.install(current)
        peer.update(displayName: "Generated peer.md", dirty: false, status: "Generated comparison",
            documentFormat: current.format, canSave: false, working: false, canReload: false, needsRecovery: false)
        peer.selectLanguage(.markdown); peer.configureReadOnlyPresentation()
        peer.presentEditor(in: .local, arrangement: .tabs)
        guard let parent = first.window else { throw Failure(stage: "compare-open-editor-parent") }
        parent.tabGroup?.selectedWindow = parent
        parent.makeKeyAndOrderFront(nil)
        try await wait("compare-open-editor-source-native") { parent.isKeyWindow }
        let original = first.surface.textView.string
        first.surface.textView.insertText("Unsaved line\n", replacementRange: .init(location: 0, length: 0))
        let draft = first.surface.textView.string, generation = first.surface.generation
        try need(draft == "Unsaved line\n" + original, "compare-open-editor-real-unsaved-edit")
        guard let command = UIVerification.menuItem("File", "Compare", "Compare with Open Editor…"),
              let action = command.action else { throw Failure(stage: "compare-open-editor-command") }
        try need(first.discoverableCommands().contains { $0.0 === command && $0.1 == "File › Compare" }
            && first.validateUserInterfaceItem(command)
            && NSApp.sendAction(action, to: first, from: command), "compare-open-editor-native-menu")
        try await wait("compare-open-editor-picker") { first.openSearch.window?.isKeyWindow == true }
        guard let picker = first.openSearch.window else { throw Failure(stage: "compare-open-editor-window") }
        for letter in "peer" { picker.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: picker)) }
        try need(first.openSearch.table.numberOfRows == 1 && first.openSearch.table.selectedRow == 0,
            "compare-open-editor-typed-name-and-native-selection")
        peer.surface.install(changed)
        picker.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: picker))
        try need(first.openSearch.window === picker && first.openEditorComparisonForVerification == nil
            && first.openSearch.status.stringValue.contains("editor changed"), "compare-open-editor-stale-refusal")
        picker.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: picker))
        try await wait("compare-open-editor-prepared") {
            first.openEditorComparisonForVerification?.planForVerification != nil && first.openSearch.window == nil
        }
        guard let compare = first.openEditorComparisonForVerification, let window = compare.window else {
            throw Failure(stage: "compare-open-editor-result")
        }
        try need(compare.planForVerification?.before.text == draft && compare.planForVerification?.current.encoded == changed.encoded
            && compare.labels.left == "Generated.json" && compare.labels.right == "Generated peer.md"
            && !compare.beforeSurface.textView.isEditable && !compare.currentSurface.textView.isEditable,
            "compare-open-editor-exact-buffer-custody")
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(window, to: c.root.appendingPathComponent("evidence/editor-open-buffers-comparison.png"))
        }
        let leftGeneration = compare.beforeSurface.generation
        peer.surface.install(current)
        window.makeKeyAndOrderFront(nil)
        let refresh = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Refresh Current Buffers")
        guard let refresh, let refreshAction = refresh.action else { throw Failure(stage: "compare-open-editor-refresh-command") }
        try need(NSApp.sendAction(refreshAction, to: compare, from: refresh), "compare-open-editor-native-refresh")
        try await wait("compare-open-editor-refreshed-peer") { compare.planForVerification?.current.encoded == current.encoded }
        peer.finishClose()
        window.makeKeyAndOrderFront(nil)
        try need(NSApp.sendAction(refreshAction, to: compare, from: refresh), "compare-open-editor-closed-peer-refresh")
        try await wait("compare-open-editor-closed-peer") { !compare.preparing && compare.status.contains("previous snapshot") }
        try need(compare.beforeSurface.generation == leftGeneration && compare.planForVerification?.current.encoded == current.encoded
            && first.surface.generation == generation && first.surface.textView.string == draft, "compare-open-editor-no-source-changes")
        await first.closeComparisonAndDrain()
        try need(compare.closed && !compare.hasWorkForVerification && first.openEditorComparisonForVerification == nil,
            "compare-open-editor-origin-drains")
        first.surface.textView.undoManager?.undo()
        try need(first.surface.textView.string == original, "compare-open-editor-native-undo-retained")
    }

    private static func comparisonChecks(_ c: Context) async throws -> [String] {
        try await Task.detached {
            for (before, after) in [("", ""), ("", "new\n"), ("old\n", ""),
                ("é 🧭\n", "e\u{301} 🧭\n"), ("one\ntwo\n", "one\ntwo"),
                ("head\nold\nmiddle\nremoved\nend\n", "head\nnew\nmiddle\nend\nadded\n")] {
                let capture = EditorComparisonCapture(baseline: before, current: after,
                    format: .init(bom: false, lineEnding: .lf), language: .plain)
                let result = try EditorTextComparison.prepare(capture, cancelled: { false })
                guard let context = EditorDiffContextPlan(result) else { throw Failure(stage: "unified-exact-pair") }
                for (side, index) in [(EditorComparisonPlan.Side.before, result.beforeIndex), (.current, result.currentIndex)] {
                    var next = 0
                    for section in context.sections {
                        if let start = section.start(from: side) {
                            try need(start == next, "unified-maps-every-original-line-in-order")
                            next += section.count
                        }
                    }
                    try need(next == index.contentLineCount, "unified-excludes-only-the-terminal-caret-line")
                }
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
            guard bounded.grouped, bounded.changes.count == 1,
                  bounded.correspondingLine(22, from: .before) == nil,
                  bounded.beforeDetails.isEmpty && bounded.currentDetails.isEmpty else { throw Failure(stage: "comparison-bounded-coarse-overview") }
            try need(EditorDiffContextPlan(bounded) == nil, "unified-does-not-project-coarse-differences")
            let middle = String(repeating: "Shared context 🧭\n", count: 2_400)
            let sparse = EditorComparisonCapture(baseline: "Old heading\n" + middle + "Removed tail\nEnd\n",
                current: "New heading\nNew note\n" + middle + "End\n", format: .init(bom: false, lineEnding: .lf), language: .plain)
            let separated = try EditorTextComparison.prepare(sparse, cancelled: { false })
            let folded = EditorDiffContextPlan(separated)?.sections.filter(\.canFold)
            try need(folded?.count == 1 && folded?.first?.count == 2_394
                && folded?.first?.before == 4 && folded?.first?.after == 5, "unified-bounded-context-keeps-original-offsets")
            let ranges = try EditorTextComparison.searchableRanges(in: sparse.left.text, index: separated.beforeIndex,
                and: sparse.right.text, index: separated.currentIndex, whitespace: .exact, cancelled: { false })
            let rebuilt = NSMutableString(string: sparse.left.text)
            for change in separated.changes.reversed() {
                rebuilt.replaceCharacters(in: change.beforeRange, with: (sparse.right.text as NSString).substring(with: change.currentRange))
            }
            try need(!separated.grouped && separated.changes.map(\.beforeLines) == [0..<1, 2_401..<2_402]
                && separated.changes.map(\.currentLines) == [0..<2, 2_402..<2_402]
                && separated.correspondingLine(1_500, from: .before) == 1_501
                && separated.changedLineCounts?.added == 2 && separated.changedLineCounts?.removed == 2
                && ranges?.before == separated.changes.map(\.beforeRange)
                && ranges?.current == [separated.changes[0].currentRange]
                && (rebuilt as String).utf8.elementsEqual(sparse.right.text.utf8),
                "comparison-sparse-edits-remain-exact-across-repeated-context")
            let saved = EditorSavedTextBaseline(id: UUID(), text: "deleted\nkept\nchanged before\nanchor\n")
            let edited = "kept\nchanged after\nanchor\nadded\n"
            let marked = try EditorTextComparison.unsavedLines(from: saved, to: edited, index: .init(edited), cancelled: { false })
            try need(marked.baselineID == saved.id && marked.kind(at: 0) == .removed && marked.kind(at: 1) == .changed
                && marked.kind(at: 2) == nil && marked.kind(at: 3) == .added, "editor-markers-identify-exact-edited-lines-and-deletion-gap")
            let inline = EditorComparisonCapture(baseline: "Color 🟦 and café\n", current: "Color 🟩 and cafe\u{301}\n",
                format: .init(bom: false, lineEnding: .lf), language: .plain)
            let detail = try EditorTextComparison.prepare(inline, cancelled: { false })
            let words = detail.beforeDetails.map { (inline.left.text as NSString).substring(with: $0) }
            let newWords = detail.currentDetails.map { (inline.right.text as NSString).substring(with: $0) }
            try need(words.count == 2 && words.first == "🟦" && words.last?.utf8.elementsEqual("é".utf8) == true
                && newWords.count == 2 && newWords.first == "🟩" && newWords.last?.utf8.elementsEqual("e\u{301}".utf8) == true,
                "comparison-inline-spans-preserve-composed-characters-and-exact-spelling")
            let longLine = EditorComparisonCapture(baseline: String(repeating: "a", count: 2_000) + "\n",
                current: String(repeating: "b", count: 2_000) + "\n", format: .init(bom: false, lineEnding: .lf), language: .plain)
            let lineOnly = try EditorTextComparison.prepare(longLine, cancelled: { false })
            try need(!lineOnly.grouped && lineOnly.changes.count == 1 && lineOnly.beforeDetails.isEmpty && lineOnly.currentDetails.isEmpty,
                "comparison-long-lines-retain-line-highlight")
            let whitespace = EditorComparisonCapture(baseline: "    value\t=\t1 \t\nunchanged \t\n",
                current: "\tvalue  =  2\nunchanged\n", format: .init(bom: false, lineEnding: .lf), language: .plain)
            let exact = try EditorTextComparison.prepare(whitespace, cancelled: { false })
            let trailing = try EditorTextComparison.realign(exact, whitespace: .trailing, cancelled: { false })
            let spacing = try EditorTextComparison.realign(exact, whitespace: .spacing, cancelled: { false })
            try need(EditorDiffContextPlan(spacing) == nil && EditorDiffContextPlan(trailing) == nil,
                "unified-requires-exact-whitespace")
            try need(exact.changedLineCounts?.added == 2 && trailing.changedLineCounts?.added == 1
                && spacing.changedLineCounts?.added == 1
                && spacing.beforeDetails.map { (whitespace.left.text as NSString).substring(with: $0) } == ["1"]
                && spacing.currentDetails.map { (whitespace.right.text as NSString).substring(with: $0) } == ["2"],
                "comparison-whitespace-maps-visible-changes-to-exact-ranges")
            for (a, b) in [("ab\n", "a b\n"), ("a\u{a0}b\n", "a b\n"), ("a\n", "a"), ("é\n", "e\u{301}\n")] {
                let pair = EditorComparisonCapture(baseline: a, current: b, format: .init(bom: false, lineEnding: .lf), language: .plain)
                let result = try EditorTextComparison.prepare(pair, whitespace: .spacing, cancelled: { false })
                try need(!result.changes.isEmpty, "comparison-spacing-retains-word-boundaries-nonbreaking-space-newlines-and-unicode")
            }
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
        let originalName = (before as NSString).range(of: "Generated")
        try need(originalName.location != NSNotFound, "comparison-inline-fixture")
        text.insertText("88", replacementRange: originalName)
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
        guard let marks = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Highlight Changes Within Lines"),
              let toggle = marks.action else { throw Failure(stage: "comparison-inline-view-command") }
        let oldDetails = comparison.beforeSurface.textView.comparisonDetails
        let revisedDetails = comparison.currentSurface.textView.comparisonDetails
        try need(oldDetails == [originalName] && revisedDetails == [.init(location: originalName.location, length: 2)]
            && comparison.validateUserInterfaceItem(marks) && marks.state == .on, "comparison-native-character-ranges")
        try need(NSApp.sendAction(toggle, to: comparison, from: marks) && comparison.beforeSurface.textView.comparisonDetails.isEmpty
            && comparison.currentSurface.textView.comparisonDetails.isEmpty && !comparison.currentSurface.textView.comparisonHighlights.isEmpty,
            "comparison-disabling-character-marks-retains-line-marks")
        try need(NSApp.sendAction(toggle, to: comparison, from: marks) && comparison.beforeSurface.textView.comparisonDetails == oldDetails,
            "comparison-inline-marks-restored")
        try need(ToolWindowMenuOwnership.owns(comparison) && comparisonFile?.item(withTitle: "Save") == nil
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
        try need(!ToolWindowMenuOwnership.owns(comparison)
            && NSApp.windowsMenu === NSApp.mainMenu?.item(withTitle: "Window")?.submenu,
            "comparison-browser-restores-window-menu-owner")
        guard let restored = NSApp.windowsMenu,
              let comparisonIndex = restored.items.firstIndex(where: { ($0.target as? NSWindow) === window }) else {
            throw Failure(stage: "comparison-native-comparison-window-entry")
        }
        restored.performActionForItem(at: comparisonIndex)
        try await wait("comparison-native-Window-returns-to-comparison") { window.isKeyWindow && ToolWindowMenuOwnership.owns(comparison) }
        try need(text.string == after && comparison.currentSurface.textView.string == after,
            "native-window-switch-preserves-editor-and-comparison-text")
        comparison.navigate(1); comparison.navigate(-1)
        let oldFrame = window.frame
        let expected = ToolWindowChrome.initialViewport(size: .init(width: 1080, height: 720),
            minimum: .init(width: 620, height: 520), scale: c.settings.interfaceSize.scale, screen: native.screen)
        let viewport = window.contentView?.bounds.size ?? .zero
        try need(abs(viewport.width - expected.size.width) < 2 && abs(viewport.height - expected.size.height) < 2,
            "comparison-default-viewport-is-paired-and-bounded")
        let narrow = NSSize(width: max(680, expected.minimum.width), height: max(680, expected.minimum.height))
        window.setContentSize(narrow); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        try need(comparison.beforeSurface.window === window && comparison.currentSurface.window === window,
            "comparison-adaptive-keeps-native-surfaces")
        let stacked = window.contentView?.bounds.size ?? .zero
        let top = comparison.beforeSurface.convert(comparison.beforeSurface.bounds, to: window.contentView)
        let bottom = comparison.currentSurface.convert(comparison.currentSurface.bounds, to: window.contentView)
        try need(abs(stacked.width - narrow.width) < 2 && abs(stacked.height - narrow.height) < 2
            && abs(top.minX - bottom.minX) < 2 && top.intersection(bottom).isEmpty,
            "comparison-stacked-viewport-does-not-grow-to-document-height")
        let capture = !ProcessInfo.processInfo.arguments.contains("--offscreen") && CGPreflightScreenCaptureAccess()
        if capture {
            try await GlassVerification.captureOwnedWindow(window, to: c.root.appendingPathComponent("evidence/editor-comparison-stacked.png"))
        }
        window.setFrame(oldFrame, display: true); try await Task.sleep(for: .milliseconds(400))
        let first = comparison.beforeSurface.convert(comparison.beforeSurface.bounds, to: window.contentView)
        let second = comparison.currentSurface.convert(comparison.currentSurface.bounds, to: window.contentView)
        try need(first.maxX < second.minX && abs(first.minY - second.minY) < 2,
            "comparison-wide-panes-actually-paired")
        if capture {
            try await GlassVerification.captureOwnedWindow(window, to: c.root.appendingPathComponent("evidence/editor-comparison-paired.png"))
        }
        if ProcessInfo.processInfo.arguments.contains("--check-development-motion"),
           !ProcessInfo.processInfo.arguments.contains("--offscreen") {
            window.makeKeyAndOrderFront(nil)
            let existingSize = c.settings.interfaceSize
            c.settings.interfaceSize = .init(125)
            window.setContentSize(.init(width: 1040, height: min(780, viewport.height)))
            try await Task.sleep(for: .milliseconds(350))
            defer { c.settings.interfaceSize = existingSize; window.setFrame(oldFrame, display: true) }
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
        try need(ToolWindowMenuOwnership.owns(document.window)
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
        try await clipboardComparisonChecks(document.window, parent: native)
        native.makeKeyAndOrderFront(nil); document.window.compareChanges(nil)
        guard let pending = document.window.comparisonForVerification else { throw Failure(stage: "comparison-parent-close-reopens") }
        document.requestClose(); try await wait("comparison-document-close") { document.isClosed && editors.documentCount == 0 }
        try need(pending.closed && !pending.hasWorkForVerification && pending.beforeSurface.textView.string.isEmpty
            && pending.currentSurface.textView.string.isEmpty, "comparison-parent-close-joins-pending-preparation")
        let retained = try await Task.detached { try Data(contentsOf: c.files.first) }.value
        try need(retained == original, "comparison-never-writes-original")
        try await linkedScrollChecks(c, capture: capture)
        try await unifiedDiffChecks(c)
        try await largeUnifiedDiffChecks()
        let visible = !ProcessInfo.processInfo.arguments.contains("--offscreen")
        if visible {
            try await comparedFileFailureChecks(c)
            try await singleAdmittedDiffChecks(c)
            try await continuedDiffSearchChecks(c)
        }
        return ["Native Compare Changes uses the real local document baseline, Unicode-exact bounded line differences and character highlights, paired/stacked read-only views and explicit snapshot refresh",
            "Native Window commands switch between the open browser, editor and comparison without closing documents; main/Window menu ownership follows the key window",
            "Linked text scrolling follows unchanged logical lines past insertions and deletions in both directions. The native View command allows independent scrolling and realigns the wrapped line when enabled.",
            "Whitespace filters retain exact text, native Find, focus and scroll position at enlarged size. They hide only the selected spacing differences.",
            "Comparison Find and Go to Line use the focused pane, including an exact line and optional column. Find in Diff reuses the displayed comparison, counts large identical pairs as checked, and invalidates old results on Refresh. The location trail restores selection and scrolling. Closing joins Find before clearing both snapshots.",
            "Comparison cancellation/close drains actual work and clears both buffers; native Undo and the unchanged generated original remain intact",
            "Compare with Clipboard uses only the explicitly supplied plain text and the selected text or entire draft. A second invocation reuses the comparison window and both source snapshots are read-only."]
            + ["Unified Diff collapses exact unchanged lines. Return expands one block, and Show All toggles every block. Find reaches an exact match over 7,000 lines down and returning to Split restores the original selection."]
            + (visible ? ["Stopping a file step retains the prior comparison. An unavailable file clears both panes without trapping navigation or showing another file’s text.",
                "Find Across Diffs searches changed or all lines in the exact visible sequence, including when just one comparable file remains. It reports skipped files, jumps to the selected UTF-16 match, and rejects an obsolete hit.",
                "Stop keeps completed diff matches and Search More resumes with both text viewports steady. Resizing preserves search focus, and changing the query cannot publish stopped results."] : [])
    }

    private static func clipboardComparisonChecks(_ editor: NativeTextEditorWindow, parent: NSWindow) async throws {
        parent.makeKeyAndOrderFront(nil)
        guard let command = UIVerification.menuItem("File", "Compare", "Compare with Clipboard"),
              let action = command.action else { throw Failure(stage: "clipboard-comparison-menu") }
        let text = editor.surface.textView, original = text.string
        let excerpt = "🧭 Café"
        var clipboard: String?
        var reads = 0
        editor.readClipboardForComparisonVerification = { reads += 1; return clipboard }
        defer { editor.readClipboardForComparisonVerification = nil }
        try need(editor.validateUserInterfaceItem(command) && reads == 0, "clipboard-menu-validation-never-reads")
        try need(NSApp.sendAction(action, to: editor, from: command) && editor.clipboardComparisonForVerification == nil,
            "clipboard-comparison-refuses-absent-plain-text")
        clipboard = String(repeating: "x", count: TextDocumentValue.maximumBytes + 1)
        try need(NSApp.sendAction(action, to: editor, from: command) && editor.clipboardComparisonForVerification == nil,
            "clipboard-comparison-refuses-large-source-before-opening")
        text.breakUndoCoalescing()
        text.insertText("\n" + excerpt + "\n", replacementRange: .init(location: original.utf16.count, length: 0))
        text.breakUndoCoalescing()
        let draft = text.string
        let selection = (draft as NSString).range(of: excerpt)
        text.setSelectedRange(selection)
        clipboard = "Copied text\r\n"
        try need(NSApp.sendAction(action, to: editor, from: command), "clipboard-native-selection-comparison")
        guard let comparison = editor.clipboardComparisonForVerification else { throw Failure(stage: "clipboard-comparison-owner") }
        clipboard = "Different clipboard contents"
        try await wait("clipboard-native-snapshots-ready") {
            !comparison.hasWorkForVerification && comparison.window?.isKeyWindow == true
        }
        try need(reads == 3 && comparison.labels.right == "Selected Text"
            && comparison.beforeSurface.textView.string == "Copied text\n"
            && comparison.currentSurface.textView.string == excerpt
            && !comparison.hasEditorSource(.before) && !comparison.hasEditorSource(.current)
            && UIVerification.menuItem("File", "Refresh") == nil,
            "clipboard-diff-holds-both-original-snapshots-and-no-edit-authority")
        parent.makeKeyAndOrderFront(nil)
        text.setSelectedRange(.init(location: 0, length: 0))
        try need(NSApp.sendAction(action, to: editor, from: command), "clipboard-native-buffer-comparison")
        try await wait("clipboard-reuses-review-for-the-new-snapshot") {
            !comparison.hasWorkForVerification && comparison.window?.isKeyWindow == true
        }
        try need(editor.clipboardComparisonForVerification === comparison && reads == 4
            && comparison.labels.right == "Editor Buffer" && comparison.beforeSurface.textView.string == clipboard
            && comparison.currentSurface.textView.string == draft && text.string == draft,
            "clipboard-explicit-new-command-reads-once-and-keeps-editor-buffer")
        await editor.closeComparisonAndDrain()
        try need(comparison.closed && editor.clipboardComparisonForVerification == nil
            && comparison.beforeSurface.textView.string.isEmpty && comparison.currentSurface.textView.string.isEmpty,
            "clipboard-comparison-releases-snapshots-on-close")
        parent.makeKeyAndOrderFront(nil)
        text.undoManager?.undo()
        try await wait("clipboard-comparison-does-not-disturb-native-undo") { text.string == original }
    }

    private static func unifiedDiffChecks(_ c: Context) async throws {
        guard let parent = c.owner.window else { throw Failure(stage: "unified-parent") }
        let target = "🧭 café"
        let middle = (1...28).map { number in
            number == 15 ? String(repeating: "prefix ", count: 250) + target : "Shared context \(number)"
        }.joined(separator: "\n")
        let before = "Retired heading\n" + middle + "\nRetired end\n"
        let after = "New heading\nAdded line\n" + middle + "\nNew end\n"
        let previousSize = c.settings.interfaceSize
        defer { c.settings.interfaceSize = previousSize }
        c.settings.interfaceSize = .init(125)
        var reads = [0, 0]
        func source(_ index: Int) -> EditorComparisonWindow.Source {
            .init(labels: .init(title: "Text Diff", source: "Unified \(index + 1).txt", left: "Prior", right: "Current",
                detail: "Generated unified diff review", refresh: "Refresh"), read: {
                    reads[index] += 1
                    return .init(baseline: before, current: after, format: .init(bom: false, lineEnding: .lf), language: .plain)
                })
        }
        let initial = source(0)
        let view = EditorComparisonWindow(relativeTo: parent, settings: c.settings, pointSize: 13,
            labels: initial.labels, files: .init(count: 2, initialIndex: 0, entryAt: source), capture: initial.read)
        view.present()
        try await wait("unified-split-open") { !view.hasWorkForVerification && view.window?.isKeyWindow == true }
        guard let window = view.window,
              let item = UIVerification.menuItem("View", "Unified Diff"), let action = item.action else {
            throw Failure(stage: "unified-native-menu")
        }
        try need(view.validateUserInterfaceItem(item) && NSApp.sendAction(action, to: view, from: item),
            "unified-native-menu-invocation")
        let unified = view.unifiedDiffView, table = unified.tableForVerification
        try await wait("unified-table-owns-focus") { view.showsUnifiedDiff && table.window === window && window.firstResponder === table }
        let collapsedCount = table.numberOfRows
        let folded = (0..<collapsedCount).first {
            (table.view(atColumn: 2, row: $0, makeIfNecessary: true) as? NSButton)?.title.contains("unchanged lines") == true
        }
        guard let folded else { throw Failure(stage: "unified-context-button") }
        try need(unified.foldedSectionsForVerification == 1 && !view.canLinkScrolling && view.position?.index == 0,
            "unified-starts-folded-with-the-same-change")
        let visible = !ProcessInfo.processInfo.arguments.contains("--offscreen")
        if visible {
            window.setContentSize(.init(width: 1040, height: 640))
            try await UIVerification.snapshot(window, to: c.root.appendingPathComponent("evidence/editor-unified-diff.png"))
        }
        table.selectRowIndexes(IndexSet(integer: folded), byExtendingSelection: false)
        func expandWithReturn() { window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window)) }
        if visible, ProcessInfo.processInfo.arguments.contains("--check-development-motion"),
           ProcessInfo.processInfo.arguments.contains("--editor-comparison-only") {
            let title = window.title
            window.title = "Unified Diff · generated review"
            defer { window.title = title }
            _ = try await NativeMotionRecorder.record(window: window, root: c.root, label: "editor-unified-context",
                sampling: .diagnostic(for: window), action: expandWithReturn)
        } else { expandWithReturn() }
        try await wait("unified-keyboard-expands-context") { unified.foldedSectionsForVerification == 0 && table.numberOfRows == collapsedCount + 22 }
        guard let collapse = table.view(atColumn: 2, row: folded, makeIfNecessary: true) as? NSButton else {
            throw Failure(stage: "unified-collapse-button")
        }
        collapse.performClick(nil)
        try await wait("unified-button-restores-context-fold") { unified.foldedSectionsForVerification == 1 && table.numberOfRows == collapsedCount }
        guard let allContext = UIVerification.menuItem("View", "Show All Unchanged Lines"),
              let toggleAll = allContext.action else { throw Failure(stage: "unified-context-menu") }
        try need(view.validateUserInterfaceItem(allContext) && allContext.state == .off
            && NSApp.sendAction(toggleAll, to: view, from: allContext)
            && view.validateUserInterfaceItem(allContext) && allContext.state == .on && table.numberOfRows == collapsedCount + 22,
            "unified-native-menu-shows-all-context")
        try need(NSApp.sendAction(toggleAll, to: view, from: allContext) && table.numberOfRows == collapsedCount,
            "unified-native-menu-refolds-all-context")
        let lineCommand = UIVerification.key("g", code: 5, flags: .control, window: window)
        try need(NSApp.mainMenu?.performKeyEquivalent(with: lineCommand) == true, "unified-line-address-native-shortcut")
        try await wait("unified-line-address-field-focused") {
            (window.attachedSheet?.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        guard let sheet = window.attachedSheet, let address = sheet.firstResponder as? NSTextView else {
            throw Failure(stage: "unified-line-address-sheet")
        }
        sheet.sendEvent(UIVerification.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, flags: [], window: sheet))
        func submitAddress(_ input: String) {
            address.selectAll(nil)
            address.insertText(input, replacementRange: address.selectedRange())
            sheet.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: sheet))
        }
        submitAddress("17:9999")
        try need(window.attachedSheet === sheet, "unified-line-address-refuses-an-out-of-range-column")
        if visible && CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(window, to: c.root.appendingPathComponent("evidence/editor-unified-go-to-line.png"))
        }
        submitAddress("17:1752")
        let exactOffset = (after as NSString).range(of: target).location
        try await wait("unified-line-address-reveals-exact-after-column") {
            window.attachedSheet == nil && unified.selectedLocation?.side == .current
                && unified.selectedLocation?.range == .init(location: exactOffset, length: 0)
        }
        try need(NSApp.sendAction(toggleAll, to: view, from: allContext) && table.numberOfRows == collapsedCount,
            "unified-line-address-expanded-only-the-containing-section")
        try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key(
            String(UnicodeScalar(NSF7FunctionKey)!), code: 98, flags: [], window: window)) == true
            && view.position?.index == 1, "unified-next-change-keeps-the-exact-group")
        try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key("f", code: 3, flags: .command, window: window)) == true,
            "unified-command-f-uses-diff-search")
        try await wait("unified-diff-search-opens") { view.diffSearch.visible }
        view.diffSearch.query = target
        view.diffSearch.scope = .entireFile
        view.diffSearch.versions = .before
        view.startDiffSearch()
        try await wait("unified-search-includes-folded-context") { view.diffSearch.report?.hits.count == 2 && !view.hasWorkForVerification }
        guard let hits = view.diffSearch.report?.hits, let hit = hits.first(where: { $0.file == 0 }),
              let otherHit = hits.first(where: { $0.file == 1 }) else { throw Failure(stage: "unified-hidden-exact-result") }
        view.openDiffSearchHit(hit)
        try need(unified.foldedSectionsForVerification == 0 && unified.selectedLocation?.side == .before
            && unified.selectedLocation?.range == (before as NSString).range(of: target) && reads == [1, 1],
            "unified-hidden-result-expands-and-retains-the-before-coordinate")
        view.openDiffSearchHit(otherHit)
        try await wait("unified-opens-other-exact-identity") { !view.hasWorkForVerification && view.fileIndex == 1 }
        try need(unified.selectedLocation?.range == otherHit.range && unified.selectedLocation?.side == .before
            && view.labels.source == "Unified 2.txt" && reads == [1, 2], "unified-cross-file-hit-keeps-its-label-and-selection")
        view.openDiffSearchHit(hit)
        try await wait("unified-refocuses-original-hit") { !view.hasWorkForVerification && view.fileIndex == 0 }
        view.diffSearch.dismiss()
        if visible {
            let initialRowHeight = table.rowHeight
            c.settings.interfaceSize = InterfaceSize(150)
            window.setContentSize(.init(width: 620, height: 520))
            try await wait("unified-enlarged-table") { table.rowHeight > initialRowHeight && table.window === window }
            guard (0..<table.numberOfRows).contains(table.selectedRow),
                  let field = table.view(atColumn: 2, row: table.selectedRow, makeIfNecessary: true) as? NSTextField else {
                throw Failure(stage: "unified-highlighted-line-cell")
            }
            let rendered = field.attributedStringValue
            let targetRange = (rendered.string as NSString).range(of: target)
            try need(table.visibleRect.intersects(table.rect(ofRow: table.selectedRow))
                && targetRange.location != NSNotFound && rendered.length < 514
                && rendered.attribute(.backgroundColor, at: targetRange.location, effectiveRange: nil) != nil,
                "unified-enlarged-viewport-keeps-the-visible-exact-match-highlighted")
            try await UIVerification.snapshot(window, to: c.root.appendingPathComponent("evidence/editor-unified-diff-150.png"))
        }
        try need(NSApp.sendAction(action, to: view, from: item), "unified-returns-to-split-via-menu")
        try await wait("unified-return-restores-before-focus-and-range") {
            !view.showsUnifiedDiff && window.firstResponder === view.beforeSurface.textView
                && view.beforeSurface.textView.selectedRange() == hit.range
        }
        try need(view.beforeSurface.textView.string == before && view.currentSurface.textView.string == after && reads == [2, 2],
            "unified-layout-switch-preserves-the-two-source-buffers-without-rereading")
        view.setUnifiedDiff(true)
        try await wait("unified-open-for-other-file") { view.showsUnifiedDiff && table.window === window }
        view.visitFile(.next)
        try await wait("unified-navigates-to-other-file") { !view.hasWorkForVerification && view.fileIndex == 1 }
        try need(unified.foldedSectionsForVerification == 1 && table.numberOfRows == collapsedCount
            && unified.selectedLocation?.range != hit.range,
            "unified-identical-text-in-another-file-starts-with-fresh-context")
        guard let whitespace = UIVerification.menuItem("View", "Whitespace", EditorComparisonWhitespace.trailing.title),
              let changeWhitespace = whitespace.action else { throw Failure(stage: "unified-whitespace-menu") }
        try need(NSApp.sendAction(changeWhitespace, to: view, from: whitespace), "unified-allows-whitespace-change")
        try await wait("unified-falls-back-for-whitespace-filter") {
            !view.hasWorkForVerification && !view.showsUnifiedDiff && !view.canShowUnifiedDiff && table.numberOfRows == 0
        }
        await view.closeAndDrain()
        try need(table.numberOfRows == 0, "unified-close-clears-all-context-rows")
    }

    private static func largeUnifiedDiffChecks() async throws {
        let needle = "Find the compass 🧭"
        let shared = (1...10_000).map { $0 == 7_000 ? needle : "Generated context \($0)" }.joined(separator: "\n")
        let before = "Old\n" + shared + "\nRemoved\n"
        let after = "New\nExtra\n" + shared + "\n"
        let plan = try await Task.detached {
            try EditorTextComparison.prepare(.init(baseline: before, current: after,
                format: .init(bom: false, lineEnding: .lf), language: .plain), cancelled: { false })
        }.value
        guard let context = EditorDiffContextPlan(plan) else { throw Failure(stage: "unified-large-exact-plan") }
        let view = EditorDiffContextView(frame: .init(x: 0, y: 0, width: 620, height: 520))
        view.install(plan, context: context)
        let table = view.tableForVerification
        try need(table.numberOfRows == 11, "unified-large-starts-with-bounded-context")
        view.toggleAllContext()
        try need(table.numberOfRows == 10_005 && view.allContextVisible, "unified-large-virtual-row-count-is-exact")
        let hit = (before as NSString).range(of: needle)
        try need(view.revealMatch(side: .before, range: hit) && view.selectedLocation?.range == hit
            && view.selectedLocation?.side == .before, "unified-large-resolves-an-exact-match-in-virtual-context")
        let row = table.selectedRow
        guard (0..<table.numberOfRows).contains(row),
              let beforeLine = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTextField,
              let afterLine = table.view(atColumn: 1, row: row, makeIfNecessary: true) as? NSTextField else {
            throw Failure(stage: "unified-large-line-cells")
        }
        try need(beforeLine.stringValue == "7001" && afterLine.stringValue == "7002",
            "unified-large-preserves-both-original-line-numbers")
        view.toggleAllContext()
        try need(table.numberOfRows == 11 && view.canToggleSelectedContext && view.selectedLocation == nil,
            "unified-large-refold-keeps-selection-at-the-section")
        view.clear()
    }

    private static func singleAdmittedDiffChecks(_ c: Context) async throws {
        guard let parent = c.owner.window else { throw Failure(stage: "single-admitted-diff-parent") }
        var reads = 0
        let source = EditorComparisonWindow.Source(labels: .init(title: "Text Diff", source: "Remaining.txt",
            left: "Prior", right: "Current", detail: "Generated review", refresh: "Refresh"), read: {
                reads += 1
                return .init(baseline: "Before\n", current: "After 🧭\n",
                    format: .init(bom: false, lineEnding: .lf), language: .plain)
            })
        let view = EditorComparisonWindow(relativeTo: parent, settings: c.settings, pointSize: 13,
            labels: source.labels, files: .init(count: 1, initialIndex: 0, excludedCount: 2,
                startsWithSearch: true, entryAt: { _ in source }), capture: source.read)
        view.present()
        try await wait("single-admitted-diff-is-presented") { !view.hasWorkForVerification && view.window?.isKeyWindow == true }
        try need(view.diffSearch.visible && view.fileCount == 1 && !view.canVisitFile(.next),
            "single-admitted-diff-keeps-the-requested-search")
        view.diffSearch.query = "After 🧭"
        view.startDiffSearch()
        try await wait("single-admitted-diff-search-finishes") { view.diffSearch.report != nil && !view.hasWorkForVerification }
        guard let report = view.diffSearch.report, let hit = report.hits.first else {
            throw Failure(stage: "single-admitted-diff-report")
        }
        try need(report.checked == 1 && report.total == 3 && report.coverage == "2 skipped" && report.hits.count == 1,
            "single-admitted-diff-accounts-for-skipped-files")
        view.openDiffSearchHit(hit)
        try need(reads == 1 && view.currentSurface.textView.selectedRange() == hit.range
            && (view.currentSurface.textView.string as NSString).substring(with: hit.range) == "After 🧭",
            "single-admitted-diff-jumps-without-rereading")
        await view.closeAndDrain()
    }

    private static func comparedFileFailureChecks(_ c: Context) async throws {
        guard let parent = c.owner.window else { throw Failure(stage: "comparison-file-list-parent") }
        var attempts = 0
        var reads: [Int: Int] = [:]
        var common = ""
        var replacedFirst = false
        func entry(_ index: Int) -> EditorComparisonWindow.Source {
            .init(labels: .init(title: "Git Text Diff", source: "Generated File \(index + 1)",
                left: "Prior", right: "Current", detail: "Generated review", refresh: "Refresh"), read: {
                reads[index, default: 0] += 1
                if index == 1 {
                    attempts += 1
                    if attempts == 1 { try await Task.sleep(for: .seconds(30)) }
                    throw EditorComparisonLoadFailure.unavailable("This generated file has no text comparison.")
                }
                let after = index == 0 && replacedFirst ? "changed snapshot" : "current \(index)"
                return .init(left: .init(text: common + "previous \(index)\n", format: .init(bom: false, lineEnding: .lf), language: .plain),
                    right: .init(text: common + after + "\n", format: .init(bom: false, lineEnding: .lf), language: .plain))
            })
        }
        let initial = entry(0)
        let view = EditorComparisonWindow(relativeTo: parent, settings: c.settings, pointSize: 13,
            labels: initial.labels, files: .init(count: 3, initialIndex: 0, excludedCount: 1, entryAt: entry), capture: initial.read)
        view.present()
        try await wait("comparison-file-list-has-first-snapshot") { !view.hasWorkForVerification && view.window?.isKeyWindow == true }
        let generation = view.currentSurface.generation
        view.visitFile(.next)
        try await wait("comparison-file-list-reads-one-target") { view.preparing && attempts == 1 }
        view.visitFile(.next)
        view.stop()
        try await wait("comparison-file-list-stop-drains") { !view.hasWorkForVerification }
        try need(attempts == 1 && view.fileIndex == 0 && view.currentSurface.generation == generation
            && view.currentSurface.textView.string == "current 0\n" && view.status.contains("previous snapshot"),
            "comparison-file-list-cancel-keeps-exact-prior-file")
        view.visitFile(.next)
        try await wait("comparison-file-list-unavailable-drains") { !view.hasWorkForVerification }
        try need(attempts == 2 && view.fileIndex == 1 && view.labels.source == "Generated File 2"
            && view.beforeSurface.textView.string.isEmpty && view.currentSurface.textView.string.isEmpty
            && view.planForVerification == nil && view.canVisitFile(.next),
            "comparison-file-list-unavailable-clears-old-pair")
        common = "Shared 🧭 context\n"
        view.visitFile(.next)
        try await wait("comparison-file-list-keeps-going") { !view.hasWorkForVerification }
        try need(view.fileIndex == 2 && view.currentSurface.textView.string == common + "current 2\n" && !view.canVisitFile(.next),
            "comparison-file-list-reaches-exact-last-file")
        guard let window = view.window else { throw Failure(stage: "diff-search-window") }
        let currentReads = reads[2]
        try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key("F", code: 3,
            flags: [.command, .shift], window: window)) == true, "diff-search-command")
        try await wait("diff-search-native-field-focus") {
            guard let content = window.contentView,
                  let field = WorkspaceNetworkVerification.descendants(content).compactMap({ $0 as? NSSearchField })
                    .first(where: { $0.identifier?.rawValue == "diff-search-query" }),
                  let editor = field.currentEditor() else { return false }
            return window.firstResponder === editor
        }
        for letter in "current" { window.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: window)) }
        try await wait("diff-search-native-query") { view.diffSearch.query == "current" }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try await wait("diff-search-changed-lines-complete") { view.diffSearch.report != nil && !view.diffSearch.isRunning }
        guard let report = view.diffSearch.report, let first = report.hits.first else { throw Failure(stage: "diff-search-results") }
        try need(report.checked == 2 && report.total == 4 && report.unavailable == 2 && !report.limited
            && report.hits.map(\.file) == [0, 2] && report.hits.allSatisfy { $0.side == .current && $0.line == 2 },
            "diff-search-scope-coverage-and-line")
        try need(report.excluded == 1 && report.skipped.map(\.name) == ["Generated File 2"]
            && report.skipped.first?.reason == .unavailable && report.unlistedSkips == 0,
            "diff-search-distinguishes-excluded-entries-and-attempted-paths")
        try await wait("diff-search-coverage-control-ready") {
            window.isKeyWindow && FolderCompositionOwnedControls.isEnabled("Search Coverage", in: window)
                && !FolderCompositionOwnedControls.frame("Search Coverage", in: window).isEmpty
        }
        try need(FolderCompositionOwnedControls.press("Search Coverage", in: window), "diff-search-coverage-button")
        func coverageWindow() -> NSWindow? {
            NSApp.windows.first { candidate in
                candidate.isVisible && !FolderCompositionOwnedControls.frame("Close Coverage", in: candidate).isEmpty
            }
        }
        try await wait("diff-search-coverage-appears") { coverageWindow() != nil }
        guard let coverage = coverageWindow() else { throw Failure(stage: "diff-search-coverage-window") }
        try await UIVerification.snapshot(coverage, to: c.root.appendingPathComponent("evidence/editor-diff-search-coverage.png"))
        try need(FolderCompositionOwnedControls.press("Close Coverage", in: coverage), "diff-search-close-coverage")
        try await wait("diff-search-coverage-dismissed") { coverageWindow() == nil && window.isKeyWindow }
        try need(reads[2] == currentReads, "diff-search-across-files-reuses-the-displayed-plan")
        replacedFirst = true
        view.openDiffSearchHit(first)
        try await wait("diff-search-refuses-stale-hit") { !view.hasWorkForVerification }
        try need(view.fileIndex == 2 && view.status.contains("changed after the search") &&
            view.currentSurface.textView.string == common + "current 2\n", "diff-search-preserves-prior-text")
        replacedFirst = false
        view.openDiffSearchHit(first)
        try await wait("diff-search-exact-hit-opened") { !view.hasWorkForVerification && view.fileIndex == 0 }
        let text = view.currentSurface.textView
        try need(window.firstResponder === text && text.selectedRange() == first.range &&
            (text.string as NSString).substring(with: first.range) == "current", "diff-search-exact-utf16-selection")
        try await UIVerification.snapshot(window, to: c.root.appendingPathComponent("evidence/editor-diff-search.png"))
        view.diffSearch.query = "context"
        view.startDiffSearch()
        try await wait("diff-search-completes-changed-context-query") { view.diffSearch.report != nil }
        try need(view.diffSearch.report?.hits.isEmpty == true, "diff-search-changed-scope-excludes-context")
        view.diffSearch.scope = .entireFile
        for (version, side) in [(EditorDiffSearch.Versions.before, EditorComparisonPlan.Side.before), (.after, .current)] {
            view.diffSearch.versions = version
            try need(view.diffSearch.report == nil, "diff-search-version-change-retires-previous-results")
            view.startDiffSearch()
            try await wait("diff-search-completes-one-version") { view.diffSearch.report != nil && !view.hasWorkForVerification }
            guard let found = view.diffSearch.report else { throw Failure(stage: "diff-search-version-report") }
            try need(found.checked == 2 && found.hits.count == 2 && found.hits.allSatisfy { $0.side == side },
                "diff-search-returns-matches-only-from-the-chosen-version")
        }
        view.diffSearch.versions = .both
        view.startDiffSearch()
        try await wait("diff-search-completes-all-lines") { view.diffSearch.report != nil }
        try need(view.diffSearch.report?.hits.count == 4, "diff-search-all-lines-includes-both-sides")
        guard let hits = view.diffSearch.report?.hits, hits.count == 4 else { throw Failure(stage: "diff-search-navigation-results") }
        let beforeNavigation = reads
        let next = UIVerification.key("g", code: 5, flags: [.command, .option], window: window)
        let previous = UIVerification.key("G", code: 5, flags: [.command, .option, .shift], window: window)
        try need(NSApp.mainMenu?.performKeyEquivalent(with: next) == true
            && view.diffSearch.selectedHit?.id == hits[1].id && view.fileIndex == 0
            && window.firstResponder === view.currentSurface.textView
            && view.currentSurface.textView.selectedRange() == hits[1].range
            && reads == beforeNavigation && !view.hasWorkForVerification, "diff-search-next-result-reuses-displayed-pair")
        try need(NSApp.mainMenu?.performKeyEquivalent(with: next) == true, "diff-search-next-file-shortcut")
        try await wait("diff-search-next-result-opens-other-file") {
            !view.hasWorkForVerification && view.fileIndex == 2 && view.diffSearch.selected == hits[2].id
        }
        try need(window.firstResponder === view.beforeSurface.textView
            && view.beforeSurface.textView.selectedRange() == hits[2].range
            && reads[2] == (beforeNavigation[2] ?? 0) + 1, "diff-search-next-file-verifies-and-selects-exact-match")
        try need(NSApp.mainMenu?.performKeyEquivalent(with: previous) == true, "diff-search-previous-result-shortcut")
        try await wait("diff-search-previous-result-returns-to-earlier-file") {
            !view.hasWorkForVerification && view.fileIndex == 0 && view.diffSearch.selected == hits[1].id
        }
        common = String(repeating: "Repeated in both versions\n", count: 45)
        view.refresh()
        try await wait("diff-search-displayed-pair-refreshed") { !view.hasWorkForVerification }
        view.diffSearch.query = "Repeated"
        view.startDiffSearch()
        try await wait("diff-search-many-matches-across-files") { view.diffSearch.report != nil }
        guard let bounded = view.diffSearch.report else { throw Failure(stage: "diff-search-capped-file-list-report") }
        try need(bounded.clippedMatches && bounded.hits.count == 80 && bounded.checked == 2
            && [0, 2].allSatisfy { file in
                bounded.hits.filter { $0.file == file && $0.side == .before }.count == 20
                    && bounded.hits.filter { $0.file == file && $0.side == .current }.count == 20
            }, "diff-search-shares-the-file-limit-between-versions")
        await view.closeAndDrain()
        try need(view.closed && view.fileCount == 0 && view.currentSurface.textView.string.isEmpty,
            "comparison-file-list-close-releases-state")
    }

    private static func continuedDiffSearchChecks(_ c: Context) async throws {
        guard let parent = c.owner.window else { throw Failure(stage: "diff-search-continuation-parent") }
        var reads: [Int] = []
        var blockedFile: Int? = 49
        var restartRead: CheckedContinuation<Void, Never>?
        var holdsRestart = false
        let identical = String(repeating: "Equal\n", count: 16_400)
        func entry(_ index: Int) -> EditorComparisonWindow.Source {
            .init(labels: .init(title: "Folder Text Diff", source: "Generated File \(index + 1)",
                left: "Prior", right: "Current", detail: "Generated review", refresh: "Refresh"), read: {
                reads.append(index)
                if index == 1, holdsRestart { await withCheckedContinuation { restartRead = $0 } }
                if index == blockedFile { try await Task.sleep(for: .seconds(30)) }
                if index == 47 {
                    return .init(baseline: identical, current: identical, format: .init(bom: false, lineEnding: .lf), language: .plain)
                }
                let current = [0, 48, 49, 50].contains(index) ? "Needle \(index)\n" : "Current \(index)\n"
                return .init(baseline: "Prior \(index)\n", current: current,
                    format: .init(bom: false, lineEnding: .lf), language: .plain)
            })
        }
        let initial = entry(0)
        let comparison = EditorComparisonWindow(relativeTo: parent, settings: c.settings, pointSize: 13,
            labels: initial.labels, files: .init(count: 51, initialIndex: 0, entryAt: entry), capture: initial.read)
        comparison.present()
        defer { comparison.window?.close() }
        try await wait("diff-search-continuation-ready") { !comparison.hasWorkForVerification && comparison.window?.isKeyWindow == true }
        guard let window = comparison.window else { throw Failure(stage: "diff-search-continuation-window") }
        reads.removeAll()
        comparison.diffSearch.show()
        func queryField() -> NSSearchField? {
            guard let content = window.contentView else { return nil }
            return WorkspaceNetworkVerification.descendants(content).compactMap { $0 as? NSSearchField }
                .first { $0.identifier?.rawValue == "diff-search-query" }
        }
        try await wait("diff-search-field-before-resize") { queryField()?.currentEditor() != nil }
        let field = queryField()
        window.setContentSize(window.contentMinSize)
        try await wait("diff-search-field-after-resize") {
            guard let field, queryField() === field, let editor = field.currentEditor() else { return false }
            return window.firstResponder === editor && field.bounds.width >= 140 * c.settings.interfaceSize.scale
                && window.frame.contains(FolderCompositionOwnedControls.frame("Close Diff Search", in: window))
        }
        for letter in "Needle" { window.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: window)) }
        try await wait("diff-search-typed-at-minimum-width") { comparison.diffSearch.query == "Needle" }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try await wait("diff-search-first-budget") { comparison.diffSearch.report?.canContinue == true && !comparison.hasWorkForVerification }
        guard let first = comparison.diffSearch.report else { throw Failure(stage: "diff-search-continuation-first-report") }
        try need(first.checked == 48 && first.remaining == 3 && first.coverage == "3 files left"
            && first.hits.map(\.file) == [0] && reads == Array(1..<48), "diff-search-first-budget-coverage")
        let selection = comparison.diffSearch.selected
        try await wait("diff-search-more-button") { FolderCompositionOwnedControls.isEnabled("Search More", in: window) }
        func panes() -> [NSRect] {
            window.contentView?.layoutSubtreeIfNeeded()
            return [comparison.beforeSurface, comparison.currentSurface].map { $0.convert($0.bounds, to: window.contentView) }
        }
        let originalPanes = panes()
        try need(FolderCompositionOwnedControls.press("Search More", in: window), "diff-search-more-native-action")
        try await wait("diff-search-next-file-held") {
            reads.last == 49 && FolderCompositionOwnedControls.isEnabled("Stop", in: window)
        }
        try need(panes() == originalPanes, "diff-search-continuation-holds-both-text-viewports")
        let continuing = c.root.appendingPathComponent("evidence/editor-diff-search-continuing.png")
        if CGPreflightScreenCaptureAccess() { try await GlassVerification.captureOwnedWindow(window, to: continuing) }
        else { try await UIVerification.snapshot(window, to: continuing) }
        try need(FolderCompositionOwnedControls.press("Stop", in: window), "diff-search-native-stop")
        try await wait("diff-search-stopped-and-drained") { !comparison.hasWorkForVerification }
        try need(comparison.diffSearch.report?.checked == 49 && comparison.diffSearch.report?.remaining == 2
            && comparison.diffSearch.report?.coverage == "Stopped · 2 files left"
            && comparison.diffSearch.report?.hits.map(\.file) == [0, 48]
            && comparison.diffSearch.selected == selection && reads == Array(1..<50),
            "diff-search-stop-retains-completed-pairs")
        blockedFile = nil
        try await wait("diff-search-resume-enabled") { FolderCompositionOwnedControls.isEnabled("Search More", in: window) }
        try need(FolderCompositionOwnedControls.press("Search More", in: window), "diff-search-resume-native-action")
        try await wait("diff-search-more-joined") {
            comparison.diffSearch.report?.remaining == 0 && !comparison.hasWorkForVerification
        }
        try need(comparison.diffSearch.report?.checked == 51 && comparison.diffSearch.report?.hits.map(\.file) == [0, 48, 49, 50]
            && reads == Array(1..<50) + [49, 50] && comparison.diffSearch.selected == selection
            && comparison.fileIndex == 0, "diff-search-more-leaves-prior-matches-and-selection")
        let evidence = c.root.appendingPathComponent("evidence/editor-diff-search-minimum-width.png")
        if CGPreflightScreenCaptureAccess() { try await GlassVerification.captureOwnedWindow(window, to: evidence) }
        else { try await UIVerification.snapshot(window, to: evidence) }
        blockedFile = 1
        comparison.diffSearch.query = "Prior"
        comparison.startDiffSearch()
        try await wait("diff-search-old-query-held") { reads.last == 1 && comparison.diffSearch.isRunning }
        comparison.diffSearch.query = "Changed query"
        try await wait("diff-search-old-query-drained") { !comparison.hasWorkForVerification }
        try need(comparison.diffSearch.report == nil && comparison.diffSearch.selected == nil, "diff-search-edit-invalidates-partial-report")
        blockedFile = nil
        holdsRestart = true
        comparison.diffSearch.query = "Prior"
        comparison.startDiffSearch()
        try await wait("diff-search-cancelled-read-held") { restartRead != nil }
        comparison.diffSearch.query = "Current"
        comparison.diffSearch.show()
        defer { restartRead?.resume() }
        try await wait("diff-search-replacement-query-focused") {
            guard let editor = queryField()?.currentEditor() else { return false }
            return window.firstResponder === editor
        }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try need(comparison.diffSearch.report == nil && comparison.diffSearch.isRunning
            && !comparison.diffSearch.canSearch, "diff-search-waits-for-owned-read")
        holdsRestart = false
        restartRead?.resume(); restartRead = nil
        try await wait("diff-search-submitted-replacement-completes") {
            comparison.diffSearch.report?.checked == 48 && !comparison.hasWorkForVerification
        }
        try need(comparison.diffSearch.report?.hits.count == 46
            && comparison.diffSearch.report?.hits.allSatisfy { $0.side == .current } == true,
            "diff-search-runs-only-the-newly-submitted-query")
        comparison.diffSearch.query = String(repeating: "é", count: 2_050)
        try need(comparison.diffSearch.queryTooLong && !comparison.diffSearch.canSearch
            && comparison.diffSearch.report == nil, "diff-search-refuses-oversized-unicode-query")
        await comparison.closeAndDrain()
    }

    private static func linkedScrollChecks(_ c: Context, capture: Bool) async throws {
        guard let parent = c.owner.window else { throw Failure(stage: "linked-scroll-parent") }
        let original = c.settings.editorPreferences
        var linked = original
        linked.linksComparisonScrolling = true
        linked.wrapsLines = true
        c.settings.updateEditorPreferences(linked)
        defer { c.settings.updateEditorPreferences(original) }
        let lines = (0..<310).map { "Generated line \($0) · " + String(repeating: "Read-only review 🧭 ", count: 12) + "\n" }
        var modified = lines
        modified[20] = "   " + lines[20]
        modified.insert(contentsOf: (0..<5).map { "Inserted line \($0)\n" }, at: 30)
        modified.removeSubrange(135..<137)
        @MainActor final class Source {
            var snapshot: EditorComparisonCapture
            var captures = 0
            init(_ snapshot: EditorComparisonCapture) { self.snapshot = snapshot }
        }
        let source = Source(.init(baseline: lines.joined(), current: modified.joined(),
            format: .init(bom: false, lineEnding: .lf), language: .plain))
        let view = EditorComparisonWindow(relativeTo: parent, settings: c.settings,
            pointSize: CGFloat(linked.basePointSize) * c.settings.interfaceSize.scale,
            labels: .init(title: "Compare Text Files", source: "Generated paired documents", left: "Saved document",
                right: "Revised document", detail: "Review the two text files.", refresh: "Refresh")) {
            source.captures += 1
            return source.snapshot
        }
        view.present()
        defer { view.window?.close() }
        try await wait("linked-scroll-ready") { view.window?.isKeyWindow == true && view.canLinkScrolling && view.linksScrolling }
        guard let window = view.window, let plan = view.planForVerification else { throw Failure(stage: "linked-scroll-plan") }
        try need(plan.correspondingLine(75, from: .before) == 80
            && plan.correspondingLine(193, from: .current) == 190
            && plan.correspondingLine(32, from: .current) == 30
            && plan.correspondingLine(130, from: .before) == 135,
            "linked-scroll-logical-mapping-and-empty-gaps")
        let before = view.beforeSurface, current = view.currentSurface
        window.contentView?.layoutSubtreeIfNeeded()
        try await wait("linked-scroll-native-viewports") {
            before.scrollView.contentView.bounds.height > 100 && current.scrollView.contentView.bounds.height > 100
        }
        try await verifyComparisonChangeMap(view, window: window, plan: plan,
            captureAt: capture ? c.root.appendingPathComponent("evidence/editor-diff-change-picker.png") : nil)
        try await Task.sleep(for: .milliseconds(350))
        before.scroll(to: .init(line: 75, column: 120, fragmentProgress: 0.4))
        func anchorsMatch() -> Bool {
            guard let left = before.scrollAnchor(), let right = current.scrollAnchor() else { return false }
            return left.line == 75 && left.column > 0 && right.line == 80
                && abs(left.fragmentProgress - right.fragmentProgress) < 0.15
        }
        do { try await wait("linked-scroll-right-follows-wrapped-line", anchorsMatch) }
        catch {
            func position(_ surface: NativeTextEditorSurface) -> String {
                let clip = surface.scrollView.contentView.bounds
                return "\(surface.scrollAnchor().map { "\($0.line),\($0.column),\($0.fragmentProgress)" } ?? "nil") y=\(clip.minY) document=\(surface.textView.frame.height)"
            }
            throw Failure(stage: "linked-scroll-right-follows-wrapped-line \(position(before)) / \(position(current))")
        }
        if capture { try await GlassVerification.captureOwnedWindow(window, to: c.root.appendingPathComponent("evidence/editor-diff-linked.png")) }
        current.scroll(to: .init(line: 193, column: 0, fragmentProgress: 0.25))
        try await wait("linked-scroll-left-follows-right") { before.scrollAnchor()?.line == 190 && current.scrollAnchor()?.line == 193 }
        guard let command = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Link Scrolling"),
              let action = command.action else { throw Failure(stage: "linked-scroll-native-command-missing") }
        try need(view.validateUserInterfaceItem(command) && command.state == .on, "linked-scroll-native-state")
        try need(NSApp.sendAction(action, to: view, from: command) && !view.linksScrolling, "linked-scroll-native-disable")
        let rightPosition = current.scrollView.contentView.bounds.minY
        before.scroll(to: .init(line: 205, column: 0, fragmentProgress: 0.5))
        try need(before.scrollAnchor()?.line == 205 && current.scrollView.contentView.bounds.minY == rightPosition,
            "linked-scroll-independent-when-disabled")
        try need(NSApp.sendAction(action, to: view, from: command) && view.linksScrolling, "linked-scroll-native-enable")
        try await wait("linked-scroll-resumed-at-current-viewport") { before.scrollAnchor()?.line == 205 && current.scrollAnchor()?.line == 208 }
        if ProcessInfo.processInfo.arguments.contains("--large-interface") {
            let originalSize = c.settings.interfaceSize
            defer { c.settings.interfaceSize = originalSize }
            c.settings.interfaceSize = .init(150)
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(.init(width: max(690, window.contentMinSize.width), height: max(770, window.contentMinSize.height)))
            try await wait("linked-scroll-enlarged-stacks-panes") {
                let left = before.convert(before.bounds, to: window.contentView)
                let right = current.convert(current.bounds, to: window.contentView)
                return abs((before.textView.font?.pointSize ?? 0) - CGFloat(linked.basePointSize) * 1.5) < 0.01
                    && abs(left.minX - right.minX) < 2 && left.intersection(right).isEmpty
            }
            try await Task.sleep(for: .milliseconds(350))
            before.scroll(to: .init(line: 75, column: 120, fragmentProgress: 0.4))
            try await wait("linked-scroll-enlarged-wrapped-viewport", anchorsMatch)
            if capture {
                try await GlassVerification.captureOwnedWindow(window, to: c.root.appendingPathComponent("evidence/editor-diff-linked-enlarged.png"))
            }
        }
        try await verifyComparisonKeyboard(view, window: window, captureAt: capture ? c.root.appendingPathComponent("evidence/editor-diff-find.png") : nil)
        try need(source.captures == 2, "whitespace-and-find-use-the-snapshot-until-explicit-refresh")
        view.diffSearch.show()
        view.diffSearch.query = "Inserted line 3"
        view.startDiffSearch()
        try await wait("single-diff-pre-refresh-search-result") { view.diffSearch.report?.hits.count == 1 && !view.hasWorkForVerification }
        guard let oldHit = view.diffSearch.selectedHit else { throw Failure(stage: "single-diff-pre-refresh-hit") }
        let lastBefore = before.generation, lastCurrent = current.generation
        let leftSelection = before.textView.selectedRange(), leftPosition = before.scrollView.contentView.bounds.minY
        let rightAnchor = current.scrollAnchor()
        let updated = modified.joined().replacingOccurrences(of: "Inserted line 3\n", with: "Replaced line 3\n")
            + "Generated end update\n"
        source.snapshot = EditorComparisonCapture(baseline: lines.joined(), current: updated,
            format: .init(bom: false, lineEnding: .lf), language: .plain)
        guard let refresh = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Refresh"), let reload = refresh.action else {
            throw Failure(stage: "diff-native-refresh-command")
        }
        try need(view.validateUserInterfaceItem(refresh) && NSApp.sendAction(reload, to: view, from: refresh), "diff-refresh-new-right-source")
        try await wait("diff-refresh-only-new-right-source") {
            !view.hasWorkForVerification && current.generation != lastCurrent && current.textView.string == updated
        }
        try need(source.captures == 3 && before.generation == lastBefore && before.textView.selectedRange() == leftSelection
            && abs(before.scrollView.contentView.bounds.minY - leftPosition) < 0.5
            && current.scrollAnchor()?.line == rightAnchor?.line, "diff-refresh-keeps-unchanged-pane-and-updated-anchor")
        let selection = current.textView.selectedRange()
        view.openDiffSearchHit(oldHit)
        try need(view.diffSearch.report == nil && view.diffSearch.query == "Inserted line 3"
            && current.textView.selectedRange() == selection, "single-diff-refresh-retires-only-the-old-search-results")
        view.diffSearch.query = "Replaced line 3"
        view.startDiffSearch()
        try await wait("single-diff-refresh-new-snapshot-searches") { view.diffSearch.report?.hits.count == 1 && !view.hasWorkForVerification }
        let identical = String(repeating: "Equal\n", count: 16_400)
        source.snapshot = .init(baseline: identical, current: identical,
            format: .init(bom: false, lineEnding: .lf), language: .plain)
        view.refresh()
        try await wait("single-diff-large-identical-pair-prepared") { !view.hasWorkForVerification && view.planForVerification?.exactTextMatches == true }
        view.diffSearch.query = "Equal"
        view.startDiffSearch()
        try await wait("single-diff-large-identical-pair-searched") { view.diffSearch.report != nil && !view.hasWorkForVerification }
        try need(view.diffSearch.report?.checked == 1 && view.diffSearch.report?.grouped == 0
            && view.diffSearch.report?.hits.isEmpty == true, "single-diff-search-reuses-the-displayed-line-comparison")
        let repeated = String(repeating: "Repeated 🧭 before\n", count: 250)
        source.snapshot = .init(baseline: repeated, current: "Repeated 🧭 after\n",
            format: .init(bom: false, lineEnding: .lf), language: .plain)
        view.refresh()
        try await wait("single-diff-many-matches-prepared") { !view.hasWorkForVerification }
        let captures = source.captures
        view.diffSearch.query = "Repeated 🧭"
        view.startDiffSearch()
        try await wait("single-diff-many-matches-searched") { view.diffSearch.report != nil && !view.hasWorkForVerification }
        guard let report = view.diffSearch.report, let rightHit = report.hits.last else {
            throw Failure(stage: "single-diff-many-matches-report")
        }
        try need(report.hits.count == 240 && report.hits.filter { $0.side == .before }.count == 239
            && rightHit.side == .current && report.clippedMatches && report.coverage == "Match limit reached",
            "single-diff-limit-keeps-a-match-from-each-version")
        view.openDiffSearchHit(rightHit)
        let rightText = current.textView.string as NSString
        try need(source.captures == captures && current.textView.selectedRange() == rightHit.range
            && rightText.substring(with: rightHit.range) == "Repeated 🧭", "single-diff-capped-right-hit-selects-exact-line")
        view.diffSearch.dismiss()
        current.find.bar.query.stringValue = "Generated"
        current.find.bar.onQuery?()
        await view.closeAndDrain()
        try need(!before.find.isWorking && !current.find.isWorking && before.textView.string.isEmpty && current.textView.string.isEmpty,
            "diff-keyboard-find-drains-the-exact-pair")
    }

    private static func verifyComparisonChangeMap(_ comparison: EditorComparisonWindow, window: NSWindow,
                                                  plan: EditorComparisonPlan, captureAt: URL?) async throws {
        let count = plan.changes.count
        guard count == 3, let content = window.contentView, let map = comparison.changeMap,
              let control = WorkspaceNetworkVerification.descendants(content).compactMap({ $0 as? NativeEditorComparisonMap }).first,
              let last = map.marks.last else { throw Failure(stage: "diff-map-native-control") }
        let before = comparison.beforeSurface, current = comparison.currentSurface
        let selections = [before.textView.selectedRange(), current.textView.selectedRange()]
        try await wait("diff-map-native-bounds") { control.bounds.width > 180 && control.bounds.height > 10 }
        let origin = control.convert(.init(x: 2 + (control.bounds.width - 4) * (last.current.lowerBound + last.current.upperBound) / 2,
            y: control.bounds.height * 0.8), to: nil)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: origin, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw Failure(stage: "diff-map-owned-click") }
        control.mouseDown(with: event)
        try need(comparison.position?.index == count - 1,
            "diff-map-selects-last-change, active \(comparison.position?.index ?? -1), native \(control.bounds)")
        func displays(_ offset: Int, in surface: NativeTextEditorSurface) -> Bool {
            let text = surface.textView
            guard let viewport = EditorTextViewport(text, drawing: text.visibleRect) else { return false }
            return NSLocationInRange(offset, viewport.characters)
        }
        try await wait("diff-map-reveals-the-change-on-both-sides") {
            displays(plan.changes[2].beforeRange.location, in: before) && displays(plan.changes[2].currentRange.location, in: current)
        }
        try need(control.accessibilityPerformDecrement(), "diff-map-accessible-previous")
        try await wait("diff-map-accessible-value") {
            comparison.position?.index == 1 && control.accessibilityValue() as? String == "Change 2 of 3"
        }
        try need(window.makeFirstResponder(control), "diff-map-native-focus")
        window.sendEvent(UIVerification.key("\u{f703}", code: 124, flags: [], window: window))
        try await wait("diff-map-native-right-arrow") { comparison.position?.index == 2 }
        let functionKey = String(UnicodeScalar(NSF7FunctionKey)!)
        let previous = UIVerification.key(functionKey, code: 98, flags: .command, window: window)
        try need(NSApp.mainMenu?.performKeyEquivalent(with: previous) == true && comparison.position?.index == 1,
            "Command-F7 selects the previous change, observed \(comparison.position?.index ?? -1)")
        let forward = UIVerification.key(functionKey, code: 98, flags: [], window: window)
        try need(NSApp.mainMenu?.performKeyEquivalent(with: forward) == true && comparison.position?.index == 2,
            "F7 selects the next change, observed \(comparison.position?.index ?? -1)")
        let shortcut = UIVerification.key(functionKey, code: 98, flags: .option, window: window)
        try need(NSApp.mainMenu?.performKeyEquivalent(with: shortcut) == true, "diff-map-go-to-change-shortcut")
        try await wait("diff-map-native-choice") { window.attachedSheet?.isKeyWindow == true }
        guard let sheet = window.attachedSheet, let table = UIVerification.nativeTables(in: sheet.contentView).first else {
            throw Failure(stage: "diff-map-choice-table")
        }
        try need(table.numberOfRows == count && table.selectedRow == 2 && sheet.firstResponder === table,
            "diff-map-choice-preselects-active-hunk")
        func excerpt(_ accent: EditorComparisonBackground.Accent) -> [String] {
            guard let content = sheet.contentView,
                  let preview = WorkspaceNetworkVerification.descendants(content)
                    .first(where: { $0.identifier?.rawValue == accent.identifier }) else { return [] }
            return WorkspaceNetworkVerification.descendants(preview).compactMap { ($0 as? NSTextField)?.stringValue }
        }
        try await wait("diff-map-previews-exact-removed-text") {
            excerpt(.removed).contains { $0.hasPrefix("Generated line 130") } && excerpt(.inserted).isEmpty
        }
        let choiceFrame = sheet.frame
        if let captureAt { try await UIVerification.snapshot(sheet, to: captureAt) }
        sheet.sendEvent(UIVerification.key("\u{f700}", code: 126, flags: [], window: sheet))
        try await wait("diff-map-arrows-update-bounded-excerpt") {
            table.selectedRow == 1 && excerpt(.removed).isEmpty
                && excerpt(.inserted) == ["Inserted line 0", "Inserted line 1", "Inserted line 2", "…"]
        }
        try need(sheet.firstResponder === table && comparison.position?.index == 2 && sheet.frame == choiceFrame,
            "diff-map-preview-preserves-focus-position-and-size")
        if let captureAt {
            try await UIVerification.snapshot(sheet,
                to: captureAt.deletingLastPathComponent().appendingPathComponent("editor-diff-change-picker-inserted.png"))
        }
        sheet.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: sheet))
        try await wait("diff-map-native-return") {
            window.isKeyWindow && window.attachedSheet == nil && comparison.position?.index == 1
        }
        let anchors = [before.scrollAnchor(), current.scrollAnchor()]
        try need(NSApp.mainMenu?.performKeyEquivalent(with: shortcut) == true, "diff-map-reopen-form")
        try await wait("diff-map-cancel-choice") { window.attachedSheet?.isKeyWindow == true }
        if let sheet = window.attachedSheet {
            sheet.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: sheet))
        }
        try await wait("diff-map-native-cancel") { window.isKeyWindow && window.attachedSheet == nil }
        try need(selections == [before.textView.selectedRange(), current.textView.selectedRange()]
            && anchors == [before.scrollAnchor(), current.scrollAnchor()] && comparison.position?.index == 1
            && before.textView.string == plan.before.text && current.textView.string == plan.current.text,
            "diff-map-keeps-native-selections-and-text")
    }

    private static func verifyComparisonKeyboard(_ view: EditorComparisonWindow, window: NSWindow, captureAt: URL?) async throws {
        let left = view.beforeSurface, right = view.currentSurface
        func command(_ title: String, menu: String) throws {
            guard let item = NSApp.mainMenu?.item(withTitle: menu)?.submenu?.item(withTitle: title), let action = item.action else {
                throw Failure(stage: "diff-keyboard-missing-\(title)")
            }
            try need(view.validateUserInterfaceItem(item) && NSApp.sendAction(action, to: view, from: item), "diff-keyboard-\(title)")
        }
        try need(window.makeFirstResponder(left.textView), "diff-keyboard-starts-on-left")
        try command("Find…", menu: "Edit")
        try need(left.find.isShown && left.find.bar.query.currentEditor() != nil && !right.find.isShown,
            "diff-keyboard-find-uses-active-left")
        let term = "Generated line 94"
        left.textView.setSelectedRange((left.textView.string as NSString).range(of: term))
        try command("Use Selection for Find", menu: "Edit")
        try need(left.find.bar.query.stringValue == term && !right.find.isShown, "diff-selection-seeds-only-focused-find")
        try await wait("diff-keyboard-left-match") { left.find.matchCount == 1 && !left.find.isWorking }
        try command("Find Next", menu: "Edit")
        try need((left.textView.string as NSString).substring(with: left.textView.selectedRange()) == "Generated line 94",
            "diff-keyboard-left-selection")
        try command("Switch Compared Text Pane", menu: "View")
        try need(window.firstResponder === right.textView, "diff-keyboard-focus-switch")
        try command("Find…", menu: "Edit")
        right.find.bar.query.stringValue = "Inserted line 3"
        right.find.bar.onQuery?()
        try await wait("diff-keyboard-right-match") { right.find.matchCount == 1 && !right.find.isWorking }
        try command("Find Next", menu: "Edit")
        let seed = right.textView.selectedRange()
        try need((right.textView.string as NSString).substring(with: seed) == "Inserted line 3" && !right.find.showsReplacement
            && NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: "Replace…") == nil,
            "diff-keyboard-right-read-only-find")
        if let captureAt { try await GlassVerification.captureOwnedWindow(window, to: captureAt) }
        let whitespace = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Whitespace")?.submenu
        guard let spacing = whitespace?.item(withTitle: EditorComparisonWhitespace.spacing.title),
              let exact = whitespace?.item(withTitle: EditorComparisonWhitespace.exact.title),
              let filter = spacing.action, let originalGroups = view.planForVerification?.changes.count else {
            throw Failure(stage: "diff-whitespace-native-menu")
        }
        let beforePositions = (left.scrollView.contentView.bounds.minY, right.scrollView.contentView.bounds.minY)
        let beforeGenerations = (left.generation, right.generation)
        let responder = window.firstResponder
        let anchors = (left.scrollAnchor(), right.scrollAnchor())
        for visible in [true, false] {
            try command(NativeTextEditorSurface.whitespaceMarksTitle, menu: "View")
            try need(left.textView.showsWhitespaceMarks == visible && right.textView.showsWhitespaceMarks == visible,
                "diff-whitespace-marks-toggle-together")
            try need(beforeGenerations == (left.generation, right.generation) && window.firstResponder === responder
                && right.textView.selectedRange() == seed && view.planForVerification?.changes.count == originalGroups
                && anchors == (left.scrollAnchor(), right.scrollAnchor()), "diff-whitespace-marks-preserve-both-panes")
        }
        try need(view.validateUserInterfaceItem(exact) && exact.state == .on
            && NSApp.sendAction(filter, to: view, from: spacing), "diff-whitespace-native-filter")
        try await wait("diff-whitespace-filter-suppresses-indentation-only-group") {
            view.planForVerification?.whitespace == .spacing && view.planForVerification?.changes.count == originalGroups - 1
        }
        try need(view.validateUserInterfaceItem(spacing) && spacing.state == .on
            && beforeGenerations == (left.generation, right.generation)
            && window.firstResponder === responder && right.textView.selectedRange() == seed
            && right.find.matchCount == 1 && right.find.bar.query.stringValue == "Inserted line 3"
            && abs(left.scrollView.contentView.bounds.minY - beforePositions.0) < 0.5
            && abs(right.scrollView.contentView.bounds.minY - beforePositions.1) < 0.5,
            "diff-whitespace-filter-keeps-both-viewports-and-native-find")
        if let captureAt {
            try await GlassVerification.captureOwnedWindow(window,
                to: captureAt.deletingLastPathComponent().appendingPathComponent("editor-diff-whitespace.png"))
        }
        try need(NSApp.sendAction(filter, to: view, from: exact), "diff-whitespace-native-show-all")
        try await wait("diff-whitespace-exact-marks-are-restored") {
            view.planForVerification?.whitespace == .exact && view.planForVerification?.changes.count == originalGroups
        }
        try command("Refresh", menu: "File")
        try await wait("diff-explicit-refresh-drains") { !view.hasWorkForVerification }
        try need(beforeGenerations == (left.generation, right.generation) && window.firstResponder === responder
            && right.textView.selectedRange() == seed && right.find.matchCount == 1
            && abs(left.scrollView.contentView.bounds.minY - beforePositions.0) < 0.5
            && abs(right.scrollView.contentView.bounds.minY - beforePositions.1) < 0.5,
            "diff-identical-refresh-keeps-viewport-find-and-selection")
        try command("Go to Line…", menu: "Edit")
        try await wait("diff-keyboard-line-sheet") { window.attachedSheet != nil }
        guard let sheet = window.attachedSheet, let line = right.lineIndex?.location(at: seed.location)?.line else {
            throw Failure(stage: "diff-keyboard-line-sheet-ownership")
        }
        try await wait("diff-keyboard-line-query-focused") { (sheet.firstResponder as? NSTextView)?.isFieldEditor == true }
        guard let field = sheet.firstResponder as? NSTextView else { throw Failure(stage: "diff-keyboard-line-field-editor") }
        try need(field.string == String(line), "diff-keyboard-line-field-starts-at-right-selection")
        field.selectAll(nil)
        field.insertText("240:999999", replacementRange: field.selectedRange())
        NSApp.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: sheet))
        try need(window.attachedSheet === sheet && right.textView.selectedRange() == seed, "diff-line-rejects-out-of-bounds-column")
        field.selectAll(nil)
        let keys: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("2", 19, []), ("4", 21, []), ("0", 29, []), (":", 41, .shift), ("6", 22, [])
        ]
        for (key, code, flags) in keys {
            NSApp.sendEvent(UIVerification.key(key, code: code, flags: flags, window: sheet))
        }
        NSApp.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: sheet))
        do {
            try await wait("diff-keyboard-line-selected-from-right") {
                let location = right.lineIndex?.location(at: right.textView.selectedRange().location)
                return window.attachedSheet == nil && window.firstResponder === right.textView
                    && right.textView.selectedRange().length == 0 && location?.line == 240 && location?.column == 6
            }
        } catch {
            let rightLine = right.lineIndex?.location(at: right.textView.selectedRange().location)?.line ?? 0
            let rightColumn = right.lineIndex?.location(at: right.textView.selectedRange().location)?.column ?? 0
            throw Failure(stage: "diff-keyboard-line-selected-from-right sheet=\(window.attachedSheet != nil) focus=\(window.firstResponder === right.textView) line=\(rightLine) column=\(rightColumn) expected=240:6 selection=\(right.textView.selectedRange().length)")
        }
        let farSelection = right.textView.selectedRange()
        let farY = right.scrollView.contentView.bounds.minY
        let leftSelection = left.textView.selectedRange()
        try need(abs(farY - beforePositions.1) > 100, "diff-line-jump-moves-the-native-viewport")
        try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key("-", code: 27, flags: .control, window: window)) == true,
            "diff-previous-location-key-equivalent")
        try need(window.firstResponder === right.textView && right.textView.selectedRange() == seed
            && abs(right.scrollView.contentView.bounds.minY - beforePositions.1) < 0.5
            && left.textView.selectedRange() == leftSelection && right.find.matchCount == 1,
            "diff-previous-location-restores-selection-scroll-and-find")
        try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key("_", code: 27, flags: [.control, .shift], window: window)) == true,
            "diff-next-location-key-equivalent")
        try need(right.textView.selectedRange() == farSelection && abs(right.scrollView.contentView.bounds.minY - farY) < 0.5
            && left.textView.selectedRange() == leftSelection, "diff-next-location-restores-the-exact-later-viewport")
        right.textView.setSelectedRange(.init(location: 0, length: 1))
        try command("Find in Selection…", menu: "Edit")
        try await wait("diff-right-scope-keeps-left-results") {
            right.find.matchCount == 0 && right.find.bar.count.stringValue == "No matches"
                && left.find.matchCount == 1 && left.textView.selectedRange() == leftSelection
        }
        guard let selectedScope = right.find.bar.options.menu?.item(withTitle: "Find in Selection"),
              let toggleScope = selectedScope.action else { throw Failure(stage: "diff-right-scope-option") }
        try need(selectedScope.state == .on && NSApp.sendAction(toggleScope, to: selectedScope.target, from: selectedScope),
            "diff-right-scope-clear-action")
        try await wait("diff-right-original-search-result-returns") { right.find.matchCount == 1 && left.find.matchCount == 1 }
        try need(window.makeFirstResponder(right.textView), "single-diff-selected-query-source")
        right.textView.setSelectedRange(seed)
        try command("Find in Diff…", menu: "Edit")
        try await wait("single-diff-native-query-focus") {
            guard let body = window.contentView,
                  let query = WorkspaceNetworkVerification.descendants(body).compactMap({ $0 as? NSSearchField })
                      .first(where: { $0.identifier?.rawValue == "diff-search-query" }), let editor = query.currentEditor() else { return false }
            return window.firstResponder === editor && query.stringValue == "Inserted line 3"
        }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try await wait("single-diff-searches-the-displayed-pair") { view.diffSearch.report?.checked == 1 && view.diffSearch.report?.hits.count == 1 }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try need(window.firstResponder === right.textView && right.textView.selectedRange() == seed
            && left.find.matchCount == 1 && right.find.matchCount == 1, "single-diff-opens-exact-match-without-resetting-native-find")
        view.diffSearch.wholeWords = true
        view.diffSearch.query = "nserted"
        view.startDiffSearch()
        try await wait("single-diff-search-honors-whole-words") { view.diffSearch.report?.hits.isEmpty == true }
        view.diffSearch.dismiss()
    }
    private static func sidebarChecks(_ c: Context) async throws -> [String] {
        let originalSize = c.settings.interfaceSize, originalAppearance = c.settings.appearance
        let enlarged = ProcessInfo.processInfo.arguments.contains("--large-interface")
        if enlarged { c.settings.interfaceSize = .init(150); c.settings.appearance = .light }
        defer { c.settings.interfaceSize = originalSize; c.settings.appearance = originalAppearance }
        let folder = c.files.directory.appendingPathComponent("Nested Project", isDirectory: true)
        let nested = folder.appendingPathComponent("Nested.txt")
        let initial = try await Task.detached {
            try FileManager().createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("Generated sidebar file\n".utf8).write(to: nested, options: .withoutOverwriting)
            try Data("Generated sidebar decoy\n".utf8).write(to: folder.appendingPathComponent("Opaque.bin"), options: .withoutOverwriting)
            let names = folder.deletingLastPathComponent().appendingPathComponent("Navigation Name Fixtures", isDirectory: true)
            try FileManager().createDirectory(at: names, withIntermediateDirectories: false)
            for name in ["EHT.swift", "EditorHTTPTrace.swift"] {
                try Data("let generatedSearchFixture = true\n".utf8).write(to: names.appendingPathComponent(name), options: .withoutOverwriting)
            }
            return try Data(contentsOf: c.files.first)
        }.value
        try c.target(.traverse)
        c.owner.window?.makeKeyAndOrderFront(nil)
        c.open()
        let editors = ApplicationLocalTextEditors.shared
        try await wait("sidebar-document-open") {
            guard let doc = editors.documentForVerification(at: c.files.first) else { return false }
            return !doc.hasPendingFileWork && doc.window.window?.isKeyWindow == true
        }
        guard let document = editors.documentForVerification(at: c.files.first), let native = document.window.window,
              let sidebar = document.window.fileSidebar, let files = sidebar.files else { throw Failure(stage: "sidebar-installed") }
        let surface = document.window.surface
        try need(!sidebar.isShown && files.outline.numberOfRows == 0, "sidebar-collapsed-loads-no-folders")
        try await verifyProjectFilePicker(document, parent: native, files: files, nested: nested, root: c.root)
        try await verifyProjectTextPicker(document, parent: native, files: files, nested: nested, root: c.root)
        try await verifyProjectDeclarations(document, parent: native, files: files, root: c.root, settings: c.settings)
        try need(!sidebar.isShown && files.outline.numberOfRows == 0, "project-search-does-not-expand-the-tree")
        let view = NSApp.mainMenu?.item(withTitle: "View")?.submenu
        guard let toggle = view?.item(withTitle: "Editor Sidebar"), let action = toggle.action,
              document.window.validateUserInterfaceItem(toggle), NSApp.sendAction(action, to: document.window, from: toggle) else {
            throw Failure(stage: "sidebar-native-view-command")
        }
        try await wait("sidebar-visible-tree") { sidebar.isShown && !sidebar.split.isAnimating && files.row(for: folder) != nil }
        try await verifySelectedFolderSearch(document, parent: native, files: files, folder: folder, nested: nested, root: c.root)
        func showMode(_ title: String, _ mode: EditorSidebarMode) throws {
            guard let item = view?.item(withTitle: title), let action = item.action else {
                throw Failure(stage: "sidebar-view-mode-command")
            }
            try need(document.window.validateUserInterfaceItem(item)
                && NSApp.sendAction(action, to: document.window, from: item)
                && sidebar.visit?.mode == mode && native.firstResponder === files.outline, "sidebar-view-menu-focuses-list")
        }
        try need(sidebar.split.sidebarPosition >= 180 && surface.window === native && files.row(for: nested) == nil,
            "sidebar-expands-the-live-viewport-with-a-lazy-tree")
        try need(!enlarged || InterfacePresentation.shared.size.percent == 150, "sidebar-uses-enlarged-interface")
        guard let folderRow = files.row(for: folder), let item = files.outline.item(atRow: folderRow),
              let focus = view?.item(withTitle: "Switch Between Sidebar and Text"), let focusAction = focus.action else {
            throw Failure(stage: "sidebar-keyboard-focus-command")
        }
        native.makeFirstResponder(surface.textView)
        _ = NSApp.sendAction(focusAction, to: document.window, from: focus)
        try need(native.firstResponder === files.outline, "sidebar-reaches-outline-by-keyboard")
        files.outline.selectRowIndexes(IndexSet(integer: folderRow), byExtendingSelection: false)
        native.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: native))
        try await wait("sidebar-child-listing") { files.outline.isItemExpanded(item) && files.row(for: nested) != nil }
        guard let nestedRow = files.row(for: nested) else { throw Failure(stage: "sidebar-nested-row") }
        files.outline.selectRowIndexes(IndexSet(integer: nestedRow), byExtendingSelection: false)
        native.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: native))
        try await wait("sidebar-opens-guarded-editor") {
            guard let doc = editors.documentForVerification(at: nested) else { return false }
            return !doc.hasPendingFileWork && doc.window.surface.textView.string == "Generated sidebar file\n"
                && doc.window.fileSidebar?.isShown == true && doc.window.fileSidebar?.files?.row(for: c.files.first) != nil
        }
        native.makeKeyAndOrderFront(nil)
        let text = surface.textView
        let original = text.string
        try await wait("sidebar-originating-tab-is-key") { native.isKeyWindow && NSApp.isActive && text.isEditable }
        try need(native.makeFirstResponder(text) && native.firstResponder === text, "sidebar-original-tab-caret")
        text.breakUndoCoalescing()
        text.insertText("\nUnsaved sidebar edit\n", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        text.breakUndoCoalescing()
        try await wait("sidebar-original-document-was-edited") { document.isDirty && text.string.hasSuffix("Unsaved sidebar edit\n") }
        try await wait("sidebar-unsaved-mark") {
            guard let row = files.row(for: c.files.first) else { return false }
            return files.outline.view(atColumn: 0, row: row, makeIfNecessary: true)?.accessibilityLabel()?.contains("Unsaved edits") == true
        }
        let previousWidth = sidebar.split.sidebarWidth
        native.setContentSize(.init(width: max(820, native.contentView?.bounds.width ?? 0), height: native.contentView?.bounds.height ?? 620))
        sidebar.split.restore(.init(isCollapsed: false, expandedWidth: 195))
        try await wait("sidebar-narrow-native-picker") { !files.compactModeControl.isHidden && files.modeControl.isHidden }
        guard let compactAction = files.compactModeControl.action else { throw Failure(stage: "sidebar-compact-mode-command") }
        files.compactModeControl.selectItem(withTitle: "Open")
        try need(NSApp.sendAction(compactAction, to: files.compactModeControl.target, from: files.compactModeControl), "sidebar-compact-choice")
        try need(files.outline.numberOfRows == 2 && files.row(for: c.files.first) != nil && files.row(for: nested) != nil,
            "sidebar-open-view-shows-both-documents")
        func captureSidebar(_ name: String) async throws {
            if let scroll = files.outline.enclosingScrollView {
                try need(!ToolContentMotion.hasCrossfade(in: scroll), "sidebar-mode-does-not-overlay-outgoing-rows")
                try await wait("sidebar-mode-entrance-settled") { !ToolContentMotion.hasContentEntrance(in: scroll) }
            }
            let destination = c.root.appendingPathComponent("evidence/" + name + ".png")
            if CGPreflightScreenCaptureAccess() { try await GlassVerification.captureOwnedWindow(native, to: destination) }
            else { try await UIVerification.snapshot(native, to: destination) }
        }
        try await captureSidebar("editor-sidebar-compact")
        sidebar.split.restore(.init(isCollapsed: false, expandedWidth: 338))
        try await wait("sidebar-wide-native-segments") { files.compactModeControl.isHidden && !files.modeControl.isHidden }
        try need(files.modeControl.selectedSegment == EditorSidebarMode.open.rawValue && files.modeControl.width(forSegment: 2) >= 54,
            "sidebar-mode-and-label-space-survive-resize")
        try showMode("Project Files", .files)
        try showMode("Open Editors", .open)
        guard let changeMode = files.modeControl.action else { throw Failure(stage: "sidebar-mode-command") }
        files.modeControl.selectedSegment = 0
        _ = NSApp.sendAction(changeMode, to: files.modeControl.target, from: files.modeControl)
        try await wait("sidebar-mode-switch-preserves-branches") { files.row(for: nested) != nil }
        try await captureSidebar("editor-sidebar-wide")
        sidebar.split.restore(.init(isCollapsed: false, expandedWidth: Double(previousWidth)))
        guard let restoredRow = files.row(for: nested) else { throw Failure(stage: "sidebar-restored-nested-row") }
        files.outline.selectRowIndexes(IndexSet(integer: restoredRow), byExtendingSelection: false)
        let generation = surface.generation, unsaved = text.string
        try revealCurrentFile(in: document)
        try need(files.outline.selectedRow == files.row(for: c.files.first) && native.firstResponder === files.outline
            && surface.generation == generation && text.string == unsaved && document.isDirty,
            "sidebar-reveal-overrides-selected-peer-and-retains-draft")
        try await captureSidebar("editor-files-sidebar")
        files.outline.selectRowIndexes(IndexSet(integer: restoredRow), byExtendingSelection: false)
        native.makeFirstResponder(files.outline)
        let recording = ProcessInfo.processInfo.arguments.contains("--check-development-motion")
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        func toggleSidebar(_ label: String) async throws {
            if recording {
                let title = native.title
                native.title = "Editor Files · generated review"
                defer { native.title = title }
                _ = try await NativeMotionRecorder.record(window: native, root: c.root, label: label,
                    sampling: .diagnostic(for: native)) {
                    try need(NSApp.sendAction(action, to: document.window, from: toggle), "sidebar-motion-native-command")
                }
            } else { _ = NSApp.sendAction(action, to: document.window, from: toggle) }
        }
        try await toggleSidebar("editor-sidebar-close")
        try await wait("sidebar-collapsed") { !sidebar.isShown && !sidebar.split.isAnimating }
        try need(native.firstResponder === text && sidebar.split.sidebarPosition == 0 && surface.window === native
            && text.string.hasSuffix("Unsaved sidebar edit\n"), "sidebar-collapse-returns-native-focus-and-retains-text")
        try await toggleSidebar("editor-sidebar-open")
        try await wait("sidebar-restores-expanded-branch") { sidebar.isShown && files.row(for: nested) == restoredRow }
        text.undoManager?.undo()
        try await wait("sidebar-undo-clears-unsaved") { !document.isDirty && text.string == original }
        try await verifyCurrentOutline(document, window: native, files: files, root: c.root, restorableFolder: nested)
        document.requestClose()
        editors.documentForVerification(at: nested)?.requestClose()
        try await wait("sidebar-owned-editors-close") { editors.documentCount == 0 }
        let actual = try await Task.detached { try Data(contentsOf: c.files.first) }.value
        try need(actual == initial, "sidebar-original-bytes-unchanged")
        try await verifyScopedFind(c)
        try await verifyNativeDeclarationOutlines(c)
        try await verifyScrollContext(c)
        try await verifyLocalDeclarationJump(c)
        try await verifyIndentGuides(c)
        return ["The editor's native View command expands a shared live split; F6 reaches the lazy file outline, Return expands a folder and opens its nested document with the same project root and sidebar visibility",
            "Command-P searches the exact local project by filename, Escape returns to the same caret, and Return opens a checked nested file with the sidebar still collapsed.",
            "Find Project Declarations uses explicit native search across Swift, TypeScript and C by initials, excludes unrelated files and literal decoys, and refuses a declaration hidden by a current draft.",
            "Reveal Current File opens the native Files sidebar, expands a nested document's path, and replaces a peer row selection without touching a draft.",
            "A narrow sidebar uses a native mode picker, and a wider sidebar restores the segmented control with the same selected mode and space for each label.",
            "Open shows both documents and Files retains expansion; a real edit shows an unsaved mark, collapse returns focus without replacing the surface or buffer, and Undo leaves the source bytes unchanged",
            "Document Outline follows the exact JSON draft generation. The text location commands retrace the jump and invalidate offsets after an edit. Stale outline rows refuse and Undo returns to the original files.",
            "Find in Selection uses native keyboard and Find options. Replace All only changes matches inside the captured scope, adjusts its length, and Undo requires a new scope. Each comparison side keeps its own search.",
            "Markdown headings, YAML block keys and supported declarations, including C-family definitions, open from the browser. Their native Outline rows move the caret to the exact token with Return.",
            "The editor's scroll context stays in the path row, follows the visible code, respects the live preference, and jumps back through the ordinary text location trail.",
            "F12 finds a declaration in the current file and ignores strings and comments. The native list fits both overloads and supports Down, Return and Escape. Back restores the caret and the Undo history remains intact.",
            "F5 completes one local name directly or lets the reader choose among distinct names. Cancel and moving through suggestions leave the file alone, and one native Undo restores the typed prefix.",
            "The distinct Outline and Go to Symbol shortcuts work in their native menus. Symbol search reaches prepared YAML keys and an unsaved declaration in a peer editor. Changed matches refuse to jump and Previous Text Location restores the source caret.",
            "Indent guides, matching-bracket highlights and optional whitespace marks use the visible native layout. Tabs, spaces and hard line breaks, local visibility overrides, wrapping and theme leave the buffer, viewport and Undo intact."]
            + (recording ? ["Local captures follow the actual native editor sidebar opening and closing"] : [])
    }

    private static func verifyProjectFilePicker(_ document: LocalTextDocumentController, parent: NSWindow,
                                                files: EditorFileSidebar, nested: URL, root: URL) async throws {
        let escaped = EditorProjectFileQuery(#"Notes\:123.txt:2:5"#)
        try need(escaped.filename == "Notes:123.txt" && escaped.address == .init(line: 2, column: 5)
            && EditorProjectFileQuery(#"Notes\:12"#).address == nil
            && EditorProjectFileQuery("Notes:0").filename == "Notes:0", "project-file-location-parser")
        let composed = EditorLineIndex("a💡b\nsecond\n")
        try need(composed.offset(at: .init(line: 1, column: 3)) == 1
            && composed.offset(at: .init(line: 2, column: 7)) == 11
            && composed.offset(at: .init(line: 1, column: 6)) == nil, "file-location-boundaries-and-composed-characters")
        let surface = document.window.surface
        let original = surface.textView.string, generation = surface.generation
        try need(parent.makeFirstResponder(surface.textView), "project-picker-starts-at-native-caret")
        let caret = surface.textView.selectedRange()
        func openPicker() async throws -> (EditorProjectFileSearch, NSPanel) {
            try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key("p", code: 35, flags: .command, window: parent)) == true,
                "project-picker-native-command-p")
            try await wait("project-picker-key-and-field-editor") {
                files.projectSearch?.panel?.isKeyWindow == true && files.projectSearch?.field.currentEditor() != nil
            }
            guard let picker = files.projectSearch, let panel = picker.panel else { throw Failure(stage: "project-file-panel") }
            return (picker, panel)
        }
        let (cancelled, first) = try await openPicker()
        for letter in "eht" { first.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: first)) }
        try await wait("project-picker-exact-and-initials-available") {
            cancelled.table.numberOfRows == 2 && cancelled.table.selectedRow == 0
        }
        let orderedNames = (0..<2).compactMap { row -> String? in
            guard let view = cancelled.table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return nil }
            return WorkspaceNetworkVerification.descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }.first
        }
        try need(orderedNames == ["EHT.swift", "EditorHTTPTrace.swift"], "project-picker-ranks-literal-stem-before-camel-case-initials")
        let expectsExit = first.occlusionState.contains(.visible) && first.isOnActiveSpace
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && (first.contentViewController as? ToolWindowChrome)?.motion.allows(.windowClosing) == true
        first.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: first))
        if expectsExit {
            try need(ToolWindowCloseMotion.isClosing(first) && first.isVisible && first.ignoresMouseEvents,
                "project-picker-escape-uses-shared-close-motion")
        }
        try await wait("project-picker-cancel-restores-editor") {
            cancelled.panel == nil && parent.isKeyWindow && parent.firstResponder === surface.textView
        }
        try need(surface.generation == generation && surface.textView.selectedRange() == caret, "project-picker-preserves-editor-state")
        let (picker, panel) = try await openPicker()
        for letter in "nested" { panel.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: panel)) }
        try await wait("project-picker-exact-nested-filename") {
            picker.table.numberOfRows == 1 && picker.table.selectedRow == 0
                && (picker.field.currentEditor() as? NSTextView)?.string == "nested"
        }
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(panel, to: root.appendingPathComponent("evidence/editor-project-file-picker.png"))
        }
        let editors = ApplicationLocalTextEditors.shared
        try await Task.detached {
            try FileManager().setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: nested.path)
        }.value
        panel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: panel))
        try await wait("project-picker-stale-row-refused") { picker.statusForVerification == SearchOpenValidation.changed.userMessage }
        try need(picker.panel === panel && editors.documentForVerification(at: nested) == nil, "stale-project-file-does-not-open")
        for letter in ".txt:1:11" { panel.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: panel)) }
        try await wait("project-picker-new-row-with-location") {
            picker.table.numberOfRows == 1 && picker.table.selectedRow == 0
                && picker.statusForVerification.contains("line 1, column 11")
        }
        panel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: panel))
        try await wait("project-file-return-opens-editor") {
            guard let opened = editors.documentForVerification(at: nested) else { return false }
            return picker.panel == nil && opened.window.window?.isKeyWindow == true && !opened.hasPendingFileWork
                && opened.window.surface.textView.selectedRange() == NSRange(location: 10, length: 0)
        }
        guard let opened = editors.documentForVerification(at: nested) else { throw Failure(stage: "project-file-opened-owner") }
        try need(opened.window.surface.textView.string == "Generated sidebar file\n" && !opened.isDirty
            && opened.window.fileSidebar?.isShown == false && surface.generation == generation && surface.textView.string == original,
            "project-file-exact-bytes-and-origin")
        guard let sidebar = opened.window.fileSidebar, let siblingFiles = sidebar.files,
              let window = opened.window.window else { throw Failure(stage: "project-file-nested-sidebar") }
        try visitTextLocation("Previous Text Location", from: opened.window)
        try await wait("previous-text-location-returns-from-project-file") {
            parent.isKeyWindow && parent.firstResponder === surface.textView && surface.textView.selectedRange() == caret
        }
        try visitTextLocation("Next Text Location", from: document.window)
        try await wait("next-text-location-restores-project-file-column") {
            window.isKeyWindow && opened.window.surface.textView.selectedRange() == NSRange(location: 10, length: 0)
        }
        let openedGeneration = opened.window.surface.generation
        try revealCurrentFile(in: opened)
        try await wait("sidebar-reveals-nested-current-file") {
            sidebar.isShown && !sidebar.split.isAnimating && sidebar.visit?.mode == .files
                && siblingFiles.row(for: nested) == siblingFiles.outline.selectedRow
        }
        try need(window.firstResponder === siblingFiles.outline && opened.window.surface.generation == openedGeneration
            && !opened.isDirty, "sidebar-reveal-focuses-exact-document-row")
        opened.requestClose()
        try await wait("project-picker-generated-child-closed") { editors.documentForVerification(at: nested) == nil }
        parent.makeKeyAndOrderFront(nil)

        let container = nested.deletingLastPathComponent()
        let originalPath = container.appendingPathComponent(".held-project-open")
        let replacement = container.appendingPathComponent(".replacement-project-open")
        let replacementBytes = Data("Generated new file\n".utf8)
        try await Task.detached { try replacementBytes.write(to: replacement, options: .withoutOverwriting) }.value
        let (handoff, handoffPanel) = try await openPicker()
        for letter in "nested.txt" {
            handoffPanel.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: handoffPanel))
        }
        try await wait("project-picker-handoff-selection") {
            handoff.table.numberOfRows == 1 && handoff.table.selectedRow == 0
                && (handoff.field.currentEditor() as? NSTextView)?.string == "nested.txt"
        }
        var substitution: Result<Void, Error>?
        handoff.didCheckOpenForVerification = { selection in
            substitution = Result {
                try need(selection.url == nested, "project-picker-handoff-exact-path")
                try FileManager.default.moveItem(at: nested, to: originalPath)
                try FileManager.default.moveItem(at: replacement, to: nested)
            }
        }
        defer { handoff.didCheckOpenForVerification = nil }
        handoffPanel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: handoffPanel))
        try await wait("project-picker-handoff-checked") { substitution != nil }
        try substitution?.get()
        try await wait("project-picker-handoff-replacement-refused") {
            guard let failed = editors.documentForVerification(at: nested),
                  let content = failed.window.window?.contentView,
                  !failed.window.saveButton.isEnabled, !failed.window.surface.textView.isEditable else { return false }
            return WorkspaceNetworkVerification.descendants(content).contains {
                ($0 as? NSTextField)?.stringValue.hasPrefix("This file changed after it was selected.") == true
            }
        }
        editors.documentForVerification(at: nested)?.requestClose()
        try await wait("project-picker-handoff-failed-editor-closed") { editors.documentForVerification(at: nested) == nil }
        try await Task.detached {
            try need(try Data(contentsOf: nested) == replacementBytes, "project-picker-handoff-replacement-untouched")
            try FileManager.default.moveItem(at: nested, to: replacement)
            try FileManager.default.moveItem(at: originalPath, to: nested)
            try FileManager.default.removeItem(at: replacement)
        }.value
        parent.makeKeyAndOrderFront(nil)
    }

    private static func visitTextLocation(_ title: String, from editor: NativeTextEditorWindow) throws {
        guard let item = UIVerification.menuItem("Go", title), let action = item.action else {
            throw Failure(stage: "text-location-menu")
        }
        try need(editor.validateUserInterfaceItem(item) && NSApp.sendAction(action, to: editor, from: item), "text-location-dispatch-" + title)
    }

    private static func verifyProjectTextPicker(_ document: LocalTextDocumentController, parent: NSWindow,
                                                files: EditorFileSidebar, nested: URL, root: URL) async throws {
        let original = "Generated sidebar file\n"
        let needle = "sidebar"
        let range = (original as NSString).range(of: needle)
        let editors = ApplicationLocalTextEditors.shared
        func search(_ query: String) async throws -> (EditorProjectFileSearch, NSPanel) {
            try await submitProjectQuery(query, editor: document.window, files: files, menu: "Edit", title: "Find in Project…")
        }
        func result() async throws -> (EditorProjectFileSearch, NSPanel) {
            let (picker, panel) = try await search(needle)
            try await wait("project-text-one-saved-match") { picker.table.numberOfRows == 1 && picker.table.selectedRow == 0 }
            return (picker, panel)
        }

        let (picker, panel) = try await result()
        try await UIVerification.snapshot(panel, to: root.appendingPathComponent("evidence/editor-project-text-picker.png"))
        panel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: panel))
        try await wait("project-text-opens-exact-matching-text") {
            guard let open = editors.documentForVerification(at: nested) else { return false }
            return picker.panel == nil && open.window.window?.isKeyWindow == true
                && open.window.surface.textView.selectedRange() == range && !open.hasPendingFileWork
        }
        guard let opened = editors.documentForVerification(at: nested), let window = opened.window.window else {
            throw Failure(stage: "project-text-opened-editor")
        }
        let body = opened.window.surface.textView
        try need(body.string == original && !opened.isDirty, "project-text-selection-preserves-file")
        guard let nestedFiles = opened.window.fileSidebar?.files,
              let findProject = UIVerification.menuItem("Edit", "Search Scope", "Find in Project…"), let action = findProject.action else {
            throw Failure(stage: "project-text-selection-seed-command")
        }
        try need(opened.window.validateUserInterfaceItem(findProject) && NSApp.sendAction(action, to: opened.window, from: findProject),
            "project-text-selection-seed-native-dispatch")
        try await wait("project-text-selection-seed-panel") {
            nestedFiles.projectSearch?.panel?.isKeyWindow == true && nestedFiles.projectSearch?.field.currentEditor() != nil
        }
        guard let seeded = nestedFiles.projectSearch, let seededPanel = seeded.panel else {
            throw Failure(stage: "project-text-selection-seed-picker")
        }
        guard let fieldEditor = seeded.field.currentEditor() as? NSTextView else {
            throw Failure(stage: "project-text-selection-seed-field-editor")
        }
        try need(fieldEditor.string == needle && fieldEditor.selectedRange() == NSRange(location: 0, length: needle.utf16.count)
            && seeded.table.numberOfRows == 0 && seeded.statusForVerification.hasPrefix("Press Return"),
            "project-text-seeds-exact-selection-and-awaits-explicit-search")
        seededPanel.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: seededPanel))
        try await wait("project-text-seed-returns-selection") { seeded.panel == nil && window.isKeyWindow }
        try need(body.selectedRange() == range, "project-text-seed-cancel-preserves-selection")
        body.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: range)],
            affinity: .downstream, stillSelecting: false)
        try need(body.selectedRanges.count == 2 && opened.window.surface.find.selectedQuery() == nil,
            "find-seed-refuses-multiple-ranges")
        body.setSelectedRange(range)
        body.insertText("changed", replacementRange: range)
        let end = NSRange(location: body.string.utf16.count, length: 0)
        body.setSelectedRange(end)
        try await wait("project-text-fresh-draft-prepared") { opened.isDirty && opened.window.surface.canGoToLine }
        parent.makeKeyAndOrderFront(nil)
        let (_, retry) = try await result()
        retry.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: retry))
        try await wait("project-text-returns-to-open-draft") { picker.panel == nil && window.isKeyWindow }
        try need(body.string == "Generated changed file\n" && body.selectedRange() == end && opened.isDirty,
            "project-text-refuses-a-stale-offset-in-an-unsaved-buffer")
        body.undoManager?.undo()
        try await wait("project-text-undo-to-saved-bytes") { body.string == original && !opened.isDirty }
        opened.requestClose()
        try await wait("project-text-generated-editor-closed") { editors.documentForVerification(at: nested) == nil }
        parent.makeKeyAndOrderFront(nil)

        let firstFolder = nested.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("00 Paged Search", isDirectory: true)
        let pagedNeedle = "pagedtoken"
        let sampleText = "Found \(pagedNeedle) here\n"
        let last = try await Task.detached {
            try FileManager().createDirectory(at: firstFolder, withIntermediateDirectories: false)
            var created = firstFolder
            for index in 0...64 {
                let suffix = index == 64 ? "TXT" : "txt"
                created = firstFolder.appendingPathComponent(String(format: "Sample-%03d.\(suffix)", index))
                let text = index == 0 || index == 64 ? sampleText : "No matches in this file\n"
                try Data(text.utf8).write(to: created, options: .withoutOverwriting)
            }
            return created
        }.value
        let (paged, pagedPanel) = try await search(pagedNeedle)
        let more = paged.searchButtonForVerification
        try await wait("project-text-first-page-holds-next-candidate") {
            paged.table.numberOfRows == 1 && paged.statusForVerification.contains("64 files searched") && more.title == "Search More"
        }
        guard let advance = more.action else { throw Failure(stage: "project-text-next-page-native-command") }
        try need(NSApp.sendAction(advance, to: more.target, from: more) && more.title == "Stop"
            && NSApp.sendAction(advance, to: more.target, from: more), "project-text-stop-next-page-command")
        try await wait("project-text-stopping-keeps-first-page") {
            more.title == "Search More" && paged.table.numberOfRows == 1 && paged.table.selectedRow == 0
                && paged.statusForVerification.hasPrefix("Search stopped.")
        }
        try need(NSApp.sendAction(advance, to: more.target, from: more), "project-text-resume-next-page-command")
        try await wait("project-text-appends-and-preserves-selection") {
            paged.table.numberOfRows == 2 && paged.table.selectedRow == 0 && more.title == "Search"
        }
        try await UIVerification.snapshot(pagedPanel, to: root.appendingPathComponent("evidence/editor-project-text-continuation.png"))
        pagedPanel.sendEvent(UIVerification.key("\u{f701}", code: 125, flags: [], window: pagedPanel))
        try need(paged.table.selectedRow == 1, "project-text-select-second-page-hit-by-keyboard")
        pagedPanel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: pagedPanel))
        try await wait("project-text-opens-second-page-location") {
            guard let open = editors.documentForVerification(at: last) else { return false }
            return paged.panel == nil && open.window.window?.isKeyWindow == true
                && open.window.surface.textView.selectedRange() == (sampleText as NSString).range(of: pagedNeedle)
        }
        editors.documentForVerification(at: last)?.requestClose()
        try await wait("project-text-second-page-editor-closed") { editors.documentForVerification(at: last) == nil }
        parent.makeKeyAndOrderFront(nil)

        let project = files.projectFolder
        let scoped = "scopedfiletoken"
        try await Task.detached {
            try Data("let \(scoped) = 1\n".utf8).write(to: project.appendingPathComponent("Scoped Example.SWIFT"), options: .withoutOverwriting)
            try Data("Generated \(scoped)\n".utf8).write(to: project.appendingPathComponent("Scoped Example.md"), options: .withoutOverwriting)
            try Data([255, 254, 0]).write(to: project.appendingPathComponent("Unavailable Example.swift"), options: .withoutOverwriting)
        }.value
        let (typed, scopedPanel) = try await submitProjectQuery(scoped, editor: document.window, files: files,
            menu: "Edit", title: "Find in Project…", fileType: "Swift")
        try await wait("project-text-filter-only-reads-matching-file-types") {
            typed.table.numberOfRows == 1 && typed.statusForVerification.contains("4 files searched")
                && typed.statusForVerification.contains("1 file skipped")
        }
        try await UIVerification.snapshot(scopedPanel, to: root.appendingPathComponent("evidence/editor-project-text-file-type.png"))
        try selectProjectFileType("Markdown", in: typed)
        try need(typed.table.numberOfRows == 0 && typed.statusForVerification.hasPrefix("Press Return"),
            "changing-file-type-retires-results-without-reading")
        scopedPanel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: scopedPanel))
        try await wait("project-text-file-type-restarts-exact-scope") {
            typed.table.numberOfRows == 1 && typed.statusForVerification.contains("searched")
                && !typed.statusForVerification.contains("skipped")
        }
        let narrow = project.appendingPathComponent("Nested Search", isDirectory: true)
        try await Task.detached {
            try FileManager().createDirectory(at: narrow, withIntermediateDirectories: false)
            try Data("Scoped version of \(scoped)\n".utf8).write(to: narrow.appendingPathComponent("Scoped Example.md"), options: .withoutOverwriting)
            try FileManager().createSymbolicLink(at: project.appendingPathComponent("Alias Folder"), withDestinationURL: narrow)
        }.value
        func enterFolder(_ value: String) throws {
            let folder = typed.folderForVerification
            try need(scopedPanel.makeFirstResponder(folder), "project-text-relative-folder-focus")
            guard let text = folder.currentEditor() as? NSTextView else { throw Failure(stage: "project-text-relative-folder-editor") }
            text.insertText(value, replacementRange: NSRange(location: 0, length: text.string.utf16.count))
            scopedPanel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: scopedPanel))
        }
        try enterFolder("../Outside")
        try await wait("project-text-refuses-a-folder-escape") {
            typed.table.numberOfRows == 0 && typed.statusForVerification.hasPrefix("Enter a relative folder")
        }
        try enterFolder("Alias Folder")
        try await wait("project-text-refuses-a-symbolic-folder") {
            typed.table.numberOfRows == 0 && typed.statusForVerification.contains("could not be checked")
        }
        try enterFolder("Nested Search/")
        try await wait("project-text-restricts-to-the-exact-typed-folder") {
            typed.table.numberOfRows == 1 && typed.statusForVerification.contains("1 file searched")
        }
        try await UIVerification.snapshot(scopedPanel, to: root.appendingPathComponent("evidence/editor-project-text-relative-folder.png"))
        scopedPanel.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: scopedPanel))
        try await wait("project-text-file-type-closes-to-editor") { typed.panel == nil && parent.isKeyWindow }
    }

    private static func selectProjectFileType(_ name: String, in picker: EditorProjectFileSearch) throws {
        let popup = picker.fileTypeForVerification
        guard let item = popup.item(withTitle: name), let action = popup.action else {
            throw Failure(stage: "project-text-file-type-menu")
        }
        popup.select(item)
        try need(NSApp.sendAction(action, to: popup.target, from: popup), "project-text-file-type-dispatch")
    }

    private static func submitProjectQuery(_ query: String, editor: NativeTextEditorWindow, files: EditorFileSidebar,
                                           menu: String, title: String, fileType: String? = nil) async throws -> (EditorProjectFileSearch, NSPanel) {
        let command = menu == "Edit" ? UIVerification.menuItem(menu, "Search Scope", title) : UIVerification.menuItem(menu, title)
        guard let item = command, let action = item.action,
              editor.validateUserInterfaceItem(item), NSApp.sendAction(action, to: editor, from: item) else {
            throw Failure(stage: "project-query-native-command-" + title)
        }
        try await wait("project-query-field") {
            files.projectSearch?.panel?.isKeyWindow == true && files.projectSearch?.field.currentEditor() != nil
        }
        guard let picker = files.projectSearch, let panel = picker.panel else { throw Failure(stage: "project-query-panel") }
        if let fileType { try selectProjectFileType(fileType, in: picker) }
        for letter in query { panel.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: panel)) }
        try need(picker.table.numberOfRows == 0 && picker.statusForVerification.hasPrefix("Press Return"),
            "project-query-waits-for-explicit-search")
        panel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: panel))
        return (picker, panel)
    }

    private static func verifyProjectDeclarations(_ document: LocalTextDocumentController, parent: NSWindow,
                                                   files: EditorFileSidebar, root: URL, settings: BrowserSettings) async throws {
        let project = files.projectFolder
        let swift = project.appendingPathComponent("A Navigation Source.SWIFT")
        let script = project.appendingPathComponent("B Navigation Source.ts")
        let cFile = project.appendingPathComponent("C Navigation Source.c")
        let original = "// Header\nstruct EditorDraftHistory {}\n"
        let target = (original as NSString).range(of: "struct").location
        try await Task.detached {
            try Data(original.utf8).write(to: swift, options: .withoutOverwriting)
            try Data("// function EditorDecoyHandler() {}\nconst decoy = \"class EditorDecoyHistory {}\";\nexport const EditorDraftHelpers = () => true;\n".utf8)
                .write(to: script, options: .withoutOverwriting)
            try Data("static int EditorDataHandler(void) { return 0; }\n".utf8).write(to: cFile, options: .withoutOverwriting)
            try Data(original.utf8).write(to: project.appendingPathComponent("Ignored Declaration.txt"), options: .withoutOverwriting)
            let excluded = project.appendingPathComponent(".ssh", isDirectory: true)
            try FileManager().createDirectory(at: excluded, withIntermediateDirectories: false)
            try Data(original.utf8).write(to: excluded.appendingPathComponent("Excluded.swift"), options: .withoutOverwriting)
            let generated = project.appendingPathComponent("Nested Build/node_modules", isDirectory: true)
            try FileManager().createDirectory(at: generated, withIntermediateDirectories: true)
            try Data("export function EditorDependencyHandler() {}\n".utf8)
                .write(to: generated.appendingPathComponent("Dependency.js"), options: .withoutOverwriting)
        }.value
        let editors = ApplicationLocalTextEditors.shared
        func result() async throws -> (EditorProjectFileSearch, NSPanel) {
            let (picker, panel) = try await submitProjectQuery("edh", editor: document.window, files: files,
                menu: "Go", title: "Find Project Declarations…")
            try await wait("project-declaration-expected-rows") {
                picker.table.numberOfRows == 3 && picker.table.selectedRow == 0
            }
            let titles = (0..<3).compactMap { row -> String? in
                guard let view = picker.table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return nil }
                return WorkspaceNetworkVerification.descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }.first
            }
            try need(titles == ["EditorDraftHistory", "EditorDraftHelpers", "EditorDataHandler"], "project-declarations-recognized-names-and-initials")
            return (picker, panel)
        }
        let origin = document.window.surface.textView.selectedRange()
        let (picker, panel) = try await result()
        try await UIVerification.snapshot(panel, to: root.appendingPathComponent("evidence/editor-project-declarations.png"))
        panel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: panel))
        try await wait("project-declaration-opens-the-exact-file-and-position") {
            guard let opened = editors.documentForVerification(at: swift) else { return false }
            return picker.panel == nil && opened.window.window?.isKeyWindow == true
                && opened.window.surface.textView.selectedRange() == NSRange(location: target, length: 0)
                && opened.window.surface.textView.string == original
        }
        guard let opened = editors.documentForVerification(at: swift), let window = opened.window.window else {
            throw Failure(stage: "project-declaration-document")
        }
        try visitTextLocation("Previous Text Location", from: opened.window)
        try await wait("project-declaration-previous-text-location") {
            parent.isKeyWindow && document.window.surface.textView.selectedRange() == origin
        }
        window.makeKeyAndOrderFront(nil)
        let surface = opened.window.surface, body = surface.textView
        let commented = "/*" + original.dropFirst(2) + "*/\n"
        body.breakUndoCoalescing()
        body.insertText(commented, replacementRange: NSRange(location: 0, length: body.string.utf16.count))
        body.breakUndoCoalescing()
        let end = NSRange(location: body.string.utf16.count, length: 0)
        body.setSelectedRange(end)
        try await wait("project-declaration-draft-comment-prepared") {
            opened.isDirty && surface.currentOutlineForSymbols?.value.entries.isEmpty == true
        }
        parent.makeKeyAndOrderFront(nil)
        let (_, retry) = try await result()
        retry.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: retry))
        try await wait("project-declaration-draft-reopened") { picker.panel == nil && window.isKeyWindow }
        try need(body.selectedRange() == end && body.string == commented && opened.isDirty,
            "project-declaration-stale-lexical-context-refused")
        body.undoManager?.undo()
        try await wait("project-declaration-undo") { !opened.isDirty && body.string == original }
        let saved = try await Task.detached { try Data(contentsOf: swift) }.value
        try need(saved == Data(original.utf8), "project-declaration-original-bytes")
        opened.requestClose()
        try await wait("project-declaration-generated-editor-closed") { editors.documentForVerification(at: swift) == nil }
        parent.makeKeyAndOrderFront(nil)
        let savedPreferences = settings.editorPreferences
        var includesDependencies = savedPreferences
        includesDependencies.includesGeneratedProjectFolders = true
        settings.updateEditorPreferences(includesDependencies)
        defer { settings.updateEditorPreferences(savedPreferences) }
        let (all, allPanel) = try await submitProjectQuery("edh", editor: document.window, files: files,
            menu: "Go", title: "Find Project Declarations…")
        try await wait("project-declarations-opt-in-adds-one-generated-dependency") { all.table.numberOfRows == 4 }
        allPanel.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: allPanel))
        try await wait("project-declarations-dismissing-dependency-search") { all.panel == nil && parent.isKeyWindow }
    }

    private static func revealCurrentFile(in document: LocalTextDocumentController) throws {
        guard let command = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Reveal Current File"),
              let action = command.action else { throw Failure(stage: "sidebar-reveal-native-command") }
        try need(document.window.validateUserInterfaceItem(command)
            && NSApp.sendAction(action, to: document.window, from: command), "sidebar-reveal-native-routing")
    }

    private static func verifyScopedFind(_ context: Context) async throws {
        let editors = ApplicationLocalTextEditors.shared
        let file = context.files.directory.appendingPathComponent("Generated Selection Find.txt")
        let prefix = "alpha before\n", selection = "let alpha = \"🧭\"\nalpha alpha\n", suffix = "alpha after\n"
        let original = prefix + selection + suffix
        try await Task.detached {
            try Data(original.utf8).write(to: file, options: .withoutOverwriting)
            let source = "catalog log 🧭 log"
            let lookup = source as NSString
            let middle = lookup.range(of: "log")
            let compass = lookup.range(of: "🧭")
            let words = EditorFindOptions(matchMode: .wholeWord)
            guard case .matches(let matches) = EditorFindPlan.search(text: source, query: "log", options: words, within: middle),
                  matches.ranges.isEmpty,
                  case .refused(.invalidRanges) = EditorFindPlan.search(text: source, query: "log", options: words,
                    within: .init(location: compass.location + 1, length: 1)) else {
                throw Failure(stage: "selection-find-preserves-real-word-and-unicode-boundaries")
            }
            let forged = EditorFindMatches(text: source, query: "log", options: words,
                ranges: [lookup.range(of: "log", options: .backwards)], isComplete: true, selection: middle)
            guard case .refused(.invalidRanges) = EditorFindPlan.replace(forged, with: "changed", format: .init(bom: false, lineEnding: .lf)) else {
                throw Failure(stage: "selection-find-plan-refuses-an-outside-replacement")
            }
        }.value
        context.browser.refresh(nil)
        try await wait("selection-find-generated-listing") { context.browser.rowsByURL[file] != nil && context.browser.orderingTask == nil }
        context.select(file)
        context.browser.openSelection(nil)
        try await wait("selection-find-editor-owned") {
            guard let document = editors.documentForVerification(at: file) else { return false }
            return document.window.window?.isKeyWindow == true && !document.hasPendingFileWork
        }
        guard let document = editors.documentForVerification(at: file), let window = document.window.window else {
            throw Failure(stage: "selection-find-editor-missing")
        }
        let surface = document.window.surface, text = surface.textView, find = surface.find
        let range = NSRange(location: prefix.utf16.count, length: selection.utf16.count)
        window.makeFirstResponder(text)
        text.setSelectedRange(range)
        try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key("l", code: 37, flags: [.command, .option], window: window)) == true
            && find.isShown, "selection-find-native-key-equivalent")
        find.perform(.showReplaceInterface)
        try await wait("selection-find-query-focus") { find.bar.query.currentEditor() != nil }
        for character in "alpha" { window.sendEvent(UIVerification.key(String(character), code: 0, flags: [], window: window)) }
        try await wait("selection-find-three-matches") { find.matchCount == 3 && find.bar.replaceAll.isEnabled }
        try need(find.bar.options.menu?.item(withTitle: "Find in Selection")?.state == .on,
            "selection-find-options-shows-active-scope")
        let replacement = "append_prefix_alpha"
        let edited = prefix + selection.replacingOccurrences(of: "alpha", with: replacement) + suffix
        find.bar.replacement.stringValue = replacement
        find.bar.replaceAll.performClick(nil)
        try await wait("selection-find-replacement-and-expanded-scope") {
            text.string == edited && document.isDirty && find.matchCount == 3 && !find.isWorking
        }
        try await UIVerification.snapshot(window, to: context.root.appendingPathComponent("evidence/editor-find-selection.png"))
        text.undoManager?.undo()
        try await wait("selection-find-undo-revokes-stale-scope") {
            text.string == original && !document.isDirty && find.matchCount == 0 && !find.bar.replaceAll.isEnabled
                && find.bar.count.stringValue == "Select text again"
        }
        guard let scopeOption = find.bar.options.menu?.item(withTitle: "Find in Selection"), let action = scopeOption.action else {
            throw Failure(stage: "selection-find-optional-whole-document-route")
        }
        try need(scopeOption.isEnabled && NSApp.sendAction(action, to: scopeOption.target, from: scopeOption), "selection-find-allow-explicit-document-scope")
        try await wait("selection-find-explicit-whole-document-recheck") { find.matchCount == 5 }
        document.requestClose()
        try await wait("selection-find-generated-editor-closed") { editors.documentForVerification(at: file) == nil }
    }

    private static func verifySelectedFolderSearch(_ document: LocalTextDocumentController, parent: NSWindow,
                                                   files: EditorFileSidebar, folder: URL, nested: URL, root: URL) async throws {
        let other = folder.deletingLastPathComponent().appendingPathComponent("Outside Folder Search.txt")
        let needle = "sidebar"
        try await Task.detached {
            try Data("Same sidebar token outside the selected folder\n".utf8).write(to: other, options: .withoutOverwriting)
        }.value
        guard let row = files.row(for: folder), let command = files.menu(forRow: row)?.item(withTitle: "Find Text in Folder…"),
              let action = command.action, document.window.validateUserInterfaceItem(command),
              NSApp.sendAction(action, to: document.window, from: command) else {
            throw Failure(stage: "selected-folder-native-context-menu")
        }
        try await wait("selected-folder-picker-owns-input") {
            files.projectSearch?.panel?.isKeyWindow == true && files.projectSearch?.field.currentEditor() != nil
        }
        guard let picker = files.projectSearch, let panel = picker.panel else { throw Failure(stage: "selected-folder-panel") }
        try need(panel.title == "Find in Folder", "selected-folder-picker-title")
        for character in needle { panel.sendEvent(UIVerification.key(String(character), code: 0, flags: [], window: panel)) }
        panel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: panel))
        try await wait("selected-folder-one-candidate") {
            picker.table.numberOfRows == 1 && picker.statusForVerification.hasPrefix("1 match · 1 file searched")
        }
        try await UIVerification.snapshot(panel, to: root.appendingPathComponent("evidence/editor-folder-text-picker.png"))
        panel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: panel))
        let editors = ApplicationLocalTextEditors.shared
        try await wait("selected-folder-exact-editor") {
            guard let opened = editors.documentForVerification(at: nested) else { return false }
            return picker.panel == nil && opened.window.window?.isKeyWindow == true
                && opened.window.surface.textView.selectedRange() == ("Generated sidebar file\n" as NSString).range(of: needle)
        }
        try need(editors.documentForVerification(at: other) == nil, "selected-folder-did-not-open-outside-scope")
        editors.documentForVerification(at: nested)?.requestClose()
        try await wait("selected-folder-origin-restored") { editors.documentForVerification(at: nested) == nil && parent.isVisible }
        parent.makeKeyAndOrderFront(nil)
        try await wait("selected-folder-edit-menu-owned") {
            parent.isKeyWindow && UIVerification.menuItem("Edit", "Search Scope", "Find in Selected Folder…")?.target === document.window
        }
        guard let shortcut = UIVerification.menuItem("Edit", "Search Scope", "Find in Selected Folder…"),
              let find = shortcut.action, document.window.validateUserInterfaceItem(shortcut),
              NSApp.sendAction(find, to: document.window, from: shortcut) else { throw Failure(stage: "selected-folder-edit-menu") }
        try await wait("selected-folder-menu-opens-same-scope") { picker.panel?.isKeyWindow == true }
        guard let again = picker.panel else { throw Failure(stage: "selected-folder-menu-panel") }
        try need(again.title == "Find in Folder" && picker.table.numberOfRows == 0, "selected-folder-menu-starts-fresh")
        again.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: again))
        try await wait("selected-folder-escape-restores-editor") { picker.panel == nil && parent.isKeyWindow }
    }

    private static func verifyCurrentOutline(_ document: LocalTextDocumentController, window: NSWindow,
                                             files: EditorFileSidebar, root: URL, restorableFolder: URL) async throws {
        let surface = document.window.surface, text = surface.textView
        let original = text.string
        guard let command = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Document Outline") else {
            throw Failure(stage: "outline-native-command")
        }
        func openOutline() throws {
            let shortcut = UIVerification.key("o", code: 31, flags: [.command, .shift], window: window)
            try need(document.window.validateUserInterfaceItem(command)
                && NSApp.mainMenu?.performKeyEquivalent(with: shortcut) == true, "outline-native-opening")
        }
        if ProcessInfo.processInfo.arguments.contains("--check-development-motion"),
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let title = window.title
            window.title = "Document Outline · generated review"
            defer { window.title = title }
            _ = try await NativeMotionRecorder.record(window: window, root: root, label: "editor-outline-mode",
                sampling: .diagnostic(for: window), action: openOutline)
        } else { try openOutline() }
        try await wait("outline-initial-json-keys") {
            files.outline.numberOfRows == 3 && surface.outlinePresentation?.generation == surface.generation
                && files.outlineSearch.currentEditor() != nil && window.firstResponder === files.outlineSearch.currentEditor()
        }
        func activateRow(_ row: Int) {
            window.makeFirstResponder(files.outline)
            files.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        }
        let origin = text.selectedRange()
        window.sendEvent(UIVerification.key("e", code: 14, flags: [], window: window))
        try await wait("outline-search-filters-names") { files.outline.numberOfRows == 2 && files.outline.selectedRow == 0 }
        window.sendEvent(UIVerification.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, flags: [], window: window))
        try need(files.outline.selectedRow == 1, "outline-search-down-arrow")
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        let enabled = (original as NSString).range(of: "\"enabled\"").location
        try need(enabled != NSNotFound && text.selectedRange().location == enabled && window.firstResponder === text,
            "outline-caret-reaches-exact-key-on-shared-line")
        try openOutline()
        window.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: window))
        try await wait("outline-search-escape-clears") { files.outline.numberOfRows == 3 && files.outlineSearch.stringValue.isEmpty }
        window.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: window))
        try need(window.firstResponder === text && text.selectedRange().location == enabled, "outline-search-escape-returns-to-caret")
        guard let previous = UIVerification.menuItem("Go", "Previous Text Location"), let next = UIVerification.menuItem("Go", "Next Text Location") else {
            throw Failure(stage: "outline-text-location-menu")
        }
        guard let nextItem = UIVerification.menuItem("Go", "Outline", "Next Outline Item") else {
            throw Failure(stage: "outline-next-item-menu")
        }
        func location(_ item: NSMenuItem) throws {
            guard let action = item.action else { throw Failure(stage: "outline-text-location-action") }
            try need(document.window.validateUserInterfaceItem(item) && NSApp.sendAction(action, to: document.window, from: item),
                "outline-text-location-command")
        }
        try location(previous)
        try need(window.firstResponder === text && text.selectedRange() == origin, "outline-previous-location-restores-original-selection")
        try location(next)
        try need(text.selectedRange().location == enabled, "outline-next-location-restores-selected-key")
        let draft = "{\n  \"outer\": {\n    \"inner 🧭\": true,\n    \"more\": [1, 2]\n  },\n  \"last\": false\n}\n"
        text.breakUndoCoalescing()
        text.insertText(draft, replacementRange: .init(location: 0, length: original.utf16.count))
        text.breakUndoCoalescing()
        try need(!document.window.validateUserInterfaceItem(previous) && !document.window.validateUserInterfaceItem(next)
            && !document.window.validateUserInterfaceItem(nextItem),
            "outline-text-edit-invalidates-both-directions")
        let caret = text.selectedRange()
        activateRow(0)
        try need(text.selectedRange() == caret, "outline-refuses-a-stale-row-during-preparation")
        try await wait("outline-replaces-draft-keys") {
            surface.outlinePresentation?.generation == surface.generation && files.outline.numberOfRows == 4
                && document.isDirty
        }
        let inner = (draft as NSString).range(of: "\"inner 🧭\"").location
        activateRow(1)
        try need(text.selectedRange().location == inner && window.firstResponder === text,
            "outline-updated-nested-unicode-key")
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/editor-document-outline.png"))
        }
        text.undoManager?.undo()
        try await wait("outline-native-undo-restores-keys") {
            !document.isDirty && text.string == original && files.outline.numberOfRows == 3
        }
        files.selectMode(.files)
        try need(files.row(for: restorableFolder) != nil, "outline-switch-preserves-expanded-file-branch")
    }

    private static func outlineSyntaxChecks() async throws {
        try await Task.detached {
            func outline(_ text: String, _ language: TextSyntaxLanguage) throws -> EditorDocumentOutline {
                let value = try TextDocumentValue.original(Data(text.utf8))
                let syntax = TextSyntax.color(value, language: language)
                let delimiters = EditorCFamilyOutline.languages.contains(language)
                    ? EditorDelimiterWalk.capture(in: value.text, syntax: syntax, cancelled: { false }) : nil
                return EditorDocumentOutline.prepare(text: value.text, syntax: syntax,
                    language: language, lines: .init(value.text), preparedDelimiters: delimiters, cancelled: { false })
            }
            let c = try outline(#"""
                #define BODY \
                    struct Skipped {};
                typedef struct Payload { int value; } Payload;
                struct Payload *reference;
                int prototype(int value);
                static const char *Render(const char *text)
                {
                    const char *literal = "int pretend() {}";
                    return call(text);
                }
                """#, .c)
            try need(c.entries.map(\.title) == ["Payload", "Render"] && c.entries.map(\.kind) == [.type, .function]
                && c.entries.map(\.line) == [3, 6], "outline-c-proven-definitions-and-macro-boundaries")
            let cpp = try outline("""
                namespace Storage {
                template <class Parameter>
                struct Unit final : public Node {
                    int visit(int value) const noexcept { return value; }
                };
                enum class Shape : unsigned { Rect };
                inline int Unit::make(int value) { return value; }
                }
                """, .cpp)
            try need(cpp.entries.map(\.title) == ["Storage", "Unit", "visit", "Shape", "make"], "outline-cpp-scoped-types-and-methods")
            let objective = try outline("""
                @protocol Incomplete;
                @interface Navigator : NSObject
                @end
                @implementation Navigator
                @end
                @protocol Renderer <NSObject>
                @end
                const char *fixture = "@interface Bogus : NSObject";
                """, .objectiveCPP)
            try need(objective.entries.map(\.title) == ["Navigator", "Navigator", "Renderer"], "outline-objective-c-named-types")
            let markdown = try outline("# Root 🧭\r\n```text\r\n# Inside fence\r\n```\r\n  ### Child ##\r\n#Tail\r\n", .markdown)
            try need(markdown.entries.map(\.title) == ["Root 🧭", "Child"]
                && markdown.entries.map(\.depth) == [0, 2] && markdown.entries.map(\.line) == [1, 5], "outline-markdown-heading-boundaries")
            let json = try outline("{\"before\": \"{\", // \"skip\": false\n \"items\": [{\"next\" /* comment */: \"}\"}], \"after\": true}", .jsonc)
            try need(json.entries.map(\.title) == ["before", "items", "next", "after"]
                && json.entries.map(\.depth) == [0, 0, 2, 0], "outline-jsonc-lexical-keys-and-depth")
            let yaml = try outline("""
                ---
                services:
                  - name: first
                    chart:
                      path: /generated
                    script: |
                      ignored: inside
                  - "label": next
                flow: {
                  hidden: [nested]
                }
                # omitted: comment
                marker-value: ---
                ...
                ---
                  'loose key': true
                """, .yaml)
            try need(yaml.entries.map(\.title) == ["services", "name", "chart", "path", "script", "label", "flow", "marker-value", "loose key"]
                && yaml.entries.map(\.depth) == [0, 1, 1, 2, 1, 1, 0, 0, 0]
                && yaml.entries.map(\.line) == [2, 3, 4, 5, 6, 8, 9, 13, 16], "outline-yaml-block-sequences-and-streams")
            let swift = try outline(##"""
                @MainActor public class Café {
                    private class func préparer() {}
                    struct Voyage {
                        init() {}
                    }
                    let note = #"""
                    A nested quote: """
                    func omittedString() {}
                    """#
                    let match = #/
                    func omittedPattern()
                    /#
                    // func omittedComment() {}
                }
                extension Café.Voyage {
                    func `repeat`() {}
                }
                """##, .swift)
            try need(swift.entries.map(\.title) == ["Café", "préparer", "Voyage", "init", "Café.Voyage", "repeat"]
                && swift.entries.map(\.depth) == [0, 1, 1, 2, 0, 1]
                && swift.entries.map(\.kind) == [.type, .function, .type, .function, .type, .function], "outline-swift-literal-and-modifier-boundaries")
            let continued = """
                struct Workspace {
                    func // A generated comment with func skipped()

                        /* Nested /* comment */ on the name line */ préparer() {}
                    func/* comment */ready() {}
                    func
                    func intact() {}
                }
                """
            let split = try outline(continued, .swift)
            try need(split.entries.map(\.title) == ["Workspace", "préparer", "ready", "intact"]
                && split.entries.map(\.line) == [1, 2, 5, 7] && split.entries[1].signatureLine == 4
                && split.scopes.count == 4, "outline-swift-function-names-follow-bounded-comment-and-blank-lines")
            let multiline = """
                struct Workspace {
                    func calculate(
                        using value: () -> Int = { 5 }
                    ) async /* generated; comment */ throws -> Swift.Int?
                    {
                        return value()
                    }
                }
                protocol Requirement {
                    func calculate(
                        input: Int
                    ) -> Int
                    var summary: String { get }
                }
                """
            let blocks = try outline(multiline, .swift)
            let returning = (multiline as NSString).range(of: "return value()")
            let unrelated = (multiline as NSString).range(of: "var summary")
            try need(blocks.entries.filter { $0.title == "calculate" }.count == 2
                && blocks.scopes.map(\.entry.title) == ["Workspace", "calculate", "Requirement"]
                && blocks.scope(containing: returning)?.entry.title == "calculate"
                && blocks.scope(containing: unrelated)?.entry.title == "Requirement",
                "outline-multiline-swift-follows-real-parameter-and-body-braces")
            let python = try outline("""
                class Café:
                    async def préparer(self):
                        '''
                        def omitted_docstring():
                            pass
                        '''
                        def local():
                            pass
                    # def omitted_comment():
                def next_page():
                    pass
                """, .python)
            try need(python.entries.map(\.title) == ["Café", "préparer", "local", "next_page"]
                && python.entries.map(\.depth) == [0, 1, 2, 0], "outline-python-async-and-docstring-boundaries")
            let rust = try outline(##"""
                pub(in crate::project) struct Café<T>(T);
                unsafe impl<T> Draw for Café<T> {
                    type Alias = T;
                    fn render(&self) {
                        let raw = r#"
                        fn omitted_raw() {}
                        "#;
                        let plain = "a generated multiline string
                        fn omitted_plain() {}
                        ";
                        /* outer /* nested */
                        fn omitted_comment() {}
                        */
                    }
                }
                pub (crate) unsafe extern "C" fn r#type() {}
                pub(super) union ResultBits { bits: u64, float: f64 }
                type Callback = fn(i32);
                """##, .rust)
            try need(rust.entries.map(\.title) == ["Café", "impl<T> Draw for Café<T>", "Alias", "render", "r#type", "ResultBits", "Callback"]
                && rust.entries.map(\.depth) == [0, 0, 1, 1, 0, 0, 0], "outline-rust-visibility-impl-and-literal-boundaries")
            let script = try outline("""
                export default class extends Example {}
                export class Café {}
                export async function* $charts() {
                  const template = `generated
                  function ignoredTemplate() {}
                  `;
                  const localValue = function expression() {};
                  const formatLabel = async (value = ")", extra = [1, 2]) => value + extra;
                  const mapPoint = point => point;
                  const inspectCallback = wrap((point) => point);
                  const notCode = "value => value";
                  const called = (function () {})();
                  // function ignoredComment() {}
                  // const omitted = () => false;
                  function namedHelper() {}
                }
                """, .javascript)
            try need(script.entries.map(\.title) == ["Café", "$charts", "localValue", "formatLabel", "mapPoint", "namedHelper"]
                && script.entries.map(\.depth) == [0, 0, 1, 1, 1, 1]
                && script.entries.map(\.kind) == [.type, .function, .function, .function, .function, .function],
                "outline-javascript-generators-assignments-arrows-and-literal-boundaries")
            let typeScript = try outline("""
                import type { Item } from "./items";
                export declare namespace Generated.Example {
                  export interface View { title: string }
                  export type Value<T> = T | null;
                  export const enum Reading { Ready }
                  export abstract class Drawing {}
                  export function plot(value: Value<View>): number;
                  const render: Renderer<View> = (value: View): Promise<Result[]> => renderItem(value);
                  const contextual: (value: View) => string = decorate(callback);
                  const factory = (value: View): ((a: View) => Value<View>) => buildRenderer(value);
                }
                """, .typescript)
            try need(typeScript.entries.map(\.title) == ["Generated.Example", "View", "Value", "Reading", "Drawing", "plot", "render"]
                && typeScript.entries.map(\.depth) == [0, 1, 1, 1, 1, 1, 1], "outline-typescript-types-and-proven-arrows")
            let tomlSource = #"""
                "root 🌱".choice = true
                [package . "public.widgets"] # note
                description = """
                [ignore.string]
                closing quotes"""""
                ports = [
                  [8080, 443], # not a table
                ]
                "a=b" . enabled = true
                [[target]]
                path = 'notes#file'
                [[target]]
                path = 'other'
                """#
            let toml = try outline(tomlSource, .toml)
            let outlineLines = EditorLineIndex(tomlSource)
            try need(toml.availability == .ready && toml.entries.map(\.title) == [
                "\"root 🌱\".choice", "package . \"public.widgets\"", "description", "ports", "\"a=b\" . enabled",
                "target", "path", "target", "path"
            ] && toml.entries.map(\.line) == [1, 2, 3, 6, 9, 10, 11, 12, 13]
                && toml.entries.map(\.depth) == [0, 0, 1, 1, 1, 0, 1, 0, 1]
                && toml.scrolledScopes(at: outlineLines.starts[8], onLine: 9).map(\.title) == ["package . \"public.widgets\""],
                "outline-toml-tables-quoted-keys-values-and-context")
            let incompleteTOML = try outline("[valid]\nvalue = [\n[99]\n", .toml)
            try need(incompleteTOML.availability == .limited && incompleteTOML.entries.map(\.title) == ["valid", "value"],
                "outline-toml-partial-array-keeps-earlier-entries")
            let large = try outline(String(repeating: "# Heading\n", count: EditorDocumentOutline.maximumEntries + 8), .markdown)
            try need(large.availability == .limited && large.entries.count == EditorDocumentOutline.maximumEntries, "outline-finite-heading-count")
            let unsupported = try outline("# Text content\n", .plain)
            try need(unsupported.availability == .unsupported && unsupported.entries.isEmpty, "outline-unsupported-language-is-explicit")
        }.value
    }

    private static func verifyScrollContext(_ context: Context) async throws {
        let editors = ApplicationLocalTextEditors.shared
        let file = context.files.directory.appendingPathComponent("Scroll Context.swift")
        let original = "struct Workspace {\n    func calculate(\n        using start: Int = 0\n    ) async -> Int\n    {\n"
            + (0..<150).map { "        let value\($0) = \($0)\n" }.joined()
            + "        return start\n    }\n}\n" + String(repeating: "// after the type\n", count: 95)
        try await Task.detached {
            try Data(original.utf8).write(to: file, options: .withoutOverwriting)
            func outline(_ value: String, _ language: TextSyntaxLanguage) -> EditorDocumentOutline {
                let syntax = TextSyntax.color(value, language: language)
                let delimiters = EditorDelimiterWalk.capture(in: value, syntax: syntax, cancelled: { false })
                return EditorDocumentOutline.prepare(text: value, syntax: syntax, language: language,
                    lines: EditorLineIndex(value), preparedDelimiters: delimiters, cancelled: { false })
            }
            let markdown = "# Parent\n\n## Child\nchild body\n# Next\nsecond body\n"
            let headings = outline(markdown, .markdown), lines = EditorLineIndex(markdown)
            try need(headings.scrolledScopes(at: lines.starts[3], onLine: 4).map(\.title) == ["Parent", "Child"]
                && headings.scrolledScopes(at: lines.starts[5], onLine: 6).map(\.title) == ["Next"],
                "scroll-context-markdown-boundaries")
            let json = "{\n  \"outer\": /* label */ {\n    \"items\": [\n      \"ignore ]\",\n      true\n    ],\n    \"next\": 1\n  }\n}"
            let values = outline(json, .jsonc), jsonLines = EditorLineIndex(json)
            try need(values.scrolledScopes(at: jsonLines.starts[4], onLine: 5).map(\.title) == ["outer", "items"]
                && values.scrolledScopes(at: jsonLines.starts[6], onLine: 7).map(\.title) == ["outer"],
                "scroll-context-jsonc-container-and-string-boundaries")
            let swift = "struct Workspace {\n    func calculate(f: () -> Int = { 1 }) {\n        let note = \"}\"\n        // }\n    }\n    let other = 2\n}\noutside\n"
            let declarations = outline(swift, .swift), swiftLines = EditorLineIndex(swift)
            try need(declarations.scrolledScopes(at: swiftLines.starts[3], onLine: 4).map(\.title) == ["Workspace", "calculate"]
                && declarations.scrolledScopes(at: swiftLines.starts[5], onLine: 6).map(\.title) == ["Workspace"]
                && declarations.scrolledScopes(at: swiftLines.starts[7], onLine: 8).isEmpty,
                "scroll-context-swift-ignores-signature-closure-literals-and-comments")
            let go = "type Packet struct {\n  size int\n}\nfunc Count() int {\n  return 3\n}\nvar later = 2\n"
            let goScopes = outline(go, .go), goLines = EditorLineIndex(go)
            try need(goScopes.scrolledScopes(at: goLines.starts[1], onLine: 2).map(\.title) == ["Packet"]
                && goScopes.scrolledScopes(at: goLines.starts[4], onLine: 5).map(\.title) == ["Count"]
                && goScopes.scrolledScopes(at: goLines.starts[6], onLine: 7).isEmpty,
                "scroll-context-go-type-and-function-boundaries")
            let cpp = "namespace Demo {\n int count()\n {\n  return 3;\n }\n int outside;\n}\nint later;\n"
            let cppScopes = outline(cpp, .cpp), cppLines = EditorLineIndex(cpp)
            try need(cppScopes.scrolledScopes(at: cppLines.starts[3], onLine: 4).map(\.title) == ["Demo", "count"]
                && cppScopes.scrolledScopes(at: cppLines.starts[5], onLine: 6).map(\.title) == ["Demo"]
                && cppScopes.scrolledScopes(at: cppLines.starts[7], onLine: 8).isEmpty,
                "scroll-context-C-family-pairs-real-implementation-braces")
        }.value
        let initial = context.settings.editorPreferences
        defer { context.settings.updateEditorPreferences(initial) }
        context.browser.refresh(nil)
        try await wait("scroll-context-generated-listing") {
            context.browser.rowsByURL[file] != nil && context.browser.orderingTask == nil
        }
        context.select(file)
        context.browser.openSelection(nil)
        try await wait("scroll-context-native-editor") {
            guard let document = editors.documentForVerification(at: file) else { return false }
            return document.window.window?.isKeyWindow == true && !document.hasPendingFileWork
                && document.window.surface.outlinePresentation?.value.scopes.count == 2
        }
        guard let document = editors.documentForVerification(at: file), let window = document.window.window else {
            throw Failure(stage: "scroll-context-owned-window")
        }
        let editor = document.window, surface = editor.surface, button = editor.scrollContextButton
        try need(button.isHidden, "scroll-context-no-extra-header-at-start")
        surface.scroll(to: .init(line: 83, column: 0, fragmentProgress: 0))
        try await wait("scroll-context-follows-viewport") { !button.isHidden && button.title == "Workspace › calculate" }
        let originalCaret = surface.textView.selectedRange()
        let originalAnchor = surface.scrollAnchor()
        let originalGeneration = surface.generation
        try await UIVerification.snapshot(window, to: context.root.appendingPathComponent("evidence/editor-scroll-context.png"))
        var disabled = initial
        disabled.showsScrollContext = false
        context.settings.updateEditorPreferences(disabled)
        try await wait("scroll-context-live-toggle-off") { button.isHidden }
        try need(surface.scrollAnchor() == originalAnchor && surface.textView.selectedRange() == originalCaret,
            "scroll-context-toggle-does-not-move-text")
        context.settings.updateEditorPreferences(initial)
        try await wait("scroll-context-live-toggle-on") { !button.isHidden }
        guard let plain = TextSyntaxLanguage.allCases.firstIndex(of: .plain),
              let swift = TextSyntaxLanguage.allCases.firstIndex(of: .swift),
              let changeLanguage = editor.language.action else { throw Failure(stage: "scroll-context-syntax-menu") }
        editor.language.selectItem(at: plain)
        _ = NSApp.sendAction(changeLanguage, to: editor.language.target, from: editor.language)
        try need(button.isHidden, "scroll-context-revokes-the-old-language-immediately")
        editor.language.selectItem(at: swift)
        _ = NSApp.sendAction(changeLanguage, to: editor.language.target, from: editor.language)
        try await wait("scroll-context-exact-language-restored") { button.title == "Workspace › calculate" && !button.isHidden }
        let expected = (original as NSString).range(of: "func calculate").location
        button.performClick(nil)
        try need(surface.textView.selectedRange().location == expected && window.firstResponder === surface.textView,
            "scroll-context-native-click-exact-heading")
        guard let previous = UIVerification.menuItem("Go", "Previous Text Location"),
              let action = previous.action, editor.validateUserInterfaceItem(previous),
              NSApp.sendAction(action, to: editor, from: previous) else { throw Failure(stage: "scroll-context-return-command") }
        try await wait("scroll-context-original-scroll-restored") { surface.scrollAnchor() == originalAnchor }
        try need(surface.generation == originalGeneration && surface.textView.selectedRange() == originalCaret
            && surface.textView.string == original && !document.isDirty, "scroll-context-never-edits-buffer")
        let inside = (original as NSString).range(of: "value83")
        surface.textView.setSelectedRange(inside)
        guard let choose = UIVerification.menuItem("Go", "Choose Visible Scope…"), let chooseAction = choose.action,
              editor.validateUserInterfaceItem(choose), NSApp.sendAction(chooseAction, to: editor, from: choose) else {
            throw Failure(stage: "visible-scope-native-picker")
        }
        try await wait("visible-scopes-open-in-their-current-editor") { window.attachedSheet?.isKeyWindow == true }
        guard let scopeSheet = window.attachedSheet else { throw Failure(stage: "visible-scope-native-sheet") }
        try await UIVerification.snapshot(scopeSheet, to: context.root.appendingPathComponent("evidence/editor-visible-scopes.png"))
        scopeSheet.sendEvent(UIVerification.key(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126, flags: [], window: scopeSheet))
        scopeSheet.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: scopeSheet))
        try await wait("visible-scope-picker-opens-the-parent") {
            window.attachedSheet == nil && window.isKeyWindow && window.firstResponder === surface.textView
                && surface.textView.selectedRange().location == 0 && surface.scrollAnchor()?.line == 0
        }
        try need(surface.generation == originalGeneration && !document.isDirty,
            "visible-scope-picker-does-not-edit-the-document")
        try need(NSApp.sendAction(action, to: editor, from: previous), "visible-scope-picker-reuses-text-location-history")
        try await wait("visible-scope-picker-original-scroll-restored") {
            surface.scrollAnchor() == originalAnchor && surface.textView.selectedRange() == inside
        }
        guard let nextItem = UIVerification.menuItem("Go", "Outline", "Next Outline Item"),
              let previousItem = UIVerification.menuItem("Go", "Outline", "Previous Outline Item"),
              let scope = UIVerification.menuItem("Go", "Outline", "Go to Enclosing Scope"),
              let jumpToScope = scope.action else { throw Failure(stage: "outline-navigation-menu") }
        let text = surface.textView
        let down = UIVerification.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125,
            flags: [.command, .option], window: window)
        let up = UIVerification.key(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126,
            flags: [.command, .option], window: window)
        text.setSelectedRange(.init(location: 0, length: 0))
        try need(!editor.validateUserInterfaceItem(previousItem) && editor.validateUserInterfaceItem(nextItem),
            "outline-arrows-admit-only-the-next-location")
        try need(NSApp.mainMenu?.performKeyEquivalent(with: down) == true, "outline-next-key-dispatches-after-scope-sheet")
        try need(text.selectedRange().location == expected && !editor.validateUserInterfaceItem(nextItem),
            "outline-next-key-reaches-the-next-item")
        try need(NSApp.mainMenu?.performKeyEquivalent(with: up) == true && text.selectedRange().location == 0,
            "outline-arrow-jumps-to-previous-item")
        text.setSelectedRange(inside)
        for offset in [expected, 0] {
            try need(editor.validateUserInterfaceItem(scope) && NSApp.sendAction(jumpToScope, to: editor, from: scope)
                && text.selectedRange().location == offset && window.firstResponder === text,
                "outline-enclosing-scope-climbs-from-method-to-type")
        }
        try need(!editor.validateUserInterfaceItem(scope), "outline-enclosing-scope-stops-at-the-outer-declaration")
        try need(NSApp.sendAction(action, to: editor, from: previous) && text.selectedRange().location == expected
            && surface.generation == originalGeneration && !document.isDirty, "outline-jumps-reuse-the-existing-location-trail")
        let outside = 180
        let beforeScroll = surface.scrollAnchor()?.line
        surface.scroll(to: .init(line: outside, column: 0, fragmentProgress: 0))
        let afterScroll = surface.scrollAnchor()?.line
        do {
            try await wait("scroll-context-stops-at-real-closing-brace") {
                button.isHidden && (surface.scrollAnchor()?.line ?? -1) >= outside - 1
            }
        } catch let failure as Failure {
            throw Failure(stage: "\(failure.stage)-anchor-\(beforeScroll ?? -1)-\(afterScroll ?? -1)-\(surface.scrollAnchor()?.line ?? -1)-hidden-\(button.isHidden)")
        }
        document.requestClose()
        try await wait("scroll-context-generated-editor-closed") { editors.documentForVerification(at: file) == nil }
    }

    private static func verifyLocalDeclarationJump(_ context: Context) async throws {
        let editors = ApplicationLocalTextEditors.shared
        let file = context.files.directory.appendingPathComponent("Generated Declarations.swift")
        let code = """
        func uniqueTarget() {}
        func process(value: Int) {}
        func process(value: String) {}
        func processText() {}
        func reference() {
            uniqueTarget()
            process(value: 10)
            // uniqueTarget()
            let note = "uniqueTarget()"
            uniqueT
            proc
        }
        """
        try await Task.detached { try Data(code.utf8).write(to: file, options: .withoutOverwriting) }.value
        context.browser.refresh(nil)
        try await wait("declaration-generated-file-listed") { context.browser.rowsByURL[file] != nil && context.browser.orderingTask == nil }
        context.select(file)
        context.browser.openSelection(nil)
        try await wait("declaration-current-syntax") {
            guard let document = editors.documentForVerification(at: file) else { return false }
            return document.window.window?.isKeyWindow == true && document.window.surface.canFindDeclaration
        }
        guard let document = editors.documentForVerification(at: file), let window = document.window.window,
              let edit = UIVerification.menuItem("Edit")?.submenu,
              let command = UIVerification.menuItem("Go", "Find Declaration in This File"),
              let find = command.action, let previous = UIVerification.menuItem("Go", "Previous Text Location"),
              let back = previous.action else { throw Failure(stage: "declaration-native-commands") }
        let editor = document.window, surface = editor.surface, text = surface.textView, value = code as NSString
        try need(edit.items.filter { !$0.isHidden && !$0.isSeparatorItem }.count <= 25
            && edit.item(withTitle: command.title) == nil,
            "editor-edit-menu-organization")
        try need(UIVerification.menuItem("Edit", "Lines", "Duplicate Lines") != nil
            && UIVerification.menuItem("Edit", "JSON", "Format JSON") != nil, "editor-edit-submenus")
        try need(editor.discoverableCommands().contains(where: { $0.0.action == find && $0.1 == "Go" }), "editor-go-command-discovery")
        let generation = surface.generation, canUndo = text.undoManager?.canUndo
        window.makeFirstResponder(text)
        func caret(_ marker: String, inside offset: Int) -> NSRange {
            .init(location: value.range(of: marker).location + offset, length: 0)
        }
        func send(_ action: Selector, item: NSMenuItem, phase: String) throws {
            try need(editor.validateUserInterfaceItem(item) && NSApp.sendAction(action, to: editor, from: item),
                "declaration-native-command-\(phase) key=\(window.isKeyWindow) textFocus=\(window.firstResponder === text) prepared=\(surface.canFindDeclaration) sheet=\(window.attachedSheet != nil)")
        }
        let initial = caret("    uniqueTarget()", inside: 7)
        text.setSelectedRange(initial)
        let key = String(UnicodeScalar(NSF12FunctionKey)!)
        try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key(key, code: 111, flags: [], window: window)) == true
            && text.selectedRange() == caret("func uniqueTarget", inside: 0), "declaration-F12-exact-single-target")
        try send(back, item: previous, phase: "single-back")
        try need(text.selectedRange() == initial && window.firstResponder === text, "declaration-native-back-to-original-caret")
        for (index, location) in [caret("// uniqueTarget()", inside: 6), caret("\"uniqueTarget()\"", inside: 4)].enumerated() {
            text.setSelectedRange(location)
            try send(find, item: command, phase: "excluded-token-\(index)")
            try need(text.selectedRange() == location && window.attachedSheet == nil
                && editor.navigationStatus.hasPrefix("No recognized declaration"), "declaration-ignores-comment-and-string")
        }
        let overloaded = caret("process(value: 10)", inside: 2)
        text.setSelectedRange(overloaded)
        func choices(_ phase: String) async throws -> NSWindow {
            try send(find, item: command, phase: phase)
            try await wait("declaration-native-choice-sheet-\(phase)") {
                window.attachedSheet?.title == "Choose Declaration" && window.attachedSheet?.isKeyWindow == true
            }
            guard let sheet = window.attachedSheet else { throw Failure(stage: "declaration-sheet-missing") }
            return sheet
        }
        let cancel = try await choices("cancel")
        cancel.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: cancel))
        try await wait("declaration-escape-restores-command-admission") { editor.validateUserInterfaceItem(command) }
        try need(text.selectedRange() == overloaded, "declaration-escape-preserves-selection")
        let select = try await choices("select")
        try need(!FolderCompositionOwnedControls.frame("Go to Declaration", in: select).isEmpty,
            "declaration-choice-confirms-with-native-control-geometry")
        guard let table = UIVerification.nativeTables(in: select.contentView).first else { throw Failure(stage: "declaration-native-result-list") }
        try await wait("declaration-both-rows-fit-in-the-sheet") {
            table.numberOfRows == 2 && table.visibleRect.contains(table.rect(ofRow: 1)) && table.visibleRect.width >= 360
        }
        try await UIVerification.snapshot(select, to: context.root.appendingPathComponent("evidence/editor-declaration-picker.png"))
        let initialRow = table.selectedRow, initialFocus = select.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        NSApp.sendEvent(UIVerification.key("\u{f701}", code: 125, flags: [], window: select))
        try await Task.sleep(for: .milliseconds(80))
        let destinationRow = table.selectedRow
        NSApp.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: select))
        do {
            try await wait("declaration-keyboard-chooses-second-overload") {
                window.attachedSheet == nil && text.selectedRange() == caret("func process(value: String)", inside: 0)
            }
        } catch {
            throw Failure(stage: "declaration-keyboard-chooses-second-overload attached=\(window.attachedSheet != nil) caret=\(text.selectedRange().location) focus=\(initialFocus) row=\(initialRow) after=\(destinationRow)")
        }
        try await wait("declaration-chooser-restores-text-focus") { window.isKeyWindow && window.firstResponder === text }
        try send(back, item: previous, phase: "choice-back")
        try need(text.selectedRange() == overloaded && text.string == code && surface.generation == generation
            && !document.isDirty && text.undoManager?.canUndo == canUndo,
            "declaration-choice-preserves-draft-and-undo")
        guard let completion = edit.item(withTitle: "Complete Name in This File"), let complete = completion.action else {
            throw Failure(stage: "local-name-completion-native-command")
        }
        let single = caret("    uniqueT\n", inside: 11)
        text.setSelectedRange(single)
        let f5 = String(UnicodeScalar(NSF5FunctionKey)!)
        try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key(f5, code: 96, flags: [], window: window)) == true,
            "local-name-completion-F5")
        let one = code.replacingOccurrences(of: "    uniqueT\n", with: "    uniqueTarget\n")
        try await wait("local-name-exact-only-completion") { text.string == one && document.isDirty && window.attachedSheet == nil }
        text.undoManager?.undo()
        try await wait("local-name-one-native-undo") { text.string == code && !document.isDirty && surface.canFindDeclaration }
        text.setSelectedRange(caret("    uniqueTarget()", inside: 7))
        try send(complete, item: completion, phase: "completed-word-untouched")
        try need(text.string == code && window.attachedSheet == nil && !document.isDirty, "local-name-refuses-interior-of-name")
        let partial = caret("    proc\n", inside: 8)
        text.setSelectedRange(partial)
        func completeChoices(_ phase: String) async throws -> NSWindow {
            try send(complete, item: completion, phase: phase)
            try await wait("local-name-native-choice-sheet-\(phase)") {
                window.attachedSheet?.title == "Complete Name" && window.attachedSheet?.isKeyWindow == true
            }
            guard let sheet = window.attachedSheet else { throw Failure(stage: "local-name-choice-sheet-missing") }
            return sheet
        }
        let cancelCompletion = try await completeChoices("cancel-name")
        NSApp.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: cancelCompletion))
        try await wait("local-name-cancel-restores-admission") { editor.validateUserInterfaceItem(completion) }
        try need(text.string == code && text.selectedRange() == partial && !document.isDirty, "local-name-Escape-preserves-prefix")
        let offered = try await completeChoices("select-name")
        guard let choices = UIVerification.nativeTables(in: offered.contentView).first else { throw Failure(stage: "local-name-native-table") }
        try need(choices.numberOfRows == 2 && choices.selectedRow == 0, "local-name-overloads-deduplicate-and-keep-distinct-names")
        NSApp.sendEvent(UIVerification.key("\u{f701}", code: 125, flags: [], window: offered))
        try await wait("local-name-next-candidate-without-edit") { choices.selectedRow == 1 }
        try need(text.string == code && !document.isDirty, "local-name-preview-does-not-change-document")
        NSApp.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: offered))
        let two = code.replacingOccurrences(of: "    proc\n", with: "    processText\n")
        try await wait("local-name-accepting-exact-second-choice") { window.attachedSheet == nil && text.string == two && document.isDirty }
        text.undoManager?.undo()
        try await wait("local-name-Undo-preserves-source") { text.string == code && !document.isDirty }
        try await verifyOpenSymbolSearch(from: document, window: window, context: context)
        document.requestClose()
        try await wait("declaration-generated-editor-closed") { editors.documentForVerification(at: file) == nil }
    }

    private static func verifyOpenSymbolSearch(from source: LocalTextDocumentController, window: NSWindow,
                                               context: Context) async throws {
        let editors = ApplicationLocalTextEditors.shared
        let file = context.files.directory.appendingPathComponent("Symbol Peer.swift")
        let original = "func originalPeer() {}\n"
        let draft = "func draftOnlySymbol() {}\n"
        let shifted = "// shifted declaration\n"
        let originalCaret = source.window.surface.textView.selectedRange()
        try await Task.detached { try Data(original.utf8).write(to: file, options: .withoutOverwriting) }.value
        context.browser.refresh(nil)
        try await wait("open-symbols-peer-listed") { context.browser.rowsByURL[file] != nil && context.browser.orderingTask == nil }
        context.select(file)
        context.browser.openSelection(nil)
        try await wait("open-symbols-peer-ready") {
            guard let peer = editors.documentForVerification(at: file) else { return false }
            return peer.window.window?.isKeyWindow == true && peer.window.surface.currentOutlineForSymbols != nil
        }
        guard let peer = editors.documentForVerification(at: file), let peerWindow = peer.window.window else {
            throw Failure(stage: "open-symbols-peer-window")
        }
        let peerText = peer.window.surface.textView
        peerText.insertText(draft, replacementRange: .init(location: original.utf16.count, length: 0))
        peerText.breakUndoCoalescing()
        try await wait("open-symbols-unsaved-outline") {
            peer.isDirty && peer.window.surface.currentOutlineForSymbols?.value.entries.contains { $0.title == "draftOnlySymbol" } == true
        }
        source.window.focusNavigationTarget()
        let sourceText = source.window.surface.textView
        try await wait("open-symbols-source-focus") {
            window.isKeyWindow && window.firstResponder === sourceText && source.window.surface.currentOutlineForSymbols != nil
        }
        let search = source.window.openSearch
        let here = UIVerification.key("o", code: 31, flags: [.command, .control], window: window)
        try need(NSApp.mainMenu?.performKeyEquivalent(with: here) == true, "document-symbols-shortcut")
        try await wait("document-symbols-native-focus") {
            search.window?.title == "Go to Symbol in This File" && search.window?.isKeyWindow == true
                && search.query.currentEditor() != nil
        }
        guard let currentPanel = search.window else { throw Failure(stage: "document-symbols-panel") }
        for letter in "dos" { currentPanel.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: currentPanel)) }
        try await wait("document-symbols-ignore-the-peer-draft") {
            search.query.stringValue == "dos" && !search.isWorking && search.matches.isEmpty
                && search.status.stringValue == "No matching symbols in this file."
        }
        search.query.selectText(nil)
        for letter in "ut" { currentPanel.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: currentPanel)) }
        try await wait("document-symbols-exact-current-file-result") {
            search.query.stringValue == "ut" && !search.isWorking && search.matches.count == 1
                && search.matches.first?.symbol?.entry.title == "uniqueTarget"
                && search.matches.first?.id == source.window.openSearchID
        }
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(currentPanel, to: context.root.appendingPathComponent("evidence/editor-document-symbol.png"))
        }
        let sourceTarget = (sourceText.string as NSString).range(of: "func uniqueTarget").location
        currentPanel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: currentPanel))
        try await wait("document-symbols-exact-caret") {
            search.window == nil && window.isKeyWindow && sourceText.selectedRange() == .init(location: sourceTarget, length: 0)
        }
        try visitTextLocation("Previous Text Location", from: source.window)
        try await wait("document-symbols-exact-origin") { sourceText.selectedRange() == originalCaret }
        let shortcut = UIVerification.key("o", code: 31, flags: [.command, .option], window: window)
        try need(NSApp.mainMenu?.performKeyEquivalent(with: shortcut) == true, "open-symbols-shortcut")
        try await wait("open-symbols-native-focus") { search.window?.isKeyWindow == true && search.query.currentEditor() != nil }
        guard let panel = search.window else { throw Failure(stage: "open-symbols-panel") }
        for letter in "dos" { panel.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: panel)) }
        try await wait("open-symbols-only-matching-declaration") {
            search.query.stringValue == "dos" && !search.isWorking && search.matches.count == 1
                && search.matches.first?.symbol?.entry.line == 2 && search.matches.first?.id == peer.window.openSearchID
        }
        peerText.insertText(shifted, replacementRange: .init(location: 0, length: 0))
        peerText.breakUndoCoalescing()
        panel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: panel))
        try need(search.window === panel && panel.isKeyWindow && !peerWindow.isKeyWindow, "open-symbols-stale-entry-did-not-jump")
        try await wait("open-symbols-shifted-outline") {
            peer.window.surface.currentOutlineForSymbols?.value.entries.contains { $0.title == "draftOnlySymbol" && $0.line == 3 } == true
        }
        search.updateMatches()
        try await wait("open-symbols-refreshed") { !search.isWorking && search.matches.first?.symbol?.entry.line == 3 }
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(panel, to: context.root.appendingPathComponent("evidence/editor-open-symbol.png"))
        }
        let expected = (peerText.string as NSString).range(of: "func draftOnlySymbol").location
        panel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: panel))
        try await wait("open-symbols-exact-peer-caret") {
            search.window == nil && peerWindow.isKeyWindow && peerText.selectedRange() == .init(location: expected, length: 0)
        }
        try visitTextLocation("Previous Text Location", from: peer.window)
        try await wait("open-symbols-exact-origin") { window.isKeyWindow && source.window.surface.textView.selectedRange() == originalCaret }
        try need(peerText.string == shifted + original + draft && peer.isDirty && !source.isDirty, "open-symbols-keeps-both-documents")
        peer.window.focusNavigationTarget()
        try await wait("open-symbols-peer-undo-focus") { peerWindow.isKeyWindow }
        peerText.undoManager?.undo(); peerText.undoManager?.undo()
        try await wait("open-symbols-native-undo") { peerText.string == original && !peer.isDirty }
        peer.requestClose()
        try await wait("open-symbols-peer-closed") { editors.documentForVerification(at: file) == nil }
    }

    private static func verifyNativeDeclarationOutlines(_ context: Context) async throws {
        let owner = ApplicationLocalTextEditors.shared
        let directory = context.files.directory
        let cExamples = [
            "c": "struct Orion { int altitude; };\nstatic int chart(int value)\n{\n    return value;\n}\n",
            "cpp": "class Orion final : public Base {\n    static int chart(int value) noexcept { return value; }\n};\n",
            "m": "@interface Orion : NSObject\n@end\nint chart(void) { return 1; }\n",
            "mm": "@interface Orion : NSObject\n@end\nint chart(void) { return 1; }\n"
        ]
        let cFiles = try await Task.detached {
            Dictionary(uniqueKeysWithValues: try cExamples.map { fileExtension, source in
                let url = directory.appendingPathComponent("Outline." + fileExtension)
                try Data(source.utf8).write(to: url, options: .withoutOverwriting)
                return (fileExtension, url)
            })
        }.value
        context.browser.refresh(nil)
        try await wait("outline-c-family-fixtures-listed") {
            !context.browser.isLoading && context.browser.orderingTask == nil
                && cFiles.values.allSatisfy { context.browser.rowsByURL[$0] != nil }
        }
        for (fileExtension, token) in [("md", "## Chart"), ("yaml", "chart:"), ("swift", "func chart"), ("py", "def chart"),
                                       ("rs", "fn chart"), ("js", "const chart"), ("ts", "const chart"),
                                       ("c", "chart("), ("cpp", "chart("), ("m", "chart("), ("mm", "chart(")] {
            guard let url = cFiles[fileExtension] ?? context.files.nativeFiles.first(where: { $0.pathExtension == fileExtension }) else {
                throw Failure(stage: "outline-\(fileExtension)-fixture")
            }
            context.select(url)
            context.browser.openSelection(nil)
            try await wait("outline-\(fileExtension)-native-open") {
                guard let editor = owner.documentForVerification(at: url) else { return false }
                return !editor.hasPendingFileWork && editor.window.window?.isKeyWindow == true
            }
            guard let document = owner.documentForVerification(at: url), let window = document.window.window,
                  let sidebar = document.window.fileSidebar?.files,
                  let command = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Document Outline"),
                  let action = command.action else { throw Failure(stage: "outline-\(fileExtension)-command") }
            let text = document.window.surface.textView
            let start = (text.string as NSString).range(of: token).location
            try need(start != NSNotFound && document.window.validateUserInterfaceItem(command)
                && NSApp.sendAction(action, to: document.window, from: command), "outline-\(fileExtension)-native-menu")
            try await wait("outline-\(fileExtension)-native-rows") {
                sidebar.outline.numberOfRows == 2 && sidebar.outlineSearch.currentEditor() != nil
            }
            for letter in "chart" { window.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: window)) }
            try await wait("outline-\(fileExtension)-search") { sidebar.outline.numberOfRows == 1 && sidebar.outline.selectedRow == 0 }
            window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
            try need(window.firstResponder === text && text.selectedRange().location == start && !document.isDirty,
                "outline-\(fileExtension)-native-token-position")
            if fileExtension == "yaml" {
                let search = document.window.openSearch
                let shortcut = UIVerification.key("o", code: 31, flags: [.command, .option], window: window)
                try need(NSApp.mainMenu?.performKeyEquivalent(with: shortcut) == true, "yaml-symbol-shortcut")
                try await wait("yaml-symbol-panel") { search.window?.isKeyWindow == true && search.query.currentEditor() != nil }
                guard let panel = search.window else { throw Failure(stage: "yaml-symbol-missing-panel") }
                for letter in "chart" { panel.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: panel)) }
                try await wait("yaml-symbol-captured-key") {
                    !search.isWorking && search.matches.count == 1 && search.matches.first?.symbol?.entry.kind == .property
                }
                try await UIVerification.snapshot(panel, to: context.root.appendingPathComponent("evidence/editor-yaml-symbols.png"))
                panel.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: panel))
                try await wait("yaml-symbol-exact-jump") {
                    search.window == nil && window.isKeyWindow && text.selectedRange().location == start && !document.isDirty
                }
            }
            document.requestClose()
            try await wait("outline-\(fileExtension)-close") { owner.documentForVerification(at: url) == nil }
        }
    }

    private static func verifyIndentGuides(_ context: Context) async throws {
        let editors = ApplicationLocalTextEditors.shared
        let file = context.files.directory.appendingPathComponent("Indent Guides.swift")
        let body = String(repeating: "generated visible text ", count: 22)
        let original = "func renderLayout() {\n    if ready {\n\t\tlet detail = \"[literal] \(body)\"\n    } // [comment]\n}\n"
        try await Task.detached { try Data(original.utf8).write(to: file, options: .withoutOverwriting) }.value
        let settings = context.settings
        let prior = settings.editorPreferences
        defer { settings.updateEditorPreferences(prior) }
        var preferences = prior
        preferences.wrapsLines = true
        preferences.indentation.columns = 4
        preferences.showsIndentGuides = true
        preferences.showsMatchingBrackets = true
        preferences.theme = .dark
        settings.updateEditorPreferences(preferences)
        context.browser.refresh(nil)
        try await wait("indent-guides-listed") { context.browser.rowsByURL[file] != nil && context.browser.orderingTask == nil }
        context.select(file)
        context.browser.openSelection(nil)
        try await wait("indent-guides-native-editor") {
            guard let document = editors.documentForVerification(at: file) else { return false }
            return document.window.window?.isKeyWindow == true && document.window.surface.canFindDeclaration
        }
        guard let document = editors.documentForVerification(at: file), let window = document.window.window else {
            throw Failure(stage: "indent-guides-owned-window")
        }
        let surface = document.window.surface, text = surface.textView
        let generation = surface.generation, caret = text.selectedRange(), undo = text.undoManager?.canUndo
        func marks() -> [NSRect] {
            window.contentView?.layoutSubtreeIfNeeded()
            return EditorIndentGuides.rectangles(in: text, dirtyRect: text.visibleRect)
        }
        try await wait("indent-guides-four-column-layout") { marks().count == 4 }
        let four = marks()
        let rows = Dictionary(grouping: four, by: \.minY).sorted { $0.key < $1.key }
        try need(rows.map { $0.value.count } == [1, 2, 1]
            && rows[0].value[0].minX == rows[1].value[0].minX
            && rows[0].value[0].minX == rows[2].value[0].minX
            && four.allSatisfy { text.visibleRect.contains($0) }, "indent-guides-mixed-tab-space-geometry")
        try await UIVerification.snapshot(window, to: context.root.appendingPathComponent("evidence/editor-indent-guides-dark.png"))
        preferences.theme = .light
        preferences.indentation.columns = 2
        settings.updateEditorPreferences(preferences)
        try await wait("indent-guides-two-column-layout") { marks().count == 6 }
        try await UIVerification.snapshot(window, to: context.root.appendingPathComponent("evidence/editor-indent-guides-light.png"))
        let anchor = surface.scrollAnchor()
        preferences.showsIndentGuides = false
        preferences.showsWhitespaceMarks = true
        settings.updateEditorPreferences(preferences)
        try await wait("indent-guides-hide-live-and-marks-show") {
            !text.showsIndentGuides && marks().isEmpty && text.showsWhitespaceMarks
        }
        let whitespace = EditorWhitespaceMarks.visible(in: text, dirtyRect: text.visibleRect)
        try need(whitespace.filter { $0.kind == .tab }.count == 2
            && whitespace.filter { $0.kind == .lineBreak }.count == 5
            && whitespace.contains { $0.kind == .space }, "whitespace-marks-show-tabs-spaces-and-hard-breaks")
        try await UIVerification.snapshot(window, to: context.root.appendingPathComponent("evidence/editor-whitespace-marks.png"))
        guard let command = UIVerification.menuItem("View", NativeTextEditorSurface.whitespaceMarksTitle),
              let action = command.action else { throw Failure(stage: "editor-whitespace-marks-menu") }
        try need(document.window.validateUserInterfaceItem(command) && command.state == .on
            && NSApp.sendAction(action, to: document.window, from: command), "editor-whitespace-marks-native-action")
        try need(document.window.validateUserInterfaceItem(command) && command.state == .off
            && settings.editorPreferences.showsWhitespaceMarks && !text.showsWhitespaceMarks
            && EditorWhitespaceMarks.visible(in: text, dirtyRect: text.visibleRect).isEmpty,
            "editor-menu-whitespace-mark-override-is-local")
        try need(text.string == original && text.selectedRange() == caret && surface.generation == generation
            && text.undoManager?.canUndo == undo && surface.scrollAnchor() == anchor && !document.isDirty,
            "indent-guides-live-settings-altered-native-text")
        let source = original as NSString
        let opening = NSMaxRange(source.range(of: "if ready {")) - 1
        let closing = source.range(of: "} //").location
        let pair = Set([NSRange(location: opening, length: 1), NSRange(location: closing, length: 1)])
        window.makeFirstResponder(text)
        text.setSelectedRange(.init(location: opening, length: 0))
        try need(Set(text.bracketHighlights) == pair, "matching-brackets-exact-nested-pair")
        try await UIVerification.snapshot(window, to: context.root.appendingPathComponent("evidence/editor-bracket-highlights-light.png"))
        for ignored in ["[literal]", "[comment]"] {
            text.setSelectedRange(.init(location: source.range(of: ignored).location, length: 0))
            try need(text.bracketHighlights.isEmpty, "matching-brackets-ignore-literals-and-comments")
        }
        text.setSelectedRange(.init(location: closing + 1, length: 0))
        try need(Set(text.bracketHighlights) == pair, "matching-brackets-allow-adjacent-caret")
        preferences.showsMatchingBrackets = false
        settings.updateEditorPreferences(preferences)
        try need(text.bracketHighlights.isEmpty, "matching-brackets-live-opt-out")
        preferences.showsMatchingBrackets = true
        preferences.theme = .dark
        settings.updateEditorPreferences(preferences)
        try need(Set(text.bracketHighlights) == pair && text.string == original && !document.isDirty
            && text.undoManager?.canUndo == undo, "matching-brackets-live-setting-preserves-draft")
        try await UIVerification.snapshot(window, to: context.root.appendingPathComponent("evidence/editor-bracket-highlights-dark.png"))
        text.insertText("", replacementRange: .init(location: closing, length: 1))
        try need(text.bracketHighlights.isEmpty, "matching-brackets-drop-stale-generation-before-preparation")
        text.undoManager?.undo()
        try await wait("matching-brackets-prepare-current-Undo-generation") {
            !document.isDirty && surface.presentedGeneration == surface.generation && text.string == original
        }
        text.setSelectedRange(.init(location: opening, length: 0))
        try need(Set(text.bracketHighlights) == pair, "matching-brackets-restored-with-exact-Undo")
        document.requestClose()
        try await wait("indent-guides-editor-closed") { editors.documentForVerification(at: file) == nil }
    }

    static func run() async {
        var root: URL?, context: Context?, checks: [String] = [], failure: String?
        let coldTAR = ProcessInfo.processInfo.arguments.contains("--tar-editor-cold-undo")
        let comparisonOnly = ProcessInfo.processInfo.arguments.contains("--editor-comparison-only")
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "scope") }
            let area = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String: Any]
            try need(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: area.lastPathComponent)?.uuidString == area.lastPathComponent
                && marker?["action"] as? String == "native-editor-preferences" && Bundle.main.bundleIdentifier == "local.macexplorer.development", "exact-generated-editor-preferences-scope")
            let archiveOnly = ProcessInfo.processInfo.arguments.contains("--archive-editor-only")
            try need(!comparisonOnly || !archiveOnly && !coldTAR && marker?["editorComparisonOnly"] as? Bool == true,
                "exact-focused-comparison-scope")
            let fullEditor = !archiveOnly && !comparisonOnly
            root = area
            if coldTAR {
                try need(archiveOnly && ProcessInfo.processInfo.arguments.contains("--tar-editor"), "cold-tar-check-profile")
                checks += try await ArchiveTextEditorVerification.coldTAR(root: area)
            } else {
            if fullEditor { checks += try EditorSettingsAppChecks.check() }
            let files = try await fixture(area), c = Context(root: area, files: files); context = c
            if comparisonOnly { NSApp.mainMenu = BrowserMenus.applicationMenu(target: c.browser) }
            c.owner.showWindow(nil); c.owner.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if ProcessInfo.processInfo.arguments.contains("--offscreen") { c.owner.window?.setFrameOrigin(.init(x: -12000, y: -12000)) }
            c.browser.navigate(to: .directory(files.directory))
            try await wait("generated-preferences-listing") { !c.browser.isLoading && c.browser.orderingTask == nil && c.browser.displayedEntries.count == EditorOpeningSupport.fileTypes.count + 3 }
            if fullEditor {
                try buildSyntaxChecks()
                try await outlineSyntaxChecks()
                checks += ["Dockerfile/Makefile lexical roles preserve UTF-16 ranges, heredoc content and cancellation"]
                try cFamilySyntaxChecks()
                checks += ["C/C++/Objective-C source and headers use bounded lexical roles for directives, comments, ordinary/raw strings, numbers, types and functions; incomplete text and unknown optional language preferences remain readable"]
                try await overviewStartupChecks(c, root: area)
                checks += ["Populated seven-tab workspace restoration keeps the disconnected-server card bounded without shrinking the pane; switching to This Mac fills its width and preserves Glass"]
                checks += try await initialLayoutChecks(c)
                checks += try await nativeDefaultChecks(c)
                checks += try await extensionlessChecks(c)
            }
            if !archiveOnly { checks += try await comparisonChecks(c) }
            if fullEditor {
                if !ProcessInfo.processInfo.arguments.contains("--offscreen") { checks += try await sidebarChecks(c) }
                checks += try await openEditorSearchChecks(c)
                checks += try await documentChecks(c)
                checks += try await openingChecks(c)
            }
            if !comparisonOnly {
                checks += try await ArchiveTextEditorVerification.check(root: area, browser: c.browser,
                    sources: [files.first, files.second], zipRecoveryCheckpoint: c.zipRecoveryCheckpoint)
            }
            if fullEditor { checks += try await staleChecks(c) }
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
                "focusedComparison": comparisonOnly,
                "interfacePercent": context?.settings.interfaceSize.percent ?? 0,
                "nativeWindowsClosed": NSApp.windows.filter { $0.isVisible }.isEmpty]
            let report = coldTAR ? "native-editor-preferences-cold.json" : "native-editor-preferences.json"
            try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/" + report), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
}
#endif
