import AppKit

/// A key tool window can replace the browser menus while it owns focus.
/// An old resign-key notification cannot restore a menu over a newer owner.
@MainActor enum ToolWindowMenuOwnership {
    private static var owner: ObjectIdentifier?
    private static var current: NSMenu?
    private static var baseline: NSMenu?
    private static var baselineWindows: NSMenu?
    private static var baselineHelp: NSMenu?

    static func owns(_ value: AnyObject) -> Bool {
        owner == ObjectIdentifier(value) && NSApp.mainMenu === current
    }
    static func claim(_ value: AnyObject, make: (NSMenu?) -> NSMenu) -> NSMenu {
        if owner == nil || NSApp.mainMenu !== current {
            baseline = NSApp.mainMenu; baselineWindows = NSApp.windowsMenu; baselineHelp = NSApp.helpMenu
        }
        let menu = make(baseline)
        if menu.item(withTitle: "Window") == nil {
            let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
            item.submenu = NativeWindowMenu.make()
            let helpIndex = menu.items.firstIndex(where: { $0.title == "Help" }) ?? menu.numberOfItems
            menu.insertItem(item, at: helpIndex)
        }
        owner = ObjectIdentifier(value); current = menu; NSApp.mainMenu = menu
        NativeWindowMenu.bind(menu.item(withTitle: "Window")?.submenu)
        NSApp.helpMenu = menu.item(withTitle: "Help")?.submenu
        return menu
    }
    static func release(_ value: AnyObject) {
        guard owner == ObjectIdentifier(value) else { return }
        if NSApp.mainMenu === current {
            NSApp.mainMenu = baseline
            NativeWindowMenu.bind(baselineWindows); NSApp.helpMenu = baselineHelp
        }
        owner = nil; current = nil; baseline = nil; baselineWindows = nil; baselineHelp = nil
    }

    static func reviewMenu(from baseline: NSMenu?, window: NSWindow?, actions: [NSMenuItem] = [],
                           viewActions: [NSMenuItem] = []) -> NSMenu {
        let menu = NSMenu()
        if let app = baseline?.items.first?.copy() as? NSMenuItem { menu.addItem(app) }
        let file = NSMenu(title: "File")
        actions.forEach(file.addItem)
        file.addItem(BrowserMenus.item("Close", #selector(NSWindow.performClose(_:)), key: "w", target: window))
        let entry = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        entry.submenu = file
        menu.addItem(entry)
        if !viewActions.isEmpty {
            let view = NSMenu(title: "View")
            viewActions.forEach(view.addItem)
            let item = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            item.submenu = view
            menu.addItem(item)
        }
        return menu
    }
}
