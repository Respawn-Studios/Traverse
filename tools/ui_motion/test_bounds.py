"""Regression for the observed cold media-cache headroom overrun."""
import sys
import unittest
from unittest import mock
import review
sys.path.insert(0,str(review.REPO/'tools/smb_reader'))
from browser_packet import reserve
from packet import TOOLING_LIMIT, MIB,put


class MediaBoundsTests(unittest.TestCase):
    def testColdCompilerCannotStartWithOnlySixtyFourMiBFree(self):
        with mock.patch.object(sys,'argv',['review.py','E7C54FAC-BEFC-43F1-95CE-5372054ECB61']), \
             mock.patch.object(review,'usage',return_value={'bytes':(TOOLING_LIMIT)-64*MIB}), \
             mock.patch.object(review.subprocess,'Popen') as child:
            with self.assertRaisesRegex(RuntimeError,'no child started'):review.main()
            child.assert_not_called()

    def testExactReservedHeadroomIsAdmittedWithoutRaisingTheCap(self):
        review.require_headroom({'bytes':(TOOLING_LIMIT)-96*MIB})
        with self.assertRaises(RuntimeError):review.require_headroom({'bytes':(TOOLING_LIMIT)-96*MIB+1})

    def testNonGeneratedArgumentsAreRejectedBeforeInspectionOrLaunch(self):
        with mock.patch.object(sys,'argv',['review.py','../ordinary']), \
             mock.patch.object(review,'usage') as inspect, mock.patch.object(review.subprocess,'Popen') as child:
            with self.assertRaises((ValueError,RuntimeError)):review.main()
            inspect.assert_not_called();child.assert_not_called()


if __name__=='__main__':
    case=reserve('media-compiler-headroom-guards',amount=16384,entries=8)
    result=unittest.main(exit=False).result
    put(case/'result.json',dict(passed=result.wasSuccessful(),testsRun=result.testsRun,failures=len(result.failures),errors=len(result.errors)))
    raise SystemExit(0 if result.wasSuccessful() else 1)
