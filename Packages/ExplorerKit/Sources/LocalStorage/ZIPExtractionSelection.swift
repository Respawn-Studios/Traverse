import Foundation

/// Exact session-selected names plus source observation. No local output path,
/// descriptor, access grant or ability to overwrite is carried by this value.
public struct ZIPExtractionSelection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var count: Int { roots.count }
    public var displayNames: [String] { roots.map(\.path) }
    public var description: String { "\(count) archive selections" }
    public var debugDescription: String { description }
    internal struct Root: Sendable { let path: String; let kind: ZIPMemberKind }
    internal let source: URL
    internal let stamp: ZIPSourceFile.Stamp
    internal let roots: [Root]
}

internal struct ZIPSourceBinding: Sendable {
    let source: URL
    let stamp: ZIPSourceFile.Stamp
}
