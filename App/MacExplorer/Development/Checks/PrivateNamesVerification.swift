#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import FileMemory
import FileOperations
import Search

/// Fresh, marked repo fixtures only. Exercises real AppKit/SwiftUI owners and
/// the same FileMemory APIs as ordinary UI; no owner catalog is opened.
@MainActor enum PrivateNamesVerification {
    private static func require(_ value: Bool, _ message: String) throws { try UIVerification.require(value, message) }
    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try require(condition(), message)
    }
    static func run(root: URL, browser: BrowserViewController, review: Bool) async throws -> [String: Any] {
        let expected = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/b07-authoring-search")
        try require(root.deletingLastPathComponent() == expected && UUID(uuidString: root.lastPathComponent) != nil
            && root.resolvingSymlinksInPath() == root && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Private-name generated fixture not admitted")
        let files = root.appendingPathComponent("Files"), first = files.appendingPathComponent("Actual report.txt")
        let second = files.appendingPathComponent("Second report.txt"), folder = files.appendingPathComponent("Folder")
        let scope = files.appendingPathComponent("Scope"), scoped = scope.appendingPathComponent("Scoped.txt")
        let settings = browser.settings
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        settings.showsHiddenFiles = true // Generated files live under the hidden .build root.
        let state = root.appendingPathComponent("state"), names = state.appendingPathComponent("private-names")
        let owner = ApplicationPrivateNames(directory: names, settings: settings)
        browser.privateNames = owner; browser.permitsBackgroundVerification = true
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        browser.navigate(to: .directory(files))
        try await wait("Private-name fixture listing") { !browser.isLoading && browser.orderingTask == nil }
        if review {
            _ = try await owner.save(AuthoredNames(nickname: "Orion plan", alternateNames: ["Release checklist"], labels: ["work", "review"]),
                source: first, id: nil, revision: nil, access: nil, allowFollowing: true)
            _ = try await owner.save(AuthoredNames(nickname: "Orion folder", labels: ["work"]), source: folder,
                id: nil, revision: nil, access: nil, allowFollowing: true)
            browser.view.window?.title = "B07.3 · generated Names & Labels review"
            browser.view.window?.makeKeyAndOrderFront(nil)
            browser.propertiesController.show(urls: [first], relativeTo: browser.view.window)
            return ["passed": true, "review": true, "generatedOnly": true, "checks": ["isolated profile", "native Properties editor", "quick sheet uses same records"]]
        }
        var checks: [String] = []
        func tracked(_ url: URL) throws -> Bool { var value = stat(); guard lstat(url.path, &value) == 0 else { throw UIVerification.Failure(message: "Generated source missing") }; return value.st_flags & UInt32(UF_TRACKED) != 0 }
        let cancelled = PrivateNamesEditorModel(owner: owner, settings: settings, access: { _ in nil })
        cancelled.select(first)
        try await wait("Passive private editor did not settle") { !cancelled.loading }
        cancelled.nickname = "Uncommitted private draft"; cancelled.cancel()
        try require(!FileManager().fileExists(atPath: state.path) && !(try tracked(first)) && cancelled.nickname.isEmpty, "Cancel or passive editor wrote state/tracking")
        checks.append("passive editor and Cancel create no storage or tracking")
        let editor = PrivateNamesEditorModel(owner: owner, settings: settings, access: { _ in nil })
        editor.select(first); try await wait("Authoring editor load") { !editor.loading }
        editor.nickname = "Orion plan"; editor.alternateDraft = "Actual report"; editor.labelDraft = "work:alpha"
        editor.save()
        try await wait("Explicit Remember consent did not appear") { !editor.saving && editor.showsConsent }
        try require(!FileManager().fileExists(atPath: names.path) && !(try tracked(first)), "Consent was bypassed")
        editor.allowAndSave()
        try await wait("Admitted Remember did not finish") { !editor.saving && !editor.loading && editor.itemID != nil }
        let id = editor.itemID!
        try require(try tracked(first), "Explicit Remember did not enable qualified following")
        var initial: (StoredNameSnapshot, RememberedNameUse)? = try await owner.snapshot(id)
        var captured: RememberedNamesSnapshot?
        _ = initial?.0.publish { captured = $0 }
        try require(captured?.names.nickname == "Orion plan" && captured?.names.labels == ["work:alpha"], "Native authoring did not save all fields")
        checks += ["one-time consent precedes source flag", "nickname alternates labels atomically saved", "first Remember selects Both"]
        // Release the explicit captured use before any later Forget.
        initial = nil
        editor.cancel()
        let properties = browser.propertiesController
        properties.update(urls: [first])
        try await wait("Properties names did not load") { properties.namesEditor?.loading == false && properties.namesEditor?.itemID == id }
        properties.update(urls: [first, second]); properties.update(urls: [first])
        try await wait("Properties did not reload after multiple selection") { properties.namesEditor?.loading == false && properties.namesEditor?.itemID == id }
        try require(properties.namesEditor?.nickname == "Orion plan", "Returning to one selected item retained an empty cancelled editor")
        properties.cancel()
        checks.append("Properties reloads its description after single/multiple/single selection")
        let a = PrivateNamesEditorModel(owner: owner, settings: settings, access: { _ in nil })
        let b = PrivateNamesEditorModel(owner: owner, settings: settings, access: { _ in nil })
        a.editSaved(id); b.editSaved(id)
        try await wait("Two saved editors did not load") { !a.loading && !b.loading }
        a.nickname = "Orion revised"; a.save()
        try await wait("First revised Save") { !a.saving && !a.loading }
        b.nickname = "Preserved stale draft"; b.save()
        try await wait("Conflicting draft did not return") { !b.saving }
        try require(b.nickname == "Preserved stale draft" && b.notice.contains("changed"), "Stale editor overwrote newer text or lost draft")
        a.cancel(); b.cancel()
        checks.append("two native editors preserve a conflicting draft")
        let secondID = try await owner.save(AuthoredNames(nickname: "Orion second"), source: second, id: nil, revision: nil, access: nil, allowFollowing: true)
        let folderID = try await owner.save(AuthoredNames(nickname: "Orion folder"), source: folder, id: nil, revision: nil, access: nil, allowFollowing: true)
        _ = try await owner.save(AuthoredNames(nickname: "Orion scoped"), source: scoped, id: nil, revision: nil, access: nil, allowFollowing: true)
        let search = browser.metadataSearch
        search.sources = .saved; search.show(scopeIndex: 0, copyFilter: false)
        search.queryField.stringValue = "Orion"; search.submit()
        try await wait("Saved-name search did not settle") { !browser.isLoading && !search.savedNames.isRunning && browser.orderingTask == nil }
        try require(Set(browser.rawEntries.map(\.url)) == Set([first, second, folder, scoped]), "Saved results lost verified scoped entries")
        try require(search.savedNames.reason(first).contains("Nickname"), "Saved reason missing")
        search.kindPopup.selectItem(at: 2); search.submit()
        try await wait("Saved metadata filter did not settle") { !browser.isLoading && !search.savedNames.isRunning && browser.orderingTask == nil }
        try require(browser.rawEntries.map(\.url) == [folder], "Saved query ignored fresh folder-kind filter")
        search.kindPopup.selectItem(at: 0)
        search.queryField.stringValue = "work:alpha"; search.submit()
        try await wait("Literal saved-label query") { !browser.isLoading && !search.savedNames.isRunning && browser.orderingTask == nil }
        try require(browser.rawEntries.map(\.url) == [first], "Typed label punctuation was reinterpreted")
        search.sources = .both; search.queryField.stringValue = "Actual report"; search.submit()
        try await wait("Both search did not settle") { !browser.isLoading && !search.hasActiveSession && !search.savedNames.isRunning && browser.orderingTask == nil }
        try require(browser.rawEntries.filter { $0.url == first }.count == 1 && search.savedNames.reason(first).contains("Filename")
            && search.savedNames.reason(first).contains("Alternate name"), "Independent search lanes failed verified deduplication")
        search.cancel(); browser.navigate(to: .directory(scope))
        try await wait("Narrow folder listing") { !browser.isLoading && browser.orderingTask == nil }
        search.sources = .saved; search.show(scopeIndex: 0, copyFilter: false); search.queryField.stringValue = "Orion"; search.submit()
        try await wait("Narrow saved query") { !browser.isLoading && !search.savedNames.isRunning && browser.orderingTask == nil }
        try require(browser.rawEntries.map(\.url) == [scoped], "Saved search leaked out-of-scope locations")
        checks += ["Saved Names current-reference results", "Both deduplicates with both reasons", "folder scope excludes other remembered locations"]
        search.cancel(); browser.navigate(to: .directory(files))
        try await wait("Address fixture listing") { !browser.isLoading && browser.orderingTask == nil }
        search.sources = .saved; search.show(scopeIndex: 1, copyFilter: false); search.externalToggle.state = .off
        search.queryField.stringValue = "Orion"; search.submit()
        try await wait("Saved This Mac internal-only query") { !browser.isLoading && !search.savedNames.isRunning && browser.orderingTask == nil }
        let internalVolume = try await Task.detached { try first.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal == true }.value
        try require(search.scopePopup.indexOfSelectedItem == 1 && browser.rawEntries.count == (internalVolume ? 4 : 0), "Internal-only search ignored native volume classification or selected scope")
        search.externalToggle.state = .on; search.submit()
        try await wait("Saved external opt-in query") { !browser.isLoading && !search.savedNames.isRunning && browser.orderingTask == nil }
        try require(browser.rawEntries.count == 4, "External opt-in failed to admit verified Workspace records")
        search.cancel()
        checks += ["saved results obey fresh type filters", "label punctuation stays literal", "This Mac external-drive opt-in enforced"]
        browser.addressCompletion.nameLocationsForVerification = []
        browser.focusLocation(nil)
        guard let textEditor = browser.pathField.currentEditor() as? NSTextView else { throw UIVerification.Failure(message: "Native address editor absent") }
        textEditor.insertText("Orion", replacementRange: NSRange(location: 0, length: textEditor.string.utf16.count))
        textEditor.setSelectedRange(NSRange(location: 5, length: 0)); browser.addressCompletion.changed()
        try await wait("Saved folder suggestion missing") { browser.addressCompletion.suggestions.contains { $0.url == folder && $0.source == .savedName } }
        try require(!browser.addressCompletion.suggestions.contains { $0.url == first }, "A file nickname became a folder address")
        settings.privateNamesAddressSuggestions = false
        try await wait("Suggestion opt-out did not retire work") { browser.addressCompletion.suggestions.isEmpty }
        browser.cancelLocationEditing(); settings.privateNamesAddressSuggestions = true
        checks += ["address admits only verified directories", "live suggestion opt-out retires saved text"]
        let history = state.appendingPathComponent("operation-recovery")
        let engine = browser.operationCoordinator.engine(at: history)
        for protected in [names, state] {
            do { _ = try await engine.prepareTransfer(sources: [protected], destinationDirectory: files, move: false); throw UIVerification.Failure(message: "Live names overlap admitted") }
            catch FileOperationFailure.protectedLocation {} catch FileOperationFailure.operationHistoryProtected {}
        }
        do { _ = try await engine.prepareTransfer(sources: [first], destinationDirectory: names, move: false); throw UIVerification.Failure(message: "Copy into names admitted") }
        catch FileOperationFailure.protectedLocation {} catch FileOperationFailure.operationHistoryProtected {}
        let protectedRequests: [FileOperationRequest] = [.rename(source: names, name: "Changed names"),
            .createFolder(parent: names, name: "Unwanted Folder"), .trash(sources: [names])]
        for request in protectedRequests {
            let refused = await engine.perform(request)
            try require(refused.recordID == nil && refused.result.items.contains { $0.status == .failed(.protectedLocation) || $0.status == .failed(.operationHistoryProtected) }, "A direct file command bypassed names protection")
        }
        try require(!FileManager().fileExists(atPath: history.path), "Protection preflight created history")
        checks.append("ordinary transfers protect live names, ancestors and destinations without creating history")
        try await owner.removeAccess(secondID)
        try require(try await owner.availability(secondID).availability == .accessRemoved, "Remove Access did not persist")
        let editAfterAccess = PrivateNamesEditorModel(owner: owner, settings: settings, access: { _ in nil })
        editAfterAccess.editSaved(secondID); try await wait("Access-removed names unavailable to editor") { !editAfterAccess.loading }
        editAfterAccess.nickname = "Orion retained"; editAfterAccess.save(); try await wait("Description-only Save needed source access") { !editAfterAccess.saving && !editAfterAccess.loading }
        try require(try await owner.availability(secondID).availability == .accessRemoved, "Editing names restored access")
        editAfterAccess.cancel()
        do { try await owner.relink(secondID, source: first, access: nil, allowFollowing: true); throw UIVerification.Failure(message: "Duplicate Relink merged descriptions") }
        catch RememberedReferenceFailure.alreadyRemembered(let target) { try require(target == id, "Duplicate target wrong") }
        checks += ["Remove Access preserves editable names", "label edit cannot restore access", "duplicate Relink refuses merge"]
        let failureDirectory = state.appendingPathComponent("failure-names")
        let failing = ApplicationPrivateNames(directory: failureDirectory, settings: settings)
        let failureID = try await failing.save(AuthoredNames(nickname: "Generated privacy failure"), source: files.appendingPathComponent("Outside.txt"),
            id: nil, revision: nil, access: nil, allowFollowing: true)
        try require(chmod(failureDirectory.path, 0o500) == 0, "Could not prepare generated permission denial")
        let failedForget = try await failing.forget(failureID)
        try require(failedForget == .sessionHiddenOnly && failing.pendingForget == failureID && failing.status.contains("only in this session"),
            "Failed Forget claimed durable removal or lost its retry action")
        let archived = root.appendingPathComponent("before-forget-retry")
        try FileManager().copyItem(at: failureDirectory, to: archived)
        try require(chmod(failureDirectory.path, 0o700) == 0, "Could not restore generated permissions")
        try await failing.retryForget()
        try require(failing.pendingForget == nil && failing.status.isEmpty, "Retry Forget did not finish")
        await failing.close()
        checks += ["unsafe catalog permissions report session-only Forget", "failed catalog preserved before explicit retry", "Retry Forget completes without a source mutation"]
        let accessFailure = ApplicationPrivateNames(directory: failureDirectory, settings: settings)
        let accessID = try await accessFailure.save(AuthoredNames(nickname: "Generated access failure"), source: files.appendingPathComponent("Outside.txt"),
            id: nil, revision: nil, access: nil, allowFollowing: false)
        try require(chmod(failureDirectory.path, 0o500) == 0, "Generated access denial unavailable")
        do { try await accessFailure.removeAccess(accessID); throw UIVerification.Failure(message: "Denied access removal claimed success") }
        catch NameStoreFailure.recoveryRequired {}
        try require(accessFailure.pendingAccessRemoval == accessID && accessFailure.status.contains("only in this session"), "Access failure lost its honest retry state")
        try FileManager().copyItem(at: failureDirectory, to: root.appendingPathComponent("before-access-retry"))
        try require(chmod(failureDirectory.path, 0o700) == 0, "Generated access permissions restore failed")
        try await accessFailure.retryAccessRemoval()
        try require(try await accessFailure.availability(accessID).availability == .accessRemoved && accessFailure.pendingAccessRemoval == nil, "Retry access removal did not finish")
        await accessFailure.close()
        checks.append("guard refusal before access fence retains an explicit retry and then removes access")
        let forgetEditor = PrivateNamesEditorModel(owner: owner, settings: settings, access: { _ in nil })
        var clears = 0; forgetEditor.clearNativeUndo = { clears += 1 }; forgetEditor.editSaved(folderID)
        try await wait("Forget editor load") { !forgetEditor.loading }
        search.sources = .saved; search.show(scopeIndex: 0, copyFilter: false); search.queryField.stringValue = "Orion"; search.submit()
        try await wait("Forget search prepare") { !browser.isLoading && !search.savedNames.isRunning && browser.orderingTask == nil }
        browser.view.window?.makeFirstResponder(search.queryField)
        guard let queryEditor = search.queryField.currentEditor() as? NSTextView else { throw UIVerification.Failure(message: "Forget query field editor absent") }
        queryEditor.insertText(" private", replacementRange: NSRange(location: queryEditor.string.utf16.count, length: 0))
        let draftWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        draftWindow.isReleasedWhenClosed = false
        let draftEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100)); draftEditor.allowsUndo = true
        draftWindow.contentView = draftEditor; draftWindow.makeFirstResponder(draftEditor)
        draftEditor.insertText("Generated private draft", replacementRange: NSRange(location: 0, length: 0))
        forgetEditor.clearNativeUndo = { clears += 1; clearPrivateTextUndo(in: draftWindow) }
        defer { draftWindow.close() }
        let outcome = try await owner.forget(folderID)
        try await wait("Forget left saved rows published") { !search.savedNames.matches.keys.contains(folder) && browser.orderingTask == nil }
        try require(outcome == .forgotten && forgetEditor.nickname.isEmpty && clears > 0 && search.queryField.stringValue.isEmpty
            && queryEditor.string.isEmpty && queryEditor.undoManager?.canUndo != true
            && draftEditor.string.isEmpty && draftEditor.undoManager?.canUndo != true
            && browser.rawEntries.isEmpty && (try tracked(folder)), "Forget did not clear editor/search/Undo or unset tracking")
        forgetEditor.cancel(); search.cancel(restoreFolder: false)
        await owner.close()
        let passiveClosing = ApplicationPrivateNames(directory: names, settings: settings)
        let passiveOpen = Task { try? await passiveClosing.readableStore() }
        await Task.yield()
        await passiveClosing.close(); _ = await passiveOpen.value
        browser.suspendBrowser()
        try await wait("Native names work did not drain") { ApplicationFileActivity.gate.activeCount == 0 }
        checks += ["Forget withdraws search/editor text and native Undo", "Forget preserves native following", "close drains an in-flight passive catalog open", "closed native views drain actual file activity"]
        return ["passed": true, "review": false, "checks": checks, "gateActive": ApplicationFileActivity.gate.activeCount]
    }
}
#endif
