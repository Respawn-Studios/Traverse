import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// Native output facts only. No source/parser, destination-path admission,
/// publication or journal authority lives in this helper.
internal enum ArchiveProducedFacts {
    static func receipt(_ descriptor:Int32,relative:String,hash:Data?,
                        expectedQuarantineSHA256:Data?=nil)throws->ArchiveProducedNode{
        var facts=stat()
        guard fstat(descriptor,&facts)==0,facts.st_uid==geteuid(),facts.st_dev != 0,
              [S_IFREG,S_IFDIR].contains(facts.st_mode&S_IFMT),facts.st_mode&S_IFMT != S_IFREG || facts.st_nlink==1 else{throw FileOperationFailure.destinationChanged}
        return .init(relative:relative,device:facts.st_dev,inode:facts.st_ino,kind:facts.st_mode&S_IFMT,
            birthSeconds:facts.st_birthtimespec.tv_sec,birthNanoseconds:facts.st_birthtimespec.tv_nsec,
            changedSeconds:facts.st_ctimespec.tv_sec,changedNanoseconds:facts.st_ctimespec.tv_nsec,size:facts.st_size,
            contentSHA256:hash,expectedQuarantineSHA256:expectedQuarantineSHA256)
    }
    static func sameObject(_ a:ArchiveProducedNode,_ b:ArchiveProducedNode)->Bool{
        a.device==b.device && a.inode==b.inode && a.kind==b.kind && a.birthSeconds==b.birthSeconds && a.birthNanoseconds==b.birthNanoseconds
    }
    static func empty(_ descriptor:Int32)throws->Bool{
        let copied=dup(descriptor);guard copied>=0 else{throw failure()}
        guard let directory=fdopendir(copied)else{close(copied);throw failure()};defer{closedir(directory)}
        rewinddir(directory)
        while true{
            errno=0;guard let entry=readdir(directory)else{guard errno==0 else{throw failure()};return true}
            let name=withUnsafePointer(to:&entry.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1){String(cString:$0)}}
            if name != "." && name != ".."{return false}
        }
    }
    static func failure(_ value:Int32=errno)->FileOperationFailure{
        switch value{
        case EEXIST,ENOTEMPTY:.conflict
        case EACCES,EPERM,EROFS:.accessDenied
        case ENOSPC:.outOfSpace
        case EDQUOT:.quotaExceeded
        case ENOENT,ENODEV,ENXIO,ESTALE:.unavailable
        default:.ioFailure
        }
    }
}
