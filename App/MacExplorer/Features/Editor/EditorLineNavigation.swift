import AppKit

enum EditorJumpDirection: Int, CaseIterable {
    case previous, next

    var offset: Int { self == .previous ? -1 : 1 }

    @MainActor static func menuItems(target: AnyObject, action: Selector) -> [NSMenuItem] {
        allCases.map { direction in
            let previous = direction == .previous
            let item = BrowserMenus.item(previous ? "Previous Text Location" : "Next Text Location",
                action, key: previous ? "-" : "_", modifiers: previous ? .control : [.control, .shift], target: target)
            item.tag = direction.rawValue
            return item
        }
    }

    @MainActor static func changeMenuItems(target: AnyObject, action: Selector, qualifier: String = "") -> [NSMenuItem] {
        [.next, .previous].map { (direction: Self) in
            let title = (direction == .next ? "Next " : "Previous ") + qualifier + "Change"
            let item = BrowserMenus.item(title, action, key: String(UnicodeScalar(NSF7FunctionKey)!),
                modifiers: direction == .next ? [] : .command, target: target)
            item.tag = direction.rawValue
            return item
        }
    }
}

struct EditorNavigationPosition: Equatable {
    let selection: NSRange
    let anchor: EditorScrollAnchor?
    let origin: NSPoint
}

struct EditorBufferIdentity: Equatable, Sendable {
    let document: UUID
    let generation: UUID
}

struct EditorFileJump {
    enum Destination: Sendable {
        case line(EditorLineAddress)
        case match(EditorTextMatchLocation)
        case declaration(EditorDocumentOutline.Entry, TextSyntaxLanguage)
    }
    let destination: Destination?
    let origin: EditorDocumentNavigation.Location?
}

struct EditorTextMatchLocation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let range: NSRange
    let expected: String

    var description: String { "<observed text match>" }
    var debugDescription: String { description }

    func verifiedRange(in text: String) -> NSRange? {
        guard let observed = Range(range, in: text), text[observed].utf16.elementsEqual(expected.utf16) else { return nil }
        return range
    }
}

/// Tracks explicit jumps. Owners validate the buffer generation before using
/// any offset; layout changes can still restore the logical viewport.
struct EditorJumpTrail<Position: Equatable> {
    private static var limit: Int { 32 }
    private var previous: [Position] = []
    private var next: [Position] = []

    func hasLocation(_ direction: EditorJumpDirection, matching accepts: (Position) -> Bool = { _ in true }) -> Bool {
        (direction == .previous ? previous : next).reversed().contains(where: accepts)
    }

    mutating func record(_ position: Position) {
        Self.push(position, onto: &previous)
        next.removeAll(keepingCapacity: true)
    }

    mutating func visit(_ direction: EditorJumpDirection, leaving position: Position,
                        matching accepts: (Position) -> Bool = { _ in true }) -> Position? {
        switch direction {
        case .previous:
            guard let destination = Self.pop(from: &previous, matching: accepts) else { return nil }
            Self.push(position, onto: &next)
            return destination
        case .next:
            guard let destination = Self.pop(from: &next, matching: accepts) else { return nil }
            Self.push(position, onto: &previous)
            return destination
        }
    }

    private static func pop(from history: inout [Position], matching accepts: (Position) -> Bool) -> Position? {
        while let position = history.popLast() {
            if accepts(position) { return position }
        }
        return nil
    }

    private static func push(_ position: Position, onto history: inout [Position]) {
        guard history.last != position else { return }
        if history.count == limit { history.removeFirst() }
        history.append(position)
    }
}

/// Shared by native editor windows. The trail owns no documents, paths, text
/// or undo history. Closing a tab or editing its buffer revokes old locations.
@MainActor final class EditorDocumentNavigation {
    static let shared = EditorDocumentNavigation()

    struct Location: Equatable {
        let buffer: EditorBufferIdentity
        let position: EditorNavigationPosition
    }

    private var trail = EditorJumpTrail<Location>()

    func location(in editor: NativeTextEditorWindow, position: EditorNavigationPosition? = nil) -> Location? {
        guard editor.canSearchOpenBuffer, let position = position ?? editor.surface.navigationPosition() else { return nil }
        return .init(buffer: editor.openBufferIdentity, position: position)
    }

    func record(_ location: Location) { trail.record(location) }

    func canVisit(_ direction: EditorJumpDirection, from origin: NativeTextEditorWindow) -> Bool {
        guard canLeave(origin), let leaving = location(in: origin) else { return false }
        let editors = openEditors(from: origin)
        return trail.hasLocation(direction) { $0 != leaving && Self.destination($0, in: editors) != nil }
    }

    func visit(_ direction: EditorJumpDirection, from origin: NativeTextEditorWindow) {
        guard canLeave(origin), let leaving = location(in: origin) else { return }
        let editors = openEditors(from: origin)
        guard let place = trail.visit(direction, leaving: leaving, matching: {
            $0 != leaving && Self.destination($0, in: editors) != nil
        }), let editor = Self.destination(place, in: editors) else { return }
        editor.focusNavigationTarget()
        editor.surface.restoreNavigationPosition(place.position)
    }

    private func canLeave(_ origin: NativeTextEditorWindow) -> Bool {
        guard let window = origin.window, window.isKeyWindow else { return false }
        return (window.firstResponder as? NSTextView)?.hasMarkedText() != true
    }

    private func openEditors(from origin: NativeTextEditorWindow) -> [UUID: NativeTextEditorWindow] {
        Dictionary(uniqueKeysWithValues: NativeTextEditorWindow.openSearchDocuments(preferred: origin).map { ($0.openSearchID, $0) })
    }

    private static func destination(_ location: Location, in editors: [UUID: NativeTextEditorWindow]) -> NativeTextEditorWindow? {
        guard let editor = editors[location.buffer.document], editor.openBufferIdentity == location.buffer,
              editor.surface.canRestoreNavigationPosition(location.position) else { return nil }
        return editor
    }
}

@MainActor final class EditorLineNavigation {
    struct Target {
        let name: String?
        let index: EditorLineIndex
        let currentLine: Int
        let lastLine: Int
    }

    private var dialog: Dialog?
    private weak var parent: NSWindow?

    func present(in window: NSWindow, surface: NativeTextEditorSurface, changed: @escaping @MainActor () -> Void) {
        guard surface.window === window, surface.canGoToLine, let index = surface.lineIndex else { return }
        let generation = surface.generation
        let current = index.location(at: surface.textView.selectedRange().location)?.line ?? 1
        let target = Target(name: nil, index: index, currentLine: current, lastLine: index.starts.count)
        present(in: window, targets: [target], initial: 0) { [weak surface, weak window] _, address in
            guard let surface, let window, surface.window === window else { return }
            if !surface.goTo(address, generation: generation) { changed() }
        }
    }

    func present(in window: NSWindow, targets: [Target], initial: Int,
                 confirmed: @escaping @MainActor (Int, EditorLineAddress) -> Void) {
        guard dialog == nil, window.isKeyWindow, window.attachedSheet == nil, targets.indices.contains(initial) else { return }
        let prompt = Dialog(targets: targets, initial: initial)
        dialog = prompt
        parent = window
        prompt.alert.beginSheetModal(for: window) { [weak self, weak prompt, weak window] response in
            guard let self, let prompt, self.dialog === prompt else { return }
            self.dialog = nil
            self.parent = nil
            guard response == .alertFirstButtonReturn, window?.isVisible == true,
                  let address = prompt.address else { return }
            confirmed(prompt.selectedTarget, address)
        }
    }

    func cancel() {
        guard let prompt = dialog else { return }
        let window = parent
        dialog = nil
        parent = nil
        if window?.attachedSheet === prompt.alert.window {
            window?.endSheet(prompt.alert.window, returnCode: .alertSecondButtonReturn)
        }
    }

    @MainActor private final class Dialog: NSObject, NSTextFieldDelegate {
        let alert = NSAlert()
        private let field: NSTextField
        private let targets: [Target]
        private var picker: NSSegmentedControl?
        var selectedTarget: Int {
            let selected = picker?.selectedSegment ?? 0
            return targets.indices.contains(selected) ? selected : 0
        }
        var address: EditorLineAddress? {
            let target = targets[selectedTarget]
            guard let address = EditorLineAddress.parse(field.stringValue, in: target.index),
                  address.line <= target.lastLine else { return nil }
            return address
        }

        init(targets: [Target], initial: Int) {
            self.targets = targets
            field = NSTextField(string: String(targets[initial].currentLine))
            super.init()
            alert.messageText = "Go to Line"
            alert.addButton(withTitle: "Go")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[1].keyEquivalent = "\u{1b}"
            field.frame = .init(x: 0, y: 0, width: 260, height: 24)
            field.drawsBackground = false
            field.setAccessibilityLabel("Line number and optional column")
            field.delegate = self
            if targets.count == 1 {
                alert.accessoryView = field
            } else {
                let control = NSSegmentedControl(labels: targets.map { $0.name ?? "" }, trackingMode: .selectOne,
                    target: self, action: #selector(targetChanged(_:)))
                control.selectedSegment = initial
                control.setAccessibilityLabel("Compared version")
                picker = control
                let stack = NSStackView(views: [control, field])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 8
                stack.frame = .init(x: 0, y: 0, width: 260, height: 60)
                field.widthAnchor.constraint(equalToConstant: 260).isActive = true
                alert.accessoryView = stack
            }
            alert.window.initialFirstResponder = field
            updateBounds()
        }

        @objc private func targetChanged(_ sender: NSSegmentedControl) { updateBounds() }

        private func updateBounds() {
            let target = targets[selectedTarget]
            let version = target.name.map { $0 + " · " } ?? ""
            alert.informativeText = version
                + "Enter a line number from 1 to \(target.lastLine.formatted()). Add a column like 12:4."
                + (picker == nil ? "" : " Use ↑ or ↓ to change versions.")
            validate()
        }

        func controlTextDidChange(_ notification: Notification) { validate() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard control === field, !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
                guard let picker else { return false }
                let step = selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1
                picker.selectedSegment = min(targets.count - 1, max(0, selectedTarget + step))
                updateBounds()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                validate()
                if alert.buttons[0].isEnabled { alert.buttons[0].performClick(nil) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                alert.buttons[1].performClick(nil)
                return true
            default: return false
            }
        }

        private func validate() { alert.buttons[0].isEnabled = address != nil }
    }
}
