import Foundation
import ExplorerCore

/// Generated qualification only. A logical fixture label is not a filesystem
/// spelling; the native metadata caller must use the enumerated bytes.
internal enum SMBGeneratedFixtureNames {
    static let regular = ["Read me.txt", "Café 文件.txt"]
    static func regularProbeNames(in observed: [String]) throws -> [String] {
        guard observed.count <= 64 else {
            throw SMBConnectionProblem.invalidResult
        }
        return try regular.map { expected in
            let matches = observed.filter { $0 == expected }
            guard matches.count == 1, let actual = matches.first else { throw SMBConnectionProblem.invalidResult }
            return actual
        }
    }
}
