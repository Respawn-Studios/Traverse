import Darwin
import FileOperations
import Foundation

/// Git evaluates only the rules for the requested paths inside an empty
/// worktree. Live configuration, filters, hooks and path bodies stay outside.
struct GitWorkingRules {
    struct Observation {
        let parent: DirectoryAnchor
        let name: String
        let entry: EntrySnapshot?
    }

    let mirror: DirectoryAnchor
    let observations: [Observation]

    func validate(check: () throws -> Void) throws {
        for rule in observations {
            try check()
            try rule.parent.validate()
            guard try rule.parent.gitEntry(rule.name).map(EntrySnapshot.init) == rule.entry else {
                throw GitInspectionFailure.changed
            }
        }
    }
}

extension GitReadView {
    func workingRules(for paths: [GitSnapshotPath], includeAttributes: Bool,
                      check: () throws -> Void) throws -> GitWorkingRules {
        let directoryName = "rules-tree"
        try createFolder(directoryName, in: directory)
        let mirror = try directory.gitDirectory(directoryName)
        var folders: [Data: (source: DirectoryAnchor, destination: DirectoryAnchor)] = [Data(): (files.root, mirror)]
        var observations: [GitWorkingRules.Observation] = []
        var budget = 1 << 20

        func observe(_ name: String, in source: DirectoryAnchor) throws -> stat? {
            try check()
            let entry = try source.gitEntry(name)
            observations.append(.init(parent: source, name: name, entry: entry.map(EntrySnapshot.init)))
            return entry
        }

        func copy(_ name: String, from source: DirectoryAnchor, to target: DirectoryAnchor,
                  ignoreSymlinks: Bool = false) throws {
            guard let entry = try observe(name, in: source),
                  !ignoreSymlinks || entry.st_mode & S_IFMT != S_IFLNK else { return }
            guard let data = try source.gitReadOptional(name, maximum: min(256 << 10, budget), check: check),
                  try source.gitEntry(name).map(EntrySnapshot.init) == EntrySnapshot(entry) else {
                throw GitInspectionFailure.changed
            }
            budget -= data.count
            try data.write(to: target.url.appendingPathComponent(name), options: .withoutOverwriting)
        }

        func copyFolderRules(from source: DirectoryAnchor, to target: DirectoryAnchor) throws {
            try copy(".gitignore", from: source, to: target, ignoreSymlinks: true)
            if includeAttributes { try copy(".gitattributes", from: source, to: target, ignoreSymlinks: true) }
        }

        try copyFolderRules(from: files.root, to: mirror)
        if try observe("info", in: files.common) != nil {
            let info = try files.common.gitDirectory("info")
            try createFolder("info", in: directory)
            let target = try directory.gitDirectory("info")
            try copy("exclude", from: info, to: target)
            if includeAttributes { try copy("attributes", from: info, to: target) }
        }

        for path in paths {
            try check()
            guard let name = path.literalArgument else { throw GitInspectionFailure.unsupportedRepository }
            var prefix = Data()
            var pair = (source: files.root, destination: mirror)
            for component in name.split(separator: "/").dropLast() {
                let part = String(component)
                prefix.append(Data((part + "/").utf8))
                if let found = folders[prefix] { pair = found; continue }
                guard folders.count < 128 else { throw GitInspectionFailure.limitExceeded }
                let source = try pair.source.gitDirectory(part)
                guard try observe(".git", in: source) == nil else { throw GitInspectionFailure.unsupportedRepository }
                try createFolder(part, in: pair.destination)
                let destination = try pair.destination.gitDirectory(part)
                try copyFolderRules(from: source, to: destination)
                pair = (source, destination)
                folders[prefix] = pair
            }
        }
        let rules = GitWorkingRules(mirror: mirror, observations: observations)
        try rules.validate(check: check)
        return rules
    }

    func ignoredPaths(_ paths: [GitSnapshotPath], using prepared: GitWorkingRules? = nil,
                      check: () throws -> Void) throws -> Set<GitSnapshotPath> {
        guard !paths.isEmpty else { return [] }
        let rules = try prepared ?? workingRules(for: paths, includeAttributes: false, check: check)
        var query = Data()
        for path in paths {
            query.append(contentsOf: [46, 47])
            query.append(path.bytes)
            query.append(0)
        }
        let result = try withInput(query, named: "ignore-query") { input in
            try run(["check-ignore", "--no-index", "--stdin", "-z"], maximumBytes: 256 << 10,
                rulesTree: rules.mirror, input: input, acceptsNoMatch: true)
        }
        let requested = Set(paths)
        var matches = Set<GitSnapshotPath>()
        for row in try records(result) {
            try check()
            guard row.starts(with: [46, 47]), let path = GitSnapshotPath(row.dropFirst(2)), requested.contains(path),
                  matches.insert(path).inserted else { throw GitInspectionFailure.invalidOutput }
        }
        try rules.validate(check: check)
        return matches
    }

    func withInput<Value>(_ data: Data, named name: String, _ work: (FileHandle) throws -> Value) throws -> Value {
        let inputURL = directory.url.appendingPathComponent(name)
        try data.write(to: inputURL, options: .withoutOverwriting)
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        return try work(input)
    }
}
