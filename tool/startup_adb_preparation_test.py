import subprocess
import unittest
from capture_startup_listener import force_stop_before_capture


class PreparationRetryTests(unittest.TestCase):
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
