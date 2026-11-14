import Foundation

// Diagnostic payloads contain no URLs, paths, identifiers, strings from errors,
// userInfo or file bodies. Observers cannot throw into the operation.
internal enum NativeRetirementStageV4:String,Codable,Sendable {
    case intentCommitted,nativeBegin,nativeReturned,rawCaptured,representationAccepted,representationRefused
    case returnedProjectBegin,returnedProjectReady,returnedEncodingBegin,returnedEncodingReady
    case returnedCommitDispatch,returnedCommitAcknowledged,returnedReadbackBegin,returnedReadbackReady
    case firstVerificationBegin,firstVerificationReady,sourcePinBegin,sourcePinReady
    case synchronizationBegin,synchronizationReady,secondVerificationBegin,secondVerificationReady
    case confirmationProjectBegin,confirmationProjectReady,confirmationCommitDispatch,confirmationCommitAcknowledged
    case confirmationReadbackBegin,confirmationReadbackReady,failureReadbackBegin,failureReadbackReady,failed,finished
}
internal enum NativeRetirementErrorDomainV4:String,Codable,Sendable {case cocoa,posix,osStatus,url,other}
internal enum NativeRetirementCallSourceV4:String,Codable,Sendable {case generatedOverride,retentionHook,defaultFileManager}
internal enum NativeRetirementComparisonV4:String,Codable,Sendable {case notObserved,yes,no}
internal struct NativeRetirementErrorV4:Codable,Sendable {
    let domain:NativeRetirementErrorDomainV4,code:Int
    init(_ error:Error) {
        let value=error as NSError
        switch value.domain {
        case NSCocoaErrorDomain:domain = .cocoa
        case NSPOSIXErrorDomain:domain = .posix
        case NSOSStatusErrorDomain:domain = .osStatus
        case NSURLErrorDomain:domain = .url
        default:domain = .other
        }
        code=value.code
    }
}
internal struct NativeRetirementDiagnosticV4:Codable,Sendable,CustomStringConvertible,CustomDebugStringConvertible {
    let ordinal:Int,stage:NativeRetirementStageV4
    let raw:NativeTrashURLFlagsV4?,bridged:NativeTrashURLFlagsV4?
    let returnedLocationPresent:Bool?,nativeErrorPresent:Bool?
    let equalsStandardized:NativeRetirementComparisonV4,absoluteIsStandardized:NativeRetirementComparisonV4
    let refusal:NativeTrashURLRefusalV4?,error:NativeRetirementErrorV4?
    let fileFailure:String?,capacityFailure:String?
    let returnedDurable:Bool?,confirmedDurable:Bool?,failureStage:NativeRetirementStageV4?
    let callSource:NativeRetirementCallSourceV4?
    let directoryHintAdded:Bool?
    var description:String {"Native retirement diagnostic (closed fields only)"}
    var debugDescription:String {description}
}
internal struct NativeRetirementTraceV4 {
    static let maximumEvents=64
    private var ordinal=0
    private(set) var lastStage:NativeRetirementStageV4?
    private let observer:(@Sendable(NativeRetirementDiagnosticV4)->Void)?
    init(observer:(@Sendable(NativeRetirementDiagnosticV4)->Void)?){self.observer=observer}
    mutating func observe(_ stage:NativeRetirementStageV4,raw:NativeTrashURLFlagsV4?=nil,bridged:NativeTrashURLFlagsV4?=nil,
        returned:Bool?=nil,nativeError:Bool?=nil,equalsStandardized:NativeRetirementComparisonV4 = .notObserved,
        absoluteIsStandardized:NativeRetirementComparisonV4 = .notObserved,refusal:NativeTrashURLRefusalV4?=nil,error:Error?=nil,
        returnedDurable:Bool?=nil,confirmedDurable:Bool?=nil,failureStage:NativeRetirementStageV4?=nil,callSource:NativeRetirementCallSourceV4?=nil,directoryHintAdded:Bool?=nil) {
        guard ordinal<Self.maximumEvents else{return};ordinal+=1
        lastStage=stage
        observer?(.init(ordinal:ordinal,stage:stage,raw:raw,bridged:bridged,returnedLocationPresent:returned,nativeErrorPresent:nativeError,
            equalsStandardized:equalsStandardized,absoluteIsStandardized:absoluteIsStandardized,refusal:refusal,error:error.map(NativeRetirementErrorV4.init),
            fileFailure:(error as? FileOperationFailure)?.rawValue,capacityFailure:(error as? LocalTextCapacityReason)?.rawValue,
            returnedDurable:returnedDurable,confirmedDurable:confirmedDurable,failureStage:failureStage,callSource:callSource,directoryHintAdded:directoryHintAdded))
    }
}
internal struct NativeRetirementCallV4:Sendable {
    let raw:NSURL?,error:(any Error)?
}
