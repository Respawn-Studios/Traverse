import AppKit

/// Search-panel presentation only. Each feature retains its command catalog,
/// captured context, focus restoration and execution/admission rules.
@MainActor enum CommandDiscoveryPresentation {
    /// Match the actual viewport after native scrollers tile. Column
    /// autoresizing alone can retain the pre-scroller document width.
    private final class ResultsScrollView: NSScrollView {
        override func layout() {
            super.layout()
            guard let table = documentView as? NSTableView, table.tableColumns.count == 1,
                  let column = table.tableColumns.first,
                  contentSize.width.isFinite, contentSize.width > 0 else { return }
            let fitted = min(column.maxWidth, max(column.minWidth,
                column.width + contentSize.width - table.frame.width))
            if abs(fitted - column.width) > 0.5 {
                column.width = fitted; table.sizeToFit()
            }
        }
    }
    static func makePanel(query: NSSearchField, table: NSTableView, status: NSTextField,
                          title: String = "Find a Command", scope: String,
                          searchLabel: String = "Find a Traverse command",
                          placeholder: String = "Find an action or shortcut",
                          resultsLabel: String = "Matching commands", accessory: NSView? = nil,
                          settings: BrowserSettings?) -> NSPanel {
        let panel = ToolWindowChrome.makePanel(title: title, size: .init(width: 620, height: 420),
            minimumSize: .init(width: 620, height: 420))
        panel.hidesOnDeactivate = true; panel.isFloatingPanel = false
        let controller = NSViewController(), content = NSView()
        controller.view = content; panel.contentViewController = controller
        query.placeholderString = placeholder
        query.sendsWholeSearchString = false; query.sendsSearchStringImmediately = true
        query.maximumRecents = 0; query.recentSearches = []; query.recentsAutosaveName = nil
        query.font = .systemFont(ofSize: 17)
        query.setAccessibilityLabel(searchLabel)
        table.setAccessibilityLabel(resultsLabel)
        if table.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: .init("command")); column.width = 576
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.tableColumns.first?.resizingMask = .autoresizingMask
        table.allowsColumnResizing = false; table.allowsColumnReordering = false
        // Use the same explicit geometry as the file list. Automatic inset
        // tables can keep their content wider than a legacy scroller's viewport.
        table.style = .plain
        table.headerView = nil; InterfaceMetrics.setRowHeight(table, base: 42)
        table.backgroundColor = .clear; table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.focusRingType = .none
        let scroll = ResultsScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        let caption = label(scope, size: 11, color: .secondaryLabelColor, weight: .medium)
        let line = NSBox(); line.boxType = .separator
        let controls = [query, caption] + [accessory].compactMap { $0 } + [scroll, line, status]
        let stack = NSStackView(views: controls); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = .init(top: 16, left: 18, bottom: 14, right: 18)
        pin(stack, inside: content)
        for view in controls {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        query.heightAnchor.constraint(equalToConstant: 34).interfaceScaled.isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        status.maximumNumberOfLines = 2
        ToolWindowChrome.install(in: panel, settings: settings)
        // An empty result table's transient fitting size must not collapse the
        // panel before its first rows are installed.
        panel.contentMinSize = .init(width: 620, height: 420)
        panel.setContentSize(.init(width: 620, height: 420))
        return panel
    }

    static func position(_ panel: NSPanel, relativeTo parent: NSWindow) {
        let available = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        let frame = NSRect(x: parent.frame.midX - panel.frame.width / 2,
            y: parent.frame.maxY - 100 - panel.frame.height, width: panel.frame.width, height: panel.frame.height)
        panel.setFrameOrigin(.init(x: min(max(frame.minX, available.minX + 12), available.maxX - frame.width - 12),
            y: min(max(frame.minY, available.minY + 12), available.maxY - frame.height - 12)))
    }

    static func animateEntrance(_ panel: NSPanel, motion: BrowserMotionPreferences) {
        guard motion.allows(.windows), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1; return
        }
        panel.alphaValue = motion.mode.initialOpacity(0.7)
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.14 * motion.mode.durationScale
            panel.animator().alphaValue = 1
        }
    }

    static func row(title: String, category: String, shortcut: String, enabled: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        let heading = label(title, size: 13, color: enabled ? .labelColor : .secondaryLabelColor)
        let subtitle = label(category + (enabled ? "" : " · Unavailable here"), size: 10, color: .secondaryLabelColor)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titles = NSStackView(views: [heading, subtitle]); titles.orientation = .vertical
        titles.alignment = .leading; titles.spacing = 2
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let key = label(shortcut, size: 12, color: .secondaryLabelColor)
        key.setContentHuggingPriority(.required, for: .horizontal)
        key.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [titles, NSView(), key]); row.spacing = 12; row.alignment = .centerY
        row.edgeInsets = .init(top: 3, left: 10, bottom: 3, right: 10); pin(row, inside: cell)
        cell.textField = heading
        cell.setAccessibilityLabel(title + ", " + category + (enabled ? "" : ", unavailable") + ", " + shortcut)
        return cell
    }
}
