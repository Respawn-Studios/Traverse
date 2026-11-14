import AppKit

/// Native window navigation stays available when a document owns the menu bar.
/// AppKit owns the window entries, their edited indicators and their actions.
@MainActor enum NativeWindowMenu {
    static func make(tabbedWindow: NSWindow? = nil) -> NSMenu {
        let menu = NSMenu(title: "Window")
        func add(_ title: String, _ action: Selector, key: String = "",
                 modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = target
            menu.addItem(item)
        }
        add("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add("Zoom", #selector(NSWindow.performZoom(_:)))
        if let window = tabbedWindow {
            menu.addItem(.separator())
            add("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), key: "\t", modifiers: .control, target: window)
            add("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), key: "\t", modifiers: [.control, .shift], target: window)
            add("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)), target: window)
            add("Merge Editor Windows", #selector(NSWindow.mergeAllWindows(_:)), target: window)
            add("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:)), target: window)
        }
        menu.addItem(.separator())
        add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        return menu
    }

    static func bind(_ menu: NSMenu?) {
        NSApp.windowsMenu = menu
    }
}
