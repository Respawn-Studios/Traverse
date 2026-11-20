#if DEBUG
import AppKit
import Darwin
#if canImport(FileOperations)
import FileOperations
#endif

/// Existing ordinary-app DEBUG verification. Every document is an authored in-memory value.
/// Only reservation/admission metadata and a bounded diagnostic JSON use a URL.
/// Reuses the editor's DEBUG-only task observations and local event boundary.
@MainActor enum EditorLineCommandVerification {
    private struct Failure: Error { let stage: String }
    private static func need(_ value: Bool, _ stage: String) throws { if !value { throw Failure(stage: stage) } }
    private static func same(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
    private static func r(_ location: Int, _ length: Int = 0) -> NSRange { .init(location: location, length: length) }
    private static func wait(_ stage: String, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !ready() {
            try need(.now < deadline, stage)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private final class Probe: @unchecked Sendable {
        struct Counts: Sendable {
            var preparations = 0, preparationsFinished = 0, deliveries = 0, deliveriesFinished = 0
            var activePreparations = 0, activeDeliveries = 0, peakPreparations = 0
            var mainPreparation = false, offMainDelivery = false
            var drained: Bool { activePreparations == 0 && activeDeliveries == 0
                && preparations == preparationsFinished && deliveries == deliveriesFinished }
        }
        private let lock = NSLock()
        private var counts = Counts()
        func record(_ event: EditorLineCommandController.VerificationEvent) {
            lock.lock(); defer { lock.unlock() }
            switch event {
            case .preparationStarted:
                counts.preparations += 1; counts.activePreparations += 1
                counts.peakPreparations = max(counts.peakPreparations, counts.activePreparations)
                counts.mainPreparation = counts.mainPreparation || Thread.isMainThread
            case .preparationFinished: counts.preparationsFinished += 1; counts.activePreparations -= 1
            case .deliveryStarted:
                counts.deliveries += 1; counts.activeDeliveries += 1
                counts.offMainDelivery = counts.offMainDelivery || !Thread.isMainThread
            case .deliveryFinished: counts.deliveriesFinished += 1; counts.activeDeliveries -= 1
            }
        }
        var snapshot: Counts { lock.lock(); defer { lock.unlock() }; return counts }
    }
    private actor PreparationHold {
        private var used = false, released = false
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        func pauseOnce() async {
            guard !used else { return }; used = true; entered = true
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    /// Uses a private application-defined event and one LOCAL monitor; no new
    /// NSApplication subclass, global monitor, CGEvent or real keyboard gesture.
    @MainActor private final class Events {
        private struct Job {
            let body: @MainActor () throws -> Void
            let continuation: CheckedContinuation<Void, Error>
            let watchdog: Task<Void, Never>
        }
        private var monitor: Any?
        private var next = 0
        private var jobs: [Int: Job] = [:]
        private(set) var unexpectedInputCount = 0
        init() throws {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.applicationDefined, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.receive(event) ?? false }
                return consumed ? nil : event
            }
            try need(monitor != nil, "local-event-monitor")
        }
        private func receive(_ event: NSEvent) -> Bool {
            if event.type != .applicationDefined {
                // Count only; never record characters, buttons or other apps.
                unexpectedInputCount += 1
                return false
            }
            guard event.type == .applicationDefined, event.data2 == 0x4C494E45,
                  let job = jobs.removeValue(forKey: event.data1) else { return false }
            job.watchdog.cancel()
            do { try job.body(); job.continuation.resume() }
            catch { job.continuation.resume(throwing: error) }
            return true
        }
        func perform(_ body: @escaping @MainActor () throws -> Void = {}) async throws {
            try need(jobs.isEmpty && next < 4096, "bounded-native-event-queue")
            next += 1; let token = next
            guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, subtype: 0, data1: token, data2: 0x4C494E45) else {
                throw Failure(stage: "native-event-construction")
            }
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let job = self?.jobs.removeValue(forKey: token) else { return }
                    job.continuation.resume(throwing: Failure(stage: "actual-application-event-deadline"))
                }
                jobs[token] = .init(body: body, continuation: continuation, watchdog: timeout)
                NSApp.postEvent(event, atStart: false)
            }
        }
        func close() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            for job in jobs.values { job.watchdog.cancel(); job.continuation.resume(throwing: Failure(stage: "event-owner-closed")) }
            jobs.removeAll()
        }
    }

    @MainActor private final class AdmissionProxy: NSObject, NSTextViewDelegate {
        weak var surface: NativeTextEditorSurface?
        var calls = 0, deny = false
        var admissions: [[String: Int]] = []
        init(_ surface: NativeTextEditorSurface) { self.surface = surface }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            calls += 1
            if admissions.count < 32 {
                admissions.append(["location": affectedCharRange.location, "length": affectedCharRange.length,
                                   "replacementUTF16": replacementString?.utf16.count ?? -1])
            }
            return !deny && surface?.textView(textView, shouldChangeTextIn: affectedCharRange, replacementString: replacementString) == true
        }
        func textDidChange(_ notification: Notification) { surface?.textDidChange(notification) }
        func textViewDidChangeSelection(_ notification: Notification) { surface?.textViewDidChangeSelection(notification) }
    }
    @MainActor private final class Fixture {
        let owner: NativeTextEditorWindow, probe = Probe(), proxy: AdmissionProxy
        var gates: [PreparationHold] = []
        var edits = 0, rejections: [TextDocumentFailure] = [], closeCount = 0, unexpectedSaves = 0
        var items: [Int: NSMenuItem] = [:]
        var facts: [String: Any] = [:]
        var surface: NativeTextEditorSurface { owner.surface }
        var text: EditorCodeTextView { surface.textView }
        var native: NSWindow { owner.window! }
        init(_ title: String, value: TextDocumentValue, selection: NSRange) {
            owner = NativeTextEditorWindow(displayName: "Generated line commands · " + title, installChrome: { _ in })
            proxy = AdmissionProxy(owner.surface)
            owner.shouldClose = { true }
            owner.surface.textView.delegate = proxy
            let observer = probe
            owner.surface.lineCommands.eventForVerification = { observer.record($0) }
            owner.surface.find.motion = { .init(mode: .off) }
            owner.surface.onEdit = { [weak self] _, _ in self?.edits += 1; self?.owner.window?.isDocumentEdited = true }
            owner.surface.onRejectedEdit = { [weak self] value in self?.rejections.append(value) }
            owner.didClose = { [weak self] in self?.closeCount += 1 }
            owner.onSave = { [weak self] in self?.unexpectedSaves += 1 }
            owner.onSaveAs = { [weak self] in self?.unexpectedSaves += 1 }
            owner.onTextCopy = { [weak self] in self?.unexpectedSaves += 1 }
            owner.surface.install(value); owner.surface.textView.setSelectedRange(selection)
            owner.window?.isDocumentEdited = false
            disableFileActions()
        }
        func disableFileActions() {
            for button in [owner.saveButton, owner.saveAsButton, owner.textCopyButton, owner.reloadButton, owner.recoveryButton] {
                button.isEnabled = false
            }
        }
        func presentCurrentLines() throws {
            let shown = try TextDocumentValue.edited(text.string, format: .init(bom: false, lineEnding: .lf))
            try need(surface.present(shown, syntax: .tokens([]), lines: .init(shown.text), for: surface.generation), "present-current-lines")
        }
        func start() async throws {
            owner.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait("actual-editor-application-active") { NSApp.isActive }
            native.makeKeyAndOrderFront(nil)
            try await wait("actual-editor-key-window") { self.native.isKeyWindow && self.native.isVisible }
            try need(native.makeFirstResponder(text), "actual-document-first-responder")
            try await wait("actual-menu-owner") { UIVerification.menuItem("Edit", "Lines")?.submenu != nil }
            guard let lines = UIVerification.menuItem("Edit", "Lines")?.submenu else { throw Failure(stage: "editor-lines-menu") }
            for tag in [0, 1, 2, 6, 7, 8] {
                guard let item = lines.items.first(where: { $0.action == NSSelectorFromString("performLineCommand:") && $0.tag == tag }),
                      (item.target as? NativeTextEditorWindow) === owner else { throw Failure(stage: "actual-targeted-line-menu") }
                items[tag] = item
            }
            try need(!owner.saveButton.isEnabled && !owner.saveAsButton.isEnabled && !owner.textCopyButton.isEnabled,
                     "save-capabilities-disabled")
            try need(items.values.allSatisfy { owner.validateUserInterfaceItem($0) }, "actual-menu-validation-enabled")
        }
        func send(_ tag: Int) throws {
            guard let item = items[tag], let action = item.action else { throw Failure(stage: "retained-menu-item") }
            facts["lastRequestedTag"] = tag; facts["lastActualItemTag"] = item.tag
            facts["lastTargetMatchesOwner"] = (item.target as? NativeTextEditorWindow) === owner
            try need(NSApp.sendAction(action, to: item.target, from: item), "actual-menu-target-delivery")
        }
        func surroundItem(_ pair: EditorSurroundingPair) throws -> NSMenuItem {
            guard let item = owner.discoverableCommands().first(where: {
                $0.0.action == NSSelectorFromString("surroundSelection:") && $0.0.tag == pair.rawValue
            })?.0, (item.target as? NativeTextEditorWindow) === owner else {
                throw Failure(stage: "actual-targeted-surround-menu")
            }
            return item
        }
        func hold() -> PreparationHold {
            let gate = PreparationHold(); gates.append(gate)
            surface.lineCommands.preparationHoldForVerification = { await gate.pauseOnce() }
            return gate
        }
        func findFocus() throws {
            surface.find.perform(.showFindInterface)
            try need(native.firstResponder !== text && surface.find.bar.query.currentEditor() != nil, "actual-Find-field-first-responder")
        }
        func diagnostics() -> [String: Any] {
            let p = probe.snapshot, state = surface.lineCommands.stateForVerification
            return ["edits": edits, "rejections": rejections.count, "nativeAdmissionCalls": proxy.calls,
                "applicationActive": NSApp.isActive, "windowKey": native.isKeyWindow,
                "windowVisible": native.isVisible, "closeCallbacks": closeCount,
                "selectionLocation": text.selectedRange().location, "selectionLength": text.selectedRange().length,
                "textUTF16Count": text.string.utf16.count, "documentEdited": native.isDocumentEdited,
                "admissions": proxy.admissions,
                "preparations": p.preparations, "preparationsFinished": p.preparationsFinished,
                "deliveries": p.deliveries, "deliveriesFinished": p.deliveriesFinished,
                "peakPreparations": p.peakPreparations, "mainPreparation": p.mainPreparation,
                "offMainDelivery": p.offMainDelivery, "pending": state.pendingCount,
                "retainedWork": state.hasRetainedWork, "undoGroupingLevel": text.undoManager?.groupingLevel ?? -1,
                "undoAvailable": text.undoManager?.canUndo == true, "redoAvailable": text.undoManager?.canRedo == true,
                "unexpectedSaveCallbacks": unexpectedSaves, "facts": facts]
        }
    }
    @MainActor private final class Context {
        let events: Events
        let evidenceDirectory: URL?
        var capturedJSONC = false
        let originalMenu: NSMenu?
        let deadline = ContinuousClock.now + .seconds(60)
        var active: [Fixture] = [], results: [[String: Any]] = []
        var lastCleanup: [[String: Any]] = [], observedSaveCallbacks = 0
        init(evidenceDirectory: URL?) throws {
            self.evidenceDirectory = evidenceDirectory
            originalMenu = NSApp.mainMenu
            if originalMenu == nil {
                let menu = NSMenu(), application = NSMenuItem(title: "Generated Line Commands", action: nil, keyEquivalent: "")
                application.submenu = NSMenu(); menu.addItem(application); NSApp.mainMenu = menu
            }
            events = try Events()
        }
        func make(_ label: String, value: TextDocumentValue, selection: NSRange) async throws -> Fixture {
            try need(active.count < 2, "maximum-two-generated-windows")
            let fixture = Fixture(label, value: value, selection: selection); active.append(fixture)
            try await fixture.start(); return fixture
        }
        func gateEntered(_ gate: PreparationHold) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while !(await gate.entered) { try need(.now < deadline, "actual-off-main-preparation-held"); try await Task.sleep(for: .milliseconds(5)) }
        }
        func drain(_ f: Fixture) async throws {
            try await wait("actual-controller-task-and-queue-drain") {
                !f.surface.lineCommands.stateForVerification.hasRetainedWork && f.probe.snapshot.drained && !f.surface.find.isWorking
            }
            try await events.perform(); try await events.perform()
            try need(!f.surface.lineCommands.stateForVerification.hasRetainedWork && f.probe.snapshot.drained,
                     "event-fenced-controller-remains-drained")
            let p = f.probe.snapshot
            try need(p.preparations == p.deliveries && p.peakPreparations <= 1 && !p.mainPreparation && !p.offMainDelivery,
                     "one-off-main-preparation-native-delivery")
        }
        func cleanup() async -> Bool {
            var clean = true; lastCleanup = []
            for f in active { for gate in f.gates { await gate.release() }; if f.closeCount == 0 { f.owner.finishClose() } }
            for f in active {
                do {
                    try await drain(f)
                    try await wait("actual-owned-window-close-animation") { !f.native.isVisible }
                    try need(f.closeCount == 1 && !f.native.isVisible && f.surface.lineCommands.stateForVerification.isClosed,
                             "actual-owned-window-close-and-controller-drain")
                    try need(f.unexpectedSaves == 0, "no-Save-handler-invocation")
                } catch { clean = false }
                var record = f.diagnostics()
                record["closed"] = f.closeCount == 1 && !f.native.isVisible
                record["controllerClosed"] = f.surface.lineCommands.stateForVerification.isClosed
                lastCleanup.append(record); observedSaveCallbacks += f.unexpectedSaves
            }
            active.removeAll(); return clean
        }
        func check(_ name: String, value: TextDocumentValue, selection: NSRange,
                   body: (Fixture) async throws -> Void) async {
            var failure: String?, diagnostic: [String: Any] = [:]
            do {
                try need(.now < deadline, "finite-suite-deadline-before-case")
                try need(events.unexpectedInputCount == 0, "unexpected-native-input-interference")
                let f = try await make(name, value: value, selection: selection)
                do {
                    try await body(f)
                    try need(events.unexpectedInputCount == 0, "unexpected-native-input-interference")
                } catch { failure = (error as? Failure)?.stage ?? "unclassified-native-error" }
                diagnostic = f.diagnostics()
            } catch {
                failure = (error as? Failure)?.stage ?? "fixture-setup-error"
                diagnostic = active.last?.diagnostics() ?? [:]
            }
            let clean = await cleanup()
            results.append(["case": name, "passed": failure == nil && clean, "failure": failure ?? "none",
                            "cleanup": clean, "observationsBeforeCleanup": diagnostic, "cleanupObservations": lastCleanup])
            print("EDITOR_LINE_CASE " + name + " " + (failure == nil && clean ? "PASS" : "FAIL") + " " + (failure ?? "none"))
        }
    }

    private static func focusCausal(_ c: Context, _ f: Fixture, fresh: Bool) async throws {
        let original = f.text.string, selection = f.text.selectedRange(), generation = f.surface.generation
        let gate = f.hold()
        try await c.events.perform { try f.send(0); try f.send(0) }
        try await c.gateEntered(gate)
        try need(f.surface.lineCommands.stateForVerification.pendingCount == 1, "one-command-queued-before-focus-transition")
        try await c.events.perform { try f.findFocus(); try need(f.native.makeFirstResponder(f.text), "document-focus-return") }
        try need(same(f.text.string, original) && f.text.selectedRange() == selection && f.surface.generation == generation,
                 "focus-causal-snapshot-unchanged")
        if fresh {
            try need(f.surface.lineCommands.stateForVerification.hasWorker && f.surface.lineCommands.stateForVerification.pendingCount == 0,
                     "cancelled-worker-retained-old-queue-cleared")
            try await c.events.perform { try f.send(2) }
            try need(f.surface.lineCommands.stateForVerification.pendingCount == 1, "fresh-command-queues-behind-cancelled-worker")
        }
        await gate.release(); try await c.drain(f)
        if fresh {
            try need(same(f.text.string, "B\nA") && f.text.selectedRange() == r(2) && f.edits == 1,
                     "new-epoch-command-uses-fresh-snapshot-once")
            try need(f.probe.snapshot.preparations == 2, "cancelled-then-one-fresh-preparation")
        } else {
            // EXACT causal assertion: retained pre-epoch inputs should fail here;
            // fixed inputs should pass. No snapshot/result is supplied by a hook.
            try need(same(f.text.string, original) && f.surface.generation == generation && f.edits == 0,
                     "transient-focus-held-work-must-not-edit")
            try need(f.text.selectedRange() == selection && f.probe.snapshot.preparations == 1,
                     "transient-focus-does-not-replay-queued-command")
        }
    }

    private static func cases(_ c: Context, causalOnly: Bool) async throws {
        func value(_ text: String) throws -> TextDocumentValue { try .edited(text, format: .init(bom: false, lineEnding: .lf)) }
        let basic = try value("A\nB")
        if causalOnly {
            await c.check("transient-focus-causal", value: basic, selection: r(0)) { try await focusCausal(c, $0, fresh: false) }
            return
        }
        try comparedChangePlans()
        let conflict = "before\n<<<<<<<<< HEAD\nlocal 🧭\n||||||||| base\nold e\u{301}\n=========\nincoming\n>>>>>>>>> branch\nafter"
        let offset = (conflict as NSString).range(of: "<<<<<<<<<").location
        for (choice, expected) in [(EditorConflictMarkers.Resolution.current, "local 🧭\n"), (.incoming, "incoming\n"),
                                    (.both, "local 🧭\nincoming\n"), (.base, "old e\u{301}\n")] {
            guard case .replace(let edit) = EditorLineCommands.plan(.resolveConflict(choice), text: conflict,
                selection: r(offset), maximumBytes: 1_024) else { throw Failure(stage: "custom-width-diff3-plan") }
            try need(same((conflict as NSString).replacingCharacters(in: edit.range, with: edit.text),
                          "before\n" + expected + "after"), "custom-width-diff3-preserves-exact-utf16-and-surrounding-lines")
        }
        let twoWay = "<<<<<<<\na\n=======\nb\n>>>>>>>"
        try need(EditorConflictMarkers.scan(twoWay, index: .init(twoWay)).blocks.count == 1
            && EditorLineCommands.plan(.resolveConflict(.base), text: twoWay, selection: r(0), maximumBytes: 1_024)
                == .refused(.noCompleteConflict), "two-way-markers-have-no-base-choice")
        for malformed in ["<<<<<<<\na\n=======\nb\n>>>>>>>>", "<<<<<<<\na\n>>>>>>>\n", "<<<<<<<\n" + twoWay + "\n=======\n>>>>>>>\n"] {
            try need(EditorLineCommands.plan(.resolveConflict(.both), text: malformed, selection: r(0), maximumBytes: 1_024)
                == .refused(.noCompleteConflict), "malformed-or-nested-conflict-preserves-text")
        }
        await c.check("native-JSON-nested-pairs-and-owned-closing-skip", value: try value(""), selection: r(0)) { f in
            f.owner.selectLanguage(.json)
            // Each user gesture gets an actual application event. Combining
            // two insertions inside one event also combines native event Undo.
            try await c.events.perform { f.text.insertText("{", replacementRange: r(NSNotFound)) }
            try await wait("outer-pair-native-event-group-ended") { f.text.undoManager?.groupingLevel == 0 }
            try await c.events.perform { f.text.insertText("[", replacementRange: r(NSNotFound)) }
            try await wait("inner-pair-native-event-group-ended") { f.text.undoManager?.groupingLevel == 0 }
            try need(same(f.text.string, "{[]}") && f.text.selectedRange() == r(2)
                && f.edits == 2 && f.proxy.calls == 2, "nested-openings-are-two-native-pair-edits")
            try await c.events.perform { f.text.insertText("]", replacementRange: r(NSNotFound)) }
            try await c.events.perform { f.text.insertText("}", replacementRange: r(NSNotFound)) }
            try need(same(f.text.string, "{[]}") && f.text.selectedRange() == r(4)
                && f.edits == 2 && f.proxy.calls == 2, "owned-closing-keys-only-move-caret")
            guard let undo = f.text.undoManager else { throw Failure(stage: "paired-brackets-native-Undo") }
            try await c.events.perform { undo.undo() }
            try need(same(f.text.string, "{}"), "one-Undo-removes-complete-inner-pair")
            try await c.events.perform { undo.undo() }
            try need(f.text.string.isEmpty && !undo.canUndo, "second-Undo-removes-complete-outer-pair")
            try await c.events.perform { undo.redo() }
            try await c.events.perform { undo.redo() }
            try need(same(f.text.string, "{[]}") && !undo.canRedo, "pair-Redo-restores-native-text")
        }
        await c.check("native-code-pair-context-provenance-and-Undo", value: try value(""), selection: r(0)) { f in
            f.text.completesCodeBrackets = true
            guard let undo = f.text.undoManager else { throw Failure(stage: "code-pair-native-Undo") }
            let languages: [TextSyntaxLanguage] = [.swift, .rust, .python, .javascript, .typescript, .c, .cpp, .objectiveC, .objectiveCPP, .css]
            for language in languages {
                f.owner.selectLanguage(language)
                try await c.events.perform { f.text.insertText("(", replacementRange: r(NSNotFound)) }
                try await wait("code-pair-\(language.rawValue)-native-Undo-group") { undo.groupingLevel == 0 }
                try need(same(f.text.string, "()") && f.text.selectedRange() == r(1), "code-pair-\(language.rawValue)-opens-with-inner-caret")
                let generation = f.surface.generation
                try await c.events.perform { f.text.insertText(")", replacementRange: r(NSNotFound)) }
                try need(same(f.text.string, "()") && f.text.selectedRange() == r(2) && f.surface.generation == generation,
                    "code-pair-\(language.rawValue)-skips-only-owned-close")
                try await c.events.perform { undo.undo() }
                try need(f.text.string.isEmpty && !undo.canUndo, "code-pair-\(language.rawValue)-one-Undo")
            }
            try await c.events.perform { f.text.insertText("[", replacementRange: r(NSNotFound)) }
            try await wait("code-pair-before-deletion-group-ended") { undo.groupingLevel == 0 }
            try need(same(f.text.string, "[]"), "code-pair-square-brackets-complete")
            try await c.events.perform { f.text.deleteBackward(nil) }
            try need(f.text.string.isEmpty, "code-pair-Backspace-removes-owned-empty-pair")
            try await c.events.perform { undo.undo() }
            try need(same(f.text.string, "[]"), "one-Undo-restores-code-pair-after-deletion")
            let line = "func render(_ value: Int) -> [Int] { return [value] } // generated source\n"
            let count = (EditorIndentation.lexicalInputLimit - 256) / line.utf16.count
            let prefix = String(repeating: line, count: count) + "let output = render"
            let boundedPair = EditorBracketPairing.plan("(", prefix: prefix, next: nil,
                ownsNextClose: false, language: .swift, enabled: true)
            try need(boundedPair == .insert("()", 41), "code-pairs-still-work-near-the-bounded-prefix-limit")
        }
        await c.check("native-optional-code-pairs-and-smart-Return", value: try value("let render = "), selection: r(13)) { f in
            f.owner.selectLanguage(.swift)
            try need(!f.text.completesCodeBrackets, "existing-editor-default-keeps-literal-code-brackets")
            try await c.events.perform { f.text.insertText("{", replacementRange: r(NSNotFound)) }
            try await wait("literal-brace-Undo-group-ended") { f.text.undoManager?.groupingLevel == 0 }
            try need(same(f.text.string, "let render = {"), "disabled-code-pairs-use-native-insertion")
            try await c.events.perform { f.text.undoManager?.undo() }
            f.text.completesCodeBrackets = true
            try await c.events.perform { f.text.insertText("{", replacementRange: r(NSNotFound)) }
            try await wait("code-pair-before-Return-group-ended") { f.text.undoManager?.groupingLevel == 0 }
            try need(same(f.text.string, "let render = {}") && f.text.selectedRange() == r(14), "enabled-code-brace-completes")
            try await c.events.perform { f.text.insertNewline(nil) }
            try await wait("code-pair-Return-Undo-group-ended") { f.text.undoManager?.groupingLevel == 0 }
            let expected = "let render = {\n    \n}"
            try need(same(f.text.string, expected) && f.text.selectedRange() == r(19), "code-pair-shares-smart-Return")
            try await c.events.perform { f.text.insertText("}", replacementRange: r(NSNotFound)) }
            try need(same(f.text.string, expected) && f.text.selectedRange().location == expected.utf16.count,
                "code-pair-can-skip-owned-close-after-empty-indentation")
            try await c.events.perform { f.text.undoManager?.undo() }
            try need(same(f.text.string, "let render = {}"), "one-Undo-removes-only-code-Return")
        }
        await c.check("native-pair-Backspace-native-Undo-and-provenance", value: try value(""), selection: r(0)) { f in
            f.owner.selectLanguage(.json)
            try await c.events.perform { f.text.insertText("{", replacementRange: r(NSNotFound)) }
            try await wait("pair-before-Backspace-event-ended") { f.text.undoManager?.groupingLevel == 0 }
            try await c.events.perform { f.text.deleteBackward(nil) }
            try need(f.text.string.isEmpty && f.text.selectedRange() == r(0) && f.edits == 2,
                "Backspace-removes-owned-empty-pair-in-one-edit")
            guard let undo = f.text.undoManager else { throw Failure(stage: "pair-Backspace-Undo") }
            try await c.events.perform { undo.undo() }
            try need(same(f.text.string, "{}"), "one-Undo-restores-complete-deleted-pair")
            try await c.events.perform { f.text.setSelectedRange(r(1)); f.text.deleteBackward(nil) }
            try need(same(f.text.string, "}"), "Undo-restored-unowned-close-is-not-deleted")
            try await c.events.perform { f.text.selectAll(nil); f.text.insertText("", replacementRange: r(NSNotFound)) }
            try await c.events.perform { f.text.insertText("[", replacementRange: r(NSNotFound)) }
            let generation = f.surface.generation, edits = f.edits
            f.proxy.deny = true
            try await c.events.perform { f.text.deleteBackward(nil) }
            try need(same(f.text.string, "[]") && f.edits == edits && f.surface.generation == generation,
                "denied-pair-Backspace-keeps-text-and-generation")
            f.proxy.deny = false; f.text.completesJSONBrackets = false
            try await c.events.perform { f.text.deleteBackward(nil) }
            try need(same(f.text.string, "]"), "disabled-pair-Backspace-uses-native-single-deletion")
        }
        await c.check("native-pair-Return-closing-skip-and-Undo", value: try value(""), selection: r(0)) { f in
            f.owner.selectLanguage(.jsonc)
            try await c.events.perform { f.text.insertText("{", replacementRange: r(NSNotFound)) }
            try await wait("pair-before-Return-native-event-group-ended") { f.text.undoManager?.groupingLevel == 0 }
            try await c.events.perform { f.text.insertNewline(nil) }
            try await wait("Return-native-event-group-ended") { f.text.undoManager?.groupingLevel == 0 }
            try need(same(f.text.string, "{\n    \n}") && f.text.selectedRange() == r(6) && f.edits == 2,
                "pair-and-Return-share-native-inner-caret")
            try await c.events.perform { f.text.insertText("}", replacementRange: r(NSNotFound)) }
            try need(same(f.text.string, "{\n    \n}") && f.text.selectedRange() == r(8) && f.edits == 2,
                "closing-key-crosses-only-empty-indentation-to-owned-close")
            guard let undo = f.text.undoManager else { throw Failure(stage: "pair-Return-Undo") }
            try await c.events.perform { undo.undo() }
            try need(same(f.text.string, "{}"), "one-Undo-removes-only-smart-Return")
            try await c.events.perform { undo.redo() }
            try need(same(f.text.string, "{\n    \n}"), "one-Redo-restores-complete-smart-Return")
            try await c.events.perform { undo.undo() }
            try await c.events.perform { f.text.setSelectedRange(r(1)); f.text.insertText("}", replacementRange: r(NSNotFound)) }
            try need(same(f.text.string, "{}}"), "Undo-discards-closing-provenance")
        }
        await c.check("native-leading-space-Backspace-Undo-preference-and-admission",
                      value: try value("{\n        \n}"), selection: r(10)) { f in
            f.owner.selectLanguage(.json)
            let original = f.text.string
            try await c.events.perform { f.text.deleteBackward(nil) }
            try need(same(f.text.string, "{\n    \n}") && f.text.selectedRange() == r(6) && f.edits == 1,
                "Backspace-removes-one-native-indent")
            guard let undo = f.text.undoManager else { throw Failure(stage: "indent-Backspace-Undo") }
            try await c.events.perform { undo.undo() }
            try need(same(f.text.string, original), "one-Undo-restores-indent")
            try await c.events.perform { undo.redo() }
            try need(same(f.text.string, "{\n    \n}"), "one-Redo-removes-indent")
            try await c.events.perform { f.text.setSelectedRange(r(6)) }
            let generation = f.surface.generation, edits = f.edits
            f.proxy.deny = true
            try await c.events.perform { f.text.deleteBackward(nil) }
            try need(same(f.text.string, "{\n    \n}") && f.edits == edits
                && f.surface.generation == generation && f.text.selectedRange() == r(6),
                "denied-unindent-keeps-native-text-and-caret")
            f.proxy.deny = false
            var preferences = EditorPreferences(); preferences.backspaceUnindents = false
            f.surface.applyEditorPreferences(preferences, pointSize: 13)
            try await c.events.perform { f.text.deleteBackward(nil) }
            try need(same(f.text.string, "{\n   \n}") && f.text.selectedRange() == r(5),
                "Backspace-opt-out-deletes-one-space")
            preferences.backspaceUnindents = true; f.surface.applyEditorPreferences(preferences, pointSize: 13)
            try await c.events.perform { f.text.deleteBackward(nil) }
            try need(same(f.text.string, "{\n\n}") && f.text.selectedRange() == r(2),
                "partial-indent-returns-to-previous-stop")
            try need(EditorIndentation.backspaceRange(in: "\t    " as NSString, selection: r(5), preferences: .fresh) == nil
                && EditorIndentation.backspaceRange(in: "word    " as NSString, selection: r(8), preferences: .fresh) == nil
                && EditorIndentation.backspaceRange(in: "    " as NSString, selection: r(2, 2), preferences: .fresh) == nil
                && EditorIndentation.backspaceRange(in: String(repeating: " ", count: 1025) as NSString,
                    selection: r(1025), preferences: .fresh) == nil,
                "mixed-content-selection-and-long-lookbehind-stay-native")
            try await c.events.perform { f.text.insertText("    ", replacementRange: r(2)) }
            f.owner.selectLanguage(.plain)
            try await c.events.perform { f.text.deleteBackward(nil) }
            try need(same(f.text.string, "{\n   \n}"), "plain-text-keeps-single-character-deletion")
        }
        for transition in ["selection", "language"] {
            await c.check("native-pair-provenance-invalidated-by-" + transition, value: try value(""), selection: r(0)) { f in
                f.owner.selectLanguage(.json)
                try await c.events.perform { f.text.insertText("{", replacementRange: r(NSNotFound)) }
                try await c.events.perform {
                    if transition == "selection" { f.text.setSelectedRange(r(0)); f.text.setSelectedRange(r(1)) }
                    else { f.owner.selectLanguage(.plain); f.owner.selectLanguage(.json) }
                    f.text.insertText("}", replacementRange: r(NSNotFound))
                }
                try need(same(f.text.string, "{}}") && f.edits == 2, "stale-pair-provenance-never-swallows-closing-input")
            }
        }
        await c.check("native-pair-opt-out-and-admission-denial", value: try value(""), selection: r(0)) { f in
            f.owner.selectLanguage(.json); f.proxy.deny = true
            try await c.events.perform { f.text.insertText("{", replacementRange: r(NSNotFound)) }
            try need(f.text.string.isEmpty && f.text.selectedRange() == r(0) && f.edits == 0
                && f.text.undoManager?.canUndo == false, "denied-pair-does-not-publish-text-caret-or-Undo")
            var preferences = EditorPreferences(); preferences.completesJSONBrackets = false
            f.surface.applyEditorPreferences(preferences, pointSize: 13); f.proxy.deny = false
            try await c.events.perform { f.text.insertText("{", replacementRange: r(NSNotFound)) }
            try need(same(f.text.string, "{") && f.edits == 1, "disabled-completion-keeps-native-opening-input")
        }
        await c.check("native-pair-preserves-selected-text-and-existing-close-intent", value: try value("{}"), selection: r(1)) { f in
            f.owner.selectLanguage(.json)
            try await c.events.perform { f.text.insertText("}", replacementRange: r(NSNotFound)) }
            try need(same(f.text.string, "{}}"), "unowned-document-close-does-not-skip")
            try await c.events.perform { f.text.selectAll(nil); f.text.insertText("[", replacementRange: r(NSNotFound)) }
            try need(same(f.text.string, "["), "selected-text-is-native-replacement-without-pairing")
        }
        await c.check("native-pair-closing-inside-string-and-marked-input", value: try value(""), selection: r(0)) { f in
            f.owner.selectLanguage(.json)
            try await c.events.perform { f.text.insertText("{", replacementRange: r(NSNotFound)) }
            try await c.events.perform { f.text.insertText("\"", replacementRange: r(NSNotFound)) }
            try await c.events.perform { f.text.insertText("}", replacementRange: r(NSNotFound)) }
            try need(same(f.text.string, "{\"}}") && f.edits == 3 && f.text.selectedRange() == r(3),
                "owned-close-inside-new-string-is-literal-input")
            try await c.events.perform {
                f.text.setMarkedText("[", selectedRange: r(1), replacementRange: r(0, 4))
            }
            try need(f.text.hasMarkedText() && same(f.text.string, "["), "marked-bracket-does-not-complete")
            try await c.events.perform { f.text.unmarkText() }
        }
        await c.check("native-JSON-smart-Return-one-Undo-Redo", value: try value("  \"🧭\": [   ]"), selection: r(9)) { f in
            f.owner.selectLanguage(.json)
            try await c.events.perform { f.text.insertNewline(nil) }
            let expanded = "  \"🧭\": [\n      \n  ]"
            try need(same(f.text.string, expanded) && f.text.selectedRange() == r(16)
                && f.edits == 1 && f.proxy.calls == 1, "smart-Return-native-single-edit-inner-caret")
            guard let undo = f.text.undoManager else { throw Failure(stage: "smart-Return-Undo-manager") }
            try await c.events.perform { undo.undo() }
            try need(same(f.text.string, "  \"🧭\": [   ]") && !undo.canUndo && undo.canRedo,
                "smart-Return-one-Undo-exact-original")
            try await c.events.perform { undo.redo() }
            try need(same(f.text.string, expanded) && f.text.selectedRange() == r(16)
                && !undo.canRedo, "smart-Return-one-Redo-restores-inner-caret")
        }
        for (language, source, cursor, inserted) in [
            (TextSyntaxLanguage.swift, "func sample() {}", "func sample() {", "\n    \n"),
            (.python, "async def sample(\n    name: str\n):", "async def sample(\n    name: str\n):", "\n    "),
            (.rust, "fn sample<'a>(value: &'a str) {}", "fn sample<'a>(value: &'a str) {", "\n    \n"),
            (.javascript, "const invoke = () => {}", "const invoke = () => {", "\n    \n"),
            (.typescript, "interface Sample {}", "interface Sample {", "\n    \n"),
            (.c, "int sample(void) {}", "int sample(void) {", "\n    \n"),
            (.cpp, "namespace Sample {}", "namespace Sample {", "\n    \n"),
            (.objectiveC, "- (void)sample {}", "- (void)sample {", "\n    \n"),
            (.objectiveCPP, "void Sample::invoke() {}", "void Sample::invoke() {", "\n    \n"),
            (.go, "func example() {}", "func example() {", "\n    \n"),
            (.css, ".sample {}", ".sample {", "\n    \n")
        ] {
            let caret = cursor.utf16.count
            let expected = cursor + inserted + String(source.dropFirst(cursor.count))
            await c.check("native-\(language.rawValue)-block-Return", value: try value(source), selection: r(caret)) { f in
                f.owner.selectLanguage(language)
                try await c.events.perform { f.text.insertNewline(nil) }
                try need(same(f.text.string, expected) && f.text.selectedRange() == r(caret + 5)
                    && f.edits == 1, "code-block-Return-one-native-edit")
                guard let undo = f.text.undoManager else { throw Failure(stage: "code-block-Return-Undo-manager") }
                try await c.events.perform { undo.undo() }
                try need(same(f.text.string, source) && undo.canRedo, "code-block-Return-restores-original")
                try await c.events.perform { undo.redo() }
                try need(same(f.text.string, expected) && f.text.selectedRange() == r(caret + 5), "code-block-Return-restores-caret")
            }
        }
        let rustRaw = "let data = r#\"generated {}\"#;"
        let rustOpening = (rustRaw as NSString).range(of: "{").location + 1
        await c.check("native-Rust-Return-preserves-raw-string-braces", value: try value(rustRaw), selection: r(rustOpening)) { f in
            f.owner.selectLanguage(.rust)
            try await c.events.perform { f.text.insertNewline(nil) }
            let expected = (rustRaw as NSString).replacingCharacters(in: r(rustOpening), with: "\n")
            try need(same(f.text.string, expected) && f.text.selectedRange() == r(rustOpening + 1)
                && f.edits == 1, "Rust-raw-string-gets-ordinary-newline")
        }
        await c.check("native-smart-Return-denial-preserves-selection", value: try value("{}"), selection: r(1)) { f in
            f.owner.selectLanguage(.json); f.proxy.deny = true
            let generation = f.surface.generation
            try await c.events.perform { f.text.insertNewline(nil) }
            try need(same(f.text.string, "{}") && f.text.selectedRange() == r(1) && f.edits == 0
                && f.surface.generation == generation && f.proxy.calls == 1 && f.text.undoManager?.canUndo == false,
                "denied-smart-Return-keeps-buffer-caret-generation-Undo")
        }
        await c.check("native-smart-Return-legacy-default-and-explicit-opt-out", value: try value("{}"), selection: r(1)) { f in
            f.owner.selectLanguage(.json)
            var preferences = EditorPreferences(); preferences.indentation = .legacy
            f.surface.applyEditorPreferences(preferences, pointSize: 13)
            try await c.events.perform { f.text.insertNewline(nil) }
            try await wait("legacy-JSON-Return-native-event-group-ended") { f.text.undoManager?.groupingLevel == 0 }
            try need(same(f.text.string, "{\n\t\n}") && f.text.selectedRange() == r(3) && f.edits == 1
                && f.surface.indentationPreferences == .legacy,
                "legacy-continuation-off-keeps-choice-and-gets-new-JSON-block-default")
            guard let undo = f.text.undoManager else { throw Failure(stage: "legacy-JSON-Return-Undo") }
            try await c.events.perform { undo.undo() }
            try need(same(f.text.string, "{}") && !undo.canUndo, "legacy-JSON-Return-is-one-native-Undo")
            preferences.indentsJSONBlocks = false
            f.surface.applyEditorPreferences(preferences, pointSize: 13)
            try await c.events.perform { f.text.setSelectedRange(r(1)); f.text.insertNewline(nil) }
            try need(same(f.text.string, "{\n}") && f.text.selectedRange() == r(2) && f.edits == 3
                && f.surface.indentationPreferences == .legacy && !f.text.indentsJSONBlocks,
                "explicit-new-JSON-opt-out-keeps-native-newline-with-old-continuation-off")
        }
        await c.check("smart-Return-discards-held-line-command", value: try value("{}"), selection: r(1)) { f in
            f.owner.selectLanguage(.json)
            let gate = f.hold()
            try await c.events.perform { try f.send(0); try f.send(0) }; try await c.gateEntered(gate)
            try await c.events.perform { f.text.insertNewline(nil) }
            let generation = f.surface.generation
            await gate.release(); try await c.drain(f)
            try need(same(f.text.string, "{\n    \n}") && f.text.selectedRange() == r(6)
                && f.edits == 1 && f.surface.generation == generation && f.probe.snapshot.preparations == 1,
                "Return-does-not-deliver-or-replay-stale-prepared-lines")
        }
        let lastEditText = "Header\n🧭 let value = 3\nFooter\n"
        let lastEditValue = try value(lastEditText)
        let editOffset = (lastEditText as NSString).range(of: "3").location
        await c.check("go-to-last-native-edit", value: lastEditValue, selection: r(0)) { f in
            guard let last = UIVerification.menuItem("Go", "Go to Last Edit"), let jump = last.action,
                  let previous = f.owner.discoverableCommands().first(where: { $0.0.title == "Previous Text Location" })?.0,
                  let back = previous.action else { throw Failure(stage: "last-edit-native-commands") }
            try await c.events.perform {
                try need(!f.owner.validateUserInterfaceItem(last), "last-edit-disabled-on-initial-load")
                f.text.insertText("42", replacementRange: r(editOffset, 1))
                f.text.breakUndoCoalescing()
                try f.presentCurrentLines()
                let origin = r(f.text.string.utf16.count)
                f.text.setSelectedRange(origin)
                try need(f.owner.validateUserInterfaceItem(last) && NSApp.sendAction(jump, to: f.owner, from: last)
                    && f.text.selectedRange() == r(editOffset), "last-edit-exact-native-offset-after-replacement")
                try need(f.owner.validateUserInterfaceItem(previous) && NSApp.sendAction(back, to: f.owner, from: previous)
                    && f.text.selectedRange() == origin && f.edits == 1, "last-edit-uses-existing-navigation-history")
                try need(f.text.undoManager?.canUndo == true, "last-edit-keeps-native-undo")
                f.text.undoManager?.undo()
                try f.presentCurrentLines()
                f.text.setSelectedRange(r(0))
                try need(same(f.text.string, lastEditText) && f.owner.validateUserInterfaceItem(last)
                    && NSApp.sendAction(jump, to: f.owner, from: last) && f.text.selectedRange() == r(editOffset),
                    "last-edit-follows-native-undo-without-changing-text")
                f.surface.install(lastEditValue)
                try need(!f.owner.validateUserInterfaceItem(last), "last-edit-cleared-on-reload")
            }
        }
        let bookmarkSource = "A\n🧭 First landmark\nMiddle\nSecond landmark\nEnd\n"
        let bookmarkValue = try value(bookmarkSource)
        await c.check("line-bookmarks-follow-native-edits", value: bookmarkValue, selection: r(2)) { f in
            guard let bookmarks = UIVerification.menuItem("Go", "Line Bookmarks")?.submenu,
                  let toggle = bookmarks.item(withTitle: "Toggle Line Bookmark"),
                  let show = bookmarks.item(withTitle: "Choose Line Bookmark…") else { throw Failure(stage: "bookmark-native-menu") }
            @MainActor func send(_ command: NSMenuItem) throws {
                guard let action = command.action, f.owner.validateUserInterfaceItem(command),
                      NSApp.sendAction(action, to: f.owner, from: command) else { throw Failure(stage: "bookmark-native-action") }
            }
            try await c.events.perform {
                try need(!f.owner.validateUserInterfaceItem(show), "new-editor-has-no-bookmarks")
                try send(toggle)
                guard let second = f.surface.lineIndex?.start(ofLine: 4) else { throw Failure(stage: "bookmark-generated-line") }
                f.text.setSelectedRange(r(second))
                try send(toggle)
                try need(f.surface.bookmarkedLines == [2, 4] && f.edits == 0, "bookmark-markers-do-not-edit-the-text")
                f.text.insertText("Header above\nAdded Context\n", replacementRange: r(0))
                f.text.breakUndoCoalescing()
                try f.presentCurrentLines()
                f.facts["shiftedBookmarkLines"] = f.surface.bookmarkedLines
                try need(f.surface.bookmarkedLines == [4, 6], "bookmark-points-follow-prefix-with-two-new-lines")
                f.text.setSelectedRange(r(0))
                let key = String(UnicodeScalar(NSF2FunctionKey)!)
                try need(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key(key, code: 120, flags: [], window: f.native)) == true
                    && f.text.selectedRange().location == f.surface.lineIndex?.start(ofLine: 4), "bookmark-next-native-F2")
                try send(show)
            }
            try await wait("visible-line-bookmark-picker") { f.native.attachedSheet?.isKeyWindow == true }
            guard let sheet = f.native.attachedSheet else { throw Failure(stage: "bookmark-picker-missing") }
            let before = f.text.selectedRange()
            try await c.events.perform { sheet.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: sheet)) }
            try await wait("line-bookmark-picker-cancelled") { f.native.attachedSheet == nil && f.owner.validateUserInterfaceItem(show) }
            try need(f.text.selectedRange() == before, "bookmark-cancel-keeps-caret")
            try await c.events.perform { try send(show) }
            try await wait("line-bookmark-picker-reopened") { f.native.attachedSheet?.isKeyWindow == true }
            guard let reopened = f.native.attachedSheet else { throw Failure(stage: "bookmark-reopened-picker-missing") }
            if let output = c.evidenceDirectory {
                try await UIVerification.snapshot(reopened, to: output.appendingPathComponent("editor-line-bookmark-picker.png"))
            }
            try await c.events.perform {
                reopened.sendEvent(UIVerification.key("\u{f701}", code: 125, flags: [], window: reopened))
                reopened.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: reopened))
            }
            try await wait("line-bookmark-selected-from-picker") {
                f.native.attachedSheet == nil && f.text.selectedRange().location == f.surface.lineIndex?.start(ofLine: 6)
            }
            try await c.events.perform {
                f.text.undoManager?.undo()
                try f.presentCurrentLines()
                try need(same(f.text.string, bookmarkSource) && f.surface.bookmarkedLines == [2, 4], "bookmark-points-follow-native-undo")
                f.text.setSelectedRange(r(2))
                try send(toggle)
                try need(f.surface.bookmarkedLines == [4], "bookmark-toggle-removes-the-one-mark")
                f.text.insertText("Replacement document\n", replacementRange: r(0, f.text.string.utf16.count))
                try f.presentCurrentLines()
                try need(f.surface.bookmarkedLines.isEmpty, "bookmark-full-replacement-clears-unbound-lines")
                f.text.setSelectedRange(r(0))
                try send(toggle)
                f.surface.install(bookmarkValue)
                try need(!f.owner.validateUserInterfaceItem(show) && f.surface.bookmarkedLines.isEmpty, "bookmark-cleared-on-reload")
            }
        }
        let occurrenceSource = "let café = caféCount\nlet Café = café\n"
        let occurrenceValue = try value(occurrenceSource)
        await c.check("replace-occurrences-seeds-native-review", value: occurrenceValue, selection: r(4, 4)) { f in
            guard let item = UIVerification.menuItem("Edit", "Replace Occurrences in File…"), let action = item.action else {
                throw Failure(stage: "replace-occurrences-native-command")
            }
            let find = f.surface.find
            try await c.events.perform {
                find.findInSelection()
                find.bar.replacement.stringValue = "Previous replacement"
                f.text.setSelectedRange(r(6))
                try need(f.native.makeFirstResponder(f.text), "replace-occurrences-in-editor")
                try need(f.owner.validateUserInterfaceItem(item) && NSApp.sendAction(action, to: f.owner, from: item),
                    "replace-occurrences-from-caret")
                try need(find.bar.query.stringValue == "café" && find.bar.replacement.stringValue.isEmpty
                    && find.currentOptions.matchesCase && find.currentOptions.matchMode == .wholeWord
                    && find.bar.replacement.currentEditor() === f.native.firstResponder
                    && f.text.selectedRange() == r(6) && f.edits == 0, "replace-occurrences-prefills-native-review-without-an-edit")
            }
            try await wait("replace-occurrences-ready") { find.matchCount == 2 && find.bar.replaceAll.isEnabled }
            try await c.events.perform {
                for character in "value" {
                    f.native.sendEvent(UIVerification.key(String(character), code: 0, flags: [], window: f.native))
                }
                try need(find.bar.replacement.stringValue == "value", "replace-occurrences-native-typing")
                find.bar.replaceAll.performClick(nil)
            }
            try await c.drain(f)
            try need(same(f.text.string, "let value = caféCount\nlet Café = value\n") && f.edits == 1,
                "replace-occurrences-whole-case-matches-only")
            try await c.events.perform {
                f.text.undoManager?.undo()
                try need(same(f.text.string, occurrenceSource) && f.edits == 2,
                    "replace-occurrences-one-native-undo")
                f.text.setSelectedRange(r(0, 8))
                try need(f.native.makeFirstResponder(f.text) && f.owner.validateUserInterfaceItem(item)
                    && NSApp.sendAction(action, to: f.owner, from: item), "replace-occurrences-from-selection")
                try need(find.bar.query.stringValue == "let café" && find.currentOptions.matchMode == .contains,
                    "replace-occurrences-literal-selection")
            }
        }
        await c.check("single-find-replacement-preserves-other-lines", value: occurrenceValue, selection: r(0)) { f in
            guard let bookmark = UIVerification.menuItem("Go", "Line Bookmarks")?.submenu?.item(withTitle: "Toggle Line Bookmark"),
                  let toggle = bookmark.action else { throw Failure(stage: "find-replacement-bookmark-command") }
            let find = f.surface.find
            let line = (occurrenceSource as NSString).range(of: "let Café")
            try await c.events.perform {
                f.text.setSelectedRange(r(line.location))
                try need(f.owner.validateUserInterfaceItem(bookmark) && NSApp.sendAction(toggle, to: f.owner, from: bookmark),
                    "find-replacement-mark-second-line")
                f.text.setSelectedRange(r(4, 4))
                find.bar.query.stringValue = "café"
                find.bar.replacement.stringValue = "longName"
                find.perform(.showReplaceInterface)
            }
            try await wait("single-find-replacement-ready") { find.matchCount > 0 && find.bar.replace.isEnabled }
            try await c.events.perform { find.bar.replace.performClick(nil) }
            try await c.drain(f)
            try f.presentCurrentLines()
            try need(same(f.text.string, "let longName = caféCount\nlet Café = café\n") && f.edits == 1
                && f.proxy.admissions == [["location": 4, "length": 4, "replacementUTF16": 8]]
                && f.surface.bookmarkedLines == [2], "find-replace-admits-only-the-match-and-retains-bookmark")
            try await c.events.perform {
                f.text.undoManager?.undo()
                try f.presentCurrentLines()
                try need(same(f.text.string, occurrenceSource) && f.surface.bookmarkedLines == [2] && f.edits == 2,
                    "localized-replacement-undo-preserves-other-line-mark")
            }
        }
        let scopeText = """
        func outer() {
            let token = 0
            func
            inner() {
                let token = 1
            }
            let token = 2
        }
        """ + "\n"
        let innerLine = (scopeText as NSString).range(of: "let token = 1").location
        await c.check("find-in-current-outline-scope", value: try value(scopeText), selection: r(innerLine)) { f in
            f.owner.selectLanguage(.swift)
            let generation = f.surface.generation
            let input = EditorPreparationInput.presentation(ticket: nil, surfaceGeneration: generation, text: scopeText,
                format: f.surface.documentFormat, language: .swift)
            let prepared = await Task.detached { EditorPreparationOwner.prepare(input, .init()) }.value
            guard case .presentation(let presentation) = prepared,
                  f.surface.present(presentation, for: generation),
                  let command = UIVerification.menuItem("Edit", "Search Scope", "Find in Current Scope…"), let action = command.action else {
                throw Failure(stage: "find-outline-native-presentation")
            }
            let find = f.surface.find
            try await c.events.perform {
                f.native.setContentSize(f.native.contentMinSize)
                find.applyInterfaceScale(1.5)
                find.bar.query.stringValue = "token"
                try need(f.surface.currentSearchScope?.name == "inner" && f.owner.validateUserInterfaceItem(command)
                    && NSApp.sendAction(action, to: f.owner, from: command), "find-outline-selects-innermost-scope")
                try need(f.text.selectedRange() == r(innerLine) && find.bar.query.placeholderString == "Find in inner"
                    && find.bar.options.item(at: 0)?.title == "In inner"
                    && find.bar.options.toolTip == "Search only in inner", "find-outline-scope-visible-without-moving-editor-caret")
            }
            try await wait("find-outline-one-match") { find.matchCount == 1 && !find.isWorking }
            if let output = c.evidenceDirectory {
                try await UIVerification.snapshot(f.native, to: output.appendingPathComponent("editor-find-current-scope.png"))
            }
            try await c.events.perform {
                find.perform(.showReplaceInterface)
                find.bar.replacement.stringValue = "value"
                try need(find.bar.replaceAll.isEnabled, "find-outline-replace-ready")
                find.bar.replaceAll.performClick(nil)
            }
            try await c.drain(f)
            let expected = scopeText.replacingOccurrences(of: "let token = 1", with: "let value = 1")
            try need(same(f.text.string, expected) && f.edits == 1 && find.matchCount == 0 && !find.bar.replaceAll.isEnabled
                && find.bar.count.stringValue == "Scope changed", "find-outline-replaces-only-inside-and-expires")
            guard let document = find.bar.options.menu?.item(withTitle: "Search Whole Document"), let rescope = document.action else {
                throw Failure(stage: "find-outline-document-option")
            }
            try await c.events.perform {
                try need(NSApp.sendAction(rescope, to: document.target, from: document), "find-outline-explicit-document-scope")
            }
            try await wait("find-outline-whole-document-restored") { find.matchCount == 2 && !find.isWorking }
            try await c.events.perform {
                f.text.undoManager?.undo()
                try need(same(f.text.string, scopeText) && f.edits == 2, "find-outline-one-native-undo")
            }
        }
        let brackets = "let value = ({[\"😀}\": 1] /* ) ] } */ })\n"
        let source = brackets as NSString
        let openBrace = source.range(of: "{[").location
        let closeBrace = source.range(of: "})\n").location
        let closeSquare = source.range(of: "] /*").location
        await c.check("native-bracket-navigation-ignores-strings-and-comments", value: try value(brackets), selection: r(openBrace)) { f in
            f.owner.selectLanguage(.swift)
            @MainActor func command(_ title: String) throws {
                guard let item = f.owner.discoverableCommands().first(where: { $0.0.title == title })?.0,
                      let action = item.action, f.owner.validateUserInterfaceItem(item) else { throw Failure(stage: "bracket-native-menu") }
                try need(NSApp.sendAction(action, to: item.target, from: item), "bracket-native-menu-dispatch")
            }
            let generation = f.surface.generation
            try await c.events.perform {
                let key = UIVerification.key("\\", code: 42, flags: [.command, .shift], window: f.native)
                try need(NSApp.mainMenu?.performKeyEquivalent(with: key) == true, "matching-bracket-native-key-equivalent")
            }
            try await c.drain(f)
            try need(f.text.selectedRange() == r(closeBrace), "bracket-skips-quoted-and-comment-braces")
            try await c.events.perform { try command("Previous Text Location") }
            try need(f.text.selectedRange() == r(openBrace), "bracket-jump-previous-restores-original-caret")
            try await c.events.perform { try command("Next Text Location") }
            try need(f.text.selectedRange() == r(closeBrace), "bracket-jump-next-restores-matching-caret")
            try await c.events.perform { f.text.isEditable = false; try command("Go to Matching Bracket") }; try await c.drain(f)
            try need(f.text.selectedRange() == r(openBrace), "bracket-navigation-works-in-read-only-text")
            try await c.events.perform {
                f.text.setSelectedRange(r(source.range(of: "😀").location))
                try command("Select Inside Brackets")
            }
            try await c.drain(f)
            try need(f.text.selectedRange() == r(openBrace + 2, closeSquare - openBrace - 2), "bracket-selects-innermost-body")
            try await c.events.perform { try command("Select Inside Brackets") }; try await c.drain(f)
            try need(f.text.selectedRange() == r(openBrace + 1, closeBrace - openBrace - 1), "bracket-selection-expands-to-parent")
            let input = EditorPreparationInput.presentation(ticket: nil, surfaceGeneration: generation, text: brackets,
                format: f.surface.documentFormat, language: .swift)
            let prepared = await Task.detached { EditorPreparationOwner.prepare(input, .init()) }.value
            guard case .presentation(let style) = prepared, f.surface.present(style, for: generation) else {
                throw Failure(stage: "expand-selection-current-syntax")
            }
            let string = source.range(of: "\"😀}\"")
            try await c.events.perform {
                f.text.setSelectedRange(string)
                let key = UIVerification.key("\u{f703}", code: 124, flags: [.command, .control, .shift], window: f.native)
                try need(NSApp.mainMenu?.performKeyEquivalent(with: key) == true, "expand-selection-uses-native-shortcut")
            }
            try await c.drain(f)
            let inside = r(openBrace + 2, closeSquare - openBrace - 2)
            try need(f.text.selectedRange() == inside, "expand-selection-inner-brackets-in-read-only-editor")
            let viewport = f.surface.scrollView.contentView.bounds.origin
            try await c.events.perform { try command("Expand Selection") }; try await c.drain(f)
            try need(f.text.selectedRange() == r(openBrace + 1, closeSquare - openBrace), "expand-selection-includes-brackets")
            try await c.events.perform { try command("Shrink Selection") }
            try need(f.text.selectedRange() == inside && f.surface.scrollView.contentView.bounds.origin == viewport,
                "shrink-selection-restores-prior-range-and-viewport")
            try await c.events.perform { f.owner.findEditorCommand(nil) }
            try await wait("shrink-selection-command-finder-is-key") { f.owner.commandFinder.window?.isKeyWindow == true }
            try await c.events.perform {
                f.owner.commandFinder.query.stringValue = "shrink selection"
                f.owner.commandFinder.updateMatches()
                try need(f.owner.commandFinder.matches.count == 1, "shrink-selection-discoverable")
                f.facts["shrink-listed-enabled"] = f.owner.commandFinder.matches.first?.enabled == true
                f.owner.commandFinder.activateSelection(nil)
                f.facts["shrink-immediate-key"] = f.native.isKeyWindow
                f.facts["shrink-immediate-focus"] = f.native.firstResponder === f.text
            }
            do { try await wait("shrink-selection-from-command-finder") { f.native.isKeyWindow && f.text.selectedRange() == string } }
            catch {
                f.facts["shrink-retained-trail"] = f.surface.lineCommands.canAdjustSelection(.shrink)
                f.facts["shrink-panel-remaining"] = f.owner.commandFinder.window != nil
                throw error
            }
            try need(f.text.selectedRange() == string && !f.surface.lineCommands.canAdjustSelection(.shrink),
                "shrink-selection-restores-original-literal")
            try await c.events.perform { try command("Expand Selection") }; try await c.drain(f)
            try await c.events.perform { f.text.setSelectedRange(r(2)) }
            try need(!f.surface.lineCommands.canAdjustSelection(.shrink), "a-new-selection-retires-the-expansion-trail")
            let gate = f.hold()
            try await c.events.perform { f.text.setSelectedRange(r(openBrace)); try command("Go to Matching Bracket") }
            try await c.gateEntered(gate)
            try await c.events.perform { f.text.setSelectedRange(r(1)) }
            await gate.release(); try await c.drain(f)
            try need(f.text.selectedRange() == r(1) && f.surface.generation == generation && f.edits == 0
                && f.proxy.calls == 0 && same(f.text.string, brackets) && f.text.undoManager?.canUndo == false,
                "stale-navigation-keeps-caret-text-and-Undo")
            let match = EditorLineCommand.navigateBrackets(.matching, .jsonc)
            try need(EditorLineCommands.plan(match, text: "[/* ] */1]", selection: r(0), maximumBytes: 64) == .select(r(9))
                && EditorLineCommands.plan(match, text: "([)]", selection: r(0), maximumBytes: 64) == .refused(.noMatchingBracket),
                "JSONC-bracket-lexing-and-mismatched-refusal")
            let rust = "fn sample<'a>() { let raw = r#\"}\"#; let ch = '}'; /* {} */ }"
            let rustOpen = (rust as NSString).range(of: "{").location
            try need(EditorLineCommands.plan(.navigateBrackets(.matching, .rust), text: rust,
                selection: r(rustOpen), maximumBytes: 128) == .select(r(rust.utf16.count - 1)),
                "Rust-bracket-skips-raw-and-character-literals-and-comments")
        }
        let surroundOriginal = "keep 😀e\u{301}\nsecond\ntail"
        let surrounded = "😀e\u{301}\nsecond"
        let surroundRange = (surroundOriginal as NSString).range(of: surrounded)
        await c.check("native-surround-selection-all-pairs-Unicode-Undo-and-admission", value: try value(surroundOriginal),
                      selection: surroundRange) { f in
            guard let undo = f.text.undoManager else { throw Failure(stage: "surround-native-Undo") }
            try await c.events.perform { f.owner.findEditorCommand(nil) }
            try await wait("surround-command-finder-is-key") { f.owner.commandFinder.window?.isKeyWindow == true }
            try await c.events.perform {
                f.owner.commandFinder.query.stringValue = "surround parentheses"
                f.owner.commandFinder.updateMatches()
                try need(f.owner.commandFinder.matches.count == 1, "nested-category-command-search")
                f.owner.commandFinder.activateSelection(nil)
            }
            try await c.drain(f)
            try need(same(f.text.string, (surroundOriginal as NSString).replacingCharacters(in: surroundRange,
                with: "(" + surrounded + ")")), "command-finder-dispatches-real-surround-menu")
            try await c.events.perform { undo.undo(); f.text.setSelectedRange(surroundRange) }; try await c.drain(f)
            for pair in EditorSurroundingPair.allCases {
                let item = try f.surroundItem(pair)
                try need(f.owner.validateUserInterfaceItem(item), "selected-surround-command-is-enabled")
                try await c.events.perform { try need(NSApp.sendAction(item.action!, to: item.target, from: item), "native-surround-dispatch") }
                try await c.drain(f)
                let expected = (surroundOriginal as NSString).replacingCharacters(in: surroundRange,
                    with: pair.open + surrounded + pair.close)
                try need(same(f.text.string, expected) && f.text.selectedRange() == r(surroundRange.location + 1, surroundRange.length)
                    && undo.undoActionName == "Surround Selection", "surround-keeps-selected-exact-Unicode-and-line-endings")
                try await c.events.perform { undo.undo() }; try await c.drain(f)
                try need(same(f.text.string, surroundOriginal) && !undo.canUndo, "surround-is-one-native-Undo")
                try await c.events.perform { f.text.setSelectedRange(surroundRange) }
            }
            let item = try f.surroundItem(.braces)
            try await c.events.perform { f.text.isEditable = false }
            try need(!f.owner.validateUserInterfaceItem(item), "readonly-surround-command-disabled")
            try await c.events.perform { _ = NSApp.sendAction(item.action!, to: item.target, from: item); f.text.isEditable = true; f.text.setSelectedRange(r(0)) }
            try need(!f.owner.validateUserInterfaceItem(item), "empty-selection-surround-disabled")
            try await c.events.perform { _ = NSApp.sendAction(item.action!, to: item.target, from: item) }
            try await c.drain(f)
            try need(same(f.text.string, surroundOriginal) && !undo.canUndo, "readonly-and-empty-selection-do-not-mutate")
            try need(EditorLineCommands.plan(.surroundSelection(.doubleQuotes), text: "😀", selection: r(1, 1), maximumBytes: 16)
                == .refused(.invalidSelection), "surround-refuses-split-surrogate")
            try need(EditorLineCommands.plan(.surroundSelection(.braces), text: "data", selection: r(0, 4), maximumBytes: 5)
                == .refused(.tooLarge), "surround-refuses-growth-beyond-byte-bound")
        }
        let sortable = "keep\nitem10\nitem2\nItem2\nitem1\ntail"
        await c.check("native-selected-natural-sort-stable-ties-Undo", value: try value(sortable),
                      selection: (sortable as NSString).range(of: "item10\nitem2\nItem2\nitem1\n")) { f in
            try await c.events.perform { try f.send(6) }; try await c.drain(f)
            let ascending = "keep\nitem1\nitem2\nItem2\nitem10\ntail"
            try need(same(f.text.string, ascending) && f.edits == 1, "sort-selection-changed-surroundings-or-numeric-ties")
            guard let undo = f.text.undoManager else { throw Failure(stage: "sort-native-Undo") }
            try need(undo.undoActionName == "Sort Lines Ascending", "sort-native-Undo-name")
            try await c.events.perform { undo.undo() }; try await c.drain(f)
            try need(same(f.text.string, sortable) && !undo.canUndo, "sort-not-one-native-Undo")
            try await c.events.perform { undo.redo() }; try await c.drain(f)
            // Native Redo leaves a caret at the replaced region's end. Select
            // the lines again, as a user does before another sort command.
            try await c.events.perform {
                f.text.setSelectedRange((f.text.string as NSString).range(of: "item1\nitem2\nItem2\nitem10\n"))
                try f.send(7)
            }; try await c.drain(f)
            try need(same(f.text.string, sortable) && undo.undoActionName == "Sort Lines Descending", "descending-sort-or-stable-ties")
            try await c.events.perform { undo.undo() }; try await c.drain(f)
            try need(same(f.text.string, ascending), "descending-sort-Undo")
            try need(EditorLineCommands.plan(.sortSelectedLines(descending: false), text: "only\nnext", selection: r(1), maximumBytes: 32) == .unchanged,
                "caret-only-sort-changed-document")
        }
        let padded = "  🧭  \t\nkeep\u{00a0}\n \t\nlast\t"
        await c.check("native-trim-whitespace-Unicode-selection-Undo", value: try value(padded),
                      selection: (padded as NSString).range(of: "🧭  \t")) { f in
            try await c.events.perform { try f.send(8) }; try await c.drain(f)
            let trimmed = "  🧭\nkeep\u{00a0}\n\nlast"
            try need(same(f.text.string, trimmed) && f.text.selectedRange() == r(2, 2) && f.edits == 1,
                "trim-lost-indentation-newlines-nonbreaking-space-or-Unicode-selection")
            guard let undo = f.text.undoManager else { throw Failure(stage: "trim-native-Undo") }
            try need(undo.undoActionName == "Trim Trailing Whitespace", "trim-native-Undo-name")
            try await c.events.perform { undo.undo() }; try await c.drain(f)
            try need(same(f.text.string, padded) && !undo.canUndo, "trim-not-one-native-Undo")
            try await c.events.perform { undo.redo() }; try await c.drain(f)
            let edits = f.edits
            try await c.events.perform { try f.send(8) }; try await c.drain(f)
            try need(same(f.text.string, trimmed) && f.edits == edits, "repeated-trim-created-edit")
        }
        let json = "{\"z\":9007199254740993,\"z\":-0,\"name\":\"Orion 🧭\\n\",\"array\":[true,null,{\"v\":1e+09}]}"
        await c.check("native-JSON-format-compact-Undo-tokens-selection", value: try value(json),
                      selection: (json as NSString).range(of: "Orion 🧭")) { f in
            guard let edit = UIVerification.menuItem("Edit", "JSON")?.submenu,
                  let format = edit.item(withTitle: "Format JSON"), let compact = edit.item(withTitle: "Compact JSON"),
                  let action = format.action else { throw Failure(stage: "actual-JSON-menu") }
            try need(!f.owner.validateUserInterfaceItem(format), "non-JSON-format-disabled")
            f.owner.selectLanguage(.json)
            try need(f.owner.validateUserInterfaceItem(format), "JSON-format-disabled")
            try await c.events.perform { try need(NSApp.sendAction(action, to: format.target, from: format), "native-JSON-format-action") }
            try await c.drain(f)
            let formatted = f.text.string
            try need(formatted.contains("\n    \"z\": 9007199254740993,") && formatted.contains("\"z\": -0,")
                && formatted.contains("\"v\": 1e+09") && formatted.contains("Orion 🧭\\n")
                && (formatted as NSString).substring(with: f.text.selectedRange()) == "Orion 🧭", "JSON-format-changed-tokens-or-selection")
            guard let undo = f.text.undoManager else { throw Failure(stage: "JSON-Undo-manager") }
            try need(undo.undoActionName == "Format JSON" && f.edits == 1, "JSON-not-one-native-edit")
            try await c.events.perform { undo.undo() }; try await c.drain(f)
            try need(same(f.text.string, json) && !undo.canUndo, "JSON-Undo-lost-original")
            try await c.events.perform { undo.redo() }; try await c.drain(f)
            try need(same(f.text.string, formatted), "JSON-Redo-lost-formatted")
            try await c.events.perform { try need(NSApp.sendAction(action, to: compact.target, from: compact), "native-JSON-compact-action") }
            try await c.drain(f)
            try need(same(f.text.string, json) && undo.undoActionName == "Compact JSON", "compact-JSON-lost-original-token-spellings")
            f.owner.selectLanguage(.jsonc)
            try need(f.owner.validateUserInterfaceItem(format), "JSONC-format-enabled")
            try need(EditorJSONFormatting.plan(.indented(.fresh), text: "{\"x\":[1,2,3]}", selection: r(0), maximumBytes: 13) == .refused(.tooLarge), "formatted-byte-cap")
            try need(EditorJSONFormatting.plan(.compact, text: json, selection: r(Int.max, Int.max), maximumBytes: 1024) == .refused(.invalidSelection), "format-range-overflow")
        }
        let jsonc = "// Keep this configuration comment.\n{\"n\":9007199254740993,/* Keep 🧭 exactly. */\"name\":\"Orion 🧭\",\"url\":\"https://example.invalid/*literal*/\",\"array\":[true,null,],\"n\":-0,} // Keep the ending.\n"
        await c.check("native-JSONC-comments-trailing-commas-compact-Undo", value: try value(jsonc),
                      selection: (jsonc as NSString).range(of: "Orion 🧭")) { f in
            f.owner.selectLanguage(.jsonc)
            guard let menu = UIVerification.menuItem("Edit", "JSON")?.submenu,
                  let format = menu.item(withTitle: "Format JSON"), let compact = menu.item(withTitle: "Compact JSON"),
                  let action = format.action, let undo = f.text.undoManager else { throw Failure(stage: "JSONC-native-menu") }
            try await c.events.perform { try need(NSApp.sendAction(action, to: format.target, from: format), "JSONC-format-action") }
            try await c.drain(f)
            let formatted = f.text.string
            try need(formatted.contains("// Keep this configuration comment.\n{\n    \"n\": 9007199254740993,")
                && formatted.contains("/* Keep 🧭 exactly. */") && formatted.contains("\"url\": \"https://example.invalid/*literal*/\"")
                && formatted.contains("        null,\n    ],") && formatted.contains("\"n\": -0,\n}")
                && formatted.contains("// Keep the ending.\n")
                && (formatted as NSString).substring(with: f.text.selectedRange()) == "Orion 🧭",
                "JSONC-format-lost-comments-token-spellings-trailing-commas-or-Unicode-selection")
            try need(f.edits == 1 && undo.undoActionName == "Format JSON", "JSONC-single-native-edit")
            if let evidence = c.evidenceDirectory {
                let value = try value(formatted), generation = f.surface.generation
                let syntax = await Task.detached { TextSyntax.color(value, language: .jsonc) }.value
                try need(f.surface.present(value, syntax: syntax, lines: EditorLineIndex(formatted), for: generation),
                         "JSONC-native-syntax-and-line-number-presentation")
                try await GlassVerification.captureOwnedWindow(f.native, to: evidence.appendingPathComponent("jsonc-formatted.png"))
                c.capturedJSONC = true
            }
            try need(EditorJSONFormatting.plan(.indented(.fresh), text: formatted, selection: f.text.selectedRange(),
                maximumBytes: 4096, allowsComments: true) == .unchanged, "JSONC-format-is-not-idempotent")
            try await c.events.perform { undo.undo() }; try await c.drain(f)
            try need(same(f.text.string, jsonc) && !undo.canUndo, "JSONC-Undo-lost-authored-text")
            try await c.events.perform { undo.redo() }; try await c.drain(f)
            try need(same(f.text.string, formatted), "JSONC-Redo-lost-formatted-text")
            try await c.events.perform { try need(NSApp.sendAction(action, to: compact.target, from: compact), "JSONC-compact-action") }
            try await c.drain(f)
            let compacted = f.text.string
            try need(compacted.contains("// Keep this configuration comment.\n{")
                && compacted.contains("/* Keep 🧭 exactly. */") && compacted.contains("\"array\":[true,null,],\"n\":-0,}")
                && compacted.contains("// Keep the ending.") && undo.undoActionName == "Compact JSON",
                "JSONC-compact-lost-comments-trailing-commas-or-line-comment-terminator")
            try need(EditorJSONFormatting.plan(.compact, text: compacted, selection: r(0), maximumBytes: 4096,
                allowsComments: true) == .unchanged, "JSONC-compact-is-not-idempotent")
            try await c.events.perform { undo.undo() }; try await c.drain(f)
            try need(same(f.text.string, formatted), "JSONC-compact-Undo")
            for invalid in ["{\"x\":1, /* unfinished", "[1,,]", "[,]", "{,}", "{\"x\":/* no value */}"] {
                try need(EditorJSONFormatting.plan(.compact, text: invalid, selection: r(0), maximumBytes: 4096,
                    allowsComments: true) == .refused(.cannotFormatJSON), "JSONC-invalid-text-must-stay-unchanged")
            }
            for inline in ["{/* empty */}", "{\"x\":/* before */[1,/* middle */2,/* last */],}",
                           "{\"x\":1// retain newline before comma\n,\"y\":true}"] {
                guard case .replace(let first) = EditorJSONFormatting.plan(.indented(.fresh), text: inline,
                    selection: r(0), maximumBytes: 4096, allowsComments: true) else {
                    throw Failure(stage: "JSONC-inline-comment-format")
                }
                try need(EditorJSONFormatting.plan(.indented(.fresh), text: first.text, selection: r(0),
                    maximumBytes: 4096, allowsComments: true) == .unchanged, "JSONC-inline-comment-idempotence")
            }
            try need(EditorJSONFormatting.plan(.compact, text: jsonc, selection: r(0), maximumBytes: 4096)
                == .refused(.cannotFormatJSON), "Strict-JSON-must-not-silently-enable-comments")
        }
        await c.check("native-invalid-JSON-preserved-with-readable-notice", value: try value("{\"x\": }"), selection: r(0)) { f in
            f.owner.selectLanguage(.json)
            guard let item = UIVerification.menuItem("Edit", "JSON", "Format JSON"),
                  let action = item.action else { throw Failure(stage: "invalid-JSON-menu") }
            var notices = 0
            let previous = f.surface.lineCommands.onNotice
            f.surface.lineCommands.onNotice = { notice in previous?(notice); notices += 1 }
            try await c.events.perform { try need(NSApp.sendAction(action, to: item.target, from: item), "invalid-JSON-action") }
            try await c.drain(f)
            try need(same(f.text.string, "{\"x\": }") && f.edits == 0 && f.text.undoManager?.canUndo == false && notices == 1,
                "invalid-JSON-was-edited-or-unexplained")
        }
        let syntaxDraft = "{\n    // Generated\n    \"label🧭\" false\n}"
        await c.check("native-JSON-check-navigates-without-editing", value: try value(syntaxDraft), selection: r(0)) { f in
            f.owner.selectLanguage(.jsonc)
            guard let item = UIVerification.menuItem("Edit", "JSON", "Check JSON"), let action = item.action else {
                throw Failure(stage: "JSON-check-menu")
            }
            try await c.events.perform { try need(NSApp.sendAction(action, to: item.target, from: item), "JSON-check-action") }
            try await wait("visible-JSON-check-issues") { f.native.attachedSheet?.isKeyWindow == true }
            guard let sheet = f.native.attachedSheet else { throw Failure(stage: "JSON-check-sheet") }
            if let evidence = c.evidenceDirectory {
                try await UIVerification.snapshot(sheet, to: evidence.appendingPathComponent("editor-json-check.png"))
            }
            try await c.events.perform { sheet.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: sheet)) }
            let offset = (syntaxDraft as NSString).range(of: "false").location
            try await wait("JSON-check-exact-issue-location") {
                f.native.attachedSheet == nil && f.text.selectedRange() == r(offset)
            }
            try need(same(f.text.string, syntaxDraft) && f.edits == 0 && f.text.undoManager?.canUndo == false
                && f.owner.navigationStatus.contains("colon"), "JSON-check-mutated-or-lost-the-draft")
        }
        await c.check("native-menu-duplicate-one-Undo-Redo", value: basic, selection: r(0)) { f in
            let generation = f.surface.generation
            try await c.events.perform { try f.send(0) }; try await c.drain(f)
            try need(same(f.text.string, "A\nA\nB") && f.text.selectedRange() == r(2)
                && f.edits == 1 && f.proxy.calls == 1 && f.surface.generation != generation, "one-native-replacement-and-generation")
            guard let undo = f.text.undoManager else { throw Failure(stage: "native-text-Undo-manager") }
            try need(undo.canUndo && undo.undoActionName == "Duplicate Lines", "native-line-command-action-name")
            try await c.events.perform { undo.undo() }; try await c.drain(f)
            try need(same(f.text.string, "A\nB") && !undo.canUndo && undo.canRedo && f.edits == 2, "one-Undo-exact-original")
            f.facts["nativeUndoSelection"] = [f.text.selectedRange().location, f.text.selectedRange().length]
            try await c.events.perform { undo.redo() }; try await c.drain(f)
            try need(same(f.text.string, "A\nA\nB") && !undo.canRedo && undo.canUndo && f.edits == 3, "one-Redo-exact-result")
            f.facts["nativeRedoSelection"] = [f.text.selectedRange().location, f.text.selectedRange().length]
        }
        let commentedSource = "  let compass = \"🧭\"\n\tlet value = 2\n"
        await c.check("native-comment-toggle-Undo-Redo-language", value: try value(commentedSource), selection: r(0, commentedSource.utf16.count)) { f in
            guard let item = UIVerification.menuItem("Edit", "Lines", "Toggle Line Comment"), let action = item.action else {
                throw Failure(stage: "actual-comment-menu-item")
            }
            try need(!f.owner.validateUserInterfaceItem(item), "plain-text-comment-disabled")
            f.owner.selectLanguage(.swift)
            try need(f.owner.validateUserInterfaceItem(item), "swift-comment-enabled")
            try await c.events.perform { try need(NSApp.sendAction(action, to: item.target, from: item), "native-comment-action") }
            try await c.drain(f)
            let expected = "  // let compass = \"🧭\"\n\t// let value = 2\n"
            try need(same(f.text.string, expected) && f.edits == 1, "native-comment-keeps-indentation-and-unicode")
            guard let undo = f.text.undoManager else { throw Failure(stage: "comment-Undo-manager") }
            try need(undo.undoActionName == "Toggle Line Comment", "comment-Undo-action-name")
            try await c.events.perform { undo.undo() }; try await c.drain(f)
            try need(same(f.text.string, commentedSource) && f.edits == 2, "comment-single-Undo")
            try await c.events.perform { undo.redo() }; try await c.drain(f)
            try need(same(f.text.string, expected) && f.edits == 3, "comment-single-Redo")
            try await c.events.perform {
                // Native Redo leaves its ordinary insertion caret at EOF.
                // Reselect the block the user intends to uncomment.
                f.text.selectAll(nil)
                try need(NSApp.sendAction(action, to: item.target, from: item), "native-uncomment-action")
            }
            try await c.drain(f)
            try need(same(f.text.string, commentedSource) && f.edits == 4, "native-toggle-removes-one-layer")
            f.owner.selectLanguage(.json)
            try need(!f.owner.validateUserInterfaceItem(item), "strict-json-comment-disabled")
            f.owner.selectLanguage(.jsonc)
            try need(f.owner.validateUserInterfaceItem(item), "jsonc-comment-enabled")
            try await c.events.perform {
                f.text.selectAll(nil)
                try need(NSApp.sendAction(action, to: item.target, from: item), "native-jsonc-comment-action")
            }
            try await c.drain(f)
            try need(same(f.text.string, expected) && f.edits == 5, "jsonc-comment-same-native-owner")
            try await c.events.perform { undo.undo() }; try await c.drain(f)
            try need(same(f.text.string, commentedSource) && f.edits == 6, "jsonc-comment-native-Undo")
        }
        await c.check("identical-lines-select-only", value: try value("x\nx"), selection: r(0)) { f in
            let generation = f.surface.generation
            var steps: [[String: Any]] = []
            for (tag, expected) in [(2, r(2)), (1, r(0))] {
                let command: EditorLineCommand = tag == 2 ? .moveLinesDown : .moveLinesUp
                let plan = EditorLineCommands.plan(command, text: f.text.string,
                    selection: f.text.selectedRange(), maximumBytes: TextDocumentValue.maximumBytes)
                let kind: String
                switch plan { case .select: kind = "select"; case .replace: kind = "replace"; case .unchanged: kind = "unchanged"; case .refused: kind = "refused" }
                steps.append(["tag": tag, "before": f.diagnostics(), "matchesFixtureBefore": same(f.text.string, "x\nx"), "planKindBefore": kind])
                f.facts["selectionSteps"] = steps
                try await c.events.perform { try f.send(tag) }; try await c.drain(f)
                steps[steps.count - 1]["afterMatchesFixture"] = same(f.text.string, "x\nx")
                steps[steps.count - 1]["afterSelection"] = [f.text.selectedRange().location, f.text.selectedRange().length]
                steps[steps.count - 1]["afterGenerationMatches"] = f.surface.generation == generation
                f.facts["selectionSteps"] = steps
                try need(same(f.text.string, "x\nx") && f.text.selectedRange() == expected
                    && f.surface.generation == generation && f.edits == 0 && f.proxy.calls == 0
                    && !f.native.isDocumentEdited && f.text.undoManager?.canUndo == false,
                    "selection-only-no-native-text-dirty-generation-or-Undo")
            }
        }
        await c.check("Unicode-half-open-lines", value: try value("😀\ne\u{301}\nz"), selection: r(0, 3)) { f in
            try await c.events.perform { try f.send(2) }; try await c.drain(f)
            try need(same(f.text.string, "e\u{301}\n😀\nz") && f.text.selectedRange() == r(3, 3)
                && f.edits == 1 && f.proxy.calls == 1, "UTF16-half-open-following-line-excluded")
        }
        await c.check("trailing-empty-line", value: try value("a\n"), selection: r(2)) { f in
            try await c.events.perform { try f.send(1) }; try await c.drain(f)
            try need(same(f.text.string, "\na") && f.text.selectedRange() == r(0) && f.edits == 1,
                     "EOF-empty-line-moves-without-concatenating-bodies")
        }
        let encoded = await Task.detached {
            Data([0xef, 0xbb, 0xbf]) + Data(String(repeating: String(repeating: "x", count: 32_766) + "\r\n", count: 16).utf8)
        }.value
        let crlf = try TextDocumentValue.original(encoded)
        await c.check("CRLF-BOM-owner-full-value-refusal", value: crlf, selection: r(0, crlf.utf16Count)) { f in
            let generation = f.surface.generation, selected = f.text.selectedRange()
            guard case .replace(let edit) = EditorLineCommands.plan(.duplicateSelectedLines, text: crlf.text,
                selection: selected, maximumBytes: TextDocumentValue.maximumBytes) else { throw Failure(stage: "canonical-growth-fits-before-format-preflight") }
            let canonical = (crlf.text as NSString).replacingCharacters(in: edit.range, with: edit.text)
            try need(canonical.utf8.count == 1_048_544 && encoded.count == 524_291,
                     "CRLF-BOM-fixture-exact-size-premise")
            let gate = f.hold(); try await c.events.perform { try f.send(0); try f.send(0) }; try await c.gateEntered(gate)
            await gate.release(); try await c.drain(f)
            try need(f.rejections == [.tooLarge] && f.edits == 0 && f.proxy.calls == 0
                && f.surface.generation == generation && same(f.text.string, crlf.text)
                && f.text.selectedRange() == selected && f.text.undoManager?.canUndo == false
                && f.probe.snapshot.preparations == 1, "encoded-format-refusal-clears-queue-before-native-insertion")
        }
        await c.check("native-delegate-refusal", value: basic, selection: r(0)) { f in
            let generation = f.surface.generation; f.proxy.deny = true
            let gate = f.hold(); try await c.events.perform { try f.send(0); try f.send(2) }; try await c.gateEntered(gate)
            await gate.release(); try await c.drain(f)
            try need(same(f.text.string, "A\nB") && f.text.selectedRange() == r(0) && f.edits == 0
                && f.surface.generation == generation && f.proxy.calls == 1 && f.probe.snapshot.preparations == 1
                && f.text.undoManager?.canUndo == false, "native-veto-has-no-predicted-selection-or-queued-edit")
        }
        await c.check("bounded-rapid-fresh-snapshots", value: try value("a"), selection: r(0)) { f in
            let gate = f.hold()
            try await c.events.perform { for _ in 0..<10 { try f.send(0) } }
            try await c.gateEntered(gate)
            try need(f.surface.lineCommands.stateForVerification.pendingCount == 8, "one-preparation-plus-at-most-eight-pending")
            await gate.release(); try await c.drain(f)
            try need(same(f.text.string, String(repeating: "a\n", count: 9) + "a") && f.text.selectedRange() == r(18)
                && f.edits == 9 && f.proxy.calls == 9 && f.probe.snapshot.preparations == 9,
                "nine-admitted-commands-take-nine-fresh-snapshots")
        }
        await c.check("Find-field-focus-refusal", value: basic, selection: r(0)) { f in
            let generation = f.surface.generation, gate = f.hold()
            try await c.events.perform { try f.send(0); try f.send(0) }; try await c.gateEntered(gate)
            try await c.events.perform { try f.findFocus(); try need(!f.owner.validateUserInterfaceItem(f.items[0]!), "Find-focus-menu-validation-refuses"); try f.send(0) }
            await gate.release(); try await c.drain(f)
            try need(f.edits == 0 && same(f.text.string, "A\nB") && f.surface.generation == generation
                && f.probe.snapshot.preparations == 1, "Find-field-focus-is-not-document-input")
        }
        await c.check("transient-focus-causal", value: basic, selection: r(0)) { try await focusCausal(c, $0, fresh: false) }
        await c.check("fresh-command-after-cancelled-epoch", value: basic, selection: r(0)) { try await focusCausal(c, $0, fresh: true) }
        await c.check("marked-text-discards-held-queue", value: basic, selection: r(0)) { f in
            let gate = f.hold(); try await c.events.perform { try f.send(0); try f.send(0) }; try await c.gateEntered(gate)
            try await c.events.perform { f.text.setMarkedText("Z", selectedRange: r(1), replacementRange: r(0)); try need(f.text.hasMarkedText(), "actual-native-marked-text") }
            let marked = f.text.string, selected = f.text.selectedRange(), generation = f.surface.generation, edits = f.edits
            try need(!f.owner.validateUserInterfaceItem(f.items[0]!), "marked-text-menu-validation-refuses")
            await gate.release(); try await c.drain(f)
            try need(same(f.text.string, marked) && f.text.selectedRange() == selected
                && f.surface.generation == generation && f.edits == edits && f.probe.snapshot.preparations == 1,
                "no-line-edit-or-selection-during-native-composition")
            // Native unmarking may legitimately notify/advance generation.
            try await c.events.perform { f.text.unmarkText() }
        }
        await c.check("same-text-new-generation-stale", value: basic, selection: r(0)) { f in
            let generation = f.surface.generation, gate = f.hold()
            try await c.events.perform { try f.send(0); try f.send(0) }; try await c.gateEntered(gate)
            try await c.events.perform { f.surface.install(basic) }
            try need(f.surface.generation != generation && same(f.text.string, basic.text) && f.text.selectedRange() == r(0),
                     "same-text-install-changes-only-generation-fence")
            let current = f.surface.generation
            await gate.release(); try await c.drain(f)
            try need(f.edits == 0 && f.surface.generation == current && same(f.text.string, basic.text)
                && f.probe.snapshot.preparations == 1, "stale-generation-never-admits-held-command")
        }
        await c.check("changed-selection-stale", value: basic, selection: r(0)) { f in
            let gate = f.hold(); try await c.events.perform { try f.send(0); try f.send(0) }; try await c.gateEntered(gate)
            try await c.events.perform { f.text.setSelectedRange(r(2)) }
            await gate.release(); try await c.drain(f)
            try need(f.edits == 0 && same(f.text.string, basic.text) && f.text.selectedRange() == r(2)
                && f.probe.snapshot.preparations == 1, "changed-selection-preserved-old-queue-cleared")
        }
        await c.check("close-held-task-retains-until-drain", value: basic, selection: r(0)) { f in
            let gate = f.hold(); try await c.events.perform { try f.send(0); try f.send(0) }; try await c.gateEntered(gate)
            try need(f.surface.lineCommands.stateForVerification.pendingCount == 1,
                     "one-queued-command-before-close")
            try await c.events.perform { f.owner.finishClose(); try need(!f.owner.validateUserInterfaceItem(f.items[0]!), "closed-window-retained-menu-refuses"); try f.send(0) }
            try need(f.surface.lineCommands.stateForVerification.hasWorker && f.probe.snapshot.activePreparations == 1
                && f.surface.lineCommands.stateForVerification.pendingCount == 0,
                     "close-retains-actual-cancelled-worker")
            await gate.release(); try await c.drain(f)
            try await wait("actual-editor-close-animation-drained") { !f.native.isVisible }
            // Closing clears the private presentation. A queued command must
            // neither repopulate that view nor create a new native Undo edit.
            try need(f.edits == 0 && f.proxy.calls == 0 && f.text.string.isEmpty
                && f.text.undoManager?.canUndo == false && !f.native.isVisible
                && f.surface.lineCommands.stateForVerification.isClosed
                && f.probe.snapshot.preparations == 1 && f.probe.snapshot.deliveries == 1,
                     "closed-editor-stays-cleared-without-late-native-insertion")
        }
        await c.check("two-window-target-isolation", value: basic, selection: r(0)) { first in
            let gate = first.hold(); try await c.events.perform { try first.send(0); try first.send(0) }; try await c.gateEntered(gate)
            let second = try await c.make("second-target", value: try value("q\nr"), selection: r(0))
            try need(!first.owner.validateUserInterfaceItem(first.items[0]!) && second.owner.validateUserInterfaceItem(second.items[0]!),
                     "actual-key-window-validates-only-own-target")
            try await c.events.perform { try first.send(0); try second.send(0) }
            await gate.release(); try await c.drain(first); try await c.drain(second)
            try need(first.edits == 0 && same(first.text.string, basic.text) && same(second.text.string, "q\nq\nr")
                && second.edits == 1, "retained-other-window-menu-cannot-retarget-edit")
        }
    }

    private static func comparedChangePlans() throws {
        let head = "a\nCafé\nrepeat\nrepeat\n"
        let draft = "insert\n" + head
        try need(try EditorTextComparison.committedLine(3, in: draft, comparedWith: head, cancelled: { false }) == .exact(2),
                 "line-origin-proves-shifted-exact-Unicode")
        try need(try EditorTextComparison.committedLine(1, in: draft, comparedWith: head, cancelled: { false }) == .changed,
                 "line-origin-refuses-insertions")
        try need(try EditorTextComparison.committedLine(4, in: draft, comparedWith: head, cancelled: { false }) == .ambiguous
            && EditorTextComparison.committedLine(3, in: head, comparedWith: head, cancelled: { false }) == .exact(3),
            "line-origin-distinguishes-duplicate-candidates-from-an-identical-snapshot")
        let target = EditorBufferIdentity(document: UUID(), generation: UUID())
        let format = TextDocumentFormat(bom: true, lineEnding: .crlf)
        func plan(_ left: String, _ right: String, whitespace: EditorComparisonWhitespace = .exact) throws -> EditorComparisonPlan {
            try EditorTextComparison.prepare(.init(baseline: left, current: right, format: format,
                language: .plain, currentEditor: target), whitespace: whitespace, cancelled: { false })
        }
        func apply(_ edit: EditorComparisonApplication, in text: String) throws -> String {
            guard edit.editor == target, case .replace(let replacement) = EditorLineCommands.plan(.applyComparedChange(edit),
                text: text, selection: r(0), maximumBytes: 16_384) else { throw Failure(stage: "compared-change-replacement") }
            return (text as NSString).replacingCharacters(in: replacement.range, with: replacement.text)
        }
        for (left, right) in [("head\nCafé 🧭\ntail\n", "head\ntail\n"),
                              ("head\ntail\n", "head\nextra\ntail\n"),
                              ("a🧭\n", "a🧭"), ("a🧭", "a🧭\n"), ("", "one"), ("one", "")] {
            let comparison = try plan(left, right)
            guard let edit = comparison.application(of: 0, to: .current) else { throw Failure(stage: "compared-change-eligible-range") }
            try need(same(try apply(edit, in: right), left) && comparison.current.format == format,
                "compared-change-insertion-deletion-grapheme-and-trailing-line")
            try need(comparison.application(of: 0, to: .before) == nil, "compared-change-read-only-side-refuses")
            try need(EditorLineCommands.plan(.applyComparedChange(edit), text: "new draft\n" + right, selection: r(0),
                maximumBytes: 16_384) == .refused(.invalidSelection), "compared-change-stale-source-refuses")
        }
        let before = "first changed\ncommon\nkeep\nsecond changed\n", after = "first draft\ncommon\nkeep\nsecond draft\n"
        let multiple = try plan(before, after)
        guard multiple.changes.count == 2, let selected = multiple.application(of: 0, to: .current) else {
            throw Failure(stage: "compared-change-multiple-hunks")
        }
        try need(try apply(selected, in: after) == "first changed\ncommon\nkeep\nsecond draft\n", "compared-change-leaves-other-hunk")
        let ignored = try plan(before, after, whitespace: .trailing)
        let grouped = try plan(String(repeating: "a\n", count: 1_100), String(repeating: "b\n", count: 1_100))
        try need(ignored.application(of: 0, to: .current) == nil && grouped.grouped
            && grouped.application(of: 0, to: .current) == nil, "compared-change-refuses-normalized-or-grouped-review")
    }

    private static func admittedRoot() async throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "explicit-generated-root") }
        let root = URL(fileURLWithPath: raw)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try need(root.resolvingSymlinksInPath() == root
            && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && Bundle.main.bundleIdentifier == "local.macexplorer.development"
            && Bundle.main.bundleURL == repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app")
            && ProcessInfo.processInfo.arguments.contains("--verify-ui")
            && ProcessInfo.processInfo.arguments.filter({ $0.hasPrefix("--check-") }) == ["--check-editor-line-commands"],
            "generated-root-bundle-and-exact-entry")
        let admitted = try await Task.detached {
            guard root.resolvingSymlinksInPath() == root else { return false }
            func metadata(_ name: String) throws -> [String: Any]? {
                let url = root.appendingPathComponent(name)
                guard url.resolvingSymlinksInPath() == url,
                      let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                      size.intValue <= 8192 else { return nil }
                return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            }
            guard let marker = try metadata("reservation.json") else { return false }
            return marker["packet"] as? String == "traverse-development-v1" && marker["action"] as? String == "native-editor-line-commands"
        }.value
        try need(admitted, "exact-generated-native-editor-action")
        return root
    }
    static func run() async {
        var root: URL?, context: Context?, failure: String?
        let causalOnly = ProcessInfo.processInfo.arguments.contains("--line-command-causal-focus-only")
        do {
            root = try await admittedRoot()
            let c = try Context(evidenceDirectory: root?.appendingPathComponent("evidence")); context = c
            try await cases(c, causalOnly: causalOnly)
        } catch { failure = (error as? Failure)?.stage ?? "scope-or-native-setup-error" }
        let clean = await context?.cleanup() ?? true
        context?.events.close()
        if let context { NSApp.mainMenu = context.originalMenu }
        let results = context?.results ?? []
        let expected = causalOnly ? 1 : 56
        if failure == nil, results.count != expected { failure = "native-case-count" }
        let passed = failure == nil && clean && context?.events.unexpectedInputCount == 0
            && results.count == expected && results.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "mode": causalOnly ? "focus-causal-only" : "full-line-commands",
            "failure": failure ?? "none", "cases": results, "expectedCases": expected, "cleanup": clean,
            "generatedInMemoryOnly": true, "documentFileReads": 0, "fileOperations": 0, "fileSaveCalls": 0,
            "SaveCallbacksObserved": context?.observedSaveCallbacks ?? 0,
            "formattedJSONCWindowCaptured": context?.capturedJSONC ?? false,
            "unexpectedNativeInputCount": context?.events.unexpectedInputCount ?? 0,
            "systemTrashCalls": 0, "networkCalls": 0, "realKeyboardGesture": "NOT EXERCISED",
            "displayedPixelRecording": "NOT EXERCISED", "actualDocumentOwnerDirtyModel": "NOT EXERCISED"]
        var wrote = false
        if let root, let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), data.count <= 262_144 {
            wrote = (try? await Task.detached {
                try data.write(to: root.appendingPathComponent("evidence/editor-line-commands.json"), options: .withoutOverwriting)
                return true
            }.value) == true
        }
        print(passed && wrote ? "EDITOR_LINE_COMMAND_NATIVE_CHECKS_PASS" : "EDITOR_LINE_COMMAND_NATIVE_CHECKS_FAILED")
        exit(passed && wrote ? 0 : 1)
    }
}
#endif
