#if DEBUG
    import AppKit
    import CryptoKit
    import Darwin
    import ExplorerCore
    import LocalStorage

    @MainActor enum ArchiveTextPreviewVerification {
        static func run(root: URL, browser: BrowserViewController, capture: Bool) async throws -> [String: Any] {
            let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/b09-text-preview")
            try check(
                root.deletingLastPathComponent().path == base.path && root.resolvingSymlinksInPath().path == root.path
                    && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                "ZIP text QA needs its reserved generated case")
            let admitted = try await Task.detached { () -> Bool in
                guard
                    let bytes = try BrowserSnapshotFile(directory: root, name: "reservation.json", maximumBytes: 4096)
                        .read(),
                    let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                else { return false }
                return fields["packet"] as? String == "b09-text-preview-v1"
                    && fields["action"] as? String == "native-100k"
            }.value
            try check(admitted, "Native ZIP preview case is not reserved")
            let source = root.appendingPathComponent("source/Generated.zip")
            let before = try await digest(source)
            browser.permitsBackgroundVerification = true
            browser.settings.reviewsRecoveryAtStartup = false
            browser.settings.autoRefreshFolders = false
            browser.settings.navigationStyle = .glass
            browser.settings.appearance = .dark
            browser.settings.folderSummariesEnabled = false
            browser.navigate(to: .directory(root.appendingPathComponent("source")))
            try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil }
            browser.reloadFileRows(preserving: [source])
            browser.browseZIP(nil)
            guard let archive = ApplicationZIPBrowser.shared.controller else {
                throw UIVerification.Failure(message: "Native archive missing")
            }
            let model = archive.model
            try await wait { !model.isLoading && !model.isPaging && model.page != nil }
            try check(
                model.summary?.files == 100_000 && model.page?.items.count == 256 && !model.isPreviewing,
                "Native archive is not a bounded metadata-only 100k view")
            try await wait { model.rowsForVerification?.table.numberOfRows == 256 }
            guard let rows = model.rowsForVerification else {
                throw UIVerification.Failure(message: "Native archive row surface missing")
            }
            try check(
                !rows.table.usesAutomaticRowHeights && rows.table.rowHeight == 26,
                "Archive table did not retain fixed native row geometry")
            print("MAC_EXPLORER_ZIP_TEXT_STAGE archive-ready")
            guard let folder = model.page?.items.first(where: { $0.name == "Docs" })?.folder else {
                throw UIVerification.Failure(message: "Generated Docs folder absent")
            }
            guard let folderRow = model.page?.items.firstIndex(where: { $0.folder == folder }) else {
                throw UIVerification.Failure(message: "Generated folder row absent")
            }
            rows.table.selectRowIndexes(IndexSet(integer: folderRow), byExtendingSelection: false)
            try sendKey(to: rows.table, code: 36, text: "\r")
            try await wait { !model.isPaging && model.page?.folder == folder && rows.table.numberOfRows == 4 }
            print("MAC_EXPLORER_ZIP_TEXT_STAGE docs-ready")
            guard let first = model.page?.items.first(where: { $0.name == "Readme.txt" }),
                let second = model.page?.items.first(where: { $0.name == "Second.txt" }),
                let binary = model.page?.items.first(where: { $0.name == "Binary.bin" }),
                let boundary = model.page?.items.first(where: { $0.name == "Limit.txt" })
            else {
                throw UIVerification.Failure(message: "Generated preview members absent")
            }
            let preview = model.textPreviewForVerification
            var last = ProcessInfo.processInfo.systemUptime
            var gaps: [Double] = []
            let pulse = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                    if Task.isCancelled { break }
                    let now = ProcessInfo.processInfo.systemUptime
                    gaps.append((now - last) * 1000)
                    last = now
                }
            }
            defer { pulse.cancel() }
            var timings: [Double] = []
            func show(_ item: ZIPArchiveItem, throughRows: Bool = false) async throws {
                if throughRows {
                    guard let row = model.page?.items.firstIndex(where: { $0.id == item.id }) else {
                        throw UIVerification.Failure(message: "Generated preview row unavailable")
                    }
                    rows.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                } else {
                    model.selection = [item.id]
                }
                await Task.yield()
                try check(model.canPreviewSelected, "Explicit native text action unavailable")
                try check(model.selection == [item.id], "Native archive selection was not synchronized")
                let began = ProcessInfo.processInfo.systemUptime
                if throughRows { try sendKey(to: rows.table, code: 49, text: " ") } else { model.previewSelected() }
                try await wait {
                    !model.isPreparingSelection && !model.isPreviewing && preview.windowForVerification != nil
                }
                timings.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
            }
            try await show(first, throughRows: true)
            print("MAC_EXPLORER_ZIP_TEXT_STAGE readme-loaded")
            try check(
                preview.textForVerification?.contains("Generated read-only ZIP preview") == true
                    && model.contentReport == nil,
                "Selected preview is missing or incorrectly blessed the whole archive")
            guard let window = preview.windowForVerification else {
                throw UIVerification.Failure(message: "Native text window absent")
            }
            window.title = "Generated ZIP text preview · " + root.lastPathComponent.prefix(8)
            preview.findForVerification()
            try check(window.firstResponder is NSTextView, "Native Find failed to focus the selected text")
            try check(preview.plainTextPolicyForVerification, "Read-only document checking/rendering policy differs")
            print("MAC_EXPLORER_ZIP_TEXT_STAGE find-shown")
            window.contentView?.layoutSubtreeIfNeeded()
            let image = try renderContent(window)
            try await Task.detached {
                try image.write(
                    to: root.appendingPathComponent("evidence/preview-content.png"), options: .withoutOverwriting)
            }.value
            if capture {
                try await GlassVerification.captureOwnedWindow(
                    window, to: root.appendingPathComponent("evidence/preview-window.png"))
            }
            browser.settings.navigationStyle = .solid
            try await Task.sleep(for: .milliseconds(20))
            try check(
                (window.contentViewController as? ToolWindowChrome)?.surface.isGlassEnabled == false,
                "Preview ignored Solid style")
            try check(
                (rows.table.headerView as? FileTableHeaderView)?.usesGlass == false,
                "Archive row header ignored Solid style")
            browser.settings.navigationStyle = .glass
            browser.settings.motion.mode = .off
            try await Task.sleep(for: .milliseconds(20))
            try check(
                (window.contentViewController as? ToolWindowChrome)?.motion.mode == .off,
                "Preview ignored Off motion")
            try await show(binary, throughRows: true)
            try check(
                preview.textForVerification?.isEmpty == true
                    && preview.statusForVerification?.contains("UTF-8") == true,
                "Binary refusal retained stale text")
            try await show(boundary)
            try check(
                preview.textForVerification?.utf8.count == Int(ZIPTextPreview.maximumUTF8Bytes),
                "Native complete-boundary text differs")
            let pending = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            defer { pending.continuation.finish() }
            var held = false
            preview.beforePublicationForVerification = {
                preview.beforePublicationForVerification = nil
                held = true
                for await _ in pending.stream { break }
            }
            model.selection = [first.id]
            model.previewSelected()
            try await wait { held }
            preview.windowForVerification?.performClose(nil)
            model.selection = [second.id]
            model.previewSelected()
            try await wait { !model.isPreparingSelection && preview.windowForVerification != nil }
            try check(
                preview.isReading && preview.textForVerification?.isEmpty == true,
                "A stale native publication escaped close/reopen")
            pending.continuation.yield(())
            try await wait { !model.isPreviewing && preview.textForVerification == "Generated second member.\n" }
            guard let closing = preview.windowForVerification,
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: closing.windowNumber,
                    context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)
            else {
                throw UIVerification.Failure(message: "Generated native key event unavailable")
            }
            try check(
                closing.performKeyEquivalent(with: event) && preview.windowForVerification == nil,
                "Command-W did not close the preview independently")
            model.selection = [first.id]
            model.previewSelected()
            model.stop()
            await model.drain()
            try check(
                !model.isPreviewing && !model.isPreparingSelection,
                "Native admission Stop did not drain selection/read owners")
            model.prepareForVolumeQuiescence()
            await model.drain()
            model.previewSelection([first.id])
            try check(
                !model.isPreviewing && preview.windowForVerification == nil,
                "Quiescence admitted a new text read")
            model.resumeAfterVolumeQuiescence()
            let end = ProcessInfo.processInfo.systemUptime
            await ApplicationZIPBrowser.shared.stopAndDrain()
            let drain = (ProcessInfo.processInfo.systemUptime - end) * 1000
            try check(
                ApplicationZIPBrowser.shared.controller == nil && ApplicationFileActivity.gate.activeCount == 0,
                "Native archive/text retained an actual reader")
            try check(try await digest(source) == before, "Read-only text workflow changed the generated archive")
            try check(
                !FileManager().fileExists(atPath: root.appendingPathComponent("source/Docs").path),
                "Selected preview materialized an archive member")
            try await Task.sleep(for: .milliseconds(30))
            pulse.cancel()
            await pulse.value
            let worst = gaps.max() ?? 0
            try check(
                !gaps.isEmpty && worst <= 250 && drain <= 2000,
                "Complete native preview workload missed responsiveness/drain gates")
            return [
                "passed": true, "members": 100_000, "nativePageRows": 256, "previewMilliseconds": timings,
                "fixedNativeRowGeometry": true, "nativeReturnFolderAndSpacePreview": true,
                "nativeSelectionSynchronized": true,
                "worstNativeGapMilliseconds": worst, "closeDrainMilliseconds": drain, "nativeFind": true,
                "readOnlyPlainText": true, "structuralAppearanceMotion": true, "binaryRefusalClearsText": true,
                "heldPublicationCloseReopen": true, "actualIOCancellation": "separate focused core controls",
                "commandWDispatchedToOwnWindow": true, "admissionStopAndQuiescence": true,
                "sourceUnchanged": true, "filesExtracted": 0, "automaticBodyReads": 0,
                "viewContentRender": true, "compositorCapture": capture, "physicalInput": false,
                "personalArchives": 0, "networkRequests": 0, "minimumOSQualified": false,
            ]
        }
        private static func sendKey(to table: ArchiveMetadataTable, code: UInt16, text: String) throws {
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: table.window?.windowNumber ?? 0,
                    context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
            else { throw UIVerification.Failure(message: "Generated archive key event unavailable") }
            table.keyDown(with: event)
        }
        private static func renderContent(_ window: NSWindow) throws -> Data {
            guard let view = window.contentView else {
                throw UIVerification.Failure(message: "Preview content unavailable")
            }
            let pdf = view.dataWithPDF(inside: view.bounds)
            guard pdf.count <= 4 << 20, let provider = CGDataProvider(data: pdf as CFData),
                let document = CGPDFDocument(provider), let page = document.page(at: 1),
                let context = CGContext(
                    data: nil, width: 820, height: 580, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                throw UIVerification.Failure(message: "Generated view-only render unavailable")
            }
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(.init(x: 0, y: 0, width: 820, height: 580))
            context.concatenate(
                page.getDrawingTransform(
                    .mediaBox, rect: .init(x: 0, y: 0, width: 820, height: 580), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage(),
                let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                png.count <= 2 << 20
            else { throw UIVerification.Failure(message: "Generated view render exceeded its bound") }
            return png
        }
        private static func digest(_ source: URL) async throws -> Data {
            try await Task.detached {
                let lease = try ApplicationFileActivity.gate.begin()
                defer { withExtendedLifetime(lease) {} }
                let descriptor = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
                guard descriptor >= 0 else {
                    throw UIVerification.Failure(message: "Generated ZIP digest source unavailable")
                }
                defer { Darwin.close(descriptor) }
                var facts = stat()
                guard fstat(descriptor, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG, facts.st_uid == geteuid(),
                    facts.st_nlink == 1, facts.st_size >= 0, facts.st_size <= 32 << 20
                else {
                    throw UIVerification.Failure(message: "Generated ZIP digest source is not an owned bounded file")
                }
                var hasher = SHA256()
                var buffer = [UInt8](repeating: 0, count: 65536)
                var total = 0
                while true {
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0, total + max(0, count) <= 32 << 20 else {
                        throw UIVerification.Failure(message: "Generated ZIP digest read failed")
                    }
                    if count == 0 { break }
                    total += count
                    hasher.update(data: Data(buffer.prefix(count)))
                }
                guard total == facts.st_size else {
                    throw UIVerification.Failure(message: "Generated ZIP digest length changed")
                }
                return Data(hasher.finalize())
            }.value
        }
        private static func check(_ condition: Bool, _ message: String) throws {
            try UIVerification.require(condition, message)
        }
        private static func wait(_ condition: () -> Bool) async throws {
            let end = ProcessInfo.processInfo.systemUptime + 20
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < end else {
                    throw UIVerification.Failure(message: "Generated native ZIP text workflow timed out")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
#endif
