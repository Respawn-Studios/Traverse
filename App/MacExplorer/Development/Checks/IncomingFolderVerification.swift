#if DEBUG
    import AppKit
    import ExplorerCore

    @MainActor enum IncomingFolderVerification {
        /// Real AppKit service-pasteboard decoding only. Registration, Finder
        /// dispatch and sandbox grants have separate installed acceptance.
        static func servicePayloads(folder: URL) throws -> [String] {
            let board = NSPasteboard(name: .init("traverse.generated.folder-service." + UUID().uuidString))
            defer { board.clearContents() }
            var received: [[URL]] = []
            let service = IncomingFolderService { received.append($0) }
            var error: NSString?
            let unicode = folder.appendingPathComponent("Café 100% #complete")
            try UIVerification.require(board.writeObjects([folder as NSURL, unicode as NSURL]), "Generated service URLs could not be written")
            service.openFoldersInTraverse(board, userData: nil, error: &error)
            try UIVerification.require(error == nil && received.count == 1 && received[0].map(\.path) == [folder.path, unicode.path],
                "Folder service did not preserve exact local file URLs")
            board.clearContents(); board.setString(folder.path, forType: .string)
            service.openFoldersInTraverse(board, userData: nil, error: &error)
            try UIVerification.require(error != nil && received.count == 1, "Folder service interpreted text as a file URL")
            let text = NSPasteboardItem(); text.setString("generated unrelated text", forType: .string)
            board.clearContents(); _ = board.writeObjects([folder as NSURL, text])
            service.openFoldersInTraverse(board, userData: nil, error: &error)
            try UIVerification.require(error != nil && received.count == 1, "Folder service accepted a mixed payload subset")
            board.clearContents(); _ = board.writeObjects(Array(repeating: folder as NSURL, count: 17))
            service.openFoldersInTraverse(board, userData: nil, error: &error)
            try UIVerification.require(error != nil && received.count == 1 && !IncomingFolderService.available,
                "Folder service batch limit or ordinary-Debug registration boundary changed")
            return ["Folder-only Services decoding preserves exact local URLs and refuses text, mixed and oversized payloads without reading the general clipboard",
                "Ordinary Debug exposes no folder Service; actual installed Finder dispatch and sandbox grants remain unexercised"]
        }
        static func run(root: URL) async throws -> [String: Any] {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            try UIVerification.require(
                root.deletingLastPathComponent() == repo.appendingPathComponent(".build/overnight-foundation")
                    && root.resolvingSymlinksInPath() == root
                    && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                "Incoming-folder QA requires its owned generated case")
            let source = root.appendingPathComponent("source")
            let first = source.appendingPathComponent("Folder A")
            let second = source.appendingPathComponent("Café 100% complete")
            let profileFolder = source.appendingPathComponent("Profile Folder")
            let store = LaunchProfileStore(directory: root.appendingPathComponent("profiles"))
            let pane = UUID()
            let layout = PaneLayout(paneID: pane)
            let sample = PaneWorkspaceSnapshot(
                layout: layout, activePane: pane,
                panes: [
                    .init(
                        id: pane, tabs: .init(tabs: [.init(location: .init(kind: .directory, url: profileFolder))]),
                        viewMode: "Details")
                ])
            let saved = try await store.edit(expected: nil) { try $0.add(name: "Generated startup", snapshot: sample) }
            let settings = BrowserSettings(persist: false)
            try await settings.chooseStartup(.profile, profile: saved.library.profiles[0].id)
            let cold = BrowserWindowController(settings: settings)
            cold.workspace.launchProfileStore = store
            cold.browser.permitsBackgroundVerification = true
            cold.window?.setFrameOrigin(NSPoint(x: -12000, y: -12000))
            defer {
                cold.suspendBrowsing()
                cold.window?.close()
            }
            let incoming = IncomingFolderOpening()
            incoming.receive([first, first, second])  // Deliberately before application/window attachment.
            incoming.attach(cold)
            cold.beginBrowsing()
            await incoming.waitForVerification()
            try UIVerification.require(
                cold.workspace.sessionReady && cold.workspace.hasIncomingFolderRequest
                    && incoming.openedCount == 2 && cold.browser.tabs.count == 2
                    && cold.browser.location == .directory(second),
                "Cold incoming folders lost precedence, duplicates or exact names")
            try UIVerification.require(
                !cold.browser.tabs.contains { $0.location == .directory(profileFolder) },
                "Startup profile overrode explicit incoming locations")
            incoming.receive([first, second])
            await incoming.waitForVerification()
            try UIVerification.require(
                cold.browser.tabs.count == 2 && cold.browser.location == .directory(second),
                "Warm opening duplicated existing tabs")
            let unchanged = cold.browser.tabs.map(\.id)
            let initialCount = incoming.openedCount
            for name in ["Plain.txt", "Bundle.app", "Folder Link", "Missing"] {
                incoming.receive([source.appendingPathComponent(name)])
                await incoming.waitForVerification()
                try UIVerification.require(
                    cold.browser.tabs.map(\.id) == unchanged && incoming.openedCount == initialCount,
                    "Unsupported, missing or linked item became a folder tab")
            }
            incoming.receive([URL(string: "smb://server/share")!])
            await incoming.waitForVerification()
            try UIVerification.require(incoming.openedCount == initialCount, "Remote URL reached local folder delivery")
            let reservation = UUID()
            let coordinator = cold.browser.operationCoordinator
            try UIVerification.require(
                coordinator.beginPreparation(owner: reservation), "Generated busy interval could not start")
            incoming.receive([first])
            await incoming.waitForVerification()
            coordinator.finishPreparation(owner: reservation)
            try UIVerification.require(
                incoming.openedCount == initialCount && cold.browser.tabs.map(\.id) == unchanged,
                "Busy window accepted incoming delivery")
            incoming.beforePublication = { cold.browser.navigate(to: .directory(profileFolder)) }
            incoming.receive([first])
            await incoming.waitForVerification()
            incoming.beforePublication = nil
            try UIVerification.require(
                incoming.openedCount == initialCount && cold.browser.location == .directory(profileFolder),
                "Stale probe stole a newer visit")
            cold.suspendBrowsing()
            incoming.receive([first])
            await incoming.waitForVerification()
            try UIVerification.require(
                !cold.workspace.isClosing && cold.browser.location == .directory(first),
                "Incoming request did not reopen a closed workspace")
            let acquired = await cold.browser.folderAccess.acquireAccess(to: first)
            try UIVerification.require(acquired?.url == first, "Incoming URL grant was not retained for actual readers")
            acquired?.close()
            await incoming.closeAndDrain()

            let gate = FileActivityGate(maximumActivities: 1)
            let held = DispatchSemaphore(value: 0)
            let blocked = IncomingFolderOpening(activity: gate, beforeRead: { held.wait() })
            blocked.attach(cold)
            blocked.receive([second])
            try await wait { gate.activeCount == 1 }
            var closed = false
            let close = Task {
                await blocked.closeAndDrain()
                closed = true
            }
            try await Task.sleep(for: .milliseconds(30))
            try UIVerification.require(
                !closed && gate.activeCount == 1, "Cancellation released a blocked native probe early")
            held.signal()
            await close.value
            try UIVerification.require(
                closed && gate.activeCount == 0 && blocked.openedCount == 0,
                "Closed probe published or retained activity")
            let final = try await store.load()
            try UIVerification.require(
                final.revision == saved.revision, "Incoming opening changed saved profile storage")
            // Deliver after startup has already captured its selected profile.
            // The newer incoming intent must still win when the read returns.
            let lateSettings = BrowserSettings(persist: false)
            try await lateSettings.chooseStartup(.profile, profile: saved.library.profiles[0].id)
            let late = BrowserWindowController(settings: lateSettings)
            late.workspace.launchProfileStore = store
            late.browser.permitsBackgroundVerification = true
            var waiting = false
            var release: CheckedContinuation<Void, Never>?
            late.workspace.persistence.beforeRestoreResult = {
                waiting = true
                await withCheckedContinuation { release = $0 }
            }
            defer {
                late.suspendBrowsing()
                late.window?.close()
            }
            let lateIncoming = IncomingFolderOpening()
            lateIncoming.attach(late)
            late.beginBrowsing()
            try await wait { waiting }
            lateIncoming.receive([first])
            release?.resume()
            release = nil
            await lateIncoming.waitForVerification()
            try UIVerification.require(
                late.browser.tabs.count == 1 && late.browser.location == .directory(first),
                "Incoming intent lost to a previously submitted startup read")
            await lateIncoming.closeAndDrain()
            return [
                "passed": true, "coldStartupPrecedence": true, "warmDuplicateReuse": true,
                "incomingDuringStartupWins": true,
                "unicodePercentNames": true, "filePackageLinkMissingRefused": true, "remoteSchemesRefused": true,
                "busyAndNewerVisitWin": true, "closedWindowReopens": true, "originalGrantRetained": true,
                "actualBlockedProbeDrains": true, "savedProfilesUnchanged": true,
                "systemDefaultChanged": false, "fileBodiesRead": 0, "operationMutations": 0,
                "notExercised": [
                    "Launch Services external delivery", "Sandbox dynamic grants", "Default-handler change",
                ],
            ]
        }
        private static func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<600 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw UIVerification.Failure(message: "Generated incoming-folder work did not settle")
        }
    }
#endif
