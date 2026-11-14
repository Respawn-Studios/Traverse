import Darwin
import Foundation

extension OperationHistoryInspector {
    // No generic inspect/page/unfinishedCount and no writable journal on these
    // selected reads. Reopening validates the envelope and exact selected proof.
    static func textRead10<T>(_ directory:URL,cancellation:OperationCancellation,metrics:JournalMetrics? = nil,
        seconds:TimeInterval=3,maximumCallbacks:Int=5_000,
        _ body:(SQLiteJournalStore) throws -> T) throws -> T? {
        let parent = try DirectoryAnchor(directory.deletingLastPathComponent(),resolve:false)
        guard try NativeRenameEntry.optional(parent:parent,name:directory.lastPathComponent) != nil else { return nil }
        let anchor = try DirectoryAnchor(directory,resolve:false)
        let marker = ".mac-explorer-journal-v1"
        let fd = openat(anchor.fd,marker,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() };defer {close(fd)}
        var root = stat(),st = stat()
        guard fstat(anchor.fd,&root) == 0,root.st_uid == geteuid(),root.st_mode & 0o077 == 0,
              fstat(fd,&st) == 0,st.st_uid == geteuid(),st.st_nlink == 1,st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o077 == 0,flock(fd,LOCK_EX|LOCK_NB) == 0 else { throw FileOperationFailure.unavailable }
        let pin = try EntrySnapshot(fd:fd)
        guard let string = String(data:try OperationJournal.read(name:marker,anchor:anchor),encoding:.utf8),let owner = UUID(uuidString:string) else { throw FileOperationFailure.recoveryUncertain }
        func snapshot() throws -> [String:EntrySnapshot] {
            let names = try GroupedCopyFilesystemEvidence.children(in:anchor,cancellation:cancellation,limit:16_384)
            let known:Set<String> = [marker,".mac-explorer-sqlite-v2",".mac-explorer-sqlite-ready-v2",SQLiteJournalStore.name,SQLiteJournalStore.name+"-journal"]
            for name in names {
                guard known.contains(name) || legacyName10(name) else { throw FileOperationFailure.recoveryUncertain }
            }
            return try Dictionary(uniqueKeysWithValues:names.map{($0,try EntrySnapshot(parent:anchor.fd,name:$0))})
        }
        let before = try snapshot()
        guard before[marker] == pin else { throw FileOperationFailure.sourceChanged }
        for token in [".mac-explorer-sqlite-v2",".mac-explorer-sqlite-ready-v2"] {
            guard try OperationJournal.read(name:token,anchor:anchor) == Data(owner.uuidString.utf8) else { throw FileOperationFailure.recoveryUncertain }
        }
        let store = try SQLiteJournalStore(readOnly:anchor,owner:owner,budget:OperationHistoryReadBudget(cancellation:cancellation,seconds:seconds,maximumCallbacks:maximumCallbacks),metrics:metrics)
        let result = try body(store)
        try store.validateFiles();try anchor.validate();try parent.validate();try cancellation.check()
        guard try snapshot() == before,try EntrySnapshot(fd:fd) == pin else { throw FileOperationFailure.sourceChanged }
        return result
    }
    private static func legacyName10(_ name:String) -> Bool {
        let bytes = Array(name.utf8)
        return bytes.count == 48 && bytes[36] == 45 && name.hasSuffix(".json")
            && UUID(uuidString:String(name.prefix(36))) != nil
            && bytes[37..<43].allSatisfy{(48...57).contains($0)}
    }
    static func textSavePlanningV3(_ directory:URL,slot:RevisionDigest,cancellation:OperationCancellation,
        selectionHistory:SelectionGroupHistoryIdentity? = nil) throws -> TextPlanning10? {
        guard selectionHistory == nil else { throw FileOperationFailure.unsupported }
        return try textRead10(directory,cancellation:cancellation) {try $0.textSavePlanningV3(slot:slot)}
    }
    static func textSelectedSlotV4(_ directory:URL,target:URL,parent:EntrySnapshot,witness:RevisionWitness,
        cancellation:OperationCancellation) throws -> TextSlotSelectionV4? {
        try textRead10(directory,cancellation:cancellation) {
            try $0.textSelectedSlotV4(target:target,parent:parent,witness:witness)
        }
    }
    static func textInspectionV2(_ directory:URL,id:UUID,cancellation:OperationCancellation,
        selectionHistory:SelectionGroupHistoryIdentity? = nil)
        throws -> (record:TextRevisionRecordV2,head:TextRevisionHeadV2?,exports:[TextRecoveryExportV2],undo:LocalTextUndoDisposition)? {
        guard selectionHistory == nil else { throw FileOperationFailure.unsupported }
        return try textRead10(directory,cancellation:cancellation) {store in
            let record = try store.textRecordV2(id)
            return (record,try? store.textHeadV2(slot:record.manifest.slot),try store.textExportsV2(id),try store.textUndoDisposition10(id))
        }
    }
    static func textDocumentRevisionsV3(_ directory:URL,slot:RevisionDigest,after:UUID?,limit:Int,
        cancellation:OperationCancellation,selectionHistory:SelectionGroupHistoryIdentity? = nil,
        metrics:JournalMetrics? = nil,admissionObserver:(@Sendable () -> Void)? = nil)
        throws -> (records:[TextRevisionRecordV2],head:TextRevisionHeadV2?,next:UUID?,undo:[UUID:LocalTextUndoDisposition])? {
        guard selectionHistory == nil else { throw FileOperationFailure.unsupported }
        return try textRead10(directory,cancellation:cancellation,metrics:metrics) {store in
            admissionObserver?()
            let page=try store.textDocumentRevisionsV3(slot:slot,after:after,limit:limit)
            var dispositions:[UUID:LocalTextUndoDisposition]=[:]
            for record in page.records {
                guard dispositions[record.id] == nil else {throw FileOperationFailure.recoveryUncertain}
                dispositions[record.id]=try store.textUndoDisposition10(record.id)
            }
            guard dispositions.count==page.records.count else {throw FileOperationFailure.recoveryUncertain}
            return (page.records,page.head,page.next,dispositions)
        }
    }
}
