import AppKit
import ExplorerCore
import SwiftUI

struct BrowserShortcutEditor: View {
    @ObservedObject var settings: BrowserSettings
    @ObservedObject private var system = SystemShortcutSnapshot.shared
    @State private var query = ""
    @State private var error = ""
    @State private var recording: BrowserCommand?
    @State private var systemOverrides = Set<BrowserCommand>()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Swap Command and Option for browser commands", isOn: Binding(
                get: { settings.effectiveShortcutPreferences.swapsCommandAndOption },
                set: { value in
                    prepareCustom()
                    var changed = settings.shortcutPreferences; changed.swapsCommandAndOption = value
                    apply(changed)
                }))
            Text("Applies inside the file browser. Text editing, macOS commands and drag modifiers keep their native behavior. Per-action bindings are applied after swapping.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            LabeledContent("Find an action or shortcut") {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").interfaceFont(.caption).foregroundStyle(.secondary)
                    ShortcutQueryField(text: $query).frame(minHeight: 18)
                }.padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12)))
                    .transaction { $0.disablesAnimations = true }
            }
            if !error.isEmpty { Text(error).interfaceFont(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleActions) { action in row(action) }
                }.padding(.vertical, 4)
            }.frame(height: 260)
            Button("Reset Shortcut Bindings to These Behavior Choices") {
                prepareCustom(); settings.shortcutPreferences = .init(); error = ""; recording = nil
            }
            Text(system.status).interfaceFont(.caption).foregroundStyle(.secondary)
            Text("Record one key combination. Escape cancels recording. Unmodified letters are kept for filename navigation; Return, Space and Delete apply to the file surface. macOS App Shortcuts take priority.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }
        .onAppear { refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshSystemState() }
    }
    private var visibleActions: [BrowserCommand] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrowserCommand.allCases.filter { action in
            action.isPresentedInBuild && (needle.isEmpty || action.title.localizedCaseInsensitiveContains(needle)
                || settings.shortcutMap.shortcuts(for: action).contains { $0.display.localizedCaseInsensitiveContains(needle) })
        }
    }
    private func row(_ action: BrowserCommand) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title).interfaceFont(.callout)
                Text(systemOverrides.contains(action) ? "Managed by macOS App Shortcuts" : keyDescription(action))
                    .interfaceFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(action.title)
            .accessibilityValue(systemOverrides.contains(action) ? "Managed by macOS App Shortcuts" : keyDescription(action))
            .frame(maxWidth: .infinity, alignment: .leading)
            ShortcutRecorder(isRecording: recording == action, begin: { prepareCustom(); error = ""; recording = action },
                cancel: { if recording == action { recording = nil } }, captured: { shortcut, event in
                    guard !system.conflicts(event) else { error = "This combination is reserved by macOS. Choose another shortcut."; return }
                    var changed = settings.shortcutPreferences; changed.overrides[action] = [shortcut]
                    if apply(changed) { recording = nil }
                })
                .frame(width: 100, height: 24).accessibilityIdentifier("shortcut-record-" + action.rawValue)
            Button("Clear") {
                prepareCustom(); var changed = settings.shortcutPreferences; changed.overrides[action] = []
                _ = apply(changed)
            }.accessibilityIdentifier("shortcut-clear-" + action.rawValue)
            Button("Reset") {
                prepareCustom(); var changed = settings.shortcutPreferences; changed.overrides.removeValue(forKey: action)
                _ = apply(changed)
            }.accessibilityIdentifier("shortcut-reset-" + action.rawValue)
        }.disabled(systemOverrides.contains(action))
    }
    private func keyDescription(_ action: BrowserCommand) -> String {
        let keys = settings.shortcutMap.shortcuts(for: action)
        return keys.isEmpty ? "No shortcut" : keys.map(\.display).joined(separator: "   ·   ")
    }
    private func prepareCustom() { if settings.keyboardProfile != .custom { settings.customizeBehavior() } }
    @discardableResult private func apply(_ preferences: BrowserShortcutPreferences) -> Bool {
        let candidate = BrowserShortcutMap(behavior: settings.behavior, preferences: preferences)
        if let issue = candidate.issues.first {
            switch issue {
            case .invalid: error = "Use one printable key with Command, Control or Option, or a supported navigation/function key."
            case .reserved: error = "This combination is reserved by macOS. Choose another shortcut."
            case .duplicate(let first, let second, let key): error = "\(key.display) is assigned to both \(first.title) and \(second.title). Change or clear the other binding first."
            }
            return false
        }
        settings.shortcutPreferences = preferences; error = ""; return true
    }
    private func refreshSystemState() {
        system.refresh()
        var found = Set<BrowserCommand>()
        func visit(_ menu: NSMenu?) {
            for item in menu?.items ?? [] {
                if !item.userKeyEquivalent.isEmpty, let action = BrowserCommand.command(for: item) { found.insert(action) }
                visit(item.submenu)
            }
        }
        visit(NSApplication.shared.mainMenu); systemOverrides = found
    }
}

/// The live native editor draws only text/caret. Its stable SwiftUI surround
/// supplies the field surface, avoiding the animated native bezel's black
/// intermediate backing when entering the Keyboard page in Glass mode.
private struct ShortcutQueryField: NSViewRepresentable {
    @Environment(\.interfaceScale) private var interfaceScale
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.font = .systemFont(ofSize: 13 * interfaceScale); field.textColor = .labelColor
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("shortcut-action-search")
        field.identifier = .init("shortcut-action-search")
        field.setAccessibilityLabel("Find an action or shortcut")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        field.font = .systemFont(ofSize: 13 * interfaceScale)
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let isRecording: Bool
    let begin: () -> Void
    let cancel: () -> Void
    let captured: (BrowserShortcut, NSEvent) -> Void
    func makeNSView(context: Context) -> ShortcutRecordButton { ShortcutRecordButton() }
    func updateNSView(_ button: ShortcutRecordButton, context: Context) {
        button.begin = begin; button.cancel = cancel; button.captured = captured
        button.setRecording(isRecording)
    }
}

/// Only recording uses a local monitor, restricted to this exact control's
/// window. Ordinary command routing never uses an event monitor or global tap.
@MainActor
private final class ShortcutRecordButton: NSButton {
    var begin: (() -> Void)?
    var cancel: (() -> Void)?
    var captured: ((BrowserShortcut, NSEvent) -> Void)?
    private var recording = false
    private var monitor: Any?
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = "Record…"; bezelStyle = .rounded; controlSize = .small
        target = self; action = #selector(startRecording(_:))
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    override var acceptsFirstResponder: Bool { true }
    func setRecording(_ value: Bool) {
        guard value != recording else { return }
        recording = value; title = value ? "Press keys…" : "Record…"
        if value {
            window?.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, self.recording, event.window === self.window else { return false }
                    if event.keyCode == 53 { self.cancel?(); return true }
                    if let shortcut = BrowserShortcut(event) { self.captured?(shortcut, event) }
                    return true
                }
                return consumed ? nil : event
            }
        } else if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    @objc private func startRecording(_ sender: Any?) { recording ? cancel?() : begin?() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { setRecording(false); cancel?() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result && recording { setRecording(false); cancel?() }
        return result
    }
}
