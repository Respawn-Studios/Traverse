import Foundation

@_spi(Qualification) public enum SMBDirectoryRejection: String, Error, Sendable, Equatable {
    case denied, missing, unavailable
}

/// A read generation is distinct from both its remote path and its tab. The
/// monotonic number also bounds replay checking without retaining all old IDs.
struct SMBBrowserReadRequest: Sendable, Equatable {
    let number: UInt64
    let id: UUID
    let components: [SMBRemoteName]
    var command: String {
        let path = components.map { name in
            let data = Array(name.wireUTF16)
            return stride(from: 0, to: data.count, by: 2).map {
                String(format: "%04x", UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
            }.joined()
        }.joined(separator: ",")
        return "READ \(number) \(id.uuidString) \(path.isEmpty ? "-" : path)\n"
    }
}
enum SMBBrowserMode: Sendable {
    case metadata, selectedDownload, folderDownload, selectedUpload
    var magic: String { switch self { case .metadata: "MEXSMBB2"; case .selectedDownload: "MEXSMBD1"; case .folderDownload: "MEXSMBF1"; case .selectedUpload: "MEXSMBU1" } }
    var argument: String { switch self { case .metadata: "--browser-worker"; case .selectedDownload: "--selected-download-browser-worker"; case .folderDownload: "--folder-download-browser-worker"; case .selectedUpload: "--selected-upload-browser-worker" } }
    var allowsFolderDownload: Bool { self == .folderDownload || self == .selectedUpload }
    var allowsFolderSizeSummary: Bool {
        switch self { case .metadata, .selectedDownload, .folderDownload, .selectedUpload: true }
    }
}
enum SMBBrowserEvent: Sendable {
    case action(SMBActionEvent)
    case edit(SMBOriginalEditEvent)
    case editSourceReleased(UUID)
    case download(SMBDownloadEvent)
    case folder(SMBFolderDownloadEvent)
    case upload(SMBUploadEvent)
    case folderUpload(SMBFolderUploadEvent)
    case connected(encrypted: Bool)
    case began(UInt64, UUID)
    case snapshot(UInt64, SMBDirectorySnapshot)
    case page(UInt64, SMBDirectoryPage)
    case found(UInt64, SMBDirectoryFindResult), queryUnavailable(UUID)
    case folderSize(UUID, RemoteFolderSizeSummary), folderSizeUnavailable(UUID, RemoteFolderSizeFailure)
    case stale(UUID)
    case idle(UInt64, cancelled: Bool)
    case rejected(UInt64, SMBDirectoryRejection)
    case networkDrained
    case profile([UInt64])
    case closed(String)
}
/// Fixed pre-BEGIN checks only. The code names a comparison, never a file or
/// any value received from the server.
@_spi(Qualification) public enum SMBActionPreflightCode: UInt8, Sendable, Equatable {
    case directory = 1, attributes, size, modified, object, links, volume, volumeCreated, createAttributes, createModified
}
enum SMBActionEvent: Sendable { case ready(UUID), complete(UUID), collision(UUID), notEmpty(UUID),
    stageCollision(UUID), finalCollision(UUID), progress(UUID, UInt64, UInt64),
    destinationUnavailable(UUID), refused(UUID, SMBActionPreflightCode), fault(UUID, UInt8) }

/// The frozen single-read page decoder remains the metadata validator. This
/// small outer layer adds session/read admission and lifetime proofs; it cannot
/// turn an unrequested or retired page into a current native row.
struct SMBBrowserDecoder {
    private struct Read {
        let number: UInt64
        let components: [SMBRemoteName]
        var decoder: SMBDirectoryCatalogDecoder
        var sequence: UInt64 = 0
        var idle = false
        var rejection: SMBDirectoryRejection?
        mutating func consume(_ payload: String, session: UUID) throws -> SMBDirectoryCatalogEvent? {
            guard sequence < UInt64.max else { throw SMBDirectoryFailure.invalidOutput }
            let line = Data("MEXSMBC1 \(session.uuidString) \(sequence) \(payload)".utf8)
            sequence += 1
            return try decoder.consume(line)
        }
    }
    let session: UUID
    let requireEncryption: Bool
    let mode: SMBBrowserMode
    private var download: SMBDownloadConversation?
    private var folder: SMBFolderDownloadConversation?
    private var upload: SMBUploadConversation?
    private var folderUpload: SMBFolderUploadConversation?
    private enum ActionPhase: Equatable { case preparing, ready, begun, faulted }
    private var action: (request: SMBSelectedActionRequest, ordinal: UInt64, phase: ActionPhase, copied: UInt64)?
    private var edit: SMBOriginalEditConversation?
    private var actionRefused = false
    private var uploadAttempted = false
    // Retain the typed BEGIN_ACTION proof through the final worker profile.
    private var copyActionBegun = false
    private var downloadOrdinal: UInt64 = 0
    private var sequence: UInt64 = 0
    private var issued: UInt64 = 0
    private var desired: SMBBrowserReadRequest?
    private var current: Read?
    private var retired: Read?
    private var pendingPage: (number: UInt64, request: SMBDirectoryPageRequest)?
    private var pendingFind: (number: UInt64, request: SMBDirectoryFindRequest)?
    private var pendingFolderSize: (number: UInt64, selection: SMBFolderSizeSelection)?
    private var pendingEditSourceRelease: UUID?
    private(set) var connected = false
    private(set) var drained = false
    private(set) var closed = false
    private var profileReceived = false
    var snapshot: SMBDirectorySnapshot? { current?.number == issued ? current?.decoder.snapshot : nil }
    var readNumber: UInt64? { current?.number == issued ? current?.number : nil }
    var hasPendingPage: Bool { pendingPage != nil || pendingFind != nil || pendingFolderSize != nil }
    var directoryRejection: SMBDirectoryRejection? { current?.number == issued ? current?.rejection : nil }

    init(session: UUID, requireEncryption: Bool, mode: SMBBrowserMode = .metadata) { self.session = session; self.requireEncryption = requireEncryption; self.mode = mode }

    mutating func navigate(components: [SMBRemoteName]) throws -> SMBBrowserReadRequest {
        guard connected, !drained, !closed else { throw SMBDirectoryFailure.unavailable }
        guard desired == nil, download == nil, folder == nil, upload == nil, folderUpload == nil, action == nil, edit == nil, pendingFolderSize == nil else { throw SMBDirectoryFailure.busy }
        guard issued < UInt64.max, components.count <= 128,
              components.reduce(0, { $0 + $1.wireUTF16.count / 2 }) + max(0, components.count - 1) <= 4096 else {
            throw SMBDirectoryFailure.invalidInput
        }
        issued += 1
        let value = SMBBrowserReadRequest(number: issued, id: UUID(), components: components)
        desired = value
        return value
    }

    mutating func request(_ page: SMBDirectoryPageRequest) throws -> String {
        guard !closed, !drained, download == nil, folder == nil, upload == nil, folderUpload == nil, action == nil, edit == nil, desired == nil, !hasPendingPage, var read = current,
              read.number == issued, read.rejection == nil else { throw SMBDirectoryFailure.busy }
        try read.decoder.request(page)
        current = read; pendingPage = (read.number, page)
        return "PAGE \(page.token.uuidString) \(read.number) \(page.snapshot.readID.uuidString) \(page.snapshot.revision) \(page.offset) \(page.sort.rawValue) \(page.descending ? 1 : 0)\(page.find.map { " " + $0.query.id.uuidString } ?? "")\n"
    }
    mutating func request(_ find: SMBDirectoryFindRequest) throws -> String {
        guard !closed, !drained, download == nil, folder == nil, upload == nil, folderUpload == nil, action == nil, edit == nil,
              desired == nil, !hasPendingPage, var read = current, read.number == issued, read.rejection == nil else {
            throw SMBDirectoryFailure.busy
        }
        try read.decoder.request(find); current = read; pendingFind = (read.number, find)
        return "FIND \(find.token.uuidString) \(read.number) \(find.fields)\n"
    }
    mutating func request(_ selection: SMBFolderSizeSelection) throws -> String {
        guard mode.allowsFolderSizeSummary else { throw RemoteFolderSizeFailure.unsupported }
        guard connected, !closed, !drained, download == nil, folder == nil, upload == nil,
              folderUpload == nil, action == nil, edit == nil, desired == nil, !hasPendingPage,
              let read = current, read.number == issued, read.idle, read.rejection == nil else { throw SMBDirectoryFailure.busy }
        guard selection.connection == session, selection.snapshot == read.decoder.snapshot,
              selection.snapshot.state == .complete else { throw RemoteFolderSizeFailure.stale }
        pendingFolderSize = (read.number, selection)
        let snapshot = selection.snapshot
        return "SIZE_FOLDER \(selection.request.uuidString) \(read.number) \(snapshot.readID.uuidString) \(snapshot.revision) \(snapshot.count) \(snapshot.folders) 1 \(selection.observation.id)\n"
    }

    mutating func prepareDownload(_ selection: SMBDownloadSelection, retainingEditSource: Bool = false) throws -> String {
        guard mode != .metadata, connected, !drained, !closed, !profileReceived else { throw SMBDirectoryFailure.unavailable }
        guard !retainingEditSource || mode == .selectedUpload && requireEncryption else { throw SMBDirectoryFailure.unavailable }
        if retainingEditSource {
            guard let object = selection.observation.objectID, let parent = selection.observation.parentID,
                  object != 0, object != .max, parent != 0, parent != .max, object != parent else {
                throw SMBTextFailure.unsupported
            }
        }
        guard download == nil, folder == nil, upload == nil, folderUpload == nil, action == nil, edit == nil, desired == nil, !hasPendingPage, let read = current, read.number == issued,
              read.idle, read.rejection == nil, read.decoder.snapshot == selection.snapshot,
              pendingEditSourceRelease == nil, selection.connection == session,
              downloadOrdinal < UInt64.max else { throw SMBDirectoryFailure.busy }
        downloadOrdinal += 1; download = try .init(selection: selection, ordinal: downloadOrdinal,
                                                   retainingEditSource: retainingEditSource)
        return selection.command(ordinal: downloadOrdinal, number: read.number,
                                 retainingEditSource: retainingEditSource)
    }
    mutating func releaseEditSource(_ token: UUID) throws -> String {
        guard mode == .selectedUpload, requireEncryption, connected, !drained, !closed,
              !profileReceived else { throw SMBDirectoryFailure.unavailable }
        guard pendingEditSourceRelease == nil, !hasPendingPage, download == nil, folder == nil, upload == nil,
              folderUpload == nil, action == nil, edit == nil else { throw SMBDirectoryFailure.busy }
        pendingEditSourceRelease = token
        return "RELEASE_EDIT_SOURCE \(token.uuidString)\n"
    }
    mutating func beginDownload(_ request: UUID) throws -> String {
        guard var transfer = download, transfer.selection.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.begin(); download = transfer; return command
    }
    mutating func releaseDownload(_ request: UUID) throws -> String {
        guard var transfer = download, transfer.selection.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.release(); download = transfer; return command
    }
    mutating func appendedDownload(_ request: UUID, end: UInt64) throws -> String {
        guard var transfer = download else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.appended(request: request, endOffset: end); download = transfer; return command
    }
    mutating func prepareFolder(_ selection: SMBFolderDownloadSelection) throws -> String {
        guard mode.allowsFolderDownload, connected, !drained, !closed, !profileReceived else { throw SMBDirectoryFailure.unavailable }
        guard download == nil, folder == nil, upload == nil, folderUpload == nil, action == nil, edit == nil, desired == nil, !hasPendingPage, let read = current, read.number == issued,
              read.idle, read.rejection == nil, read.decoder.snapshot == selection.snapshot,
              selection.connection == session, downloadOrdinal < UInt64.max else { throw SMBDirectoryFailure.busy }
        downloadOrdinal += 1; folder = try .init(selection: selection, ordinal: downloadOrdinal)
        return selection.command(ordinal: downloadOrdinal, number: read.number)
    }
    mutating func beginFolder(_ request: UUID) throws -> String {
        guard var transfer = folder, transfer.selection.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.begin(); folder = transfer; return command
    }
    mutating func releaseFolder(_ request: UUID) throws -> String {
        guard var transfer = folder, transfer.selection.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.release(); folder = transfer; return command
    }
    mutating func appendedFolder(_ request: UUID, member: Int, end: UInt64) throws -> String {
        guard var transfer = folder else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.appended(request: request, member: member, end: end); folder = transfer; return command
    }
    mutating func prepareUpload(_ request: SMBRequestedUpload) throws -> String {
        guard mode == .selectedUpload, requireEncryption, connected, !drained, !closed, !profileReceived else { throw SMBDirectoryFailure.unavailable }
        guard download == nil, folder == nil, upload == nil, folderUpload == nil, action == nil, edit == nil, desired == nil, !hasPendingPage,
              let read = current, read.number == issued, read.idle, read.rejection == nil,
              read.components == request.directory, read.decoder.snapshot == request.snapshot,
              request.connection == session, downloadOrdinal < UInt64.max else { throw SMBDirectoryFailure.busy }
        downloadOrdinal += 1; upload = try .init(request: request, ordinal: downloadOrdinal); uploadAttempted = true
        return request.command(ordinal: downloadOrdinal, number: read.number)
    }
    mutating func beginUpload(_ request: UUID) throws -> String {
        guard var transfer = upload, transfer.request.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.begin(); upload = transfer; return command
    }
    mutating func uploadData(_ request: UUID, sequence: UInt64, offset: UInt64, bytes: Data) throws -> Data {
        guard var transfer = upload, transfer.request.request == request else { throw SMBDirectoryFailure.invalidInput }
        let frame = try transfer.data(sequence: sequence, offset: offset, bytes: bytes); upload = transfer; return frame
    }
    mutating func uploadDigest(_ request: UUID, value: Data) throws -> String {
        guard var transfer = upload, transfer.request.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.supplyDigest(value); upload = transfer; return command
    }
    mutating func commitUpload(_ request: UUID) throws -> String {
        guard var transfer = upload, transfer.request.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.commit(); upload = transfer; return command
    }
    mutating func prepareFolderUpload(_ request: SMBRequestedFolderUpload) throws -> String {
        guard mode == .selectedUpload, requireEncryption, connected, !drained, !closed, !profileReceived else { throw SMBDirectoryFailure.unavailable }
        guard download == nil, folder == nil, upload == nil, folderUpload == nil, action == nil, edit == nil, desired == nil, !hasPendingPage,
              let read = current, read.number == issued, read.idle, read.rejection == nil,
              read.components == request.directory, read.decoder.snapshot == request.snapshot,
              request.connection == session, downloadOrdinal < UInt64.max else { throw SMBDirectoryFailure.busy }
        downloadOrdinal += 1; folderUpload = try .init(request: request, ordinal: downloadOrdinal); uploadAttempted = true
        return request.command(ordinal: downloadOrdinal, number: read.number)
    }
    mutating func prepareAction(_ request: SMBSelectedActionRequest) throws -> String {
        guard mode == .selectedUpload, requireEncryption, connected, !drained, !closed, !profileReceived else { throw SMBDirectoryFailure.unavailable }
        guard action == nil, edit == nil, download == nil, folder == nil, upload == nil, folderUpload == nil,
              desired == nil, !hasPendingPage, let read = current, read.number == issued,
              read.idle, read.rejection == nil, read.components == request.directory,
              read.decoder.snapshot == request.snapshot, request.connection == session,
              downloadOrdinal < UInt64.max else { throw SMBDirectoryFailure.busy }
        downloadOrdinal += 1
        action = (request: request, ordinal: downloadOrdinal, phase: .preparing, copied: 0)
        uploadAttempted = true
        return request.command(ordinal: downloadOrdinal, number: read.number)
    }
    mutating func beginAction(_ request: UUID) throws -> String {
        guard var action, action.request.request == request, action.phase == .ready else { throw SMBDirectoryFailure.invalidInput }
        action.phase = .begun; self.action = action
        if action.request.operation.isCopy { copyActionBegun = true }
        return "BEGIN_ACTION \(request.uuidString) \(action.ordinal)\n"
    }
    mutating func prepareEdit(_ request: SMBOriginalEditRequest) throws -> String {
        guard mode == .selectedUpload, requireEncryption, connected, !drained, !closed, !profileReceived else {
            throw SMBDirectoryFailure.unavailable
        }
        guard edit == nil, action == nil, download == nil, folder == nil, upload == nil, folderUpload == nil,
              desired == nil, !hasPendingPage, pendingFolderSize == nil, let read = current, read.number == issued,
              read.idle, pendingEditSourceRelease == nil,
              (request.sourceToken != nil || read.rejection == nil && read.decoder.snapshot == request.selection.snapshot),
              request.selection.connection == session, downloadOrdinal < UInt64.max else {
            throw SMBDirectoryFailure.busy
        }
        downloadOrdinal += 1
        edit = try .init(request: request, ordinal: downloadOrdinal)
        uploadAttempted = true
        return request.command(ordinal: downloadOrdinal, number: read.number)
    }
    mutating func editData(_ id: UUID, sequence: UInt64, offset: UInt64, bytes: Data) throws -> Data {
        guard var edit, edit.request.id == id else { throw SMBDirectoryFailure.invalidInput }
        let frame = try edit.data(sequence: sequence, offset: offset, bytes: bytes)
        self.edit = edit; return frame
    }
    mutating func authorizeEdit(_ id: UUID) throws -> String {
        guard var edit, edit.request.id == id else { throw SMBDirectoryFailure.invalidInput }
        let command = try edit.authorize(); self.edit = edit; return command
    }
    mutating func folderUploadManifest(_ request: UUID, offset: Int, bytes: Data) throws -> Data {
        guard var transfer = folderUpload, transfer.request.request == request else { throw SMBDirectoryFailure.invalidInput }
        let frame = try transfer.manifest(offset: offset, bytes: bytes); folderUpload = transfer; return frame
    }
    mutating func beginFolderUpload(_ request: UUID) throws -> String {
        guard var transfer = folderUpload, transfer.request.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.begin(); folderUpload = transfer; return command
    }
    mutating func acknowledgeFolderUploadRoot(_ request: UUID) throws -> String {
        guard var transfer = folderUpload, transfer.request.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.acknowledgeRoot(); folderUpload = transfer; return command
    }
    mutating func folderUploadData(_ request: UUID, node: Int, sequence: UInt64, offset: UInt64, bytes: Data) throws -> Data {
        guard var transfer = folderUpload, transfer.request.request == request else { throw SMBDirectoryFailure.invalidInput }
        let frame = try transfer.data(node: node, sequence: sequence, offset: offset, bytes: bytes); folderUpload = transfer; return frame
    }
    mutating func folderUploadDigest(_ request: UUID, node: Int, value: Data) throws -> String {
        guard var transfer = folderUpload, transfer.request.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.supplyDigest(node: node, value: value); folderUpload = transfer; return command
    }
    mutating func acknowledgeFolderUploadFile(_ request: UUID, node: Int, files: Int, bytes: UInt64) throws -> String {
        guard var transfer = folderUpload, transfer.request.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.acknowledgeFile(node: node, files: files, bytes: bytes); folderUpload = transfer; return command
    }
    mutating func commitFolderUpload(_ request: UUID, digest: Data) throws -> String {
        guard var transfer = folderUpload, transfer.request.request == request else { throw SMBDirectoryFailure.invalidInput }
        let command = try transfer.commit(digest); folderUpload = transfer; return command
    }
    mutating func consumeBinary(_ bytes: Data) throws -> SMBBrowserEvent {
        if mode.allowsFolderDownload, var transfer = folder {
            guard connected, !drained, !closed, !profileReceived, sequence < UInt64.max else { throw SMBDirectoryFailure.invalidOutput }
            do { let event = try transfer.binary(bytes, session: session, globalSequence: sequence, magic: mode.magic); folder = transfer; sequence += 1; return .folder(event) }
            catch { folder = transfer; throw error }
        }
        guard mode != .metadata, connected, !drained, !closed, !profileReceived,
              var transfer = download, sequence < UInt64.max else { throw SMBDirectoryFailure.invalidOutput }
        do {
            let event = try transfer.binary(bytes, session: session, globalSequence: sequence, magic: mode.magic)
            download = transfer; sequence += 1; return .download(event)
        } catch { download = transfer; throw error }
    }
    mutating func consume(_ line: Data) throws -> SMBBrowserEvent? {
        guard !closed, !line.isEmpty, line.count <= 16512, line.allSatisfy({ (32...126).contains($0) }),
              let text = String(data: line, encoding: .ascii) else { throw SMBDirectoryFailure.invalidOutput }
        let p = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 4, p.allSatisfy({ !$0.isEmpty }), p[0] == mode.magic, p[1] == session.uuidString,
              try number(p[2], UInt64.self) == sequence, sequence < UInt64.max else { throw SMBDirectoryFailure.invalidOutput }
        sequence += 1
        if drained, p[3] != "closed" { throw SMBDirectoryFailure.invalidOutput }
        if profileReceived, !drained, p[3] != "networkDrained" { throw SMBDirectoryFailure.invalidOutput }
        if p[3] == "editSourceReleased" {
            guard mode == .selectedUpload, connected, p.count == 5,
                  let pendingEditSourceRelease, p[4] == pendingEditSourceRelease.uuidString else {
                throw SMBDirectoryFailure.invalidOutput
            }
            self.pendingEditSourceRelease = nil
            return .editSourceReleased(pendingEditSourceRelease)
        }
        if p[3].hasPrefix("action") {
            guard mode == .selectedUpload, connected, !profileReceived, p.count >= 6,
                  var action, p[4] == action.request.request.uuidString,
                  try number(p[5], UInt64.self) == action.ordinal else { throw SMBDirectoryFailure.invalidOutput }
            switch p[3] {
            case "actionReady":
                let selected = action.request.observation
                guard p.count == 12, action.phase == .preparing,
                      try number(p[6], UInt32.self) == selected.attributes,
                      try number(p[7], UInt64.self) == selected.logicalBytes,
                      try number(p[8], UInt64.self) == selected.modifiedFileTime,
                      try number(p[9], UInt64.self) == selected.objectID,
                      try number(p[10], UInt64.self) == selected.parentID,
                      p[11] == SMBUploadName.wire(selected.name) else { throw SMBDirectoryFailure.invalidOutput }
                action.phase = .ready; self.action = action; return .action(.ready(action.request.request))
            case "actionProgress":
                guard p.count == 8, action.phase == .begun, action.request.operation.isCopy else {
                    throw SMBDirectoryFailure.invalidOutput
                }
                let done = try number(p[6], UInt64.self), total = try number(p[7], UInt64.self)
                guard total == action.request.observation.logicalBytes, done > action.copied,
                      done <= total else { throw SMBDirectoryFailure.invalidOutput }
                action.copied = done; self.action = action
                return .action(.progress(action.request.request, done, total))
            case "actionComplete", "actionCollision", "actionNotEmpty", "actionStageCollision", "actionFinalCollision":
                guard p.count == 6, action.phase == .begun else { throw SMBDirectoryFailure.invalidOutput }
                guard p[3] != "actionNotEmpty" || action.request.operation == .deleteEmptyDirectory,
                      p[3] != "actionCollision" || action.request.operation.isRename || action.request.operation.isMove || action.request.operation.isCopy,
                      !["actionStageCollision", "actionFinalCollision"].contains(p[3]) || action.request.operation.isCopy,
                      p[3] != "actionComplete" || !action.request.operation.isCopy ||
                        action.copied == action.request.observation.logicalBytes else { throw SMBDirectoryFailure.invalidOutput }
                self.action = nil
                switch p[3] {
                case "actionComplete": return .action(.complete(action.request.request))
                case "actionCollision": return .action(.collision(action.request.request))
                case "actionStageCollision": return .action(.stageCollision(action.request.request))
                case "actionFinalCollision": return .action(.finalCollision(action.request.request))
                default: return .action(.notEmpty(action.request.request))
                }
            case "actionDestinationUnavailable":
                guard p.count == 6, action.phase == .preparing,
                      action.request.operation.isMove || action.request.operation.isCopy else { throw SMBDirectoryFailure.invalidOutput }
                self.action = nil
                return .action(.destinationUnavailable(action.request.request))
            case "actionRefused":
                guard p.count == 7, action.phase == .preparing,
                      let code = SMBActionPreflightCode(rawValue: try number(p[6], UInt8.self)) else { throw SMBDirectoryFailure.invalidOutput }
                self.action = nil; actionRefused = true
                return .action(.refused(action.request.request, code))
            case "actionFault":
                guard p.count == 7 else { throw SMBDirectoryFailure.invalidOutput }
                let checkpoint = try number(p[6], UInt8.self)
                guard action.phase == .begun,
                      action.request.operation.isMove || action.request.operation.isCopy,
                      (1...6).contains(checkpoint) else { throw SMBDirectoryFailure.invalidOutput }
                action.phase = .faulted; self.action = action
                return .action(.fault(action.request.request, checkpoint))
            default: throw SMBDirectoryFailure.invalidOutput
            }
        }
        if p[3].hasPrefix("edit") {
            guard mode == .selectedUpload, connected, !profileReceived, var edit else {
                throw SMBDirectoryFailure.invalidOutput
            }
            do {
                let event = try edit.text(Array(p.dropFirst(3)))
                self.edit = edit.phase == .complete ? nil : edit
                return .edit(event)
            } catch { self.edit = edit; throw error }
        }
        if p[3].hasPrefix("folderUpload") {
            guard mode == .selectedUpload, connected, !profileReceived, var transfer = folderUpload else { throw SMBDirectoryFailure.invalidOutput }
            do {
                let event = try transfer.text(Array(p.dropFirst(3)))
                folderUpload = transfer.phase == .complete ? nil : transfer
                return .folderUpload(event)
            } catch { folderUpload = transfer; throw error }
        }
        if p[3].hasPrefix("folder") && !["folderSize", "folderSizeUnavailable"].contains(p[3]) {
            guard mode.allowsFolderDownload, connected, !profileReceived, var transfer = folder else { throw SMBDirectoryFailure.invalidOutput }
            do { let event = try transfer.text(Array(p.dropFirst(3))); folder = transfer.phase == .complete ? nil : transfer; return event.map(SMBBrowserEvent.folder) }
            catch { folder = transfer; throw error }
        }
        if p[3].hasPrefix("download") {
            guard mode != .metadata, connected, !profileReceived, var transfer = download else { throw SMBDirectoryFailure.invalidOutput }
            do {
                let event = try transfer.text(Array(p.dropFirst(3)))
                download = transfer.phase == .complete ? nil : transfer; return .download(event)
            } catch { download = transfer; throw error }
        }
        if p[3].hasPrefix("upload") {
            guard mode == .selectedUpload, connected, !profileReceived, var transfer = upload else { throw SMBDirectoryFailure.invalidOutput }
            do { let event = try transfer.text(Array(p.dropFirst(3))); upload = transfer.phase == .complete ? nil : transfer; return .upload(event) }
            catch { upload = transfer; throw error }
        }
        if download != nil || folder != nil || upload != nil || folderUpload != nil || action != nil || edit != nil
            || pendingEditSourceRelease != nil,
           !["profile", "networkDrained", "closed"].contains(p[3]) { throw SMBDirectoryFailure.invalidOutput }
        switch p[3] {
        case "connected":
            guard p.count == 5, !connected, ["encrypted", "signed"].contains(p[4]),
                  !requireEncryption || p[4] == "encrypted" else { throw SMBDirectoryFailure.invalidOutput }
            connected = true; return .connected(encrypted: p[4] == "encrypted")
        case "began":
            guard connected, p.count == 6, let desired, try number(p[4], UInt64.self) == desired.number,
                  p[5] == desired.id.uuidString, current == nil || current?.idle == true else { throw SMBDirectoryFailure.invalidOutput }
            if pendingPage?.number == current?.number && pendingPage != nil
                || pendingFind?.number == current?.number && pendingFind != nil { retired = current }
            current = Read(number: desired.number, components: desired.components, decoder: SMBDirectoryCatalogDecoder(session: session, read: desired.id))
            self.desired = nil; return .began(desired.number, desired.id)
        case "snapshot":
            guard p.count == 10, var read = current, try number(p[4], UInt64.self) == read.number,
                  !read.idle, p[5] == read.decoder.read.uuidString else { throw SMBDirectoryFailure.invalidOutput }
            let state: String
            switch p[9] { case "0": state = "loading"; case "1": state = "complete"; case "2": state = "partial"; case "3": state = "stopped"; default: throw SMBDirectoryFailure.invalidOutput }
            let event = try read.consume("snapshot \(p[5]) \(p[6]) \(p[7]) \(p[8]) \(state)", session: session)
            current = read
            if case .snapshot(let value) = event, read.number == issued { return .snapshot(read.number, value) }
            return nil
        case "folderSize":
            guard p.count == 16, let pending = pendingFolderSize,
                  p[4] == pending.selection.request.uuidString,
                  try number(p[5], UInt64.self) == pending.number,
                  p[6] == pending.selection.snapshot.readID.uuidString,
                  try number(p[7], UInt64.self) == pending.selection.snapshot.revision,
                  try number(p[8], Int64.self) == pending.selection.snapshot.count,
                  try number(p[9], Int64.self) == pending.selection.snapshot.folders, p[10] == "1",
                  try number(p[11], Int64.self) == pending.selection.observation.id else { throw SMBDirectoryFailure.invalidOutput }
            let bytes = try number(p[12], UInt64.self), files = try number(p[13], UInt32.self)
            let folders = try number(p[14], UInt32.self), links = try number(p[15], UInt32.self)
            guard let summary = try? RemoteFolderSizeSummary(logicalBytes: bytes, files: files,
                folders: folders, excludedLinks: links) else { throw SMBDirectoryFailure.invalidOutput }
            pendingFolderSize = nil
            guard pending.number == issued, pending.selection.snapshot == snapshot else { return .folderSizeUnavailable(pending.selection.request, .stale) }
            return .folderSize(pending.selection.request, summary)
        case "folderSizeUnavailable":
            guard p.count == 6, let pending = pendingFolderSize, p[4] == pending.selection.request.uuidString,
                  let failure = RemoteFolderSizeFailure(wireReason: try number(p[5], UInt8.self)) else { throw SMBDirectoryFailure.invalidOutput }
            pendingFolderSize = nil; return .folderSizeUnavailable(pending.selection.request, failure)
        case "find", "findStale", "findUnavailable":
            guard let pendingFind, p.count >= 7, p[4] == pendingFind.request.token.uuidString,
                  try number(p[5], UInt64.self) == pendingFind.number else { throw SMBDirectoryFailure.invalidOutput }
            let payload = "\(p[3]) \(p[4]) " + p[6...].joined(separator: " ")
            let event: SMBDirectoryCatalogEvent?
            if var read = current, read.number == pendingFind.number {
                event = try read.consume(payload, session: session); current = read
            } else if var read = retired, read.number == pendingFind.number {
                event = try read.consume(payload, session: session); retired = read
            } else { throw SMBDirectoryFailure.invalidOutput }
            self.pendingFind = nil; retired = nil
            if case .found(let result) = event, pendingFind.number == issued { return .found(pendingFind.number, result) }
            if case .queryUnavailable(let id) = event { return .queryUnavailable(id) }
            return .stale(pendingFind.request.token)
        case "row", "page", "stale", "findRow", "findPage", "findPageStale", "findPageUnavailable":
            guard let pendingPage, p.count >= 6, p[4] == pendingPage.request.token.uuidString,
                  try number(p[5], UInt64.self) == pendingPage.number else { throw SMBDirectoryFailure.invalidOutput }
            let payload: String
            switch p[3] {
            case "row":
                guard p.count == 11 || p.count == 13 else { throw SMBDirectoryFailure.invalidOutput }
                payload = "row \(p[4]) " + p[6...].joined(separator: " ")
            case "page":
                guard p.count == 10 else { throw SMBDirectoryFailure.invalidOutput }
                payload = "page \(p[4]) " + p[6...9].joined(separator: " ")
            case "findRow", "findPage", "findPageStale", "findPageUnavailable":
                payload = "\(p[3]) \(p[4]) " + p[6...].joined(separator: " ")
            default:
                guard p.count == 6 else { throw SMBDirectoryFailure.invalidOutput }
                payload = "stale \(p[4])"
            }
            let event: SMBDirectoryCatalogEvent?
            if var read = current, read.number == pendingPage.number {
                event = try read.consume(payload, session: session); current = read
            } else if var read = retired, read.number == pendingPage.number {
                event = try read.consume(payload, session: session); retired = read
            } else { throw SMBDirectoryFailure.invalidOutput }
            if p[3] == "row" || p[3] == "findRow" { return nil }
            self.pendingPage = nil; retired = nil
            if case .page(let page) = event, pendingPage.number == issued { return .page(pendingPage.number, page) }
            if case .queryUnavailable(let id) = event { return .queryUnavailable(id) }
            return .stale(pendingPage.request.token)
        case "rejected":
            guard p.count == 7, var read = current, !read.idle,
                  try number(p[4], UInt64.self) == read.number, p[5] == read.decoder.read.uuidString,
                  let reason = SMBDirectoryRejection(rawValue: p[6]), let snapshot = read.decoder.snapshot,
                  snapshot.state == .stopped, snapshot.count == 0, snapshot.folders == 0 else { throw SMBDirectoryFailure.invalidOutput }
            read.idle = true; read.rejection = reason; current = read
            return read.number == issued ? .rejected(read.number, reason) : nil
        case "idle":
            guard p.count == 6, ["complete", "cancelled"].contains(p[5]) else { throw SMBDirectoryFailure.invalidOutput }
            let n = try number(p[4], UInt64.self)
            if let desired, desired.number == n, p[5] == "cancelled" {
                self.desired = nil; return .idle(n, cancelled: true)
            }
            guard var read = current, n == read.number, !read.idle, let snapshot = read.decoder.snapshot,
                  p[5] == "complete" ? snapshot.state == .complete : snapshot.state == .stopped else { throw SMBDirectoryFailure.invalidOutput }
            read.idle = true; current = read
            return n == issued ? .idle(n, cancelled: p[5] == "cancelled") : nil
        case "networkDrained":
            guard profileReceived, p.count == 7, ["0", "4"].contains(p[4]), p[5] == "0", try number(p[6], UInt64.self) <= 1,
                  !connected || p[4] == "4" else { throw SMBDirectoryFailure.invalidOutput }
            drained = true; return .networkDrained
        case "profile":
            guard p.count == 5, !profileReceived else { throw SMBDirectoryFailure.invalidOutput }
            let fields = p[4].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 19 else { throw SMBDirectoryFailure.invalidOutput }
            let counts = try fields.map { try number($0, UInt64.self) }
            let forbidden: [Int]
            if mode == .metadata {
                forbidden = [7, 8, 9, 10, 11, 15, 16, 17, 18]
            } else if mode == .selectedUpload && uploadAttempted {
                forbidden = copyActionBegun ? [10, 15, 18] : [10, 11, 15, 18]
            } else {
                forbidden = [7, 9, 10, 11, 15, 17, 18]
            }
            guard forbidden.allSatisfy({ counts[$0] == 0 }) else { throw SMBDirectoryFailure.invalidOutput }
            profileReceived = true; return .profile(counts)
        case "closed":
            guard p.count == 7, drained, p[5] == "1", p[6] == "0",
                  (["invalid", "ipc", "stopped", "deadline", "remote", "authentication", "denied", "security", "storage", "quota", "close"].contains(p[4])
                    || (p[4] == "actionRefused" && actionRefused)) else {
                throw SMBDirectoryFailure.invalidOutput
            }
            closed = true; current = nil; retired = nil; desired = nil; pendingPage = nil; pendingFind = nil; pendingFolderSize = nil; pendingEditSourceRelease = nil; download = nil; folder = nil; upload = nil; folderUpload = nil; action = nil; edit = nil
            return .closed(p[4])
        default: throw SMBDirectoryFailure.invalidOutput
        }
    }

    private func number<T: FixedWidthInteger>(_ text: String, _ type: T.Type) throws -> T {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = T(text), String(value) == text else {
            throw SMBDirectoryFailure.invalidOutput
        }
        return value
    }
}
