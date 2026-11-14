import Foundation

/// A filename observation, never the contents of a manifest or repository.
public enum AnalysisProjectMarker: Int, Comparable, Sendable {
    case git, swift, rust, dart, python, node, go
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var evidence: String {
        switch self {
        case .git: return ".git entry name"
        case .swift: return "Package.swift filename"
        case .rust: return "Cargo.toml filename"
        case .dart: return "pubspec.yaml filename"
        case .python: return "pyproject.toml filename"
        case .node: return "package.json filename"
        case .go: return "go.mod filename"
        }
    }
    static func match(_ path: Data, kind: AnalysisEntryKind) -> Self? {
        let start = path.lastIndex(of: 47).map { path.index(after: $0) } ?? path.startIndex
        let name = path[start...]
        if kind == .directory || kind == .regularFile, name.elementsEqual(".git".utf8) { return .git }
        guard kind == .regularFile else { return nil }
        switch name.count {
        case 6: return name.elementsEqual("go.mod".utf8) ? .go : nil
        case 10: return name.elementsEqual("Cargo.toml".utf8) ? .rust : nil
        case 12: return name.elementsEqual("package.json".utf8) ? .node : name.elementsEqual("pubspec.yaml".utf8) ? .dart : nil
        case 13: return name.elementsEqual("Package.swift".utf8) ? .swift : nil
        case 14: return name.elementsEqual("pyproject.toml".utf8) ? .python : nil
        default: return nil
        }
    }
}

public enum AnalysisCategory: Int, CaseIterable, Sendable {
    case other, buildOutput, dependencies, toolCache, modelStore, appSupport, versionControl, pythonCache, flutterState
    case steamLibrary, developerCache, applicationBundle, systemFiles
    public var title: String {
        switch self {
        case .other: return "Unclassified storage role"
        case .buildOutput: return "Build outputs"
        case .dependencies: return "Dependencies"
        case .toolCache: return "Tool caches"
        case .modelStore: return "Hugging Face cache"
        case .appSupport: return "Application support"
        case .versionControl: return "Version control"
        case .pythonCache: return "Python caches"
        case .flutterState: return "Dart / Flutter tool state"
        case .steamLibrary: return "Steam & games"
        case .developerCache: return "Developer tool data"
        case .applicationBundle: return "Application bundles"
        case .systemFiles: return "System files"
        }
    }
    public var explanation: String {
        switch self {
        case .other: return "No supported, specific directory-layout rule matched."
        case .buildOutput: return "Conventional build directory within an observed project."
        case .dependencies: return "Recognized dependency-directory name; package contents were not read."
        case .toolCache: return "Recognized tool-cache directory layout. This does not establish that deletion is safe."
        case .modelStore: return "Conventional Hugging Face cache layout, which can contain models, datasets and Spaces. Repository type, model identity and active use are not verified."
        case .appSupport: return "Observed Library/Application Support or supported application-container layout; app ownership and purpose are not verified."
        case .versionControl: return "Observed .git directory layout; repository contents were not interpreted."
        case .pythonCache: return "Observed __pycache__, .pytest_cache or .mypy_cache directory. Active use and cleanup safety are unknown."
        case .flutterState: return "Observed .dart_tool or .pub-cache directory layout. This may contain required tool state or dependencies."
        case .steamLibrary: return "Observed steamapps/common directory layout. Game/tool identity and active use were not verified; manifests were not read."
        case .developerCache: return "Conventional developer-tool layout, including caches and supported Xcode DerivedData. It can contain indexes, logs and build products; cleanup safety was not inspected."
        case .applicationBundle: return "Observed .app directory name; installation, signature and active use were not verified."
        case .systemFiles: return "Observed files on the verified startup System source. Shared or snapshot blocks are not attributed exclusively."
        }
    }
}

public struct AnalysisAttributionSlice: Sendable {
    public let title: String
    public let explanation: String
    public let bytes: AnalysisByteSubtotals
    public let files: UInt64
    /// Set only for an observed project, not for a guessed external location.
    public let folder: AnalysisFolderID?
    public internal(set) var storedTarget: StoredAnalysisDrillTarget? = nil
    public internal(set) var purposeTarget: StoredPurposeJourneyTarget? = nil
}

/// A compact display projection. At most twelve named projects are retained;
/// all other project scopes remain included in a labelled remainder. It does
/// not retain the folder snapshot, read a path, or grant cleanup authority.
public struct AnalysisAttributionReport: Sendable {
    public let categories: [AnalysisAttributionSlice]
    public let fileTypes: [AnalysisAttributionSlice]
    public let projects: [AnalysisAttributionSlice]
    public let projectCount: Int
    public let isComplete: Bool
    public let crossFolderHardlinkObjects: UInt64
    public internal(set) var crossFolderHardlinkCountIsKnown = true
    public internal(set) var hasLayoutAttribution = true
    /// A committed scan prefix, never a final classification or drill authority.
    public internal(set) var isProvisional = false

    public static func make(_ snapshot: StorageAnalysisSnapshot, scopePath: String,
                            rankingMetric: AnalysisByteMetric = .dataLogical) throws -> Self {
        let folders = snapshot.folders
        guard !folders.isEmpty else { throw AnalysisConfigurationError.invalidLimits }
        // Public snapshots are produced by the validated accumulator. Still
        // reject unexpected topology rather than indexing arbitrary references.
        for (i, folder) in folders.enumerated() {
            guard folder.id.rawValue == i,
                  i == 0 ? folder.parent == nil : (folder.parent.map { (0..<i).contains($0.rawValue) } == true)
            else { throw AnalysisConfigurationError.invalidLimits }
        }
        var kinds = Array(repeating: AnalysisCategory.other, count: folders.count)
        func name(_ index: Int) -> String? {
            let path = folders[index].relativePath
            return path.isEmpty ? scopePath.split(separator: "/").last.map(String.init) : String(bytes: path.split(separator: 47).last ?? Data.SubSequence(), encoding: .utf8)
        }
        var steamRoots = Set<Int>()
        for folder in folders where name(folder.id.rawValue) == "common" {
            if let parent = folder.parent?.rawValue, name(parent) == "steamapps" { steamRoots.insert(parent) }
        }
        var nearest = Array(repeating: -1, count: folders.count)
        var projectRoots: [Int] = [], parentProject: [Int] = []
        var sharedCacheRoots: [(folder: Int, project: Int)] = []
        let rootComponents = scopePath.split(separator: "/").map(String.init)
        let rootCategory = classify(rootComponents, inherited: .other, hasProject: false)
        for i in folders.indices {
            if i % 512 == 0 { try Task.checkCancellation() }
            let parent = folders[i].parent?.rawValue
            let inherited = parent.map { kinds[$0] } ?? rootCategory
            let previousProject = parent.map { nearest[$0] } ?? -1
            let path = folders[i].relativePath
            let nameStart = path.lastIndex(of: 47).map { path.index(after: $0) } ?? path.startIndex
            let rawName = path[nameStart...]
            let name = String(bytes: rawName, encoding: .utf8)
            var context = name.map { [$0] } ?? []
            if let parent, name == "Caches" || name == "Application Support" || name == "registry" {
                let parentPath = folders[parent].relativePath
                let start = parentPath.lastIndex(of: 47).map { parentPath.index(after: $0) } ?? parentPath.startIndex
                let parentName = parentPath.isEmpty ? rootComponents.last : String(bytes: parentPath[start...], encoding: .utf8)
                if parentName == "Library" || parentName == ".cargo" { context.insert(parentName!, at: 0) }
            }
            let marker = snapshot.projectMarkers[folders[i].id]
            kinds[i] = i == 0 ? rootCategory : classify(context, inherited: inherited,
                hasProject: previousProject >= 0)
            if steamRoots.contains(i) { kinds[i] = .steamLibrary }
            let suppressMarker = [.buildOutput, .dependencies, .toolCache, .modelStore, .versionControl, .pythonCache, .flutterState, .steamLibrary, .developerCache, .applicationBundle, .systemFiles].contains(kinds[i])
            if marker != nil && !suppressMarker {
                nearest[i] = projectRoots.count
                projectRoots.append(i); parentProject.append(previousProject)
            } else { nearest[i] = previousProject }
            if nearest[i] >= 0, name == ".cache" || context == ["Library", "Caches"] {
                sharedCacheRoots.append((i, nearest[i]))
                nearest[i] = -1
            }
        }

        var children = Array(repeating: [Int](), count: folders.count)
        // This temporary index is released with the off-main projection; the
        // The result retains fixed role/type slices and fourteen project rows.
        for i in folders.indices.dropFirst() { children[folders[i].parent!.rawValue].append(i) }
        var totals = Array(repeating: AnalysisByteSubtotals(), count: AnalysisCategory.allCases.count)
        var counts = Array(repeating: UInt64(0), count: AnalysisCategory.allCases.count)
        for i in folders.indices {
            if i % 512 == 0 { try Task.checkCancellation() }
            var direct = folders[i].namespaceSubtotals
            var files = folders[i].counts.regularFiles
            for child in children[i] {
                direct.subtract(folders[child].namespaceSubtotals)
                files -= folders[child].counts.regularFiles
            }
            totals[kinds[i].rawValue].merge(direct); counts[kinds[i].rawValue] += files
        }
        let categories = AnalysisCategory.allCases.map { kind in
            AnalysisAttributionSlice(title: kind.title, explanation: kind.explanation,
                bytes: totals[kind.rawValue], files: counts[kind.rawValue], folder: nil)
        }
        var nested = Array(repeating: [Int](), count: projectRoots.count)
        var unassigned = folders[0].namespaceSubtotals
        var unassignedFiles = folders[0].counts.regularFiles
        for j in projectRoots.indices {
            if parentProject[j] >= 0 { nested[parentProject[j]].append(projectRoots[j]) }
            else {
                unassigned.subtract(folders[projectRoots[j]].namespaceSubtotals)
                unassignedFiles -= folders[projectRoots[j]].counts.regularFiles
            }
        }
        for shared in sharedCacheRoots {
            nested[shared.project].append(shared.folder)
            unassigned.merge(folders[shared.folder].namespaceSubtotals)
            unassignedFiles += folders[shared.folder].counts.regularFiles
        }
        var largest: [AnalysisAttributionSlice] = []
        var remainder = AnalysisByteSubtotals(), remainderFiles: UInt64 = 0
        for j in projectRoots.indices {
            if j % 512 == 0 { try Task.checkCancellation() }
            let folder = folders[projectRoots[j]]
            var bytes = folder.namespaceSubtotals, files = folder.counts.regularFiles
            for child in nested[j] { bytes.subtract(folders[child].namespaceSubtotals); files -= folders[child].counts.regularFiles }
            let marker = snapshot.projectMarkers[folder.id]!
            let path = String(bytes: folder.relativePath, encoding: .utf8) ?? "Folder with a non-UTF-8 name"
            largest.append(.init(title: path.isEmpty ? (scopePath as NSString).lastPathComponent : path,
                explanation: "Observed \(marker.evidence); nested projects excluded. Namespace totals may overlap hardlinks.",
                bytes: bytes, files: files, folder: folder.id))
            largest.sort {
                let a = $0.bytes[rankingMetric].knownBytes ?? 0, b = $1.bytes[rankingMetric].knownBytes ?? 0
                return a == b ? $0.title < $1.title : a > b
            }
            if largest.count > 12 {
                let removed = largest.removeLast(); remainder.merge(removed.bytes); remainderFiles += removed.files
            }
        }
        if projectRoots.count > 12 {
            largest.append(.init(title: "Other project scopes", explanation: "Remaining \(projectRoots.count - 12) observed projects.",
                bytes: remainder, files: remainderFiles, folder: nil))
        }
        largest.append(.init(title: "Unassigned / shared", explanation: "No supported project marker, or a shared cache layout whose project ownership is not established.",
            bytes: unassigned, files: unassignedFiles, folder: nil))
        let fileTypes = snapshot.fileTypes.map { value in
            AnalysisAttributionSlice(title: value.type.title, explanation: value.type.explanation,
                bytes: value.bytes, files: value.files, folder: nil)
        }
        return Self(categories: categories, fileTypes: fileTypes, projects: largest, projectCount: projectRoots.count,
            isComplete: snapshot.isComplete, crossFolderHardlinkObjects: snapshot.distinctObjects.observedCrossFolderHardlinkObjects)
    }

    static func classify(_ components: [String], inherited: AnalysisCategory, hasProject: Bool,
                         revision: AnalysisClassificationRevision = .v2) -> AnalysisCategory {
        if components.contains("huggingface") && (components.contains(".cache") || zip(components, components.dropFirst()).contains(where: { $0 == "Library" && $1 == "Caches" }) || inherited == .toolCache) { return .modelStore }
        if [.dependencies, .modelStore, .versionControl, .toolCache, .pythonCache, .flutterState, .steamLibrary, .developerCache, .applicationBundle, .systemFiles].contains(inherited) { return inherited }
        if revision.supportsApplicationRules, components.count >= 4,
           let index = (0...(components.count - 4)).first(where: { Array(components[$0..<($0 + 4)]) == ["Library", "Developer", "Xcode", "DerivedData"] }) {
            let prior = classify(Array(components.prefix(index + 3)), inherited: inherited, hasProject: hasProject)
            if [.other, .buildOutput, .appSupport].contains(prior) { return .developerCache }
        }
        if components.contains(".git") { return .versionControl }
        if components.contains(where: { ["node_modules", "Pods", ".venv", "venv"].contains($0) }) { return .dependencies }
        if components.contains(where: { ["__pycache__", ".pytest_cache", ".mypy_cache"].contains($0) }) { return .pythonCache }
        if components.contains(where: { [".dart_tool", ".pub-cache"].contains($0) }) { return .flutterState }
        if let library = components.lastIndex(of: "Library"), components.indices.contains(library + 1) {
            if components[library + 1] == "Caches" { return .toolCache }
            if components[library + 1] == "Application Support" { return .appSupport }
            if revision.supportsApplicationRules, ["Containers", "Group Containers"].contains(components[library + 1]) {
                let prior = classify(Array(components.prefix(library + 1)), inherited: inherited, hasProject: hasProject)
                return [.other, .buildOutput, .appSupport].contains(prior) ? .appSupport : prior
            }
        }
        if components.contains(".cache") || components.contains(".npm") { return .toolCache }
        if components.contains(".gradle") || components.contains(".m2") || zip(components, components.dropFirst()).contains(where: { $0 == ".cargo" && $1 == "registry" }) { return .developerCache }
        if components.contains(where: { $0.hasSuffix(".app") }) { return .applicationBundle }
        if hasProject && components.contains(where: { ["build", "dist", "target", ".build"].contains($0) }) { return .buildOutput }
        return inherited
    }
}

extension AnalysisByteSubtotals {
    /// Subtract observed disjoint child namespaces only. An overflowed parent
    /// cannot establish a remainder: preserve unavailable rather than inventing it.
    mutating func subtract(_ other: Self) {
        for metric in AnalysisByteMetric.allCases {
            var value = self[metric], child = other[metric]
            // Byte overflow does not erase exact observation counts. Keeping
            // the parent's support counts when removing a disjoint child
            // would attribute the same unavailable field to multiple groups.
            let validSupport = value.notReturnedCount >= child.notReturnedCount
                && value.failedCount >= child.failedCount
            if validSupport {
                value.notReturnedCount -= child.notReturnedCount
                value.failedCount -= child.failedCount
            }
            if value.overflowed || child.overflowed || value.knownBytes == nil || child.knownBytes == nil
                || value.knownBytes! < child.knownBytes! || !validSupport {
                value.knownBytes = nil; value.overflowed = true
            } else {
                value.knownBytes! -= child.knownBytes!
            }
            self[metric] = value
        }
    }
}
