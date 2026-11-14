import AppKit

/// Contextual projection of existing commands. Menubar actions remain the
/// complete catalog; item menus show only relevant actions, grouped consistently.
@MainActor enum NativeContextMenu {
    static func arrange(_ source: NSMenu?, groups: [[Selector]], allows: (NSMenuItem) -> Bool,
                        alwaysShow: Set<Selector> = []) -> NSMenu {
        let result = NSMenu()
        for group in groups {
            var entries: [NSMenuItem] = []
            for action in group {
                guard let item = source?.items.first(where: { $0.action == action && !$0.isHidden }),
                      allows(item) || alwaysShow.contains(action), let copy = item.copy() as? NSMenuItem else { continue }
                entries.append(copy)
            }
            guard !entries.isEmpty else { continue }
            if !result.items.isEmpty { result.addItem(.separator()) }
            for item in entries { result.addItem(item) }
        }
        return result
    }
}
