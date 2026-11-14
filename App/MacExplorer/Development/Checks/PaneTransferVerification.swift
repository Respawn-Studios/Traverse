#if DEBUG
    import AppKit
    import ExplorerCore
    import FileOperations

    @MainActor enum PaneTransferVerification {
        static func run(root: URL, workspace: BrowserWorkspaceController, capture: Bool) async throws -> [String: Any] {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            try check(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/workspace-action-qualification")
                && root.resolvingSymlinksInPath() == root
                && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                "Pane action QA requires its exact generated case")
            let admitted = try await Task.detached {
                guard let data = try BrowserSnapshotFile(directory: root, name: "reservation.json", maximumBytes: 4096).read(),
                    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return value["packet"] as? String == "workspace-actions-v1"
            }.value
            try check(admitted, "Pane action case is not reserved")
            try check(workspace.isViewLoaded && workspace.view.window != nil,
                "Pane action QA requires the actual window workspace composition")
            try await wait { workspace.sessionReady }
            let left = workspace.activeBrowser
            left.permitsBackgroundVerification = true
            let settings = left.settings
            settings.autoRefreshFolders = false
            settings.folderSummariesEnabled = false
            settings.reviewsRecoveryAtStartup = false
            settings.showsDockProgress = false
            settings.motion.mode = .off
            let engine = left.operationCoordinator.engine(at: root.appendingPathComponent("journal"))
            left.recoverableFileOperations = engine
            let queue = left.operationCoordinator.transfers
            let board = NSPasteboard.withUniqueName()
            board.setString("Generated pane clipboard sentinel", forType: .string)
            left.transferPasteboard = board
            let clipboardCount = board.changeCount
            defer {
                board.releaseGlobally()
                for browser in workspace.browsers.values {
                    browser.paneTransfers.presentForVerification = nil
                    browser.transferConflictPrompt = nil
                    browser.operationResultPresenter = nil
                    browser.operationErrorPresenter = nil
                }
            }
            let source = root.appendingPathComponent("source/Source")
            let destination = root.appendingPathComponent("source/Destination")
            let alternative = root.appendingPathComponent("source/Alternative")
            let copy = source.appendingPathComponent("Copy.txt")
            let move = source.appendingPathComponent("Move.txt")
            let conflict = source.appendingPathComponent("Conflict.txt")
            left.navigate(to: .directory(source))
            try await wait { settled(left) && left.rowsByURL[copy] != nil }
            func select(_ url: URL) {
                workspace.activate(left)
                left.renderFilePresentation(selection: [url])
                left.fileSelectionDidChange()
            }
            func prepare(_ url: URL = copy) async throws {
                left.refresh(nil)
                try await wait { settled(left) && left.rowsByURL[url] != nil }
                select(url)
            }
            var checks: [String] = []
            select(copy)
            try check(!left.canTransferToOtherPane, "Single-pane transfer was enabled")
            try check(workspace.splitActive(at: .trailing), "Generated destination pane could not open")
            let right = workspace.activeBrowser
            right.permitsBackgroundVerification = true
            try await wait { settled(right) }
            select(copy)
            try check(!left.canTransferToOtherPane, "Same-folder target was offered")
            right.navigate(to: .directory(destination))
            try await wait { settled(right) && right.rowsByURL[destination.appendingPathComponent("Conflict.txt")] != nil }
            select(copy)
            for browser in [left, right] {
                browser.operationResultPresenter = { _ in }
                browser.operationErrorPresenter = { _ in }
            }
            try check(left.canTransferToOtherPane && !right.canTransferToOtherPane, "Active-pane command ownership differs")
            let context = BrowserMenus.fileContextMenu(target: left)
            try check([BrowserCommand.copyToPane, .moveToPane].allSatisfy { command in
                context.items.contains { $0.action == command.selector && left.commandEnabled($0.action) }
            }, "File context menu lacks enabled pane transfer actions")
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            left.view.addSubview(text)
            left.view.window?.makeFirstResponder(text)
            try check(!left.canTransferToOtherPane, "Text editing admitted a pane transfer")
            text.removeFromSuperview(); left.focusBrowserContent()
            checks.append("Single/same-folder/inactive panes and text editing refuse transfers")

            // Actual File menu action; change the destination after queue admission.
            queue.pause()
            let menu = BrowserMenus.menu(.file, target: left)
            guard let index = menu.items.firstIndex(where: { $0.action == #selector(left.copyToOtherPane(_:)) }) else {
                throw UIVerification.Failure(message: "File menu lacks pane Copy")
            }
            let prior = Set(queue.results.map(\.id))
            menu.performActionForItem(at: index)
            try check(queue.state.waiting.count == 1, "Copy action did not reserve one queued transfer")
            right.navigate(to: .directory(alternative))
            try check(queue.resume(), "Generated Copy queue could not resume")
            try await wait { !queue.hasOutstandingWork && queue.results.contains(where: { !prior.contains($0.id) }) }
            guard let copied = queue.results.first(where: { !prior.contains($0.id) }), let copyID = copied.outcome.recordID else {
                throw UIVerification.Failure(message: "Queued Copy lacks its exact operation")
            }
            let copyBytes = try await Task.detached {
                try Data(contentsOf: copy) == Data(contentsOf: destination.appendingPathComponent("Copy.txt"))
                    && !FileManager().fileExists(atPath: alternative.appendingPathComponent("Copy.txt").path)
            }.value
            try check(copied.outcome.result.disposition == .succeeded && copyBytes,
                "Copy changed its captured destination or bytes")
            let undoneCopy = await engine.undo(recordID: copyID)
            try check(undoneCopy.result.disposition == .succeeded, "Exact queued Copy Undo failed")
            checks.append("Native File action queues Copy to the captured pane folder and exact Undo succeeds")

            right.navigate(to: .directory(destination))
            try await wait { settled(right) }
            try await prepare(move)
            let beforeMove = Set(queue.results.map(\.id))
            left.moveToOtherPane(nil)
            try await wait { !queue.hasOutstandingWork && queue.results.contains(where: { !beforeMove.contains($0.id) }) }
            guard let moved = queue.results.first(where: { !beforeMove.contains($0.id) }), let moveID = moved.outcome.recordID else {
                throw UIVerification.Failure(message: "Queued Move lacks an exact operation")
            }
            let movedBytes = try await Task.detached {
                let payload = try Data(contentsOf: destination.appendingPathComponent("Move.txt"))
                return !FileManager().fileExists(atPath: move.path) && payload == Data("Generated move payload\n".utf8)
            }.value
            try check(moved.outcome.result.disposition == .succeeded && movedBytes, "Queued pane Move differs")
            let undoneMove = await engine.undo(recordID: moveID)
            let restoredMove = try await Task.detached {
                try Data(contentsOf: move) == Data("Generated move payload\n".utf8)
                    && !FileManager().fileExists(atPath: destination.appendingPathComponent("Move.txt").path)
            }.value
            try check(undoneMove.result.disposition == .succeeded && restoredMove, "Exact queued Move Undo failed")
            checks.append("Direct pane Move and exact Undo preserve generated source bytes")

            // Cancel and Skip retain both source and pre-existing destination.
            for cancel in [true, false] {
                try await prepare(conflict)
                var prompts = 0
                left.transferConflictPrompt = { conflicts in
                    prompts += 1
                    return cancel ? nil : Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .skip) })
                }
                let before = Set(queue.results.map(\.id))
                left.copyToOtherPane(nil)
                try await wait { !queue.hasOutstandingWork && queue.results.contains(where: { !before.contains($0.id) }) }
                let unchanged = try await Task.detached {
                    try Data(contentsOf: conflict) == Data("Generated source conflict\n".utf8)
                        && Data(contentsOf: destination.appendingPathComponent("Conflict.txt")) == Data("Generated existing destination\n".utf8)
                }.value
                try check(prompts == 1 && unchanged, "Conflict Cancel/Skip changed existing files")
                _ = queue.resume()
            }
            left.transferConflictPrompt = nil
            checks.append("Conflict Cancel and Skip each preserve both generated files")

            try await prepare()
            workspace.activate(right)
            try check(workspace.splitActive(at: .bottom), "Third generated pane could not open")
            let third = workspace.activeBrowser
            third.permitsBackgroundVerification = true
            third.navigate(to: .directory(alternative))
            try await wait { settled(third) }
            select(copy)
            func choose(_ id: UUID, in menu: NSMenu) {
                if let index = menu.items.firstIndex(where: { $0.representedObject as? UUID == id }) {
                    menu.performActionForItem(at: index)
                }
            }
            let beforeCancel = queue.results.count
            var offered = 0
            left.paneTransfers.presentForVerification = { offered = $0.items.count }
            left.copyToOtherPane(nil)
            try check(offered == 2 && queue.results.count == beforeCancel && !queue.hasOutstandingWork,
                "Multi-pane menu Cancel admitted work")

            // Every callback selects a previously offered menu item after staling it.
            for change in 0..<4 {
                try await prepare()
                let before = queue.results.count
                left.paneTransfers.presentForVerification = { menu in
                    switch change {
                    case 0: select(move)
                    case 1: left.newTab(nil)
                    case 2: left.refresh(nil)
                    default: right.navigate(to: .directory(alternative))
                    }
                    choose(right.paneID, in: menu)
                }
                left.moveToOtherPane(nil)
                try check(!queue.hasOutstandingWork && queue.results.count == before,
                    "Stale source selection/tab/visit or destination admitted work")
                if change == 1 { left.closeTab(nil) }
                right.navigate(to: .directory(destination))
                try await wait { settled(left) && settled(right) }
            }
            checks.append("Multiple peers require a choice; Cancel and changed source/target contexts admit nothing")

            try await prepare()
            left.paneTransfers.presentForVerification = { menu in choose(third.paneID, in: menu) }
            let beforeChoice = Set(queue.results.map(\.id))
            left.copyToOtherPane(nil)
            try await wait { !queue.hasOutstandingWork && queue.results.contains(where: { !beforeChoice.contains($0.id) }) }
            guard let chosenCopy = queue.results.first(where: { !beforeChoice.contains($0.id) }), let chosenID = chosenCopy.outcome.recordID else {
                throw UIVerification.Failure(message: "Chosen third-pane Copy has no record")
            }
            let chosenBytes = try await Task.detached {
                try Data(contentsOf: alternative.appendingPathComponent("Copy.txt")) == Data(contentsOf: copy)
            }.value
            try check(chosenCopy.outcome.result.disposition == .succeeded && chosenBytes,
                "Multi-pane choice copied to a different folder")
            if capture, let window = workspace.view.window {
                settings.appearance = .dark
                settings.navigationStyle = .glass
                settings.glassFileContent = true
                third.refresh(nil)
                try await wait { settled(third) && third.rowsByURL[alternative.appendingPathComponent("Copy.txt")] != nil }
                window.title = "Generated pane transfers · " + root.lastPathComponent.prefix(8)
                window.makeKeyAndOrderFront(nil)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/panes-native.png"))
            }
            let chosenUndo = await engine.undo(recordID: chosenID)
            try check(chosenUndo.result.disposition == .succeeded, "Chosen pane Copy Undo failed")
            checks.append("Explicit third-pane selection uses the intended destination and exact Undo")

            // Remote location is a value only: no network session is created.
            third.navigate(to: .smb(.init(connectionID: UUID(), directoryID: UUID(), displayHint: "Generated offline peer")))
            try await wait { settled(third) }
            try await prepare()
            var unexpectedMenu = false
            left.paneTransfers.presentForVerification = { _ in unexpectedMenu = true }
            queue.pause()
            for _ in 0..<16 { left.copyToOtherPane(nil) }
            try check(!unexpectedMenu && queue.state.waiting.count == 16 && !left.canTransferToOtherPane,
                "Remote peer was offered or the bounded queue did not refuse admission")
            left.moveToOtherPane(nil)
            try check(queue.state.waiting.count == 16, "Full queue admitted another transfer")
            queue.cancelAllWaiting()
            _ = queue.resume()
            try await wait { queue.isIdleForVolumeAction && !queue.hasOutstandingWork }
            checks.append("Remote targets are excluded and full/cancelled waiting queues preserve the existing bounds")

            third.navigate(to: .directory(alternative))
            try await wait { settled(third) }
            try await prepare()
            left.paneTransfers.presentForVerification = { menu in
                workspace.activate(right)
                _ = workspace.closeActivePane()
                workspace.activate(left)
                choose(right.paneID, in: menu)
            }
            left.moveToOtherPane(nil)
            try check(!queue.hasOutstandingWork, "Closed destination pane admitted work")
            try check(board.changeCount == clipboardCount && board.string(forType: .string) == "Generated pane clipboard sentinel",
                "Pane transfer changed the isolated clipboard")
            try await wait { ApplicationFileActivity.gate.activeCount == 0 }
            checks.append("Closed destination refuses; isolated clipboard is unchanged and all work drains")
            return ["passed": true, "checks": checks, "networkRequests": 0, "personalFiles": 0,
                "systemClipboardWrites": 0, "physicalInput": false, "localActivityAfterDrain": 0,
                "compositorCapture": capture, "ordinaryPaneTransfersEnabled": PaneTransferFeature.enabled]
        }

        private static func settled(_ browser: BrowserViewController) -> Bool {
            !browser.isLoading && browser.orderingTask == nil && browser.directoryRefreshTask == nil
        }
        private static func check(_ value: Bool, _ message: String) throws { try UIVerification.require(value, message) }
        private static func wait(_ predicate: () -> Bool) async throws {
            let end = ProcessInfo.processInfo.systemUptime + 25
            while !predicate() {
                try check(ProcessInfo.processInfo.systemUptime < end, "Generated pane action did not settle")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
#endif
