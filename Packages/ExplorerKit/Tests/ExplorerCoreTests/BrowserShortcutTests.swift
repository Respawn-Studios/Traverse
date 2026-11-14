import Foundation
import Testing
@testable import ExplorerCore

struct BrowserShortcutTests {
    @Test func presetsAndFileSurfaceContextAreUnambiguous() {
        let explorer = BrowserShortcutMap(behavior: .explorer)
        let mac = BrowserShortcutMap(behavior: .mac)
        #expect(explorer.issues.isEmpty && mac.issues.isEmpty)
        #expect(explorer.resolve(.init(.special(.returnKey)), fileSurface: true) == .open)
        #expect(mac.resolve(.init(.special(.returnKey)), fileSurface: true) == .rename)
        #expect(mac.resolve(.init(.special(.returnKey)), fileSurface: false) == nil)
        #expect(explorer.resolve(.init(.special(.f2)), fileSurface: false) == nil)
        #expect(explorer.resolve(.init(.character("c"), .control), fileSurface: true) == .copy)
        #expect(mac.resolve(.init(.character("c"), .control), fileSurface: true) == nil)
        #expect(mac.resolve(.init(.character("d"), .command), fileSurface: true) == .duplicate)
        #expect(explorer.resolve(.init(.character("d"), .command), fileSurface: true) == .duplicate)
    }

    @Test func overrideDisablesOldAliasesAndResolvesAfterModifierSwap() throws {
        let custom = BrowserShortcutPreferences(swapsCommandAndOption: true,
            overrides: [.copy: [.init(.character("b"), [.command, .shift])], .rename: []])
        let map = BrowserShortcutMap(behavior: .explorer, preferences: custom)
        #expect(map.issues.isEmpty)
        #expect(map.resolve(.init(.character("b"), [.command, .shift]), fileSurface: true) == .copy)
        #expect(map.resolve(.init(.character("c"), .option), fileSurface: true) == nil)
        #expect(map.resolve(.init(.character("c"), .control), fileSurface: true) == nil)
        #expect(map.resolve(.init(.special(.f2)), fileSurface: true) == nil)
        #expect(map.resolve(.init(.character("t"), .option), fileSurface: false) == .newTab)
        #expect(try JSONDecoder().decode(BrowserShortcutPreferences.self, from: JSONEncoder().encode(custom)) == custom)
    }

    @Test func duplicatesReservedAndMalformedCannotResolveAnyCommand() {
        let chord = BrowserShortcut(.character("c"), .command)
        let duplicate = BrowserShortcutMap(behavior: .explorer, preferences: .init(overrides: [.trash: [chord]]))
        #expect(duplicate.issues.contains { if case .duplicate(.copy, .trash, chord) = $0 { true } else { false } })
        #expect(duplicate.resolve(chord, fileSurface: true) == nil)
        for value in [BrowserShortcut(.character("q"), .command), .init(.special(.space), .command),
                      .init(.character("long"), .command), .init(.character("c")),
                      .init(.character("a"), .init(rawValue: 99)), .init(.special(.tab))] {
            let map = BrowserShortcutMap(behavior: .mac, preferences: .init(overrides: [.copy: [value]]))
            #expect(!map.issues.isEmpty)
        }
    }

    @Test func explicitSearchScopesShareRegistryValidationAndCustomization() throws {
        for behavior in [BrowserBehaviorPreferences.mac, .explorer] {
            let map = BrowserShortcutMap(behavior: behavior)
            #expect(map.issues.isEmpty)
            #expect(map.resolve(.init(.character("f"), [.command, .option]), fileSurface: false) == .directFilter)
            #expect(map.resolve(.init(.character("f"), [.command, .option, .shift]), fileSurface: true) == .searchFolder)
            #expect(map.resolve(.init(.character("f"), [.command, .control, .shift]), fileSurface: true) == .searchThisMac)
            for action in [BrowserCommand.directFilter, .searchFolder, .searchThisMac] { #expect(!action.allowsRepeat) }
        }
        let saved = BrowserShortcutPreferences(overrides: [.searchFolder: [.init(.special(.f8), .control)], .directFilter: []])
        let restored = try JSONDecoder().decode(BrowserShortcutPreferences.self, from: JSONEncoder().encode(saved))
        let map = BrowserShortcutMap(behavior: .mac, preferences: restored)
        #expect(map.issues.isEmpty)
        #expect(map.resolve(.init(.special(.f8), .control), fileSurface: true) == .searchFolder)
        #expect(map.resolve(.init(.character("f"), [.command, .option]), fileSurface: true) == nil)
        let reserved = BrowserShortcutMap(behavior: .mac, preferences: .init(overrides: [.searchThisMac: [.init(.special(.space), .command)]]))
        #expect(reserved.issues.contains(.reserved(.searchThisMac)))
    }

    @Test func connectPresetPreservesExistingCustomKeys() throws {
        let chord = BrowserShortcut(.character("k"), .command)
        let initial = BrowserShortcutMap(behavior: .mac)
        #expect(initial.resolve(chord, fileSurface: false) == .connectServer)
        let older = BrowserShortcutPreferences(overrides: [.storageAnalysis: [chord]])
        let migrated = BrowserShortcutMap(behavior: .mac, preferences: older)
        #expect(migrated.issues.isEmpty && migrated.resolve(chord, fileSurface: false) == .storageAnalysis)
        #expect(migrated.shortcuts(for: .connectServer).isEmpty)
        let explicitConflict = BrowserShortcutMap(behavior: .mac,
            preferences: .init(overrides: [.storageAnalysis: [chord], .connectServer: [chord]]))
        #expect(!explicitConflict.issues.isEmpty)
        let key = BrowserShortcut(.special(.f8), [.control, .option])
        let choices = BrowserShortcutPreferences(overrides: [.connectServer: [], .disconnectServer: [key]])
        let restored = try JSONDecoder().decode(BrowserShortcutPreferences.self, from: JSONEncoder().encode(choices))
        let customized = BrowserShortcutMap(behavior: .explorer, preferences: restored)
        #expect(customized.issues.isEmpty && customized.resolve(key, fileSurface: true) == .disconnectServer)
        #expect(customized.resolve(chord, fileSurface: true) == nil)
    }

    @Test func quickProfilePresetPreservesOlderCustomKeys() throws {
        let chord = BrowserShortcut(.character("p"), [.command, .control])
        #expect(BrowserShortcutMap(behavior: .mac).resolve(chord, fileSurface: false) == .switchLaunchProfile)
        let older = BrowserShortcutPreferences(overrides: [.storageAnalysis: [chord]])
        let updated = BrowserShortcutMap(behavior: .mac, preferences: older)
        #expect(updated.issues.isEmpty && updated.resolve(chord, fileSurface: false) == .storageAnalysis)
        #expect(updated.shortcuts(for: .switchLaunchProfile).isEmpty)
        #expect(!BrowserCommand.switchLaunchProfile.allowsRepeat)
        let explicit = BrowserShortcutMap(behavior: .mac,
            preferences: .init(overrides: [.storageAnalysis: [chord], .switchLaunchProfile: [chord]]))
        #expect(!explicit.issues.isEmpty)
        let saved = BrowserShortcutPreferences(overrides: [.switchLaunchProfile: []])
        let restored = try JSONDecoder().decode(BrowserShortcutPreferences.self, from: JSONEncoder().encode(saved))
        #expect(BrowserShortcutMap(behavior: .explorer, preferences: restored).resolve(chord, fileSurface: false) == nil)
    }

    @Test func mutationsAndTogglesDoNotRepeat() {
        for action in [BrowserCommand.rename, .trash, .paste, .duplicate, .newFolder, .previewPane, .newTab, .open] { #expect(!action.allowsRepeat) }
        #expect(BrowserCommand.nextTab.allowsRepeat && BrowserCommand.nextFocus.allowsRepeat)
        #expect(!BrowserShortcut(.character("é"), .command).isReserved)
        #expect(BrowserShortcut(.character("é"), .command).isWellFormed)
    }

    @Test func commandFinderPresetPreservesPreviewAndOlderExplicitKeys() throws {
        let chord = BrowserShortcut(.character("k"), [.command, .shift])
        for behavior in [BrowserBehaviorPreferences.mac, .explorer] {
            let preset = BrowserShortcutMap(behavior: behavior)
            #expect(preset.issues.isEmpty && preset.resolve(chord, fileSurface: false) == .findCommand)
            #expect(preset.resolve(.init(.character("p"), [.command, .shift]), fileSurface: false) == .previewPane)
            let old = BrowserShortcutMap(behavior: behavior, preferences: .init(overrides: [.storageAnalysis: [chord]]))
            #expect(old.issues.isEmpty && old.resolve(chord, fileSurface: false) == .storageAnalysis)
            #expect(old.shortcuts(for: .findCommand).isEmpty)
        }
        let explicit = BrowserShortcutMap(behavior: .mac,
            preferences: .init(overrides: [.storageAnalysis: [chord], .findCommand: [chord]]))
        #expect(!explicit.issues.isEmpty)
        let choice = BrowserShortcutPreferences(overrides: [.findCommand: []])
        #expect(try JSONDecoder().decode(BrowserShortcutPreferences.self, from: JSONEncoder().encode(choice)) == choice)
        #expect(!BrowserCommand.findCommand.allowsRepeat)
    }

    @Test func nativeToolCommandsHaveExplicitCustomizableBindings() throws {
        for action in [BrowserCommand.launchProfiles, .browseArchive, .extractArchive, .createZIP, .batchRename, .namesAndLabels, .rememberedItems, .storageAnalysis,
                       .saveFolderView, .applyFolderView, .forgetFolderView, .folderViews, .copyToPane, .moveToPane, .moveOnServer, .copyNames, .copyRelativePaths] {
            let baseline = BrowserShortcutMap(behavior: .mac)
            #expect(baseline.shortcuts(for: action).isEmpty && !action.allowsRepeat)
            let key = BrowserShortcut(.special(.f8), [.control, .option])
            let saved = BrowserShortcutPreferences(overrides: [action: [key]])
            let restored = try JSONDecoder().decode(BrowserShortcutPreferences.self, from: JSONEncoder().encode(saved))
            let map = BrowserShortcutMap(behavior: .mac, preferences: restored)
            #expect(map.issues.isEmpty && map.resolve(key, fileSurface: true) == action)
        }
    }
}
