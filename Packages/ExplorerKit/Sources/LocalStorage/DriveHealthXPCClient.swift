import Foundation
import XPC

/// Stop invalidates publication while the admitted native request finishes.
/// It cannot turn connection cancellation into evidence of native cleanup.
internal final class DriveHealthServiceControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false, admitted = false
    var stopRequested: Bool { lock.withLock { stopped } }
    func requestStop() { lock.withLock { stopped = true } }
    /// This is the send-admission instant. Stop before it refuses the request;
    /// Stop after it invalidates publication while that one request finishes.
    func claimRequest() -> Bool {
        lock.withLock {
            guard !stopped, !admitted else { return false }
            admitted = true
            return true
        }
    }
}

/// One queued request, one nonce reply and its service's exit notification.
/// Queueing happens before connection activation, so an interruption cancels
/// that queued send rather than silently replaying it to another service.
internal struct DriveHealthServiceReplyState {
    private let nonce: [UInt8]
    private var queued = false, acknowledged = false, exited = false
    private var reply: Data?
    private(set) var result: DriveHealthReport?

    init(nonce: [UInt8]) { self.nonce = nonce }
    mutating func didQueue() { if result == nil { queued = true } }
    mutating func receive(_ data: Data) -> DriveHealthReport? {
        guard queued, result == nil else { return result }
        guard data.count == 256, reply == nil,
              DriveHealthWire.decode(data, nonce: nonce, transport: .serviceReply(settled: false)) != nil else {
            return fail()
        }
        reply = data
        return completeIfReady()
    }
    mutating func serviceDidExit() -> DriveHealthReport? {
        guard queued, result == nil else { return result }
        exited = true
        return completeIfReady()
    }
    var requiresAcknowledgement: Bool { reply != nil && !acknowledged && result == nil }
    mutating func didAcknowledge() -> DriveHealthReport? {
        guard requiresAcknowledgement else { return result }
        acknowledged = true
        return completeIfReady()
    }
    mutating func fail(_ reason: DriveHealthDiagnostic.TransportFailure = .malformedReply) -> DriveHealthReport {
        if let result { return result }
        let pending = reply.flatMap { DriveHealthWire.decode($0, nonce: nonce, transport: .serviceReply(settled: false)) }
        let diagnostic = DriveHealthDiagnostic(stage: .reply, requestSent: queued,
            transportFailure: reason, native: pending?.diagnostic?.native)
        let failed: DriveHealthReport = pending?.replacingOutcome(.unavailable(.uncertain), diagnostic: diagnostic)
            ?? DriveHealthReport(outcome: .unavailable(.uncertain), transport: queued ? .serviceReply(settled: false) : .notStarted,
                     nativeCleanupConfirmed: !queued, diagnostic: diagnostic)
        result = failed
        reply = nil
        return failed
    }
    private mutating func completeIfReady() -> DriveHealthReport? {
        guard exited, acknowledged, let reply else { return nil }
        result = DriveHealthWire.decode(reply, nonce: nonce, transport: .serviceReply(settled: true))
        self.reply = nil
        return result
    }
}

internal enum DriveHealthXPCClient {
    static func run(_ selection: PreparedDriveHealthSelection,
                    control: DriveHealthServiceControl) async -> DriveHealthReport {
        let request = Request(selection: selection, control: control)
        return await withTaskCancellationHandler {
            await request.run()
        } onCancel: { control.requestStop() }
    }

    /// Closed, bounded response parsing is shared with the existing wire tests;
    /// the caller has already applied the authenticated peer requirement.
    static func decodeReply(_ object: xpc_object_t, nonce: [UInt8], serviceExited: Bool) -> DriveHealthReport? {
        guard let bytes = replyData(object) else { return nil }
        return DriveHealthWire.decode(bytes, nonce: nonce, transport: .serviceReply(settled: serviceExited))
    }
    fileprivate static func setBytes(_ data: Data, on message: xpc_object_t, key: String) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return false }
            xpc_dictionary_set_data(message, key, base, buffer.count)
            return true
        }
    }

    fileprivate static func replyData(_ object: xpc_object_t) -> Data? {
        guard xpc_get_type(object) == XPC_TYPE_DICTIONARY,
              xpc_dictionary_get_count(object) == 1,
              let value = xpc_dictionary_get_value(object, "reply"),
              xpc_get_type(value) == XPC_TYPE_DATA, xpc_data_get_length(value) == 256,
              let bytes = xpc_data_get_bytes_ptr(value) else { return nil }
        return Data(bytes: bytes, count: 256)
    }
    static func replyFailure(_ object: xpc_object_t) -> DriveHealthDiagnostic.TransportFailure? {
        guard xpc_get_type(object) == XPC_TYPE_ERROR else { return nil }
        if object === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT { return .peerIdentity }
        return .connectionEnded
    }

    /// All request state and XPC objects stay on one private serial queue.
    /// Only the separately locked Stop flag crosses that boundary. XPC's C
    /// callbacks require this concrete queue owner rather than an actor hop.
    private final class Request: @unchecked Sendable {
        private let queue = DispatchQueue(label: "local.traverse.drive-health-service", qos: .utility)
        private let selection: PreparedDriveHealthSelection
        private let control: DriveHealthServiceControl
        private let nonce: [UInt8]
        private var replyState: DriveHealthServiceReplyState
        private var connection: xpc_connection_t?
        private var continuation: CheckedContinuation<DriveHealthReport, Never>?
        private var sent = false, finished = false

        init(selection: PreparedDriveHealthSelection, control: DriveHealthServiceControl) {
            self.selection = selection; self.control = control
            var value = UUID().uuid
            nonce = withUnsafeBytes(of: &value) { Array($0) }
            replyState = DriveHealthServiceReplyState(nonce: nonce)
        }

        func run() async -> DriveHealthReport {
            await withCheckedContinuation { continuation in
                queue.async { [self] in begin(continuation) }
            }
        }

        private func begin(_ continuation: CheckedContinuation<DriveHealthReport, Never>) {
            dispatchPrecondition(condition: .onQueue(queue))
            self.continuation = continuation
            guard !control.stopRequested else {
                finish(failure(.stale, stage: .installation, cleanup: true)); return
            }
            let admission: DriveHealthServiceIdentity.Prepared
            do {
                admission = try DriveHealthServiceIdentity.prepare()
                try admission.validateInstallation()
            } catch {
                finish(failure(DriveHealthServiceIdentity.compositionDeclared ? .unavailable : .unsupported,
                    stage: .helperAdmission, cleanup: true, admission: Self.admissionFailure(error)))
                return
            }
            guard !control.stopRequested else {
                finish(failure(.stale, stage: .installation, cleanup: true)); return
            }
            let peer = xpc_connection_create(admission.serviceIdentifier, queue)
            connection = peer
            xpc_connection_set_event_handler(peer) { [weak self] event in
                guard let self, xpc_get_type(event) == XPC_TYPE_ERROR, !finished else { return }
                if !sent { finish(failure(.unavailable, stage: .launch, cleanup: true)) }
                else if event === XPC_ERROR_CONNECTION_INTERRUPTED,
                        let report = replyState.serviceDidExit() { finish(report) }
            }
            let requirement = admission.peerRequirement.withCString {
                xpc_connection_set_peer_code_signing_requirement(peer, $0)
            }
            guard requirement == 0 else {
                // A locally created inactive connection cannot be finally
                // released. Activate then cancel, without sending any request.
                xpc_connection_activate(peer)
                finish(failure(.unavailable, stage: .helperAdmission, cleanup: true, admission: .signature)); return
            }
            guard !control.stopRequested else {
                xpc_connection_activate(peer)
                finish(failure(.stale, stage: .request, cleanup: true)); return
            }
            let message = xpc_dictionary_create(nil, nil, 0)
            let bytes = DriveHealthWire.request(selection, nonce: nonce)
            guard DriveHealthXPCClient.setBytes(bytes, on: message, key: "request"), control.claimRequest() else {
                xpc_connection_activate(peer)
                finish(failure(.stale, stage: .request, cleanup: true)); return
            }
            // Queued is not proof that acquisition began. After this point an
            // absent/invalid reply is nevertheless uncertain, never a retry.
            sent = true
            replyState.didQueue()
            xpc_connection_send_message_with_reply(peer, message, queue) { [self] reply in
                guard !finished else { return }
                if let failure = DriveHealthXPCClient.replyFailure(reply) {
                    finish(replyState.fail(failure)); return
                }
                guard let data = DriveHealthXPCClient.replyData(reply) else {
                    finish(replyState.fail()); return
                }
                if let report = replyState.receive(data) { finish(report); return }
                guard replyState.requiresAcknowledgement else { return }
                // Keep the authenticated service alive until its reply has
                // actually been validated here. A send barrier at the service
                // cannot prove receipt or keep live-peer validation possible.
                let acknowledgement = xpc_dictionary_create(nil, nil, 0)
                guard DriveHealthXPCClient.setBytes(Data(nonce), on: acknowledgement, key: "ack") else {
                    finish(replyState.fail()); return
                }
                guard let connection else { finish(replyState.fail(.connectionEnded)); return }
                xpc_connection_send_message(connection, acknowledgement)
                if let report = replyState.didAcknowledge() { finish(report) }
            }
            // Inactive connections retain this single send. Activation follows
            // admission/queueing; an interrupted send is never replayed here.
            xpc_connection_activate(peer)
            queue.asyncAfter(deadline: .now() + .seconds(10)) { [weak self] in
                guard let self, !finished else { return }
                // This bounds waiting, not the native call or service lifetime.
                // Incomplete transport keeps the app's activity/drives fenced.
                finish(replyState.fail(.deadline))
            }
        }

        private func finish(_ report: DriveHealthReport) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !finished else { return }
            finished = true
            // A successful request has both its terminal reply and the public
            // service-exit notification. Cancellation supplies neither fact.
            if let connection { xpc_connection_cancel(connection) }
            connection = nil
            let continuation = continuation; self.continuation = nil
            continuation?.resume(returning: report)
        }

        private func failure(_ reason: DriveHealthUnavailable, stage: DriveHealthDiagnostic.Stage,
                             cleanup: Bool, admission: DriveHealthDiagnostic.AdmissionFailure? = nil) -> DriveHealthReport {
            .init(outcome: .unavailable(reason), transport: sent ? .serviceReply(settled: false) : .notStarted,
                  nativeCleanupConfirmed: cleanup,
                  diagnostic: .init(stage: stage, requestSent: sent, admissionFailure: admission))
        }

        private static func admissionFailure(_ error: Error) -> DriveHealthDiagnostic.AdmissionFailure? {
            switch error {
            case DriveHealthHelperIdentity.Failure.policy: .policy
            case DriveHealthHelperIdentity.Failure.changed: .changed
            case DriveHealthHelperIdentity.Failure.signature: .signature
            default: nil
            }
        }
    }
}
