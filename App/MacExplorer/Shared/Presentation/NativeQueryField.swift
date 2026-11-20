import AppKit
import SwiftUI

/// A native field editor shares typing, IME and command routing with the
/// surrounding tool. The caller owns the meaning of Return and Escape.
struct NativeQueryField: NSViewRepresentable {
    typealias Key = NativeQueryInput.Command
    enum Style { case plain, search, focusedSearch }

    @Binding var text: String
    let identifier: String
    let placeholder: String
    var style = Style.plain
    var restoresPriorFocus = false
    let onCommand: (Key) -> Bool
    @Environment(\.interfaceScale) private var scale

    func makeCoordinator() -> NativeQueryInput { NativeQueryInput() }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField
        switch style {
        case .plain:
            field = NSTextField()
            field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        case .search:
            let search = SearchShortcutField()
            search.sendsSearchStringImmediately = true
            // The settings sidebar owns its explicit dismissal control.
            (search.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
            field = search
        case .focusedSearch:
            let search = FocusedSearchField()
            search.sendsSearchStringImmediately = true
            search.restoresPriorFocus = restoresPriorFocus
            field = search
        }
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.identifier = .init(identifier)
        field.setAccessibilityIdentifier(identifier)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let binding = $text
        context.coordinator.onChange = { binding.wrappedValue = $0 }
        context.coordinator.onCommand = onCommand
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
        let font = NSFont.systemFont(ofSize: 13 * scale)
        if field.font != font { field.font = font }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.isEnabled = context.environment.isEnabled
        (field as? FocusedSearchField)?.focusWhenReady()
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: NativeQueryInput) {
        coordinator.onChange = nil
        coordinator.onCommand = nil
        field.delegate = nil
        (field as? FocusedSearchField)?.releaseOwnedFocus()
    }

    private final class SearchShortcutField: NSSearchField {
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let host = window, event.window === host, host.isKeyWindow, host.attachedSheet == nil,
                  isEnabled, !isHiddenOrHasHiddenAncestor,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "f" else {
                return super.performKeyEquivalent(with: event)
            }
            if let editor = currentEditor(), host.firstResponder === editor { return true }
            return host.makeFirstResponder(self)
        }
    }

    private final class FocusedSearchField: NSSearchField {
        var restoresPriorFocus = false
        private weak var focusHost: NSWindow?
        private weak var previousResponder: NSResponder?
        private var waitingForKey: BrowserNotificationObservation?
        private var requestedFocus = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            waitingForKey = nil
            guard let host = window else { return }
            waitingForKey = BrowserNotificationObservation(name: NSWindow.didBecomeKeyNotification, object: host) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusWhenReady() }
            }
            focusWhenReady()
        }

        func focusWhenReady() {
            guard requestedFocus, isEnabled, let host = window else { return }
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, let host, requestedFocus, window === host, host.isVisible, host.isKeyWindow,
                      !isHiddenOrHasHiddenAncestor, isEnabled else { return }
                let prior = host.firstResponder
                guard host.makeFirstResponder(self) else { return }
                requestedFocus = false
                waitingForKey = nil
                if restoresPriorFocus { focusHost = host; previousResponder = prior }
            }
        }

        func releaseOwnedFocus() {
            guard restoresPriorFocus, let host = focusHost, host.isKeyWindow,
                  let responder = host.firstResponder, responder === self || responder === currentEditor() else { return }
            let previous = previousResponder as? NSView
            let target = previous?.window === host && previous?.isHiddenOrHasHiddenAncestor == false ? previous : nil
            if !host.makeFirstResponder(target) { host.makeFirstResponder(nil) }
        }
    }
}

/// Review lists share the same keyboard field and count without owning the
/// report or deciding whether a selected row can perform an action.
struct ReviewFilterField: View {
    @Binding var query: String
    let identifier: String
    var placeholder = "Filter by name or path"
    let visibleCount: Int
    let totalCount: Int
    let isFiltering: Bool
    let dismiss: () -> Void
    let onCommand: (NativeQueryField.Key) -> Bool
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            NativeQueryField(text: $query, identifier: identifier, placeholder: placeholder,
                style: .focusedSearch, restoresPriorFocus: true, onCommand: onCommand)
                .frame(height: 27 * scale)
            if isFiltering {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Text("\(visibleCount) of \(totalCount)").interfaceFont(.caption).foregroundStyle(.secondary)
            }
            Button("Close Filter", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly)
        }
    }
}

/// Replaceable work for a local, already captured review list. A canceled
/// predicate must drain before the latest pending list starts filtering.
@MainActor final class ReviewRowFilter<Row: Sendable> {
    private struct Request: Sendable {
        let rows: [Row]
        let matches: @Sendable (Row) -> Bool
        let receive: @MainActor @Sendable ([Row]) -> Void
    }

    private var active: Task<Void, Never>?
    private var pending: Request?

    isolated deinit { active?.cancel() }

    func replace(_ rows: [Row], matches: @escaping @Sendable (Row) -> Bool,
                 receive: @escaping @MainActor @Sendable ([Row]) -> Void) {
        pending = .init(rows: rows, matches: matches, receive: receive)
        active?.cancel()
        start()
    }

    func cancel() {
        pending = nil
        active?.cancel()
    }

    private func start() {
        guard active == nil, let request = pending else { return }
        pending = nil
        active = Task.detached(priority: .userInitiated) { [weak self] in
            var rows: [Row] = []
            try? await Task.sleep(for: .milliseconds(45))
            for row in request.rows {
                if Task.isCancelled { break }
                if request.matches(row) { rows.append(row) }
            }
            await self?.complete(rows, request: request)
        }
    }

    private func complete(_ rows: [Row], request: Request) {
        active = nil
        if !Task.isCancelled { request.receive(rows) }
        start()
    }
}

@MainActor final class NativeQueryInput: NSObject, NSSearchFieldDelegate {
    enum Command { case submit, cancel, up, down }
    var onChange: ((String) -> Void)?
    var onCommand: ((Command) -> Bool)?

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        onChange?((field.currentEditor() as? NSTextView)?.string ?? field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText(), let onCommand else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): return onCommand(.submit)
        case #selector(NSResponder.cancelOperation(_:)): return onCommand(.cancel)
        case #selector(NSResponder.moveUp(_:)): return onCommand(.up)
        case #selector(NSResponder.moveDown(_:)): return onCommand(.down)
        default: return false
        }
    }
}
