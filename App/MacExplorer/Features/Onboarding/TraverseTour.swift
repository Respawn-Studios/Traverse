import AppKit
import ExplorerCore
import SwiftUI

/// Optional instructions only: no navigation, selection, filesystem access or
/// operation admission. Shortcuts are read from the active user's actual map.
@MainActor final class TraverseTourModel: ObservableObject {
    @Published private(set) var page = 0
    let settings: BrowserSettings
    init(settings: BrowserSettings) { self.settings = settings }
    var title: String { ["Find your way", "Make room for your work", "Keep changes reviewable"][page] }
    var symbol: String { ["location.magnifyingglass", "rectangle.split.2x1", "arrow.uturn.backward.circle"][page] }
    var detail: String {
        switch page {
        case 0: "Jump to a folder from the address bar (\(key(.address))). Use the search menu to look in the current folder or This Mac. Your own saved names work without AI."
        case 1: "Create a tab with \(key(.newTab)). Drag a tab to the edge of your files, or use View → Split Pane, to browse two places side by side. Save a layout profile to use it again."
        default: "Open Operation Results to check your changes. Use \(key(.undo)) to undo a supported change. If anything needs attention, Traverse will show you what to review."
        }
    }
    func next() { page = min(page + 1, 2) }
    func back() { page = max(page - 1, 0) }
    private func key(_ command: BrowserCommand) -> String {
        settings.shortcutMap.shortcuts(for: command).first?.display ?? command.title + " in the menu"
    }
}

@MainActor final class TraverseTourController: NSWindowController, NSWindowDelegate {
    static let shared = TraverseTourController()
    private(set) var model: TraverseTourModel?
    init() { super.init(window: nil) }
    required init?(coder: NSCoder) { nil }
    func show(from browser: BrowserViewController) {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let model = TraverseTourModel(settings: browser.settings)
        let content = TraverseTourView(settings: browser.settings, model: model) { [weak self] in self?.window?.performClose(nil) }
        let window = ToolWindowChrome.makeWindow(title: "A quick look around Traverse",
            size: .init(width: 420, height: 285), minimumSize: .zero, styleMask: [.titled, .closable, .resizable])
        window.contentMinSize = .init(width: 420, height: 285)
        let host = InterfaceHostingController(rootView: content)
        host.view.frame = .init(x: 0, y: 0, width: 420, height: 285)
        window.contentViewController = host
        ToolWindowChrome.install(in: window, settings: browser.settings)
        window.setContentSize(.init(width: 420, height: 285)); window.delegate = self
        self.window = window; self.model = model
        if let parent = browser.view.window, let screen = parent.screen {
            let area = screen.visibleFrame
            window.setFrameOrigin(.init(x: min(max(parent.frame.maxX - window.frame.width - 24, area.minX), area.maxX - window.frame.width),
                y: min(max(parent.frame.midY - window.frame.height / 2, area.minY), area.maxY - window.frame.height)))
        } else { window.center() }
        window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        model = nil; window = nil; contentViewController = nil
        Task { @MainActor in
            await Task.yield()
            closing.orderOut(nil); closing.contentViewController = nil; closing.contentView = nil
        }
    }
}

private struct TraverseTourView: View {
    @ObservedObject var settings: BrowserSettings
    @ObservedObject var model: TraverseTourModel
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: model.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(model.title).interfaceFont(.title3.bold())
                Spacer()
                Text("\(model.page + 1) of 3").interfaceFont(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(model.detail).interfaceFont(.body).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .toolPageEntrance(model.page, enabled: settings.motion.allows(.pages), mode: settings.motion.mode)
            }.scrollBounceBehavior(.basedOnSize)
            Text("Keep browsing while this stays open. Reopen it from Help → Show Me Around.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                if model.page > 0 { Button("Back") { model.back() } }
                Button(model.page == 2 ? "Done" : "Next") {
                    if model.page == 2 { close() } else { model.next() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("traverse-optional-tour")
            #if DEBUG
            .background(RenderedToolSession(model: model).allowsHitTesting(false))
            #endif
    }
}

extension BrowserViewController {
    @objc func showTraverseTour(_ sender: Any?) { TraverseTourController.shared.show(from: self) }
}
