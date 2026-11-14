#if DEBUG
import AppKit

@MainActor
extension UIVerification {
    static func verifyMaterialAreas(_ browser: BrowserViewController, fixture: URL, output: URL) async throws -> [String] {
        let settings = browser.settings
        let appearance = settings.appearance
        let style = settings.navigationStyle
        let regions = (settings.glassNavigation, settings.glassSidebar, settings.glassStatusBar, settings.glassFileContent)
        defer {
            settings.appearance = appearance
            settings.navigationStyle = style
            settings.glassNavigation = regions.0
            settings.glassSidebar = regions.1
            settings.glassStatusBar = regions.2
            settings.glassFileContent = regions.3
            browser.updateMaterialSurfaces()
        }
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        guard let window = browser.view.window,
              let navigation = browser.navigationSurface, let sidebar = browser.sidebarSurface,
              let content = browser.contentSurface, let status = browser.statusSurface,
              let address = browser.pathField.superview as? AddressSurfaceView else {
            throw Failure(message: "Material regions are missing from the actual browser")
        }
        settings.navigationStyle = .glass
        settings.glassNavigation = true
        settings.glassSidebar = true
        settings.glassStatusBar = true
        settings.glassFileContent = false
        browser.updateMaterialSurfaces()
        try await snapshot(window, to: output.appendingPathComponent("areas-initial-default-content.png"))
        try require(content.isUsingOpaqueSurface && browser.folderScroll.drawsBackground && browser.table.backgroundColor.alphaComponent == 1,
                    "File rows must be solid by default (material=\(content.isUsingOpaqueSurface), scroll=\(browser.folderScroll.drawsBackground), tableAlpha=\(browser.table.backgroundColor.alphaComponent))")
        let fallback = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        try require(navigation.isUsingOpaqueSurface == fallback && sidebar.isUsingOpaqueSurface == fallback && status.isUsingOpaqueSurface == fallback,
                    "Default navigation/sidebar/status did not follow the material policy")

        for mode in [BrowserAppearance.light, .dark] {
            settings.appearance = mode
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            try await snapshot(window, to: output.appendingPathComponent("areas-\(mode.rawValue)-glass.png"))
        }
        browser.focusLocation(nil)
        browser.pathField.stringValue = "Unfinished generated address"
        let editor = browser.pathField.currentEditor()
        settings.glassNavigation = false
        browser.updateMaterialSurfaces()
        try require(navigation.isUsingOpaqueSurface && !address.isGlassEnabled && !browser.tabStrip.isGlassEnabled
                    && sidebar.isUsingOpaqueSurface == fallback && status.isUsingOpaqueSurface == fallback,
                    "Turning navigation Glass off changed another region or left dark chrome translucent")
        try require(browser.pathField.currentEditor() === editor && browser.pathField.stringValue == "Unfinished generated address",
                    "Region material change lost native address focus or input")
        window.makeFirstResponder(browser.table)
        settings.glassSidebar = false
        settings.glassStatusBar = false
        settings.glassFileContent = true
        browser.updateMaterialSurfaces()
        try require(sidebar.isUsingOpaqueSurface && status.isUsingOpaqueSurface && content.isUsingOpaqueSurface == fallback,
                    "Independent region controls did not take effect")
        try require(browser.folderScroll.drawsBackground == fallback && browser.table.backgroundColor.alphaComponent == (fallback ? 1 : 0),
                    "Experimental content retained an opaque scroll or table background")
        let volumes = browser.volumeBrowser
        try require(volumes.scrollView.drawsBackground == fallback
                    && volumes.scrollView.contentView.drawsBackground == fallback
                    && volumes.collectionView.backgroundColors.allSatisfy { $0.alphaComponent == (fallback ? 1 : 0) },
                    "This Mac retained an opaque scrolling layer over the shared content material")
        settings.glassNavigation = true
        settings.glassSidebar = true
        settings.glassStatusBar = true
        browser.updateMaterialSurfaces()
        try await snapshot(window, to: output.appendingPathComponent("areas-dark-experimental-content.png"))
        settings.navigationStyle = .solid
        browser.updateMaterialSurfaces()
        try require([navigation, sidebar, content, status].allSatisfy(\.isUsingOpaqueSurface)
                    && !address.isGlassEnabled && !browser.tabStrip.isGlassEnabled && browser.folderScroll.drawsBackground,
                    "Solid master style did not override all area preferences")
        try require(volumes.scrollView.drawsBackground && volumes.scrollView.contentView.drawsBackground
                    && volumes.collectionView.backgroundColors.allSatisfy { $0.alphaComponent == 1 },
                    "This Mac did not restore solid content with the master style")
        try await snapshot(window, to: output.appendingPathComponent("areas-dark-solid.png"))
        return ["Native material regions follow independent controls and master Solid override; file content defaults solid",
                "Opt-in content removes table/scroll opaque fills; current accessibility fallback remains authoritative",
                "Changing native material preserves actual field-editor focus/input; Light/Dark captures use owned fixture"]
    }
}
#endif
