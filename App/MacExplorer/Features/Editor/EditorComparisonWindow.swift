import AppKit
import Combine
import SwiftUI

/// One immutable read-only comparison per editor. CPU work is retained until
/// actual completion; closing the editor joins this owner before releasing text.
@MainActor final class EditorComparisonWindow: NSWindowController, NSWindowDelegate, ObservableObject, NSUserInterfaceValidations {
    let beforeSurface = NativeTextEditorSurface(frame: .zero)
    let currentSurface = NativeTextEditorSurface(frame: .zero)
    @Published private(set) var status = "Preparing comparison…"
    @Published private(set) var position = ""
    @Published private(set) var preparing = false
    @Published private(set) var canNavigate = false
    let sourceName: String
    private let settings: BrowserSettings
    private let capture: @MainActor () -> EditorComparisonCapture?
    private var preferenceObservation: AnyCancellable?
    private var plan: EditorComparisonPlan?
    private var index = 0
    private var worker: Task<EditorComparisonPlan?, Never>?
    private var delivery: Task<Void, Never>?
    private var closingWork: Task<Void, Never>?
    private(set) var closed = false
    var didClose: (() -> Void)?
    #if DEBUG
    var planForVerification: EditorComparisonPlan? { plan }
    var hasWorkForVerification: Bool { worker != nil || delivery != nil || closingWork != nil }
    #endif

    init(relativeTo parent: NSWindow, settings: BrowserSettings, pointSize: CGFloat,
         capture: @escaping @MainActor () -> EditorComparisonCapture?) {
        self.settings = settings; self.capture = capture
        sourceName = parent.tab.title
        let native = ToolWindowChrome.makeWindow(title: "Compare Changes — Traverse",
            size: .init(width: 1080, height: 720), minimumSize: .init(width: 620, height: 520))
        super.init(window: native); native.delegate = self
        for surface in [beforeSurface, currentSurface] {
            surface.textView.isEditable = false; surface.textView.allowsUndo = false
            surface.applyEditorPreferences(settings.editorPreferences, pointSize: pointSize)
        }
        beforeSurface.textView.comparisonTint = .systemRed
        currentSurface.textView.comparisonTint = .systemBlue
        beforeSurface.setAccessibilityLabel("Saved snapshot, read only")
        currentSurface.setAccessibilityLabel("Current text snapshot, read only")
        // Reuse the controller's fixed-window sizing policy. A hosting view's
        // intrinsic document height must not resize this viewport to all text.
        native.contentViewController = InterfaceHostingController(rootView: EditorComparisonContent(model: self, settings: settings))
        ToolWindowChrome.install(in: native, settings: settings)
        // Installing a content controller can adopt its minimum fitting size.
        // Restore the feature's intended initial viewport only on first create.
        native.setContentSize(.init(width: 1080, height: 720))
        native.title = "Compare " + sourceName + " — Traverse"
        ToolWindowChrome.position(native, relativeTo: parent)
        preferenceObservation = settings.$editorPreferences.combineLatest(settings.$interfaceSize).dropFirst()
            .receive(on: RunLoop.main).sink { [weak self] preferences, size in
                guard let self, !closed, closingWork == nil else { return }
                for surface in [beforeSurface, currentSurface] {
                    surface.applyEditorPreferences(preferences, pointSize: CGFloat(preferences.basePointSize) * size.scale)
                }
            }
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        guard !closed, closingWork == nil else { return }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        if plan == nil && worker == nil { refresh() }
    }
    func refresh() {
        guard !closed, closingWork == nil, worker == nil, delivery == nil else { return }
        guard let captured = capture() else {
            status = "Finish the editor’s current action before refreshing this comparison."; return
        }
        preparing = true; canNavigate = false; status = "Comparing captured text…"
        let computation = Task.detached(priority: .userInitiated) {
            try? EditorTextComparison.prepare(captured, cancelled: { Task.isCancelled })
        }
        worker = computation
        delivery = Task { [weak self] in
            let prepared = await computation.value
            guard let self else { return }
            worker = nil; delivery = nil; preparing = false
            guard !closed, closingWork == nil else { return }
            guard let prepared else {
                status = "This comparison could not be prepared. The editor text is unchanged."; return
            }
            beforeSurface.install(prepared.before); currentSurface.install(prepared.current)
            _ = beforeSurface.present(prepared.before, syntax: prepared.beforeSyntax,
                lines: prepared.beforeIndex, for: beforeSurface.generation)
            _ = currentSurface.present(prepared.current, syntax: prepared.currentSyntax,
                lines: prepared.currentIndex, for: currentSurface.generation)
            beforeSurface.textView.comparisonHighlights = prepared.changes.map(\.beforeRange)
            currentSurface.textView.comparisonHighlights = prepared.changes.map(\.currentRange)
            plan = prepared; index = 0; canNavigate = !prepared.changes.isEmpty
            status = prepared.changes.isEmpty ? "No text changes in this snapshot."
                : prepared.grouped ? "Large changes grouped for review · read only"
                : "Changed lines: saved text in red, current text in blue · read only"
            navigate(0)
            if let content = window?.contentView { ToolContentMotion.crossfade(content) }
        }
    }
    func navigate(_ offset: Int) {
        guard !closed, !preparing, let plan, !plan.changes.isEmpty else { position = ""; return }
        index = (index + offset + plan.changes.count) % plan.changes.count
        let change = plan.changes[index]
        beforeSurface.textView.scrollRangeToVisible(change.beforeRange)
        currentSurface.textView.scrollRangeToVisible(change.currentRange)
        func lines(_ value: Range<Int>) -> String {
            if value.isEmpty { return "near line \(value.lowerBound + 1)" }
            return value.count == 1 ? "line \(value.lowerBound + 1)" : "lines \(value.lowerBound + 1)–\(value.upperBound)"
        }
        position = "Change \(index + 1) of \(plan.changes.count) · Saved \(lines(change.beforeLines)) · Current \(lines(change.currentLines))"
    }
    func closeAndDrain() async {
        if closed { return }
        if let closingWork { await closingWork.value; return }
        let task = Task { [self] in
            preferenceObservation = nil
            worker?.cancel()
            if let delivery { await delivery.value }
            worker = nil; delivery = nil; plan = nil; canNavigate = false
            beforeSurface.clearPrivatePresentation(); currentSurface.clearPrivatePresentation()
            closed = true; window?.close()
        }
        closingWork = task; await task.value; closingWork = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closed { return true }
        if worker == nil && delivery == nil { return true }
        Task { [self] in await closeAndDrain() }; return false
    }
    func windowWillClose(_ notification: Notification) {
        closed = true; plan = nil; canNavigate = false
        preferenceObservation = nil
        beforeSurface.clearPrivatePresentation(); currentSurface.clearPrivatePresentation()
        EditorMenuOwnership.release(self)
        didClose?()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard !closed else { return }
        _ = EditorMenuOwnership.claim(self) { base in
            let menu = NSMenu()
            if let item = base?.items.first?.copy() as? NSMenuItem { menu.addItem(item) }
            func section(_ title: String, _ entries: [(String, Selector, String, NSEvent.ModifierFlags, AnyObject?)]) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""), child = NSMenu(title: title)
                for (title, action, key, modifiers, target) in entries {
                    let command = NSMenuItem(title: title, action: action, keyEquivalent: key)
                    command.keyEquivalentModifierMask = modifiers; command.target = target; child.addItem(command)
                }
                item.submenu = child; menu.addItem(item)
            }
            section("File", [("Refresh Snapshot", #selector(refreshSnapshot(_:)), "r", .command, self),
                ("Close", #selector(NSWindow.performClose(_:)), "w", .command, window)])
            section("Edit", [("Copy", #selector(NSText.copy(_:)), "c", .command, nil),
                ("Select All", #selector(NSText.selectAll(_:)), "a", .command, nil)])
            let f7 = String(UnicodeScalar(NSF7FunctionKey)!)
            section("View", [("Next Change", #selector(nextChange(_:)), f7, [], self),
                ("Previous Change", #selector(previousChange(_:)), f7, .shift, self)])
            return menu
        }
    }
    func windowDidResignKey(_ notification: Notification) { EditorMenuOwnership.release(self) }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard !closed, window?.isKeyWindow == true else { return false }
        switch item.action {
        case #selector(refreshSnapshot(_:)): return !preparing && closingWork == nil
        case #selector(nextChange(_:)), #selector(previousChange(_:)): return canNavigate
        default: return true
        }
    }
    @objc private func refreshSnapshot(_ sender: Any?) { refresh() }
    @objc private func nextChange(_ sender: Any?) { navigate(1) }
    @objc private func previousChange(_ sender: Any?) { navigate(-1) }
}

private struct EditorComparisonContent: View {
    @ObservedObject var model: EditorComparisonWindow
    @ObservedObject var settings: BrowserSettings
    @Environment(\.interfaceScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stacked = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare Changes").interfaceFont(.title2.weight(.semibold))
                Spacer()
                Button("Refresh Snapshot", systemImage: "arrow.clockwise") { model.refresh() }.disabled(model.preparing)
            }
            Text(model.sourceName).interfaceFont(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text("A snapshot of your saved text and current edits. Refresh Snapshot includes later changes.")
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .help("Saved snapshot is the last text successfully loaded or saved by this editor. This comparison does not check the file or server for newer changes.")
            HStack {
                Button("Previous", systemImage: "chevron.up") { model.navigate(-1) }.disabled(!model.canNavigate)
                Button("Next", systemImage: "chevron.down") { model.navigate(1) }.disabled(!model.canNavigate)
                Text(model.position).interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if model.preparing { ProgressView().controlSize(.small) }
            }
            GeometryReader { geometry in
                let height = max(100, stacked ? (geometry.size.height - 16) / 2 : geometry.size.height)
                AdaptiveToolColumns(settings: settings, minimumWidth: 720, onArrangementChanged: { stacked = $0 }) {
                    pane("Saved snapshot", symbol: "minus.circle", surface: model.beforeSurface).frame(height: height)
                } trailing: {
                    pane("Current text", symbol: "plus.circle", surface: model.currentSurface).frame(height: height)
                }
                .animation(reduceMotion || !settings.motion.allows(.pages) ? nil
                    : .easeInOut(duration: settings.motion.mode == .reduced ? 0.14 : 0.30), value: stacked)
            }
            Text(model.status).interfaceFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("editor-comparison-status")
        }.padding(18)
    }
    private func pane(_ title: String, symbol: String, surface: NativeTextEditorSurface) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).interfaceFont(.callout.weight(.medium))
            EditorComparisonSurface(surface: surface)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.25)) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct EditorComparisonSurface: NSViewRepresentable {
    let surface: NativeTextEditorSurface
    func makeNSView(context: Context) -> NativeTextEditorSurface { surface }
    func updateNSView(_ view: NativeTextEditorSurface, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeTextEditorSurface, context: Context) -> CGSize? {
        .init(width: max(0, proposal.width ?? 0), height: max(0, proposal.height ?? 0))
    }
}
