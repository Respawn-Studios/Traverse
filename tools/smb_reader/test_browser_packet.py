"""Small preserved controls for the existing bounded evidence allowance."""
import json
import stat
from types import SimpleNamespace
import unittest
import uuid
from unittest import mock
import browser_packet
from packet import TOOLING,native_compiler_lock,directory,put,digest,verify_fixture_link


class NativePacketTests(unittest.TestCase):
    def testGeneratedSymbolicLinkIsCountedWithoutReadingItsBodyAndCannotChange(self):
        facts=SimpleNamespace(st_dev=1,st_ino=2,st_mode=stat.S_IFLNK|0o700,st_nlink=1,st_size=18)
        control=dict(kind='symlink',target='/generated/retained',identity=dict(device=1,inode=2,mode=facts.st_mode,links=1,size=18))
        with mock.patch('packet.os.readlink',return_value='/generated/retained'),mock.patch('packet.digest') as body:
            verify_fixture_link(TOOLING/'generated-link',facts,control);body.assert_not_called()
        with mock.patch('packet.os.readlink',return_value='/different'):
            with self.assertRaises(RuntimeError):verify_fixture_link(TOOLING/'generated-link',facts,control)
        facts.st_ino=3
        with self.assertRaises(RuntimeError):verify_fixture_link(TOOLING/'generated-link',facts,control)

    def testHardLinkControlCannotAcquireAnUnaccountedAliasOrDifferentContent(self):
        facts=SimpleNamespace(st_dev=1,st_ino=2,st_mode=stat.S_IFREG|0o600,st_nlink=2,st_size=18)
        control=dict(kind='hardlink',sha256='expected',identity=dict(device=1,inode=2,mode=facts.st_mode,links=2,size=18))
        with mock.patch('packet.digest',return_value='expected'):verify_fixture_link(TOOLING/'generated-file',facts,control)
        with mock.patch('packet.digest',return_value='different'):
            with self.assertRaises(RuntimeError):verify_fixture_link(TOOLING/'generated-file',facts,control)
        facts.st_nlink=3
        with self.assertRaises(RuntimeError):verify_fixture_link(TOOLING/'generated-file',facts,control)

    def testCompilerLockCannotRedirectDirectoryOrEscapeCache(self):
        root=TOOLING/'swift-module-cache'/'generated'
        self.assertTrue(native_compiler_lock(root/'Foundation-123.pcm.lock','fixture.local-1234'))
        self.assertTrue(native_compiler_lock(root/'dnssd-123.pcm.lock-aAb012','fixture.local-1234'))
        self.assertTrue(native_compiler_lock(root/'CoreGraphics-123.pcm.lock',str(root/'CoreGraphics-123.pcm.lock-aAb012')))
        for path,target in [(TOOLING/'target/foreign.lock','fixture.local-1234'),
            (root/'../..'/'foreign.lock','fixture.local-1234'),
            (root/'foreign.pcm','fixture.local-1234'),(root/'Foundation.pcm.lock','/private/tmp/elsewhere'),
            (root/'Foundation.pcm.lock','../elsewhere'),(root/'Foundation.pcm.lock','..'),
            (root/'Foundation.pcm.lock','x'*256),
            (root/'CoreGraphics-123.pcm.lock',str(root/'Foundation-123.pcm.lock-aAb012')),
            (root/'CoreGraphics-123.pcm.lock',str(root/'../CoreGraphics-123.pcm.lock-aAb012'))]:
            self.assertFalse(native_compiler_lock(path,target))


class BrowserBudgetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.case=browser_packet.reserve('browser-budget-guard-controls',amount=256*1024,entries=128)

    def root(self): return directory(self.case/'source'/str(uuid.uuid4()).upper())

    def item(self,root):
        case=directory(root/str(uuid.uuid4()).upper())
        put(case/'reservation.json',dict(bytes=64*1024,entries=16))
        put(case/'result.json',dict(passed=True,actualExit=0))
        return case

    def seal(self,case):
        put(case/'budget-seal.json',dict(version=1,retainedBytes=32*1024,
            reservationSHA256=digest(case/'reservation.json'),
            files={p.name:digest(p) for p in case.iterdir() if p.is_file()}))

    def audit(self,root):
        with mock.patch.object(browser_packet,'ROOT',root):return browser_packet.audit()

    def testFrozenExitedSuccessChargesOnlyItsRetainedReservation(self):
        root=self.root();case=self.item(root);self.seal(case)
        self.assertEqual(self.audit(root)['reservedBytes'],32*1024)
        (case/'result.json').write_text('{"passed":true,"actualExit":0}')
        with self.assertRaises(RuntimeError):self.audit(root)

    def testLiveOrFailedCasesCannotReleaseTheirReservation(self):
        for result in [dict(passed=False,actualExit=0),dict(passed=True,actualExit=None),dict(passed=True,actualExit=0,reviewLeftOpen=True)]:
            root=self.root();case=self.item(root);(case/'result.json').write_text(json.dumps(result));self.seal(case)
            with self.assertRaises(RuntimeError):self.audit(root)

    def testUnlistedEvidenceCannotBeAddedToFrozenSuccess(self):
        root=self.root();case=self.item(root);self.seal(case);(case/'extra.json').write_text('{}')
        with self.assertRaises(RuntimeError):self.audit(root)

    def testExplicitSupplementIsChargedWithoutRewritingTheOriginal(self):
        root=self.root();case=self.item(root);original=(case/'reservation.json').read_bytes()
        put(case/'reservation-supplement.json',dict(version=1,bytes=64*1024,reservationSHA256=digest(case/'reservation.json')))
        self.assertEqual(self.audit(root)['reservedBytes'],128*1024)
        self.assertEqual((case/'reservation.json').read_bytes(),original)
        (case/'reservation-supplement.json').write_text('{"version":1,"bytes":-1}')
        with self.assertRaises(RuntimeError):self.audit(root)

    def testUnsafeLinkControlReceiptCannotAuthorizeEscapingPathsOrOtherPackets(self):
        for action,path in [('saved-server-store-debug','source/../retained.json'),('unrelated','source/invalid/file')]:
            root=self.root();case=self.item(root)
            (case/'reservation.json').write_text(json.dumps(dict(bytes=64*1024,entries=16,action=action)))
            put(case/'fixture-links.json',dict(version=1,guardChecksPassed=True,entries=[dict(path=path,kind='symlink')]))
            with self.assertRaises((RuntimeError,ValueError)):self.audit(root)


if __name__=='__main__':
    result=unittest.main(exit=False).result
    if hasattr(BrowserBudgetTests,'case'):
        put(BrowserBudgetTests.case/'result.json',dict(passed=result.wasSuccessful(),testsRun=result.testsRun,
            failures=len(result.failures),errors=len(result.errors)))
    raise SystemExit(0 if result.wasSuccessful() else 1)
