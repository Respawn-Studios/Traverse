import AppKit
import QuartzCore
import SwiftUI

/// Isolated native form hosts prevent SwiftUI from reusing outgoing AppKit form
/// controls inside an incoming opacity transaction. Only two live view trees
/// overlap briefly; the outgoing one loses input and accessibility immediately.
/// There are no captured bitmaps, persisted fields or delayed model commands.
typealias NativeSettingsPageHost = NativeToolPageHost<BrowserSettingsView.Page>

@MainActor
final class NativeToolPageViewport: NSView {
    var finishPageTransition: (() -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishPageTransition?() }
        super.viewWillMove(toWindow: newWindow)
    }
}

struct NativeToolPageHost<ID: Hashable>: NSViewControllerRepresentable {
    let page: ID
    // Capture identity-specific display values when building content. An
    // outgoing tree observing the new selection would replace its facts before
    // the fade finishes. Commands can keep their live, revalidating owner.
    let content: AnyView
    let motion: BrowserMotionPreferences

    func makeNSViewController(context: Context) -> Controller { Controller() }
    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.show(page, content: content, motion: motion)
    }
    static func dismantleNSViewController(_ controller: Controller, coordinator: ()) {
        controller.finishTransition()
    }

    @MainActor final class Controller: NSViewController {
        private final class PageContainer: NSView {
            var acceptsInput = true
            override func hitTest(_ point: NSPoint) -> NSView? {
                acceptsInput ? super.hitTest(point) : nil
            }
        }
        private struct Entry {
            let page: ID
            let host: InterfaceHostingController<AnyView>
            let container: PageContainer
        }
        private struct Transition {
            let id: UUID
            let outgoing: Entry
            let incoming: Entry
        }
        private var current: Entry?
        private var transition: Transition?

        override func loadView() {
            let root = NativeToolPageViewport()
            root.finishPageTransition = { [weak self] in self?.finishTransition() }
            root.wantsLayer = true
            // NSView no longer clips by default on macOS14+. A native form
            // must stay within its fixed viewport while its layout settles.
            root.clipsToBounds = true; root.layer?.masksToBounds = true
            root.identifier = .init("tool-page-viewport")
            view = root
            ToolContentMotion.registerPageViewport(root)
        }
        func show(_ page: ID, content: AnyView, motion: BrowserMotionPreferences) {
            loadViewIfNeeded()
            let duration = ToolPageMotionPolicy.crossfadeDuration(motion)
            if let transition, transition.incoming.page == page {
                transition.incoming.host.content = content
                if duration == 0 { finishTransition() }
                return
            }
            // An explicit newer click takes precedence. End only this owner's
            // current transition; stale completion cannot remove a newer page.
            finishTransition()
            if let current, current.page == page {
                current.host.content = content
                return
            }
            if let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor,
               let container = current?.container, editor.isDescendant(of: container) {
                _ = view.window?.makeFirstResponder(nil)
            }
            let host = InterfaceHostingController(rootView: content)
            host.sizingOptions = []
            addChild(host)
            let container = PageContainer(frame: view.bounds)
            container.autoresizingMask = [.width, .height]
            container.wantsLayer = true
            container.clipsToBounds = true; container.layer?.masksToBounds = true
            container.identifier = .init("tool-page-live-container")
            host.view.clipsToBounds = true; host.view.layer?.masksToBounds = true
            host.view.identifier = .init("tool-page-form")
            host.view.frame = container.bounds; host.view.autoresizingMask = [.width, .height]
            container.addSubview(host.view)
            let incoming = Entry(page: page, host: host, container: container)
            view.addSubview(container)
            guard let outgoing = current else { current = incoming; return }
            guard duration > 0, view.window?.isVisible == true else {
                remove(outgoing); current = incoming; return
            }
            outgoing.container.acceptsInput = false
            outgoing.container.setAccessibilityHidden(true)
            container.alphaValue = 0
            let id = UUID()
            transition = .init(id: id, outgoing: outgoing, incoming: incoming)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = ToolPageMotionPolicy.crossfadeTiming
                context.allowsImplicitAnimation = true
                outgoing.container.animator().alphaValue = 0
                container.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard self?.transition?.id == id else { return }
                    self?.finishTransition()
                }
            }
        }
        func finishTransition() {
            guard let transition else { return }
            self.transition = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                transition.incoming.container.animator().alphaValue = 1
                transition.outgoing.container.animator().alphaValue = 0
            }
            transition.incoming.container.acceptsInput = true
            transition.incoming.container.setAccessibilityHidden(false)
            remove(transition.outgoing)
            current = transition.incoming
        }
        private func remove(_ entry: Entry) {
            entry.container.removeFromSuperview()
            entry.host.removeFromParent()
        }
    }
}
