import AppKit
import ExplorerCore
import LocalStorage

@MainActor
final class FileIconThumbnails {
    struct Scope: Equatable {
        let folder: URL
        let visit: UUID
    }

    private enum Preview { case image(NSImage), unavailable }
    private static let visibleLimit = 48
    private var scope: Scope?
    private var demand: [FileEntry] = []
    private var previews: [FileEntry: Preview] = [:]
    private var current: FileEntry?
    private var worker: Task<CGImage?, Error>?
    private var pipeline: Task<Void, Never>?

    var load: ((FileEntry, URL) async throws -> CGImage?)?
    var onImage: ((FileEntry, NSImage) -> Void)?

    @discardableResult
    func use(_ next: Scope?) -> Bool {
        guard scope != next else { return false }
        scope = next
        demand = []
        previews = [:]
        worker?.cancel()
        return true
    }

    func update(visible: [FileEntry]) {
        let next = scope == nil ? [] : Array(visible.lazy.filter(LocalFileThumbnail.supports).prefix(Self.visibleLimit))
        guard demand != next else { return }
        demand = next
        let retained = Set(next)
        previews = previews.filter { retained.contains($0.key) }
        if let current, !retained.contains(current) { worker?.cancel() }
        if pipeline == nil, !next.isEmpty { pipeline = Task { [self] in await readVisible() } }
    }

    func image(for entry: FileEntry) -> NSImage? {
        if case .image(let image) = previews[entry] { return image }
        return nil
    }

    private func readVisible() async {
        defer { pipeline = nil }
        while let scope, let entry = demand.first(where: { previews[$0] == nil }), let load {
            current = entry
            let task = Task { try await load(entry, scope.folder) }
            worker = task
            let image = try? await task.value
            worker = nil; current = nil
            guard scope == self.scope, demand.contains(entry) else { continue }
            // A cancelled request may be visible again by the time it drains.
            // Retry that visible request without keeping a failure placeholder.
            guard !task.isCancelled else { continue }
            if let image {
                let thumbnail = NSImage(cgImage: image, size: .zero)
                previews[entry] = .image(thumbnail)
                onImage?(entry, thumbnail)
            } else {
                previews[entry] = .unavailable
            }
        }
    }
}
