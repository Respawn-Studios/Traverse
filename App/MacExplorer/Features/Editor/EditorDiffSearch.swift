import FileOperations
import SwiftUI

struct EditorDiffSearchHit: Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id = UUID()
    let file: Int
    let name: String
    let snapshot: EditorComparisonPlan.Snapshot
    let side: EditorComparisonPlan.Side
    let line: Int
    let range: NSRange
    let preview: String
    let emphasis: NSRange?
    var description: String { "<diff search result>" }
    var debugDescription: String { description }
}

/// A search is explicit and scoped to the compared files already admitted by
/// the review. Loaded documents are released one pair at a time.
@MainActor final class EditorDiffSearch: ObservableObject {
    enum Scope: String, CaseIterable, Sendable { case changes = "Changed Lines", entireFile = "All Lines" }
    enum Versions: String, CaseIterable, Sendable { case both = "Both Versions", before = "Before", after = "After" }

    struct SkippedFile: Identifiable {
        enum Reason: String { case unavailable = "Text unavailable", grouped = "Changes grouped. Try All Lines." }
        let id: Int
        let name: String
        let reason: Reason
    }

    struct Report {
        var hits: [EditorDiffSearchHit] = []
        private(set) var skipped: [SkippedFile] = []
        var checked = 0
        var unavailable = 0
        var grouped = 0
        var nextFile = 0
        var clippedMatches = false
        var stopped = false
        let comparable: Int
        let excluded: Int

        init(comparable: Int, excluded: Int) {
            self.comparable = comparable
            self.excluded = excluded
            unavailable = excluded
        }

        var total: Int { comparable + excluded }
        var remaining: Int { comparable - nextFile }
        var canContinue: Bool { remaining > 0 && hits.count < EditorDiffSearch.maximumHits }
        var limited: Bool { remaining > 0 || clippedMatches }
        var unlistedSkips: Int { unavailable + grouped - excluded - skipped.count }

        mutating func skip(_ file: Int, named name: String, because reason: SkippedFile.Reason) {
            switch reason {
            case .unavailable: unavailable += 1
            case .grouped: grouped += 1
            }
            if skipped.count < 32 { skipped.append(.init(id: file, name: name, reason: reason)) }
        }

        var summary: String {
            let count = hits.count
            return "\(count) \(count == 1 ? "match" : "matches") · \(checked) of \(total) \(total == 1 ? "file" : "files") searched"
        }
        var coverage: String {
            var reasons: [String] = []
            if stopped { reasons.append("Stopped") }
            if unavailable > 0 { reasons.append("\(unavailable) skipped") }
            if grouped > 0 { reasons.append("\(grouped) grouped") }
            if remaining > 0 { reasons.append("\(remaining) \(remaining == 1 ? "file" : "files") left") }
            if clippedMatches || remaining > 0 && !canContinue { reasons.append("Match limit reached") }
            return reasons.joined(separator: " · ")
        }
    }

    private enum Pair: Sendable {
        case displayed(EditorComparisonPlan)
        case captured(EditorComparisonCapture, EditorComparisonWhitespace)

        var textBytes: Int {
            switch self {
            case .displayed(let plan): plan.before.text.utf8.count + plan.current.text.utf8.count
            case .captured(let pair, _): pair.left.text.utf8.count + pair.right.text.utf8.count
            }
        }
    }
    private typealias Source = (name: String, read: @MainActor () async throws -> Pair)

    private static let maximumFiles = 48
    private static let maximumBytes = 8 << 20
    nonisolated private static let maximumHits = 240
    private static let maximumHitsPerFileInList = 40
    @Published private(set) var visible = false
    @Published private(set) var focusID = UUID()
    @Published private(set) var progress: String?
    @Published private(set) var report: Report?
    @Published var selected: EditorDiffSearchHit.ID?
    @Published var query = "" { didSet { if query != oldValue { invalidate() } } }
    @Published var scope = Scope.changes { didSet { if scope != oldValue { invalidate() } } }
    @Published var versions = Versions.both { didSet { if versions != oldValue { invalidate() } } }
    @Published var matchesCase = false { didSet { if matchesCase != oldValue { invalidate() } } }
    @Published var wholeWords = false { didSet { if wholeWords != oldValue { invalidate() } } }
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var runningGeneration: UUID?
    private var queuedSearch: (@MainActor () -> Void)?
    var isRunning: Bool { task != nil }
    var queryTooLong: Bool { query.utf8.count > EditorFindPlan.maximumQueryBytes }
    var canSearch: Bool {
        !query.isEmpty && !queryTooLong && (!isRunning || runningGeneration != generation && queuedSearch == nil)
    }

    isolated deinit { task?.cancel() }

    func show() { focusID = UUID(); visible = true }
    func dismiss() {
        visible = false
        query = ""
        invalidate()
    }
    func invalidate() {
        generation = UUID()
        stop()
        report = nil
        selected = nil
    }
    func stop() {
        queuedSearch = nil
        guard let task else { return }
        task.cancel()
        progress = runningGeneration == generation ? "Stopping search…" : "Finishing previous search…"
    }
    func closeAndDrain() async {
        dismiss()
        await task?.value
    }

    var selectedHit: EditorDiffSearchHit? { report?.hits.first { $0.id == selected } }
    func contains(_ hit: EditorDiffSearchHit) -> Bool { visible && report?.hits.contains { $0.id == hit.id } == true }

    func moveSelection(_ offset: Int) -> Bool {
        guard !isRunning, let hits = report?.hits, !hits.isEmpty else { return false }
        let index = hits.firstIndex(where: { $0.id == selected }) ?? (offset > 0 ? -1 : hits.count)
        selected = hits[min(hits.count - 1, max(0, index + offset))].id
        return true
    }

    func adjacentHit(toward direction: EditorJumpDirection) -> EditorDiffSearchHit? {
        guard visible, !isRunning, let hits = report?.hits, hits.count > 1 else { return nil }
        let index = hits.firstIndex { $0.id == selected } ?? 0
        return hits[(index + direction.offset + hits.count) % hits.count]
    }

    func find(in files: EditorComparisonWindow.FileList, whitespace: EditorComparisonWhitespace,
              displayed: (index: Int, name: String, plan: EditorComparisonPlan)?) {
        find(count: files.count, excluded: files.excludedCount) { index in
            if let displayed, displayed.index == index {
                return (displayed.name, { .displayed(displayed.plan) })
            }
            let entry = files.entryAt(index)
            return (entry.labels.source, { .captured(try await entry.read(), whitespace) })
        }
    }

    func find(in plan: EditorComparisonPlan, named name: String, excluded: Int) {
        find(count: 1, excluded: excluded) { _ in (name, { .displayed(plan) }) }
    }

    private func find(count: Int, excluded: Int, sourceAt: @escaping @MainActor (Int) -> Source) {
        guard visible, canSearch else { return }
        if isRunning {
            queuedSearch = { [weak self] in self?.find(count: count, excluded: excluded, sourceAt: sourceAt) }
            progress = "Finishing previous search. Next search queued…"
            return
        }
        let query = self.query, scope = self.scope, versions = self.versions, binding = generation
        let options = EditorFindOptions(matchesCase: matchesCase, matchMode: wholeWords ? .wholeWord : .contains)
        let previous = report.flatMap { $0.canContinue ? $0 : nil }
        let selectedBefore = previous == nil ? nil : selected
        if previous == nil { report = nil; selected = nil }
        progress = "Searching compared files…"
        runningGeneration = binding
        task = Task { [weak self] in
            var result = previous ?? Report(comparable: count, excluded: excluded)
            result.stopped = false
            var availableBytes = Self.maximumBytes
            let deadline = ContinuousClock.now + .seconds(30)
            let end = min(count, result.nextFile + Self.maximumFiles)
            let fileLimit = count == 1 ? Self.maximumHits : Self.maximumHitsPerFileInList
            for index in result.nextFile..<end {
                if Task.isCancelled { break }
                let limit = min(fileLimit, Self.maximumHits - result.hits.count)
                guard limit > 0, availableBytes > 0, ContinuousClock.now < deadline else { break }
                self?.progress = "Searching file \(index + 1) of \(count)…"
                let source = sourceAt(index)
                do {
                    let pair = try await source.read()
                    let name = source.name
                    try Task.checkCancellation()
                    let bytes = pair.textBytes
                    guard bytes <= availableBytes else { break }
                    availableBytes -= bytes
                    let work = Task.detached(priority: .userInitiated) {
                        try Self.matches(in: pair, file: index, name: name, query: query, options: options,
                            changedOnly: scope == .changes, versions: versions, limit: limit)
                    }
                    let found = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    try Task.checkCancellation()
                    if let found {
                        result.checked += 1
                        result.hits.append(contentsOf: found.hits)
                        result.clippedMatches = result.clippedMatches || !found.complete
                    } else { result.skip(index, named: name, because: .grouped) }
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        result.stopped = true
                        break
                    }
                    result.skip(index, named: source.name, because: .unavailable)
                }
                result.nextFile = index + 1
            }
            guard let self else { return }
            task = nil; runningGeneration = nil; progress = nil
            if let next = queuedSearch {
                queuedSearch = nil
                next()
                return
            }
            guard generation == binding, visible else { return }
            result.stopped = result.remaining > 0 && (result.stopped || Task.isCancelled)
            report = result
            selected = selectedBefore ?? result.hits.first?.id
        }
    }

    private nonisolated static func matches(in pair: Pair, file: Int, name: String, query: String,
                                             options: EditorFindOptions, changedOnly: Bool, versions: Versions, limit: Int) throws
        -> (hits: [EditorDiffSearchHit], complete: Bool)? {
        let before: TextDocumentValue, current: TextDocumentValue
        let leftLines: EditorLineIndex, rightLines: EditorLineIndex
        let snapshot: EditorComparisonPlan.Snapshot
        var changed: (before: [NSRange], current: [NSRange])?
        switch pair {
        case .displayed(let plan):
            before = plan.before; current = plan.current
            snapshot = plan.snapshot
            leftLines = plan.beforeIndex; rightLines = plan.currentIndex
            if changedOnly {
                guard !plan.grouped else { return nil }
                changed = (plan.changes.map(\.beforeRange).filter { $0.length > 0 },
                           plan.changes.map(\.currentRange).filter { $0.length > 0 })
            }
        case .captured(let input, let whitespace):
            before = try TextDocumentValue.edited(input.left.text, format: input.left.format)
            current = try TextDocumentValue.edited(input.right.text, format: input.right.format)
            snapshot = .init(before, current)
            leftLines = EditorLineIndex(before.text); rightLines = EditorLineIndex(current.text)
            if changedOnly {
                guard let ranges = try EditorTextComparison.searchableRanges(in: before.text, index: leftLines,
                    and: current.text, index: rightLines, whitespace: whitespace, cancelled: { Task.isCancelled }) else { return nil }
                changed = ranges
            }
        }
        let ranges = changed ?? ([NSRange(location: 0, length: leftLines.length)], [NSRange(location: 0, length: rightLines.length)])
        let left = before.text as NSString, right = current.text as NSString
        let leftMatches = versions == .after ? (ranges: [NSRange](), complete: true)
            : try EditorFindPlan.matchingRanges(in: left, query: query, options: options, scopes: ranges.before,
                limit: limit, cancelled: { Task.isCancelled })
        let rightMatches = versions == .before ? (ranges: [NSRange](), complete: true)
            : try EditorFindPlan.matchingRanges(in: right, query: query, options: options, scopes: ranges.current,
                limit: limit, cancelled: { Task.isCancelled })
        let complete = leftMatches.complete && rightMatches.complete
            && leftMatches.ranges.count + rightMatches.ranges.count <= limit
        // Give each version room when both have many matches. A version with
        // fewer matches leaves more places for the other one.
        let leftLimit = min(leftMatches.ranges.count, max((limit + 1) / 2, limit - rightMatches.ranges.count))
        var hits: [EditorDiffSearchHit] = []
        for (side, source, lines, found) in [
            (EditorComparisonPlan.Side.before, left, leftLines, leftMatches.ranges.prefix(leftLimit)),
            (.current, right, rightLines, rightMatches.ranges.prefix(limit - leftLimit))
        ] {
            for range in found {
                guard let excerpt = EditorFindPlan.excerpt(for: range, in: source, lines: lines) else { continue }
                hits.append(.init(file: file, name: name, snapshot: snapshot, side: side, line: excerpt.line, range: range,
                    preview: excerpt.text, emphasis: excerpt.highlight))
            }
        }
        return (hits, complete)
    }
}

struct EditorDiffSearchBar: View {
    @ObservedObject var search: EditorDiffSearch
    let title: String
    let searchFiles: () -> Void
    let open: (EditorDiffSearchHit) -> Void
    @Environment(\.interfaceScale) private var scale
    @State private var showsCoverage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                NativeQueryField(text: $search.query, identifier: "diff-search-query", placeholder: title,
                    style: .focusedSearch, restoresPriorFocus: true) { command in
                    switch command {
                    case .submit:
                        if let hit = search.selectedHit { open(hit) }
                        else { searchFiles() }
                        return true
                    case .cancel: search.dismiss(); return true
                    case .up: return search.moveSelection(-1)
                    case .down: return search.moveSelection(1)
                    }
                }.frame(height: 27 * scale).id(search.focusID)
                Picker("Search in", selection: $search.scope) {
                    ForEach(EditorDiffSearch.Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize()
                Picker("Versions to Search", selection: $search.versions) {
                    ForEach(EditorDiffSearch.Versions.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize().help("Choose which versions to search")
                Toggle(isOn: $search.matchesCase) {
                    Label("Match Case", systemImage: "textformat").labelStyle(.iconOnly)
                }.toggleStyle(.button).help("Match Case")
                Toggle(isOn: $search.wholeWords) {
                    Label("Whole Words", systemImage: "textformat.abc").labelStyle(.iconOnly)
                }.toggleStyle(.button).help("Whole Words")
                if search.isRunning && !search.canSearch {
                    Button("Stop", action: search.stop)
                } else {
                    Button(search.report?.canContinue == true ? "Search More" : "Find", action: searchFiles)
                        .disabled(!search.canSearch)
                }
                Button("Close Diff Search", systemImage: "xmark", action: search.dismiss).labelStyle(.iconOnly)
            }
            Group {
                if search.queryTooLong {
                    Text("Use a shorter search phrase.")
                } else if let progress = search.progress {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(progress) }
                } else if let report = search.report {
                    HStack(spacing: 8) {
                        Text(report.summary)
                        Spacer(minLength: 0)
                        Text(report.coverage).lineLimit(1).help(report.coverage)
                        if report.unavailable > 0 || report.grouped > 0 {
                            Button("Search Coverage", systemImage: "info.circle") { showsCoverage.toggle() }
                                .labelStyle(.iconOnly).buttonStyle(.plain).help("Show skipped files")
                                .popover(isPresented: $showsCoverage, arrowEdge: .bottom) { coverage(report) }
                        }
                    }
                }
            }.interfaceFont(.caption).foregroundStyle(.secondary).frame(height: 19 * scale)
            if let report = search.report, !report.hits.isEmpty {
                results(report.hits).disabled(search.isRunning)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("diff-search")
        .onChange(of: search.report == nil) { _, empty in if empty { showsCoverage = false } }
    }

    private func coverage(_ report: EditorDiffSearch.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Skipped during search").interfaceFont(.callout.weight(.semibold))
                Spacer(minLength: 0)
                Button("Close Coverage", systemImage: "xmark") { showsCoverage = false }.labelStyle(.iconOnly)
            }
            if report.excluded > 0 {
                Text("\(report.excluded) \(report.excluded == 1 ? "item was" : "items were") outside the text comparison.")
                    .foregroundStyle(.secondary)
            }
            if !report.skipped.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.skipped) { file in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).lineLimit(1).truncationMode(.middle).help(file.name)
                                Text(file.reason.rawValue).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(CGFloat(report.skipped.count) * 41, 190) * scale)
            }
            if report.unlistedSkips > 0 { Text("Plus \(report.unlistedSkips) more.").foregroundStyle(.secondary) }
        }.interfaceFont(.caption).padding(12).frame(width: min(420, 300 * scale))
    }

    private func results(_ hits: [EditorDiffSearchHit]) -> some View {
        let rowHeight = 20 * scale
        return ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hits) { hit in
                        Button { open(hit) } label: {
                            HStack(spacing: 6) {
                                Label(String(hit.line), systemImage: hit.side == .before ? "minus.circle" : "plus.circle")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("\(hit.side == .before ? "Before" : "After"), line \(hit.line)")
                                    .fixedSize()
                                Text(hit.name).fontWeight(.medium).truncationMode(.middle)
                                Rectangle().fill(.tertiary).frame(width: 1, height: 9 * scale).accessibilityHidden(true)
                                Text(excerpt(hit)).foregroundStyle(.secondary)
                            }.interfaceFont(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: rowHeight).padding(.horizontal, 5)
                                .background(search.selected == hit.id ? Color.accentColor.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .help(hit.name + "\n" + hit.preview)
                            .id(hit.id)
                    }
                }
            }.frame(height: CGFloat(min(hits.count, 5)) * rowHeight)
                .onChange(of: search.selected) { _, value in if let value { scroll.scrollTo(value) } }
        }
    }

    private func excerpt(_ hit: EditorDiffSearchHit) -> AttributedString {
        var value = AttributedString(hit.preview)
        if let range = hit.emphasis, let swiftRange = Range(range, in: hit.preview),
           let chosen = Range(swiftRange, in: value) {
            value[chosen].inlinePresentationIntent = .stronglyEmphasized
            value[chosen].foregroundColor = .primary
        }
        return value
    }
}
