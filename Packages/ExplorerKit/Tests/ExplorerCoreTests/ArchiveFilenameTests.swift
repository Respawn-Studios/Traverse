import Testing
@testable import ExplorerCore

struct ArchiveFilenameTests {
    @Test func wrapperAliasesKeepOneIdentityAndWholeSuffix() {
        for (kind, names) in [
            (ArchiveFilename.Kind.tarGzip, ["Data.tar.gz", "Data.TGZ"]),
            (.tarBzip2, ["Data.tar.bz2", "Data.TBZ2", "Data.tbz"]),
            (.tarXZ, ["Data.tar.xz", "Data.TXZ"]),
            (.tarZstandard, ["Data.tar.zst", "Data.TZST"])
        ] {
            for name in names {
                #expect(ArchiveFilename(name)?.kind == kind)
                #expect(ArchiveFilename(name)?.kind.isTAR == true)
                #expect(ArchiveFilename.removingExtension(from: name) == "Data")
            }
        }
        #expect(ArchiveFilename("写真.TAR.BZ2")?.matchedExtension == "tar.bz2")
        #expect(ArchiveFilename.removingExtension(from: "写真.TAR.BZ2") == "写真")
    }

    @Test func recognitionDoesNotInventAContainerOrStripAnUnrelatedExtension() {
        #expect(ArchiveFilename("Code.zip")?.kind == .zip)
        #expect(ArchiveFilename("Code.jar")?.kind == .jar)
        #expect(ArchiveFilename("Code.tar")?.kind == .tar)
        #expect(ArchiveFilename("Code.jar")?.kind.isTAR == false)
        for name in ["Reader.EPUB", "Reader.cbz", "Reader.WhL"] {
            #expect(ArchiveFilename(name)?.kind == .zipPackage)
            #expect(ArchiveFilename(name)?.kind.isTAR == false)
            #expect(ArchiveFilename.removingExtension(from: name) == "Reader")
        }
        for name in ["", "README", "archive.tar.gz.part", "data.gz", "data.bz2", "data.xz", "data.zst", "zip"] {
            #expect(ArchiveFilename(name) == nil)
            #expect(ArchiveFilename.removingExtension(from: name) == nil)
        }
    }
}
