import AppKit
import ExplorerCore
import FileOperations
import LocalStorage

#if DEBUG
@MainActor
private final class DestinationFixtureDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingSequenceNumber: Int
    let draggingSourceOperationMask: NSDragOperation
    var draggingDestinationWindow: NSWindow?
    var draggingLocation = NSPoint.zero
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, source: Any? = nil, sequence: Int, allowed: NSDragOperation = .copy) {
        draggingPasteboard = board; draggingSource = source; draggingSequenceNumber = sequence
        draggingSourceOperationMask = allowed
        super.init()
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// Cancellation deliberately does not release holds: an already dispatched
/// filesystem observation may finish after its consumer has been cancelled.
@MainActor
private final class DestinationObservationGate {
    private var next = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    var arrivals: Int { next }
    func hold() async {
        next += 1
        let ordinal = next
        await withCheckedContinuation { waiters[ordinal] = $0 }
    }
    func release(_ ordinal: Int) { waiters.removeValue(forKey: ordinal)?.resume() }
    func releaseAll() {
        let held = Array(waiters.values); waiters.removeAll()
        for waiter in held { waiter.resume() }
    }
}

@MainActor
extension UIVerification {
    /// Native callback admission on generated destinations. No real drag session,
    /// Finder, system clipboard, or file-operation mutation is exercised here.
    static func verifyDestinationDropWorkflows(_ browser: BrowserViewController, fixture: URL,
                                               output: URL) async throws -> [String] {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let build = project.appendingPathComponent(".build", isDirectory: true).path + "/"
        try require(output.path.hasPrefix(build) && output.resolvingSymlinksInPath() == output,
                    "Destination output is not an owned repository build root")
        let root = output.appendingPathComponent("destination-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false,
                                         attributes: [.posixPermissions: 0o700])
        try Data("MacExplorer generated destination fixture v1\n".utf8)
            .write(to: root.appendingPathComponent(".owned-fixture"), options: .withoutOverwriting)
        let sourceFolder = root.appendingPathComponent("Source", isDirectory: true)
        let sidebarTarget = root.appendingPathComponent("Sidebar Target", isDirectory: true)
        let driveTarget = root.appendingPathComponent("Drive Target", isDirectory: true)
        let readOnlyTarget = root.appendingPathComponent("Read Only Target", isDirectory: true)
        for directory in [sourceFolder, sidebarTarget, driveTarget, readOnlyTarget] {
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let source = sourceFolder.appendingPathComponent("generated.txt")
        let payload = Data("generated destination source".utf8)
        try payload.write(to: source, options: .withoutOverwriting)
        let missingTarget = root.appendingPathComponent("Missing Target", isDirectory: true)
        let sidebarNode = SidebarNode("Generated Sidebar Target", location: .directory(sidebarTarget), children: [])
        let missingNode = SidebarNode("Generated Missing Target", location: .directory(missingTarget), children: [])
        let unresolvedNode = SidebarNode("Generated Unresolved Folder", children: [])
        let secondNode = SidebarNode("Generated Second Target", location: .directory(driveTarget), children: [])
        let group = SidebarNode("Generated Destinations", group: true, children: [sidebarNode, secondNode, missingNode, unresolvedNode])

        let coordinator = browser.dragDrop
        let originalRoots = browser.sidebarRoots, originalVolumes = browser.volumes
        let originalHooks = coordinator.hooks, originalVerification = coordinator.permitsVerification
        let originalBackground = browser.permitsBackgroundVerification
        coordinator.permitsVerification = true; browser.permitsBackgroundVerification = true
        var admissions: [BrowserDropRequest] = []
        coordinator.hooks.admit = { admissions.append($0); return true }
        defer {
            coordinator.windowWillClose(); coordinator.hooks = originalHooks
            coordinator.permitsVerification = originalVerification
            browser.permitsBackgroundVerification = originalBackground
            browser.sidebarRoots = originalRoots; browser.volumes = originalVolumes
            browser.outline.reloadData()
            for node in browser.sidebarRoots where node.group { browser.outline.expandItem(node) }
            browser.renderVolumes()
            coordinator.configureDestinationViews(); coordinator.destinationsChanged()
        }
        browser.navigate(to: .directory(sourceFolder)); try await settled(browser)
        browser.sidebarRoots = [group]
        browser.outline.reloadData(); browser.outline.expandItem(group)
        browser.view.layoutSubtreeIfNeeded()
        coordinator.destinationsChanged()
        try require(coordinator.sidebarDestination(for: group) == nil
                    && coordinator.sidebarDestination(for: unresolvedNode) == nil,
                    "Sidebar group or unresolved location became a drop target")
        try require(coordinator.navigationCandidatesForVerification.contains(sidebarTarget),
                    "Visible generated sidebar target was not captured")
        try await waitUntil("Generated source drag preparation") { !coordinator.verificationState.preparing }
        try require(!coordinator.hasPreparedDestinationForVerification(sidebarTarget),
                    "Merely rendering the sidebar probed its destination")
        guard let row = browser.rowsByURL[source] else { throw Failure(message: "Generated source row missing") }
        browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        coordinator.selectionDidChange()
        try require(coordinator.registerSourceForVerification(sequence: 4101), "Internal source was not prepared")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([source as NSURL])
        let promises = NSPasteboard.withUniqueName()
        defer { promises.releaseGlobally() }
        promises.setString("generated promise", forType: NSPasteboard.PasteboardType("com.apple.filepromise"))
        let promiseDrag = DestinationFixtureDrag(board: promises, sequence: 4100)
        try require(coordinator.validateDestinationDrop(promiseDrag, destination: sidebarTarget).isEmpty
                    && !coordinator.verificationState.preparing
                    && !coordinator.hasPreparedDestinationForVerification(sidebarTarget),
                    "Unsupported promise-only source initiated destination observation")
        try require(browser.outline.wantsPeriodicDraggingUpdates(),
                    "Async outline preparation has no stationary native update path")
        let internalDrag = DestinationFixtureDrag(board: board, source: browser.table, sequence: 4101, allowed: [.copy, .move])
        _ = browser.outlineView(browser.outline, validateDrop: internalDrag, proposedItem: sidebarNode,
                                proposedChildIndex: NSOutlineViewDropOnItemIndex)
        try await waitUntil("Hovered sidebar target observation") { coordinator.hasPreparedDestinationForVerification(sidebarTarget) }
        if NSEvent.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            try require(browser.outlineView(browser.outline, validateDrop: internalDrag, proposedItem: sidebarNode,
                                            proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move,
                        "Native outline validation did not negotiate registered internal Move")
            try require(browser.outlineView(browser.outline, acceptDrop: internalDrag, item: sidebarNode,
                                            childIndex: NSOutlineViewDropOnItemIndex),
                        "Native outline acceptance did not admit its authenticated source/destination")
        }
        try require(await coordinator.dropForVerification(from: coordinator, urls: [source], destination: sidebarTarget),
                    "Internal sidebar Move was not admitted")
        try require(admissions.last?.move == true && admissions.last?.destination == sidebarTarget,
                    "Sidebar admission lost the observed destination or internal volume policy")
        try require(await coordinator.dropForVerification(from: coordinator, urls: [source], destination: sidebarTarget,
                                                          moveModifier: .option), "Sidebar Option Copy was refused")
        try require(admissions.last?.move == false, "Sidebar Option requested Move")
        try require(browser.outlineView(browser.outline, validateDrop: internalDrag, proposedItem: group,
                                        proposedChildIndex: NSOutlineViewDropOnItemIndex).isEmpty,
                    "Native outline callback admitted a group")
        try require(browser.outlineView(browser.outline, validateDrop: internalDrag, proposedItem: sidebarNode,
                                        proposedChildIndex: 0).isEmpty, "Outline insertion acquired folder drop authority")
        let oldPreparation = browser.operationPreparationTask
        browser.operationPreparationTask = Task {}
        let busyAccepted = coordinator.acceptDestinationDrop(internalDrag, destination: sidebarTarget)
        browser.operationPreparationTask = oldPreparation
        try require(!busyAccepted, "Busy operation admitted another destination drop")
        coordinator.draggingExited()
        let gate = DestinationObservationGate()
        let fileOperations = browser.fileOperations
        coordinator.hooks.observeTarget = { url in
            await gate.hold()
            return try await fileOperations.observeDirectory(url)
        }
        defer { gate.releaseAll() }
        let completedBefore = coordinator.targetPreparationCompletionCountForVerification
        _ = coordinator.validateDestinationDrop(internalDrag, destination: sidebarTarget)
        try await waitUntil("First held A hover") { gate.arrivals == 1 }
        _ = coordinator.validateDestinationDrop(internalDrag, destination: driveTarget)
        try await waitUntil("Held B hover") { gate.arrivals == 2 }
        _ = coordinator.validateDestinationDrop(internalDrag, destination: sidebarTarget)
        try await waitUntil("Second held A hover") { gate.arrivals == 3 }
        gate.release(1)
        try await waitUntil("Cancelled old A completes cleanup") {
            coordinator.targetPreparationCompletionCountForVerification > completedBefore
        }
        try require(coordinator.verificationState.preparing,
                    "Cancelled A cleared a newer preparation for the same destination")
        gate.release(2); gate.release(3)
        try await waitUntil("Newer A publishes after old A cleanup") {
            coordinator.hasPreparedDestinationForVerification(sidebarTarget) && !coordinator.verificationState.preparing
        }
        coordinator.hooks.observeTarget = nil
        browser.sidebarRoots = []
        browser.outline.reloadData(); coordinator.destinationsChanged()
        try require(!coordinator.acceptDestinationDrop(internalDrag, destination: sidebarTarget),
                    "Removed sidebar target retained authority")
        coordinator.endSourceForVerification()
        coordinator.draggingExited()
        try require(!coordinator.hasPreparedDestinationForVerification(sidebarTarget)
                    && admissions.first?.observation.urls.contains(sidebarTarget) == true,
                    "Drag exit retained hover authority or invalidated an accepted request snapshot")

        browser.navigate(to: .computer); try await settled(browser)
        browser.volumes = [
            VolumeInfo(url: driveTarget, name: "Generated Drive", kind: .externalDisk, isReadOnly: false),
            VolumeInfo(url: readOnlyTarget, name: "Generated Read Only", kind: .externalDisk, isReadOnly: true)
        ]
        browser.renderVolumes(); browser.view.layoutSubtreeIfNeeded()
        browser.volumeBrowser.layoutSubtreeIfNeeded(); browser.volumeBrowser.collectionView.layoutSubtreeIfNeeded()
        coordinator.destinationsChanged()
        try await waitUntil("Generated drive tiles") {
            browser.volumeBrowser.visibleTiles.contains { $0.volume?.url == driveTarget }
        }
        coordinator.destinationsChanged()
        try require(coordinator.navigationCandidatesForVerification.contains(driveTarget)
                    && !coordinator.navigationCandidatesForVerification.contains(readOnlyTarget),
                    "Drive destinations omitted writable observation or admitted known read-only volume")
        try require(!coordinator.hasPreparedDestinationForVerification(driveTarget),
                    "Merely rendering the drive overview probed its destination")
        guard let tile = browser.volumeBrowser.visibleTiles.first(where: { $0.volume?.url == driveTarget }) else {
            throw Failure(message: "Generated drive tile is missing")
        }
        let collection = browser.volumeBrowser.collectionView
        let external = DestinationFixtureDrag(board: board, sequence: 4102)
        external.draggingDestinationWindow = browser.view.window
        external.draggingLocation = tile.view.convert(NSPoint(x: tile.view.bounds.midX, y: tile.view.bounds.midY), to: nil)
        _ = collection.draggingEntered(external)
        try await waitUntil("External source and hovered drive observation") {
            coordinator.verificationState.external && coordinator.hasPreparedDestinationForVerification(driveTarget)
        }
        if NSEvent.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            try require(collection.draggingUpdated(external) == .copy,
                        "Native drive callback did not negotiate external Copy")
            try require(collection.performDragOperation(external), "Native drive callback did not admit external Copy")
            try require(admissions.last?.move == false && admissions.last?.destination == driveTarget,
                        "Drive callback retargeted the request or requested external source retirement")
        }
        external.draggingLocation = collection.convert(NSPoint(x: -20, y: -20), to: nil)
        try require(collection.draggingUpdated(external).isEmpty && !collection.performDragOperation(external),
                    "Drive overview background acquired destination authority")
        browser.volumes = []; browser.renderVolumes(); coordinator.destinationsChanged()
        try require(!coordinator.acceptDestinationDrop(external, destination: driveTarget),
                    "Removed volume retained prepared destination authority")
        browser.sidebarRoots = [group]; browser.outline.reloadData(); browser.outline.expandItem(group)
        browser.view.layoutSubtreeIfNeeded(); coordinator.destinationsChanged()
        _ = coordinator.validateDestinationDrop(external, destination: missingTarget)
        try await waitUntil("Missing destination preparation refused") { !coordinator.verificationState.preparing }
        try require(!coordinator.hasPreparedDestinationForVerification(missingTarget)
                    && !coordinator.acceptDestinationDrop(external, destination: missingTarget),
                    "Missing target was offered as an observed destination")
        try require(try Data(contentsOf: source) == payload
                    && !FileManager().fileExists(atPath: sidebarTarget.appendingPathComponent(source.lastPathComponent).path)
                    && !FileManager().fileExists(atPath: driveTarget.appendingPathComponent(source.lastPathComponent).path),
                    "Injected destination callback verification mutated its fixtures")
        browser.navigate(to: .directory(fixture)); try await settled(browser)
        let checks = [
            "Visible sidebar directories and writable drive tiles expose drop-only destinations; groups, insertions, unresolved and read-only locations refuse",
            "Sidebar and drive targets are observed off-main only on explicit hover, with cached internal Move/Option Copy and external Copy-only admission",
            "Busy, removed, missing and background destinations refuse; A-B-A hover cancellation cannot clear a newer same-target task; accepted requests retain observations",
            "Injected native destination callbacks use a private pasteboard and leave generated sources/destinations unchanged; physical drag and Finder unexercised"
        ]
        try JSONSerialization.data(withJSONObject: ["checks": checks, "admittedRequests": admissions.count,
            "physicalDragExercised": false, "fileMutationExercised": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("destination-drop-verification.json"), options: .withoutOverwriting)
        return checks
    }
}
#endif
