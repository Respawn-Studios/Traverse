#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import ExplorerCore
import FileOperations
import LocalStorage

@MainActor enum GitBrowserVerification {
    static func run(in workspace: BrowserWorkspaceController, window: NSWindow, owned: URL, indexOnly: Bool = false) async throws -> [String] {
        let browser = workspace.activeBrowser
        let indexChecks = try await verifyGuardedIndex(in: workspace, browser: browser, parent: window, owned: owned)
        if indexOnly { return indexChecks }
        let tree = owned.appendingPathComponent("Generated Git Project", isDirectory: true)
        let folder = tree.appendingPathComponent("Project Scope", isDirectory: true)
        let draft = folder.appendingPathComponent("Draft.txt")
        let reference = folder.appendingPathComponent("Reference.txt")
        let subfolder = folder.appendingPathComponent("Nested Shared", isDirectory: true)
        let untracked = folder.appendingPathComponent("Untracked.txt")
        let observed = [tree.appendingPathComponent(".git/HEAD"), tree.appendingPathComponent(".git/index"), draft, reference, untracked]
        let original = try await Task.detached {
            try FileManager().createDirectory(at: folder, withIntermediateDirectories: true)
            try UIVerification.generateGit(in: tree, ["init", "--template=", "--initial-branch=main"])
            try Data("old draft\n".utf8).write(to: draft, options: .withoutOverwriting)
            try Data("reference text\n".utf8).write(to: reference, options: .withoutOverwriting)
            try FileManager().createDirectory(at: subfolder, withIntermediateDirectories: false)
            try Data("nested committed text\n".utf8).write(to: subfolder.appendingPathComponent("Nested.txt"), options: .withoutOverwriting)
            try UIVerification.generateGit(in: tree, ["add", "-A"])
            try UIVerification.generateGit(in: tree, ["commit", "-m", "First generated revision"])
            try UIVerification.generateGit(in: tree, ["branch", "earlier"])
            try Data("new draft\r\n".utf8).write(to: draft)
            try Data("outside scope\n".utf8).write(to: tree.appendingPathComponent("Outside.txt"))
            try UIVerification.generateGit(in: tree, ["add", "-A"])
            try UIVerification.generateGit(in: tree, ["commit", "-m", "Second generated revision"])
            try UIVerification.generateGit(in: tree, ["checkout", "-b", "long-history"])
            try UIVerification.generateGit(in: tree, ["mv", "--", "Project Scope/Draft.txt", "Project Scope/Prior.txt"])
            try UIVerification.generateGit(in: tree, ["commit", "-m", "Earlier path"])
            try UIVerification.generateGit(in: tree, ["mv", "--", "Project Scope/Prior.txt", "Project Scope/Draft.txt"])
            try UIVerification.generateGit(in: tree, ["commit", "-m", "Current path"])
            for index in 0..<95 {
                try Data("long timeline change \(index)\n".utf8).write(to: draft)
                try UIVerification.generateGit(in: tree, ["commit", "-am", "Revise generated draft \(index)"])
            }
            try UIVerification.generateGit(in: tree, ["checkout", "main"])
            try UIVerification.generateGit(in: tree, ["checkout", "-b", "review-branch", "earlier"])
            try Data("one branch addition\n".utf8).write(to: subfolder.appendingPathComponent("Branch.txt"))
            try UIVerification.generateGit(in: tree, ["add", "-A"])
            try UIVerification.generateGit(in: tree, ["commit", "-m", "Add a file on a diverged branch"])
            try UIVerification.generateGit(in: tree, ["checkout", "main"])
            try Data("staged draft\r\n".utf8).write(to: draft)
            try UIVerification.generateGit(in: tree, ["add", "--", "Project Scope/Draft.txt"])
            try Data("new draft\r\n".utf8).write(to: draft)
            try Data("untracked\n".utf8).write(to: untracked, options: .withoutOverwriting)
            return try observed.map { try Data(contentsOf: $0) }
        }.value

        browser.navigate(to: .directory(folder))
        try await UIVerification.waitUntil("Generated Git folder and toolbar") {
            browser.gitControls.isAvailable && browser.gitControls.repository?.root.path == tree.path
                && browser.rowsByURL[draft] != nil && browser.orderingTask == nil
        }
        let button = browser.navigationButtons.first { $0.1 == #selector(BrowserViewController.showGitMenu(_:)) }?.0
        let mainHeading = browser.gitToolsMenu().items.first
        try UIVerification.require(button?.isHidden == false && button?.toolTip == "Git Tools · main"
            && mainHeading?.isSectionHeader == true && mainHeading?.title == "main",
            "A known local repository did not show its Git tool and checked-out branch")
        let fileMenu = BrowserMenus.menu(.file, target: browser)
        let gitGroup = fileMenu.items.first { $0.identifier == BrowserMenus.gitSectionIdentifier }
        try UIVerification.require(gitGroup?.isHidden == false, "The detected repository did not expose the Git section")
        browser.settings.showsGitControls = false
        try await UIVerification.waitUntil("Git toolbar preference off") { button?.isHidden == true && !browser.gitControls.isAvailable }
        BrowserShortcutMenus.shared.menuNeedsUpdate(fileMenu)
        try UIVerification.require(gitGroup?.isHidden == true, "The open File menu retained a disabled Git section")
        browser.settings.showsGitControls = true
        try await UIVerification.waitUntil("Git toolbar preference restored") { button?.isHidden == false && browser.gitControls.isAvailable }
        BrowserShortcutMenus.shared.menuNeedsUpdate(fileMenu)
        try UIVerification.require(gitGroup?.isHidden == false, "Re-enabling Git did not restore the same File menu section")
        try await verifyBrowserBadges(browser, window: window, staged: draft, clean: reference, untracked: untracked, owned: owned)

        try send(.compareGitRevisions, from: BrowserMenus.menu(.file, target: browser), to: browser)
        guard let review = workspace.gitComparisonWindow, let gitWindow = review.window else {
            throw UIVerification.Failure(message: "The native Git review window did not open")
        }
        defer { review.window?.close() }
        try await UIVerification.waitUntil("Git comparison result") { !review.model.busy && gitWindow.isKeyWindow }
        guard let scoped = review.model.report else { throw UIVerification.Failure(message: review.model.notice) }
        try UIVerification.require(scoped.changes.count == 1 && scoped.lines.added == 1 && scoped.lines.removed == 1
            && scoped.changes[0].right?.path.display == "Project Scope/Draft.txt", "Git folder review did not retain its exact scope")
        let earlier = review.model.choices.first { $0.title == "earlier" }
        try UIVerification.require(earlier?.revision == .object(scoped.left), "Local branch picker did not preserve its exact revision")
        review.model.useWholeRepository(true)
        try await UIVerification.waitUntil("Repository-wide result") { !review.model.busy }
        try UIVerification.require(review.model.report?.changes.count == 2, "Whole Repository did not expand the selected scope")
        try await verifyComparedFileNavigation(review, workspace: workspace, window: gitWindow, settings: browser.settings, owned: owned)
        try await verifyChangeFilter(review, workspace: workspace, window: gitWindow, settings: browser.settings, owned: owned)
        review.model.swap()
        try await UIVerification.waitUntil("Swapped Git sides") { !review.model.busy }
        try UIVerification.require(review.model.report?.left == scoped.right && review.model.report?.right == scoped.left
            && review.model.report?.lines.removed == 2, "Swapping revisions did not reverse their direction and line totals")
        try await UIVerification.snapshot(gitWindow, to: owned.appendingPathComponent("git-revisions.png"))
        review.model.useWholeRepository(false)
        try await UIVerification.waitUntil("Folder scope restored") { !review.model.busy }
        review.model.selectedChange = 0
        let menu = NSApp.mainMenu?.item(withTitle: "File")?.submenu
        guard let item = menu?.item(withTitle: "Open Text Diff"), review.validateMenuItem(item),
              let action = item.action, NSApp.sendAction(action, to: review, from: item) else {
            throw UIVerification.Failure(message: "The selected Git row could not open its text diff")
        }
        let gitDiff = try await capturedDiff(workspace.textComparisonWindow, left: "new draft\n", right: "old draft\n")
        await gitDiff.closeAndDrain()
        gitWindow.makeKeyAndOrderFront(nil)
        try await verifyComparisonHistory(review, workspace: workspace, window: gitWindow, side: .right,
            commit: scoped.left, path: "Project Scope/Draft.txt", entries: [scoped.left], owned: owned)
        review.model.setPresentation(.folders)
        try await UIVerification.waitUntil("Both pinned folder trees") { !review.model.busy && review.model.folders != nil }
        guard let folders = review.model.folders,
              let nested = folders.left.entries.first(where: { $0.path.name == "Nested Shared" }) else {
            throw UIVerification.Failure(message: "The nested folder was absent from its committed tree")
        }
        try UIVerification.require(folders.path?.display == "Project Scope" && folders.left.entries.count == 3
            && folders.right.entries.contains(where: { $0.path == nested.path && $0.object == nested.object }),
            "The two views did not use the selected committed folder pair")
        try await verifyPairedFolderLayout(gitWindow, settings: browser.settings, owned: owned)
        guard let content = gitWindow.contentView, let leftTable = tables(in: content).first,
              let nestedRow = folders.left.entries.firstIndex(of: nested) else {
            throw UIVerification.Failure(message: "The paired folder table is not available for native selection")
        }
        try await UIVerification.clickRow(nestedRow, in: leftTable)
        try await UIVerification.waitUntil("Native folder row selection") { review.model.selectedMember == nested.path }
        func sendGitFile(_ title: String) throws {
            guard let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: title),
                  let action = item.action, review.validateMenuItem(item), NSApp.sendAction(action, to: review, from: item) else {
                throw UIVerification.Failure(message: "Native Git folder command unavailable: \(title)")
            }
        }
        try sendGitFile("Open Folder")
        try await UIVerification.waitUntil("Enter the same branch in both trees") { !review.model.busy && review.model.folders?.path == nested.path }
        try UIVerification.require(review.model.folders?.left.entries.first?.path.name == "Nested.txt"
            && review.model.folders?.right.entries.first?.path.name == "Nested.txt", "Paired navigation selected the wrong child")
        try sendGitFile("Up a Folder")
        try await UIVerification.waitUntil("Return to the comparison scope") { !review.model.busy && review.model.folders?.path == folders.path }
        review.model.selectedMember = folders.left.entries.first(where: { $0.path.name == "Draft.txt" })?.path
        try sendGitFile("Open Text Diff")
        let treeDiff = try await capturedDiff(workspace.textComparisonWindow, left: "new draft\n", right: "old draft\n")
        await treeDiff.closeAndDrain()
        gitWindow.makeKeyAndOrderFront(nil)
        try await UIVerification.waitUntil("Git comparison after text diff") { gitWindow.isKeyWindow }
        review.model.selectedMember = nested.path
        try sendGitFile("Open Folder")
        try await UIVerification.waitUntil("Paired folder before alternate branch") { !review.model.busy && review.model.folders?.path == nested.path }
        try await chooseRightBranch("review-branch", in: gitWindow, model: review.model)
        try await UIVerification.waitUntil("Diverged branch views") { !review.model.busy && review.model.folders?.path == nested.path }
        try UIVerification.require(review.model.report?.changes.count == 2, "Direct comparison lost the left branch's edit")
        try sendGitFile("Since Common Ancestor")
        try await UIVerification.waitUntil("Shared ancestor views") { !review.model.busy && review.model.folders?.path == nested.path }
        guard let ancestor = review.model.report, let ancestorFolders = review.model.folders,
              let branchRow = ancestorFolders.right.entries.firstIndex(where: { $0.path.name == "Branch.txt" }) else {
            throw UIVerification.Failure(message: "The common ancestor and branch folder could not be compared")
        }
        try UIVerification.require(ancestor.basis == .commonAncestor && ancestor.left == scoped.left && ancestor.selectedLeft == scoped.right
            && ancestor.changes.count == 1 && ancestor.affectedSubfolders == 1 && ancestor.lines.added == 1 && ancestor.lines.removed == 0,
            "Ancestor mode recomputed the wrong pinned endpoints or counts")
        try await UIVerification.snapshot(gitWindow, to: owned.appendingPathComponent("git-common-ancestor.png"))
        guard let rightTable = gitWindow.contentView.flatMap({ tables(in: $0).last }) else {
            throw UIVerification.Failure(message: "The alternate branch table did not appear")
        }
        try await UIVerification.clickRow(branchRow, in: rightTable)
        try UIVerification.require(review.model.selectedMember == ancestorFolders.right.entries[branchRow].path,
            "Selecting a one-sided row was lost in the other table")
        try sendGitFile("Open Text Diff")
        let additionDiff = try await capturedDiff(workspace.textComparisonWindow, left: "", right: "one branch addition\n", added: 1, removed: 0)
        await additionDiff.closeAndDrain()
        gitWindow.makeKeyAndOrderFront(nil)
        try await verifyComparisonHistory(review, workspace: workspace, window: gitWindow, side: .right,
            commit: ancestor.right, path: "Project Scope/Nested Shared/Branch.txt", entries: [ancestor.right], missingLeft: true)
        try await verifyCommitRange(review, workspace: workspace, window: gitWindow, report: ancestor,
            settings: browser.settings, owned: owned)
        review.window?.close()
        try await verifyStagedReview(workspace, browser: browser, parent: window,
            before: scoped.left, head: scoped.right, owned: owned)
        try await verifyWorkingFolder(workspace, browser: browser, parent: window, base: scoped.left, owned: owned)
        try await verifyFolderHistory(workspace, browser: browser, parent: window, report: scoped, owned: owned)

        window.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        browser.setFileSelection([draft])
        browser.fileSelectionDidChange()
        try await verifyBrowserFileRevisions(workspace, browser: browser, parent: window, file: draft)
        let workingFile = try await chooseBrowserWorkingFile(browser, parent: window, usingEditor: false)
        let diskDiff = try await capturedDiff(workingFile, left: "old draft\n", right: "new draft\n")
        try UIVerification.require(diskDiff.labels.left.hasPrefix("earlier") && diskDiff.labels.right.hasPrefix("On Disk")
            && workspace.gitFileHistoryWindow == nil && browser.orderedSelectedURLs == [draft],
            "Working file comparison opened history, switched selection or mislabeled the disk file")
        await diskDiff.closeAndDrain()
        window.makeKeyAndOrderFront(nil)
        try await UIVerification.waitUntil("Working file comparison returns to the browser") { window.isKeyWindow }
        try send(.gitFileHistory, from: BrowserMenus.fileContextMenu(target: browser), to: browser)
        guard let history = workspace.gitFileHistoryWindow, let historyWindow = history.window else {
            throw UIVerification.Failure(message: "The browser did not open Git File History")
        }
        defer { history.window?.close() }
        try await UIVerification.waitUntil("Git file history is visible") { historyWindow.isKeyWindow && !history.model.busy }
        try UIVerification.require(history.model.history?.entries.map(\.commit.object) == [scoped.right, scoped.left]
            && history.model.selection == scoped.right, "The timeline selected the wrong commit or lost the selected file")
        try await UIVerification.snapshot(historyWindow, to: owned.appendingPathComponent("git-file-history.png"))
        let historyMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu
        guard let open = historyMenu?.item(withTitle: "Open Version"), history.validateMenuItem(open),
              let action = open.action, NSApp.sendAction(action, to: history, from: open) else {
            throw UIVerification.Failure(message: "The selected commit could not open its version")
        }
        try await UIVerification.waitUntil("Immutable historical editor") { history.snapshotForVerification?.window.window?.isKeyWindow == true }
        guard let historicalEditor = history.snapshotForVerification else {
            throw UIVerification.Failure(message: "An immutable historical editor was missing")
        }
        try UIVerification.require(historicalEditor.window.surface.textView.string == "new draft\n"
            && !historicalEditor.window.surface.textView.isEditable && !historicalEditor.window.saveButton.isEnabled,
            "The version viewer did not receive the exact bytes in read-only mode")
        await historicalEditor.closeAndDrain()
        try UIVerification.require(historicalEditor.window.surface.textView.string.isEmpty, "Closing retained the historical editor text")
        historyWindow.makeKeyAndOrderFront(nil)
        if let earlier { try await verifyExactRevision(history, window: historyWindow, revision: earlier, owned: owned) }
        guard let compare = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Compare Change"),
              history.validateMenuItem(compare), let action = compare.action,
              NSApp.sendAction(action, to: history, from: compare) else {
            throw UIVerification.Failure(message: "The file history's change could not open a comparison")
        }
        let committed = try await capturedDiff(history.diffForVerification, left: "old draft\n", right: "new draft\n")
        await committed.closeAndDrain()
        if let earlier {
            history.compareRevisions(with: earlier)
            try await UIVerification.waitUntil("Same file across branches") { !history.model.busy && history.diffForVerification != nil }
            let alternate = try await capturedDiff(history.diffForVerification, left: "new draft\n", right: "old draft\n")
            await alternate.closeAndDrain()
            history.model.choose(earlier, path: history.model.path)
            try await UIVerification.waitUntil("Timeline starts at the selected branch") { !history.model.busy }
            try UIVerification.require(history.model.history?.entries.map(\.id) == [scoped.left],
                "The same-file timeline included commits outside the selected branch")
        }
        try await verifyHistoryPages(history, window: historyWindow, settings: browser.settings, owned: owned)
        history.window?.close()

        window.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        browser.setFileSelection([draft, reference])
        browser.fileSelectionDidChange()
        let selected = browser.orderedSelectedURLs
        try UIVerification.require(Set(selected) == [draft, reference], "The generated text pair was not selected")
        try send(.compareTextFiles, from: BrowserMenus.fileContextMenu(target: browser), to: browser)
        let displayedText = selected.map { $0 == draft ? "new draft\n" : "reference text\n" }
        let localDiff = try await capturedDiff(workspace.textComparisonWindow, left: displayedText[0], right: displayedText[1])
        try await verifyDiffLayout(localDiff, settings: browser.settings, owned: owned)
        await localDiff.closeAndDrain()
        try await verifyEditorGit(browser, window: window, draft: draft, untracked: untracked, owned: owned)
        try await verifyLinkedWorktree(workspace, browser: browser, parent: window, repo: tree, base: scoped.left, owned: owned)

        browser.goComputer(nil)
        try UIVerification.require(button?.isHidden == true, "Git remained available after leaving the repository")
        let after = try await Task.detached { try observed.map { try Data(contentsOf: $0) } }.value
        try UIVerification.require(original == after, "A comparison changed the original Git files, HEAD or index")
        try await verifyConflictReview(workspace, browser: browser, parent: window, owned: owned)
        return indexChecks + [
            "Git Tools appears for the exact generated repository, names each checkout's own branch or detached revision, respects its preference and retires on navigation",
            "Opt-in Git badges label staged and untracked files in native List and Icons at 150 percent. Disabling shows ordinary names again, with selection and Git Tools intact",
            "The native File command compares local Git commits by folder or whole repository; swapping sides reverses totals",
            "Both pinned folder views fit side by side and reflow at enlarged size. Selecting a native row navigates into the same child and back before comparing its committed file",
            "Native revision search accepts typed input and keyboard selection. A diverged branch can be compared directly or from its common ancestor, retaining the nested folder and opening its exact one-sided text",
            "Review Staged Changes compares the scoped index with HEAD or an older base through the native revision picker. A selected row opens exact staged text even when the working file has different bytes",
            "Shift-Command-F opens search across the actual visible Git revision or working-folder diffs at enlarged size. Return selects the exact match while keeping the originating row",
            "Git Change Type and path filtering intersect. Escape preserves the selected type, hidden rows cannot open, and Find Across Diffs follows the filtered list while totals still cover the review.",
            "Compare Working Folder reads names and types against a pinned revision or the exact Git index. It retains scope and selection on reload, hides verified matches on request and filters with native typing, arrows and Escape. Exact disk/staged text uses the ordinary native commands.",
            "Working Folder compares the selected revision with a live editor draft, reopens that editor at an exact change, and retains the previous snapshot after the draft changes or closes.",
            "A linked worktree reviews its own staged text against its own HEAD with shared Git objects. The worktree chooser cancels cleanly and opens the verified other checkout in a tab or pane. The editor opens the same path in that checkout and compares on-disk or unsaved editor text.",
            "The divider compares matching folders at the two checked-out commits in pane order, preserves file selection, and opens the committed diff. The enlarged Changes row stays under its four native headers after resizing.",
            "The native Conflicts view compares Git’s recorded stages, including a deleted side. The editor resolves a generated diff3 block in memory with ordinary Undo and Redo, leaving the working files and index unchanged.",
            "Git File History uses the browser selection. Its revision picker compares exact branch text with an unsaved buffer, and two selected rows compare the recorded names and bytes across a rename",
            "Git Changes and paired Folders open file history at the chosen side's immutable commit. Reload keeps that commit, and an absent side offers no history.",
            "Git Folder History starts at the current checkout, scopes commit details to the open folder and moves through the selected branch's pinned pages without checking it out.",
            "Native browser commands compare two pinned revisions or a revision with the selected on-disk file or open draft. The picker preserves selection and the draft keeps its edit destination and Undo",
            "Native Older Changes and Newer Changes retain the chosen branch tip across a rename. Filtering one page accepts ordinary typing, honors either recorded path and closes with Escape",
            "A native comparison base stays pinned across history pages. The two committed buffers and the selected row stay exact when comparing and clearing that base",
            "The local editor opens Git history with its sidebar closed, distinguishes Git and unsaved marks, and reuses the native staged and working-folder reviews for the exact current folder. Index, disk and draft comparisons preserve the live draft, Undo and checkout",
            "The editor’s File menu opens immutable Git text, compares a revision with the current buffer, or picks two revisions of the same path in one native sheet. Back, Escape, typing and Return keep the draft intact",
            "Compare Editor with HEAD and Git Index open the exact committed or staged text beside the draft without an intermediate chooser, preserving Git, the source file and edit ownership",
            "Show Commit for Line refuses draft-only text, maps an unchanged shifted line to its committed location, and opens the original read-only without disturbing the native draft or Undo",
            "A changed Git row and two selected local files open read-only text diffs with exact content and line counts; the actual paired and enlarged stacked panes fit without overlap, and HEAD, index and original files are unchanged"
        ]
    }

    private static func verifyGuardedIndex(in workspace: BrowserWorkspaceController, browser: BrowserViewController,
                                           parent: NSWindow, owned: URL) async throws -> [String] {
        let tree = owned.appendingPathComponent("Generated Index Review", isDirectory: true)
        let file = tree.appendingPathComponent("Untracked.txt")
        let draft = tree.appendingPathComponent("Draft.txt")
        let removed = tree.appendingPathComponent("Removed.txt")
        let kept = tree.appendingPathComponent("Keep.txt")
        let index = tree.appendingPathComponent(".git/index")
        try await Task.detached {
            try FileManager().createDirectory(at: tree, withIntermediateDirectories: false)
            try UIVerification.generateGit(in: tree, ["init", "--template=", "--initial-branch=main"])
            try Data("first old\nbetween\nlast old\n".utf8).write(to: draft, options: .withoutOverwriting)
            try Data("tracked removal\n".utf8).write(to: removed, options: .withoutOverwriting)
            try Data("unrelated baseline\n".utf8).write(to: kept, options: .withoutOverwriting)
            try UIVerification.generateGit(in: tree, ["add", "--", "Draft.txt", "Removed.txt", "Keep.txt"])
            try UIVerification.generateGit(in: tree, ["commit", "-m", "Generated base"])
            try Data("unrelated staged change\n".utf8).write(to: kept)
            try UIVerification.generateGit(in: tree, ["add", "--", "Keep.txt"])
            try Data("first new\nbetween\nlast new\n".utf8).write(to: draft)
            try Data("untracked\n".utf8).write(to: file, options: .withoutOverwriting)
        }.value
        try await verifyIndexActions(workspace, browser: browser, parent: parent, file: file, index: index)
        try await verifyWorkingIndexActions(workspace, browser: browser, parent: parent,
            missing: removed, saved: file, draft: draft, index: index)
        fputs("Native generated Stage and Unstage checks passed.\n", stderr)
        return [
            "Native Stage Saved File cancels without a write, rejects a replacement after review and stages only the confirmed bytes. Unstage restores the selected path and reloads the index",
            "An independent viewport in the same checkout shows staged and untracked status after the successful actions",
            "Working Folder against Git Index stages reviewed saved bytes or a reviewed absence. A reappeared file is refused, and Unstage restores only the index entry",
            "A selected Git diff change can be cancelled, staged and unstaged. The other changes stay in the working folder and index. The review opens the remaining text diff",
            "The editor stages the exact saved file while keeping unsaved edits and Undo. A same-byte replacement cannot use the old editor's source observation"
        ]
    }

    private static func verifyIndexActions(_ workspace: BrowserWorkspaceController, browser: BrowserViewController,
                                           parent: NSWindow, file: URL, index: URL) async throws {
        parent.makeKeyAndOrderFront(nil)
        browser.navigate(to: .directory(file.deletingLastPathComponent()))
        try await UIVerification.waitUntil("Generated index edit folder") {
            parent.isKeyWindow && browser.gitControls.isAvailable && !browser.isLoading
                && browser.rowsByURL[file] != nil && browser.orderingTask == nil
        }
        browser.focusBrowserContent()
        browser.setFileSelection([file]); browser.fileSelectionDidChange()
        guard let repository = browser.gitControls.repository,
              let badgeAccess = GitReviewAccess(location: repository, fileSystem: browser.fileSystem, access: browser.folderAccess) else {
            throw UIVerification.Failure(message: "The independent Git badge reader has no checkout")
        }
        let observation = UUID()
        let viewport = GitViewportBadges(request: {
            .init(access: badgeAccess, urls: [file], generation: observation, inspectWorkingBytes: false)
        }, delivered: { _, _ in })
        viewport.update()
        try await UIVerification.waitUntil("Another viewport shows the untracked file") {
            viewport.badge(for: file)?.text == "?" && !viewport.isReading
        }
        let before = try Data(contentsOf: index)
        func stage() throws { try send(.stageGitFile, from: BrowserMenus.menu(.file, target: browser), to: browser) }
        try stage()
        try await indexReviewButton("Cancel", in: parent).performClick(nil)
        try await UIVerification.waitUntil("Stage Cancel drain") { !browser.gitControls.isChoosing && parent.isKeyWindow }
        try UIVerification.require(try Data(contentsOf: index) == before, "Cancelling Stage changed the index")

        browser.focusBrowserContent()
        try stage()
        let stale = try await indexReviewButton("Stage File", in: parent)
        let changedBytes = Data("changed after review\n".utf8)
        try await Task.detached { try changedBytes.write(to: file, options: .atomic) }.value
        stale.performClick(nil)
        try await UIVerification.waitUntil("Stale stage drain") { !browser.gitControls.isChoosing && parent.isKeyWindow }
        try UIVerification.require(try Data(contentsOf: index) == before && browser.status.stringValue.contains("changed"),
            "Stage accepted a replacement after the sheet opened or hid its refusal")

        browser.focusBrowserContent()
        try stage()
        try await indexReviewButton("Stage File", in: parent).performClick(nil)
        try await UIVerification.waitUntil("Successful stage drain") { !browser.gitControls.isChoosing && parent.isKeyWindow }
        try UIVerification.require(try Data(contentsOf: index) != before && browser.status.stringValue == "Saved file staged.",
            "The confirmed native action failed to stage the generated file: \(browser.status.stringValue)")
        try await UIVerification.waitUntil("The other viewport updates after confirmed Stage") {
            viewport.badge(for: file)?.text == "S" && !viewport.isReading
        }

        try send(.reviewStagedChanges, from: BrowserMenus.menu(.file, target: browser), to: browser)
        guard let review = workspace.gitComparisonWindow, let window = review.window else {
            throw UIVerification.Failure(message: "Native staged review did not open after Stage")
        }
        defer { review.window?.close() }
        try await UIVerification.waitUntil("Newly staged file in the index review") {
            window.isKeyWindow && !review.model.busy
                && review.model.visibleChanges.contains { $0.right?.path.name == file.lastPathComponent }
        }
        let row = review.model.visibleChanges.first { $0.right?.path.name == file.lastPathComponent }
        review.model.selectedChange = row?.id
        review.unstageFile(nil)
        try await indexReviewButton("Unstage File", in: window).performClick(nil)
        try await UIVerification.waitUntil("The staged review refreshed after Unstage") {
            !review.model.busy && review.model.staged != nil
                && !review.model.visibleChanges.contains { $0.right?.path.name == file.lastPathComponent }
        }
        try UIVerification.require(try Data(contentsOf: file) == changedBytes
            && review.model.visibleChanges.contains { $0.right?.path.name == "Keep.txt" },
            "Unstage changed working bytes or the unrelated staged file")
        try await UIVerification.waitUntil("The other viewport updates after confirmed Unstage") {
            viewport.badge(for: file)?.text == "?" && !viewport.isReading
        }
        let access = review.model.access
        review.window?.close()
        try await verifyEditorIndexActions(browser, parent: parent, file: file, index: index, saved: changedBytes, access: access)
    }

    private static func verifyWorkingIndexActions(_ workspace: BrowserWorkspaceController, browser: BrowserViewController,
                                                  parent: NSWindow, missing file: URL, saved: URL, draft: URL, index: URL) async throws {
        try await Task.detached { try FileManager().removeItem(at: file) }.value
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try send(.compareGitWorkingFolder, from: BrowserMenus.menu(.file, target: browser), to: browser)
        guard let working = workspace.gitComparisonWindow, let window = working.window,
              let path = GitSnapshotPath(file.lastPathComponent) else {
            throw UIVerification.Failure(message: "Working-folder removal review did not open")
        }
        defer { working.window?.close() }
        try await UIVerification.waitUntil("Working removal review shows committed comparison") {
            working.model.workingFolder?.comparesIndex == false && !working.model.busy && window.isKeyWindow
        }
        working.model.selectedMember = path
        guard let item = UIVerification.menuItem("File", "Stage File Removal…"),
              let savedItem = UIVerification.menuItem("File", "Stage Saved File…"),
              let stage = item.action, let switchItem = UIVerification.menuItem("View", "Compare with Git Index"),
              let switchMode = switchItem.action else { throw UIVerification.Failure(message: "Missing native removal review commands") }
        try UIVerification.require(!working.validateMenuItem(item) && !working.validateMenuItem(savedItem)
            && NSApp.sendAction(switchMode, to: working, from: switchItem),
            "A committed comparison offered to write an index entry")
        try await selectWorkingIndexRow(path, in: working, difference: .onlyInRevision)
        try await UIVerification.waitUntil("Index removal review can stage the selected absent file") {
            working.model.selectedMember == path && working.validateMenuItem(item)
        }
        let baseline = try Data(contentsOf: index)
        try UIVerification.require(NSApp.sendAction(stage, to: working, from: item), "Native Stage File Removal command did not open")
        let confirmation = try await indexReviewButton("Stage Removal", in: window)
        let replacement = Data("returned during review\n".utf8)
        try await Task.detached { try replacement.write(to: file, options: .withoutOverwriting) }.value
        confirmation.performClick(nil)
        try await UIVerification.waitUntil("Removal refusal is visible") { !working.model.busy && working.model.notice.contains("changed") }
        try UIVerification.require(try Data(contentsOf: index) == baseline && Data(contentsOf: file) == replacement,
            "Stage removal changed the index or the reappeared file")

        try await Task.detached { try FileManager().removeItem(at: file) }.value
        working.model.load()
        try await UIVerification.waitUntil("Refreshed removal is staged from the same review") {
            window.isKeyWindow && working.validateMenuItem(item)
        }
        try UIVerification.require(NSApp.sendAction(stage, to: working, from: item), "Current removal did not open its confirmation")
        try await indexReviewButton("Stage Removal", in: window).performClick(nil)
        try await UIVerification.waitUntil("Working review reloads the staged absence") {
            !working.model.busy && !working.model.visibleWorkingRows.contains { $0.path == path }
        }
        try UIVerification.require(try Data(contentsOf: index) != baseline && !FileManager().fileExists(atPath: file.path),
            "Confirmed removal did not stage the absence")
        try await verifyReviewedSavedStage(saved, index: index, review: working, window: window, command: savedItem)
        try await verifySelectedChangeStage(draft, workspace: workspace, working: working, window: window, index: index)
        working.window?.close()
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try send(.reviewStagedChanges, from: BrowserMenus.menu(.file, target: browser), to: browser)
        guard let staged = workspace.gitComparisonWindow, let stagedWindow = staged.window else {
            throw UIVerification.Failure(message: "Staged removal review did not open")
        }
        defer { staged.window?.close() }
        try await UIVerification.waitUntil("Stage review shows a removal and the unrelated staged file") {
            stagedWindow.isKeyWindow && !staged.model.busy
                && staged.model.visibleChanges.contains { $0.kind == .removed && $0.left?.path == path }
        }
        try await verifySelectedChangeUnstage(draft, workspace: workspace, staged: staged)
        staged.model.selectedChange = staged.model.visibleChanges.first { $0.kind == .removed && $0.left?.path == path }?.id
        staged.unstageFile(nil)
        try await indexReviewButton("Unstage File", in: stagedWindow).performClick(nil)
        try await UIVerification.waitUntil("Staged removal leaves the index review") {
            !staged.model.busy && !staged.model.visibleChanges.contains { $0.left?.path == path || $0.right?.path == path }
        }
        try UIVerification.require(!FileManager().fileExists(atPath: file.path)
            && staged.model.visibleChanges.contains { $0.right?.path.name == "Draft.txt" }
            && staged.model.visibleChanges.contains { $0.right?.path.name == "Keep.txt" }
            && staged.model.visibleChanges.contains { $0.right?.path.name == saved.lastPathComponent },
            "Unstage restored a working file or lost an unrelated staged entry")
    }

    private static func verifySelectedChangeStage(_ file: URL, workspace: BrowserWorkspaceController,
                                                  working: GitComparisonWindow, window: NSWindow, index: URL) async throws {
        guard let path = GitSnapshotPath(file.lastPathComponent) else { throw UIVerification.Failure(message: "No draft path") }
        try await selectWorkingIndexRow(path, in: working, difference: .contentsUnchecked)
        working.openDiff(nil)
        guard let diff = workspace.textComparisonWindow, let diffWindow = diff.window else {
            throw UIVerification.Failure(message: "Git index text comparison did not open")
        }
        try await UIVerification.waitUntil("Git diff has two distinct changes and offers staging") {
            diffWindow.isKeyWindow && diff.canEditSelectedIndexChange && diff.planForVerification?.changes.count == 2
        }
        guard let stage = UIVerification.menuItem("File", "Stage Selected Change…"), let action = stage.action else {
            throw UIVerification.Failure(message: "Git selected-change command is missing")
        }
        let oldIndex = try Data(contentsOf: index), original = try Data(contentsOf: file)
        try UIVerification.require(NSApp.sendAction(action, to: diff, from: stage), "Selected-change menu could not open")
        try await indexReviewButton("Cancel", in: diffWindow).performClick(nil)
        try await UIVerification.waitUntil("Cancelled selected change leaves the comparison open") {
            diffWindow.isKeyWindow && diffWindow.attachedSheet == nil && diff.canEditSelectedIndexChange
        }
        try UIVerification.require(try Data(contentsOf: index) == oldIndex && Data(contentsOf: file) == original,
            "Cancelling selected-change staging changed a file")
        try UIVerification.require(NSApp.sendAction(action, to: diff, from: stage), "Selected change could not be reviewed again")
        try await indexReviewButton("Stage Change", in: diffWindow).performClick(nil)
        try await UIVerification.waitUntil("Confirmed change reloads the same working file") {
            diff.closed && !working.model.busy && working.model.selectedMember == path
                && working.model.notice == "Selected change staged."
        }
        let updated = try await working.model.access.indexText(for: file)
        try UIVerification.require(try updated.encoded == Data("first new\nbetween\nlast old\n".utf8)
            && Data(contentsOf: file) == original, "Staging a single hunk lost an adjacent unstaged change")
        window.makeKeyAndOrderFront(nil)
        working.openDiff(nil)
        guard let remaining = workspace.textComparisonWindow else {
            throw UIVerification.Failure(message: "Remaining Git change did not open")
        }
        try await UIVerification.waitUntil("Exactly one working change remains") {
            remaining.window?.isKeyWindow == true && remaining.planForVerification?.changes.count == 1
                && remaining.planForVerification?.changes.first?.beforeLines == 2..<3
        }
        try await confirmSelectedIndexChange("Stage Selected Change…", button: "Stage Change", in: remaining)
        try await UIVerification.waitUntil("The remaining change stages too") { remaining.closed && !working.model.busy }
        let both = try await working.model.access.indexText(for: file)
        try UIVerification.require(both.encoded == original, "Staging the remaining hunk lost the first staged hunk")
    }

    private static func verifySelectedChangeUnstage(_ file: URL, workspace: BrowserWorkspaceController,
                                                    staged: GitComparisonWindow) async throws {
        guard let path = GitSnapshotPath(file.lastPathComponent),
              let row = staged.model.visibleChanges.first(where: { $0.right?.path == path }) else {
            throw UIVerification.Failure(message: "Both changes are missing from the staged file list")
        }
        staged.model.setChangeQuery(file.lastPathComponent)
        try await UIVerification.waitUntil("The staged filter isolates the file to review") {
            !staged.model.filteringChanges && staged.model.visibleChanges.map(\.id) == [row.id]
        }
        staged.model.selectedChange = row.id
        staged.openDiff(nil)
        guard let diff = workspace.textComparisonWindow else {
            throw UIVerification.Failure(message: "The staged text comparison did not open")
        }
        try await UIVerification.waitUntil("Staged text comparison offers one-change Unstage") {
            diff.window?.isKeyWindow == true && diff.canEditSelectedIndexChange && diff.planForVerification?.changes.count == 2
        }
        try await confirmSelectedIndexChange("Unstage Selected Change…", button: "Unstage Change", in: diff)
        try await UIVerification.waitUntil("One selected change is unstaged and staged review refreshes") {
            diff.closed && !staged.model.busy && !staged.model.filteringChanges && staged.model.notice == "Selected change unstaged."
                && staged.model.selected?.right?.path == path && staged.model.visibleChanges.map { $0.right?.path } == [path]
        }
        let text = try await staged.model.access.indexText(for: file)
        try UIVerification.require(try text.encoded == Data("first old\nbetween\nlast new\n".utf8)
            && staged.model.visibleChanges.first?.right != row.right
            && Data(contentsOf: file) == Data("first new\nbetween\nlast new\n".utf8),
            "Unstaging one change modified the working file or lost the other staged change")
        staged.model.setChangeQuery("")
    }

    private static func confirmSelectedIndexChange(_ title: String, button: String, in diff: EditorComparisonWindow) async throws {
        guard let window = diff.window, let item = UIVerification.menuItem("File", title), let action = item.action,
              NSApp.sendAction(action, to: diff, from: item) else {
            throw UIVerification.Failure(message: "The native Git diff command did not open")
        }
        try await indexReviewButton(button, in: window).performClick(nil)
    }

    private static func selectWorkingIndexRow(_ path: GitSnapshotPath, in review: GitComparisonWindow,
                                              difference: GitWorkingFolder.Difference) async throws {
        try await UIVerification.waitUntil("Native Git index row matches the reviewed path") {
            review.model.workingFolder?.comparesIndex == true && !review.model.busy
                && review.model.visibleWorkingRows.contains { $0.path == path && $0.difference == difference }
                && UIVerification.nativeTables(in: review.window?.contentView).first?.numberOfRows == review.model.visibleWorkingRows.count
        }
        guard let table = UIVerification.nativeTables(in: review.window?.contentView).first,
              let row = review.model.visibleWorkingRows.firstIndex(where: { $0.path == path }) else {
            throw UIVerification.Failure(message: "Missing file row in the Git index comparison")
        }
        try await UIVerification.clickRow(row, in: table)
        try await UIVerification.waitUntil("Selected native Git index row") { review.model.selectedMember == path }
    }

    private static func verifyReviewedSavedStage(_ file: URL, index: URL, review: GitComparisonWindow,
                                                 window: NSWindow, command: NSMenuItem) async throws {
        guard let path = GitSnapshotPath(file.lastPathComponent), let action = command.action else {
            throw UIVerification.Failure(message: "Missing the native saved-file staging command")
        }
        try await selectWorkingIndexRow(path, in: review, difference: .onlyOnDisk)
        let before = try Data(contentsOf: index), saved = try Data(contentsOf: file)
        try UIVerification.require(review.validateMenuItem(command) && NSApp.sendAction(action, to: review, from: command),
            "Staging saved bytes from the index review did not open")
        try await indexReviewButton("Cancel", in: window).performClick(nil)
        try await UIVerification.waitUntil("Cancelled Stage leaves the working review available") {
            window.isKeyWindow && window.attachedSheet == nil && review.validateMenuItem(command)
        }
        try UIVerification.require(try Data(contentsOf: index) == before && Data(contentsOf: file) == saved,
            "Cancelling the working review's Stage changed the index or file")
        try UIVerification.require(NSApp.sendAction(action, to: review, from: command), "Saved Stage did not reopen after Cancel")
        try await indexReviewButton("Stage File", in: window).performClick(nil)
        try await UIVerification.waitUntil("Working review visibly confirms Stage and keeps the row") {
            !review.model.busy && review.model.notice == "Saved file staged." && review.model.selectedMember == path
                && review.model.visibleWorkingRows.contains { $0.path == path && $0.difference == .contentsUnchecked }
        }
        let result = try await review.model.access.indexText(for: file)
        try UIVerification.require(try result.encoded == saved && Data(contentsOf: file) == saved,
            "Staging the reviewed file did not keep exactly the saved bytes")
    }

    private static func indexReviewButton(_ title: String, in window: NSWindow) async throws -> NSButton {
        try await UIVerification.waitUntil("Git index review sheet") { window.attachedSheet != nil }
        guard let content = window.attachedSheet?.contentView,
              let control = views(in: content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
            throw UIVerification.Failure(message: "Git index review did not expose \(title)")
        }
        return control
    }

    private static func verifyEditorIndexActions(_ browser: BrowserViewController, parent: NSWindow, file: URL,
                                                 index: URL, saved: Data, access: GitReviewAccess) async throws {
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try UIVerification.select(file.lastPathComponent, in: browser)
        browser.editTextInTraverse(nil)
        let editors = ApplicationLocalTextEditors.shared
        try await UIVerification.waitUntil("Generated index file opens in the ordinary editor") {
            guard let document = editors.documentForVerification(at: file) else { return false }
            return document.window.window?.isKeyWindow == true && document.window.fileSidebar?.files?.currentHistoryFile == file
                && document.canCaptureCurrentText
        }
        guard let document = editors.documentForVerification(at: file), let window = document.window.window else {
            throw UIVerification.Failure(message: "Editor index review has no current local document")
        }
        let editor = document.window, text = editor.surface.textView
        let draft = "generated unsaved draft\n"
        text.insertText(draft, replacementRange: NSRange(location: 0, length: text.string.utf16.count))
        try await UIVerification.waitUntil("Editor marks the generated draft") { document.isDirty && text.undoManager?.canUndo == true }
        func command(_ title: String) throws {
            guard let item = UIVerification.menuItem("File", "Git")?.submenu?.item(withTitle: title), let action = item.action,
                  editor.validateUserInterfaceItem(item), NSApp.sendAction(action, to: editor, from: item) else {
                throw UIVerification.Failure(message: "Editor Git action unavailable: \(title)")
            }
        }
        try command("Stage Saved File…")
        let stage = try await indexReviewButton("Stage File", in: window)
        guard let sheetContents = stage.window?.contentView else { throw UIVerification.Failure(message: "Stage review content is missing") }
        try UIVerification.require(views(in: sheetContents).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.contains("Unsaved edits stay in the editor.") }, "Stage lacks the saved-versus-draft explanation")
        stage.performClick(nil)
        try await UIVerification.waitUntil("Editor confirms the saved file was staged") {
            window.isKeyWindow && editor.navigationStatus == "Saved file staged."
        }
        let staged = try await access.indexText(for: file)
        try UIVerification.require(staged.encoded == saved && text.string == draft && document.isDirty && text.undoManager?.canUndo == true,
            "Editor Stage changed the draft or used its unsaved bytes")
        try command("Unstage File…")
        try await indexReviewButton("Unstage File", in: window).performClick(nil)
        try await UIVerification.waitUntil("Editor unstage is confirmed") { window.isKeyWindow && editor.navigationStatus == "File unstaged." }
        let before = try Data(contentsOf: index)
        try await Task.detached { try saved.write(to: file, options: .atomic) }.value
        try command("Stage Saved File…")
        try await UIVerification.waitUntil("Editor refuses the equal-byte replacement before showing a sheet") {
            window.isKeyWindow && window.attachedSheet == nil && editor.navigationStatus.contains("Reload the editor")
        }
        try UIVerification.require(try Data(contentsOf: index) == before && Data(contentsOf: file) == saved && text.string == draft
            && document.isDirty && text.undoManager?.canUndo == true, "The refused Stage changed the index, file, draft or Undo")
        text.undoManager?.undo()
        try await UIVerification.waitUntil("Undo still restores the editor's saved text") { !document.isDirty && Data(text.string.utf8) == saved }
        document.requestClose()
        try await UIVerification.waitUntil("The editor Index action and document have drained") { editors.documentForVerification(at: file) == nil }
    }

    private static func chooseBrowserWorkingFile(_ browser: BrowserViewController, parent: NSWindow,
                                                 usingEditor: Bool) async throws -> EditorComparisonWindow {
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try await UIVerification.waitUntil("Browser can compare its selected working file") {
            browser.canCompareSelectedGitFile && parent.isKeyWindow
        }
        try send(.compareGitWorkingFile, from: BrowserMenus.menu(.file, target: browser), to: browser)
        try await UIVerification.waitUntil("Browser opens the single revision chooser") {
            parent.attachedSheet?.isKeyWindow == true
        }
        guard let sheet = parent.attachedSheet, sheet.title == "Git Revision" else {
            throw UIVerification.Failure(message: "The working file did not open the shared one-revision picker")
        }
        _ = try await typeRevisionSearch("earlier", limitedTo: sheet)
        if usingEditor {
            try UIVerification.require(FolderCompositionOwnedControls.press("Compare Open Editor", in: sheet),
                "The revision picker did not offer the original open editor")
        } else {
            sheet.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: sheet))
        }
        do {
            try await UIVerification.waitUntil("Chosen working file opens as a pinned comparison") {
                browser.workspace?.textComparisonWindow?.window?.isKeyWindow == true
            }
        } catch {
            throw UIVerification.Failure(message: "Working file comparison did not arrive: \(browser.status.stringValue)")
        }
        guard let diff = browser.workspace?.textComparisonWindow else {
            throw UIVerification.Failure(message: "The chosen comparison window is missing")
        }
        return diff
    }

    private static func verifyBrowserBadges(_ browser: BrowserViewController, window: NSWindow, staged: URL,
                                            clean: URL, untracked: URL, owned: URL) async throws {
        let settings = browser.settings
        let priorMode = browser.effectiveViewMode, priorSize = settings.interfaceSize
        let selection = browser.selectedURLs
        defer {
            settings.showsGitFileBadges = false
            settings.interfaceSize = priorSize
            browser.setPaneViewMode(priorMode)
            browser.setFileSelection(selection)
        }
        func accessibleName(_ url: URL) -> String {
            if browser.usesFileIcons {
                return browser.iconBrowser.visibleItems.first { $0.entry?.url == url }?.view.accessibilityLabel() ?? ""
            }
            guard let row = browser.rowsByURL[url],
                  let column = browser.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }),
                  let name = browser.table.view(atColumn: column, row: row, makeIfNecessary: false) else { return "" }
            return name.accessibilityLabel() ?? ""
        }
        func selectMode(_ mode: BrowserViewMode) {
            browser.viewModeControl.selectedSegment = BrowserViewMode.allCases.firstIndex(of: mode) ?? 0
            browser.changeViewFromControl(browser.viewModeControl)
        }
        settings.interfaceSize = .init(150)
        selectMode(.list)
        window.contentView?.layoutSubtreeIfNeeded()
        settings.showsGitFileBadges = true
        try await UIVerification.waitUntil("Native Git marks in enlarged List") {
            accessibleName(staged).contains("Git change staged") && accessibleName(untracked).contains("Untracked by Git")
        }
        let cleanLabel = accessibleName(clean)
        try UIVerification.require(!accessibleName(staged).contains("On-disk bytes") && cleanLabel.hasPrefix(clean.lastPathComponent)
            && !["Git change staged", "Untracked by Git", "Git conflict"].contains { cleanLabel.contains($0) },
            "Browser badges inferred a text comparison or marked a clean file")
        try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-browser-badges-list-150.png"))

        selectMode(.icons)
        try await UIVerification.waitUntil("Native Git marks in enlarged Icons") {
            browser.usesFileIcons && accessibleName(staged).contains("Git change staged") && accessibleName(untracked).contains("Untracked by Git")
        }
        try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-browser-badges-icons-150.png"))
        settings.showsGitFileBadges = false
        try await UIVerification.waitUntil("Disabling native marks keeps filename and Git Tools") {
            let trackedName = accessibleName(staged), untrackedName = accessibleName(untracked)
            return trackedName.hasPrefix(staged.lastPathComponent) && !trackedName.contains("Git change staged")
                && untrackedName.hasPrefix(untracked.lastPathComponent) && !untrackedName.contains("Untracked by Git")
        }
        try UIVerification.require(browser.selectedURLs == selection && browser.gitControls.isAvailable,
            "File badges changed the selection or disabled Git navigation")
    }

    private static func verifyWorkingFolder(_ workspace: BrowserWorkspaceController, browser: BrowserViewController,
                                            parent: NSWindow, base: GitObjectID, owned: URL) async throws {
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try send(.compareGitWorkingFolder, from: BrowserMenus.menu(.file, target: browser), to: browser)
        guard let review = workspace.gitComparisonWindow, let window = review.window else {
            throw UIVerification.Failure(message: "The native Working Folder review did not open")
        }
        defer { window.close() }
        try await UIVerification.waitUntil("Working folder and current revision") {
            window.isKeyWindow && !review.model.busy && review.model.workingFolder?.path?.display == "Project Scope"
        }
        func sendReview(_ title: String, menu: String = "File") async throws {
            window.makeKeyAndOrderFront(nil)
            func command() -> NSMenuItem? { UIVerification.menuItem(menu, title) }
            try await UIVerification.waitUntil("Working Folder \(menu) command \(title)") {
                window.isKeyWindow && command()?.target === review && command().map(review.validateMenuItem) == true
            }
            guard let item = command(), let action = item.action,
                  NSApp.sendAction(action, to: review, from: item) else {
                throw UIVerification.Failure(message: "Native working review command unavailable: \(title)")
            }
        }
        func selectRow(_ name: String) async throws {
            guard let folder = review.model.workingFolder,
                  let row = folder.rows.firstIndex(where: { $0.path.name == name }) else {
                throw UIVerification.Failure(message: "Expected working folder row is unavailable")
            }
            try await UIVerification.waitUntil("Working folder native rows match the visible directory") {
                UIVerification.nativeTables(in: window.contentView).first?.numberOfRows == folder.rows.count
            }
            guard let table = UIVerification.nativeTables(in: window.contentView).first else {
                throw UIVerification.Failure(message: "Working folder table is unavailable")
            }
            try await UIVerification.clickRow(row, in: table)
            try await UIVerification.waitUntil("Working folder selected row") { review.model.selectedMember == folder.rows[row].path }
        }
        try await withEnlargedLayout(window, settings: browser.settings) {
            let picker = try await searchRevisions("Committed revision", in: window, query: "earlier")
            picker.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: picker))
            try await UIVerification.waitUntil("Selected branch compared with current disk") {
                window.isKeyWindow && !review.model.busy && review.model.workingFolder?.revision == base
            }
            let root = review.model.workingFolder
            try UIVerification.require(root?.onlyOnDisk == 1 && root?.onlyInRevision == 0 &&
                root?.rows.first(where: { $0.path.name == "Draft.txt" })?.difference == .contentsUnchecked,
                "The working folder claimed unobserved content or the wrong side")
            try await selectRow("Nested Shared")
            try await sendReview("Open Folder")
            try await UIVerification.waitUntil("Shared path on disk and in branch") {
                !review.model.busy && review.model.workingFolder?.path?.display == "Project Scope/Nested Shared"
                    && review.model.workingFolder?.rows.first?.path.name == "Nested.txt"
            }
            try await sendReview("Up a Folder")
            try await UIVerification.waitUntil("Working review returned within original scope") {
                !review.model.busy && review.model.workingFolder?.path == root?.path
            }
            try await selectRow("Draft.txt")
            guard let table = UIVerification.nativeTables(in: window.contentView).first,
                  table.tableColumns.count == 4 else { throw UIVerification.Failure(message: "Working folder columns are missing") }
            let viewport = table.enclosingScrollView?.contentView.bounds.width ?? table.bounds.width
            try UIVerification.require(table.rect(ofColumn: 3).maxX <= viewport + 1,
                "The enlarged working folder review clipped the Comparison column")
            try await sendReview("Check Contents")
            try await UIVerification.waitUntil("Explicit working content check finishes") {
                !review.model.busy && review.model.workingContents?.matching == 1 && review.model.workingContents?.differing == 1
            }
            try UIVerification.require(review.model.selectedMember?.name == "Draft.txt"
                && review.model.workingContents?.unchecked == 0, "Checking contents displaced the selected row or lost a comparison")
            let location = owned.appendingPathComponent("git-working-folder-150.png")
            if CGPreflightScreenCaptureAccess() { try await GlassVerification.captureOwnedWindow(window, to: location) }
            else { try await UIVerification.snapshot(window, to: location) }
            try await sendReview("Open Text Diff")
            let disk = try await capturedDiff(workspace.textComparisonWindow, left: "old draft\n", right: "new draft\n")
            try UIVerification.require(disk.labels.left.contains(base.short) && disk.labels.right.hasPrefix("Working Folder"),
                "The comparison did not label the selected commit and the on-disk source")
            await disk.closeAndDrain()
            await Task.yield()
            window.makeKeyAndOrderFront(nil)
            try await UIVerification.verifyDiffSearch(in: window, workspace: workspace, query: "untracked",
                expectedPath: "Project Scope/Untracked.txt", files: 3)
            try UIVerification.require(review.model.selectedMember?.name == "Draft.txt",
                "Searching across working-folder diffs displaced its selected file")
            guard let workingPath = review.model.selectedMember, let open = review.model.workingOpenSelection(for: workingPath) else {
                throw UIVerification.Failure(message: "No working file to edit")
            }
            let editors = ApplicationLocalTextEditors.shared
            try await sendReview("Open Working File in Editor")
            try await UIVerification.waitUntil("Working file opens through the ordinary edit owner") {
                guard let document = editors.documentForVerification(at: open.url) else { return false }
                return document.window.window?.isKeyWindow == true && document.captureCurrentText()?.text == "new draft\n"
            }
            guard let editor = editors.documentForVerification(at: open.url) else {
                throw UIVerification.Failure(message: "The working editor was lost")
            }
            let text = editor.window.surface.textView
            text.setSelectedRange(.init(location: 0, length: 0))
            text.insertText("Edited ", replacementRange: text.selectedRange())
            try UIVerification.require(editor.isDirty, "Working file did not join the editable buffer")
            try await sendReview("Open Working File in Editor")
            try await UIVerification.waitUntil("Opening reuses the same unsaved working file") {
                editor.window.window?.isKeyWindow == true && editors.documentForVerification(at: open.url) === editor
                    && text.string == "Edited new draft\n"
            }
            text.undoManager?.undo()
            try await UIVerification.waitUntil("Working file Undo returns to its original text") { !editor.isDirty && text.string == "new draft\n" }
            editor.requestClose()
            try await UIVerification.waitUntil("The owned working editor closes before the review continues") {
                editors.documentForVerification(at: open.url) == nil
            }
            let diskBytes = try await Task.detached { try Data(contentsOf: open.url) }.value
            try UIVerification.require(diskBytes == Data("new draft\r\n".utf8) && review.model.selectedMember == workingPath,
                "Opening and editing changed the disk file or the review selection")
            window.makeKeyAndOrderFront(nil)
            try await selectRow("Untracked.txt")
            try await sendReview("Open Text Diff")
            let addition = try await capturedDiff(workspace.textComparisonWindow, left: "", right: "untracked\n", added: 1, removed: 0)
            try UIVerification.require(addition.labels.left.hasSuffix("Absent"), "A missing committed file was shown as an existing empty file")
            await addition.closeAndDrain()

            window.makeKeyAndOrderFront(nil)
            @MainActor func indexCommand() -> NSMenuItem? {
                NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Compare with Git Index")
            }
            try await UIVerification.waitUntil("Native working baseline command") {
                window.isKeyWindow && indexCommand().map(review.validateMenuItem) == true
            }
            guard let compareIndex = indexCommand(), let action = compareIndex.action,
                  compareIndex.state == .off, NSApp.sendAction(action, to: review, from: compareIndex) else {
                throw UIVerification.Failure(message: "The working-folder baseline command did not dispatch")
            }
            try await UIVerification.waitUntil("Working folder and recorded Git index") {
                !review.model.busy && review.model.workingFolder?.comparesIndex == true
                    && review.model.workingFolder?.path == root?.path
            }
            try UIVerification.require(review.model.left?.revision == .object(base) && review.validateMenuItem(compareIndex)
                && compareIndex.state == .on && review.model.selectedMember == nil,
                "Index mode changed the captured revision or retained a stale selection")
            try await selectRow("Nested Shared")
            try await sendReview("Open Folder")
            try await UIVerification.waitUntil("Index paths imply the nested folder") {
                !review.model.busy && review.model.workingFolder?.path?.display == "Project Scope/Nested Shared"
                    && review.model.workingFolder?.rows.first?.path.name == "Nested.txt"
            }
            try await sendReview("Up a Folder")
            try await UIVerification.waitUntil("Working index review returns to its starting scope") {
                !review.model.busy && review.model.workingFolder?.path == root?.path
            }
            try await selectRow("Draft.txt")
            try await sendReview("Reload Working Folder")
            try UIVerification.require(review.model.workingFolder?.comparesIndex == true && review.model.selectedMember?.name == "Draft.txt",
                "Reload discarded the current report or selected path while the index read was pending")
            try await UIVerification.waitUntil("Reload keeps the same selected working index path") {
                !review.model.busy && review.model.workingFolder?.comparesIndex == true && review.model.selectedMember?.name == "Draft.txt"
            }
            try await sendReview("Check Contents")
            try await UIVerification.waitUntil("On-disk content compared against its index object") {
                !review.model.busy && review.model.workingContents?.matching == 1 && review.model.workingContents?.differing == 1
            }
            let reviewModel = review.model
            let matching = reviewModel.workingContents?.results.first { $0.value == .matchesRevision }?.key
            try await sendReview("Hide Matching Files", menu: "View")
            try await UIVerification.waitUntil("Only verified matching files are hidden") {
                !reviewModel.filteringChanges && reviewModel.hidesMatchingFiles && matching != nil
                    && !reviewModel.visibleWorkingRows.contains { $0.path == matching }
                    && reviewModel.visibleWorkingRows.contains { $0.path.name == "Nested Shared" && $0.isFolder }
                    && reviewModel.selectedMember?.name == "Draft.txt"
            }
            try await sendReview("Filter Folder Paths…", menu: "View")
            try await UIVerification.waitUntil("Working path filter has a native field editor") { (window.firstResponder as? NSTextView)?.isFieldEditor == true }
            guard let field = window.firstResponder as? NSTextView else { throw UIVerification.Failure(message: "Working path filter is inactive") }
            field.insertText(".txt", replacementRange: field.selectedRange())
            try await UIVerification.waitUntil("Working filter retains only the changed and new text paths") {
                !reviewModel.filteringChanges && reviewModel.changeQuery == ".txt"
                    && reviewModel.visibleWorkingRows.map(\.path.name) == ["Draft.txt", "Untracked.txt"]
            }
            window.sendEvent(UIVerification.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, flags: [], window: window))
            try await UIVerification.waitUntil("Working path filter Arrow moves its selection") { reviewModel.selectedMember?.name == "Untracked.txt" }
            try UIVerification.require(window.firstResponder === field, "Working path selection stole filter input focus")
            try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-working-index-150.png"))
            window.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: window))
            try await UIVerification.waitUntil("Working path filter Escape resets only its query") {
                reviewModel.changeFilterID == nil && !reviewModel.filteringChanges && reviewModel.changeQuery.isEmpty
                    && reviewModel.hidesMatchingFiles && window.firstResponder !== field
            }
            try await sendReview("Hide Matching Files", menu: "View")
            try await UIVerification.waitUntil("Matching file returned before opening a selected diff") {
                !reviewModel.hidesMatchingFiles && !reviewModel.filteringChanges && reviewModel.visibleWorkingRows.contains { $0.path == matching }
            }
            try await selectRow("Draft.txt")
            try await sendReview("Open Text Diff")
            let indexed = try await capturedDiff(workspace.textComparisonWindow, left: "staged draft\n", right: "new draft\n")
            try UIVerification.require(indexed.labels.left.hasPrefix("Git Index")
                && indexed.planForVerification?.before.encoded == Data("staged draft\r\n".utf8)
                && indexed.planForVerification?.current.encoded == Data("new draft\r\n".utf8),
                "The working-file diff substituted HEAD or changed staged/disk bytes")
            await indexed.closeAndDrain()
            window.makeKeyAndOrderFront(nil)
            try await UIVerification.waitUntil("Baseline command returned after closing its diff") {
                window.isKeyWindow && indexCommand().map(review.validateMenuItem) == true
            }
            guard let returnToRevision = indexCommand(), let toggle = returnToRevision.action,
                  NSApp.sendAction(toggle, to: review, from: returnToRevision) else {
                throw UIVerification.Failure(message: "The prior committed baseline could not be restored")
            }
            try await UIVerification.waitUntil("Prior pinned revision restored in the same scope") {
                !review.model.busy && review.model.workingFolder?.revision == base
                    && review.model.workingFolder?.path == root?.path
            }
        }
    }

    private static func verifyConflictReview(_ workspace: BrowserWorkspaceController, browser: BrowserViewController,
                                             parent: NSWindow, owned: URL) async throws {
        let root = owned.appendingPathComponent("Conflict Repository", isDirectory: true)
        let text = root.appendingPathComponent("Conflict.txt"), deleted = root.appendingPathComponent("Removed.txt")
        let observed = [text, deleted] + ["HEAD", "index", "MERGE_HEAD"].map { root.appendingPathComponent(".git/" + $0) }
        let original = try await Task.detached {
            try FileManager().createDirectory(at: root, withIntermediateDirectories: false)
            try UIVerification.generateGit(in: root, ["init", "--template=", "--initial-branch=main"])
            try Data("base text\n".utf8).write(to: text)
            try Data("initial second file\n".utf8).write(to: deleted)
            try UIVerification.generateGit(in: root, ["add", "-A"])
            try UIVerification.generateGit(in: root, ["commit", "-m", "Base"])
            try UIVerification.generateGit(in: root, ["checkout", "-b", "incoming"])
            try Data("incoming text\n".utf8).write(to: text)
            try UIVerification.generateGit(in: root, ["rm", "--", "Removed.txt"])
            try UIVerification.generateGit(in: root, ["commit", "-am", "Incoming branch"])
            try UIVerification.generateGit(in: root, ["checkout", "main"])
            try Data("checked out text\n".utf8).write(to: text)
            try Data("kept on main\n".utf8).write(to: deleted)
            try UIVerification.generateGit(in: root, ["commit", "-am", "Working branch"])
            try UIVerification.generateGit(in: root, ["-c", "merge.conflictStyle=diff3", "merge", "--no-edit", "incoming"], expectedStatus: 1)
            return try observed.map { try Data(contentsOf: $0) }
        }.value
        browser.navigate(to: .directory(root))
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try await UIVerification.waitUntil("Exact unmerged generated repository") {
            parent.isKeyWindow && browser.gitControls.repository?.root.path == root.path && browser.rowsByURL[text] != nil
        }
        try send(.reviewStagedChanges, from: BrowserMenus.menu(.file, target: browser), to: browser)
        guard let review = workspace.gitComparisonWindow, let window = review.window else {
            throw UIVerification.Failure(message: "Conflicts did not open from the native staged review")
        }
        defer { window.close() }
        func sendReview(_ title: String, in menuName: String) async throws {
            window.makeKeyAndOrderFront(nil)
            func command() -> NSMenuItem? { NSApp.mainMenu?.item(withTitle: menuName)?.submenu?.item(withTitle: title) }
            try await UIVerification.waitUntil("Git conflict command \(title)") {
                window.isKeyWindow && command()?.target === review && command().map(review.validateMenuItem) == true
            }
            guard let item = command(), let action = item.action,
                  NSApp.sendAction(action, to: review, from: item) else {
                throw UIVerification.Failure(message: "The conflict review did not handle \(title)")
            }
        }
        try await UIVerification.waitUntil("Unmerged paths become the active review") {
            window.isKeyWindow && !review.model.busy && review.model.presentation == .conflicts
        }
        try await withEnlargedLayout(window, settings: browser.settings) {
            try UIVerification.require(review.model.staged?.unmerged.map(\.display) == ["Conflict.txt", "Removed.txt"],
                "The unmerged native list did not preserve both index paths")
            try await sendReview("Show Changes", in: "View")
            try UIVerification.require(review.model.presentation == .changes, "The native View menu did not return to staged changes")
            try await sendReview("Show Conflicts", in: "View")
            try await UIVerification.waitUntil("Native conflict table") {
                guard let table = UIVerification.nativeTables(in: window.contentView).first else { return false }
                return table.numberOfRows == 2 && table.tableColumns.count == 4
            }
            guard let table = UIVerification.nativeTables(in: window.contentView).first else {
                throw UIVerification.Failure(message: "No selectable native unmerged table")
            }
            let edge = table.rect(ofColumn: 3).maxX
            let viewport = table.enclosingScrollView?.contentView.bounds.width ?? table.bounds.width
            try UIVerification.require(table.tableColumns.map(\.title) == ["File", "Base", "Ours", "Theirs"] && edge <= viewport + 1,
                "An unmerged stage column is outside the enlarged window")
            try await UIVerification.clickRow(0, in: table)
            try await sendReview("Open Text Diff", in: "File")
            let branches = try await capturedDiff(workspace.textComparisonWindow, left: "checked out text\n", right: "incoming text\n")
            try UIVerification.require(branches.labels.left.hasPrefix("Ours") && branches.labels.right.hasPrefix("Theirs"),
                "The compared index stages are mislabeled")
            await branches.closeAndDrain()
            try await sendReview("Compare Base and Theirs", in: "View")
            try await UIVerification.clickRow(1, in: table)
            let capture = owned.appendingPathComponent("git-conflict-review-150.png")
            if CGPreflightScreenCaptureAccess() { try await GlassVerification.captureOwnedWindow(window, to: capture) }
            else { try await UIVerification.snapshot(window, to: capture) }
            try await sendReview("Open Text Diff", in: "File")
            let omission = try await capturedDiff(workspace.textComparisonWindow,
                left: "initial second file\n", right: "", added: 0, removed: 1)
            try UIVerification.require(omission.labels.left.hasPrefix("Base") && omission.labels.right == "Theirs · Absent",
                "A deleted conflict side was shown as an existing empty file")
            await omission.closeAndDrain()
        }
        window.close()
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try await verifyConflictMarkers(in: browser, at: text, original: String(decoding: original[0], as: UTF8.self))
        let end = try await Task.detached { try observed.map { try Data(contentsOf: $0) } }.value
        try UIVerification.require(end == original, "Conflict review changed the generated merge, index or working copy")
        browser.goComputer(nil)
    }

    private static func verifyConflictMarkers(in browser: BrowserViewController, at file: URL, original: String) async throws {
        try UIVerification.select(file.lastPathComponent, in: browser)
        browser.editTextInTraverse(nil)
        let editors = ApplicationLocalTextEditors.shared
        try await UIVerification.waitUntil("Generated conflict opened with one recognized block") {
            guard let editor = editors.documentForVerification(at: file) else { return false }
            return editor.window.window?.isKeyWindow == true && editor.window.surface.conflictMarkers?.blocks.count == 1
        }
        guard let editor = editors.documentForVerification(at: file), let window = editor.window.window else {
            throw UIVerification.Failure(message: "Generated conflict editor is unavailable")
        }
        let surface = editor.window.surface, body = surface.textView
        window.makeFirstResponder(body)
        func choose(_ label: String) throws {
            let edit = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu
            let choices = edit?.item(withTitle: "Merge Conflict Markers")?.submenu
            guard let item = choices?.item(withTitle: label), let action = item.action, editor.window.validateUserInterfaceItem(item),
                  NSApp.sendAction(action, to: editor.window, from: item) else {
                throw UIVerification.Failure(message: "Conflict editor command unavailable: " + label)
            }
        }
        body.setSelectedRange(NSRange(location: body.string.utf16.count, length: 0))
        try choose("Next Conflict")
        try UIVerification.require(body.selectedRange().location == 0 && body.string == original,
            "Conflict navigation moved the caret or changed the wrong text")
        try choose("Keep Base Section")
        try await UIVerification.waitUntil("Base chosen in memory") { body.string == "base text\n" && editor.isDirty }
        guard let undo = body.undoManager else { throw UIVerification.Failure(message: "Conflict text did not retain native Undo") }
        undo.undo()
        try await UIVerification.waitUntil("Undo restored the exact diff3 text and markers") {
            body.string == original && surface.conflictMarkers?.blocks.count == 1 && !editor.isDirty
        }
        try choose("Keep Both Sections")
        try await UIVerification.waitUntil("Both sections preserved in the original order") {
            body.string == "checked out text\nincoming text\n" && editor.isDirty
        }
        undo.undo()
        try await UIVerification.waitUntil("Undo restores the conflict before Redo") { body.string == original && !editor.isDirty }
        undo.redo()
        try await UIVerification.waitUntil("Redo reapplies the exact selected sections") { body.string == "checked out text\nincoming text\n" }
        undo.undo()
        try await UIVerification.waitUntil("Generated diff3 editor is clean") { body.string == original && !editor.isDirty }
        editor.requestClose()
        try await UIVerification.waitUntil("Generated conflict editor closed") { editors.documentForVerification(at: file) == nil }
    }

    private static func verifyLinkedWorktree(_ workspace: BrowserWorkspaceController, browser: BrowserViewController,
                                             parent: NSWindow, repo: URL, base: GitObjectID, owned: URL) async throws {
        let linked = owned.appendingPathComponent("Linked Checkout", isDirectory: true)
        let scope = linked.appendingPathComponent("Project Scope", isDirectory: true)
        let file = scope.appendingPathComponent("Draft.txt")
        try await Task.detached {
            try UIVerification.generateGit(in: repo, ["worktree", "add", "-b", "linked-review", linked.path, base.hex])
            try Data("linked index text\n".utf8).write(to: file)
            try UIVerification.generateGit(in: linked, ["add", "--", "Project Scope/Draft.txt"])
            try Data("linked disk text\n".utf8).write(to: file)
        }.value
        browser.navigate(to: .directory(scope))
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try await UIVerification.waitUntil("Git Tools is active inside the linked worktree") {
            parent.isKeyWindow && browser.gitControls.repository?.isLinkedWorktree == true
                && browser.gitControls.repository?.root.path == linked.path && browser.rowsByURL[file] != nil
        }
        try UIVerification.require(browser.gitToolsMenu().items.first?.title == "linked-review",
            "A linked checkout displayed the main checkout's branch")
        try send(.reviewStagedChanges, from: BrowserMenus.menu(.file, target: browser), to: browser)
        guard let review = workspace.gitComparisonWindow, let window = review.window else {
            throw UIVerification.Failure(message: "Linked worktree did not open the staged review")
        }
        defer { if window.isVisible { window.close() } }
        try await UIVerification.waitUntil("Linked worktree's own index is visible") {
            window.isKeyWindow && !review.model.busy && review.model.staged?.base == base
                && UIVerification.nativeTables(in: window.contentView).first?.numberOfRows == 1
        }
        guard let table = UIVerification.nativeTables(in: window.contentView).first,
              let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Open Text Diff"), let action = item.action else {
            throw UIVerification.Failure(message: "Linked worktree's staged diff was unavailable")
        }
        try await UIVerification.clickRow(0, in: table)
        try UIVerification.require(review.validateMenuItem(item) && NSApp.sendAction(action, to: review, from: item),
            "The staged comparison refused the linked worktree's live row")
        let diff = try await capturedDiff(workspace.textComparisonWindow, left: "old draft\n", right: "linked index text\n")
        await diff.closeAndDrain()
        let bytes = try await Task.detached { try Data(contentsOf: file) }.value
        try UIVerification.require(bytes == Data("linked disk text\n".utf8), "Review changed the linked working file")
        window.close()
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try await verifyBrowseWorktrees(workspace, browser: browser, parent: parent, repo: repo, base: base, owned: owned)
        try await verifyEditorWorktree(browser, parent: parent, source: file, other: repo.appendingPathComponent("Project Scope/Draft.txt"))
        try await Task.detached { try UIVerification.generateGit(in: linked, ["update-ref", "--no-deref", "HEAD", base.hex]) }.value
        parent.makeKeyAndOrderFront(nil)
        browser.refresh(nil)
        try await UIVerification.waitUntil("Git Tools refreshed the detached checkout label") {
            browser.gitControls.checkout?.head == .detached(base) && browser.gitToolsMenu().items.first?.title == "Detached at \(base.short)"
        }
    }

    private static func verifyEditorWorktree(_ browser: BrowserViewController, parent: NSWindow, source: URL, other: URL) async throws {
        let editors = ApplicationLocalTextEditors.shared
        let before = try await Task.detached { try [source, other].map { try Data(contentsOf: $0) } }.value
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try await UIVerification.waitUntil("Worktree file returns to the ordinary browser listing") {
            parent.isKeyWindow && browser.rowsByURL[source] != nil && !browser.isLoading && browser.orderingTask == nil
        }
        browser.setFileSelection([source])
        try UIVerification.require(browser.canEditTextInTraverse, "The selected worktree file was not eligible for its ordinary editor")
        browser.editTextInTraverse(nil)
        try await UIVerification.waitUntil("Linked worktree editor and its Git menu") {
            guard let editor = editors.documentForVerification(at: source) else { return false }
            return editor.window.window?.isKeyWindow == true && !editor.hasPendingFileWork && editor.window.surface.canGoToLine
        }
        guard let original = editors.documentForVerification(at: source), let origin = original.window.window else {
            throw UIVerification.Failure(message: "The linked working file did not open in an ordinary editor")
        }
        defer {
            if let sheet = origin.attachedSheet, sheet.title == "File in Git Worktree" {
                origin.endSheet(sheet, returnCode: .cancel)
            }
        }
        let first = original.window.surface.textView
        first.insertText("linked draft text\n", replacementRange: NSRange(location: 0, length: first.string.utf16.count))
        try await UIVerification.waitUntil("First worktree draft is ready") { original.isDirty && original.window.surface.canGoToLine }
        let sourceCaret = first.selectedRange()
        func choose() async throws -> NSWindow {
            origin.makeKeyAndOrderFront(nil)
            func command() -> NSMenuItem? {
                UIVerification.menuItem("File", "Git", "Open or Compare File in Git Worktree…")
            }
            try await UIVerification.waitUntil("Worktree command owned by the original editor") {
                origin.isKeyWindow && command()?.target === original.window && command().map(original.window.validateUserInterfaceItem) == true
            }
            guard let item = command(), let action = item.action, NSApp.sendAction(action, to: original.window, from: item) else {
                throw UIVerification.Failure(message: "The native editor worktree command did not dispatch")
            }
            try await UIVerification.waitUntil("Native editor worktree choices") {
                origin.attachedSheet?.isKeyWindow == true
                    && UIVerification.nativeTables(in: origin.attachedSheet?.contentView).contains { $0.numberOfRows == 2 }
            }
            guard let sheet = origin.attachedSheet else { throw UIVerification.Failure(message: "Editor worktree chooser disappeared") }
            return sheet
        }
        let disk = try await choose()
        try worktreeButton("Compare with Editor", in: disk).performClick(nil)
        try await UIVerification.waitUntil("Worktree disk diff opens") { original.window.gitRevisionDiffForVerification != nil }
        let firstDiff = try await capturedDiff(original.window.gitRevisionDiffForVerification,
            left: "linked draft text\n", right: "new draft\n")
        try UIVerification.require(firstDiff.labels.right == "main · On Disk", "Worktree comparison mislabeled the exact on-disk source")
        await firstDiff.closeAndDrain()

        let open = try await choose()
        open.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: open))
        try await UIVerification.waitUntil("Return opened the other worktree file") {
            guard let peer = editors.documentForVerification(at: other) else { return false }
            return peer.window.window?.isKeyWindow == true && !peer.hasPendingFileWork && peer.window.surface.canGoToLine
        }
        guard let peer = editors.documentForVerification(at: other), let peerWindow = peer.window.window else {
            throw UIVerification.Failure(message: "The counterpart editor was not retained")
        }
        let second = peer.window.surface.textView
        try UIVerification.require(second.string == "new draft\n" && first.string == "linked draft text\n"
            && peer.window.fileSidebar?.files?.currentHistoryFile == other, "Opening the counterpart used the wrong checkout or replaced the first draft")
        second.insertText("main draft text\n", replacementRange: NSRange(location: 0, length: second.string.utf16.count))
        try await UIVerification.waitUntil("Second worktree draft is ready") { peer.isDirty && peer.window.surface.canGoToLine }
        guard let previous = UIVerification.menuItem("Go", "Previous Text Location"),
              let previousAction = previous.action, peer.window.validateUserInterfaceItem(previous),
              NSApp.sendAction(previousAction, to: peer.window, from: previous) else {
            throw UIVerification.Failure(message: "Opening a worktree counterpart did not keep the editor return location")
        }
        try await UIVerification.waitUntil("Previous Text Location returns to the original worktree editor") {
            origin.isKeyWindow && first.selectedRange() == sourceCaret
        }
        let compare = try await choose()
        try worktreeButton("Compare with Editor", in: compare).performClick(nil)
        try await UIVerification.waitUntil("Worktree draft diff opens") { original.window.gitRevisionDiffForVerification != nil }
        let both = try await capturedDiff(original.window.gitRevisionDiffForVerification,
            left: "linked draft text\n", right: "main draft text\n")
        try UIVerification.require(both.labels.right == "main · Editor Buffer", "The comparison read disk instead of the exact open worktree editor")
        try await verifyApplyWorktreeChange(both, first: original, second: peer)
        await both.closeAndDrain()
        peerWindow.makeKeyAndOrderFront(nil)
        second.undoManager?.undo()
        origin.makeKeyAndOrderFront(nil)
        first.undoManager?.undo()
        try await UIVerification.waitUntil("Undo clears both drafts without saving") { !peer.isDirty && !original.isDirty }
        peerWindow.makeKeyAndOrderFront(nil)
        peer.requestClose()
        origin.makeKeyAndOrderFront(nil)
        original.requestClose()
        try await UIVerification.waitUntil("Generated worktree editors close") {
            editors.documentForVerification(at: source) == nil && editors.documentForVerification(at: other) == nil
        }
        let after = try await Task.detached { try [source, other].map { try Data(contentsOf: $0) } }.value
        try UIVerification.require(before == after, "Worktree opening or comparing changed disk bytes")
        parent.makeKeyAndOrderFront(nil)
    }

    private static func verifyApplyWorktreeChange(_ diff: EditorComparisonWindow, first: LocalTextDocumentController,
                                                  second: LocalTextDocumentController) async throws {
        guard let window = diff.window else { throw UIVerification.Failure(message: "Missing worktree change window") }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(diff.currentSurface.textView)
        func menuItem() -> NSMenuItem? {
            NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Apply Selected Change to Editor")
        }
        try await UIVerification.waitUntil("Apply to the exact selected worktree editor") {
            window.isKeyWindow && menuItem()?.target === diff && menuItem().map(diff.validateUserInterfaceItem) == true
        }
        guard let command = menuItem(), let action = command.action,
              NSApp.sendAction(action, to: diff, from: command) else {
            throw UIVerification.Failure(message: "The exact change did not dispatch through the shared File menu")
        }
        let target = second.window.surface.textView
        try await UIVerification.waitUntil("One native change applied to the other worktree draft") {
            second.window.window?.isKeyWindow == true && target.string == "linked draft text\n"
                && target.undoManager?.undoActionName == "Apply Compared Change"
        }
        try UIVerification.require(first.window.surface.textView.string == "linked draft text\n" && first.isDirty,
            "Applying to the peer changed the original worktree editor")
        target.undoManager?.undo()
        try await UIVerification.waitUntil("One text Undo restores the other worktree's original draft") {
            target.string == "main draft text\n" && second.isDirty
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(diff.currentSurface.textView)
        try UIVerification.require(!diff.canApplyChange(to: .current) && menuItem().map(diff.validateUserInterfaceItem) != true,
            "An Undo still admitted an offset captured from the old editor generation")
    }

    private static func worktreeButton(_ title: String, in sheet: NSWindow) throws -> NSButton {
        guard sheet.isKeyWindow, let content = sheet.contentView,
              let button = WorkspaceNetworkVerification.descendants(content).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == title && $0.isEnabled }) else {
            throw UIVerification.Failure(message: "Could not use \(title) in the native worktree chooser")
        }
        return button
    }

    private static func verifyBrowseWorktrees(_ workspace: BrowserWorkspaceController, browser: BrowserViewController,
                                               parent: NSWindow, repo: URL, base: GitObjectID, owned: URL) async throws {
        let original = browser.activeID
        let location = browser.location
        let tabs = browser.tabs.map(\.id)
        let paneCount = workspace.browsers.count
        defer {
            if let sheet = parent.attachedSheet, sheet.title == "Browse Git Worktrees" {
                parent.endSheet(sheet, returnCode: .cancel)
            }
        }
        func picker() async throws -> NSWindow {
            try await UIVerification.waitUntil("Current checkout can browse worktrees") { browser.canBrowseGitWorktrees && parent.isKeyWindow }
            try send(.browseGitWorktrees, from: BrowserMenus.menu(.file, target: browser), to: browser)
            try await UIVerification.waitUntil("Linked and primary worktree rows") {
                guard let sheet = parent.attachedSheet, sheet.isKeyWindow else { return false }
                return UIVerification.nativeTables(in: sheet.contentView).contains { $0.numberOfRows == 2 }
            }
            guard let sheet = parent.attachedSheet else { throw UIVerification.Failure(message: "Worktree picker disappeared") }
            return sheet
        }

        let cancel = try await picker()
        cancel.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: cancel))
        try await UIVerification.waitUntil("Escape dismissed the worktree sheet") { parent.attachedSheet == nil }
        try await UIVerification.waitUntil("Worktree Cancel drains without changing either pane") { browser.canBrowseGitWorktrees }
        try UIVerification.require(browser.tabs.map(\.id) == tabs && browser.location == location && workspace.browsers.count == paneCount,
            "Cancelling the worktree chooser changed the workspace")

        do {
            let settings = browser.settings
            let originalSize = settings.interfaceSize
            let previousBinding = InterfacePresentation.shared.settings
            InterfacePresentation.shared.bind(settings)
            defer {
                settings.interfaceSize = originalSize
                if let previousBinding { InterfacePresentation.shared.bind(previousBinding) }
            }
            settings.interfaceSize = .init(150)
            let side = try await picker()
            guard let content = side.contentView, let table = UIVerification.nativeTables(in: content).first else {
                throw UIVerification.Failure(message: "The worktree chooser has no native table")
            }
            try await UIVerification.waitUntil("Worktree table has keyboard focus and room for both checkouts") {
                side.firstResponder === table && table.visibleRect.height >= table.rect(ofRow: 1).maxY - 1
            }
            let selected = table.selectedRow
            try UIVerification.require(selected >= 0, "The worktree chooser did not select an alternate checkout")
            let arrow = selected == 0 ? UIVerification.key("\u{f701}", code: 125, flags: [], window: side)
                : UIVerification.key("\u{f700}", code: 126, flags: [], window: side)
            side.sendEvent(arrow)
            try UIVerification.require(table.selectedRow == selected, "The current checkout became selectable")
            for title in ["Open in Pane", "Open matching folder", "Open in Tab"] {
                let control = try worktreeButton(title, in: side)
                let frame = control.convert(control.bounds, to: content)
                try UIVerification.require(frame.width > 30 && content.bounds.contains(frame),
                    "The worktree chooser clipped \(title) at enlarged size")
            }
            try await UIVerification.snapshot(side, to: owned.appendingPathComponent("git-worktree-picker-native.png"))
            try worktreeButton("Open in Pane", in: side).performClick(nil)
        }
        let matchingFolder = repo.appendingPathComponent("Project Scope", isDirectory: true)
        try await UIVerification.waitUntil("Matching worktree folder opened beside the linked checkout") {
            workspace.browsers.count == paneCount + 1 && workspace.activeBrowser !== browser
                && workspace.activeBrowser.location.directoryURL == matchingFolder && workspace.activeBrowser.gitControls.repository?.root == repo
        }
        try UIVerification.require(browser.activeID == original && browser.location == location && browser.tabs.map(\.id) == tabs,
            "Opening a worktree changed the originating pane")
        try await verifyPairedCheckouts(workspace, original: browser, peer: workspace.activeBrowser,
                                       parent: parent, main: repo, base: base, owned: owned)
        let peer = workspace.activeBrowser.activeID
        try UIVerification.require(workspace.closeActivePane() && workspace.activeBrowser === browser, "Could not close the generated peer pane")
        browser.closeTab(id: peer)
        browser.selectTab(original)
        let tab = try await picker()
        let option = try worktreeButton("Open matching folder", in: tab)
        try UIVerification.require(option.state == .on, "The worktree picker did not default to the matching folder")
        option.performClick(nil)
        try UIVerification.require(option.state == .off, "The worktree picker did not allow opening the checkout root instead")
        tab.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: tab))
        try await UIVerification.waitUntil("Return opened the main checkout in a tab") {
            browser.location.directoryURL == repo && browser.tabs.count == tabs.count + 1
        }
        let opened = browser.activeID
        browser.selectTab(original)
        browser.closeTab(id: opened)
        try UIVerification.require(browser.tabs.map(\.id) == tabs && browser.location == location,
            "The linked checkout's original tabs did not survive the journey")
    }

    private static func verifyPairedCheckouts(_ workspace: BrowserWorkspaceController, original: BrowserViewController,
                                               peer: BrowserViewController, parent: NSWindow, main: URL, base: GitObjectID,
                                               owned: URL) async throws {
        peer.navigate(to: .directory(main))
        try await UIVerification.waitUntil("Different relative folders leave the Git comparison unavailable") {
            peer.gitControls.repository?.relativeFolder.isEmpty == true && !workspace.canPerformDividerAction(.compareGit)
        }
        let sameFolder = main.appendingPathComponent("Project Scope", isDirectory: true)
        peer.goBack(nil)
        try await UIVerification.waitUntil("Corresponding Git folders admit a revision comparison") {
            parent.isKeyWindow && peer.location.directoryURL == sameFolder
                && peer.gitControls.checkout?.head == .branch("main") && workspace.canPerformDividerAction(.compareGit)
        }
        let action = BrowserCommand.compareGitCheckouts.selector
        let menu = BrowserMenus.menu(.view, target: peer)
        guard let together = workspace.layout.parent(of: peer.paneID)?.id,
              let item = menu.items.first(where: { $0.action == action }), peer.validateMenuItem(item), !item.isHidden else {
            throw UIVerification.Failure(message: "The matching Git folders have no native View command")
        }
        let originalSelection = original.selectedURLs, peerSelection = peer.selectedURLs
        try WorkspaceNavigationVerification.pressDivider(.compareGit, split: together, in: workspace)
        guard let review = workspace.gitComparisonWindow, let window = review.window else {
            throw UIVerification.Failure(message: "The divider did not open Git checkout comparison")
        }
        try await UIVerification.waitUntil("Git checkout pair report") { window.isKeyWindow && !review.model.busy }
        try UIVerification.require(review.model.left?.title == "linked-review" && review.model.right?.title == "main"
            && review.model.report?.selectedLeft == base && review.model.report?.right != base
            && review.model.report?.summary.changes.first?.right?.path.display == "Project Scope/Draft.txt"
            && review.model.report?.summary.changes.count == 1,
            "The clicked divider did not compare the two checked-out revisions in pane order")
        try await withEnlargedLayout(window, settings: peer.settings) {
            try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-checkouts-enlarged.png"))
            if CGPreflightScreenCaptureAccess() {
                try await GlassVerification.captureOwnedWindow(window, to: owned.appendingPathComponent("git-checkouts-composited.png"))
            }
            guard let table = UIVerification.nativeTables(in: window.contentView).first, table.numberOfColumns == 4 else {
                throw UIVerification.Failure(message: "The enlarged checkout comparison did not lay out four columns")
            }
            for column in 0..<table.numberOfColumns {
                guard let cell = table.view(atColumn: column, row: 0, makeIfNecessary: false) else {
                    throw UIVerification.Failure(message: "The enlarged checkout comparison did not retain column \(column)")
                }
                let expected = table.rect(ofColumn: column)
                let actual = table.convert(cell.bounds, from: cell)
                try UIVerification.require(abs(actual.midX - expected.midX) < 10,
                    "Checkout table row column \(column) is offset from its header at 150 percent: \(actual.midX) vs \(expected.midX)")
            }
        }
        try await UIVerification.waitUntil("Checkout comparison owns its native menu") {
            window.isKeyWindow && ToolWindowMenuOwnership.owns(review)
        }
        guard let table = UIVerification.nativeTables(in: window.contentView).first,
              let command = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Open Text Diff"),
              let mode = command.action else { throw UIVerification.Failure(message: "The paired comparison text command is unavailable") }
        try await UIVerification.clickRow(0, in: table)
        try UIVerification.require(review.validateMenuItem(command) && NSApp.sendAction(mode, to: review, from: command),
            "The paired revision did not open its committed text")
        let diff = try await capturedDiff(workspace.textComparisonWindow, left: "old draft\n", right: "new draft\n")
        await diff.closeAndDrain()
        window.close()
        parent.makeKeyAndOrderFront(nil)
        workspace.activate(peer)
        peer.focusBrowserContent()
        try UIVerification.require(original.selectedURLs == originalSelection && peer.selectedURLs == peerSelection,
            "Comparing two Git checkouts changed the browser selection")
    }

    private static func verifyStagedReview(_ workspace: BrowserWorkspaceController, browser: BrowserViewController,
                                           parent: NSWindow, before: GitObjectID, head: GitObjectID, owned: URL) async throws {
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try send(.reviewStagedChanges, from: BrowserMenus.menu(.file, target: browser), to: browser)
        guard let review = workspace.gitComparisonWindow, let window = review.window else {
            throw UIVerification.Failure(message: "The File menu did not open Review Staged Changes")
        }
        defer { window.close() }
        try await UIVerification.waitUntil("Staged changes against HEAD") {
            window.isKeyWindow && !review.model.busy && review.model.staged?.base == head
        }
        try UIVerification.require(review.model.summary?.changes.count == 1
            && review.model.summary?.changes.first?.right?.path.display == "Project Scope/Draft.txt"
            && review.model.report == nil, "The staged report did not distinguish the index from local working files")
        try await withEnlargedLayout(window, settings: browser.settings) {
            let picker = try await searchRevisions("Base revision", in: window, query: "earlier")
            picker.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: picker))
            try await UIVerification.waitUntil("Index comparison remains open with the earlier base") {
                window.isKeyWindow && !review.model.busy && review.model.staged?.base == before
            }
            try await UIVerification.waitUntil("Staged table and File menu are installed after revision selection") {
                ToolWindowMenuOwnership.owns(review)
                    && UIVerification.nativeTables(in: window.contentView).first?.numberOfRows == 1
                    && NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Open Text Diff")?.target === review
            }
            guard let row = review.model.summary?.changes.first?.id,
                  let table = UIVerification.nativeTables(in: window.contentView).first,
                  let command = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Open Text Diff"),
                  let action = command.action else {
                throw UIVerification.Failure(message: "The staged report did not expose its text diff")
            }
            try await UIVerification.clickRow(row, in: table)
            try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-staged-review-150.png"))
            let columns = table.tableColumns.map { ($0.title, Int($0.width)) }
            let visibleWidth = table.enclosingScrollView?.contentView.bounds.width ?? table.bounds.width
            let end = table.tableColumns.count == 4 ? table.rect(ofColumn: 3).maxX : table.bounds.maxX
            try UIVerification.require(table.tableColumns.count == 4 && end <= visibleWidth + 1,
                "The enlarged staged table clipped its Change or Lines column: \(columns), \(end) of \(visibleWidth) points")
            try UIVerification.require(review.validateMenuItem(command) && NSApp.sendAction(action, to: review, from: command),
                                       "The selected staged row did not open the native text diff")
            let diff = try await capturedDiff(workspace.textComparisonWindow, left: "old draft\n", right: "staged draft\n")
            try UIVerification.require(diff.labels.right.hasPrefix("Git Index") && diff.labels.left.contains(before.short),
                                       "The diff did not label its exact base and staged source")
            await diff.closeAndDrain()
        }
    }

    private static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views(in: $0) } }

    private static func searchRevisions(_ label: String, in window: NSWindow, query: String) async throws -> NSWindow {
        try await UIVerification.waitUntil("Current native revision picker \(label)") {
            window.isKeyWindow && FolderCompositionOwnedControls.isEnabled(label, in: window)
        }
        try UIVerification.require(FolderCompositionOwnedControls.press(label, in: window), "The native revision picker did not open")
        return try await typeRevisionSearch(query)
    }

    private static func typeRevisionSearch(_ query: String, limitedTo target: NSWindow? = nil) async throws -> NSWindow {
        let deadline = ContinuousClock.now + .seconds(3)
        func fields() -> [NSTextField] {
            (target.map { [$0] } ?? NSApp.windows.filter(\.isVisible))
                .compactMap(\.contentView).flatMap { views(in: $0) }.compactMap { $0 as? NSTextField }
        }
        let input = {
            fields().first {
                $0.placeholderString == "Find a branch, tag or commit" || $0.accessibilityIdentifier() == "git-revision-search"
            }
        }
        while input()?.currentEditor() == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        guard let search = input(), let popover = search.window, search.currentEditor() != nil else {
            let observed = NSApp.windows.filter(\.isVisible).map { candidate in
                "\(type(of: candidate)) key=\(candidate.isKeyWindow) responder=\(candidate.firstResponder.map { String(describing: type(of: $0)) } ?? "none")"
            }
            throw UIVerification.Failure(message: "Native revision search has no focused field. Fields \(fields().count). \(observed.joined(separator: ", "))")
        }
        for letter in query {
            popover.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: popover))
        }
        try await UIVerification.waitUntil("Revision search accepts normal typing") {
            (search.currentEditor() as? NSTextView)?.string == query || search.stringValue == query
        }
        try await Task.sleep(for: .milliseconds(90))
        return popover
    }

    private static func chooseRightBranch(_ name: String, in window: NSWindow, model: GitComparisonModel) async throws {
        let query = "local branch"
        let candidates = model.choices.filter { $0.title.localizedStandardContains(query) || $0.detail.localizedStandardContains(query) }
        guard let index = candidates.firstIndex(where: { $0.title == name }), index > 0 else {
            throw UIVerification.Failure(message: "The generated branch does not exercise arrow selection")
        }
        let popover = try await searchRevisions("Right revision", in: window, query: query)
        for _ in 0..<index {
            popover.sendEvent(UIVerification.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, flags: [], window: popover))
            try await Task.sleep(for: .milliseconds(30))
        }
        popover.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: popover))
        let selectionDeadline = ContinuousClock.now + .seconds(3)
        while model.right?.id != candidates[index].id && ContinuousClock.now < selectionDeadline { try await Task.sleep(for: .milliseconds(30)) }
        try UIVerification.require(model.right?.id == candidates[index].id,
            "Return did not choose the highlighted revision. Selected \(model.right?.title ?? "none").")
    }

    private static func verifyChangeFilter(_ review: GitComparisonWindow, workspace: BrowserWorkspaceController,
                                           window: NSWindow, settings: BrowserSettings, owned: URL) async throws {
        func focus() async throws {
            let prior = review.model.changeFilterID
            try await UIVerification.waitUntil("Review owns its native filter menu") {
                window.isKeyWindow && ToolWindowMenuOwnership.owns(review)
                    && UIVerification.menuItem("View", "Filter Changed Files…")?.target === review
            }
            try UIVerification.require(NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key("f", code: 3,
                flags: .command, window: window)) == true, "The native Git filter shortcut was not available")
            try await UIVerification.waitUntil("Git filter command routed to this review") {
                review.model.changeFilterID != prior && review.model.changeFilterID != nil
            }
            try await UIVerification.waitUntil("Git change-filter field editor") {
                guard let content = window.contentView,
                      let field = views(in: content).compactMap({ $0 as? NSSearchField }).first(where: {
                          $0.identifier?.rawValue == "git-change-filter"
                      }), let editor = field.currentEditor() else { return false }
                return window.firstResponder === editor
            }
        }
        try await focus()
        for letter in "outside" { window.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: window)) }
        try await UIVerification.waitUntil("Git change-filter exact result") {
            review.model.changeQuery == "outside" && !review.model.filteringChanges && review.model.visibleChanges.count == 1
                && review.model.selected?.right?.path.name == "Outside.txt"
        }
        try UIVerification.require(review.model.summary?.changes.count == 2,
            "Filtering changed the comparison's full summary")
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(window, to: owned.appendingPathComponent("git-filtered-changes.png"))
        }
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        let diff = try await capturedDiff(workspace.textComparisonWindow, left: "", right: "outside scope\n", removed: 0)
        try UIVerification.require(diff.fileIndex == 0 && diff.fileCount == 1 && !diff.canVisitFile(.next),
            "A filtered-out path remained in the file navigation list")
        await diff.closeAndDrain()
        window.makeKeyAndOrderFront(nil)
        try await UIVerification.waitUntil("Git review reclaims keyboard after filtered diff") { window.isKeyWindow }
        try await UIVerification.verifyDiffSearch(in: window, workspace: workspace, query: "outside scope",
            expectedPath: "Outside.txt", files: 1)
        try UIVerification.require(review.model.changeQuery == "outside" && review.model.visibleChanges.count == 1,
            "Searching the one visible Git diff changed the originating filter")
        try await focus()
        window.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: window))
        try await UIVerification.waitUntil("Git filter Escape restores complete list") {
            review.model.changeFilterID == nil && review.model.changeQuery.isEmpty && review.model.visibleChanges.count == 2
        }
        let unfiltered = review.model.visibleChanges
        guard let outside = unfiltered.first(where: { $0.right?.path.name == "Outside.txt" }) else {
            throw UIVerification.Failure(message: "Generated added file missing")
        }
        func selectType(_ kind: GitComparisonModel.ChangeKind?) async throws {
            guard let item = UIVerification.menuItem("View", "Change Type", GitComparisonModel.changeKindLabel(kind)),
                  let action = item.action, review.validateMenuItem(item),
                  NSApp.sendAction(action, to: review, from: item) else {
                throw UIVerification.Failure(message: "Native Change Type choice unavailable")
            }
            try await UIVerification.waitUntil("Change Type limits the displayed rows") {
                review.model.changeKind == kind && !review.model.filteringChanges
                    && review.model.visibleChanges.map(\.id) == unfiltered.filter { kind == nil || $0.kind == kind }.map(\.id)
            }
            try UIVerification.require(review.validateMenuItem(item) && item.state == .on
                && review.model.summary?.changes.count == unfiltered.count, "Change type checkbox or full totals differ")
        }
        try await selectType(.modified)
        review.model.selectedChange = outside.id
        try UIVerification.require(review.model.selected == nil && !review.model.canOpenTextDiff,
            "A file outside the chosen kind retained an Open action")
        try await focus()
        for letter in "outside" { window.sendEvent(UIVerification.key(String(letter), code: 0, flags: [], window: window)) }
        try await UIVerification.waitUntil("Path and type filters intersect") {
            !review.model.filteringChanges && review.model.changeQuery == "outside" && review.model.visibleChanges.isEmpty
                && !review.model.canFindAcrossDiffs
        }
        window.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: window))
        try await UIVerification.waitUntil("Escape keeps the selected change type") {
            review.model.changeFilterID == nil && review.model.changeKind == .modified && !review.model.filteringChanges
                && review.model.visibleChanges.map { $0.right?.path.name } == ["Draft.txt"]
        }
        try await selectType(.added)
        let originalFrame = window.frame
        defer { window.setFrame(originalFrame, display: true) }
        try await withEnlargedLayout(window, settings: settings) {
            try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-change-type-150.png"))
            try await UIVerification.verifyDiffSearch(in: window, workspace: workspace, query: "outside scope",
                expectedPath: "Outside.txt", files: 1)
        }
        window.makeKeyAndOrderFront(nil)
        try await selectType(nil)
    }

    private static func verifyComparedFileNavigation(_ review: GitComparisonWindow, workspace: BrowserWorkspaceController,
                                                     window: NSWindow, settings: BrowserSettings, owned: URL) async throws {
        let originalFrame = window.frame
        defer { window.setFrame(originalFrame, display: true) }
        try await withEnlargedLayout(window, settings: settings) {
            let rows = review.model.visibleChanges
            try UIVerification.require(rows.map { $0.right?.path.name } == ["Outside.txt", "Draft.txt"],
                "The generated two-file comparison has unexpected ordering")
            review.model.selectedChange = rows.first?.id
            guard let open = UIVerification.menuItem("File", "Open Text Diff"), let action = open.action,
                  review.validateMenuItem(open), NSApp.sendAction(action, to: review, from: open) else {
                throw UIVerification.Failure(message: "Could not open a selected file in the native two-file comparison")
            }
            let diff = try await capturedDiff(workspace.textComparisonWindow, left: "", right: "outside scope\n", removed: 0)
            guard let native = diff.window else { throw UIVerification.Failure(message: "The file comparison window was lost") }
            try await UIVerification.waitUntil("Native file comparison commands") {
                native.isKeyWindow && UIVerification.menuItem("View", "Next Compared File")?.target === diff
            }
            guard let previous = UIVerification.menuItem("View", "Previous Compared File"),
                  let next = UIVerification.menuItem("View", "Next Compared File"),
                  let back = previous.action else { throw UIVerification.Failure(message: "The file sequence commands were lost") }
            try UIVerification.require(diff.fileIndex == 0 && diff.fileCount == 2 && !diff.validateUserInterfaceItem(previous)
                && diff.validateUserInterfaceItem(next), "The first file exposed the wrong sequence bounds")
            let following = UIVerification.key("]", code: 30, flags: [.command, .option], window: native)
            try UIVerification.require(NSApp.mainMenu?.performKeyEquivalent(with: following) == true,
                "The next-file keyboard command was unavailable")
            _ = try await capturedDiff(workspace.textComparisonWindow, left: "old draft\n", right: "new draft\n")
            try UIVerification.require(workspace.textComparisonWindow === diff && diff.window === native
                && diff.fileIndex == 1 && diff.labels.source == "Project Scope/Draft.txt" && diff.position?.index == 0
                && diff.validateUserInterfaceItem(previous) && !diff.validateUserInterfaceItem(next),
                "A file change replaced the window or lost its pinned text, position or native menu")
            try await UIVerification.snapshot(native, to: owned.appendingPathComponent("git-diff-compared-files-150.png"))
            try UIVerification.require(NSApp.sendAction(back, to: diff, from: previous), "The prior comparison could not be visited")
            _ = try await capturedDiff(workspace.textComparisonWindow, left: "", right: "outside scope\n", removed: 0)
            try UIVerification.require(diff.fileIndex == 0 && review.model.selectedChange == rows.first?.id,
                "Returning to the first file changed the originating review")
            await diff.closeAndDrain()
            window.makeKeyAndOrderFront(nil)
            try await UIVerification.waitUntil("The Git review reclaims its native filter shortcut") { window.isKeyWindow }
            try await UIVerification.verifyDiffSearch(in: window, workspace: workspace, query: "new draft",
                expectedPath: "Project Scope/Draft.txt", files: 2)
            try UIVerification.require(review.model.selectedChange == rows.first?.id,
                "Searching across revision diffs displaced the original selection")
        }
    }

    private static func verifyExactRevision(_ history: GitFileHistoryWindow, window: NSWindow, revision: GitRevisionOption,
                                            owned: URL) async throws {
        let first = history.model.startingCommit, selection = history.model.selection
        let popover = try await searchRevisions("Open or Compare Revision", in: window, query: revision.title)
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(popover, to: owned.appendingPathComponent("git-file-revision-choices.png"))
        }
        try UIVerification.require(FolderCompositionOwnedControls.press("Open Version", in: popover),
            "The revision picker did not open its highlighted version")
        try await UIVerification.waitUntil("Exact branch snapshot from the revision picker") {
            history.snapshotForVerification?.window.window?.isKeyWindow == true
        }
        guard let snapshot = history.snapshotForVerification, case .object(let commit) = revision.revision else {
            throw UIVerification.Failure(message: "The exact revision could not be inspected")
        }
        try UIVerification.require(snapshot.window.surface.textView.string == "old draft\n"
            && snapshot.window.window?.title.contains(commit.short) == true && !snapshot.window.surface.textView.isEditable
            && history.model.startingCommit == first && history.model.selection == selection,
            "Opening the branch version changed the timeline or showed different text")
        await snapshot.closeAndDrain()
        window.makeKeyAndOrderFront(nil)
        try await UIVerification.waitUntil("History focus after exact branch snapshot") { window.isKeyWindow }
    }

    private static func verifyFolderHistory(_ workspace: BrowserWorkspaceController, browser: BrowserViewController,
                                            parent: NSWindow, report: GitTreeComparison, owned: URL) async throws {
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try send(.gitFolderHistory, from: BrowserMenus.menu(.file, target: browser), to: browser)
        guard let review = workspace.gitComparisonWindow, let window = review.window else {
            throw UIVerification.Failure(message: "Git Folder History did not open")
        }
        defer { review.window?.close() }
        let model = review.model
        func command(_ title: String) throws {
            guard let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: title),
                  review.validateMenuItem(item), let action = item.action, NSApp.sendAction(action, to: review, from: item) else {
                throw UIVerification.Failure(message: "Git Folder History command unavailable: \(title)")
            }
        }
        try await UIVerification.waitUntil("Folder history follows local HEAD") { window.isKeyWindow && !model.busy && model.folderHistory != nil }
        try UIVerification.require(model.folderHistory?.start == report.right
            && model.folderHistory?.commits.map(\.id) == [report.right, report.left], "Folder history selected the wrong checkout")
        try command("Review Selected Commit")
        try await UIVerification.waitUntil("Scoped folder commit details") { !model.busy && model.commitChanges != nil }
        try UIVerification.require(model.commitChanges?.parent == report.left
            && model.commitChanges?.summary.changes.compactMap(\.right?.path.display) == ["Project Scope/Draft.txt"],
            "Folder history included changes outside the selected folder")
        try command("Back to Commits")
        try UIVerification.require(model.selectedRangeCommit == report.right, "Returning to the folder history lost its selection")
        guard let branch = model.choices.first(where: { $0.title == "long-history" }), case .object(let expected) = branch.revision else {
            throw UIVerification.Failure(message: "The generated long folder history branch was missing")
        }
        let picker = try await searchRevisions("History starting at", in: window, query: "long-history")
        picker.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: picker))
        try await UIVerification.waitUntil("Native Folder History revision choice") {
            window.isKeyWindow && !model.busy && model.folderHistory?.start == expected
        }
        guard let first = model.folderHistory, let older = first.older, first.commits.count == 96 else {
            throw UIVerification.Failure(message: "Folder history lost its first bounded page")
        }
        try await withEnlargedLayout(window, settings: browser.settings) {
            try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-folder-history-enlarged.png"))
            guard let content = window.contentView, let table = tables(in: content).first,
                  let scroll = table.enclosingScrollView else {
                throw UIVerification.Failure(message: "The enlarged Folder History table is missing")
            }
            let visible = table.tableColumns.enumerated().filter { !$0.element.isHidden }
            try UIVerification.require(content.bounds.insetBy(dx: -1, dy: -1).contains(scroll.convert(scroll.bounds, to: content))
                && visible.map(\.element.title) == ["Commit", "Date"] && visible.allSatisfy {
                    table.rect(ofColumn: $0.offset).maxX <= scroll.contentView.bounds.width + 1
                },
                "Folder History columns or table escaped the enlarged viewport")
        }
        try await filterCommits(review, window: window, by: report.left.short, expected: [])
        try UIVerification.require(!model.canInspectCommit && model.canReadOlderCommits,
            "A filtered-out commit remained actionable or blocked paging")
        try command("Older Commits")
        try await UIVerification.waitUntil("Older folder commits") { !model.busy && model.folderHistoryPage == 2 }
        try UIVerification.require(model.folderHistory?.start == older
            && model.folderHistory?.commits.map(\.id) == [older, report.right, report.left]
            && model.left?.revision == .object(expected) && !model.canReadOlderCommits
            && model.commitQuery == report.left.short && model.selectedRangeCommit == report.left,
            "Folder History skipped a commit or changed its selected branch while paging")
        try await dismissCommitFilter(review, window: window)
        try command("Newer Commits")
        try await UIVerification.waitUntil("Newer folder commits") { !model.busy && model.folderHistoryPage == 1 }
        try UIVerification.require(model.folderHistory?.commits.map(\.id) == first.commits.map(\.id),
            "Returning to the first folder history page changed the pinned list")
    }

    private static func verifyComparisonHistory(_ review: GitComparisonWindow, workspace: BrowserWorkspaceController,
                                                window: NSWindow, side: GitComparisonModel.Side, commit: GitObjectID,
                                                path: String, entries: [GitObjectID], missingLeft: Bool = false,
                                                owned: URL? = nil) async throws {
        func item(_ title: String) -> NSMenuItem? { NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: title) }
        try await UIVerification.waitUntil("Pinned file history from the comparison") {
            item(side.historyTitle).map(review.validateMenuItem) == true
        }
        if missingLeft {
            try UIVerification.require(item(GitComparisonModel.Side.left.historyTitle).map(review.validateMenuItem) == false,
                "An absent Git side offered file history")
        }
        guard let command = item(side.historyTitle), let action = command.action,
              NSApp.sendAction(action, to: review, from: command), let history = workspace.gitFileHistoryWindow,
              let historyWindow = history.window else {
            throw UIVerification.Failure(message: "The compared file did not open its native history window")
        }
        defer { history.window?.close() }
        try await UIVerification.waitUntil("Pinned native file history") { historyWindow.isKeyWindow && !history.model.busy }
        func requireAnchor() throws {
            try UIVerification.require(history.model.startingRevision?.revision == .object(commit)
                && history.model.startingRevision?.isPinned == true && history.model.startingCommit == commit
                && history.model.path == GitSnapshotPath(path) && history.model.history?.entries.map(\.id) == entries,
                "File history replaced the chosen revision or path with the current checkout")
        }
        try requireAnchor()
        if let owned {
            try await UIVerification.snapshot(historyWindow, to: owned.appendingPathComponent("git-file-history-from-comparison.png"))
            guard let reload = item("Reload History"), history.validateMenuItem(reload), let command = reload.action,
                  NSApp.sendAction(command, to: history, from: reload) else {
                throw UIVerification.Failure(message: "Pinned file history has no native Reload History command")
            }
            try await UIVerification.waitUntil("Reloaded pinned history") { !history.model.busy }
            try requireAnchor()
        }
        historyWindow.performClose(nil)
        window.makeKeyAndOrderFront(nil)
        try await UIVerification.waitUntil("Comparison focus after history") { window.isKeyWindow && workspace.gitFileHistoryWindow == nil }
    }

    private static func verifyCommitRange(_ review: GitComparisonWindow, workspace: BrowserWorkspaceController,
                                          window: NSWindow, report: GitTreeComparison, settings: BrowserSettings, owned: URL) async throws {
        func command(_ menu: String, _ title: String) -> NSMenuItem? {
            NSApp.mainMenu?.item(withTitle: menu)?.submenu?.item(withTitle: title)
        }
        func invoke(_ menu: String, _ title: String) async throws {
            try await UIVerification.waitUntil("Git Commit Range command \(title)") {
                command(menu, title)?.target === review && command(menu, title).map(review.validateMenuItem) == true
            }
            guard let item = command(menu, title), let action = item.action,
                  NSApp.sendAction(action, to: review, from: item) else {
                throw UIVerification.Failure(message: "Native Git Commit Range action unavailable")
            }
        }
        try await invoke("View", "Show Commits")
        try await UIVerification.waitUntil("Exact left and right commits") { !review.model.busy && review.model.commitRange != nil }
        guard let range = review.model.commitRange, let right = range.right.commits.first else {
            throw UIVerification.Failure(message: "Git history did not return an exclusive right-side commit")
        }
        try UIVerification.require(range.left.revision == report.selectedLeft && range.right.revision == report.right
            && range.left.commits.map(\.id) == [report.selectedLeft] && range.right.commits.map(\.id) == [report.right]
            && right.parents == [report.left], "Exclusive commits used the merge base as the left revision")
        func visibleCommits() -> NSTableView? {
            window.contentView.flatMap { tables(in: $0).first {
                !$0.isHiddenOrHasHiddenAncestor && $0.numberOfRows == range.left.commits.count + range.right.commits.count
                    && $0.tableColumns.contains { $0.title == "Commit" }
            } }
        }
        try await UIVerification.waitUntil("Both exclusive commits are present in the native table") { visibleCommits() != nil }
        try await withEnlargedLayout(window, settings: settings) {
            try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-commit-range-enlarged.png"))
            guard let body = window.contentView, let scroll = visibleCommits()?.enclosingScrollView else {
                throw UIVerification.Failure(message: "The enlarged Commits view lost its table")
            }
            let rectangle = scroll.convert(scroll.bounds, to: body)
            try UIVerification.require(rectangle.height >= 110 && body.bounds.insetBy(dx: -1, dy: -1).contains(rectangle),
                "The Commits view did not fit its enlarged window")
        }
        guard let activeTable = visibleCommits() else {
            throw UIVerification.Failure(message: "The Git Commits table disappeared after resizing")
        }
        try await UIVerification.clickRow(range.left.commits.count, in: activeTable)
        try await UIVerification.waitUntil("Exact Git commit selected") { review.model.selectedRangeCommit == right.id }
        try await filterCommits(review, window: window, by: right.commit.subject, expected: [right.id])
        try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-commit-range-filter.png"))
        window.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: window))
        try await UIVerification.waitUntil("Exact parent-specific file changes") { !review.model.busy && review.model.commitChanges != nil }
        try UIVerification.require(review.model.commitChanges?.parent == report.left
            && review.model.commitChanges?.summary.changes.first?.right?.path.name == "Branch.txt"
            && review.model.commitChanges?.summary.lines.added == 1, "Selected commit read the wrong parent or file")
        try await invoke("File", "Open Text Diff")
        let diff = try await capturedDiff(workspace.textComparisonWindow, left: "", right: "one branch addition\n", added: 1, removed: 0)
        try UIVerification.require(diff.labels.left.hasPrefix("Parent · " + report.left.short)
            && diff.labels.right.hasPrefix("Commit · " + right.id.short), "Commit diff dropped the reviewed identities")
        await diff.closeAndDrain()
        window.makeKeyAndOrderFront(nil)
        try await verifyComparisonHistory(review, workspace: workspace, window: window, side: .right,
            commit: right.id, path: "Project Scope/Nested Shared/Branch.txt", entries: [right.id], missingLeft: true)
        try await invoke("File", "Back to Commits")
        try UIVerification.require(review.model.commitChanges == nil && review.model.selectedRangeCommit == right.id
            && review.model.commitQuery == right.commit.subject && review.model.visibleCommitRows.map(\.id) == [right.id],
            "Returning to Commits moved selection away from the inspected commit")
        try await dismissCommitFilter(review, window: window)
    }

    private static func focusedCommitFilter(_ review: GitComparisonWindow, window: NSWindow) async throws -> NSTextField {
        // Update native item validation after a mode transition, as the View menu does when it opens.
        NSApp.mainMenu?.item(withTitle: "View")?.submenu?.update()
        try UIVerification.require(UIVerification.menuItem("View", "Filter Commits…")?.target === review
            && NSApp.mainMenu?.performKeyEquivalent(with: UIVerification.key("f", code: 3, flags: .command, window: window)) == true,
            "The native commit filter command was unavailable")
        func field() -> NSTextField? {
            guard let body = window.contentView else { return nil }
            return views(in: body).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "git-commit-filter" }
        }
        try await UIVerification.waitUntil("Commit filter receives native focus") { field()?.currentEditor() != nil }
        guard let field = field() else { throw UIVerification.Failure(message: "The focused commit filter was lost") }
        return field
    }

    private static func filterCommits(_ review: GitComparisonWindow, window: NSWindow, by query: String,
                                      expected: [GitObjectID]) async throws {
        let field = try await focusedCommitFilter(review, window: window)
        field.currentEditor()?.selectAll(nil)
        for character in query { window.sendEvent(UIVerification.key(String(character), code: 0, flags: [], window: window)) }
        try await UIVerification.waitUntil("Commit filter selects their exact identities") {
            review.model.commitQuery == query && review.model.visibleCommitRows.map(\.id) == expected
                && review.model.selectedRangeCommit == expected.first
        }
    }

    private static func dismissCommitFilter(_ review: GitComparisonWindow, window: NSWindow) async throws {
        _ = try await focusedCommitFilter(review, window: window)
        window.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: window))
        try await UIVerification.waitUntil("Commit filter Escape restores the loaded list") {
            review.model.commitFilterID == nil && review.model.commitQuery.isEmpty
                && review.model.visibleCommitRows.map(\.id) == review.model.commitRows.map(\.id)
        }
    }

    private static func verifyHistoryPages(_ history: GitFileHistoryWindow, window: NSWindow,
                                           settings: BrowserSettings, owned: URL) async throws {
        guard let branch = history.model.revisions.first(where: { $0.title == "long-history" }) else {
            throw UIVerification.Failure(message: "The generated branch for the long timeline is unavailable")
        }
        history.model.choose(branch, path: history.model.path)
        try await UIVerification.waitUntil("Long branch history") { !history.model.busy && window.isKeyWindow }
        guard let recent = history.model.history, let anchor = recent.start,
              let prior = recent.older, recent.entries.count == 96 else {
            throw UIVerification.Failure(message: "Git File History did not return its bounded first page")
        }
        func command(_ title: String) throws {
            guard let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: title),
                  let action = item.action, history.validateMenuItem(item), NSApp.sendAction(action, to: history, from: item) else {
                throw UIVerification.Failure(message: "Native history page action unavailable: \(title)")
            }
        }
        try command("Older Changes")
        try await UIVerification.waitUntil("Older file history page through rename") { !history.model.busy && history.model.pageNumber == 2 }
        try UIVerification.require(history.model.history?.start == prior && prior.path.name == "Prior.txt"
            && history.model.selected?.after?.path == prior.path && history.model.startingCommit == anchor.commit
            && history.model.startingRevision?.id == branch.id && history.model.canGoNewer && !history.model.canGoOlder,
            "Older changes used the wrong path or moved the branch comparison anchor")
        try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-file-history-older.png"))
        try command("Open Version")
        try await UIVerification.waitUntil("Open historical file under its earlier name") { history.snapshotForVerification?.window.window?.isKeyWindow == true }
        guard let snapshot = history.snapshotForVerification else { throw UIVerification.Failure(message: "Previous file text was unavailable") }
        try UIVerification.require(snapshot.window.surface.textView.string == "new draft\n" && !snapshot.window.surface.textView.isEditable,
            "Older page opened the wrong committed bytes")
        guard let original = history.model.history?.entries.first(where: { $0.commit.subject == "Second generated revision" }) else {
            throw UIVerification.Failure(message: "The renamed historical fixture did not retain its source commit")
        }
        try await verifyLineOrigin(snapshot, originalCommit: original.commit.object, owned: owned)
        await snapshot.closeAndDrain()
        window.makeKeyAndOrderFront(nil)
        try await UIVerification.waitUntil("File history restored after old version") { window.isKeyWindow }
        try await verifySelectedVersions(history, window: window, extra: original, owned: owned)
        try await verifyHistoryFilter(history, window: window, renamed: prior, original: original.id, owned: owned)
        guard let base = history.model.selected, base.commit.subject == "First generated revision",
              let newest = recent.entries.first else { throw UIVerification.Failure(message: "The two history pages lost their comparison endpoints") }
        try command("Set Comparison Base")
        try UIVerification.require(history.model.comparisonBase?.id == base.id && !history.model.canCompareWithBase,
            "A history difference could compare the base with itself")
        try command("Newer Changes")
        try await UIVerification.waitUntil("Newer file history page restored") { !history.model.busy && history.model.pageNumber == 1 }
        try UIVerification.require(history.model.history?.start == anchor && history.model.history?.entries.map(\.id) == recent.entries.map(\.id)
            && history.model.comparisonBase?.id == base.id && history.model.selection == newest.id,
            "Returning from older history changed the selected revision or skipped a commit")
        try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-file-history-comparison-base.png"))
        let frame = window.frame
        try await withEnlargedLayout(window, settings: settings) {
            try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-file-history-enlarged.png"))
            guard let content = window.contentView, let table = tables(in: content).first,
                  let scroll = table.enclosingScrollView else {
                throw UIVerification.Failure(message: "The enlarged history lost its native table")
            }
            let bounds = scroll.convert(scroll.bounds, to: content)
            try UIVerification.require(bounds.height >= 110 && content.bounds.insetBy(dx: -1, dy: -1).contains(bounds)
                && history.model.selection == newest.id && history.model.canCompareWithBase,
                "Enlarging Git history displaced the table or the pinned comparison")
        }
        window.setFrame(frame, display: true)
        try await UIVerification.waitUntil("History restores Compare with Base after resizing") {
            guard let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Compare with Base") else { return false }
            return window.isKeyWindow && item.target === history && history.validateMenuItem(item)
        }
        try command("Compare with Base")
        let review = try await capturedDiff(history.diffForVerification, left: "old draft\n", right: "long timeline change 94\n")
        try UIVerification.require(review.labels.left.hasPrefix("Base \(base.id.short)") && review.labels.right.hasPrefix(newest.id.short),
            "The cross-page diff lost the pinned base or newer commit")
        await review.closeAndDrain()
        window.makeKeyAndOrderFront(nil)
        try await UIVerification.waitUntil("History focused after comparing with the base") { window.isKeyWindow }
        try command("Clear Comparison Base")
        try UIVerification.require(history.model.comparisonBase == nil && history.model.selection == newest.id
            && history.model.history?.start == anchor, "Clearing the base reset the user's current page or selection")
        guard let entered = GitRevisionOption.entered(prior.commit.short) else {
            throw UIVerification.Failure(message: "The historical hash could not be entered")
        }
        history.model.choose(entered, path: prior.path)
        try await UIVerification.waitUntil("Entered revision is pinned") { !history.model.busy && history.model.startingCommit == prior.commit }
        try UIVerification.require(history.model.startingRevision?.revision == .object(prior.commit), "A typed abbreviation did not pin its full commit")
        try command("Reload History")
        try await UIVerification.waitUntil("Reloaded pinned history") { !history.model.busy }
        try UIVerification.require(history.model.history?.start == prior && history.model.startingRevision?.revision == .object(prior.commit),
            "Reload replaced the entered commit with another revision")
    }

    private static func verifySelectedVersions(_ history: GitFileHistoryWindow, window: NSWindow,
                                               extra: GitFileHistory.Entry, owned: URL) async throws {
        guard let entries = history.model.history?.entries, let later = entries.first,
              let earlier = entries.first(where: { $0.commit.subject == "First generated revision" }),
              let earlierRow = entries.firstIndex(where: { $0.id == earlier.id }),
              let extraRow = entries.firstIndex(where: { $0.id == extra.id }),
              let body = window.contentView, let table = tables(in: body).first,
              let menu = NSApp.mainMenu?.item(withTitle: "File")?.submenu,
              let compare = menu.item(withTitle: "Compare Change"),
              let open = menu.item(withTitle: "Open Version") else {
            throw UIVerification.Failure(message: "The native history pair was unavailable")
        }
        // Choose in reverse chronological order, then prove the display uses
        // the first-parent page ordering and each row's own committed path.
        try await UIVerification.clickRow(0, in: table)
        try await UIVerification.clickRow(earlierRow, in: table, modifiers: .command)
        try UIVerification.require(history.model.selectedCommits == [earlier.id, later.id]
            && !history.validateMenuItem(open) && history.validateMenuItem(compare) && compare.title == "Compare Versions",
            "Two selected history rows did not offer the native comparison")
        let shortcut = UIVerification.key("\r", code: 36, flags: .command, window: window)
        try UIVerification.require(menu.performKeyEquivalent(with: shortcut), "Command-Return did not dispatch Compare Versions")
        let difference = try await capturedDiff(history.diffForVerification, left: "old draft\n", right: "new draft\n")
        try UIVerification.require(difference.labels.left == "\(earlier.id.short) · Project Scope/Draft.txt"
            && difference.labels.right == "\(later.id.short) · Project Scope/Prior.txt"
            && history.model.selectedCommits == [earlier.id, later.id],
            "Comparing across a rename lost an endpoint path or the selected commits")
        if let native = difference.window {
            try await UIVerification.snapshot(native, to: owned.appendingPathComponent("git-history-selected-versions.png"))
        }
        await difference.closeAndDrain()
        window.makeKeyAndOrderFront(nil)
        try await UIVerification.waitUntil("History focused after comparing two versions") { window.isKeyWindow }
        try await UIVerification.clickRow(extraRow, in: table, modifiers: .command)
        try UIVerification.require(history.model.selectedCommits.count == 3 && !history.validateMenuItem(compare),
            "The history attempted a text comparison for three selected versions")
    }

    private static func verifyHistoryFilter(_ history: GitFileHistoryWindow, window: NSWindow, renamed: GitFileHistory.Page,
                                            original: GitObjectID, owned: URL) async throws {
        guard let body = window.contentView,
              let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Filter This History Page"),
              let action = item.action, history.validateMenuItem(item), NSApp.sendAction(action, to: history, from: item) else {
            throw UIVerification.Failure(message: "The native History filter command was unavailable")
        }
        func input() -> NSTextField? {
            views(in: body).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "git-history-filter" }
        }
        try await UIVerification.waitUntil("History filter takes focus") { input()?.currentEditor() != nil }
        guard let field = input() else { throw UIVerification.Failure(message: "The focused history filter field was missing") }
        let earlierCount = history.model.history?.entries.count
        func type(_ query: String, expecting ids: [GitObjectID]) async throws {
            field.currentEditor()?.selectAll(nil)
            for character in query { window.sendEvent(UIVerification.key(String(character), code: 0, flags: [], window: window)) }
            try await UIVerification.waitUntil("History filter showing \(query)") {
                history.model.query == query && history.model.visibleEntries.map(\.id) == ids
            }
        }
        try await type("Prior.txt", expecting: [renamed.commit])
        try UIVerification.require(history.model.selectedCommits == [renamed.commit] && history.model.canOpen,
            "The history filter left a hidden commit selected")
        try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-file-history-filter.png"))
        try await type("Draft.txt", expecting: history.model.history?.entries.map(\.id) ?? [])
        try await type(original.short, expecting: [original])
        try await type("First generated revision", expecting: history.model.history?.entries.last.map { [$0.id] } ?? [])
        window.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: window))
        try await UIVerification.waitUntil("Escape restores the same history page") {
            input() == nil && history.model.query.isEmpty && history.model.visibleEntries.count == earlierCount
        }
        try UIVerification.require(history.model.history?.start == renamed && history.model.pageNumber == 2,
            "Filtering reloaded or navigated the history page")
    }

    private static func verifyLineOrigin(_ snapshot: NativeTextSnapshotController, originalCommit: GitObjectID, owned: URL) async throws {
        let owner = snapshot.window, surface = owner.surface
        guard let window = owner.window, let review = owner.gitLineReview,
              let command = UIVerification.menuItem("File", "Git", "Show Commit for Line…"),
              let action = command.action else { throw UIVerification.Failure(message: "Git line lookup is missing from the revision editor") }
        try await UIVerification.waitUntil("Revision line index prepared") { surface.lineIndex != nil }
        try UIVerification.require(surface.goToLine(2, generation: surface.generation) && !owner.validateUserInterfaceItem(command),
            "The virtual last editor line should not be passed to Git")
        try UIVerification.require(surface.goToLine(1, generation: surface.generation)
            && owner.validateUserInterfaceItem(command) && NSApp.sendAction(action, to: owner, from: command),
            "The native Git line command was not enabled for a committed line")
        try await UIVerification.waitUntil("Native Git line-origin result") { window.attachedSheet != nil && review.alertForVerification != nil }
        guard let alert = review.alertForVerification, alert.window === window.attachedSheet,
              let open = alert.buttons.first(where: { $0.title == "Open Original Line" }) else {
            throw UIVerification.Failure(message: "The renamed line did not offer its original file")
        }
        try UIVerification.require(alert.messageText == "Commit for Line 1"
            && alert.informativeText.contains(originalCommit.short)
            && alert.informativeText.contains("Second generated revision")
            && alert.informativeText.contains("Project Scope/Draft.txt · Line 1"),
            "Git line provenance did not identify the original commit and filename")
        let image = owned.appendingPathComponent("git-line-origin.png")
        if CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(alert.window, to: image)
        } else {
            try await UIVerification.snapshot(alert.window, to: image)
        }
        open.performClick(nil)
        try await UIVerification.waitUntil("Original Git line opens in its exact committed file") {
            guard let original = review.originalForVerification else { return false }
            return original.window.window?.isKeyWindow == true && original.window.surface.lineIndex != nil
        }
        guard let original = review.originalForVerification else { throw UIVerification.Failure(message: "Missing original snapshot") }
        let body = original.window.surface
        try UIVerification.require(original.window.window?.title.contains("Draft.txt · " + originalCommit.short) == true
            && body.textView.string == "new draft\n" && !body.textView.isEditable
            && body.lineIndex?.location(at: body.textView.selectedRange().location)?.line == 1
            && surface.textView.string == "new draft\n" && surface.textView.selectedRange().location == 0,
            "Opening the original line changed the first snapshot or displayed a different version")
        await snapshot.closeAndDrain()
        try UIVerification.require(original.closed && original.window.surface.textView.string.isEmpty,
            "Closing the originating snapshot did not drain its original version")
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        UIVerification.nativeTables(in: view)
    }

    private static func verifyPairedFolderLayout(_ window: NSWindow, settings: BrowserSettings, owned: URL) async throws {
        let frame = window.frame
        defer { window.setFrame(frame, display: true) }
        func check(stacked: Bool) throws {
            guard let content = window.contentView else { throw UIVerification.Failure(message: "Missing folder viewport") }
            let rects = tables(in: content).compactMap { $0.enclosingScrollView }.map { $0.convert($0.bounds, to: content) }
            try UIVerification.require(rects.count == 2, "There are not two native Git folder tables")
            let first = rects[0], second = rects[1]
            let aligned = stacked ? abs(first.minX - second.minX) < 3 : abs(first.minY - second.minY) < 3
            try UIVerification.require(aligned && first.intersection(second).isEmpty && rects.allSatisfy {
                $0.width >= 245 && $0.height >= 100 && content.bounds.insetBy(dx: -1, dy: -1).contains($0)
            }, "Git folder tables did not fit their \(stacked ? "stacked" : "paired") viewport: \(rects)")
        }
        try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-paired-folders.png"))
        try check(stacked: false)
        try await withEnlargedLayout(window, settings: settings) {
            try await UIVerification.snapshot(window, to: owned.appendingPathComponent("git-paired-folders-enlarged.png"))
            try check(stacked: true)
        }
    }

    private static func verifyBrowserFileRevisions(_ workspace: BrowserWorkspaceController, browser: BrowserViewController,
                                                   parent: NSWindow, file: URL) async throws {
        func chooseLeft() async throws -> NSWindow {
            try send(.compareGitFileRevisions, from: BrowserMenus.fileContextMenu(target: browser), to: browser)
            try await UIVerification.waitUntil("Browser owns the two-revision sheet") { parent.attachedSheet != nil }
            guard let sheet = parent.attachedSheet, sheet.title == "Compare Git Revisions" else {
                throw UIVerification.Failure(message: "The browser did not open the shared two-revision picker")
            }
            _ = try await typeRevisionSearch("earlier", limitedTo: sheet)
            sheet.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: sheet))
            try await UIVerification.waitUntil("Browser revision sheet focuses its second step") {
                (sheet.firstResponder as? NSTextView)?.string.isEmpty == true
            }
            return sheet
        }
        let cancel = try await chooseLeft()
        cancel.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: cancel))
        try await UIVerification.waitUntil("Cancellation returns to the original browser selection") {
            parent.isKeyWindow && parent.attachedSheet == nil && browser.canCompareSelectedGitFile
        }
        try UIVerification.require(workspace.textComparisonWindow == nil && browser.orderedSelectedURLs == [file],
            "Cancel changed the browser selection or opened a comparison")
        let sheet = try await chooseLeft()
        _ = try await typeRevisionSearch("HEAD", limitedTo: sheet)
        sheet.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: sheet))
        do {
            try await UIVerification.waitUntil("Pinned browser text comparison after the second revision") {
                workspace.textComparisonWindow != nil
            }
        } catch {
            throw UIVerification.Failure(message: "Direct browser comparison did not arrive: \(browser.status.stringValue)")
        }
        let diff = try await capturedDiff(workspace.textComparisonWindow, left: "old draft\n", right: "new draft\n")
        try UIVerification.require(diff.labels.left.hasPrefix("earlier") && diff.labels.right.hasPrefix("HEAD")
            && workspace.gitFileHistoryWindow == nil, "Direct browser comparison opened unrelated history or lost its refs")
        await diff.closeAndDrain()
        parent.makeKeyAndOrderFront(nil)
        try await UIVerification.waitUntil("Browser focus after the pinned text pair") { parent.isKeyWindow }
        try UIVerification.require(browser.orderedSelectedURLs == [file], "The pinned text pair changed browser selection")
    }

    private static func verifyEditorGit(_ browser: BrowserViewController, window: NSWindow, draft: URL, untracked: URL,
                                        owned: URL) async throws {
        let priorEngine = browser.recoverableFileOperations
        let preferences = browser.settings.editorPreferences
        if priorEngine == nil {
            browser.recoverableFileOperations = RecoverableFileOperations(
                journalDirectory: owned.appendingPathComponent("Git Editor History"), activity: ApplicationFileActivity.beginOperation)
        }
        var editorPreferences = preferences
        editorPreferences.opensFileSidebar = false
        browser.settings.updateEditorPreferences(editorPreferences)
        defer {
            browser.recoverableFileOperations = priorEngine
            browser.settings.updateEditorPreferences(preferences)
        }
        window.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        browser.setFileSelection([draft])
        browser.fileSelectionDidChange()
        browser.editTextInTraverse(nil)
        let editors = ApplicationLocalTextEditors.shared
        try await UIVerification.waitUntil("Local Git editor opened") {
            guard let editor = editors.documentForVerification(at: draft) else { return false }
            return editor.window.window?.isKeyWindow == true && !editor.hasPendingFileWork
        }
        guard let editor = editors.documentForVerification(at: draft), let editorWindow = editor.window.window,
              let files = editor.window.fileSidebar?.files else { throw UIVerification.Failure(message: "The editor had no sidebar") }
        guard let menu = UIVerification.menuItem("File")?.submenu else {
            throw UIVerification.Failure(message: "The editor File menu did not attach")
        }
        menu.update()
        try UIVerification.require(menu.item(withTitle: "Git")?.isHidden == false
            && menu.item(withTitle: "Save")?.action != nil && menu.item(withTitle: "Close")?.action != nil
            && menu.item(withTitle: "Git File History…") == nil
            && editor.window.discoverableCommands().contains { $0.0.title == "Git File History…" && $0.1 == "File › Git" },
            "The editor File menu did not group context-aware commands and keep Save and Close direct")
        func showHistory() async throws -> GitFileHistoryWindow {
            guard let command = UIVerification.menuItem("File", "Git", "Git File History…"),
                  let action = command.action, editor.window.validateUserInterfaceItem(command),
                  NSApp.sendAction(action, to: editor.window, from: command) else {
                throw UIVerification.Failure(message: "Git history was missing from the editor's own File menu")
            }
            try await UIVerification.waitUntil("Git history from the editor") {
                guard let history = NSApp.keyWindow?.windowController as? GitFileHistoryWindow else { return false }
                return !history.model.busy && history.model.history?.entries.count == 2
            }
            guard let history = NSApp.keyWindow?.windowController as? GitFileHistoryWindow else {
                throw UIVerification.Failure(message: "The editor had no Git timeline")
            }
            return history
        }
        try UIVerification.require(editor.window.fileSidebar?.isShown == false && files.outline.numberOfRows == 0,
            "First-open Git history must be tested before listing the sidebar")
        let first = try await showHistory()
        first.window?.close()
        editorWindow.makeKeyAndOrderFront(nil)
        try await UIVerification.waitUntil("Editor regains focus") { editorWindow.isKeyWindow }
        guard let toggle = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Editor Sidebar"),
              let action = toggle.action, NSApp.sendAction(action, to: editor.window, from: toggle) else {
            throw UIVerification.Failure(message: "The editor sidebar command was unavailable")
        }
        func label(_ url: URL) -> String {
            guard let row = files.row(for: url) else { return "" }
            return files.outline.view(atColumn: 0, row: row, makeIfNecessary: true)?.accessibilityLabel() ?? ""
        }
        do {
            try await UIVerification.waitUntil("Git status marks on the current files") {
                label(draft).contains("Git change staged") && label(untracked).contains("Untracked by Git")
                    && files.folderHeadingForVerification == "Generated Git Project · main"
            }
        } catch {
            try? await UIVerification.snapshot(editorWindow, to: owned.appendingPathComponent("git-editor-sidebar-refused.png"))
            let pane = editor.window.fileSidebar
            let clip = files.outline.visibleRect
            throw UIVerification.Failure(message: "Git sidebar did not settle. Shown \(pane?.isShown == true), width \(pane?.split.sidebarPosition ?? 0), rows \(files.outline.numberOfRows), visible \(clip.width) × \(clip.height), project \(files.currentHistoryFile != nil), refresh \(files.gitStatusForVerification).")
        }
        try UIVerification.require(!label(draft).contains("On-disk bytes differ"), "The on-disk check ran without opt-in")
        editorPreferences.showsWorkingGitChanges = true
        browser.settings.updateEditorPreferences(editorPreferences)
        do {
            try await UIVerification.waitUntil("Verified on-disk Git badge") { label(draft).contains("On-disk bytes differ") }
        } catch {
            try? await UIVerification.snapshot(editorWindow, to: owned.appendingPathComponent("git-editor-working-badge-refused.png"))
            throw UIVerification.Failure(message: "Working Git badge did not settle. Key \(editorWindow.isKeyWindow), enabled \(browser.settings.editorPreferences.showsWorkingGitChanges), staged visible \(label(draft).contains("Git change staged")), \(files.gitStatusForVerification).")
        }
        let body = editor.window.surface.textView
        let original = body.string
        body.breakUndoCoalescing()
        body.insertText("Draft-only change\n", replacementRange: NSRange(location: 0, length: 0))
        body.breakUndoCoalescing()
        let edited = body.string
        defer {
            if editor.isDirty && body.string == edited { body.undoManager?.undo() }
            if !editor.isClosed && !editor.isDirty { editor.requestClose() }
        }
        try await UIVerification.waitUntil("The same row distinguishes both states") {
            editor.isDirty && label(draft).contains("Unsaved edits") && label(draft).contains("Git change staged")
        }
        try await UIVerification.snapshot(editorWindow, to: owned.appendingPathComponent("git-editor-sidebar.png"))
        try await verifyWorkingGitLine(editor, parent: editorWindow, draft: edited)
        let bufferGeneration = editor.window.surface.generation
        let browserDiff = try await chooseBrowserWorkingFile(browser, parent: window, usingEditor: true)
        _ = try await capturedDiff(browserDiff, left: "old draft\n", right: edited, added: 2)
        try UIVerification.require(browserDiff.labels.right.hasPrefix("Editor Buffer") && browserDiff.canEditAtChange(.current)
            && body.string == edited && editor.window.surface.generation == bufferGeneration && body.undoManager?.canUndo == true,
            "The working file comparison lost the open buffer, edit destination or Undo")
        await browserDiff.closeAndDrain()
        guard let workspace = browser.workspace else { throw UIVerification.Failure(message: "Editor review has no browser workspace") }
        try await verifyEditorFolderReview(editor, parent: editorWindow, workspace: workspace)
        try UIVerification.require(body.string == edited && editor.window.surface.generation == bufferGeneration
            && body.undoManager?.canUndo == true, "Folder reviews disturbed the open draft or its Undo")
        for (command, label, baseText, added, removed) in [
            ("Compare Editor with HEAD", "HEAD · ", "new draft\n", 1, 0),
            ("Compare Editor with Git Index", "Git Index", "staged draft\n", 2, 1)
        ] {
            editorWindow.makeKeyAndOrderFront(nil)
            try await UIVerification.waitUntil("Git baseline comparison uses the correct native editor") { editorWindow.isKeyWindow }
            guard let item = UIVerification.menuItem("File", "Git", command),
                  let action = item.action, editor.window.validateUserInterfaceItem(item), NSApp.sendAction(action, to: editor.window, from: item) else {
                throw UIVerification.Failure(message: "Unavailable Git baseline compare command: \(command)")
            }
            try await UIVerification.waitUntil("Git baseline comparison opens without an intermediate sheet") {
                editorWindow.attachedSheet == nil && editor.window.gitRevisionDiffForVerification?.window?.isKeyWindow == true
            }
            let diff = try await capturedDiff(editor.window.gitRevisionDiffForVerification, left: baseText,
                right: edited, added: added, removed: removed)
            try UIVerification.require(diff.labels.left.hasPrefix(label) && diff.labels.right.hasPrefix("Editor Buffer")
                && (label != "Git Index" || diff.planForVerification?.before.format.lineEnding == .crlf)
                && editor.isDirty && body.string == edited && editor.window.surface.generation == bufferGeneration,
                "Direct Git comparison changed the staged representation or live draft")
            await diff.closeAndDrain()
        }
        try await verifyEditorRevisionSheet(editor, parent: editorWindow, text: edited, settings: browser.settings, owned: owned)
        let history = try await showHistory()
        guard let reviewWindow = history.window else { throw UIVerification.Failure(message: "The editor had no Git timeline") }
        func compareUsingMenu(_ action: GitLocalDiff) throws {
            guard let compare = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Compare Local")?.submenu,
                  let command = compare.item(withTitle: action.title), let selector = command.action,
                  history.validateMenuItem(command), NSApp.sendAction(selector, to: history, from: command) else {
                throw UIVerification.Failure(message: "The local version command was unavailable: \(action.title)")
            }
        }
        try compareUsingMenu(.indexToDisk)
        let disk = try await capturedDiff(history.diffForVerification, left: "staged draft\n", right: "new draft\n")
        try UIVerification.require(disk.planForVerification?.before.format.lineEnding == .crlf,
            "The staged newline format was lost during comparison")
        await disk.closeAndDrain()
        reviewWindow.makeKeyAndOrderFront(nil)
        try compareUsingMenu(.diskToDraft)
        let unsaved = try await capturedDiff(history.diffForVerification, left: original, right: edited, removed: 0)
        try UIVerification.require(unsaved.labels.left.hasPrefix("On Disk") && unsaved.labels.right.hasPrefix("Unsaved Buffer"),
            "Comparison labels could be mistaken for a saved edit")
        await unsaved.closeAndDrain()
        reviewWindow.makeKeyAndOrderFront(nil)
        let pinnedHistory = history.model.startingCommit, selectedCommit = history.model.selection
        try await withEnlargedLayout(reviewWindow, settings: browser.settings) {
            let picker = try await searchRevisions("Open or Compare Revision", in: reviewWindow, query: "earlier")
            if CGPreflightScreenCaptureAccess() {
                try await GlassVerification.captureOwnedWindow(picker, to: owned.appendingPathComponent("git-file-revision-draft-150.png"))
            }
            try UIVerification.require(FolderCompositionOwnedControls.press("Unsaved Buffer", in: picker),
                "The native revision picker could not compare a branch with the current draft")
            try await UIVerification.waitUntil("Branch versus draft opens") { !history.model.busy && history.diffForVerification != nil }
            let branchDraft = try await capturedDiff(history.diffForVerification, left: "old draft\n", right: edited, added: 2)
            try UIVerification.require(history.model.startingCommit == pinnedHistory && history.model.selection == selectedCommit
                && branchDraft.labels.right.hasPrefix("Unsaved Buffer"), "A direct branch comparison moved the history selection")
            await branchDraft.closeAndDrain()
        }
        reviewWindow.close()
        editorWindow.makeKeyAndOrderFront(nil)
        try UIVerification.require(body.string == edited && editor.isDirty, "Reading Git changed or retired the local draft")
        let pinnedDraft = try await verifyWorkingEditorComparison(browser, parent: window, file: draft, draft: edited)
        guard let diffWindow = pinnedDraft.window, let change = pinnedDraft.planForVerification?.changes.first,
              let edit = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Edit at Selected Change"),
              let action = edit.action else { throw UIVerification.Failure(message: "Git draft has no native edit destination") }
        try UIVerification.require(pinnedDraft.canEditAtChange(.current) && !pinnedDraft.canEditAtChange(.before)
            && pinnedDraft.validateUserInterfaceItem(edit) && NSApp.sendAction(action, to: pinnedDraft, from: edit),
            "The pinned draft could not reopen its exact live editor at the selected change")
        try await UIVerification.waitUntil("Git change focuses the exact dirty editor and caret") {
            editorWindow.isKeyWindow && editorWindow.firstResponder === body
                && body.selectedRange() == NSRange(location: change.currentRange.location, length: 0) && body.string == edited
        }
        body.undoManager?.undo()
        try await UIVerification.waitUntil("Draft undo restores the original buffer") { body.string == original && !editor.isDirty }
        diffWindow.makeKeyAndOrderFront(nil)
        try UIVerification.require(!pinnedDraft.canEditAtChange(.current), "Changed draft still admitted a stale diff offset")
        editor.requestClose()
        try await UIVerification.waitUntil("Git fixture editor closed") { editor.isClosed && editors.documentCount == 0 }
        pinnedDraft.refresh()
        try await UIVerification.waitUntil("Closed draft refuses a new capture") {
            !pinnedDraft.hasWorkForVerification && pinnedDraft.status.contains("previous snapshot")
        }
        try UIVerification.require(pinnedDraft.currentSurface.textView.string == edited,
            "Closing the draft changed the retained comparison")
        await pinnedDraft.closeAndDrain()
        window.makeKeyAndOrderFront(nil)
    }

    private static func verifyEditorFolderReview(_ editor: LocalTextDocumentController, parent: NSWindow,
                                                 workspace: BrowserWorkspaceController) async throws {
        let modes: [(String, GitComparisonModel.Mode)] = [("Review Staged Changes…", .index), ("Compare Working Folder…", .working)]
        for (title, mode) in modes {
            parent.makeKeyAndOrderFront(nil)
            try await UIVerification.waitUntil("Editor regains focus for its folder review") { parent.isKeyWindow }
            guard let item = UIVerification.menuItem("File", "Git", title), let action = item.action,
                  editor.window.validateUserInterfaceItem(item), NSApp.sendAction(action, to: editor.window, from: item) else {
                throw UIVerification.Failure(message: "The editor's folder review command is unavailable")
            }
            try await UIVerification.waitUntil("Editor opened the ordinary scoped folder review") {
                guard let review = workspace.gitComparisonWindow else { return false }
                return review.window?.isKeyWindow == true && review.model.mode == mode && !review.model.busy
                    && (mode == .index ? review.model.staged != nil : review.model.workingFolder != nil)
            }
            guard let review = workspace.gitComparisonWindow, let reviewWindow = review.window else {
                throw UIVerification.Failure(message: "The shared Git folder review was lost")
            }
            try UIVerification.require(review.model.location.relativeFolder == "Project Scope",
                "The Git review picked a folder outside the current editor context")
            if mode == .index {
                review.model.selectedChange = review.model.visibleChanges.first?.id
                guard let command = UIVerification.menuItem("File", "Open Text Diff"), let action = command.action,
                      review.validateMenuItem(command), NSApp.sendAction(action, to: review, from: command) else {
                    throw UIVerification.Failure(message: "The editor's staged review had no openable text change")
                }
                let diff = try await capturedDiff(workspace.textComparisonWindow, left: "new draft\n", right: "staged draft\n")
                try UIVerification.require(diff.planForVerification?.current.format.lineEnding == .crlf,
                    "Review from the editor did not preserve the staged CRLF text")
                await diff.closeAndDrain()
            }
            reviewWindow.close()
            try await UIVerification.waitUntil("The folder review closes before switching mode") { workspace.gitComparisonWindow == nil }
        }
    }

    private static func verifyWorkingGitLine(_ editor: LocalTextDocumentController, parent: NSWindow, draft: String) async throws {
        let owner = editor.window, surface = owner.surface, text = surface.textView
        guard let lineReview = owner.gitLineReview, let undo = text.undoManager, undo.canUndo else {
            throw UIVerification.Failure(message: "Working editor had no local Git line review")
        }
        let prior = text.selectedRange(), generation = surface.generation, undoName = undo.undoActionName
        func show() throws {
            guard let item = UIVerification.menuItem("File", "Git", "Show Commit for Line…"),
                  let action = item.action, owner.validateUserInterfaceItem(item), NSApp.sendAction(action, to: owner, from: item) else {
                throw UIVerification.Failure(message: "The native working editor Git line command was unavailable")
            }
        }
        try await UIVerification.waitUntil("The local Git editor draft line index is ready") { surface.canGoToLine && parent.isKeyWindow }
        parent.makeFirstResponder(text)
        text.setSelectedRange(.init(location: (draft as NSString).range(of: "Draft-only").location, length: 0))
        try show()
        try await UIVerification.waitUntil("A draft-only line makes no authorship claim") {
            !lineReview.isRunning && owner.navigationStatus == "This line differs from HEAD."
        }
        try UIVerification.require(parent.attachedSheet == nil && text.string == draft, "An unsaved line was attributed to a commit")
        text.setSelectedRange(.init(location: (draft as NSString).range(of: "new draft").location, length: 0))
        try show()
        try await UIVerification.waitUntil("Commit sheet for the shifted working line") { lineReview.alertForVerification != nil }
        guard let alert = lineReview.alertForVerification, let open = alert.buttons.first(where: { $0.title == "Open Original Line" }) else {
            throw UIVerification.Failure(message: "Mapped working text did not offer the original Git line")
        }
        try UIVerification.require(alert.messageText == "Commit for Line 2" && alert.informativeText.contains("Second generated revision")
            && alert.informativeText.contains("Matched line 1 at "), "Git line attribution used the draft's shifted location as the committed line")
        open.performClick(nil)
        try await UIVerification.waitUntil("The original Git line is open read-only") {
            guard let original = lineReview.originalForVerification else { return false }
            let historical = original.window.surface
            return original.window.window?.isKeyWindow == true && historical.canGoToLine && !historical.textView.isEditable
                && historical.textView.string == "new draft\n" && historical.textView.selectedRange().location == 0
        }
        await lineReview.originalForVerification?.closeAndDrain()
        parent.makeKeyAndOrderFront(nil)
        _ = parent.makeFirstResponder(text)
        try UIVerification.require(editor.isDirty && text.string == draft && surface.generation == generation
            && undo.canUndo && undo.undoActionName == undoName, "Opening the original line disturbed the draft or its Undo")
        text.setSelectedRange(prior)
    }

    private static func verifyWorkingEditorComparison(_ browser: BrowserViewController, parent: NSWindow,
                                                       file: URL, draft: String) async throws -> EditorComparisonWindow {
        guard let workspace = browser.workspace else { throw UIVerification.Failure(message: "Draft workspace is unavailable") }
        parent.makeKeyAndOrderFront(nil)
        browser.focusBrowserContent()
        try send(.compareGitWorkingFolder, from: BrowserMenus.menu(.file, target: browser), to: browser)
        guard let review = workspace.gitComparisonWindow, let window = review.window else {
            throw UIVerification.Failure(message: "Working review could not open with a live draft")
        }
        defer { window.close() }
        try await UIVerification.waitUntil("Working folder comparison has a native draft target") {
            !review.model.busy && window.isKeyWindow && review.model.workingFolder != nil
        }
        guard let folder = review.model.workingFolder,
              let row = folder.rows.firstIndex(where: { folder.textSelection(for: $0.path)?.workingFileURL == file }) else {
            throw UIVerification.Failure(message: "The working file did not match the editor’s exact path")
        }
        try await UIVerification.waitUntil("Working folder table is ready to select the draft") {
            UIVerification.nativeTables(in: window.contentView).first?.numberOfRows == folder.rows.count
        }
        guard let table = UIVerification.nativeTables(in: window.contentView).first else {
            throw UIVerification.Failure(message: "Working folder table did not appear")
        }
        try await UIVerification.clickRow(row, in: table)
        try await UIVerification.waitUntil("Working folder matched the live draft") { review.model.selectedMember == folder.rows[row].path }
        guard let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Compare Revision with Open Editor"),
              review.validateMenuItem(item), let action = item.action,
              NSApp.sendAction(action, to: review, from: item) else {
            throw UIVerification.Failure(message: "Open draft comparison was unavailable from the native File menu")
        }
        let diff = try await capturedDiff(workspace.textComparisonWindow, left: "new draft\n", right: draft, removed: 0)
        try UIVerification.require(folder.revision.map { diff.labels.left.contains($0.short) } == true
            && diff.labels.right.hasPrefix("Editor Buffer"),
            "The working-editor comparison lost its pinned commit or mislabeled the draft")
        return diff
    }

    private static func verifyDiffLayout(_ diff: EditorComparisonWindow, settings: BrowserSettings, owned: URL) async throws {
        guard let native = diff.window, let content = native.contentView else {
            throw UIVerification.Failure(message: "Missing diff window or content view")
        }
        let surfaces = [diff.beforeSurface, diff.currentSurface]

        func check(stacked: Bool) throws {
            let rects = surfaces.map { $0.convert($0.bounds, to: content) }
            let left = rects[0], right = rects[1]
            let aligned = stacked ? abs(left.minX - right.minX) < 2
                : left.maxX < right.minX && abs(left.minY - right.minY) < 2
            try UIVerification.require(surfaces.allSatisfy { $0.window === native } && aligned
                && left.intersection(right).isEmpty && rects.allSatisfy {
                    $0.width > 240 && $0.height > 120 && content.bounds.insetBy(dx: -1, dy: -1).contains($0)
                }, "Diff viewport did not fit its \(stacked ? "stacked" : "paired") native surfaces: \(rects)")
        }

        try await UIVerification.snapshot(native, to: owned.appendingPathComponent("local-text-diff.png"))
        try check(stacked: false)
        try await withEnlargedLayout(native, settings: settings) {
            try await UIVerification.snapshot(native, to: owned.appendingPathComponent("local-text-diff-enlarged.png"))
            try check(stacked: true)
        }
    }

    private static func withEnlargedLayout(_ window: NSWindow, settings: BrowserSettings,
                                           check: () async throws -> Void) async throws {
        let originalSize = settings.interfaceSize
        let previousBinding = InterfacePresentation.shared.settings
        InterfacePresentation.shared.bind(settings)
        defer {
            settings.interfaceSize = originalSize
            if let previousBinding { InterfacePresentation.shared.bind(previousBinding) }
        }
        settings.interfaceSize = .init(150)
        try await Task.sleep(for: .milliseconds(450))
        try UIVerification.require(InterfacePresentation.shared.size.percent == 150, "The tool did not use the enlarged preference")
        window.setContentSize(.init(width: max(680, window.contentMinSize.width), height: max(690, window.contentMinSize.height)))
        try await check()
    }

    private static func verifyEditorRevisionSheet(_ editor: LocalTextDocumentController, parent: NSWindow,
                                                  text: String, settings: BrowserSettings, owned: URL) async throws {
        func choose(_ phase: String, title: String = "Open or Compare Git Revision…") async throws -> NSWindow {
            parent.makeKeyAndOrderFront(nil)
            func currentCommand() -> NSMenuItem? {
                UIVerification.menuItem("File", "Git", title)
            }
            try await UIVerification.waitUntil("Editor revision command is ready for \(phase)") {
                guard parent.isKeyWindow, ToolWindowMenuOwnership.owns(editor.window), let command = currentCommand() else { return false }
                return editor.window.validateUserInterfaceItem(command)
            }
            guard let command = currentCommand(), let action = command.action,
                  NSApp.sendAction(action, to: editor.window, from: command) else {
                throw UIVerification.Failure(message: "The editor did not route its native revision command for \(phase)")
            }
            try await UIVerification.waitUntil("The active editor owns the revision sheet") { parent.attachedSheet != nil }
            guard let sheet = parent.attachedSheet else { throw UIVerification.Failure(message: "The editor had no revision sheet") }
            let focused = try await typeRevisionSearch("earlier", limitedTo: sheet)
            try UIVerification.require(focused === sheet, "Native revision input was not in the editor's attached sheet")
            return sheet
        }
        let body = editor.window.surface.textView
        let before = editor.window.surface.generation
        try await withEnlargedLayout(parent, settings: settings) {
            defer {
                if let sheet = parent.attachedSheet, ["Git Revision", "Compare Git Revisions"].contains(sheet.title) {
                    parent.endSheet(sheet, returnCode: .cancel)
                }
            }
            let cancel = try await choose("Cancel")
            cancel.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: cancel))
            try await UIVerification.waitUntil("Escape closes only the revision sheet") { parent.attachedSheet == nil }
            try UIVerification.require(editor.window.gitRevisionEditorForVerification == nil && editor.window.gitRevisionDiffForVerification == nil,
                                       "Cancel created a historical editor or comparison")

            let open = try await choose("Open")
            if CGPreflightScreenCaptureAccess() {
                try? await GlassVerification.captureOwnedWindow(open, to: owned.appendingPathComponent("git-editor-revision-sheet-150.png"))
            }
            try UIVerification.require(FolderCompositionOwnedControls.press("Open Version", in: open), "The revision sheet did not open the selected version")
            try await UIVerification.waitUntil("Exact branch snapshot visible from editor") {
                editor.window.gitRevisionEditorForVerification?.window.window?.isKeyWindow == true
            }
            guard let snapshot = editor.window.gitRevisionEditorForVerification else {
                throw UIVerification.Failure(message: "The historical editor did not open")
            }
            try UIVerification.require(snapshot.window.surface.textView.string == "old draft\n"
                && !snapshot.window.surface.textView.isEditable, "The opened revision was not the exact read-only branch text")
            await snapshot.closeAndDrain()

            let compare = try await choose("Compare")
            compare.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: compare))
            try await UIVerification.waitUntil("Return opens native branch-to-editor comparison") {
                editor.window.gitRevisionDiffForVerification?.window?.isKeyWindow == true
            }
            let diff = try await capturedDiff(editor.window.gitRevisionDiffForVerification,
                left: "old draft\n", right: text, added: 2, removed: 1)
            try UIVerification.require(diff.labels.right.hasPrefix("Editor Buffer") && body.string == text
                && editor.window.surface.generation == before && editor.isDirty && body.undoManager?.canUndo == true,
                "Revision review disturbed the open buffer or its Undo")
            await diff.closeAndDrain()
            parent.makeKeyAndOrderFront(nil)

            @MainActor func chooseLeft() async throws -> NSWindow {
                let pair = try await choose("Left revision", title: "Compare Git Revisions…")
                pair.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: pair))
                try await UIVerification.waitUntil("The same revision sheet focuses the right search") {
                    parent.attachedSheet === pair && (pair.firstResponder as? NSTextView)?.string == ""
                }
                return pair
            }
            let back = try await chooseLeft()
            try UIVerification.require(FolderCompositionOwnedControls.press("Back", in: back), "A left revision could not be revised")
            try await UIVerification.waitUntil("Back focuses the left search again") {
                parent.attachedSheet === back && (back.firstResponder as? NSTextView)?.string == ""
            }
            back.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: back))
            try await UIVerification.waitUntil("Cancel drains both revision choices") { parent.attachedSheet == nil }
            try UIVerification.require(editor.window.gitRevisionDiffForVerification == nil,
                "Cancel opened a comparison before both revisions were chosen")
            let pair = try await chooseLeft()
            _ = try await typeRevisionSearch("main", limitedTo: pair)
            pair.sendEvent(UIVerification.key("\r", code: 36, flags: [], window: pair))
            try await UIVerification.waitUntil("Return opens the pinned two-revision comparison") {
                editor.window.gitRevisionDiffForVerification?.window?.isKeyWindow == true
            }
            let pinned = try await capturedDiff(editor.window.gitRevisionDiffForVerification, left: "old draft\n", right: "new draft\n")
            try UIVerification.require(pinned.labels.left.hasPrefix("earlier") && pinned.labels.right.contains("main")
                && pinned.planForVerification?.current.format.lineEnding == .crlf
                && parent.attachedSheet == nil && editor.window.surface.generation == before
                && body.string == text && body.undoManager?.canUndo == true,
                "Two-revision comparison relabeled or changed either captured version or the open draft")
            if let native = pinned.window {
                try await UIVerification.snapshot(native, to: owned.appendingPathComponent("git-editor-revision-pair-150.png"))
            }
            await pinned.closeAndDrain()
            parent.makeKeyAndOrderFront(nil)
        }
    }

    private static func send(_ command: BrowserCommand, from menu: NSMenu, to browser: BrowserViewController) throws {
        guard let item = BrowserMenus.commandItem(command.selector, in: menu), browser.validateMenuItem(item),
              NSApp.sendAction(command.selector, to: browser, from: item) else {
            throw UIVerification.Failure(message: "The native \(command.title) command is unavailable")
        }
    }

    private static func capturedDiff(_ candidate: EditorComparisonWindow?, left: String, right: String,
                                     added: Int = 1, removed: Int = 1) async throws -> EditorComparisonWindow {
        guard let comparison = candidate else {
            throw UIVerification.Failure(message: "The shared text difference viewer did not open")
        }
        try await UIVerification.waitUntil("Text difference prepared") { !comparison.hasWorkForVerification }
        try UIVerification.require(comparison.beforeSurface.textView.string == left
            && comparison.currentSurface.textView.string == right
            && !comparison.beforeSurface.textView.isEditable && !comparison.currentSurface.textView.isEditable
            && comparison.planForVerification?.changedLineCounts?.added == added
            && comparison.planForVerification?.changedLineCounts?.removed == removed,
            "Read-only diff did not match the exact captured texts or expected line totals (\(comparison.labels.title))")
        return comparison
    }
}
#endif
