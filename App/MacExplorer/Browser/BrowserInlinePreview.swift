import AppKit
import Darwin
import ExplorerCore
import QuickLookUI

/// The first inline renderer deliberately admits a finite set of common types.
/// Quick Look is an OS renderer, not an app-owned sandbox or read-only editor.
protocol InlinePreviewSelectionReading: Sendable {
    func prepare(_ entry: FileEntry) async throws -> InlinePreviewSelectionReader.Decision
}

actor InlinePreviewSelectionReader: InlinePreviewSelectionReading {
    static let supportedExtensions: Set<String> = ["txt", "png", "jpg", "jpeg", "pdf"]
    enum Decision: Equatable, Sendable {
        case eligible
        case metadataOnly(String)
    }

    func prepare(_ entry: FileEntry) throws -> Decision {
        try Task.checkCancellation()
        let activity = try ApplicationFileActivity.gate.begin()
        defer { withExtendedLifetime(activity) {} }
        try Task.checkCancellation()
        guard entry.url.isFileURL, entry.url.host == nil || entry.url.host == "" || entry.url.host == "localhost",
              entry.url.user == nil, entry.url.password == nil, entry.url.query == nil, entry.url.fragment == nil else {
            return .metadataOnly("Only local file paths are eligible for inline preview.")
        }
        guard entry.kind == .file else { return .metadataOnly("Folders, packages, links and special items show metadata only.") }
        guard Self.supportedExtensions.contains(entry.url.pathExtension.lowercased()) else {
            return .metadataOnly("Inline preview currently supports plain text, PNG, JPEG and PDF. This item shows metadata only.")
        }
        // The URL sent to Quick Look must have no symlink ancestor. These are
        // metadata checks only; no body, directory traversal or alias resolution.
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var observed = stat()
        for component in entry.url.pathComponents.dropFirst() {
            try Task.checkCancellation()
            current.appendPathComponent(component)
            let result = current.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &observed) } ?? -1 }
            guard result == 0, observed.st_mode & S_IFMT != S_IFLNK else {
                return .metadataOnly("This item is unavailable or has a symbolic link in its path.")
            }
        }
        guard observed.st_mode & S_IFMT == S_IFREG else { return .metadataOnly("This item is no longer an ordinary file.") }
        guard observed.st_flags & UInt32(SF_DATALESS) == 0 else {
            return .metadataOnly("This item is a cloud placeholder. Inline preview does not request a download.")
        }
        let metadata: URLResourceValues
        do {
            metadata = try entry.url.resourceValues(forKeys: [.isAliasFileKey, .isPackageKey, .isRegularFileKey,
                                                               .isReadableKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        } catch { return .metadataOnly("This item's preview eligibility could not be verified.") }
        guard metadata.isAliasFile == false, metadata.isPackage != true, metadata.isRegularFile == true,
              metadata.isReadable == true else {
            return .metadataOnly("Aliases, packages and inaccessible items show metadata only.")
        }
        if metadata.isUbiquitousItem == true, metadata.ubiquitousItemDownloadingStatus != .current {
            return .metadataOnly("This cloud item is not confirmed current on this Mac. Inline preview does not request a download.")
        }
        try Task.checkCancellation()
        var latest = stat()
        let result = entry.url.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &latest) } ?? -1 }
        guard result == 0, observed.st_dev == latest.st_dev, observed.st_ino == latest.st_ino,
              observed.st_size == latest.st_size, observed.st_mtimespec.tv_sec == latest.st_mtimespec.tv_sec,
              observed.st_mtimespec.tv_nsec == latest.st_mtimespec.tv_nsec,
              latest.st_flags & UInt32(SF_DATALESS) == 0 else {
            return .metadataOnly("This item changed while its preview was being prepared. Select it again to retry.")
        }
        if let size = entry.byteCount, size != latest.st_size {
            return .metadataOnly("This item's metadata changed. Refresh the folder before previewing it.")
        }
        let modified = Date(timeIntervalSince1970: Double(latest.st_mtimespec.tv_sec) + Double(latest.st_mtimespec.tv_nsec) / 1_000_000_000)
        if let expected = entry.modifiedAt, expected != modified {
            return .metadataOnly("This item's metadata changed. Refresh the folder before previewing it.")
        }
        return .eligible
    }
}

@MainActor
final class BrowserInlinePreviewController {
    let view = NSView()
    private(set) var isEnabled = false
    private(set) var state = State.disabled
    enum State: Equatable { case disabled, empty, preparing, metadataOnly, previewing }
    private let title = label("Preview", size: 14, weight: .semibold)
    private let details = NSTextField(wrappingLabelWithString: "")
    private let explanation = NSTextField(wrappingLabelWithString: "Enable Preview to inspect the active selection.")
    private let rendererHost = NSView()
    private let reader: any InlinePreviewSelectionReading
    private var renderer: QLPreviewView?
    private var preparation: Task<Void, Never>?
    private var reading: Task<InlinePreviewSelectionReader.Decision, Error>?
    private var desired: Request?
    private var revision = UUID()
    private var access: FileAccessLifetimes?
    private var context: Context?

    private struct Context: Equatable {
        let browser: ObjectIdentifier
        let tab: UUID
        let visit: UUID
        let presentation: UUID
        let entry: FileEntry
    }
    private struct Request {
        weak var browser: BrowserViewController?
        let context: Context
        let revision: UUID
    }

    init(reader: any InlinePreviewSelectionReading = InlinePreviewSelectionReader()) {
        self.reader = reader
        details.font = .systemFont(ofSize: 11)
        details.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        view.setAccessibilityLabel("Active pane preview")
        for child in [title, details, explanation, rendererHost] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            details.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            details.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            details.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            explanation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            explanation.topAnchor.constraint(equalTo: details.bottomAnchor, constant: 10),
            rendererHost.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            rendererHost.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            rendererHost.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 10),
            rendererHost.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        endSession()
    }

    func updateSelection(from browser: BrowserViewController) {
        guard isEnabled else { return }
        let selected = browser.orderedSelectedURLs(upTo: 2)
        guard !browser.isBrowserSuspended, !browser.isMetadataAccessQualification, !browser.isLoading,
              selected.count == 1, let url = selected.first, let row = browser.rowsByURL[url],
              browser.displayedEntries.indices.contains(row) else {
            endSession()
            return
        }
        let entry = browser.displayedEntries[row]
        let next = Context(browser: ObjectIdentifier(browser), tab: browser.activeID, visit: browser.sessionID,
                           presentation: browser.filePresentationID, entry: entry)
        guard next != context else { return }
        releaseResources()
        context = next
        title.stringValue = entry.name
        let kind = entry.kind == .file ? (entry.filenameExtension?.uppercased().appending(" file") ?? "File") : entry.kind.rawValue.capitalized
        let size = entry.byteCount.map { FileSizeText.string($0) } ?? "Size unavailable"
        details.stringValue = kind + " · " + size
        explanation.stringValue = "Preparing preview…"
        state = .preparing
        desired = .init(browser: browser, context: next, revision: revision)
        if preparation == nil {
            // Ownership ends at actual return, not when cancellation is requested.
            // Selection storms retain one latest request behind this one owner.
            preparation = Task { [self] in await prepareLoop() }
        }
    }

    private func prepareLoop() async {
        defer { reading = nil; preparation = nil }
        while isEnabled, let request = desired {
            desired = nil
            // Debounce before acquiring access or queuing native metadata work.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { continue }
            guard let browser = request.browser, isCurrent(request.context, token: request.revision, browser: browser) else { continue }
            let entry = request.context.entry
            let lifetime = await browser.accessLifetime(for: [entry.url])
            guard isCurrent(request.context, token: request.revision, browser: browser) else { continue }
            let task = Task { [reader] in try await reader.prepare(entry) }
            reading = task
            do {
                let decision = try await task.value
                guard isCurrent(request.context, token: request.revision, browser: browser) else { continue }
                switch decision {
                case .metadataOnly(let reason):
                    explanation.stringValue = reason
                    state = .metadataOnly
                case .eligible:
                    access = lifetime
                    guard let preview = QLPreviewView(frame: rendererHost.bounds, style: .compact) else {
                        access = nil
                        explanation.stringValue = "The native preview renderer is unavailable."
                        state = .metadataOnly
                        continue
                    }
                    preview.autostarts = false
                    preview.shouldCloseWithWindow = false
                    renderer = preview
                    pin(preview, inside: rendererHost)
                    explanation.stringValue = "Native Quick Look preview"
                    state = .previewing
                    preview.previewItem = entry.url as NSURL
                }
            } catch {
                guard isCurrent(request.context, token: request.revision, browser: browser) else { continue }
                explanation.stringValue = "Preview could not be prepared. Turn Preview off and on to try again."
                state = .metadataOnly
            }
            reading = nil
        }
    }

    /// Release the current body renderer/access immediately. Enablement remains
    /// session-only so the next explicit active selection can prepare afresh.
    func endSession() {
        releaseResources()
        title.stringValue = "Preview"
        details.stringValue = ""
        explanation.stringValue = isEnabled ? "Select one file in the active pane." : "Enable Preview to inspect the active selection."
        state = isEnabled ? .empty : .disabled
    }

    private func releaseResources() {
        revision = UUID()
        desired = nil
        reading?.cancel()
        context = nil
        // close() releases renderer state; a closed QLPreviewView is never reused.
        renderer?.previewItem = nil
        renderer?.close()
        renderer?.removeFromSuperview()
        renderer = nil
        access = nil
    }

    private func isCurrent(_ expected: Context, token: UUID, browser: BrowserViewController) -> Bool {
        !Task.isCancelled && isEnabled && revision == token && context == expected
            && !browser.isBrowserSuspended && !browser.isMetadataAccessQualification
            && browser.activeID == expected.tab && browser.sessionID == expected.visit
            && browser.filePresentationID == expected.presentation && browser.orderedSelectedURLs(upTo: 2) == [expected.entry.url]
    }

    #if DEBUG
    var contextNameForVerification: String? { context?.entry.name }
    var hasReleasedSession: Bool { renderer == nil && preparation == nil && reading == nil && desired == nil && access == nil && context == nil }
    var rendererAutostarts: Bool? { renderer?.autostarts }
    var renderedURL: URL? { renderer?.previewItem?.previewItemURL ?? nil }
    #endif
}
