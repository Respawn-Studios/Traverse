import Foundation

/// A metadata-only review of one pinned local APFS tree. This uses the existing
/// source inventory and byte reader but applies SMB's narrower name/path rules
/// before any remote stage intent. The local source is reopened and compared
/// again by the later mutation owner.
@_spi(Qualification) public struct SMBFolderUploadPlan: Sendable, CustomDebugStringConvertible {
    public let name: String
    public let files: Int, folders: Int
    public let logicalBytes: UInt64
    let url: URL
    let snapshot: SFTPFolderUploadSourceSnapshot
    let manifest: SFTPFolderUploadManifest
    let remoteNodes: [[SMBRemoteName]]
    public var debugDescription: String { "<SMB reviewed local folder>" }

    static func fromPrepared(_ source: SFTPFolderUploadSource, url: URL) throws -> Self {
        let snapshot = source.snapshot, manifest = source.manifest
        guard SMBRequestedUpload.isSupportedName(snapshot.name),
              manifest.nodes.first?.components.isEmpty == true,
              manifest.nodes.first?.directory == true else {
            throw SMBUploadGroupIssue.invalidSelection
        }
        var nodes: [[SMBRemoteName]] = []
        var siblings: [Data: Set<String>] = [:]
        for node in manifest.nodes {
            var components: [SMBRemoteName] = []
            for raw in node.components {
                guard let text = String(data: raw, encoding: .utf8), Data(text.utf8) == raw,
                      SMBRequestedUpload.isSupportedName(text),
                      let remote = try? SMBRemoteName(text), SMBUploadName.safe(remote) else {
                    throw SMBUploadGroupIssue.invalidSelection
                }
                components.append(remote)
            }
            if let last = node.components.last, let display = components.last?.displayName {
                let parent = SFTPFolderUploadManifest.key(Array(node.components.dropLast()))
                let folded = display.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                             locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
                guard siblings[parent, default: []].insert(folded).inserted, !last.isEmpty else {
                    throw SMBUploadGroupIssue.duplicateNames
                }
            }
            nodes.append(components)
        }
        return .init(name: snapshot.name, files: snapshot.files, folders: snapshot.folders,
                     logicalBytes: snapshot.logicalBytes, url: url, snapshot: snapshot,
                     manifest: manifest, remoteNodes: nodes)
    }

    public static func inspect(_ url: URL, excluding roots: [URL]) async throws -> Self {
        let source: SFTPFolderUploadSource
        do { source = try await SFTPFolderUploadSource.prepare(url, excluding: roots) }
        catch let failure as SFTPUploadSourceFailure { throw SFTPUploadLocalIssue(failure) }
        do {
            let plan = try fromPrepared(source, url: url)
            await source.drain()
            try Task.checkCancellation()
            return plan
        } catch {
            await source.drain()
            throw error
        }
    }

    func validateDestination(directory: [SMBRemoteName], name: String, temporaryName: String) throws {
        let stagePrefix = ".traverse-smb-upload-", stageSuffix = ".part"
        let stageToken = temporaryName.dropFirst(stagePrefix.count).dropLast(stageSuffix.count)
        guard directory.count <= 128, directory.allSatisfy(SMBUploadName.safe),
              SMBRequestedUpload.isSupportedName(name), temporaryName.hasPrefix(stagePrefix),
              temporaryName.hasSuffix(stageSuffix), stageToken.count == 32,
              stageToken.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let final = try? SMBRemoteName(name), let stage = try? SMBRemoteName(temporaryName),
              SMBUploadName.safe(stage), final.displayName.lowercased() != temporaryName else {
            throw SMBUploadGroupIssue.invalidSelection
        }
        let parent = directory.reduce(0) { $0 + $1.wireUTF16.count / 2 } + max(0, directory.count - 1)
        guard parent <= 1920 else { throw SMBUploadGroupIssue.invalidSelection }
        for path in remoteNodes {
            let suffix = path.reduce(0) { $0 + 1 + $1.wireUTF16.count / 2 }
            let separator = directory.isEmpty ? 0 : 1
            guard parent + separator + final.wireUTF16.count / 2 + suffix <= 2048,
                  parent + separator + stage.wireUTF16.count / 2 + suffix <= 2048 else {
                throw SMBUploadGroupIssue.invalidSelection
            }
        }
    }
}
