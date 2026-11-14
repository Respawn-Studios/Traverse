#if DEBUG
import AppKit
import ExplorerCore

/// Generated native adapter assertions at actual reconciliation completion.
/// Mouse gestures, screen pixels and external accessibility remain separate.
@MainActor enum SidebarLayoutPresentationRegression {
    /// All UI observations and the watchdog stay explicitly on MainActor. The
    /// watchdog is a refusal deadline, never evidence that animation completed.
    @MainActor private final class CompletionBoundary {
        let name: String
        private var expected: [UUID: Bool] = [:]
        private var reconciled: Set<UUID> = []
        private var finished: Set<UUID> = []
        private var result: Result<Void, SidebarRowPresentationProbe.Failure>?
        private var continuation: CheckedContinuation<Result<Void, SidebarRowPresentationProbe.Failure>, Never>?
        var sample: ((UUID) throws -> Void)?
        init(_ name: String) { self.name = name }
        func expect(_ generation: UUID?, reconciles: Bool) throws {
            guard let generation, expected[generation] == nil else {
                throw SidebarRowPresentationProbe.Failure(description: name + ":missing-or-duplicate-generation")
            }
            expected[generation] = reconciles
        }
        func didReconcile(_ generation: UUID) {
            guard expected[generation] == true, reconciled.insert(generation).inserted else {
                fail("unexpected-reconciliation"); return
            }
            guard let sample else { fail("missing-completion-sample"); return }
            do { try sample(generation) }
            catch { fail("completion-sample:" + String(describing: error)) }
        }
        func didFinish(_ generation: UUID, reconciles: Bool) {
            guard let wanted = expected[generation], wanted == reconciles,
                  finished.insert(generation).inserted,
                  reconciled.contains(generation) == reconciles else {
                fail("completion-generation-or-outcome"); return
            }
            if finished.count == expected.count { resolve(.success(())) }
        }
        private func fail(_ reason: String) {
            resolve(.failure(.init(description: name + ":" + reason)))
        }
        private func resolve(_ value: Result<Void, SidebarRowPresentationProbe.Failure>) {
            guard result == nil else { return }
            result = value; continuation?.resume(returning: value); continuation = nil
        }
        func wait() async throws {
            guard !expected.isEmpty else { throw SidebarRowPresentationProbe.Failure(description: name + ":no-generation") }
            let watchdog = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.fail("actual-completion-timeout")
            }
            let value = await withCheckedContinuation { continuation in
                if let result { continuation.resume(returning: result) }
                else { self.continuation = continuation }
            }
            watchdog.cancel(); await watchdog.value
            try Task.checkCancellation()
            try value.get()
        }
    }

    @MainActor private struct State {
        let selected: [SidebarNode]
        let expanded: [(SidebarNode, Bool)]
        let scroll: NSPoint?
        let responder: NSResponder?
        let focusedRowNode: SidebarNode?
        let focusedViewType: ObjectIdentifier?
        init(_ outline: NSOutlineView, window: NSWindow) {
            selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? SidebarNode }
            expanded = (0..<outline.numberOfRows).compactMap { row in
                guard let node = outline.item(atRow: row) as? SidebarNode, outline.isExpandable(node) else { return nil }
                return (node, outline.isItemExpanded(node))
            }
            scroll = outline.enclosingScrollView?.contentView.bounds.origin
            responder = window.firstResponder
            if let view = responder as? NSView, outline.row(for: view) >= 0 {
                focusedRowNode = outline.item(atRow: outline.row(for: view)) as? SidebarNode
                focusedViewType = ObjectIdentifier(type(of: view))
            } else { focusedRowNode = nil; focusedViewType = nil }
        }
        func focusAgrees(_ outline: NSOutlineView, window: NSWindow) -> Bool {
            if let focusedRowNode, let focusedViewType {
                guard let view = window.firstResponder as? NSView, view.window === window else { return false }
                let row = outline.row(for: view)
                return row >= 0 && (outline.item(atRow: row) as? SidebarNode) === focusedRowNode
                    && ObjectIdentifier(type(of: view)) == focusedViewType
            }
            return window.firstResponder === responder
        }
    }

    static func run(_ browser: BrowserViewController) async -> [String: Any] {
        var records: [[String: Any]] = []
        var failure: String?
        var latestScrollChange = "NOT EXERCISED"
        do {
            guard browser.isVerificationSession, browser.volumes.isEmpty,
                  browser.rememberedFolders.isEmpty, browser.connectedLocationSnapshot.isEmpty,
                  browser.pinsController.collection.pins.isEmpty,
                  browser.remotePins.collection.pins.isEmpty,
                  browser.sidebarLayout.visibleSections == [.computer, .places, .locations],
                  let computer = browser.sidebarLayout.root(for: .computer),
                  let places = browser.sidebarLayout.root(for: .places),
                  let locations = browser.sidebarLayout.root(for: .locations),
                  let children = places.children, children.map(\.title) == ["Home", "Desktop", "Documents", "Downloads"],
                  browser.outline.isItemExpanded(places),
                  let window = browser.outline.window else {
                throw SidebarRowPresentationProbe.Failure(description: "generated-fixture-precondition")
            }
            let outline = browser.outline, adapter = browser.sidebarLayout
            let previousReconciliation = adapter.didReconcileNativeMoveForQualification
            let previousCompletion = adapter.didFinishNativeMoveForQualification
            defer {
                adapter.didReconcileNativeMoveForQualification = previousReconciliation
                adapter.didFinishNativeMoveForQualification = previousCompletion
            }
            let all = [computer, places] + children + [locations]
            let tokens = Dictionary(uniqueKeysWithValues: all.enumerated().map { (ObjectIdentifier($0.element), $0.offset + 1) })
            var expectedRoots = [computer, places, locations], expectedChildren = children
            let origin = browser.location
            func expected() -> [SidebarRowPresentationProbe.Expected] {
                expectedRoots.flatMap { root in
                    ([root] + (root === places ? expectedChildren : [])).map { node in
                        SidebarRowPresentationProbe.Expected(item: node, token: tokens[ObjectIdentifier(node)]!, title: node.title,
                            group: node.group, height: node.group ? InterfaceMetrics.points(24) : outline.rowHeight)
                    }
                }
            }
            func capture(_ label: String, settled: Bool) throws -> SidebarRowPresentationProbe.Sample {
                let sample = try SidebarRowPresentationProbe.sample(outline, expected: expected(), phase: label, settled: settled)
                records.append(["phase": label, "issues": sample.issues, "presentationChecked": sample.presentationChecked,
                    "rows": sample.rows.map { row in
                        ["row": row.index, "expectedToken": row.expectedToken, "nativeToken": row.itemToken ?? -1,
                         "renderedTexts": row.renderedTexts] as [String: Any]
                    }])
                return sample
            }
            func checkState(_ state: State, _ name: String) throws {
                let actualSelected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? SidebarNode }
                let selectionOK = actualSelected == state.selected
                let scrollOK = outline.enclosingScrollView?.contentView.bounds.origin == state.scroll
                let focusOK = state.focusAgrees(outline, window: window)
                let expansionOK = state.expanded.allSatisfy { outline.isItemExpanded($0.0) == $0.1 }
                let rootsOK = browser.sidebarRoots == expectedRoots
                let childrenOK = places.children == expectedChildren
                let locationOK = browser.location == origin
                records.append(["phase": name + ":preservation", "selectionAgrees": selectionOK,
                    "scrollAgrees": scrollOK, "focusAgrees": focusOK, "expansionAgrees": expansionOK,
                    "modelRootsAgree": rootsOK, "modelChildrenAgree": childrenOK, "locationAgrees": locationOK])
                guard selectionOK, scrollOK, focusOK, expansionOK, rootsOK, childrenOK, locationOK else {
                    throw SidebarRowPresentationProbe.Failure(description: name + ":preservation")
                }
            }
            func observe(_ boundary: CompletionBoundary) {
                adapter.didReconcileNativeMoveForQualification = { generation in
                    previousReconciliation?(generation); boundary.didReconcile(generation)
                }
                adapter.didFinishNativeMoveForQualification = { generation, reconciles in
                    previousCompletion?(generation, reconciles); boundary.didFinish(generation, reconciles: reconciles)
                }
            }
            func move(_ subject: BrowserSidebarLayoutAdapter.Subject, _ target: BrowserSidebarLayoutAdapter.Target) -> Bool {
                guard let fence = adapter.fence() else { return false }
                return adapter.move(subject, to: target, captured: fence)
            }
            try capture("adapter-baseline", settled: true).requireAgreement()
            func step(_ name: String, roots nextRoots: [SidebarNode], children nextChildren: [SidebarNode],
                      action: () -> Bool) async throws {
                let state = State(outline, window: window), boundary = CompletionBoundary(name)
                expectedRoots = nextRoots; expectedChildren = nextChildren
                boundary.sample = { _ in
                    try capture(name + ":actual-completion", settled: true).requireAgreement()
                    try checkState(state, name)
                }
                observe(boundary)
                guard action() else { throw SidebarRowPresentationProbe.Failure(description: name + ":action-refused") }
                try boundary.expect(adapter.pendingNativeMoveGenerationForQualification, reconciles: true)
                try capture(name + ":immediate", settled: false).requireAgreement()
                try await boundary.wait()
            }
            try await step("places-up-expanded", roots: [places, computer, locations], children: children) {
                move(.category(.places), .category(.computer))
            }
            try await step("places-down-expanded", roots: [computer, places, locations], children: children) {
                move(.category(.places), .category(.locations))
            }
            let nextChildren = [children[1], children[2], children[0], children[3]]
            guard let home = adapter.subject(for: children[0]) else {
                throw SidebarRowPresentationProbe.Failure(description: "home-subject")
            }
            try await step("home-down", roots: [computer, places, locations], children: nextChildren) {
                move(home, .row(.places, .stored(.place(.downloads))))
            }
            try await step("home-up", roots: [computer, places, locations], children: children) {
                move(home, .row(.places, .stored(.place(.desktop))))
            }
            func menu(_ title: String) -> Bool {
                guard let entries = adapter.drag.appendAlternatives(to: nil, for: places),
                      let item = entries.items.first(where: { $0.title == title }), item.isEnabled,
                      let action = item.action else { return false }
                return NSApp.sendAction(action, to: item.target, from: item)
            }
            try await step("native-menu-up", roots: [places, computer, locations], children: children) { menu("Move Up") }
            try await step("native-menu-down", roots: [computer, places, locations], children: children) { menu("Move Down") }

            func selectOnly(_ node: SidebarNode) throws {
                let row = outline.row(forItem: node)
                guard row >= 0 else { throw SidebarRowPresentationProbe.Failure(description: "focused-control:selection-row") }
                let updating = browser.updatingSidebarSelection
                browser.updatingSidebarSelection = true
                defer { browser.updatingSidebarSelection = updating }
                // A generated selection-control probe, not a navigation action.
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            func handle(in view: NSView) -> BrowserSidebarNameView? {
                if let value = view as? BrowserSidebarNameView { return value }
                for child in view.subviews { if let value = handle(in: child) { return value } }
                return nil
            }
            func focusHomeName() throws {
                try selectOnly(children[0])
                guard let cell = outline.view(atColumn: 0, row: outline.row(forItem: children[0]), makeIfNecessary: true),
                      let grip = handle(in: cell), window.makeFirstResponder(grip), window.firstResponder === grip else {
                    throw SidebarRowPresentationProbe.Failure(description: "focused-control:initial-focus")
                }
            }
            try focusHomeName()
            // No intervening input: the equivalent control in the recreated
            // cell must regain focus at actual completion, in both directions.
            try await step("focused-places-up", roots: [places, computer, locations], children: children) {
                move(.category(.places), .category(.computer))
            }
            try await step("focused-places-down", roots: [computer, places, locations], children: children) {
                move(.category(.places), .category(.locations))
            }

            // Both moves are admitted synchronously by this generated memory-only
            // owner while the Home name is focused. Neither MainActor completion
            // task can run between them; its logical focus must survive reversal.
            let reversal = CompletionBoundary("rapid-reversal")
            let reversalState = State(outline, window: window)
            reversal.sample = { _ in
                try capture("rapid-reversal:actual-completion", settled: true).requireAgreement()
                try checkState(reversalState, "rapid-reversal")
            }
            observe(reversal)
            expectedRoots = [places, computer, locations]
            guard move(.category(.places), .category(.computer)) else {
                throw SidebarRowPresentationProbe.Failure(description: "rapid-reversal:first-refused")
            }
            try reversal.expect(adapter.pendingNativeMoveGenerationForQualification, reconciles: false)
            try capture("rapid-reversal:first-immediate", settled: false).requireAgreement()
            expectedRoots = [computer, places, locations]
            guard move(.category(.places), .category(.locations)) else {
                throw SidebarRowPresentationProbe.Failure(description: "rapid-reversal:second-refused")
            }
            try reversal.expect(adapter.pendingNativeMoveGenerationForQualification, reconciles: true)
            try capture("rapid-reversal:second-immediate", settled: false).requireAgreement()
            try await reversal.wait()
            // Both actual completion attempts have now been observed; an older
            // callback arriving later cannot hide outside the acceptance window.
            try capture("rapid-reversal:both-finished", settled: true).requireAgreement()
            try checkState(reversalState, "rapid-reversal:both-finished")

            try focusHomeName()
            let beforeLatest = State(outline, window: window)
            let latest = CompletionBoundary("latest-choice")
            var latestState: State?
            latest.sample = { _ in
                guard let latestState else { throw SidebarRowPresentationProbe.Failure(description: "latest-choice:no-snapshot") }
                try capture("latest-choice:actual-completion", settled: true).requireAgreement()
                try checkState(latestState, "latest-choice")
            }
            observe(latest)
            expectedRoots = [places, computer, locations]
            guard move(.category(.places), .category(.computer)) else {
                throw SidebarRowPresentationProbe.Failure(description: "latest-choice:move-refused")
            }
            try latest.expect(adapter.pendingNativeMoveGenerationForQualification, reconciles: true)
            try capture("latest-choice:immediate", settled: false).requireAgreement()
            // These real UI changes precede queued reconciliation. They must
            // survive instead of the drag-start Home/name state. This does not
            // certify that a physical animation was still in flight.
            guard window.firstResponder === outline else {
                throw SidebarRowPresentationProbe.Failure(description: "latest-choice:focus-not-parked-before-selection")
            }
            // Keep the original assertion trigger: selection changes BEFORE
            // another control receives focus. Reordering this would mask it.
            try selectOnly(children[1])
            let search = browser.folderFilter.displayedField
            guard !browser.folderFilter.isCompact, search.isEnabled,
                  search.window === window, !search.isHiddenOrHasHiddenAncestor else {
                throw SidebarRowPresentationProbe.Failure(description: "latest-choice:visible-focus-target")
            }
            browser.folderFilter.focus()
            guard let changedResponder = window.firstResponder, changedResponder !== outline,
                  changedResponder !== beforeLatest.responder, search.currentEditor() === changedResponder else {
                throw SidebarRowPresentationProbe.Failure(description: "latest-choice:changed-focus")
            }
            let scrollBeforeChoice = outline.enclosingScrollView?.contentView.bounds.origin
            if let scroll = outline.enclosingScrollView {
                var bounds = scroll.contentView.bounds
                bounds.origin.y += InterfaceMetrics.points(12)
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            let changed = State(outline, window: window)
            guard changed.selected != beforeLatest.selected, changed.responder !== beforeLatest.responder else {
                throw SidebarRowPresentationProbe.Failure(description: "latest-choice:unchanged-control")
            }
            latestScrollChange = changed.scroll != scrollBeforeChoice ? "EXERCISED" : "NOT EXERCISED: no scroll delta/overflow"
            latestState = changed
            records.append(["phase": "latest-choice:changed-before-reconciliation", "selectionChanged": true,
                "focusChanged": true, "scrollChange": latestScrollChange,
                "animatedMotionEnabled": browser.settings.motion.allows(.pages)
                    && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion])
            try await latest.wait()
        } catch { failure = String(describing: error) }
        return ["passed": failure == nil, "failure": failure ?? "none", "samples": records,
            "settlingEvidence": "actual native reconciliation and completion-attempt callbacks; timeout refuses",
            "latestScrollChange": latestScrollChange, "latestDisclosureChange": "NOT EXERCISED",
            "changesDuringPhysicalAnimation": "NOT EXERCISED: latest choices precede reconciliation; raw timing is not asserted",
            "offscreenFocusedControl": "NOT EXERCISED", "dynamicSourceSupersession": "NOT EXERCISED",
            "realDragGesture": "NOT EXERCISED", "screenPixels": "NOT EXERCISED", "externalAccessibility": "NOT EXERCISED",
            "personalProfileReads": 0, "fileOperations": 0]
    }
}
#endif
