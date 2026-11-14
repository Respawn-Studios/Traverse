import Darwin
import Foundation

/// Name selection is bounded preparation, never permission to overwrite. The
/// ordinary transfer subsequently rechecks absence and publishes exclusively.
@_spi(ArchiveProduction) public enum DuplicateDestination {
    public static let maximumCandidates = 10_000

    static func key(_ url: URL, caseSensitive: Bool) -> String {
        caseSensitive ? url.path : url.path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func name(_ original: String, preservesExtension: Bool, number: Int) throws -> String {
        guard number > 0, number <= maximumCandidates else { throw FileOperationFailure.invalidRequest }
        try validateName(original)
        var stem = original, suffix = ""
        if preservesExtension, let dot = original.lastIndex(of: "."), dot != original.startIndex,
           original.index(after: dot) != original.endIndex {
            stem = String(original[..<dot]); suffix = String(original[dot...])
        }
        let numberSuffix = " (\(number))"
        let available = 255 - numberSuffix.utf8.count - suffix.utf8.count
        guard available > 0 else { throw FileOperationFailure.unsupported }
        // Remove whole Characters, retaining valid Unicode and the extension.
        while stem.utf8.count > available { stem.removeLast() }
        guard !stem.isEmpty else { throw FileOperationFailure.unsupported }
        let result = stem + numberSuffix + suffix
        try validateName(result)
        return result
    }

    static func choose(_ entry: TransferEntry, reserved: inout Set<String>, caseSensitive: Bool,
                       cancellation: OperationCancellation) throws -> TransferEntry {
        let parent = try DirectoryAnchor(entry.destination.deletingLastPathComponent(), resolve: false)
        guard parent.identity.sameObject(as: entry.destinationParent) else { throw FileOperationFailure.destinationChanged }
        let package = entry.sourceIdentity.isDirectory
            ? (try entry.source.resourceValues(forKeys: [.isPackageKey]).isPackage ?? false) : false
        for number in 1...maximumCandidates {
            try cancellation.check()
            let name = try name(entry.destination.lastPathComponent,
                preservesExtension: !entry.sourceIdentity.isDirectory || package, number: number)
            let url = parent.url.appendingPathComponent(name)
            let key = key(url, caseSensitive: caseSensitive)
            guard !reserved.contains(key) else { continue }
            do { try requireAbsent(name, in: parent.fd) }
            catch FileOperationFailure.conflict { continue }
            try parent.validate()
            reserved.insert(key)
            return TransferEntry(id: entry.id, source: entry.source, destination: url,
                sourceIdentity: entry.sourceIdentity, sourceParent: entry.sourceParent,
                destinationIdentity: nil, destinationParent: parent.identity, children: nil)
        }
        throw FileOperationFailure.unsupported
    }
}
