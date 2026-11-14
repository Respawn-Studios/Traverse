import AppKit
import ExplorerCore

/// A view-scoped adapter to AppKit's existing primary-pointer selection and drag
/// tracker. It never selects items itself, creates a dragging session, monitors
/// global events, posts input or changes physical modifier state.
@MainActor
final class BrowserPointerSelection {
    private weak var admittedWindow: NSWindow?
    private var active = false

    static func modifiers(_ flags: NSEvent.ModifierFlags, behavior: BrowserBehaviorPreferences) -> NSEvent.ModifierFlags {
        guard behavior.controlClickTogglesSelection, flags.contains(.control) else { return flags }
        var result = flags
        result.remove(.control); result.insert(.command)
        return result
    }

    /// Let the destination's existing broker interpret the Explorer copy alias
    /// instead of AppKit filtering it as a native Link. All other gestures keep
    /// native modifier filtering, including unsupported Control-Shift Link.
    nonisolated static func isControlCopyDrag(_ flags: NSEvent.ModifierFlags, controlAliases: Bool) -> Bool {
        controlAliases && flags.intersection([.control, .shift, .option, .command]) == .control
    }

    static func isSelectionAlias(_ event: NSEvent, in view: NSView,
                                 behavior: BrowserBehaviorPreferences, isEditingText: Bool = false) -> Bool {
        !isEditingText && behavior.controlClickTogglesSelection
            && event.type == .leftMouseDown && event.buttonNumber == 0
            && event.modifierFlags.contains(.control) && view.window != nil && event.window === view.window
    }

    func begin(_ event: NSEvent, in view: NSView, behavior: BrowserBehaviorPreferences,
               isEditingText: Bool = false) -> NSEvent {
        cancel()
        guard Self.isSelectionAlias(event, in: view, behavior: behavior, isEditingText: isEditingText),
              let window = view.window else { return event }
        guard let adapted = Self.copy(event, flags: Self.modifiers(event.modifierFlags, behavior: behavior)) else {
            return event
        }
        active = true; admittedWindow = window
        return adapted
    }
    func continuing(_ event: NSEvent, in view: NSView) -> NSEvent {
        guard active, view.window === admittedWindow, event.window === admittedWindow,
              [.leftMouseDragged, .leftMouseUp].contains(event.type) else { return event }
        defer { if event.type == .leftMouseUp { cancel() } }
        // Native Shift/Option changes and releasing Control remain physical
        // input. Only a currently held Control becomes Command for this alias.
        return Self.copy(event, flags: Self.modifiers(event.modifierFlags, behavior: .explorer)) ?? event
    }
    func cancel() { active = false; admittedWindow = nil }

    static func isEditingText(in collection: NSCollectionView) -> Bool {
        guard let editor = collection.window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView else { return false }
        return field === collection || field.isDescendant(of: collection)
    }
    private static func copy(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
            modifierFlags: flags, timestamp: event.timestamp, windowNumber: event.windowNumber,
            context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure)
    }
}
