import ExplorerCore
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPPreparedConnectionTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func candidatePool() async throws -> SMBTemporaryCatalogPool {
        let directory = repositoryRoot.appendingPathComponent(".build/traverse-development/prepared-editor-permit", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let layout = try ApplicationStorageLayout(applicationSupport: directory.appendingPathComponent("Support", isDirectory: true),
            caches: directory.appendingPathComponent("Cache", isDirectory: true), bundleIdentifier: "generated.prepared-editor")
        let workspace = try ConnectionWorkspace(layout: layout)
        return SMBTemporaryCatalogPool(storage: try await workspace.prepareForConnect().metadataStorage)
    }

    func testPreparedEditorCandidateKeepsOrdinaryTransferModesAndBindsDirectPeer() async throws {
        let request = try SFTPConnectionRequest(address: SFTPConnectionAddress("127.0.0.1:2222"), account: "generated")
        let pool = try await candidatePool()
        let endpoint = try await SFTPPreparedConnection.prepare(request, bundleURL: Bundle.main.bundleURL, activity: FileActivityGate())
        let readOnly = try SFTPWorkerSession.configuredPreparedPeer(request, endpoint: endpoint, bundleURL: Bundle.main.bundleURL,
            pool: pool, requestedDownloads: true, requestedFolderDownloads: true, keyAuthentication: true)
        XCTAssertEqual(readOnly.contentAccess, .readOnly)
        XCTAssertNil(readOnly.inPlaceEditingPermit)
        let upload = try SFTPWorkerSession.configuredPreparedPeer(request, endpoint: endpoint, bundleURL: Bundle.main.bundleURL,
            pool: pool, requestedDownloads: true, requestedFolderDownloads: true, freshUploads: true, keyAuthentication: true,
            freshFolderUploads: true)
        XCTAssertEqual(upload.contentAccess, .transferWrites)
        XCTAssertNil(upload.inPlaceEditingPermit)

        let editor = try SFTPWorkerSession.configuredPreparedPeer(request, endpoint: endpoint, bundleURL: Bundle.main.bundleURL,
            pool: pool, requestedDownloads: true, requestedFolderDownloads: true, freshUploads: true, keyAuthentication: true,
            freshFolderUploads: true, guardedInPlaceEditing: true)
        XCTAssertEqual(editor.contentAccess, .guardedInPlaceV1)
        XCTAssertEqual(try SFTPInPlaceTransfers(peer: editor), .all)
        XCTAssertNotNil(editor.inPlaceEditingPermit)
        XCTAssertNoThrow(try editor.inPlaceEditingPermit?.validate(peer: editor, pool: pool))
        var altered = editor; altered.allowsFreshFolderUploads = false
        XCTAssertThrowsError(try editor.inPlaceEditingPermit?.validate(peer: altered, pool: pool))
        altered = editor; altered.requestedScopeID = 1
        XCTAssertThrowsError(try editor.inPlaceEditingPermit?.validate(peer: altered, pool: pool))
    }

    func testPreparedEditorCandidateRejectsMissingTransferOrStorageAuthority() async throws {
        let request = try SFTPConnectionRequest(address: SFTPConnectionAddress("127.0.0.1"), account: "generated")
        let pool = try await candidatePool()
        let endpoint = try await SFTPPreparedConnection.prepare(request, bundleURL: Bundle.main.bundleURL, activity: FileActivityGate())
        for (downloads, folders, uploads, profile) in [(false, true, true, true), (true, false, true, true),
            (true, true, false, true), (true, true, true, false)] {
            XCTAssertThrowsError(try SFTPWorkerSession.configuredPreparedPeer(request, endpoint: endpoint,
                bundleURL: Bundle.main.bundleURL, pool: pool, requestedDownloads: downloads,
                requestedFolderDownloads: folders, freshUploads: uploads, keyAuthentication: profile,
                guardedInPlaceEditing: true))
        }
        // Keep the bare URL outside the Debug-only generated-permit namespace.
        // A nested genuine workspace is deeper than the old fixture root.
        let unadmittedRoot = repositoryRoot.appendingPathComponent(".build/traverse-security-review", isDirectory: true)
        let unadmitted = SMBTemporaryCatalogPool(storage: try SMBTemporaryStorage(directory:
            unadmittedRoot.appendingPathComponent("unadmitted-editor-" + UUID().uuidString, isDirectory: true)))
        XCTAssertThrowsError(try SFTPWorkerSession.configuredPreparedPeer(request, endpoint: endpoint,
            bundleURL: Bundle.main.bundleURL, pool: unadmitted, requestedDownloads: true,
            requestedFolderDownloads: true, freshUploads: true, keyAuthentication: true,
            guardedInPlaceEditing: true))
    }

    func testRemoteActionPeerRetainsExplicitEditorPermit() async throws {
        let request = try SFTPConnectionRequest(address: SFTPConnectionAddress("127.0.0.1:2222"), account: "generated")
        let pool = try await candidatePool()
        let endpoint = try await SFTPPreparedConnection.prepare(request, bundleURL: Bundle.main.bundleURL, activity: FileActivityGate())
        let actions = try SFTPWorkerSession.configuredPreparedPeer(request, endpoint: endpoint,
            bundleURL: Bundle.main.bundleURL, pool: pool, requestedDownloads: true,
            requestedFolderDownloads: true, freshUploads: true, keyAuthentication: true,
            freshFolderUploads: true, remoteActions: true, guardedInPlaceEditing: true)
        XCTAssertTrue(actions.allowsRemoteActions)
        XCTAssertEqual(actions.contentAccess, .guardedInPlaceV1)
        XCTAssertEqual(try SFTPInPlaceTransfers(peer: actions), .all)
        XCTAssertNotNil(actions.inPlaceEditingPermit)
        XCTAssertNoThrow(try actions.inPlaceEditingPermit?.validate(peer: actions, pool: pool))

        let withoutEditor = try SFTPWorkerSession.configuredPreparedPeer(request, endpoint: endpoint,
            bundleURL: Bundle.main.bundleURL, pool: pool, requestedDownloads: true,
            requestedFolderDownloads: true, freshUploads: true, keyAuthentication: true,
            freshFolderUploads: true, remoteActions: true)
        XCTAssertTrue(withoutEditor.allowsRemoteActions)
        XCTAssertNil(withoutEditor.inPlaceEditingPermit)
        XCTAssertEqual(withoutEditor.contentAccess, .transferWrites)
    }

    func testPreparedRouteEditorCandidateRequiresExistingWriteChoice() async throws {
        let jump = try SFTPServerDraft(name: "Jump", address: SFTPConnectionAddress("127.0.0.1"), account: "jump")
        let destination = try SFTPServerDraft(name: "Destination", address: SFTPConnectionAddress("127.0.0.2"), account: "target")
        let route = try SFTPRouteDescription(destination: destination, jump: jump)
        let pool = try await candidatePool()
        let endpoint = try await SFTPPreparedConnection.prepare(jump.request, bundleURL: Bundle.main.bundleURL, activity: FileActivityGate())
        let readOnly = try SFTPJumpHostStage.configuredPreparedRoutePeer(destination: destination.request,
            jump: jump.request, route: route, previous: nil, endpoint: endpoint, bundleURL: Bundle.main.bundleURL,
            pool: pool, downloads: true, uploads: false, folderUploads: false, guardedInPlaceEditing: false)
        XCTAssertEqual(readOnly.contentAccess, .readOnly)
        XCTAssertNil(readOnly.inPlaceEditingPermit)
        let upload = try SFTPJumpHostStage.configuredPreparedRoutePeer(destination: destination.request,
            jump: jump.request, route: route, previous: nil, endpoint: endpoint, bundleURL: Bundle.main.bundleURL,
            pool: pool, downloads: true, uploads: true, folderUploads: true, guardedInPlaceEditing: false)
        XCTAssertEqual(upload.contentAccess, .transferWrites)
        XCTAssertNil(upload.inPlaceEditingPermit)
        XCTAssertThrowsError(try SFTPJumpHostStage.configuredPreparedRoutePeer(destination: destination.request,
            jump: jump.request, route: route, previous: nil, endpoint: endpoint, bundleURL: Bundle.main.bundleURL,
            pool: pool, downloads: true, uploads: false, folderUploads: false, guardedInPlaceEditing: true))
        let editor = try SFTPJumpHostStage.configuredPreparedRoutePeer(destination: destination.request,
            jump: jump.request, route: route, previous: nil, endpoint: endpoint, bundleURL: Bundle.main.bundleURL,
            pool: pool, downloads: true, uploads: true, folderUploads: true, guardedInPlaceEditing: true)
        XCTAssertEqual(editor.contentAccess, .guardedInPlaceV1)
        XCTAssertEqual(try SFTPInPlaceTransfers(peer: editor), .all)
        XCTAssertNotNil(editor.inPlaceEditingPermit)
        XCTAssertNoThrow(try editor.inPlaceEditingPermit?.validate(peer: editor, pool: pool))
        var altered = editor; altered.jump = .init(nonce: UUID(), host: jump.address.host, port: jump.address.port)
        XCTAssertThrowsError(try editor.inPlaceEditingPermit?.validate(peer: altered, pool: pool))
    }

    func testPreparedRouteActionPeerBindsGuardedEditorToBothRouteRoles() async throws {
        let jump = try SFTPServerDraft(name: "Jump", address: SFTPConnectionAddress("127.0.0.1:2224"), account: "jump")
        let destination = try SFTPServerDraft(name: "Destination", address: SFTPConnectionAddress("127.0.0.2:2222"), account: "target")
        let route = try SFTPRouteDescription(destination: destination, jump: jump)
        let pool = try await candidatePool()
        let endpoint = try await SFTPPreparedConnection.prepare(jump.request, bundleURL: Bundle.main.bundleURL, activity: FileActivityGate())
        let peer = try SFTPJumpHostStage.configuredPreparedRoutePeer(destination: destination.request,
            jump: jump.request, route: route, previous: nil, endpoint: endpoint, bundleURL: Bundle.main.bundleURL,
            pool: pool, downloads: true, uploads: true, folderUploads: true, remoteActions: true,
            guardedInPlaceEditing: true)
        XCTAssertTrue(peer.allowsRemoteActions)
        XCTAssertEqual(peer.contentAccess, .guardedInPlaceV1)
        XCTAssertEqual(try SFTPInPlaceTransfers(peer: peer), .all)
        XCTAssertNotNil(peer.rememberedRoute)
        XCTAssertNoThrow(try peer.inPlaceEditingPermit?.validate(peer: peer, pool: pool))
        var changed = peer; changed.jump = .init(nonce: UUID(), host: jump.address.host, port: jump.address.port)
        XCTAssertThrowsError(try peer.inPlaceEditingPermit?.validate(peer: changed, pool: pool))
        changed = peer; changed.requestedScopeID = 1
        XCTAssertThrowsError(try peer.inPlaceEditingPermit?.validate(peer: changed, pool: pool))
        XCTAssertThrowsError(try SFTPJumpHostStage.configuredPreparedRoutePeer(destination: destination.request,
            jump: jump.request, route: nil, previous: nil, endpoint: endpoint, bundleURL: Bundle.main.bundleURL,
            pool: pool, downloads: true, uploads: true, folderUploads: true, remoteActions: true,
            guardedInPlaceEditing: true))
        XCTAssertThrowsError(try SFTPJumpHostStage.configuredPreparedRoutePeer(destination: destination.request,
            jump: jump.request, route: route, previous: nil, endpoint: endpoint, bundleURL: Bundle.main.bundleURL,
            pool: pool, downloads: true, uploads: false, folderUploads: false, remoteActions: true,
            guardedInPlaceEditing: true))
    }

    func testNumericPreparationIsCredentialFreeAndBoundToHostPortScope() async throws {
        let gate = FileActivityGate(), address = try SFTPConnectionAddress("sftp://127.0.0.1:2222/home")
        let request = try SFTPConnectionRequest(address: address, account: "generated")
        XCTAssertEqual(String(reflecting: request), "<SFTP connection request>")
        let prepared = try await SFTPPreparedConnection.prepare(request, bundleURL: Bundle.main.bundleURL, activity: gate)
        XCTAssertEqual(prepared.numericHost, "127.0.0.1"); XCTAssertEqual(prepared.interfaceScopeID, 0); XCTAssertEqual(gate.activeCount, 0)
        XCTAssertNoThrow(try prepared.validate(for: request))
        for typed in ["127.0.0.2:2222", "127.0.0.1:2223", "[::1]:2222"] {
            XCTAssertThrowsError(try prepared.validate(for: SFTPConnectionRequest(address: SFTPConnectionAddress(typed), account: "generated")))
        }
        // DNS is not file-access authority: path/account may change before the
        // actual request is frozen, but cannot redirect its network endpoint.
        let same = try SFTPConnectionRequest(address: SFTPConnectionAddress("127.0.0.1:2222/other"), account: "other-generated")
        XCTAssertNoThrow(try prepared.validate(for: same))
        XCTAssertThrowsError(try prepared.validate(for: request, now: prepared.expires))
        XCTAssertEqual(String(reflecting: prepared), "<SFTP prepared connection>")
    }
    func testIPv6InterfaceScopeCannotBeSubstituted() async throws {
        let request = try SFTPConnectionRequest(address: SFTPConnectionAddress("[fe80::1%253]"), account: "generated")
        let prepared = try await SFTPPreparedConnection.prepare(request, bundleURL: Bundle.main.bundleURL, activity: FileActivityGate())
        XCTAssertEqual(prepared.numericHost, "fe80::1"); XCTAssertEqual(prepared.interfaceScopeID, 3)
        XCTAssertThrowsError(try prepared.validate(for: SFTPConnectionRequest(address: SFTPConnectionAddress("[fe80::1%254]"), account: "generated")))
    }
    func testCancelledPreparationStartsNoResolverOrSession() async throws {
        let request = try SFTPConnectionRequest(address: SFTPConnectionAddress("generated.example.invalid"), account: "generated"), gate = FileActivityGate()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SFTPPreparedConnection.prepare(request, bundleURL: Bundle.main.bundleURL, activity: gate)
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? SFTPSessionFailure, .stopped) }
        XCTAssertEqual(gate.activeCount, 0)
    }
    func testResolverFailureClassificationPreservesDeadlineCancellationAndBadOutput() {
        XCTAssertEqual(SFTPPreparedConnection.resolverFailure(.deadline), .deadline)
        XCTAssertEqual(SFTPPreparedConnection.resolverFailure(.stopped), .stopped)
        XCTAssertEqual(SFTPPreparedConnection.resolverFailure(.busy), .busy)
        XCTAssertEqual(SFTPPreparedConnection.resolverFailure(.invalidInput), .input)
        XCTAssertEqual(SFTPPreparedConnection.resolverFailure(.invalidOutput), .output)
        XCTAssertEqual(SFTPPreparedConnection.resolverFailure(.workerExited), .exited)
        XCTAssertEqual(SFTPPreparedConnection.resolverFailure(.containment), .unavailable)
        XCTAssertEqual(SFTPPreparedConnection.resolverFailure(.unavailable), .unavailable)
    }
    func testAccountAndPasswordAreBoundedSeparateAndRedacted() throws {
        let address = try SFTPConnectionAddress("server")
        for account in ["", "line\nfeed", "zero\0byte", String(repeating: "x", count: 257)] {
            XCTAssertThrowsError(try SFTPConnectionRequest(address: address, account: account))
        }
        XCTAssertNoThrow(try SFTPConnectionRequest(address: address, account: "generated@realm"))
        let password = try SFTPPassword("generated\nvalue")
        XCTAssertEqual(String(describing: password), "<SFTP password>"); XCTAssertEqual(String(reflecting: password), "<SFTP password>")
        for value in ["", "a\0b", String(repeating: "x", count: 4097)] { XCTAssertThrowsError(try SFTPPassword(value)) }
    }
}
