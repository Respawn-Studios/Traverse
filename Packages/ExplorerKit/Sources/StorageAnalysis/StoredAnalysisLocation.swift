import Darwin
import Foundation

/// Verified for a read-only action at request time. Not a permission grant,
/// FileOperationSelection, content-change proof or mutation/cleanup authority.
public struct ResolvedAnalysisLocation: Sendable {
    public let url: URL
    public let kind: AnalysisEntryKind
    public let sourceID: UInt64
    public let recordedIdentity: AnalysisObjectIdentity
    public let isSourceRoot: Bool
}

struct StoredAnalysisLocationReference: Sendable {
    struct Step: Sendable {
        let id: UInt64, parent: UInt64
        let name: Data
        let kind: AnalysisEntryKind
        let identity: AnalysisObjectIdentity
        let flags: UInt32
    }
    let node: UInt64, source: UInt64
    let chain: [Step]
    var maximumPathComponents = 64
    static func decode(_ frames: [[String: Any]], node: UInt64, maximumPathComponents: Int = 64,
                       classificationRevision: AnalysisClassificationRevision = .v3) throws -> Self {
        guard classificationRevision.supportsApplicationRules, [64,128].contains(maximumPathComponents), node < Int64.max, frames.count == 1, let frame = frames.first,
              frame["kind"] as? String == "location", strictInteger(frame["location_revision"]) == 1,
              strictInteger(frame["classification_revision"]) == classificationRevision.rawValue,
              try storedNumber(frame["node"]) == node, let source = strictInteger(frame["source"]), (0...2).contains(source),
              let rows = frame["chain"] as? [[String: Any]], rows.count <= maximumPathComponents else { throw StorageScanFailure.invalidOutput }
        var parent = UInt64(source), chain: [Step] = [], length = 0
        for (index, row) in rows.enumerated() {
            let id = try storedNumber(row["id"]), capturedParent = try storedNumber(row["parent"])
            let name = try storedBlob(row["name"]), device = try storedNumber(row["device"]), inode = try storedNumber(row["inode"])
            let flags = try storedNumber(row["flags"])
            guard id > parent, id < Int64.max, capturedParent == parent,
                  !name.isEmpty, name.count <= 255, !name.contains(0), !name.contains(47), name != Data([46]), name != Data([46, 46]),
                  device > 0, device <= UInt32.max, inode > 0, flags <= UInt32.max,
                  let kind = strictInteger(row["type"]), (0...1).contains(kind), index == rows.count - 1 || kind == 1 else {
                throw StorageScanFailure.invalidOutput
            }
            length += name.count + 1
            guard length <= 8192 else { throw StorageScanFailure.invalidOutput }
            chain.append(.init(id: id, parent: parent, name: name, kind: kind == 1 ? .directory : .regularFile,
                identity: .init(device: device, inode: inode), flags: UInt32(flags)))
            parent = id
        }
        guard parent == node else { throw StorageScanFailure.invalidOutput }
        return .init(node: node, source: UInt64(source), chain: chain, maximumPathComponents: maximumPathComponents)
    }
}

extension StorageAnalysisResult {
    public var supportsStoredLocations: Bool { policyBindingForLocations && locationSources?.supportsResolution == true }

    /// Explicit user action only; SQL and fresh native ancestry checks share
    /// one reader/cancellation/activity lifetime. No file contents are read.
    public func resolveLocation(node: UInt64, retainingAccess lifetime: any Sendable) async throws -> ResolvedAnalysisLocation {
        guard supportsStoredLocations, let sources = locationSources, node < Int64.max else { throw StorageScanFailure.unsupportedLocation }
        let box = ResolvedLocationBox()
        do {
            _ = try await query("location", parent: node, retainingAccess: lifetime, onFrames: { [scopeIsCurrent = self.scopeIsCurrentForLocations] frames, control in
                guard scopeIsCurrent() else { throw LocationSourceFailure(failure: .changed) }
                let reference = try StoredAnalysisLocationReference.decode(frames, node: node, maximumPathComponents: self.maximumPathComponentsForQueries,
                    classificationRevision: self.classificationRevision)
                do {
                    #if DEBUG
                    try self.runLocationHookForQualification()
                    #endif
                    let location = try sources.resolve(reference, cancelled: { control.cancelled || !scopeIsCurrent() })
                    guard !control.cancelled else { throw CancellationError() }
                    guard scopeIsCurrent() else { throw LocationSourceFailure(failure: .changed) }
                    box.set(location)
                } catch let error as StorageScanFailure {
                    // A source change is not catalog corruption. Do not make
                    // the query owner's store-uncertainty guard retain a valid
                    // temporary catalog merely because the source moved.
                    throw LocationSourceFailure(failure: error)
                }
            })
        } catch let error as LocationSourceFailure { throw error.failure }
        guard let value = box.value else { throw StorageScanFailure.invalidOutput }
        return value
    }
}

private struct LocationSourceFailure: Error, Sendable { let failure: StorageScanFailure }

private final class ResolvedLocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ResolvedAnalysisLocation?
    var value: ResolvedAnalysisLocation? { lock.withLock { stored } }
    func set(_ value: ResolvedAnalysisLocation) { lock.withLock { stored = value } }
}
