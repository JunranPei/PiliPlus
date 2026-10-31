"""Verify same-process rearm identity and expiry waits without live ADB."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from startup_home_card import rearm_verified_home_card


class HomeRearmTests(unittest.TestCase):
    def run_rearm(self, *, expire, pid='44', start_us=1_000_000):
        with tempfile.TemporaryDirectory() as directory:
            out=Path(directory)
            (out/'home-preparation').mkdir()
            (out/'home-preparation/selected.json').write_text(json.dumps({'title':'card'}),encoding='utf-8')
            rows=[{'seq':4,'event':'startup.urlPrefetch.begin','cid':42,'utcUs':start_us}]
            calls=[]
            def adb(*args):
                calls.append(args)
                if args[:2]==('shell','cat'): return (json.dumps(rows[0])+'\n').encode()
                if args[:2]==('shell','date'): return b'4000000000\n'
                return b''
            reuse={'traceFiles':['flutter-44-1000000.jsonl','native-44-1000.jsonl']}
            with patch('startup_home_card.time.sleep') as sleep:
                result=rearm_verified_home_card(adb,out,'package',pid,{'cid':42,'bvid':'BV1'},
                                                [540,800],'immediate',reuse=reuse,expire_url=expire)
                report=json.loads((out/'home-rearm.json').read_text(encoding='utf-8'))
            return result,report,calls,sleep.call_args_list

    def test_reuse_needs_no_fresh_logcat_announcement(self):
        result,report,calls,sleeps=self.run_rearm(expire=False)
        self.assertEqual(result,[540,800])
        self.assertEqual(report['minimumDartSequence'],4)
        self.assertEqual(len([c for c in calls if 'swipe' in c]),2)
        self.assertEqual(sleeps,[])

    def test_expiry_uses_original_request_clock_then_real_scroll(self):
        _,report,calls,sleeps=self.run_rearm(expire=True)
        self.assertAlmostEqual(sleeps[0].args[0],7.2)
        self.assertEqual(report['urlExpiryWait']['targetUrlAgeSeconds'],10.2)
        self.assertEqual(calls[-1],('shell','input','touchscreen','swipe','540','1190','540','1250','500'))

    def test_wrong_process_rejected_before_adb(self):
        with self.assertRaises(ValueError): self.run_rearm(expire=False,pid='45')

    def test_bad_clock_rejected_before_scrolling(self):
        with self.assertRaises(RuntimeError): self.run_rearm(expire=True,start_us=100_000_000)


if __name__=='__main__': unittest.main()
