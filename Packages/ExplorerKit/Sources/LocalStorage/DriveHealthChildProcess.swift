import Darwin
import Foundation

internal enum DriveHealthChildProcess {
    private static let maximumReplyBytes = 256
    static func run(_ selection: PreparedDriveHealthSelection,
                    control: ReadOnlyToolChildControl) -> DriveHealthReport {
        let admission: DriveHealthHelperIdentity.Prepared
        do { admission = try DriveHealthHelperIdentity.prepare() }
        catch {
            return .init(outcome: .unavailable(DriveHealthHelperIdentity.compositionDeclared ? .unavailable : .unsupported),
                transport: .notStarted, nativeCleanupConfirmed: true,
                diagnostic: .init(stage: .helperAdmission, admissionFailure: admissionFailure(error)))
        }
        guard !control.stopRequested else {
            return .init(outcome: .unavailable(.stale), transport: .notStarted, nativeCleanupConfirmed: true,
                diagnostic: .init(stage: .installation))
        }
        do { try admission.validateInstallation() }
        catch { return .init(outcome: .unavailable(.unavailable), transport: .notStarted, nativeCleanupConfirmed: true,
            diagnostic: .init(stage: .installation, admissionFailure: admissionFailure(error))) }
        let child = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = admission.helper
        child.arguments = []
        child.environment = ["LANG": "C", "LC_ALL": "C"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        do { try child.run() }
        catch { return .init(outcome: .unavailable(.unavailable), transport: .notStarted, nativeCleanupConfirmed: true,
            diagnostic: .init(stage: .launch)) }
        control.attach(child)
        var sent = false, admitted = false
        var failureStage = DriveHealthDiagnostic.Stage.childAdmission
        var failureAdmission: DriveHealthDiagnostic.AdmissionFailure?
        var nonce = UUID().uuid
        let nonceBytes = withUnsafeBytes(of: &nonce) { Array($0) }
        if !control.stopRequested {
            do {
                try admission.validateChild(child.processIdentifier)
                admitted = true
                failureStage = .request
                let request = DriveHealthWire.request(selection, nonce: nonceBytes)
                try input.fileHandleForWriting.write(contentsOf: request)
                sent = true
            } catch { failureAdmission = admissionFailure(error); control.requestStop() }
        }
        try? input.fileHandleForWriting.close()
        let observation = NativeToolPipes.collect(child, output: output, outputLimit: maximumReplyBytes,
            errors: errors, errorLimit: maximumReplyBytes, query: .init(control: control, timeout: nil))
        control.detachAfterReap()
        guard admitted, sent else {
            return .init(outcome: .unavailable(control.stopRequested ? .stale : .uncertain),
                childReaped: true, nativeCleanupConfirmed: false,
                diagnostic: .init(stage: failureStage, childStarted: true, requestSent: sent,
                    admissionFailure: failureAdmission))
        }
        guard observation.status == 0, !observation.stopped, observation.complete,
              !observation.stdoutTruncated, observation.stderr.isEmpty, !observation.stderrTruncated,
              let decoded = DriveHealthWire.decode(observation.stdout, nonce: nonceBytes) else {
            return .init(outcome: .unavailable(.uncertain), childReaped: true, nativeCleanupConfirmed: false,
                diagnostic: .init(stage: .reply, childStarted: true, requestSent: true))
        }
        return decoded
    }

    private static func admissionFailure(_ error: Error) -> DriveHealthDiagnostic.AdmissionFailure? {
        switch error {
        case DriveHealthHelperIdentity.Failure.policy: return .policy
        case DriveHealthHelperIdentity.Failure.changed: return .changed
        case DriveHealthHelperIdentity.Failure.signature: return .signature
        default: return nil
        }
    }

}
