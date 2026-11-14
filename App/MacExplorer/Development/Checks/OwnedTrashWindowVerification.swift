#if DEBUG
import AppKit

/// One UI flow in the existing native runner; callbacks only, no Trash or file
/// action. The engine's generated protocol/native acceptance stays separate.
@MainActor
enum OwnedTrashWindowVerification {
    static func run(root: URL, settings: BrowserSettings, parent: NSWindow?, recording: Bool) async throws -> [[String: Any]] {
        let previousSize = settings.interfaceSize, previousAppearance = settings.appearance
        let previousMotion = settings.motion, previousStyle = settings.navigationStyle
        settings.interfaceSize = .init(100); settings.appearance = .dark
        settings.motion.mode = .full; settings.navigationStyle = .glass
        let tool = OwnedTrashWindow(settings: settings)
        defer {
            tool.close(); settings.interfaceSize = previousSize; settings.appearance = previousAppearance
            settings.motion = previousMotion; settings.navigationStyle = previousStyle
        }
        let first = UUID(), second = UUID(), folder = root.appendingPathComponent("source/Generated Trash Display", isDirectory: true)
        let entries: [OwnedTrashItemPresentation] = [
            .init(id: 0, originalURL: folder.appendingPathComponent("Generated.txt"), isDirectory: false,
                recordedByteCount: 46, stateTitle: "Moved to Trash"),
            .init(id: 1, originalURL: folder.appendingPathComponent("Generated Folder"), isDirectory: true,
                recordedByteCount: nil, stateTitle: "Moved to Trash")
        ]
        let ready = OwnedTrashGroupPresentation(id: first, createdAt: Date(timeIntervalSince1970: 1_793_800_000),
            entries: entries, canRestore: true, canDelete: true, needsReview: false,
            explanation: "Restore returns both generated items together. No filesystem action is installed in this review.")
        let review = OwnedTrashGroupPresentation(id: second, createdAt: Date(timeIntervalSince1970: 1_793_799_000),
            entries: entries.map { .init(id: $0.id, originalURL: $0.originalURL, isDirectory: $0.isDirectory,
                recordedByteCount: $0.recordedByteCount, stateTitle: "Needs review") },
            canRestore: false, canDelete: false, needsReview: true,
            explanation: "An earlier generated deletion needs review. No Restore or additional Delete is offered.")
        var restored: [UUID] = [], removed: [UUID] = [], clips: [[String: Any]] = []
        tool.onRestore = { restored.append($0) }; tool.onDelete = { removed.append($0) }
        tool.update([ready, review], message: "Generated recorded metadata only.", hasMore: true, busy: false)
        tool.present(relativeTo: parent)
        guard let window = tool.window, let content = window.contentView else { throw UIVerification.Failure(message: "Missing generated Trash window") }
        window.title = "Traverse Trash · generated review"
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(180))
        let views = descendants(content)
        guard let groups = views.compactMap({ $0 as? NSTableView }).first(where: { $0.headerView == nil }),
              let restore = views.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "owned-trash-restore-group" }),
              let remove = views.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "owned-trash-delete-group" }) else {
            throw UIVerification.Failure(message: "Missing generated Trash controls")
        }
        try UIVerification.require(tool.selectedGroupID == first && restore.isEnabled && remove.isEnabled,
            "Initial Trash group did not expose its actual actions")
        restore.performClick(nil); remove.performClick(nil)
        try UIVerification.require(restored == [first] && removed == [first], "Whole-group actions lost their exact IDs")
        let consent = OwnedTrashDeletionReview.make(originalURLs: entries.map(\.originalURL))
        var consentResponse: NSApplication.ModalResponse?
        consent.beginSheetModal(for: window) { consentResponse = $0 }
        try await Task.sleep(for: .milliseconds(100))
        guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: consent.window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
            throw UIVerification.Failure(message: "Missing generated Return event")
        }
        let handled = consent.window.performKeyEquivalent(with: enter)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while consentResponse == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if consent.window.sheetParent === window { window.endSheet(consent.window, returnCode: .alertSecondButtonReturn) }
        try UIVerification.require(handled && consentResponse == .alertSecondButtonReturn,
            "Return selected permanent deletion instead of Cancel")
        if recording, CGPreflightScreenCaptureAccess() {
            let movie = try await NativeMotionRecorder.record(window: window, root: root,
                label: "owned-trash-group-selection", sampling: .diagnostic(for: window)) {
                groups.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            }
            clips.append(DevelopmentMotionVerification.clip("owned-trash-group-selection", report: movie, field: nil, window: window))
        } else { groups.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false) }
        try UIVerification.require(tool.selectedGroupID == second && !restore.isEnabled && !remove.isEnabled,
            "Review-only Trash group enabled a mutation")
        restore.performClick(nil); remove.performClick(nil)
        try UIVerification.require(restored == [first] && removed == [first], "Disabled Trash action dispatched")
        groups.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tool.setBusy(true, message: "Generated worker is still finishing.", locksSelection: true)
        try UIVerification.require(!restore.isEnabled && !remove.isEnabled && !groups.isEnabled
            && groups.delegate?.tableView?(groups, shouldSelectRow: 1) == false,
            "Busy Trash group exposed a second mutation or different visible group")
        tool.update([review, ready], message: "Generated refresh preserves selection.", hasMore: false, busy: false)
        try UIVerification.require(tool.selectedGroupID == first && restore.isEnabled,
            "Trash metadata refresh substituted a different group")
        try await Task.sleep(for: .milliseconds(320))
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/owned-trash-normal.png"))
        }
        if recording, CGPreflightScreenCaptureAccess() {
            let movie = try await NativeMotionRecorder.record(window: window, root: root,
                label: "owned-trash-interface-size", sampling: .diagnostic(for: window)) {
                settings.interfaceSize = .init(150); settings.appearance = .light
            }
            clips.append(DevelopmentMotionVerification.clip("owned-trash-interface-size", report: movie, field: nil, window: window))
        } else { settings.interfaceSize = .init(150); settings.appearance = .light }
        try await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
        try UIVerification.require(window.styleMask.contains(.resizable) && window.isOpaque
            && tool.selectedGroupID == first && restore.isEnabled,
            "Enlarged Trash layout lost its state or native window behavior")
        let itemTables = descendants(window.contentView!).compactMap { $0 as? NSTableView }.filter {
            $0.accessibilityLabel() == "Items in the selected Trash group"
        }
        guard itemTables.count == 1, let table = itemTables.first,
              let name = table.tableColumn(withIdentifier: .init("name")),
              let state = table.tableColumn(withIdentifier: .init("status")),
              let viewport = table.enclosingScrollView?.contentView else {
            throw UIVerification.Failure(message: "Missing enlarged Trash column layout")
        }
        try UIVerification.require(name.width >= 180 * InterfaceMetrics.scale - 1
            && state.width >= 140 * InterfaceMetrics.scale - 1
            && table.rect(ofColumn: table.column(withIdentifier: state.identifier)).maxX <= viewport.bounds.maxX + 1,
            "Enlarged Trash hid its essential Name/Status columns")
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/owned-trash-large.png"))
        }
        tool.update([], message: "Generated unavailable history.", hasMore: false, busy: false,
            emptyTitle: "Recorded items unavailable", offersHistoryReview: true)
        try UIVerification.require(tool.selectedGroupID == nil && !restore.isEnabled && !remove.isEnabled,
            "Unavailable Trash history retained action authority")
        let frame = window.frame
        tool.close(); try UIVerification.require(!tool.isOpen && tool.selectedGroupID == nil, "Trash close retained selection")
        tool.update([ready], message: "Generated reopen.", hasMore: false, busy: false)
        tool.present(relativeTo: parent)
        try UIVerification.require(window.frame == frame && tool.selectedGroupID == first,
            "Reopening an existing Trash window reset its user frame")
        return clips
    }
    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
#endif
