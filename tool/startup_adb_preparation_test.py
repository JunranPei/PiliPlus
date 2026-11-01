import subprocess
import json
from pathlib import Path
import tempfile
import unittest
from capture_startup_listener import dump_pre_input_ui, force_stop_before_capture


class PreparationRetryTests(unittest.TestCase):
    def test_ui_dump_empty_255_retries_only_read_and_preserves_failure(self):
        calls=[];sleeps=[]
        def adb(*args):
            calls.append(args)
            if len(calls)==1:
                raise subprocess.CalledProcessError(255,args,output=b'',stderr=b'')
            return b'UI hierarchy dumped'
        with tempfile.TemporaryDirectory() as folder:
            out=Path(folder)
            self.assertEqual(dump_pre_input_ui(adb,'/sdcard/fixture.xml',out,sleep=sleeps.append),b'UI hierarchy dumped')
            records=[json.loads(l)for l in(out/'pre-input-ui-dump-attempts.jsonl').read_text().splitlines()]
        self.assertEqual([r['exit']for r in records],[255,0])
        self.assertEqual(calls,[('shell','uiautomator','dump','/sdcard/fixture.xml')]*2)
        self.assertEqual(sleeps,[.25])

    def test_ui_dump_permission_error_is_not_retried(self):
        def adb(*args):raise subprocess.CalledProcessError(255,args,stderr=b'Permission Denial')
        with tempfile.TemporaryDirectory() as folder,self.assertRaises(subprocess.CalledProcessError):
            dump_pre_input_ui(adb,'/sdcard/fixture.xml',Path(folder),sleep=lambda _:self.fail('Unexpected retry'))

    def test_ui_dump_persistent_timeout_is_bounded_and_retained(self):
        calls=[];sleeps=[]
        def adb(*args):
            calls.append(args)
            raise subprocess.TimeoutExpired(args,45)
        with tempfile.TemporaryDirectory() as folder:
            out=Path(folder)
            with self.assertRaises(subprocess.TimeoutExpired):
                dump_pre_input_ui(adb,'/sdcard/fixture.xml',out,sleep=sleeps.append)
            self.assertEqual(len((out/'pre-input-ui-dump-attempts.jsonl').read_text().splitlines()),3)
        self.assertEqual(len(calls),3)
        self.assertEqual(sleeps,[.25,.25])

    def timeout_fixture(self, stopped=True, live=False, verification_timeout=False):
        def adb(*args):
            if args[1:3] == ('am', 'force-stop'):
                raise subprocess.TimeoutExpired(args, 20)
            if verification_timeout:
                raise subprocess.TimeoutExpired(args, 10)
            if args == ('shell', 'am', 'get-current-user'):
                return b'0\n'
            if args[1:3] == ('dumpsys', 'package'):
                return ('  User 0: installed=true stopped=' + str(stopped).lower() + '\n').encode()
            if args[1] == 'ps':
                return b'NAME\nsystem_server\n' + (b'fixture.app:playback\n' if live else b'')
            self.fail(str(args))
        return adb

    def test_timeout_accepts_only_verified_stop_and_no_package_process(self):
        result = force_stop_before_capture(self.timeout_fixture(), 'fixture.app')
        self.assertTrue(result['commandTimedOut'] and result['verifiedStopped'])
        self.assertEqual(result['packageProcessCount'], 0)

    def test_timeout_does_not_accept_just_absent_pid(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            force_stop_before_capture(self.timeout_fixture(stopped=False), 'fixture.app')

    def test_timeout_does_not_accept_remaining_secondary_process(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            force_stop_before_capture(self.timeout_fixture(live=True), 'fixture.app')

    def test_timeout_does_not_accept_missing_observations(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            force_stop_before_capture(self.timeout_fixture(verification_timeout=True), 'fixture.app')

    def test_recorded_handshake_failure_can_recover_before_launch(self):
        calls=[];sleeps=[]
        def adb(*args):
            calls.append(args)
            if len(calls)==1:
                raise subprocess.CalledProcessError(1,args,stderr=b'could not read ok from ADB Server\n* failed to start daemon\nadb.exe: cannot connect to daemon')
        force_stop_before_capture(adb,'fixture.app',sleep=sleeps.append)
        self.assertEqual(calls,[('shell','am','force-stop','fixture.app')]*2)
        self.assertEqual(sleeps,[1])

    def test_android_permission_error_is_not_retried(self):
        calls=[]
        def adb(*args):
            calls.append(args)
            raise subprocess.CalledProcessError(1,args,stderr=b'Permission Denial: forceStopPackage')
        with self.assertRaises(subprocess.CalledProcessError):
            force_stop_before_capture(adb,'fixture.app',sleep=lambda _: self.fail('unexpected retry'))
        self.assertEqual(len(calls),1)

    def test_persistent_transport_failure_is_bounded(self):
        calls=[];sleeps=[]
        def adb(*args):
            calls.append(args)
            raise subprocess.CalledProcessError(1,args,stderr=b'adb.exe: cannot connect to daemon')
        with self.assertRaises(subprocess.CalledProcessError):
            force_stop_before_capture(adb,'fixture.app',sleep=sleeps.append)
        self.assertEqual(len(calls),3)
        self.assertEqual(sleeps,[1,1])


if __name__=='__main__':unittest.main()
