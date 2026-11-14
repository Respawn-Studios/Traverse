import Foundation
import Testing
import DriveHealthNative
import IOKit.storage
import XPC
@testable import LocalStorage

struct DriveHealthWireTests {
    @Test func knownHelperCompositionsKeepDistinctManifestsAndInheritedRights() throws {
        let tag = "9309F6A1-E7A3-45C2-A864-0CBF02880D63"
        let preview = try DriveHealthHelperIdentity.Profile.resolve(identifier: "local.macexplorer.preview", info: [
            "MacExplorerDistributionChannel": "development-preview", "MacExplorerReviewCase": tag])
        let shipping = try DriveHealthHelperIdentity.Profile.resolve(identifier: "com.respawnstudios.traverse", info: [
            "MacExplorerDistributionChannel": "developer-id", "MacExplorerAccessPolicy": "sandbox-selected-v1",
            "TraverseDriveHealthHelperVersion": 2, "TraversePrivateUpdaterVersion": "2.10.0"])
        let publicRelease = try DriveHealthHelperIdentity.Profile.resolve(identifier: "com.respawnstudios.traverse", info: [
            "MacExplorerDistributionChannel": "developer-id", "MacExplorerAccessPolicy": "sandbox-selected-v1",
            "TraverseDriveHealthHelperVersion": 2, "TraversePublicUpdaterVersion": "2.10.0"])
        let qaParent = "local.macexplorer.sandbox.remote-editor.9309f6a1e7a345c2a8640cbf02880d63"
        let qa = try DriveHealthHelperIdentity.Profile.resolve(identifier: qaParent, info: [
            "MacExplorerDistributionChannel": "qualification", "MacExplorerStorageMode": "portable",
            "MacExplorerAccessPolicy": "sandbox-selected-v1", "MacExplorerSandboxQualificationCase": tag,
            "TraverseDriveHealthHelperVersion": 2])
        let inherited: [String: Any] = ["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true]
        for profile in [preview, shipping, publicRelease, qa] {
            var manifest: [String: Any] = ["format": profile.inherited ? "drive-health-inherited-v2" : "drive-health-preview-v1",
                "parentIdentifier": profile.parentIdentifier, "helperIdentifier": profile.helperIdentifier,
                "teamIdentifier": "CDLNJRG82U", "sha256": String(repeating: "a", count: 64)]
            if let tag = profile.reviewCase { manifest["reviewCase"] = tag }
            if profile.inherited { manifest["channel"] = profile.channel; manifest["accessPolicy"] = "sandbox-selected-v1" }
            #expect(profile.acceptsManifest(manifest))
            #expect(profile.acceptsHelperRights(inherited) == profile.inherited)
            #expect(profile.acceptsHelperRights([:]) == !profile.inherited)
            var extraRights = inherited; extraRights["com.apple.security.network.client"] = true
            #expect(!profile.acceptsHelperRights(extraRights))
            var changed = manifest; changed["helperIdentifier"] = "another.helper"
            #expect(!profile.acceptsManifest(changed))
            changed = manifest; changed["extra"] = true
            #expect(!profile.acceptsManifest(changed))
            changed = manifest; changed["sha256"] = String(repeating: "G", count: 64)
            #expect(!profile.acceptsManifest(changed))
        }
        var parent: [String: Any] = ["com.apple.security.app-sandbox": true,
            "com.apple.security.files.user-selected.read-write": true,
            "com.apple.security.files.bookmarks.app-scope": true, "com.apple.security.network.client": true]
        #expect(qa.acceptsParentRights(parent))
        #expect(!shipping.acceptsParentRights(parent))
        #expect(!publicRelease.acceptsParentRights(parent))
        parent["com.apple.security.temporary-exception.mach-lookup.global-name"] = [
            "com.respawnstudios.traverse-spks", "com.respawnstudios.traverse-spki"]
        #expect(shipping.acceptsParentRights(parent))
        #expect(publicRelease.acceptsParentRights(parent))
        parent["com.apple.security.temporary-exception.iokit-user-client-class"] = ["UnknownClient"]
        #expect(!shipping.acceptsParentRights(parent))
    }

    @Test func unknownOrMixedHealthCompositionIsNotAdmitted() {
        let profiles: [(String, [String: Any])] = [
            ("com.respawnstudios.traverse", ["MacExplorerDistributionChannel": "app-store", "TraverseDriveHealthHelperVersion": 2]),
            ("com.respawnstudios.traverse", ["MacExplorerDistributionChannel": "developer-id", "MacExplorerAccessPolicy": "sandbox-selected-v1"]),
            ("com.respawnstudios.traverse", ["MacExplorerDistributionChannel": "developer-id", "MacExplorerAccessPolicy": "sandbox-selected-v1", "TraverseDriveHealthHelperVersion": 2, "TraversePrivateUpdaterVersion": "unknown"]),
            ("com.respawnstudios.traverse", ["MacExplorerDistributionChannel": "developer-id", "MacExplorerAccessPolicy": "sandbox-selected-v1", "TraverseDriveHealthHelperVersion": 2, "TraversePublicUpdaterVersion": "unknown"]),
            ("com.respawnstudios.traverse", ["MacExplorerDistributionChannel": "developer-id", "MacExplorerAccessPolicy": "sandbox-selected-v1", "TraverseDriveHealthHelperVersion": 2, "TraversePrivateUpdaterVersion": "2.10.0", "TraversePublicUpdaterVersion": "2.10.0"]),
            ("com.respawnstudios.traverse", ["MacExplorerDistributionChannel": "developer-id", "MacExplorerAccessPolicy": "sandbox-selected-v1", "TraverseDriveHealthHelperVersion": 2, "TraversePublicUpdaterVersion": NSNull()]),
            ("com.respawnstudios.traverse", ["MacExplorerDistributionChannel": "developer-id", "MacExplorerAccessPolicy": "local-user-v1", "TraverseDriveHealthHelperVersion": 2]),
            ("another.app", ["MacExplorerDistributionChannel": "developer-id", "MacExplorerAccessPolicy": "sandbox-selected-v1", "TraverseDriveHealthHelperVersion": 2]),
            ("local.macexplorer.preview", ["MacExplorerDistributionChannel": "development-preview", "MacExplorerReviewCase": "9309F6A1-E7A3-45C2-A864-0CBF02880D63", "TraversePublicUpdaterVersion": "2.10.0"]),
            ("local.macexplorer.preview", ["MacExplorerDistributionChannel": "development-preview", "MacExplorerReviewCase": "invalid"]),
        ]
        for (identifier, info) in profiles {
            #expect(throws: (any Error).self) { _ = try DriveHealthHelperIdentity.Profile.resolve(identifier: identifier, info: info) }
        }
    }

    @Test func directTransportClassificationPreservesExternalAndWrapperBoundaries() {
        for location in [kIOPropertyInternalKey, kIOPropertyExternalKey] {
            let native = [kIOPropertyPhysicalInterconnectLocationKey: location,
                          kIOPropertyPhysicalInterconnectTypeKey: kIOPropertyPhysicalInterconnectTypePCIExpress] as CFDictionary
            #expect(th_native_transport(native) == 2)
            let sata = [kIOPropertyPhysicalInterconnectLocationKey: location,
                        kIOPropertyPhysicalInterconnectTypeKey: kIOPropertyPhysicalInterconnectTypeSerialATA] as CFDictionary
            #expect(th_native_transport(sata) == 1)
            for transport in ["USB", "Thunderbolt", "Virtual", "unknown"] {
                let wrapper = [kIOPropertyPhysicalInterconnectLocationKey: location,
                               kIOPropertyPhysicalInterconnectTypeKey: transport] as CFDictionary
                #expect(th_native_transport(wrapper) == 0)
            }
        }
        #expect(th_native_transport(nil) == 0)
        #expect(th_native_transport([kIOPropertyPhysicalInterconnectTypeKey: kIOPropertyPhysicalInterconnectTypePCIExpress] as CFDictionary) == 0)
        #expect(th_native_transport([kIOPropertyPhysicalInterconnectLocationKey: "unknown",
                                    kIOPropertyPhysicalInterconnectTypeKey: kIOPropertyPhysicalInterconnectTypePCIExpress] as CFDictionary) == 0)
    }
    private let nonce = Array(UInt8(1)...UInt8(16))

    private func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
    private func put64(_ value: UInt64, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
    private func reply(kind: UInt8 = 2, warning: UInt8 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 256)
        bytes.replaceSubrange(0..<4, with: [84, 72, 83, 50]) // THS2
        bytes[4] = 2
        bytes.replaceSubrange(8..<24, with: nonce)
        put32(6, at: 28, in: &bytes) // Complete stage
        bytes[44] = 1
        bytes[45] = warning
        bytes[46] = kind
        bytes[47] = 1
        put64(403, at: 48, in: &bytes) // Selected provider
        put64(1_700_000_000, at: 56, in: &bytes)
        put32(500_000_000, at: 64, in: &bytes)
        if kind == 2 {
            bytes[68] = 1; bytes[69] = 0x36; bytes[70] = 1 // 310Kelvin
            bytes[71] = 97; bytes[72] = 10; bytes[73] = 12
        }
        return bytes
    }

    @Test func serviceReplyUsesTheClosedWireEnvelopeWithoutChildEvidence() throws {
        let message = xpc_dictionary_create(nil, nil, 0)
        let bytes = reply(warning: 0x41)
        bytes.withUnsafeBytes { xpc_dictionary_set_data(message, "reply", $0.baseAddress, $0.count) }
        let report = try #require(DriveHealthXPCClient.decodeReply(message, nonce: nonce, serviceExited: true))
        #expect(report.transport == .serviceReply(settled: true) && !report.childReaped)
        #expect(report.nativeCleanupConfirmed && report.nvmeMeasurements?.temperatureCelsius != nil)
        #expect(report.diagnostic?.childStarted == false && report.diagnostic?.requestSent == true)
        #expect(DriveHealthXPCClient.decodeReply(message, nonce: Array(repeating: 0, count: 16), serviceExited: true) == nil)
        xpc_dictionary_set_bool(message, "extra", true)
        #expect(DriveHealthXPCClient.decodeReply(message, nonce: nonce, serviceExited: true) == nil)
    }

    @Test func stopAndOneServiceRequestShareTheirFinalAdmission() async {
        let stopped = DriveHealthServiceControl()
        stopped.requestStop()
        #expect(!stopped.claimRequest())
        let control = DriveHealthServiceControl()
        let claims = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            group.addTask { control.requestStop(); return false }
            for _ in 0..<32 { group.addTask { control.claimRequest() } }
            var count = 0
            for await accepted in group where accepted { count += 1 }
            return count
        }
        #expect(claims <= 1 && control.stopRequested && !control.claimRequest())
    }

    @Test func malformedServiceEnvelopeNeverPublishesHardwareMeasurements() {
        let wrongType = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(wrongType, "reply", "not a hardware reply")
        #expect(DriveHealthXPCClient.decodeReply(wrongType, nonce: nonce, serviceExited: true) == nil)
        #expect(DriveHealthXPCClient.decodeReply(XPC_ERROR_CONNECTION_INVALID, nonce: nonce, serviceExited: true) == nil)
        #expect(DriveHealthXPCClient.replyFailure(XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT) == .peerIdentity)
        #expect(DriveHealthXPCClient.replyFailure(XPC_ERROR_CONNECTION_INVALID) == .connectionEnded)
        for bytes in [Array(reply().dropLast()), reply() + [0]] {
            let message = xpc_dictionary_create(nil, nil, 0)
            bytes.withUnsafeBytes { xpc_dictionary_set_data(message, "reply", $0.baseAddress, $0.count) }
            #expect(DriveHealthXPCClient.decodeReply(message, nonce: nonce, serviceExited: true) == nil)
        }
        let absent = DriveHealthDrain(transport: .notStarted, nativeCleanupConfirmed: true)
        #expect(absent.transportSettled && !absent.childReaped)
    }

    @Test func serviceCompletionRequiresNonceReplyAndExitAfterTheQueuedAdmission() throws {
        let bytes = Data(reply())
        var replyFirst = DriveHealthServiceReplyState(nonce: nonce)
        replyFirst.didQueue()
        let waitingForExit = replyFirst.receive(bytes)
        #expect(waitingForExit == nil && replyFirst.requiresAcknowledgement)
        let waitingAfterAcknowledgement = replyFirst.didAcknowledge()
        #expect(waitingAfterAcknowledgement == nil && !replyFirst.requiresAcknowledgement)
        let completed = replyFirst.serviceDidExit()
        let first = try #require(completed)
        #expect(first.transportSettled && first.nativeCleanupConfirmed && !first.childReaped)
        #expect(first.nvmeMeasurements != nil)
        var exitFirst = DriveHealthServiceReplyState(nonce: nonce)
        exitFirst.didQueue()
        let waitingForReply = exitFirst.serviceDidExit()
        #expect(waitingForReply == nil)
        let reversed = exitFirst.receive(bytes)
        #expect(reversed == nil && exitFirst.requiresAcknowledgement)
        let acknowledgedAfterExit = exitFirst.didAcknowledge()
        #expect(acknowledgedAfterExit == first)
        // An event preceding this request's admission cannot complete it.
        var early = DriveHealthServiceReplyState(nonce: nonce)
        let ignored = early.serviceDidExit()
        #expect(ignored == nil)
        early.didQueue()
        let missingExit = early.receive(bytes)
        #expect(missingExit == nil)
        let failed = early.fail(.deadline)
        #expect(!failed.transportSettled && failed.nativeCleanupConfirmed && failed.nvmeMeasurements == nil)
        #expect(failed.diagnostic?.transportFailure == .deadline)
        let lateExit = early.serviceDidExit()
        #expect(lateExit == failed) // A late event cannot undo timeout.
    }

    @Test func absentOrInvalidServiceReplyCannotBeRepairedByAnExit() {
        var missing = DriveHealthServiceReplyState(nonce: nonce)
        missing.didQueue()
        let missingReply = missing.serviceDidExit()
        #expect(missingReply == nil)
        let failed = missing.fail()
        #expect(!failed.nativeCleanupConfirmed && !failed.transportSettled && !failed.childReaped)
        let lateReply = missing.receive(Data(reply()))
        #expect(lateReply == failed)
        let unacknowledged = missing.didAcknowledge()
        #expect(unacknowledged == failed)
        var wrong = DriveHealthServiceReplyState(nonce: Array(repeating: 0, count: 16))
        wrong.didQueue()
        _ = wrong.serviceDidExit()
        let invalid = wrong.receive(Data(reply()))
        #expect(invalid?.outcome == .unavailable(.uncertain))
        #expect(wrong.result?.nvmeMeasurements == nil)
    }

    @Test func fixedOneSelectionRequestContainsOnlyEphemeralIDsAndNonce() {
        let target = ManagedVolume(id: UUID(), name: "Generated", url: nil, isInternal: true,
            canMount: false, canUnmount: false, canEject: false, fileSystemID: nil,
            group: 202, mediaID: 101)
        let selected = PreparedDriveHealthSelection(selected: target, selectedMedia: 101,
            outerWhole: 202, blockBoundary: 303, generation: 404)
        let request = [UInt8](DriveHealthWire.request(selected, nonce: nonce))
        #expect(request.count == 64)
        #expect(Array(request[0..<4]) == [84, 72, 82, 50] && request[4] == 2)
        #expect(Array(request[8..<24]) == nonce)
        #expect(request[24] == 101 && request[32] == 202 && request[40] == 47 && request[41] == 1)
        #expect(request[48] == 148 && request[49] == 1)
        #expect(request[5..<8].allSatisfy({ $0 == 0 }) && request[56..<64].allSatisfy({ $0 == 0 }))
    }

    @Test func sharedCRequestCodecPreservesTheExactWorkerAdmission() {
        var valid = [UInt8](repeating: 0, count: Int(THRequestBytes))
        valid.replaceSubrange(0..<4, with: [84, 72, 82, 50]); valid[4] = 2
        valid.replaceSubrange(8..<24, with: nonce)
        for (offset, value) in [(24, UInt64.max), (32, 202), (40, 303), (48, 404)] {
            put64(value, at: offset, in: &valid)
        }
        var decoded = THWireRequest()
        #expect(th_wire_decode_request(valid, valid.count, &decoded) == 1)
        #expect(decoded.selected_media == UInt64.max && decoded.outer_whole == 202
                && decoded.block_boundary == 303 && decoded.generation == 404)
        #expect(withUnsafeBytes(of: decoded.nonce) { Array($0) } == nonce)
        // The legacy worker accepts any16-byte nonce, including all zeroes.
        var zeroNonce = valid; zeroNonce.replaceSubrange(8..<24, with: repeatElement(UInt8(0), count: 16))
        #expect(th_wire_decode_request(zeroNonce, zeroNonce.count, &decoded) == 1)
        var invalid = [Array(valid.dropLast()), valid + [0]]
        for offset in [0, 4, 5, 6, 7, 56, 63] {
            var changed = valid; changed[offset] ^= 1; invalid.append(changed)
        }
        for offset in [24, 32, 40, 48] {
            var changed = valid; put64(0, at: offset, in: &changed); invalid.append(changed)
        }
        for bytes in invalid {
            decoded.selected_media = 99
            #expect(th_wire_decode_request(bytes, bytes.count, &decoded) == 0)
            #expect(decoded.selected_media == 0 && decoded.generation == 0)
        }
        #expect(th_wire_decode_request(nil, valid.count, &decoded) == 0)
    }

    @Test func sharedCResponseCodecMatchesSyntheticSwiftReplyAndFailureLayout() throws {
        var request = THWireRequest()
        withUnsafeMutableBytes(of: &request.nonce) { $0.copyBytes(from: nonce) }
        var result = THNativeOutcome()
        result.status = UInt32(THNativeSample); result.smart.stage = UInt32(THStageComplete)
        result.smart.warning_valid = 1; result.smart.warning_byte = 0x41
        result.smart.provider_kind = UInt8(THKindNVMe); result.cleanup_confirmed = 1
        result.provider = 403; result.captured_seconds = 1_700_000_000; result.captured_nanoseconds = 500_000_000
        result.smart.nvme.valid = 1; result.smart.nvme.temperature_kelvin = 310
        result.smart.nvme.available_spare = 97; result.smart.nvme.spare_threshold = 10
        result.smart.nvme.percentage_used = 12
        var bytes = [UInt8](repeating: 0xff, count: Int(THResponseBytes))
        #expect(th_wire_encode_response(&request, &result, &bytes, bytes.count) == 1)
        #expect(bytes == reply(warning: 0x41))
        #expect(DriveHealthWire.decode(Data(bytes), nonce: nonce)?.nvmeMeasurements != nil)
        _ = withUnsafeMutableBytes(of: &result.smart.nvme.counters_le) { $0.initializeMemory(as: UInt8.self, repeating: 0xff) }
        #expect(th_wire_encode_response(&request, &result, &bytes, bytes.count) == 1)
        #expect(DriveHealthWire.decode(Data(bytes), nonce: nonce)?.nvmeMeasurements?[.dataUnitsRead] == UInt128.max)
        result = THNativeOutcome()
        result.status = UInt32(THNativeReadFailure); result.smart.stage = UInt32(THStageCreate)
        result.smart.code_domain = UInt32(THDomainKernel); result.smart.primary_code = kIOReturnNoResources
        result.cleanup_confirmed = 1
        #expect(th_wire_encode_response(&request, &result, &bytes, bytes.count) == 1)
        let failure = try #require(DriveHealthWire.decode(Data(bytes), nonce: nonce))
        #expect(failure.outcome == .unavailable(.unavailable))
        #expect(failure.diagnostic?.native?.code == kIOReturnNoResources)
        #expect(bytes[68..<256].allSatisfy { $0 == 0 })
        #expect(th_wire_encode_response(&request, &result, &bytes, bytes.count - 1) == 0)
    }

    @Test func completeNativeResultsCopyOnlyThresholdOrCriticalWarningAndTime() {
        let nvme = DriveHealthWire.decode(Data(reply(kind: 2, warning: 0x41)), nonce: nonce)
        #expect(nvme?.childReaped == true && nvme?.nativeCleanupConfirmed == true)
        #expect(nvme?.outcome == .warning(kind: .nvme, rawByte: 0x41,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000.5)))
        let ata = DriveHealthWire.decode(Data(reply(kind: 1, warning: 1)), nonce: nonce)
        #expect(ata?.outcome == .warning(kind: .ata, rawByte: 1,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000.5)))
        #expect(ata?.nvmeMeasurements == nil)
    }

    @Test func serviceCompletionNeverClaimsAReapedChildAndSurvivesInvalidation() throws {
        let report = try #require(DriveHealthWire.decode(Data(reply()), nonce: nonce,
            transport: .serviceReply(settled: true)))
        #expect(report.transport == .serviceReply(settled: true) && report.transportSettled && !report.childReaped)
        #expect(report.drain == DriveHealthDrain(transport: .serviceReply(settled: true), nativeCleanupConfirmed: true))
        #expect(report.diagnostic?.childStarted == false && report.diagnostic?.requestSent == true)
        #expect(report.nvmeMeasurements != nil)
        for reason in [DriveHealthUnavailable.stale, .uncertain, .unavailable] {
            let changed = report.replacingOutcome(.unavailable(reason))
            #expect(changed.transport == report.transport && changed.drain == report.drain)
            #expect(changed.nvmeMeasurements == nil && changed.diagnostic == report.diagnostic)
        }
        let unsettled = try #require(DriveHealthWire.decode(Data(reply()), nonce: nonce,
            transport: .serviceReply(settled: false)))
        #expect(!unsettled.transportSettled && !unsettled.childReaped && unsettled.nativeCleanupConfirmed)
        #expect(unsettled.outcome == .unavailable(.uncertain) && unsettled.nvmeMeasurements == nil)
        let incomplete = DriveHealthReport(outcome: .unavailable(.uncertain),
            transport: .serviceReply(settled: false), nativeCleanupConfirmed: false)
        #expect(incomplete.replacingOutcome(.unavailable(.stale)).drain == incomplete.drain)
        #expect(!incomplete.drain.transportSettled && !incomplete.drain.nativeCleanupConfirmed)
        let legacy = DriveHealthDrain(childReaped: true, nativeCleanupConfirmed: false)
        #expect(legacy.transport == .ownedChild(reaped: true) && legacy.childReaped && legacy.transportSettled)
    }

    @Test func serviceNativeFailureKeepsCleanupAndTransportAsIndependentFacts() throws {
        var bytes = [UInt8](repeating: 0, count: Int(THResponseBytes))
        bytes.replaceSubrange(0..<4, with: [84, 72, 83, 50]); bytes[4] = 2
        bytes.replaceSubrange(8..<24, with: nonce)
        put32(UInt32(THNativeReadFailure), at: 24, in: &bytes)
        put32(UInt32(THStageCreate), at: 28, in: &bytes)
        put32(UInt32(THDomainKernel), at: 32, in: &bytes)
        put32(UInt32(bitPattern: kIOReturnNoResources), at: 36, in: &bytes)
        bytes[47] = 1
        let failed = try #require(DriveHealthWire.decode(Data(bytes), nonce: nonce,
            transport: .serviceReply(settled: true)))
        #expect(failed.outcome == .unavailable(.unavailable) && failed.nvmeMeasurements == nil)
        #expect(failed.nativeCleanupConfirmed && failed.transportSettled && !failed.childReaped)
        bytes[47] = 0
        let uncertain = try #require(DriveHealthWire.decode(Data(bytes), nonce: nonce,
            transport: .serviceReply(settled: true)))
        #expect(uncertain.outcome == .unavailable(.uncertain) && uncertain.transportSettled)
        #expect(!uncertain.nativeCleanupConfirmed && !uncertain.childReaped && uncertain.nvmeMeasurements == nil)
        #expect(uncertain.replacingOutcome(.unavailable(.stale)).drain == uncertain.drain)
    }

    @Test func nvmeSnapshotRetainsFullCountersAndHonestMissingOrOutOfRangeValues() throws {
        var bytes = reply()
        for index in 80..<96 { bytes[index] = 0xff }
        bytes[73] = 255
        let report = try #require(DriveHealthWire.decode(Data(bytes), nonce: nonce))
        let readings = try #require(report.nvmeMeasurements)
        #expect(readings[.dataUnitsRead] == UInt128.max)
        #expect(String(readings[.dataUnitsRead]) == "340282366920938463463374607431768211455")
        #expect(readings[.dataUnitsWritten] == 0 && readings[.errorLogEntries] == 0)
        #expect(abs(try #require(readings.temperatureCelsius) - 36.85) < 0.001)
        #expect(readings.availableSparePercent == 97 && readings.spareThresholdPercent == 10 && readings.percentageUsed == 255)
        bytes[69] = 0; bytes[70] = 0; bytes[71] = 101; bytes[72] = 255
        let missing = try #require(DriveHealthWire.decode(Data(bytes), nonce: nonce)?.nvmeMeasurements)
        #expect(missing.temperatureCelsius == nil && missing.availableSparePercent == nil && missing.spareThresholdPercent == nil)
        let invalid = DriveHealthReport(outcome: .unavailable(.stale), childReaped: true,
            nativeCleanupConfirmed: true, nvmeMeasurements: readings)
        #expect(invalid.nvmeMeasurements == nil)
    }

    @Test func malformedOrUnfinishedReplyNeverBecomesWarningFree() {
        let valid = reply()
        var cases = [[UInt8]]()
        cases.append(Array(valid.dropLast()))
        cases.append(valid + [0])
        var reserved = valid; reserved[74] = 1; cases.append(reserved)
        var tail = valid; tail[255] = 1; cases.append(tail)
        var wrongVersion = valid; wrongVersion[4] = 1; cases.append(wrongVersion)
        var missingMetrics = valid; missingMetrics[68] = 0; cases.append(missingMetrics)
        var ataMetrics = valid; ataMetrics[46] = 1; cases.append(ataMetrics)
        var missingRead = valid; missingRead[44] = 0; cases.append(missingRead)
        var badStage = valid; put32(4, at: 28, in: &badStage); cases.append(badStage)
        var badProvider = valid; put64(0, at: 48, in: &badProvider); cases.append(badProvider)
        var badTime = valid; put64(0, at: 56, in: &badTime); cases.append(badTime)
        let ataOverflow = reply(kind: 1, warning: 2); cases.append(ataOverflow)
        for candidate in cases { #expect(DriveHealthWire.decode(Data(candidate), nonce: nonce) == nil) }
        let staleNonce = Array(repeating: UInt8(9), count: 16)
        #expect(DriveHealthWire.decode(Data(valid), nonce: staleNonce) == nil)
        var incomplete = reply(kind: 1); incomplete[47] = 0
        let result = DriveHealthWire.decode(Data(incomplete), nonce: nonce)
        #expect(result?.outcome == .unavailable(.uncertain))
        #expect(result?.nativeCleanupConfirmed == false)
    }

    @Test func nativeFailureDiagnosticsSurviveOutcomeMapping() throws {
        let cases: [(UInt32, UInt32, UInt32, Int32, DriveHealthUnavailable)] = [
            (UInt32(THNativeUnavailable), UInt32(THStageAdmission), UInt32(THDomainKernel), kIOReturnError, .unavailable),
            (UInt32(THNativeInvalid), UInt32(THStageAdmission), UInt32(THDomainKernel), kIOReturnError, .unavailable),
            (UInt32(THNativeReadFailure), UInt32(THStageCreate), UInt32(THDomainKernel), kIOReturnError, .unavailable),
            (UInt32(THNativeReadFailure), UInt32(THStageQuery), UInt32(THDomainHRESULT), th_smart_no_interface_hresult(), .unsupported),
            (UInt32(THNativeReadFailure), UInt32(THStageRead), UInt32(THDomainIOReturn), kIOReturnNotPermitted, .denied),
            (UInt32(THNativeReadFailure), UInt32(THStageQuery), UInt32(THDomainContract), Int32(THContractMissingQuery), .unavailable)
        ]
        for (status, stage, domain, code, reason) in cases {
            var bytes = [UInt8](repeating: 0, count: 256)
            bytes.replaceSubrange(0..<4, with: [84, 72, 83, 50]); bytes[4] = 2
            bytes.replaceSubrange(8..<24, with: nonce); bytes[47] = 1
            put32(status, at: 24, in: &bytes); put32(stage, at: 28, in: &bytes)
            put32(domain, at: 32, in: &bytes); put32(UInt32(bitPattern: code), at: 36, in: &bytes)
            let report = try #require(DriveHealthWire.decode(Data(bytes), nonce: nonce))
            #expect(report.outcome == .unavailable(reason))
            #expect(report.drain == DriveHealthDrain(childReaped: true, nativeCleanupConfirmed: true))
            #expect(report.nvmeMeasurements == nil)
            let diagnostic = try #require(report.diagnostic)
            #expect(diagnostic.stage == .native && diagnostic.childStarted && diagnostic.requestSent)
            #expect(diagnostic.admissionFailure == nil)
            let native = try #require(diagnostic.native)
            #expect(native.status == status && native.stage == stage && native.domain == domain)
            #expect(native.code == code && native.destroyCode == 0)
        }
    }

    @Test func incompleteCleanupRetainsNativeFailureWithoutMeasurements() throws {
        var bytes = [UInt8](repeating: 0, count: 256)
        bytes.replaceSubrange(0..<4, with: [84, 72, 83, 50]); bytes[4] = 2
        bytes.replaceSubrange(8..<24, with: nonce)
        put32(UInt32(THNativeUncertain), at: 24, in: &bytes)
        put32(UInt32(THStageCleanup), at: 28, in: &bytes)
        put32(UInt32(THDomainIOReturn), at: 32, in: &bytes)
        put32(UInt32(bitPattern: kIOReturnError), at: 36, in: &bytes)
        put32(UInt32(bitPattern: kIOReturnError), at: 40, in: &bytes)
        let report = try #require(DriveHealthWire.decode(Data(bytes), nonce: nonce))
        #expect(report.outcome == .unavailable(.uncertain))
        #expect(report.childReaped && !report.nativeCleanupConfirmed && report.nvmeMeasurements == nil)
        #expect(report.diagnostic?.native?.destroyCode == kIOReturnError)
        #expect(report.diagnostic?.native?.code == kIOReturnError)
        let legacy = DriveHealthReport(outcome: .unavailable(.unavailable), childReaped: true, nativeCleanupConfirmed: true)
        #expect(legacy.diagnostic == nil)
    }
}
