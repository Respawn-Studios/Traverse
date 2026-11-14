import CryptoKit
import Darwin
import Foundation
import Security

enum SFTPProtocolFailure: Error, Equatable, Sendable {
    case invalidInput, invalidOutput, stale, phase, trust, closed
}

/// A fully framed, request-scoped refusal. It carries no remote path or server
/// text and never stands for transport loss, a partial frame or failed CLOSE.
@_spi(Qualification) public enum SFTPDirectoryRejection: UInt8, Error, Sendable { case missing = 2, denied = 3, unavailable = 4 }

/// Public-key bytes are canonical SSH blobs, not file paths or private keys.
@_spi(Qualification) public struct SFTPHostKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let bytes: Data
    public let fingerprint: String
    public let algorithm: String
    public var description: String { "<SFTP host key>" }
    public var debugDescription: String { description }
    init(_ bytes: Data) throws {
        guard (32...16384).contains(bytes.count) else { throw SFTPProtocolFailure.trust }
        var cursor = SFTPCursor(bytes)
        let name = try cursor.text(cap: 32)
        do {
            switch name {
            case "ssh-ed25519":
                _ = try Curve25519.Signing.PublicKey(rawRepresentation: cursor.field(cap: 32))
            case "ecdsa-sha2-nistp256":
                guard try cursor.text(cap: 8) == "nistp256" else { throw SFTPProtocolFailure.trust }
                _ = try P256.Signing.PublicKey(x963Representation: cursor.field(cap: 65))
            case "ecdsa-sha2-nistp384":
                guard try cursor.text(cap: 8) == "nistp384" else { throw SFTPProtocolFailure.trust }
                _ = try P384.Signing.PublicKey(x963Representation: cursor.field(cap: 97))
            case "ecdsa-sha2-nistp521":
                guard try cursor.text(cap: 8) == "nistp521" else { throw SFTPProtocolFailure.trust }
                _ = try P521.Signing.PublicKey(x963Representation: cursor.field(cap: 133))
            case "ssh-rsa":
                let encodedExponent = try cursor.field(cap: 5), encodedModulus = try cursor.field(cap: 513)
                func positive(_ data: Data) throws -> Data {
                    guard let first = data.first, first & 0x80 == 0,
                          first != 0 || data.count > 1 && data[data.startIndex + 1] & 0x80 != 0 else { throw SFTPProtocolFailure.trust }
                    return first == 0 ? Data(data.dropFirst()) : data
                }
                let exponent = try positive(encodedExponent), modulus = try positive(encodedModulus)
                let bits = modulus.count * 8 - (modulus.first?.leadingZeroBitCount ?? 8)
                guard (2048...4096).contains(bits), modulus.last! & 1 != 0,
                      !exponent.isEmpty, exponent.count <= 4 else { throw SFTPProtocolFailure.trust }
                let value = exponent.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard value >= 65537, value & 1 != 0 else { throw SFTPProtocolFailure.trust }
                func der(_ tag: UInt8, _ data: Data) -> Data {
                    let length: Data = data.count < 128 ? Data([UInt8(data.count)])
                        : data.count < 256 ? Data([0x81, UInt8(data.count)]) : Data([0x82, UInt8(data.count >> 8), UInt8(data.count & 255)])
                    return Data([tag]) + length + data
                }
                let encoded = der(0x30, der(0x02, encodedModulus) + der(0x02, encodedExponent))
                guard SecKeyCreateWithData(encoded as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                    kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) != nil else { throw SFTPProtocolFailure.trust }
            default: throw SFTPProtocolFailure.trust
            }
        } catch { throw SFTPProtocolFailure.trust }
        guard cursor.finished else { throw SFTPProtocolFailure.trust }
        self.bytes = bytes
        algorithm = name
        fingerprint = "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

#if TRAVERSE_SFTP_EDITOR_QA
/// A read-only agent listing. The selected key remains in the worker; this
/// parent value contains no comment, socket path, private key, or raw blob.
@_spi(Qualification) public struct SFTPAgentIdentitySummary: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let digest: Data
    public let algorithm: String
    public var fingerprint: String {
        "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    public var description: String { "<SFTP agent identity>" }
    public var debugDescription: String { description }
    init(digest: Data, algorithm: String) throws {
        let allowed: Set<String> = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
            "ecdsa-sha2-nistp521", "ssh-rsa", "sk-ssh-ed25519@openssh.com",
            "sk-ecdsa-sha2-nistp256@openssh.com"]
        guard digest.count == 32, allowed.contains(algorithm) else { throw SFTPProtocolFailure.invalidOutput }
        self.digest = digest; self.algorithm = algorithm
    }
}
#endif

@_spi(Qualification) public struct SFTPRemoteName: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let wireUTF8: Data
    public var description: String { "<SFTP remote name>" }
    public var debugDescription: String { description }
    public init(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= 8192, let name = String(data: bytes, encoding: .utf8),
              name != ".", name != "..", !bytes.contains(0), !bytes.contains(47),
              Data(name.utf8) == bytes else { throw SFTPProtocolFailure.invalidOutput }
        wireUTF8 = bytes
    }
    private static func requiresPresentationEscape(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
            || [0x061c, 0x200e, 0x200f].contains(scalar.value)
            || (0x202a...0x202e).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }
    /// A typed, single-line action name may contain an ordinary backslash, but
    /// never a scalar that the remote-name presenter must escape.
    public var isSafeForSingleLineEntry: Bool {
        String(decoding: wireUTF8, as: UTF8.self).unicodeScalars.allSatisfy { !Self.requiresPresentationEscape($0) }
    }
    /// Escape control/bidi text and literal backslashes for unambiguous
    /// presentation while retaining exact bytes for remote requests.
    public var displayName: String {
        String(decoding: wireUTF8, as: UTF8.self).unicodeScalars.map { scalar in
            if scalar.value == 0x5c { return "\\\\" }
            if Self.requiresPresentationEscape(scalar) {
                return "\\u{\(String(scalar.value, radix: 16))}"
            }
            return String(scalar)
        }.joined()
    }
}

@_spi(Qualification) public struct SFTPWorkerEntry: Sendable, Equatable {
    public let name: SFTPRemoteName
    public let logicalBytes: UInt64?
    public let modifiedSeconds: UInt32?
    public let permissions: UInt32?
    public var isDirectory: Bool? { permissions.map { $0 & 0o170000 == 0o040000 } }
}
enum SFTPWireMode: Sendable { case batches, catalog, transferCatalog, uploadCatalog, keyCatalog, keyTransferCatalog, keyUploadCatalog
    case interactiveCatalog, interactiveTransferCatalog, interactiveUploadCatalog
    case jumpCatalog, rememberedJumpCatalog, folderCatalog, folderUploadCatalog, routedFolderCatalog, exclusiveUploadCatalog, freshFolderUploadCatalog, routedExclusiveUploadCatalog, routedFreshFolderUploadCatalog
    case originalEditCatalog, routedOriginalEditCatalog, inPlaceEditCatalog, routedInPlaceEditCatalog
    case remoteActionCatalog, routedRemoteActionCatalog
    #if TRAVERSE_SFTP_EDITOR_QA
    case agentCatalog
    #endif
    var allowsRemoteActions: Bool { self == .remoteActionCatalog || self == .routedRemoteActionCatalog }
    var isAgent: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        return self == .agentCatalog
        #else
        return false
        #endif
    }
    var allowsInPlaceEditing: Bool { self == .inPlaceEditCatalog || self == .routedInPlaceEditCatalog }
    var requiresSharedTextBudget: Bool { allowsOriginalEditing || allowsInPlaceEditing }
    var allowsOriginalEditing: Bool { self == .originalEditCatalog || self == .routedOriginalEditCatalog }
    var allowsFolderDownloads: Bool {
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
        self == .folderCatalog || self == .folderUploadCatalog || self == .routedFolderCatalog || self == .exclusiveUploadCatalog || self == .freshFolderUploadCatalog || self == .routedExclusiveUploadCatalog || self == .routedFreshFolderUploadCatalog
        #else
        false
        #endif
    }
    var isCatalog: Bool { self != .batches }
    var isJump: Bool { self == .jumpCatalog || self == .rememberedJumpCatalog || self == .routedFolderCatalog || self == .routedExclusiveUploadCatalog || self == .routedFreshFolderUploadCatalog || self == .routedOriginalEditCatalog || self == .routedInPlaceEditCatalog || self == .routedRemoteActionCatalog }
    var hasRouteBinding: Bool { self == .rememberedJumpCatalog || self == .routedFolderCatalog || self == .routedExclusiveUploadCatalog || self == .routedFreshFolderUploadCatalog || self == .routedOriginalEditCatalog || self == .routedInPlaceEditCatalog || self == .routedRemoteActionCatalog }
    var allowsInteractiveAuthentication: Bool { self == .interactiveCatalog || self == .interactiveTransferCatalog || self == .interactiveUploadCatalog || isJump || allowsFolderDownloads || allowsOriginalEditing || allowsInPlaceEditing || allowsRemoteActions }
    var allowsKeyAuthentication: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        if self == .agentCatalog { return true }
        #endif
        return self == .keyCatalog || self == .keyTransferCatalog || self == .keyUploadCatalog || allowsInteractiveAuthentication
    }
    var allowsDownloads: Bool { self == .transferCatalog || self == .uploadCatalog || self == .keyTransferCatalog || self == .keyUploadCatalog || self == .interactiveTransferCatalog || self == .interactiveUploadCatalog || allowsFolderDownloads }
    var allowsUploads: Bool {
        #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
        (self == .exclusiveUploadCatalog || self == .freshFolderUploadCatalog || self == .routedExclusiveUploadCatalog || self == .routedFreshFolderUploadCatalog) && allowsFolderDownloads
        #else
        false
        #endif
    }
    var allowsFolderUploads: Bool {
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
        (self == .freshFolderUploadCatalog || self == .routedFreshFolderUploadCatalog) && allowsUploads
        #else
        false
        #endif
    }
    var magic: Data {
        switch self {
        case .batches: Data("MEXSFTP1".utf8)
        case .catalog: Data("MEXSFTP2".utf8)
        case .transferCatalog: Data("MEXSFTP3".utf8)
        case .uploadCatalog: Data("MEXSFTP4".utf8)
        case .keyCatalog: Data("MEXSFTP5".utf8)
        case .keyTransferCatalog: Data("MEXSFTP6".utf8)
        case .keyUploadCatalog: Data("MEXSFTP7".utf8)
        case .interactiveCatalog: Data("MEXSFTP8".utf8)
        case .interactiveTransferCatalog: Data("MEXSFTP9".utf8)
        case .interactiveUploadCatalog: Data("MEXSFTPA".utf8)
        case .jumpCatalog: Data("MEXSFTPB".utf8)
        case .rememberedJumpCatalog: Data("MEXSFTPC".utf8)
        case .folderCatalog: Data("MEXSFTPD".utf8)
        case .folderUploadCatalog: Data("MEXSFTPE".utf8)
        case .routedFolderCatalog: Data("MEXSFTPF".utf8)
        case .exclusiveUploadCatalog: Data("MEXSFTPG".utf8)
        case .freshFolderUploadCatalog: Data("MEXSFTPH".utf8)
        case .routedExclusiveUploadCatalog: Data("MEXSFTPI".utf8)
        case .routedFreshFolderUploadCatalog: Data("MEXSFTPJ".utf8)
        case .originalEditCatalog: Data("MEXSFTPK".utf8)
        case .routedOriginalEditCatalog: Data("MEXSFTPL".utf8)
        case .inPlaceEditCatalog: Data("MEXSFTPM".utf8)
        case .routedInPlaceEditCatalog: Data("MEXSFTPN".utf8)
        case .remoteActionCatalog: Data("MEXSFTPO".utf8)
        case .routedRemoteActionCatalog: Data("MEXSFTPP".utf8)
        #if TRAVERSE_SFTP_EDITOR_QA
        case .agentCatalog: Data("MEXSFTPQ".utf8)
        #endif
        }
    }
}
@_spi(Qualification) public struct SFTPStoredSnapshot: Sendable, Equatable {
    public enum State: UInt8, Sendable { case loading, complete, partial, stopped }
    public let read: UInt64, revision: UInt64, count: UInt64, folders: UInt64
    public let state: State
}
@_spi(Qualification) public struct SFTPStoredRow: Sendable, Equatable {
    public let observation: UInt64
    public let entry: SFTPWorkerEntry
}
@_spi(Qualification) public enum SFTPStoredSort: UInt8, Sendable { case name, size, modified }
@_spi(Qualification) public struct SFTPStoredPage: Sendable {
    public let request: UUID, generation: UUID
    public let snapshot: SFTPStoredSnapshot
    public let offset: UInt64
    public let rows: [SFTPStoredRow]
    public let find: SFTPDirectoryFindResult?
    public init(request: UUID, generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64,
                rows: [SFTPStoredRow], find: SFTPDirectoryFindResult? = nil) {
        self.request = request; self.generation = generation; self.snapshot = snapshot
        self.offset = offset; self.rows = rows; self.find = find
    }
}

@_spi(Qualification) public enum SFTPTrustAction: UInt8, Sendable { case reject, connectOnce, remember, useMatching, replaceVerified }
@_spi(Qualification) public struct SFTPHostChallenge: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: UInt8, Sendable { case first = 1, matching, changed }
    public let session: UUID
    public let host: String
    public let port: UInt16
    public let current: SFTPHostKey
    public let previous: SFTPHostKey?
    public var description: String { "<SFTP host review>" }
    public var debugDescription: String { description }
    public var kind: Kind { previous.map { $0 == current ? .matching : .changed } ?? .first }
    func permits(_ action: SFTPTrustAction) -> Bool {
        switch (kind, action) {
        case (_, .reject), (.first, .connectOnce), (.first, .remember), (.matching, .useMatching), (.changed, .replaceVerified): true
        default: false
        }
    }
}

/// Only this decoder can construct verification evidence. It does not grant
/// file access, save trust or read a password; the parent still owns those acts.
struct SFTPVerifiedHost: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let session: UUID
    let host: String
    let port: UInt16
    let key: SFTPHostKey
    var description: String { "<SFTP verified host>" }
    var debugDescription: String { description }
    fileprivate init(_ challenge: SFTPHostChallenge) {
        session = challenge.session; host = challenge.host; port = challenge.port; key = challenge.current
    }
}
@_spi(Qualification) public struct SFTPWorkerTerminal: Sendable {
    public enum WriterEnd: UInt8, Sendable { case notStarted, closed, failed }
    public let outcome: UInt8
    public let directoryCloseAcknowledged: Bool
    public let sshTaskEndedBeforeRuntimeDrop: Bool
    public let tasksBeforeRuntimeDrop: UInt64
    public let tasksAfterRuntimeDrop: UInt64
    public let catalogWriterEnd: WriterEnd?
    public var jumpTaskEndedBeforeRuntimeDrop: Bool? = nil
    /// This is only runtime evidence. Actual process exit and IPC EOF remain
    /// mandatory in the parent before releasing its activity/storage leases.
    public var runtimeDisposed: Bool { tasksAfterRuntimeDrop == 0 }
}
enum SFTPWorkerEvent: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case inPlace(SFTPInPlaceWorkerEvent)
    case original(SFTPOriginalWorkerEvent)
    case challenge(SFTPHostChallenge), verified(SFTPVerifiedHost), authenticated, authenticatedIdentity(SFTPHostKey), ready
    #if TRAVERSE_SFTP_EDITOR_QA
    case agentIdentities([SFTPAgentIdentitySummary]), agentSelected(Data)
    #endif
    case interactiveChallenge(SFTPInteractiveChallenge)
    case jumpChallenge(SFTPHostChallenge), jumpVerified(SFTPVerifiedHost), jumpIdentity(SFTPHostKey), jumpAuthenticated
    case jumpInteractiveChallenge(SFTPInteractiveChallenge)
    case directory(UUID, String), batch(UUID, [SFTPWorkerEntry], end: Bool), closed(SFTPWorkerTerminal)
    case storedDirectory(UUID, String, SFTPStoredSnapshot), storedProgress(UUID, SFTPStoredSnapshot)
    case storedPage(SFTPStoredPage), stalePage(UUID)
    case found(SFTPDirectoryFindResult), findStale(UUID), findUnavailable(UUID)
    case folderSize(UUID, RemoteFolderSizeSummary), folderSizeUnavailable(UUID, RemoteFolderSizeFailure)
    case filteredPageUnavailable(UUID)
    case remoteActionPrepared(UUID), remoteActionConfirmed(UUID)
    case remoteActionRefused(UUID, SFTPRemoteActionRefusal), remoteActionNeedsReview(UUID)
    case directoryRecoveryEnabled, directoryRejected(UUID, SFTPDirectoryRejection)
    case downloadStarted(SFTPDownloadSelection), downloadBytes(UUID, UInt64, Data), downloadComplete(SFTPDownloadReceipt)
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
    case downloadCheckpoint(UUID)
    case folderStarted(UUID), folderMetadataProgress(UUID, UInt8, Int), folderPrepared(SFTPPreparedFolderDownload), folderReceiving(UUID)
    case folderMemberStarted(UUID, Int), folderMemberBytes(UUID, Int, UInt64, Data), folderMemberFinished(UUID, Int, UInt64)
    case folderComplete(UUID, UInt64, Int), folderReleased(UUID)
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
    case uploadStarted(SFTPUploadSelection), uploadSourceRequest(UUID, UInt64, Int), uploadPublicationRequest(UUID, Data)
    case uploadComplete(SFTPUploadReceipt), uploadInterrupted(SFTPUploadInterruption)
    case uploadOpenRefused(SFTPUploadOpenRefusal)
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
    case folderUploadStarted(SFTPFolderUploadSelection), folderUploadManifestRequest(UUID, Int, Int)
    case folderUploadSourceRequest(UUID, Int, UInt64, Int), folderUploadFilePermitRequest(UUID, Int, Data)
    case folderUploadRootCreated(UUID), folderUploadVerified(UUID, Int, Int, UInt64), folderUploadFinalPermitRequest(UUID, Data)
    case folderUploadComplete(SFTPFolderUploadReceipt), folderUploadInterrupted(SFTPFolderUploadInterruption)
    #endif
    var description: String { "<SFTP worker event>" }
    var debugDescription: String { description }
}

struct SFTPWorkerDecoder {
    static let maximumFrameBytes = 65536
    private enum Phase { case routing, challenge, verification, authentication, readying, ready, closed }
    let session: UUID
    let host: String
    let port: UInt16
    let previous: SFTPHostKey?
    let mode: SFTPWireMode
    private let inPlaceTransfers: SFTPInPlaceTransfers
    private let remoteActionEditorEnabled: Bool
    private var inPlaceEnabled: Bool { mode.allowsInPlaceEditing || mode.allowsRemoteActions && remoteActionEditorEnabled }
    private var permitsDownloads: Bool { mode.allowsDownloads || (mode.allowsInPlaceEditing || mode.allowsRemoteActions) && inPlaceTransfers.downloads }
    private var permitsFolderDownloads: Bool { mode.allowsFolderDownloads || (mode.allowsInPlaceEditing || mode.allowsRemoteActions) && inPlaceTransfers.folders }
    private var permitsUploads: Bool { mode.allowsUploads || (mode.allowsInPlaceEditing || mode.allowsRemoteActions) && inPlaceTransfers.uploads }
    private var permitsFolderUploads: Bool { mode.allowsFolderUploads || (mode.allowsInPlaceEditing || mode.allowsRemoteActions) && inPlaceTransfers.folderUploads }
    private var phase: Phase = .challenge
    private var inPlaceStartupAccepted = false
    private var sequence: UInt64 = 0
    private var valid = true
    private var challenge: SFTPHostChallenge?
    private var approval: SFTPTrustAction?
    private var keyAuthentication = false, identityReceived = false
    private var certificateAuthentication = false
    #if TRAVERSE_SFTP_EDITOR_QA
    private var agentListRequested = false, agentListReceived = false
    private var agentIdentities: [SFTPAgentIdentitySummary] = []
    private var agentSelectionDigest: Data?
    #endif
    private var expectedIdentity: SFTPHostKey?
    private var interactiveStarted = false
    private var interactiveRound: UInt8 = 0
    private var pendingInteractive: SFTPInteractiveChallenge?
    private var jump: SFTPJumpProtocolState?
    private var generation: UUID?
    private var awaitingDirectory = false
    private var reading = false
    private var complete = false
    private var everOpened = false
    private var recoveryRequested = false, recoveryEnabled = false
    private var pending: [SFTPWorkerEntry] = []
    private var pendingNames = Set<Data>()
    private var pendingBytes = 0
    private var storedSnapshot: SFTPStoredSnapshot?
    private var canonicalDirectory: String?
    private struct Query {
        let request: UUID, generation: UUID
        let snapshot: SFTPStoredSnapshot
        let offset: UInt64
        let limit: Int
        var find: SFTPDirectoryFindResult? = nil
        var finding: RemoteDirectoryFindQuery? = nil
        var sizing: SFTPFolderSizeSelection? = nil
        var count: UInt64 { find?.count ?? snapshot.count }
    }
    private var query: Query?
    private var activeFind: SFTPDirectoryFindResult?
    private var pageStarted = false
    private var storedRows: [SFTPStoredRow] = []
    private var storedNames = Set<Data>(), storedObservations = Set<UInt64>()
    private var storedBytes = 0
    private struct Download {
        let selection: SFTPDownloadSelection
        var started = false
        var received: UInt64 = 0
    }
    private var download: Download?
    private var original = SFTPOriginalProtocolState()
    private var inPlace = SFTPInPlaceProtocolState()
    private enum RemoteActionPhase: Equatable { case preparing, prepared, permitted }
    private var remoteAction: (request: UUID, phase: RemoteActionPhase)?
    private(set) var supportsServerCopy = false
    private var serverCopyCapabilityReceived = false
    var inPlaceBaselineCapacityAvailable: Bool { inPlaceEnabled && inPlace.isIdle && inPlace.liveBaselineCount < 2 }
    var originalBaselineCapacityAvailable: Bool { mode.allowsOriginalEditing && original.isIdle && original.liveBaselineCount < 2 }
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
    private var folder: SFTPFolderProtocolState?
    private var folderIsIdle: Bool { folder == nil }
    #else
    private var folderIsIdle: Bool { true }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
    private struct Upload {
        let selection: SFTPUploadSelection
        var started = false, sent: UInt64 = 0
        var sourceRequest: (offset: UInt64, count: Int)?
        var requestedDigest: Data?, permittedDigest: Data?
    }
    private var upload: Upload?
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
    private var folderUpload: SFTPFolderUploadProtocolState?
    private var folderUploadIsIdle: Bool { folderUpload == nil }
    #else
    private var folderUploadIsIdle: Bool { true }
    #endif
    private var uploadIsIdle: Bool {
        #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
        upload == nil && folderUploadIsIdle && original.isIdle && inPlace.isIdle
        #else
        original.isIdle && inPlace.isIdle
        #endif
    }

    init(session: UUID, canonicalHost: String, port: UInt16, previous: SFTPHostKey? = nil, mode: SFTPWireMode = .batches,
         jump: SFTPJumpIdentity? = nil, inPlaceTransfers: SFTPInPlaceTransfers = .none,
         remoteActionEditorEnabled: Bool = false) throws {
        guard SFTPWire.validToken(session), Self.host(canonicalHost), port > 0,
              ![SFTPWireMode.exclusiveUploadCatalog,.freshFolderUploadCatalog,.routedExclusiveUploadCatalog,.routedFreshFolderUploadCatalog].contains(mode) || mode.allowsUploads,
              ![SFTPWireMode.freshFolderUploadCatalog,.routedFreshFolderUploadCatalog].contains(mode) || mode.allowsFolderUploads else { throw SFTPProtocolFailure.invalidInput }
        guard ![SFTPWireMode.folderCatalog,.folderUploadCatalog,.routedFolderCatalog,.exclusiveUploadCatalog,.freshFolderUploadCatalog,.routedExclusiveUploadCatalog,.routedFreshFolderUploadCatalog].contains(mode) || mode.allowsFolderDownloads else { throw SFTPProtocolFailure.invalidInput }
        self.session = session; host = canonicalHost; self.port = port; self.previous = previous; self.mode = mode
        self.inPlaceTransfers = inPlaceTransfers; self.remoteActionEditorEnabled = remoteActionEditorEnabled
        guard mode.allowsInPlaceEditing || mode.allowsRemoteActions || inPlaceTransfers == .none,
              mode.allowsRemoteActions || !remoteActionEditorEnabled,
              !inPlaceTransfers.folders || SFTPWireMode.folderCatalog.allowsFolderDownloads,
              !inPlaceTransfers.uploads || SFTPWireMode.exclusiveUploadCatalog.allowsUploads,
              !inPlaceTransfers.folderUploads || SFTPWireMode.freshFolderUploadCatalog.allowsFolderUploads else { throw SFTPProtocolFailure.invalidInput }
        guard mode.isJump == (jump != nil), mode != .jumpCatalog || previous == nil && jump?.previous == nil else { throw SFTPProtocolFailure.invalidInput }
        if let jump {
            guard Self.host(jump.host), jump.port > 0, SFTPWire.validToken(jump.nonce), jump.nonce != session else { throw SFTPProtocolFailure.invalidInput }
            self.jump = SFTPJumpProtocolState(identity: jump, permitsRememberedRoute: mode.hasRouteBinding); phase = .routing
        }
    }
    private static func host(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, host == host.lowercased() else { return false }
        if host.contains(":") {
            var raw = in6_addr(); return host.withCString { inet_pton(AF_INET6, $0, &raw) } == 1
        }
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            var raw = in_addr(); return host.withCString { inet_pton(AF_INET, $0, &raw) } == 1
        }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
    mutating func noteApproval(_ action: SFTPTrustAction, challenge expected: SFTPHostChallenge) throws {
        guard valid, phase == .verification, challenge == expected, approval == nil, expected.permits(action) else {
            valid = false; throw SFTPProtocolFailure.trust
        }
        guard !mode.isJump || (mode.hasRouteBinding ? action != .remember : action == .connectOnce || action == .reject) else { throw SFTPProtocolFailure.trust }
        approval = action
    }
    mutating func noteJumpApproval(_ action: SFTPTrustAction, challenge: SFTPHostChallenge) throws {
        guard valid, phase == .routing, jump != nil else { throw SFTPProtocolFailure.phase }
        try jump!.approve(action, review: challenge)
    }
    mutating func noteJumpAuthentication(key: Bool, interactive: Bool, expected: SFTPHostKey? = nil) throws {
        guard valid, phase == .routing, jump != nil else { throw SFTPProtocolFailure.phase }
        try jump!.beginAuthentication(key: key, interactive: interactive, expected: expected)
    }
    mutating func noteJumpAnswers(_ challenge: SFTPInteractiveChallenge, answers: SFTPInteractiveAnswers) throws {
        guard valid, phase == .routing, jump != nil else { throw SFTPProtocolFailure.phase }
        try jump!.answer(challenge, answers: answers)
    }
    mutating func noteKeyAuthentication(expected: SFTPHostKey?) throws {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard !mode.isAgent else { throw SFTPProtocolFailure.phase }
        #endif
        guard valid, phase == .authentication, mode.allowsKeyAuthentication,
              !keyAuthentication, !identityReceived else { throw SFTPProtocolFailure.phase }
        keyAuthentication = true; expectedIdentity = expected
    }
    /// New outcomes are legal only after this concrete direct certificate
    /// command; old key, routed and agent sessions retain their old grammar.
    mutating func noteCertificateAuthentication(expected: SFTPHostKey?, interactive: Bool) throws {
        guard !certificateAuthentication, !mode.isJump, !mode.isAgent else { throw SFTPProtocolFailure.phase }
        if interactive { try noteInteractiveAuthentication(expected: expected, usingKey: true) }
        else { try noteKeyAuthentication(expected: expected) }
        certificateAuthentication = true
    }
    #if TRAVERSE_SFTP_EDITOR_QA
    mutating func noteAgentList() throws {
        guard valid, mode == .agentCatalog, phase == .authentication,
              !agentListRequested, !agentListReceived, !keyAuthentication else { throw SFTPProtocolFailure.phase }
        agentListRequested = true
    }
    mutating func noteAgentSelection(_ summary: SFTPAgentIdentitySummary) throws {
        guard valid, mode == .agentCatalog, phase == .authentication,
              agentListReceived, agentSelectionDigest == nil,
              agentIdentities.contains(summary), !keyAuthentication else { throw SFTPProtocolFailure.phase }
        agentSelectionDigest = summary.digest; keyAuthentication = true
    }
    #endif
    mutating func noteInteractiveAuthentication(expected: SFTPHostKey?, usingKey: Bool) throws {
        guard valid, phase == .authentication, mode.allowsInteractiveAuthentication, !interactiveStarted,
              !keyAuthentication, !identityReceived, pendingInteractive == nil else { throw SFTPProtocolFailure.phase }
        if usingKey { try noteKeyAuthentication(expected: expected) }
        interactiveStarted = true
    }
    mutating func noteInteractiveAnswers(_ challenge: SFTPInteractiveChallenge, answers: SFTPInteractiveAnswers) throws {
        guard valid, phase == .authentication, interactiveStarted, pendingInteractive == challenge,
              answers.values.count == challenge.prompts.count else { throw SFTPProtocolFailure.phase }
        pendingInteractive = nil
    }
    mutating func beginDirectory(_ id: UUID) throws {
        guard valid, phase == .ready, !recoveryRequested, !reading, pending.isEmpty, !awaitingDirectory, query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil,
              SFTPWire.validToken(id), id != generation else { throw SFTPProtocolFailure.phase }
        generation = id; awaitingDirectory = true; complete = false; storedSnapshot = nil; canonicalDirectory = nil; activeFind = nil
    }
    mutating func beginDirectoryRecovery() throws {
        guard valid, mode.isCatalog, phase == .ready, !everOpened, generation == nil,
              !recoveryRequested, !recoveryEnabled else { throw SFTPProtocolFailure.phase }
        recoveryRequested = true
    }
    mutating func beginNext(_ id: UUID) throws {
        guard valid, phase == .ready, generation == id, !awaitingDirectory, !complete,
              !reading, pending.isEmpty, query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil else { throw SFTPProtocolFailure.phase }
        reading = true
    }
    mutating func beginPage(_ request: UUID, generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, limit: Int,
                            find: SFTPDirectoryFindResult? = nil) throws {
        guard valid, phase == .ready, mode.isCatalog, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil,
              SFTPWire.validToken(request), offset <= UInt64(Int64.max), (1...256).contains(limit) else { throw SFTPProtocolFailure.phase }
        guard self.generation == generation, storedSnapshot == snapshot else { throw SFTPProtocolFailure.stale }
        guard find == nil || find == activeFind else { throw SFTPProtocolFailure.stale }
        query = Query(request: request, generation: generation, snapshot: snapshot, offset: offset, limit: limit, find: find)
    }
    mutating func beginFind(_ value: RemoteDirectoryFindQuery, generation: UUID, snapshot: SFTPStoredSnapshot) throws {
        try beginPage(value.id, generation: generation, snapshot: snapshot, offset: 0, limit: 1)
        query?.finding = value; activeFind = nil
    }
    mutating func beginFolderSize(_ value: SFTPFolderSizeSelection) throws {
        guard value.snapshot.state == .complete else { throw SFTPProtocolFailure.stale }
        try beginPage(value.request, generation: value.generation, snapshot: value.snapshot, offset: 0, limit: 1)
        query?.sizing = value
    }
    mutating func beginDownload(_ selection: SFTPDownloadSelection) throws {
        guard valid, permitsDownloads, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil, complete, storedSnapshot?.state == .complete else { throw SFTPProtocolFailure.phase }
        guard generation == selection.generation else { throw SFTPProtocolFailure.stale }
        download = Download(selection: selection)
    }
    mutating func beginInPlaceRead(_ selection: SFTPDownloadSelection, snapshot: SFTPStoredSnapshot) throws {
        guard valid, inPlaceEnabled, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil, complete, snapshot.state == .complete,
              storedSnapshot == snapshot, generation == selection.generation else { throw SFTPProtocolFailure.phase }
        try inPlace.beginRead(selection, catalogRevision: snapshot.revision)
    }
    mutating func beginInPlaceSave(_ record: SFTPInPlaceRecord) throws {
        // The document retains its captured target; current browse generation
        // intentionally need not match after an ordinary folder navigation.
        guard valid, inPlaceEnabled, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil, record.session == session else { throw SFTPProtocolFailure.phase }
        try inPlace.beginSave(record)
    }
    mutating func beginInPlaceRelease(_ payload: Data) throws {
        guard valid, inPlaceEnabled, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil else { throw SFTPProtocolFailure.phase }
        try inPlace.beginRelease(payload)
    }
    mutating func noteInPlaceAcceptance(_ payload: Data) throws { try inPlace.noteAcceptance(payload) }
    mutating func noteInPlaceSource(_ payload: Data) throws { try inPlace.noteSource(payload) }
    mutating func noteInPlacePermit(_ payload: Data) throws { try inPlace.notePermit(payload) }
    mutating func beginOriginalRead(_ selection: SFTPDownloadSelection, snapshot: SFTPStoredSnapshot) throws {
        guard valid, mode.allowsOriginalEditing, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil, complete,
              snapshot.state == .complete, storedSnapshot == snapshot,
              generation == selection.generation else { throw SFTPProtocolFailure.phase }
        try original.beginRead(selection)
    }
    mutating func beginOriginalSave(_ record: SFTPOriginalRecord) throws {
        guard valid, mode.allowsOriginalEditing, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil,
              record.session == session else { throw SFTPProtocolFailure.phase }
        try original.beginSave(record)
    }
    mutating func beginOriginalRelease(_ payload: Data) throws {
        guard valid, mode.allowsOriginalEditing, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil else { throw SFTPProtocolFailure.phase }
        try original.beginRelease(payload)
    }
    mutating func noteOriginalAcceptance(_ payload: Data) throws { try original.noteAcceptance(payload) }
    mutating func noteOriginalSource(_ payload: Data) throws { try original.noteSource(payload) }
    mutating func noteOriginalPermit(_ payload: Data) throws { try original.notePermit(payload) }
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
    mutating func beginFolder(_ selection: SFTPFolderDownloadSelection) throws {
        guard valid, permitsFolderDownloads, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil, complete,
              storedSnapshot?.state == .complete else { throw SFTPProtocolFailure.phase }
        guard generation == selection.generation, storedSnapshot?.read == selection.read,
              storedSnapshot?.revision == selection.revision else { throw SFTPProtocolFailure.stale }
        folder = .init(selection)
    }
    mutating func receiveFolder(_ prepared: SFTPPreparedFolderDownload) throws {
        guard valid, phase == .ready, folder != nil else { throw SFTPProtocolFailure.phase }; try folder!.beginReceipt(prepared)
    }
    mutating func releaseFolder(_ request: UUID) throws {
        guard valid, phase == .ready, folder != nil else { throw SFTPProtocolFailure.phase }; try folder!.beginRelease(request)
    }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
    func uploadDirectory(_ generation: UUID, revision: UInt64) throws -> String {
        guard valid, permitsUploads, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil, complete, storedSnapshot?.state == .complete else { throw SFTPProtocolFailure.phase }
        guard self.generation == generation, storedSnapshot?.revision == revision, let canonicalDirectory else { throw SFTPProtocolFailure.stale }
        return canonicalDirectory
    }
    mutating func beginUpload(_ selection: SFTPUploadSelection) throws {
        guard valid, permitsUploads, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil, complete, storedSnapshot?.state == .complete else { throw SFTPProtocolFailure.phase }
        guard generation == selection.generation, storedSnapshot?.revision == selection.revision,
              canonicalDirectory.map({ Data($0.utf8) }) == Data(selection.directory.utf8) else { throw SFTPProtocolFailure.stale }
        upload = Upload(selection: selection)
    }
    mutating func noteUploadSource(_ request: UUID, offset: UInt64, bytes: Data) throws -> Data {
        guard valid, permitsUploads, phase == .ready, var upload, upload.started, upload.selection.request == request,
              let source = upload.sourceRequest, source.offset == offset, source.count == bytes.count else { throw SFTPProtocolFailure.phase }
        var payload = SFTPWire.token(request); SFTPWire.number(offset, bytes: 8, into: &payload); try SFTPWire.field(bytes, into: &payload)
        upload.sent += UInt64(bytes.count); upload.sourceRequest = nil; self.upload = upload; return payload
    }
    mutating func noteUploadPublication(_ request: UUID, digest: Data) throws -> Data {
        guard valid, permitsUploads, phase == .ready, var upload, upload.selection.request == request,
              upload.requestedDigest == digest, upload.permittedDigest == nil else { throw SFTPProtocolFailure.phase }
        upload.permittedDigest = digest; self.upload = upload; return SFTPWire.token(request) + digest
    }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
    mutating func beginFolderUpload(_ selection: SFTPFolderUploadSelection) throws {
        guard valid, permitsFolderUploads, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil, complete, storedSnapshot?.state == .complete else { throw SFTPProtocolFailure.phase }
        guard generation == selection.generation, storedSnapshot?.revision == selection.revision,
              canonicalDirectory.map({ Data($0.utf8) }) == Data(selection.directory.utf8) else { throw SFTPProtocolFailure.stale }
        folderUpload = .init(selection)
    }
    mutating func noteFolderUploadReply(request: UUID, _ response: SFTPFolderUploadReply) throws -> (UInt8, Data) {
        guard valid, permitsFolderUploads, phase == .ready, var folderUpload else { throw SFTPProtocolFailure.phase }
        valid = false; let value = try folderUpload.reply(request: request, response); self.folderUpload = folderUpload; valid = true; return value
    }
    #endif
    func remoteActionDirectory(_ intent: SFTPRemoteActionIntent) throws -> String {
        guard valid, mode.allowsRemoteActions, phase == .ready, !reading, !awaitingDirectory,
              query == nil, download == nil, uploadIsIdle, folderIsIdle, remoteAction == nil,
              !(intent.kind == .renameDirectory || intent.kind == .moveFile || intent.kind == .moveDirectory || intent.kind == .copyFile)
                  || mode == .remoteActionCatalog,
              intent.kind != .copyFile || supportsServerCopy,
              complete, generation == intent.generation, storedSnapshot == intent.snapshot,
              let canonicalDirectory else { throw SFTPProtocolFailure.stale }
        return canonicalDirectory
    }
    mutating func beginRemoteAction(_ intent: SFTPRemoteActionIntent) throws {
        _ = try remoteActionDirectory(intent)
        remoteAction = (intent.request, .preparing)
    }
    mutating func permitRemoteAction(_ request: UUID) throws {
        guard valid, let current = remoteAction, current.request == request,
              current.phase == .prepared else { throw SFTPProtocolFailure.phase }
        remoteAction = (request, .permitted)
    }
    mutating func consume(_ bytes: Data) throws -> SFTPWorkerEvent? {
        guard valid, phase != .closed else { throw SFTPProtocolFailure.closed }
        valid = false
        guard (33...Self.maximumFrameBytes).contains(bytes.count) else { throw SFTPProtocolFailure.invalidOutput }
        var cursor = SFTPCursor(bytes)
        guard try cursor.take(8) == mode.magic, try cursor.token() == session,
              try cursor.number(8) == sequence, sequence < UInt64.max else { throw SFTPProtocolFailure.stale }
        let event: SFTPWorkerEvent?
        let eventKind = try cursor.number(1)
        // In startup3 no trust/auth/ready event can precede exact version ACK.
        guard !inPlaceEnabled || inPlaceStartupAccepted || eventKind == 200 else { throw SFTPProtocolFailure.phase }
        switch eventKind {
        #if TRAVERSE_SFTP_EDITOR_QA
        case 138:
            guard mode == .agentCatalog, phase == .authentication,
                  agentListRequested, !agentListReceived, agentSelectionDigest == nil else { throw SFTPProtocolFailure.phase }
            let count = try cursor.number(1)
            guard (1...16).contains(count) else { throw SFTPProtocolFailure.invalidOutput }
            var identities: [SFTPAgentIdentitySummary] = []
            for _ in 0..<count {
                let digest = try cursor.take(32)
                let algorithm = try cursor.text(cap: 48)
                let summary = try SFTPAgentIdentitySummary(digest: digest, algorithm: algorithm)
                guard !identities.contains(where: { $0.digest == digest }) else { throw SFTPProtocolFailure.invalidOutput }
                identities.append(summary)
            }
            agentIdentities = identities; agentListReceived = true; event = .agentIdentities(identities)
        case 139:
            guard mode == .agentCatalog, phase == .authentication, keyAuthentication,
                  !identityReceived, let selected = agentSelectionDigest else { throw SFTPProtocolFailure.phase }
            let actual = try cursor.take(32)
            guard actual == selected else { throw SFTPProtocolFailure.trust }
            identityReceived = true; event = .agentSelected(actual)
        #endif
        case 210:
            let request = try cursor.token()
            guard mode.allowsRemoteActions, let action = remoteAction, action.request == request,
                  action.phase == .preparing, cursor.finished else { throw SFTPProtocolFailure.phase }
            remoteAction = (request, .prepared); event = .remoteActionPrepared(request)
        case 211, 213:
            let request = try cursor.token()
            guard mode.allowsRemoteActions, let action = remoteAction, action.request == request,
                  action.phase == .permitted, cursor.finished else { throw SFTPProtocolFailure.phase }
            remoteAction = nil; generation = nil; storedSnapshot = nil; canonicalDirectory = nil; complete = false
            event = eventKind == 211 ? .remoteActionConfirmed(request) : .remoteActionNeedsReview(request)
        case 212:
            let request = try cursor.token(), code = try cursor.number(1)
            guard mode.allowsRemoteActions, let action = remoteAction, action.request == request,
                  action.phase == .preparing || action.phase == .permitted, cursor.finished else { throw SFTPProtocolFailure.phase }
            let refusal: SFTPRemoteActionRefusal
            switch code { case 1: refusal = .targetExists; case 2: refusal = .sourceChanged
            case 3: refusal = .denied; case 4: refusal = .unavailable; case 5: refusal = .busy
            case 6: refusal = .notEmpty
            default: throw SFTPProtocolFailure.invalidOutput }
            remoteAction = nil; event = .remoteActionRefused(request, refusal)
        case 200:
            let expected = mode.allowsRemoteActions ? Data([4, 7, 2, inPlaceTransfers.rawValue, 1])
                : Data([3, 7, 1, inPlaceTransfers.rawValue])
            guard inPlaceEnabled, !inPlaceStartupAccepted,
                  try cursor.take(expected.count) == expected, cursor.finished else { throw SFTPProtocolFailure.invalidOutput }
            inPlaceStartupAccepted = true; event = nil
        case 190...199, 201:
            guard inPlaceEnabled, phase == .ready else { throw SFTPProtocolFailure.phase }
            event = .inPlace(try inPlace.consume(eventKind, payload: cursor.take(bytes.count - 33)))
        case 180...189:
            guard mode.allowsOriginalEditing, phase == .ready else { throw SFTPProtocolFailure.phase }
            // The sole outer decoder has already consumed the33-byte envelope.
            let payload = try cursor.take(bytes.count - 33)
            event = .original(try original.consume(eventKind, payload: payload))
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
        case 160...168:
            guard permitsFolderUploads, phase == .ready, var state = folderUpload else { throw SFTPProtocolFailure.invalidOutput }
            event = try state.consume(eventKind, cursor: &cursor)
            if eventKind == 167 || eventKind == 168 { folderUpload = nil } else { folderUpload = state }
        #endif
        #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
        case 123:
            let request = try cursor.token()
            guard permitsFolderDownloads, phase == .ready, let download, download.started,
                  request == download.selection.request else { throw SFTPProtocolFailure.phase }
            event = .downloadCheckpoint(request)
        case 150...159:
            guard permitsFolderDownloads, phase == .ready, folder != nil else { throw SFTPProtocolFailure.phase }
            event = try folder!.consume(eventKind, cursor: &cursor)
            if folder!.ended { folder = nil }
        #endif
        case 142...146:
            guard mode.isJump, phase == .routing, jump != nil else { throw SFTPProtocolFailure.phase }
            // The kind is the last byte of the already validated header.
            let kind = UInt64(bytes[32])
            switch try jump!.consume(kind, cursor: &cursor) {
            case .challenge(let value): event = .jumpChallenge(value)
            case .verified(let value): event = .jumpVerified(SFTPVerifiedHost(value))
            case .identity(let value): event = .jumpIdentity(value)
            case .authenticated: phase = .challenge; event = .jumpAuthenticated
            case .prompts(let value): event = .jumpInteractiveChallenge(value)
            }
        case 100:
            guard phase == .challenge else { throw SFTPProtocolFailure.phase }
            let kind = try cursor.number(1), actualHost = try cursor.text(cap: 253), actualPort = try cursor.number(2)
            let current = try SFTPHostKey(cursor.field(cap: 16384)), oldBytes = try cursor.field(cap: 16384)
            let old = try oldBytes.isEmpty ? nil : SFTPHostKey(oldBytes)
            let challenge = SFTPHostChallenge(session: session, host: actualHost, port: UInt16(actualPort), current: current, previous: old)
            guard actualHost == host, actualPort == port, old == previous, kind == challenge.kind.rawValue else { throw SFTPProtocolFailure.trust }
            self.challenge = challenge; phase = .verification; event = .challenge(challenge)
        case 101:
            guard phase == .verification, let challenge, let approval, approval != .reject else { throw SFTPProtocolFailure.trust }
            phase = .authentication; event = .verified(SFTPVerifiedHost(challenge))
        case 102:
            guard phase == .authentication, keyAuthentication == identityReceived, pendingInteractive == nil else { throw SFTPProtocolFailure.phase }
            #if TRAVERSE_SFTP_EDITOR_QA
            if mode.isAgent {
                guard agentSelectionDigest != nil, identityReceived else { throw SFTPProtocolFailure.phase }
            }
            #endif
            phase = .readying; event = .authenticated
        case 135:
            guard mode.allowsKeyAuthentication, !mode.isAgent, phase == .authentication,
                  keyAuthentication, !identityReceived, pendingInteractive == nil else { throw SFTPProtocolFailure.phase }
            let identity = try SFTPHostKey(cursor.field(cap: 16384))
            guard expectedIdentity == nil || expectedIdentity == identity else { throw SFTPProtocolFailure.trust }
            identityReceived = true; event = .authenticatedIdentity(identity)
        case 136:
            guard mode.allowsInteractiveAuthentication, phase == .authentication, interactiveStarted,
                  pendingInteractive == nil, !identityReceived, interactiveRound < 8 else { throw SFTPProtocolFailure.phase }
            let round = try cursor.number(1), responseSeconds = try cursor.number(2)
            let name = try cursor.serverText(cap: 256), instructions = try cursor.serverText(cap: 4096), count = try cursor.number(1)
            guard round == UInt64(interactiveRound) + 1, count <= 8 else { throw SFTPProtocolFailure.phase }
            var prompts: [SFTPInteractivePrompt] = []
            for _ in 0..<count {
                let echo = try cursor.number(1), text = try cursor.serverText(cap: 1024)
                guard echo <= 1 else { throw SFTPProtocolFailure.invalidOutput }
                prompts.append(try .init(text: text, echo: echo == 1))
            }
            let challenge = try SFTPInteractiveChallenge(session: session, round: UInt8(round), host: host, port: port,
                name: name, instructions: instructions, prompts: prompts, responseSeconds: UInt16(responseSeconds))
            interactiveRound = UInt8(round); pendingInteractive = challenge; event = .interactiveChallenge(challenge)
        case 109:
            guard phase == .readying else { throw SFTPProtocolFailure.phase }
            phase = .ready; event = .ready
        case 214:
            let supported = try cursor.boolean()
            guard mode.allowsRemoteActions, phase == .readying, !serverCopyCapabilityReceived else {
                throw SFTPProtocolFailure.phase
            }
            serverCopyCapabilityReceived = true; supportsServerCopy = supported; event = nil
        case 169:
            guard mode.isCatalog, phase == .ready, recoveryRequested, !recoveryEnabled,
                  !everOpened, generation == nil, try cursor.number(1) == 1 else { throw SFTPProtocolFailure.phase }
            recoveryRequested = false; recoveryEnabled = true; event = .directoryRecoveryEnabled
        case 170:
            let id = try cursor.token(), raw = try cursor.number(1)
            guard mode.isCatalog, phase == .ready, recoveryEnabled, !recoveryRequested,
                  awaitingDirectory, generation == id, !reading,
                  let rejection = SFTPDirectoryRejection(rawValue: UInt8(raw)) else { throw SFTPProtocolFailure.stale }
            generation = nil; awaitingDirectory = false; complete = false; storedSnapshot = nil; canonicalDirectory = nil
            event = .directoryRejected(id, rejection)
        case 103:
            let id = try cursor.token(), path = try cursor.text(cap: 8192)
            guard mode == .batches, phase == .ready, awaitingDirectory, generation == id, path.hasPrefix("/") else { throw SFTPProtocolFailure.stale }
            awaitingDirectory = false; everOpened = true; event = .directory(id, path)
        case 104:
            let id = try cursor.token(), flags = try cursor.number(1), size = try cursor.number(8)
            let modified = try cursor.number(4), permissions = try cursor.number(4)
            let name = try SFTPRemoteName(cursor.field(cap: 8192))
            guard mode == .batches, phase == .ready, reading, generation == id, !complete, flags <= 7,
                  size <= UInt64(Int64.max), flags & 1 != 0 || size == 0,
                  flags & 2 != 0 || modified == 0, flags & 4 != 0 || permissions == 0,
                  pending.count < 1024, pendingNames.insert(name.wireUTF8).inserted else { throw SFTPProtocolFailure.invalidOutput }
            pendingBytes += name.wireUTF8.count + 128
            guard pendingBytes <= 512 << 10 else { throw SFTPProtocolFailure.invalidOutput }
            pending.append(SFTPWorkerEntry(name: name, logicalBytes: flags & 1 == 0 ? nil : size,
                modifiedSeconds: flags & 2 == 0 ? nil : UInt32(modified), permissions: flags & 4 == 0 ? nil : UInt32(permissions)))
            event = nil
        case 105:
            let id = try cursor.token(), count = try cursor.number(4), end = try cursor.boolean()
            guard mode == .batches, phase == .ready, reading, generation == id, count == pending.count,
                  !end || count == 0 else { throw SFTPProtocolFailure.invalidOutput }
            let entries = pending; clearPending(); reading = false; complete = end; event = .batch(id, entries, end: end)
        case 107:
            let outcome = try cursor.number(1), ack = try cursor.boolean(), sshEnded = try cursor.boolean()
            let before = try cursor.number(8), after = try cursor.number(8)
            let writerEnd: SFTPWorkerTerminal.WriterEnd?
            if mode.isCatalog {
                guard let end = SFTPWorkerTerminal.WriterEnd(rawValue: UInt8(try cursor.number(1))) else { throw SFTPProtocolFailure.invalidOutput }
                writerEnd = end
            } else { writerEnd = nil }
            let jumpEnded = try mode.isJump ? cursor.boolean() : nil
            let certificateOutcome = (outcome == 16 || outcome == 17) && certificateAuthentication
                && phase == .authentication && !identityReceived
            guard certificateOutcome || outcome <= (mode.isJump ? 15 : mode.allowsKeyAuthentication ? 14 : permitsDownloads ? 10 : mode.isCatalog ? 9 : 8),
                  after == 0, !ack || everOpened else { throw SFTPProtocolFailure.invalidOutput }
            clearPending(); clearPage(); activeFind = nil; download = nil; reading = false; phase = .closed
            original.invalidateAfterActualSessionEnd(); inPlace.invalidateAfterActualSessionEnd()
            #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
            upload = nil
            #endif
            event = .closed(SFTPWorkerTerminal(outcome: UInt8(outcome), directoryCloseAcknowledged: ack,
                sshTaskEndedBeforeRuntimeDrop: sshEnded, tasksBeforeRuntimeDrop: before, tasksAfterRuntimeDrop: after, catalogWriterEnd: writerEnd,
                jumpTaskEndedBeforeRuntimeDrop: jumpEnded))
        case 110:
            let id = try cursor.token(), path = try cursor.text(cap: 8192), snapshot = try cursor.snapshot()
            guard mode.isCatalog, phase == .ready, awaitingDirectory, generation == id, path.hasPrefix("/"),
                  snapshot.state == .loading, snapshot.revision == 0, snapshot.count == 0 else { throw SFTPProtocolFailure.stale }
            awaitingDirectory = false; everOpened = true; storedSnapshot = snapshot; canonicalDirectory = path; event = .storedDirectory(id, path, snapshot)
        case 111:
            let id = try cursor.token(), snapshot = try cursor.snapshot()
            guard mode.isCatalog, phase == .ready, reading, generation == id, let old = storedSnapshot,
                  snapshot.read == old.read, snapshot.revision >= old.revision, snapshot.count >= old.count,
                  snapshot.count - old.count <= 1024, snapshot.folders >= old.folders,
                  snapshot.state == .loading || snapshot.state == .complete,
                  snapshot.revision > old.revision || snapshot.count == old.count && snapshot.folders == old.folders else {
                throw SFTPProtocolFailure.stale
            }
            reading = false; complete = snapshot.state == .complete
            if storedSnapshot != snapshot { activeFind = nil }
            storedSnapshot = snapshot; event = .storedProgress(id, snapshot)
        case 220:
            let request = try cursor.token(), id = try cursor.token(), snapshot = try cursor.snapshot()
            let observation = try cursor.number(8), bytes = try cursor.number(8)
            let files = try cursor.number(4), folders = try cursor.number(4), links = try cursor.number(4)
            guard mode.isCatalog, phase == .ready, let query, let sizing = query.sizing,
                  !pageStarted, query.request == request, sizing.generation == id,
                  sizing.snapshot == snapshot, sizing.row.observation == observation else {
                throw SFTPProtocolFailure.invalidOutput
            }
            guard let summary = try? RemoteFolderSizeSummary(logicalBytes: bytes, files: UInt32(files),
                folders: UInt32(folders), excludedLinks: UInt32(links)) else { throw SFTPProtocolFailure.invalidOutput }
            clearPage(); event = .folderSize(request, summary)
        case 221:
            let request = try cursor.token(), reason = try cursor.number(1)
            guard mode.isCatalog, phase == .ready, let query, query.sizing != nil,
                  !pageStarted, query.request == request,
                  let failure = RemoteFolderSizeFailure(wireReason: UInt8(reason)) else {
                throw SFTPProtocolFailure.invalidOutput
            }
            clearPage(); event = .folderSizeUnavailable(request, failure)
        case 118:
            let request = try cursor.token(), id = try cursor.token(), snapshot = try cursor.snapshot()
            let count = try cursor.number(8), folders = try cursor.number(8)
            guard mode.isCatalog, phase == .ready, let query, let finding = query.finding,
                  !pageStarted, query.request == request, query.generation == id, query.snapshot == snapshot,
                  count <= snapshot.count, folders <= count, folders <= snapshot.folders else { throw SFTPProtocolFailure.invalidOutput }
            let result = try SFTPDirectoryFindResult(query: finding, generation: id, snapshot: snapshot, count: count, folders: folders)
            clearPage(); activeFind = result; event = .found(result)
        case 119, 124:
            let request = try cursor.token()
            guard mode.isCatalog, phase == .ready, let query, query.finding != nil,
                  !pageStarted, query.request == request else { throw SFTPProtocolFailure.invalidOutput }
            if eventKind == 124 { guard try cursor.number(1) == 1 else { throw SFTPProtocolFailure.invalidOutput } }
            clearPage(); event = eventKind == 119 ? .findStale(request) : .findUnavailable(request)
        case 114, 174:
            let request = try cursor.token()
            let findID = eventKind == 174 ? try cursor.token() : nil
            let id = try cursor.token(), snapshot = try cursor.snapshot(), offset = try cursor.number(8)
            guard mode.isCatalog, phase == .ready, let query, query.finding == nil, query.sizing == nil, !pageStarted, query.request == request,
                  query.find?.query.id == findID,
                  query.generation == id, query.snapshot == snapshot, query.offset == offset else { throw SFTPProtocolFailure.stale }
            if eventKind == 174 {
                guard let find = query.find, try cursor.number(8) == find.count,
                      try cursor.number(8) == find.folders else { throw SFTPProtocolFailure.invalidOutput }
            }
            pageStarted = true; event = nil
        case 115, 175:
            let request = try cursor.token(), findID = eventKind == 175 ? try cursor.token() : nil
            let observation = try cursor.number(8), entry = try cursor.entry()
            guard mode.isCatalog, phase == .ready, let query, pageStarted, query.request == request,
                  query.finding == nil, query.sizing == nil, query.find?.query.id == findID,
                  observation > 0, observation <= UInt64(Int64.max), storedRows.count < query.limit,
                  storedNames.insert(entry.name.wireUTF8).inserted, storedObservations.insert(observation).inserted else { throw SFTPProtocolFailure.invalidOutput }
            storedBytes += entry.name.wireUTF8.count + 160
            guard storedBytes <= 3 << 20 else { throw SFTPProtocolFailure.invalidOutput }
            storedRows.append(SFTPStoredRow(observation: observation, entry: entry)); event = nil
        case 116, 176:
            let request = try cursor.token(), findID = eventKind == 176 ? try cursor.token() : nil
            let count = try cursor.number(4)
            guard mode.isCatalog, phase == .ready, let query, pageStarted, request == query.request,
                  query.finding == nil, query.sizing == nil, query.find?.query.id == findID,
                  count == storedRows.count, count == min(UInt64(query.limit), query.count > query.offset ? query.count - query.offset : 0) else {
                throw SFTPProtocolFailure.invalidOutput
            }
            let page = SFTPStoredPage(request: request, generation: query.generation, snapshot: query.snapshot,
                                      offset: query.offset, rows: storedRows, find: query.find)
            clearPage(); event = .storedPage(page)
        case 117, 177, 178:
            let request = try cursor.token(), findID = eventKind == 117 ? nil : try cursor.token()
            guard mode.isCatalog, phase == .ready, let query, query.finding == nil, query.sizing == nil,
                  !pageStarted, query.request == request, query.find?.query.id == findID else { throw SFTPProtocolFailure.stale }
            if eventKind == 178 { guard try cursor.number(1) == 1 else { throw SFTPProtocolFailure.invalidOutput } }
            clearPage(); event = eventKind == 178 ? .filteredPageUnavailable(request) : .stalePage(request)
        case 120:
            let request = try cursor.token(), generation = try cursor.token(), observation = try cursor.number(8)
            let size = try cursor.number(8), modified = try cursor.number(4), permissions = try cursor.number(4)
            let name = try SFTPRemoteName(cursor.field(cap: 8192))
            guard permitsDownloads, phase == .ready, var download, !download.started else { throw SFTPProtocolFailure.phase }
            let selection = download.selection, row = selection.row
            guard selection.request == request, selection.generation == generation, row.observation == observation,
                  row.entry.name == name, row.entry.logicalBytes == size, row.entry.modifiedSeconds == UInt32(modified),
                  row.entry.permissions == UInt32(permissions) else { throw SFTPProtocolFailure.stale }
            download.started = true; self.download = download; event = .downloadStarted(selection)
        case 121:
            let request = try cursor.token(), offset = try cursor.number(8), bytes = try cursor.field(cap: 32768)
            guard permitsDownloads, phase == .ready, var download, download.started,
                  request == download.selection.request, !bytes.isEmpty, offset == download.received,
                  download.received <= download.selection.logicalBytes,
                  UInt64(bytes.count) <= download.selection.logicalBytes - download.received else { throw SFTPProtocolFailure.invalidOutput }
            download.received += UInt64(bytes.count); self.download = download; event = .downloadBytes(request, offset, bytes)
        case 122:
            let request = try cursor.token(), size = try cursor.number(8), acknowledged = try cursor.boolean(), shutdown = try cursor.boolean()
            guard permitsDownloads, phase == .ready, let download, download.started, request == download.selection.request,
                  size == download.selection.logicalBytes, size == download.received, acknowledged, shutdown else { throw SFTPProtocolFailure.invalidOutput }
            self.download = nil; event = .downloadComplete(SFTPDownloadReceipt(selection: download.selection, receivedBytes: size))
        #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
        case 130:
            let request = try cursor.token(), generation = try cursor.token(), size = try cursor.number(8)
            let temporary = try cursor.field(cap: 8192), final = try cursor.field(cap: 8192)
            guard permitsUploads, phase == .ready, var upload, !upload.started,
                  request == upload.selection.request, generation == upload.selection.generation, size == upload.selection.logicalBytes,
                  temporary.isEmpty, final == upload.selection.finalPath else { throw SFTPProtocolFailure.stale }
            upload.started = true; self.upload = upload; event = .uploadStarted(upload.selection)
        case 131:
            let request = try cursor.token(), offset = try cursor.number(8), count = try cursor.number(4)
            guard permitsUploads, phase == .ready, var upload, upload.started, upload.selection.request == request,
                  upload.sourceRequest == nil, upload.requestedDigest == nil, offset == upload.sent, offset < upload.selection.logicalBytes,
                  count == min(32768, upload.selection.logicalBytes - offset) else { throw SFTPProtocolFailure.invalidOutput }
            upload.sourceRequest = (offset, Int(count)); self.upload = upload; event = .uploadSourceRequest(request, offset, Int(count))
        case 132:
            let request = try cursor.token(), size = try cursor.number(8), digest = try cursor.take(32)
            guard permitsUploads, phase == .ready, var upload, upload.started, upload.selection.request == request,
                  upload.sourceRequest == nil, upload.sent == size, size == upload.selection.logicalBytes, upload.requestedDigest == nil else { throw SFTPProtocolFailure.invalidOutput }
            upload.requestedDigest = digest; self.upload = upload; event = .uploadPublicationRequest(request, digest)
        case 133:
            let request = try cursor.token(), size = try cursor.number(8), digest = try cursor.take(32)
            let synced = try cursor.boolean(), exclusivelyCreated = try cursor.boolean(), closed = try cursor.boolean(), shutdown = try cursor.boolean()
            guard permitsUploads, phase == .ready, let upload, upload.selection.request == request,
                  upload.sourceRequest == nil, size == upload.selection.logicalBytes, upload.sent == size,
                  upload.permittedDigest == digest, synced, exclusivelyCreated, closed, shutdown else { throw SFTPProtocolFailure.invalidOutput }
            self.upload = nil; event = .uploadComplete(.init(selection: upload.selection, digest: digest))
        case 134:
            let request = try cursor.token()
            guard let cause = SFTPUploadInterruption.Cause(rawValue: UInt8(try cursor.number(1))),
                  let stage = SFTPUploadInterruption.Phase(rawValue: UInt8(try cursor.number(1))) else { throw SFTPProtocolFailure.invalidOutput }
            let temporary = try cursor.boolean(), published = try cursor.boolean(), status = try cursor.number(4)
            let beforeCreate = stage == .admission || stage == .negotiation || stage == .destination
            let afterCreate = [SFTPUploadInterruption.Phase.openingFinal, .writing, .readback, .permissions, .syncing, .closing, .authorization, .finalReadback, .shutdown].contains(stage)
            guard permitsUploads, phase == .ready, let upload, upload.started, upload.selection.request == request,
                  beforeCreate || afterCreate, !temporary, published == afterCreate,
                  (cause == .status ? status >= 2 : status == 0),
                  (stage == .finalReadback || stage == .shutdown) ? upload.permittedDigest != nil : true,
                  cause != .unsupportedSync || stage == .negotiation, cause != .input || stage == .admission else { throw SFTPProtocolFailure.invalidOutput }
            self.upload = nil; event = .uploadInterrupted(.init(selection: upload.selection, cause: cause, phase: stage, status: UInt32(status), temporaryMayExist: temporary, publicationMayHaveHappened: published))
        case 137:
            let request = try cursor.token()
            guard permitsUploads, phase == .ready, let upload, upload.started,
                  upload.selection.request == request, upload.sent == 0,
                  upload.sourceRequest == nil, upload.requestedDigest == nil,
                  upload.permittedDigest == nil else { throw SFTPProtocolFailure.invalidOutput }
            self.upload = nil; event = .uploadOpenRefused(.init(selection: upload.selection))
        #endif
        default: throw SFTPProtocolFailure.invalidOutput
        }
        guard cursor.finished else { throw SFTPProtocolFailure.invalidOutput }
        sequence += 1; valid = true; return event
    }
    private mutating func clearPending() {
        pending.removeAll(keepingCapacity: true); pendingNames.removeAll(keepingCapacity: true); pendingBytes = 0
    }
    private mutating func clearPage() {
        query = nil; pageStarted = false; storedRows.removeAll(keepingCapacity: true)
        storedNames.removeAll(keepingCapacity: true); storedObservations.removeAll(keepingCapacity: true); storedBytes = 0
    }
}

enum SFTPWire {
    static func validToken(_ id: UUID) -> Bool { token(id).contains { $0 != 0 } }
    static func token(_ id: UUID) -> Data { var value = id.uuid; return withUnsafeBytes(of: &value) { Data($0) } }
    static func number(_ value: UInt64, bytes: Int, into data: inout Data) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    static func field(_ bytes: Data, into data: inout Data) throws {
        guard bytes.count <= 65536, data.count <= 65536 - 4 - bytes.count else { throw SFTPProtocolFailure.invalidInput }
        number(UInt64(bytes.count), bytes: 4, into: &data); data.append(bytes)
    }
    static func body(session: UUID, sequence: UInt64, kind: UInt8, mode: SFTPWireMode = .batches) throws -> Data {
        guard validToken(session) else { throw SFTPProtocolFailure.invalidInput }
        var data = mode.magic; data.append(token(session)); number(sequence, bytes: 8, into: &data); data.append(kind); return data
    }
    static func frame(_ body: Data) throws -> Data {
        guard (33...65536).contains(body.count) else { throw SFTPProtocolFailure.invalidInput }
        var data = Data(); number(UInt64(body.count), bytes: 4, into: &data); data.append(body); return data
    }
}

struct SFTPCursor {
    private let bytes: [UInt8]
    private var offset = 0
    init(_ data: Data) { bytes = Array(data) }
    var finished: Bool { offset == bytes.count }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count - offset else { throw SFTPProtocolFailure.invalidOutput }
        defer { offset += count }; return Data(bytes[offset..<offset + count])
    }
    mutating func number(_ count: Int) throws -> UInt64 {
        guard (1...8).contains(count) else { throw SFTPProtocolFailure.invalidOutput }
        return try take(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
    mutating func boolean() throws -> Bool {
        let value = try number(1); guard value < 2 else { throw SFTPProtocolFailure.invalidOutput }; return value == 1
    }
    mutating func token() throws -> UUID {
        let value = Array(try take(16)); guard value.contains(where: { $0 != 0 }) else { throw SFTPProtocolFailure.invalidOutput }
        return UUID(uuid: (value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
                           value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15]))
    }
    mutating func field(cap: Int) throws -> Data {
        let size = try number(4); guard size <= cap else { throw SFTPProtocolFailure.invalidOutput }; return try take(Int(size))
    }
    mutating func text(cap: Int) throws -> String {
        guard let value = String(data: try field(cap: cap), encoding: .utf8), !value.isEmpty, !value.contains("\0") else {
            throw SFTPProtocolFailure.invalidOutput
        }; return value
    }
    mutating func serverText(cap: Int) throws -> String {
        guard let value = String(data: try field(cap: cap), encoding: .utf8) else { throw SFTPProtocolFailure.invalidOutput }
        return value
    }
    mutating func snapshot() throws -> SFTPStoredSnapshot {
        let read = try number(8), revision = try number(8), count = try number(8), folders = try number(8)
        guard let state = SFTPStoredSnapshot.State(rawValue: UInt8(try number(1))), read > 0,
              [read, revision, count, folders].allSatisfy({ $0 <= UInt64(Int64.max) }), folders <= count else { throw SFTPProtocolFailure.invalidOutput }
        return SFTPStoredSnapshot(read: read, revision: revision, count: count, folders: folders, state: state)
    }
    mutating func entry() throws -> SFTPWorkerEntry {
        let flags = try number(1), size = try number(8), modified = try number(4), mode = try number(4)
        let name = try SFTPRemoteName(field(cap: 8192))
        guard flags <= 7, flags & 1 != 0 || size == 0, flags & 2 != 0 || modified == 0, flags & 4 != 0 || mode == 0 else {
            throw SFTPProtocolFailure.invalidOutput
        }
        return SFTPWorkerEntry(name: name, logicalBytes: flags & 1 == 0 ? nil : size,
            modifiedSeconds: flags & 2 == 0 ? nil : UInt32(modified), permissions: flags & 4 == 0 ? nil : UInt32(mode))
    }
}
