import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPDefaultDirectoryPersistenceTests: XCTestCase {
    private final class NoKeychainBackend: SFTPPasswordBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        var callCount: Int { lock.withLock { attempts } }
        func read(service: String, reference: SFTPCredentialReference) throws -> Data {
            lock.withLock { attempts += 1 }
            throw SFTPPasswordFailure.unavailable
        }
        func save(service: String, reference: SFTPCredentialReference, bytes: Data) throws {
            lock.withLock { attempts += 1 }
            throw SFTPPasswordFailure.unavailable
        }
        func remove(service: String, reference: SFTPCredentialReference) throws {
            lock.withLock { attempts += 1 }
            throw SFTPPasswordFailure.unavailable
        }
    }

    private func key(_ byte: UInt8) throws -> SFTPHostKey {
        var wire = Data()
        try SFTPWire.field(Data("ssh-ed25519".utf8), into: &wire)
        try SFTPWire.field(Data(repeating: byte, count: 32), into: &wire)
        return try SFTPHostKey(wire)
    }

    private func legacyVersion(_ snapshot: SFTPSettingsSnapshot, format: Int) throws -> Data {
        let encoded = try snapshot.encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("\"format\":7"))
        return Data(text.replacingOccurrences(of: "\"format\":7", with: "\"format\":\(format)").utf8)
    }

    func testCrossRootPresentationKeepsExactServerAndRouteAuthenticationMetadata() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let store = SFTPSettingsStore(directory: root.appendingPathComponent("state"))
        let backend = NoKeychainBackend()
        let state = SFTPRememberedState(settings: store,
            passwords: .init(service: "Traverse.Generated.DefaultDirectory.NoKeychain", backend: backend))
        let server = try SFTPServerDraft(name: "Original", address: .init("sftp://server.generated.invalid/Original"), account: "alice")
        let jump = try SFTPServerDraft(name: "Jump", address: .init("sftp://jump.generated.invalid/Jump"), account: "jumper")
        let destination = try SFTPServerDraft(name: "Destination", address: .init("sftp://destination.generated.invalid"), account: "bob")
        let route = try SFTPRouteDescription(destination: destination, jump: jump)
        let hostKey = try key(23)
        var snapshot = try await store.openForExplicitWrite().snapshot
        snapshot = try await store.apply(.saveHost(.init(identity: .init(address: server.address), key: hostKey), replacing: nil), revision: snapshot.revision).snapshot
        let pending = try await store.apply(.beginPassword(.init(request: server.request, key: hostKey)), revision: snapshot.revision)
        snapshot = pending.snapshot
        let credentialID = try XCTUnwrap(pending.credential?.id)
        snapshot = try await store.apply(.confirmPassword(credentialID), revision: snapshot.revision).snapshot
        let savedServer = try await store.apply(.saveServer(server, id: nil, credentialID: credentialID), revision: snapshot.revision)
        snapshot = savedServer.snapshot
        let serverID = try XCTUnwrap(savedServer.serverID)
        let savedRoute = try await store.apply(.saveRoute(route, jump: .init(key: try key(24), signIn: .password),
            destination: .init(key: try key(25), signIn: .password), id: nil), revision: snapshot.revision)
        snapshot = savedRoute.snapshot
        let routeID = try XCTUnwrap(savedRoute.routeID)
        await store.close()
        let before = snapshot

        let serverHome = try SFTPDefaultDirectory(field: "~/Home% #?", root: .home)
        do {
            _ = try await state.updatePresentation(id: serverID, expectedRevision: snapshot.revision,
                label: server.name, directory: serverHome)
            XCTFail("A root change needs the exact saved connection binding")
        } catch SFTPSettingsFailure.invalidRecord { }
        do {
            _ = try await state.updatePresentation(id: serverID, expectedRevision: snapshot.revision,
                label: server.name, directory: serverHome, expectedBinding: .init(server: destination))
            XCTFail("A different connection binding must be refused")
        } catch SFTPSettingsFailure.staleRevision { }
        let direct = try await state.updatePresentation(id: serverID, expectedRevision: snapshot.revision,
            label: "Renamed", directory: serverHome, expectedBinding: .init(server: server))
        snapshot = direct.snapshot
        XCTAssertEqual(snapshot.format, 7)
        XCTAssertEqual(try snapshot.visibleServers.first(where: { $0.id == serverID })?.effectiveDefaultDirectory, serverHome)
        XCTAssertEqual(snapshot.hosts, before.hosts)
        XCTAssertEqual(snapshot.credentials, before.credentials)
        XCTAssertEqual(snapshot.visibleServers.first(where: { $0.id == serverID })?.credentialID, credentialID)
        XCTAssertEqual(snapshot.visibleServers.first(where: { $0.id == serverID })?.details.address, server.address)
        XCTAssertEqual(snapshot.visibleServers.first(where: { $0.id == serverID })?.details.account, server.account)
        XCTAssertEqual(snapshot.visibleRoutes, before.visibleRoutes)
        for oldFormat in [5, 6] {
            XCTAssertThrowsError(try SFTPSettingsSnapshot.decode(legacyVersion(snapshot, format: oldFormat))) { error in
                XCTAssertEqual(error as? SFTPSettingsFailure, .invalidRecord)
            }
        }

        let routeServer = try SFTPDefaultDirectory(field: "/Alternate", root: .server)
        do {
            _ = try await state.updatePresentation(id: routeID, route: true, expectedRevision: snapshot.revision,
                label: route.destination.name, directory: routeServer)
            XCTFail("A route root change needs the exact saved route binding")
        } catch SFTPSettingsFailure.invalidRecord { }
        let routed = try await state.updatePresentation(id: routeID, route: true, expectedRevision: snapshot.revision,
            label: "Renamed destination", directory: routeServer, expectedBinding: .init(route: route))
        snapshot = routed.snapshot
        let saved = try XCTUnwrap(snapshot.visibleRoutes.first(where: { $0.id == routeID }))
        XCTAssertEqual(try saved.effectiveDefaultDirectory, routeServer)
        XCTAssertEqual(saved.details.destination.address, destination.address)
        XCTAssertEqual(saved.details.destination.account, destination.account)
        XCTAssertEqual(saved.details.jump, route.jump)
        XCTAssertEqual(saved.jump, before.visibleRoutes.first?.jump)
        XCTAssertEqual(saved.destination, before.visibleRoutes.first?.destination)
        XCTAssertEqual(snapshot.hosts, before.hosts)
        XCTAssertEqual(snapshot.credentials, before.credentials)
        XCTAssertEqual(snapshot.visibleServers.first(where: { $0.id == serverID })?.credentialID, credentialID)
        XCTAssertEqual(try SFTPSettingsSnapshot.decode(snapshot.encoded()), snapshot)
        var routeOnlyCrossRoot = snapshot
        routeOnlyCrossRoot.servers[0].defaultDirectory = nil
        XCTAssertThrowsError(try SFTPSettingsSnapshot.decode(legacyVersion(routeOnlyCrossRoot, format: 6))) { error in
            XCTAssertEqual(error as? SFTPSettingsFailure, .invalidRecord)
        }
        XCTAssertThrowsError(try SFTPSettingsSnapshot.decode(legacyVersion(snapshot, format: 9))) { error in
            XCTAssertEqual(error as? SFTPSettingsFailure, .incompatibleVersion)
        }
        let reopened = SFTPSettingsStore(directory: root.appendingPathComponent("state"))
        let reopenedSnapshot = try await reopened.inspect()
        XCTAssertEqual(reopenedSnapshot, snapshot)
        XCTAssertEqual(backend.callCount, 0)
    }

    func testUnsavedCrossRootMetadataStartsAtFormatSevenWithoutPasswordAccess() async throws {
        let root = try LocalStorageTestFixtures.directory()
        let store = SFTPSettingsStore(directory: root.appendingPathComponent("state"))
        let backend = NoKeychainBackend()
        let state = SFTPRememberedState(settings: store,
            passwords: .init(service: "Traverse.Generated.DefaultDirectory.NoKeychain", backend: backend))
        let draft = try SFTPServerDraft(name: "Unremembered", address: .init("sftp://server.generated.invalid/Original"), account: "alice")
        let directory = try SFTPDefaultDirectory(field: "~/Chosen", root: .home)
        let result = try await state.saveMetadata(draft, expectedRevision: 0, directory: directory)
        let saved = try XCTUnwrap(result.snapshot.visibleServers.first)
        XCTAssertEqual(result.snapshot.format, 7)
        XCTAssertEqual(saved.details, draft)
        XCTAssertEqual(try saved.effectiveDefaultDirectory, directory)
        XCTAssertNil(saved.credentialID)
        XCTAssertTrue(result.snapshot.hosts.isEmpty)
        XCTAssertTrue(result.snapshot.credentials.isEmpty)
        XCTAssertThrowsError(try SFTPSettingsSnapshot.decode(legacyVersion(result.snapshot, format: 6))) { error in
            XCTAssertEqual(error as? SFTPSettingsFailure, .invalidRecord)
        }
        XCTAssertEqual(backend.callCount, 0)
    }
}
