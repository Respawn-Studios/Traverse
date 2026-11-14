/// Closed local failure facts for an explicit remote text Open. The caller may
/// record these numeric codes without exposing paths, file bytes or error text.
@_spi(Qualification) public struct SFTPInPlaceOpenDiagnostic: Sendable, Equatable {
    public let error: DiagnosticErrorCode
    public let cause: DiagnosticErrorCode?

    private init(_ code: Int64, cause: DiagnosticErrorCode? = nil) {
        error = .init(domain: .network, code: code)
        self.cause = cause
    }

    public static func project(_ value: any Error) -> Self? {
        if let failure = value as? DownloadQuarantineFailure {
            switch failure {
            case .unsafe: return .init(1201)
            case .changed: return .init(1202)
            case .unavailable: return .init(1203)
            }
        }
        if let failure = value as? RemoteDownloadStorageFailure {
            switch failure {
            case .unsafe: return .init(1211)
            case .changed: return .init(1212)
            case .unavailable: return .init(1213)
            case .capacity: return .init(1214)
            case .busy: return .init(1215)
            case .incomplete: return .init(1216)
            case .io(let number):
                let cause = (1...4095).contains(number) ? DiagnosticErrorCode(domain: .posix, code: Int64(number)) : nil
                return .init(1217, cause: cause)
            }
        }
        if let failure = value as? SFTPSharedBudgetFailure {
            switch failure {
            case .unsafe: return .init(1231)
            case .busy: return .init(1232)
            case .capacity: return .init(1233)
            case .recoveryRequired: return .init(1234)
            case .ownerEnded: return .init(1235)
            case .stale: return .init(1236)
            case .referenced: return .init(1237)
            }
        }
        return nil
    }
}
