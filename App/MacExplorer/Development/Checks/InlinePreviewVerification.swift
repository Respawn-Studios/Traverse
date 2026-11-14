#if DEBUG
import AppKit
import CoreGraphics
import Darwin
import ExplorerCore
import ImageIO

@MainActor
enum InlinePreviewVerification {
    /// Native body rendering is a separate explicit generated-fixture opt-in.
    static func run(in testRoot: URL, renderKnownFixtures: Bool = false) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw UIVerification.Failure(message: "Inline preview verification requires its explicit unredirected fixture root.")
        }
        let owned = testRoot.appendingPathComponent("inline-preview-\(UUID().uuidString)", isDirectory: true)
        let text = owned.appendingPathComponent("ordinary.txt")
        let unknown = owned.appendingPathComponent("network-content.html")
        let package = owned.appendingPathComponent("Package.app", isDirectory: true)
        let symbolic = owned.appendingPathComponent("symbolic.txt")
        let alias = owned.appendingPathComponent("alias.txt")
        let fifo = owned.appendingPathComponent("special.txt")
        let missing = owned.appendingPathComponent("missing.txt")
        try await Task.detached {
            let manager = FileManager()
            try manager.createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("mac-explorer-inline-preview-fixture-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            try Data("Generated inline preview fixture\nNo personal file body is used.\n".utf8).write(to: text, options: .withoutOverwriting)
            try Data("<html><img src='https://invalid.example/should-not-load'></html>".utf8).write(to: unknown, options: .withoutOverwriting)
            try manager.createDirectory(at: package, withIntermediateDirectories: false)
            try manager.createSymbolicLink(at: symbolic, withDestinationURL: text)
            let bookmark = try text.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(bookmark, to: alias)
            let result = fifo.withUnsafeFileSystemRepresentation { $0.map { mkfifo($0, 0o600) } ?? -1 }
            guard result == 0 else { throw UIVerification.Failure(message: "Could not create owned special-file preview fixture") }
        }.value
        let reader = InlinePreviewSelectionReader()
        let ordinary = FileEntry(url: text, name: text.lastPathComponent, kind: .file)
        try require(try await reader.prepare(ordinary) == .eligible, "Generated ordinary text was not eligible")
        let metadataOnly = [
            FileEntry(url: unknown, name: unknown.lastPathComponent, kind: .file),
            FileEntry(url: package, name: package.lastPathComponent, kind: .package),
            FileEntry(url: symbolic, name: symbolic.lastPathComponent, kind: .symbolicLink),
            FileEntry(url: alias, name: alias.lastPathComponent, kind: .file),
            FileEntry(url: fifo, name: fifo.lastPathComponent, kind: .file),
            FileEntry(url: missing, name: missing.lastPathComponent, kind: .file)
        ]
        for entry in metadataOnly {
            guard case .metadataOnly = try await reader.prepare(entry) else {
                throw UIVerification.Failure(message: "Unsafe/generated fallback item was admitted to inline renderer")
            }
        }
        var checks = ["Inline metadata eligibility admits generated plain text and refuses real Finder alias, symlink, package, FIFO, missing item and HTML without body rendering"]

        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false
        let browser = BrowserViewController(settings: settings)
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        _ = browser.view
        browser.tabs[browser.activeIndex].navigate(to: .directory(owned))
        browser.restoringScroll = false
        browser.isLoading = false
        browser.displayedEntries = [ordinary] + metadataOnly
        browser.rawEntries = browser.displayedEntries
        browser.rowsByURL = Dictionary(uniqueKeysWithValues: browser.displayedEntries.enumerated().map { ($0.element.url, $0.offset) })
        let controller = BrowserInlinePreviewController()
        func select(_ url: URL) { browser.renderFilePresentation(selection: [url]); controller.updateSelection(from: browser) }
        select(text)
        try require(!controller.isEnabled && controller.state == .disabled && controller.hasReleasedSession,
                    "Ordinary browsing enabled or retained an inline renderer")
        controller.setEnabled(true)
        select(text)
        controller.setEnabled(false)
        try await Task.sleep(for: .milliseconds(250))
        try require(controller.state == .disabled && controller.hasReleasedSession && controller.renderedURL == nil,
                    "Disable allowed late preview preparation to retain/render selected data")
        controller.setEnabled(true)
        select(text)
        select(unknown)
        try await waitUntil("Latest metadata fallback") { controller.state == .metadataOnly }
        try require(controller.renderedURL == nil, "A stale previous selection reached the renderer")
        select(text)
        browser.sessionID = UUID()
        controller.endSession()
        try await Task.sleep(for: .milliseconds(250))
        try require(controller.hasReleasedSession && controller.renderedURL == nil, "Visit change retained stale preview resources")
        checks.append("Inline preview starts off; explicit enablement, selection churn, Disable and visit invalidation reject stale renderer work and release sessions")

        if renderKnownFixtures {
            let png = owned.appendingPathComponent("generated.png")
            let pdf = owned.appendingPathComponent("generated.pdf")
            try await Task.detached {
                guard let bitmap = CGContext(data: nil, width: 480, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                      let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) else {
                    throw UIVerification.Failure(message: "Could not create generated PNG preview fixture")
                }
                bitmap.setFillColor(CGColor(red: 0.08, green: 0.15, blue: 0.32, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
                bitmap.setFillColor(CGColor(red: 0.2, green: 0.65, blue: 0.9, alpha: 1))
                bitmap.fill(CGRect(x: 30, y: 30, width: 195, height: 260))
                bitmap.setFillColor(CGColor(red: 0.95, green: 0.65, blue: 0.3, alpha: 1))
                bitmap.fill(CGRect(x: 255, y: 30, width: 195, height: 260))
                guard let image = bitmap.makeImage() else { throw UIVerification.Failure(message: "Generated PNG drawing failed") }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw UIVerification.Failure(message: "Generated PNG encoding failed") }
                var media = CGRect(x: 0, y: 0, width: 280, height: 180)
                guard let consumer = CGDataConsumer(url: pdf as CFURL),
                      let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
                    throw UIVerification.Failure(message: "Could not create generated PDF preview fixture")
                }
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(red: 0.16, green: 0.42, blue: 0.8, alpha: 1))
                context.fill(CGRect(x: 20, y: 20, width: 240, height: 140))
                context.endPDFPage()
                context.closePDF()
            }.value
            browser.displayedEntries += [FileEntry(url: png, name: png.lastPathComponent, kind: .file), FileEntry(url: pdf, name: pdf.lastPathComponent, kind: .file)]
            browser.rawEntries = browser.displayedEntries
            browser.rowsByURL = Dictionary(uniqueKeysWithValues: browser.displayedEntries.enumerated().map { ($0.element.url, $0.offset) })
            let before = try await Task.detached { try [text, png, pdf].map { try Data(contentsOf: $0) } }.value
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.title = "Generated preview qualification"
            window.contentView = controller.view
            window.setContentSize(NSSize(width: 340, height: 480))
            window.orderFront(nil)
            defer { controller.setEnabled(false); window.close() }
            var exactWindowCaptures = 0
            for (index, url) in [text, png, pdf].enumerated() {
                select(url)
                try await waitUntil("Known fixture native renderer admission") { controller.state == .previewing && controller.renderedURL == url }
                try require(controller.rendererAutostarts == false, "Inline renderer enabled automatic playback")
                try await Task.sleep(for: .milliseconds(1200))
                controller.view.layoutSubtreeIfNeeded()
                if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try await Task.detached { try data.write(to: owned.appendingPathComponent("inline-render-\(index).png"), options: .withoutOverwriting) }.value
                    }
                }
                do {
                    try await GlassVerification.captureOwnedWindow(window,
                        to: owned.appendingPathComponent("inline-render-\(index)-compositor.png"))
                    exactWindowCaptures += 1
                } catch {
                    // Preserve the view-cache evidence and report the capture
                    // limit. Never widen capture to the desktop or other apps.
                }
                controller.endSession()
                try require(controller.hasReleasedSession, "Native renderer did not close/release on session end")
            }
            let after = try await Task.detached { try [text, png, pdf].map { try Data(contentsOf: $0) } }.value
            try require(before == after, "Explicit native previews changed generated source bytes")
            checks.append("Explicit generated text/PNG/PDF native Quick Look admission has autostart off, unchanged fixture bytes and close/recreate cleanup; retained view-cache and \(exactWindowCaptures) of 3 exact owned-window compositor captures require separate renderer fidelity/control inspection")
        } else {
            checks.append("Native inline body rendering was not exercised; generated-fixture renderer qualification requires explicit opt-in")
        }
        controller.setEnabled(false)
        browser.suspendBrowser()
        return checks
    }

    private static func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try require(condition(), message)
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UIVerification.Failure(message: message) }
    }
}
#endif
