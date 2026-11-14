import Foundation
import Testing
@testable import ExplorerCore

@Suite struct FilenameClipboardTextTests {
    private func rawURL(_ path: String) -> URL {
        let allowed = CharacterSet(charactersIn: "/ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return URL(string: "file://" + path.addingPercentEncoding(withAllowedCharacters: allowed)!)!
    }
    @Test func filenamesKeepExtensionsUnicodeQuotesAndSelectionOrder() throws {
        let names = ["Space file.md", "Café – 日本語 👩‍💻.txt", "quote'and\"name.json", "literal%00.txt"]
        let urls = names.map { rawURL("/generated/" + $0) }
        let output = try FilenameClipboardText.make(urls, kind: .names)
        #expect(Data(output.utf8) == Data(names.joined(separator: "\n").utf8))
    }
    @Test func relativePathsKeepHierarchyAndRequireExactComponentBoundaries() throws {
        let base = URL(fileURLWithPath: "/generated/Project")
        let values = [base.appendingPathComponent("Docs/Readme.txt"), base.appendingPathComponent("Source.swift"), base]
        #expect(try FilenameClipboardText.make(values, kind: .relativePaths, relativeTo: base) == "Docs/Readme.txt\nSource.swift\n.")
        for other in ["/generated/Project-other/file", "/generated/project/file", "/generated/Elsewhere/file"] {
            #expect(throws: FilenameClipboardText.Failure.outsideFolder) {
                try FilenameClipboardText.make([URL(fileURLWithPath: other)], kind: .relativePaths, relativeTo: base)
            }
        }
    }
    @Test func rootBaseAndLexicallyStandardizedPathsDoNotAccessTheFilesystem() throws {
        #expect(try FilenameClipboardText.make([URL(fileURLWithPath: "/generated/file")], kind: .relativePaths,
            relativeTo: URL(fileURLWithPath: "/")) == "generated/file")
        #expect(try FilenameClipboardText.make([URL(fileURLWithPath: "/generated/child/../file")], kind: .relativePaths,
            relativeTo: URL(fileURLWithPath: "/generated")) == "file")
        #expect(throws: FilenameClipboardText.Failure.unsupported) { try FilenameClipboardText.make([URL(fileURLWithPath: "/generated/file")], kind: .relativePaths) }
    }
    @Test func malformedDecoratedRemoteAndEncodedSlashInputsRefuseCompletely() throws {
        for text in ["https://example.invalid/file", "sftp://example.invalid/file", "file://server.invalid/share/file",
            "file://user@localhost/generated/file", "file:///generated/file?q=1", "file:///generated/file#fragment",
            "file:///generated/child%2Foutside"] {
            #expect(throws: FilenameClipboardText.Failure.unsupported) {
                try FilenameClipboardText.make([URL(string: text)!], kind: .names)
            }
        }
    }
    @Test func controlCharactersAndEncodedNULAreRefusedBeforePathProjection() throws {
        for text in ["file:///generated/bad%00name", "file:///generated/bad%0Aname", "file:///generated/bad%0Dname",
            "file:///generated/bad%09name", "file:///generated/bad%7Fname", "file:///generated/bad%C2%85name"] {
            #expect(throws: FilenameClipboardText.Failure.unsafeLine) {
                try FilenameClipboardText.make([URL(string: text)!], kind: .names)
            }
        }
    }
    @Test func mixedInvalidSelectionIsNeverOmittedOrTruncated() throws {
        let base = URL(fileURLWithPath: "/generated/Project")
        #expect(throws: FilenameClipboardText.Failure.outsideFolder) {
            try FilenameClipboardText.make([base.appendingPathComponent("Good.txt"), URL(fileURLWithPath: "/outside/Bad.txt")],
                kind: .relativePaths, relativeTo: base)
        }
        #expect(throws: FilenameClipboardText.Failure.empty) { try FilenameClipboardText.make([], kind: .names) }
        #expect(throws: FilenameClipboardText.Failure.tooMany) {
            try FilenameClipboardText.make(Array(repeating: base, count: 4097), kind: .names)
        }
    }
    @Test func exactAggregateBoundAndOverLimitSelectionsAreFinite() throws {
        let good = (0..<4096).map { index in URL(fileURLWithPath: "/generated/" + String(format: "%04d", index) + String(repeating: "x", count: 251)) }
        #expect(try FilenameClipboardText.make(good, kind: .names).utf8.count == 1_048_575)
        let larger = good.map { $0.appendingPathExtension("x") }
        #expect(throws: FilenameClipboardText.Failure.tooLarge) { try FilenameClipboardText.make(larger, kind: .names) }
        #expect(throws: FilenameClipboardText.Failure.tooLarge) {
            try FilenameClipboardText.make([URL(fileURLWithPath: "/generated/" + String(repeating: "x", count: 17_000))], kind: .names)
        }
    }
    @Test func byteSpellingIsNotSilentlyCaseOrUnicodeFolded() throws {
        let composed = rawURL("/generated/Café")
        let decomposed = rawURL("/generated/Cafe\u{301}/file")
        #expect(throws: FilenameClipboardText.Failure.outsideFolder) {
            try FilenameClipboardText.make([decomposed], kind: .relativePaths, relativeTo: composed)
        }
    }
    @Test func commandLookupAndExistingKeysRemainAvailableWithoutNewDefaults() throws {
        let entries = BrowserCommand.allCases.map { BrowserCommandSearch.Entry(command: $0) }
        #expect(try BrowserCommandSearch.matches("copy filenames", entries: entries).first?.command == .copyNames)
        #expect(try BrowserCommandSearch.matches("relative path", entries: entries).first?.command == .copyRelativePaths)
        for behavior in [BrowserBehaviorPreferences.mac, .explorer] {
            let map = BrowserShortcutMap(behavior: behavior)
            #expect(map.issues.isEmpty && map.shortcuts(for: .copyNames).isEmpty && map.shortcuts(for: .copyRelativePaths).isEmpty)
            #expect(map.resolve(.init(.character("c"), [.command, .option]), fileSurface: true) == .copyPath)
        }
    }
}
