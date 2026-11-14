import Foundation
import Testing
@testable import ExplorerCore

struct SMBConnectionTests {
    @Test func addressesAreExplicitBoundedCanonicalAndNotCredentials() throws {
        let a = try SMBShareAddress(" SMB://NAS.local:445/Team%20Files/ ")
        #expect(a.host == "nas.local" && a.share == "Team Files" && a.displayAddress == "smb://nas.local/Team%20Files")
        #expect(a == (try SMBShareAddress("smb://nas.local/Team Files")))
        #expect(a != (try SMBShareAddress("smb://nas.local/team files")))
        #expect(try SMBShareAddress("smb://192.168.1.20/資料").share == "資料")
        #expect(try SMBShareAddress("smb://[2001:db8::1]/Shared").host == "[2001:db8::1]")
        #expect(String(describing: a) == "SMB share address" && String(reflecting: a) == "SMB share address")
        #expect(throws: SMBAddressFailure.credentialsNotAllowed) { try SMBShareAddress("smb://alice:secret@nas.local/share") }
        #expect(!SMBAddressFailure.credentialsNotAllowed.userMessage.contains("secret"))
    }
    @Test func ambiguousUnsafeAndUnsupportedAddressesRefuse() {
        let values = ["", "server", "\\\\server\\share", "ftp://server/share", "smb://server", "smb://server/", "smb://server/a/b",
            "smb://server/a//", "smb://server/a?x=y", "smb://server/a#x", "smb://server/%2e%2e", "smb://server/%2f",
            "smb://server/a%2f", "smb://server/%252e%252e", "smb://server/%5c", "smb://server/a%00", "smb://server/a%0a",
            "smb://server/a\n", "smb://server/a\u{202e}", "smb://server:/a", "smb://server:0445/a", "smb://server:1445/a",
            "smb://server:65536/a", "smb://[fe80::1%25en0]/a", "smb://127.1/a", "smb://0127.0.0.1/a", "smb://bad_host/a",
            "smb://server/" + String(repeating: "a", count: 256), String(repeating: "x", count: 2_049)]
        for (ordinal, value) in values.enumerated() { #expect(throws: (any Error).self, "Generated address case \(ordinal)") { try SMBShareAddress(value) } }
    }
    @Test func submissionIsNotConnectionAndVerificationRefusesWritableMounts() throws {
        var value = SMBConnectionLifecycle(); let id = try value.begin(SMBShareAddress("smb://nas/share"))
        #expect(value.phase == .connecting && value.nativeRequestPending && !value.canRead && !value.canConnect)
        #expect(value.completed(id, result: .mounted(count: 1)) == .verifySingleMount(id))
        #expect(value.phase == .checkingMount && value.verificationPending && !value.canRead)
        #expect(value.verified(id, problem: .writableMount) && value.phase == .failed(.writableMount) && value.canConnect)
        #expect(!value.verified(id, problem: nil) && !value.canRead)
    }
    @Test func deadlineAndCloseRetainActualRequestUntilCompletion() throws {
        var value = SMBConnectionLifecycle(); let id = try value.begin(SMBShareAddress("smb://nas/share"))
        #expect(value.deadlinePassed(id) && value.phase == .outcomeUncertain && value.hasOutstandingWork && !value.canConnect)
        #expect(throws: SMBConnectionProblem.busy) { try value.begin(SMBShareAddress("smb://other/share")) }
        value.closeView()
        #expect(value.phase == .finishingClosedView && value.nativeRequestPending && value.address != nil)
        #expect(value.completed(id, result: .mounted(count: 1)) == .none && value.phase == .closed && !value.hasOutstandingWork && value.address == nil)
    }
    @Test func oldDuplicateAndWrongCallbacksCannotAffectCurrentGeneration() throws {
        var value = SMBConnectionLifecycle(); let address = try SMBShareAddress("smb://nas/share"), first = try value.begin(address)
        let failedSubmission = value.submissionFailed(first, problem: .unavailable)
        #expect(failedSubmission)
        #expect(value.completed(first, result: .mounted(count: 1)) == .none)
        let second = try value.begin(address)
        #expect(value.completed(first, result: .failed(.denied)) == .none && value.nativeRequestPending)
        #expect(value.completed(UUID(), result: .mounted(count: 1)) == .none && value.phase == .connecting)
        #expect(value.completed(second, result: .userCancelled) == .none && value.phase == .userCancelled && !value.hasOutstandingWork)
        #expect(value.completed(second, result: .mounted(count: 1)) == .none && !value.canRead)
    }
    @Test func ambiguousMountsAndEveryVerificationFailureRemainUnavailable() throws {
        for count in [Int.min, -1, 0, 2, Int.max] {
            var value = SMBConnectionLifecycle(); let id = try value.begin(SMBShareAddress("smb://nas/share"))
            #expect(value.completed(id, result: .mounted(count: count)) == .none && value.phase == .failed(.invalidResult) && !value.canRead)
        }
        for problem in [SMBConnectionProblem.authentication, .denied, .unavailable, .invalidResult, .writableMount, .notSMB, .changed] {
            var value = SMBConnectionLifecycle(); let id = try value.begin(SMBShareAddress("smb://nas/share"))
            _ = value.completed(id, result: .mounted(count: 1))
            #expect(value.verified(id, problem: problem) && value.phase == .failed(problem) && !value.canRead)
        }
    }
    @Test func closeDuringVerificationOrReadWaitsForActualWorkerExit() throws {
        for verifying in [true, false] {
            var value = SMBConnectionLifecycle(); let id = try value.begin(SMBShareAddress("smb://nas/share"))
            var reader: UUID?
            _ = value.completed(id, result: .mounted(count: 1))
            if !verifying {
                #expect(value.verified(id, problem: nil) && value.canRead)
                reader = value.beginRead()
                #expect(reader != nil && reader != id && value.beginRead() == nil)
            }
            value.closeView()
            #expect(value.hasOutstandingWork && value.phase == .finishingClosedView)
            #expect(!value.readerFinished(UUID()) && !value.verified(UUID(), problem: nil) && value.hasOutstandingWork)
            let finished = verifying ? value.verified(id, problem: nil) : value.readerFinished(try #require(reader))
            #expect(finished)
            #expect(!value.hasOutstandingWork && value.phase == .closed && value.address == nil && !value.canRead && !value.canConnect)
        }
    }
    @Test func duplicateReadCompletionCannotDrainTheNextRead() throws {
        var value = SMBConnectionLifecycle()
        let connection = try value.begin(SMBShareAddress("smb://nas/share"))
        _ = value.completed(connection, result: .mounted(count: 1))
        let verified = value.verified(connection, problem: nil)
        #expect(verified)
        let firstRead = value.beginRead(), first = try #require(firstRead)
        let finishedFirst = value.readerFinished(first)
        #expect(finishedFirst)
        let secondRead = value.beginRead(), second = try #require(secondRead)
        #expect(first != second && first != connection && second != connection)
        let staleFailure = value.readerFinished(first, problem: .unavailable)
        #expect(!staleFailure)
        let connectionCompletion = value.readerFinished(connection)
        #expect(!connectionCompletion)
        #expect(value.readerPending && value.phase == .connectedReadOnly)
        value.closeView()
        let staleCompletion = value.readerFinished(first)
        #expect(!staleCompletion)
        #expect(value.hasOutstandingWork && value.phase == .finishingClosedView)
        let finishedSecond = value.readerFinished(second)
        #expect(finishedSecond)
        #expect(!value.hasOutstandingWork && value.phase == .closed && value.address == nil)
    }
}
