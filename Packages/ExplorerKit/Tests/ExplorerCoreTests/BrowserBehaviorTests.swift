import ExplorerCore
import Foundation
import Testing

@Test func browserBehaviorPresetsPreserveExistingKeys() {
    let explorer = BrowserBehaviorPreferences.explorer
    let mac = BrowserBehaviorPreferences.mac
    #expect(explorer.action(for: .returnKey) == .open)
    #expect(explorer.action(for: .backspace) == .back)
    #expect(explorer.action(for: .function2) == .rename)
    #expect(explorer.action(for: .forwardDelete) == .trash)
    #expect(mac.action(for: .returnKey) == .rename)
    #expect(mac.action(for: .backspace) == nil)
    #expect(mac.action(for: .function2) == nil)
    #expect(mac.action(for: .forwardDelete) == nil)
    for policy in [explorer, mac] {
        #expect(policy.action(for: .space) == .quickLook)
        #expect(policy.action(for: .backspace, modifiers: .command) == .trash)
        #expect(policy.action(for: .returnKey, modifiers: .option) == nil)
    }
}

@Test func customBehaviorChoicesAreIndependentAndRetainedByPreset() throws {
    let custom = BrowserBehaviorPreferences(returnAction: .rename, backspaceGoesBack: true,
                                             controlAliasesEnabled: false, explorerFunctionKeysEnabled: true)
    #expect(BrowserBehaviorPreferences.effective(preset: .custom, custom: custom) == custom)
    #expect(BrowserBehaviorPreferences.effective(preset: .explorer, custom: custom) == .explorer)
    #expect(BrowserBehaviorPreferences.effective(preset: .mac, custom: custom) == .mac)
    let restored = try JSONDecoder().decode(BrowserBehaviorPreferences.self, from: JSONEncoder().encode(custom))
    #expect(restored == custom)
    #expect(restored.action(for: .returnKey) == .rename)
    #expect(restored.action(for: .backspace) == .back)
    #expect(!restored.controlAliasesEnabled)
}

@Test func fileBrowserBehaviorNeverTakesNativeTextKeys() {
    for policy in [BrowserBehaviorPreferences.explorer, .mac] {
        for key: BrowserBehaviorPreferences.FileKey in [.returnKey, .backspace, .function2, .forwardDelete, .space] {
            for modifiers: BrowserBehaviorPreferences.Modifiers in [[], .command, .control, .option, .shift] {
                #expect(policy.action(for: key, modifiers: modifiers, isEditingText: true) == nil)
            }
        }
    }
}

@Test func browserBehaviorRejectsUnknownChoicesInsteadOfInventingCommands() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(BrowserKeyboardPreset.self, from: Data("\"Global remap\"".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(BrowserBehaviorPreferences.self, from: Data("{\"returnAction\":\"Execute\"}".utf8))
    }
}
