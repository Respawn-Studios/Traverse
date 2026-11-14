import CryptoKit
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPRouteBindingTests: XCTestCase, @unchecked Sendable {
    private func route(target: String = "sftp://database.internal.test:2222", targetAccount: String = "designer",
        jump: String = "sftp://gateway.example.test", jumpAccount: String = "studio", name: String = "Generated route") throws -> SFTPRouteDescription {
        try .init(destination: .init(name: name, address: .init(target), account: targetAccount),
            jump: .init(name: "Generated jump", address: .init(jump), account: jumpAccount))
    }
    private func key() throws -> SFTPHostKey {
        var data = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &data)
        try SFTPWire.field(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, into: &data); return try .init(data)
    }
    func testRouteRolesAndDirectCredentialsNeverHaveTheSameBinding() throws {
        let route = try route(), peer = try key(), digest = Data(SHA256.hash(data: peer.bytes))
        let outer = try route.passwordBinding(role: .jump, verifiedJumpKeyDigest: digest, peerKeyDigest: digest)
        let inner = try route.passwordBinding(role: .destination, verifiedJumpKeyDigest: digest, peerKeyDigest: digest)
        let direct = try SFTPCredentialBinding(request: route.destination.request, key: peer)
        XCTAssertNotEqual(outer.digest, inner.digest); XCTAssertNotEqual(inner.digest, direct.digest); XCTAssertNotEqual(outer.digest, direct.digest)
        XCTAssertEqual(inner.hostKeyDigest,digest); XCTAssertEqual(outer.hostKeyDigest,digest)
    }
    func testEndpointAccountPortAndScopeChangesAreExactButDisplayAndPathAreNotAuthority() throws {
        let original = try route(), digest = Data(repeating: 7, count: 32)
        let binding = try original.bindingTag(role: .destination, verifiedJumpKeyDigest: digest)
        for changed in [try route(target:"sftp://other.internal.test:2222"), try route(target:"sftp://database.internal.test:2223"),
            try route(targetAccount:"Designer"), try route(jump:"sftp://other.example.test"), try route(jump:"sftp://gateway.example.test:2200"), try route(jumpAccount:"Studio")] {
            XCTAssertNotEqual(binding, try changed.bindingTag(role:.destination,verifiedJumpKeyDigest:digest))
        }
        XCTAssertEqual(binding,try route(target:"sftp://database.internal.test:2222/another-folder",name:"Another visible name").bindingTag(role:.destination,verifiedJumpKeyDigest:digest))
        let first = try route(jump:"sftp://[fe80::1%251]:22"), second = try route(jump:"sftp://[fe80::1%252]:22")
        XCTAssertNotEqual(first.authorityDigest,second.authorityDigest)
        let composed = try route(targetAccount:"caf\u{e9}"), decomposed = try route(targetAccount:"cafe\u{301}")
        XCTAssertEqual(composed.destination.account,decomposed.destination.account)
        XCTAssertNotEqual(composed.authorityDigest,decomposed.authorityDigest,"SSH accounts are exact UTF-8 even when Swift strings compare canonically")
        XCTAssertThrowsError(try route(target:"sftp://[fe80::1%251]:22"))
    }
    func testDestinationBindingRejectsClonedTargetKeyOnAnotherVerifiedJump() throws {
        let route = try route(), target = Data(repeating: 3,count:32)
        let first = try route.passwordBinding(role:.destination,verifiedJumpKeyDigest:Data(repeating:1,count:32),peerKeyDigest:target)
        let second = try route.passwordBinding(role:.destination,verifiedJumpKeyDigest:Data(repeating:2,count:32),peerKeyDigest:target)
        XCTAssertNotEqual(first.digest,second.digest)
        let outer = try route.bindingTag(role:.jump,verifiedJumpKeyDigest:Data(repeating:1,count:32))
        // It is possible to compute the outer tag before any destination key
        // exists; no circular demand for an unobservable inner trust proof.
        XCTAssertEqual(outer.count,32)
        for bytes in [Data(),Data(repeating:0,count:31),Data(repeating:0,count:33)] {
            XCTAssertThrowsError(try route.bindingTag(role:.jump,verifiedJumpKeyDigest:bytes))
            XCTAssertThrowsError(try route.passwordBinding(role:.destination,verifiedJumpKeyDigest:target,peerKeyDigest:bytes))
        }
    }
    func testKeyReferencePreservesLegacyEncodingAndRefusesCrossRoleBeforeResolvingBookmark() async throws {
        let route = try route(), peer = try key(), identity = try key(), digest = Data(SHA256.hash(data: peer.bytes)), request = try route.destination.request
        let tag = try route.bindingTag(role:.destination,verifiedJumpKeyDigest:digest)
        let reference = try SFTPKeyAccessReference(bookmark:Data("not-a-native-bookmark".utf8),request:request,host:peer,identity:identity,routeBinding:tag)
        XCTAssertTrue(try reference.matches(request,host:peer,routeBinding:tag))
        XCTAssertFalse(try reference.matches(request,host:peer))
        let direct = try SFTPKeyAccessReference(bookmark:Data([1]),request:request,host:peer,identity:identity)
        XCTAssertFalse(try direct.matches(request,host:peer,routeBinding:tag))
        let encoded = try JSONEncoder().encode(direct)
        XCTAssertFalse(String(decoding:encoded,as:UTF8.self).contains("routeBindingDigest"))
        XCTAssertEqual(try JSONDecoder().decode(SFTPKeyAccessReference.self,from:encoded),direct)
        let selection = try SFTPSelectedPrivateKey(reference:reference)
        let context = SFTPVerifiedSessionContext(host:request.address.host,port:request.address.port,requestedScopeID:0,account:request.account,
            key:peer,previous:nil,permitsRememberingHost:false,permitsSavedAuthentication:false,
            routeKeyBinding:try route.bindingTag(role:.jump,verifiedJumpKeyDigest:digest))
        XCTAssertThrowsError(try context.request()); XCTAssertFalse(context.matches(request))
        let refused = await Task.detached { () -> Bool in
            do { _ = try selection.readAfterHostReview(context,check:{}); return false }
            catch SFTPSessionFailure.keyChanged { return true }
            catch { return false }
        }.value
        XCTAssertTrue(refused,"Wrong-role reference must fail before native bookmark parsing")
    }
    private final class MemoryBackend: SFTPPasswordBackend, @unchecked Sendable {
        private let lock = NSLock(); private var values: [UUID:Data] = [:], reads = 0
        var readCount:Int { lock.withLock { reads } }
        func read(service:String,reference:SFTPCredentialReference)throws->Data {
            try lock.withLock { reads += 1; guard let value = values[reference.id] else { throw SFTPPasswordFailure.missing };return value }
        }
        func save(service:String,reference:SFTPCredentialReference,bytes:Data)throws { lock.withLock { values[reference.id] = bytes } }
        func remove(service:String,reference:SFTPCredentialReference)throws { _ = lock.withLock { values.removeValue(forKey:reference.id) } }
    }
    func testWrongRoleOrJumpKeyCannotReachThePasswordBackend() async throws {
        let route = try route(), outer = Data(repeating:7,count:32), target = Data(repeating:9,count:32), backend = MemoryBackend()
        let vault = SFTPPasswordVault(service:"Generated.Route.InMemoryOnly",backend:backend)
        let binding = try route.passwordBinding(role:.destination,verifiedJumpKeyDigest:outer,peerKeyDigest:target)
        let reference = SFTPCredentialReference(binding:binding)
        _ = try await vault.save(.init("generated-only-password"),reference:reference,binding:binding)
        let wrongRole = try route.passwordBinding(role:.jump,verifiedJumpKeyDigest:outer,peerKeyDigest:target)
        let wrongJump = try route.passwordBinding(role:.destination,verifiedJumpKeyDigest:Data(repeating:8,count:32),peerKeyDigest:target)
        for wrong in [wrongRole,wrongJump] {
            do { _ = try await vault.password(reference,binding:wrong);XCTFail("Unbound lookup admitted") }
            catch SFTPPasswordFailure.bindingMismatch { }
        }
        XCTAssertEqual(backend.readCount,0)
        let password = try await vault.password(reference,binding:binding)
        XCTAssertEqual(password.bytes,Data("generated-only-password".utf8));XCTAssertEqual(backend.readCount,1)
        _ = try await vault.removeOwned(reference);await vault.drain()
    }
}
