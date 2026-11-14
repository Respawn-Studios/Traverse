#if DEBUG
import AppKit
import ExplorerCore
import SwiftUI

@MainActor struct RenderedToolSession<Model: AnyObject>: NSViewRepresentable {
    let model: Model
    final class Marker: NSView { weak var model: Model? }
    func makeNSView(context: Context) -> Marker { let view = Marker(); view.model = model; return view }
    func updateNSView(_ view: Marker, context: Context) { view.model = model }
    static func models(in view: NSView) -> [Model] {
        (view as? Marker).flatMap { $0.model }.map { [$0] } ?? view.subviews.flatMap { models(in: $0) }
    }
}

/// Real workspace replacement beneath the normal setup model. Generated state
/// only; no file grant, personal scan, server or Keychain access is performed.
@MainActor enum SetupLifetimeVerification {
    static func run() async {
        guard let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: text)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.resolvingSymlinksInPath() == root,
              root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              let data = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["action"] as? String == "setup-lifetime-qualification" else { exit(2) }
        var owner: BrowserWindowController?
        var checks: [String] = []
        var facts: [String: Any] = [:]
        var failure: String?
        do {
            let settings = BrowserSettings(persist: false)
            settings.motion.mode = .full
            InterfacePresentation.shared.bind(settings)
            let controller = BrowserWindowController(settings: settings)
            owner = controller
            guard controller.isWorkspacePresentation else { throw UIVerification.Failure(message: "Real workspace composition required") }
            controller.showWindow(nil)
            controller.window?.title = "Generated setup lifetime · no file changes"
            TraverseSetupController.shared.show(from: controller.browser)
            guard let model = TraverseSetupController.shared.model, let setup = TraverseSetupController.shared.window else {
                throw UIVerification.Failure(message: "Ordinary setup model/window absent")
            }
            model.page = 3
            let originalID = ObjectIdentifier(controller.browser)
            let snapshot = try controller.workspace.captureSessionSnapshot(syncViewState: false)
            try controller.workspace.applyRestoredSnapshot(snapshot)
            await Task.yield()
            facts["workspaceBrowserReplaced"] = ObjectIdentifier(controller.browser) != originalID
            facts["setupBrowserMissing"] = model.browser == nil
            facts["setupFollowsCurrentBrowser"] = model.browser === controller.browser
            facts["initialSetupCompletedBeforeAction"] = settings.initialSetupCompleted
            try UIVerification.require(model.browser === controller.browser,
                "Setup keeps a retired startup pane after restored workspace replacement")
            checks.append("Setup follows the live browser after the actual restored-workspace replacement")
            TraverseSetupController.shared.show(from: controller.browser)
            try UIVerification.require(TraverseSetupController.shared.model === model && model.page == 3,
                "Reopening visible setup discards current choices or page")
            checks.append("Raising visible setup preserves its current choices and page")
            model.chooseStartup(.computer)
            try await wait { settings.startupMode == .computer && !model.changingStartup }
            checks.append("Startup preference actions still reach shared settings after pane replacement")
            model.chooseFolder(initialDirectory: root.appendingPathComponent("source/Generated Folder"))
            try await wait { setup.attachedSheet != nil }
            guard let panel = setup.attachedSheet as? NSOpenPanel else {
                throw UIVerification.Failure(message: "Real setup folder chooser absent")
            }
            try UIVerification.require(panel.title == "Grant Folder Access" && model.choosing,
                "Folder selection did not use the actual access chooser")
            panel.cancel(nil)
            try await wait { setup.attachedSheet == nil && !model.choosing }
            checks.append("Actual folder chooser presents and Cancel drains without granting access")
            model.page = 4
            model.finish()
            try await wait { settings.initialSetupCompleted && !setup.isVisible }
            checks.append("The shared Skip/Start action completes and closes after startup replacement")
            TraverseSetupController.shared.show(from: controller.browser)
            guard let second = TraverseSetupController.shared.model, let secondWindow = TraverseSetupController.shared.window else {
                throw UIVerification.Failure(message: "Setup cannot reopen after completion")
            }
            let next = try controller.workspace.captureSessionSnapshot(syncViewState: false)
            try controller.workspace.applyRestoredSnapshot(next)
            try UIVerification.require(second.browser === controller.browser,
                "A second workspace replacement loses setup ownership")
            second.page = 0; second.finish()
            try await wait { !secondWindow.isVisible }
            checks.append("Reopened setup and repeated workspace replacement retain working finish actions")
            try UIVerification.require(TraverseSetupController.shared.model == nil && TraverseSetupController.shared.window == nil
                && TraverseSetupController.shared.contentViewController == nil
                && second.window == nil, "Closed setup retains an obsolete window/model action context")
            checks.append("Closed setup releases its hosting/action context instead of reviving an obsolete session")
            try await wait { secondWindow.contentViewController == nil }
            let savedMode = settings.startupMode
            second.chooseStartup(savedMode == .computer ? .lastSession : .computer)
            second.chooseFolder(initialDirectory: root.appendingPathComponent("source/Generated Folder"))
            second.finish()
            await Task.yield()
            try UIVerification.require(second.isClosed && !second.finishing && settings.startupMode == savedMode
                && secondWindow.attachedSheet == nil, "Retired setup controls still mutate preferences or present a chooser")
            checks.append("Retired hosting is detached and obsolete setup actions refuse without saving or presenting")
            for _ in 0..<3 {
                TraverseSetupController.shared.show(from: controller.browser)
                guard let current = TraverseSetupController.shared.model, let currentWindow = TraverseSetupController.shared.window else {
                    throw UIVerification.Failure(message: "Repeated setup has no live context")
                }
                try await Task.sleep(for: .milliseconds(350))
                let rendered = currentWindow.contentView.map { RenderedToolSession<TraverseSetupModel>.models(in: $0) } ?? []
                facts["renderedSessionCount"] = rendered.count
                facts["renderedCurrentSession"] = rendered.map { $0 === current }
                facts["renderedClosedSessions"] = rendered.map(\.isClosed)
                try UIVerification.require(rendered.count == 1 && rendered[0] === current && !current.isClosed && !current.finishing,
                    "The rendered setup page revives an obsolete session after animated reopen")
                current.finish()
                try await wait { !currentWindow.isVisible }
                try await Task.sleep(for: .milliseconds(350))
            }
            checks.append("Animated repeat reopening renders only the current live setup session")
            for _ in 0..<2 {
                TraverseTourController.shared.show(from: controller.browser)
                guard let tour = TraverseTourController.shared.model, let tourWindow = TraverseTourController.shared.window else {
                    throw UIVerification.Failure(message: "Tour has no live context")
                }
                try await Task.sleep(for: .milliseconds(350))
                let rendered = tourWindow.contentView.map { RenderedToolSession<TraverseTourModel>.models(in: $0) } ?? []
                facts["renderedTourSessionCount"] = rendered.count
                facts["renderedCurrentTourSession"] = rendered.map { $0 === tour }
                try UIVerification.require(rendered.count == 1 && rendered[0] === tour && tour.page == 0,
                    "The rendered tour revives an obsolete session after reopening")
                tour.next(); tourWindow.close()
                try await Task.sleep(for: .milliseconds(350))
            }
            checks.append("Optional tour repeat reopening renders its fresh current session")
        } catch { failure = String(describing: error) }
        TraverseSetupController.shared.window?.close()
        TraverseTourController.shared.window?.close()
        owner?.close()
        facts["passed"] = failure == nil
        facts["checks"] = checks
        facts["failure"] = failure as Any
        facts["grantsAccepted"] = 0
        facts["personalFileOperations"] = 0
        do {
            let output = try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: root.appendingPathComponent("evidence/native-setup-lifetime.json"), options: .withoutOverwriting)
        } catch { exit(2) }
        exit(failure == nil ? 0 : 2)
    }

    private static func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw UIVerification.Failure(message: "Setup action did not complete within its bound") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
