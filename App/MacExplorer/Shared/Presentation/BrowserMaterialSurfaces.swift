import AppKit

@MainActor
extension BrowserViewController {
    func updateMaterialSurfaces() {
        workspace?.updateChromeBackdrop()
        // One continuous workspace backdrop connects adjoining chrome regions.
        // Standalone windows retain their independent native backdrop.
        for surface in [navigationSurface, sidebarSurface, statusSurface, contentSurface, addressLayout?.bottomSurface] {
            surface?.usesWindowBackdrop = workspace == nil
        }
        let workspace = NSWorkspace.shared
        func enabled(_ region: Bool) -> Bool {
            BrowserMaterialPolicy.glassEnabled(style: settings.navigationStyle, enabled: region,
                reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
        }
        let navigation = enabled(settings.glassNavigation)
        view.window?.titlebarAppearsTransparent = navigation
        (view.window as? BrowserWindow)?.titlebarMaterial?.surface.isGlassEnabled = navigation
        addressLayout?.bottomSurface.isGlassEnabled = navigation
        navigationSurface?.isGlassEnabled = navigation
        tabStrip.isGlassEnabled = navigation
        (pathField.superview as? AddressSurfaceView)?.isGlassEnabled = navigation
        tabStrip.drawsSolidBackground = false
        pathContainer.drawsSolidBackground = false
        sidebarSurface?.isGlassEnabled = enabled(settings.glassSidebar)
        statusSurface?.isGlassEnabled = enabled(settings.glassStatusBar)
        let content = enabled(settings.glassFileContent)
        (detailsHeader as? FileTableHeaderView)?.usesGlass = content
        (table.headerView as? FileTableHeaderView)?.usesGlass = content
        (detailsHeader as? FileTableHeaderView)?.motionEnabled = settings.motion.allows(.sortIndicators)
        (table.headerView as? FileTableHeaderView)?.motionEnabled = settings.motion.allows(.sortIndicators)
        contentSurface?.isGlassEnabled = content
        for owner in smbTabs.values { owner.rows.configure(glass: content, motion: settings.motion.allows(.sortIndicators), mode: settings.motion.mode) }
        for owner in sftpTabs.values { owner.rows.configure(glass: content, motion: settings.motion.allows(.sortIndicators), mode: settings.motion.mode) }
        folderScroll.backgroundColor = .controlBackgroundColor
        folderScroll.drawsBackground = !content
        folderScroll.contentView.drawsBackground = !content
        table.backgroundColor = content ? .clear : .controlBackgroundColor
        iconBrowser.contentBackgroundIsTransparent = content
        volumeBrowser.contentBackgroundIsTransparent = content
        view.needsDisplay = true
    }
}
