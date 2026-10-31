import hashlib
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

from startup_native_library import NativeLibraryOverride


class NativeLibraryOverrideTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.gradle = self.root / 'build.gradle'
        self.original = self.root / 'default-x86_64.jar'
        self.native = self.root / 'libmpv.so'
        self.staged = self.root / 'staged.jar'
        payload = bytearray(64)
        payload[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<H', payload, 18, 62)
        self.native.write_bytes(payload)
        with zipfile.ZipFile(self.original, 'x') as z:
            z.writestr('lib/x86_64/libmpv.so', b'original-mpv')
            z.writestr('lib/x86_64/libmediakitandroidhelper.so', b'unchanged-helper')
            z.writestr('lib/x86_64/libmedia_kit_native_event_loop.so', b'unchanged-loop')
        sha = hashlib.sha256(self.original.read_bytes()).hexdigest()
        self.gradle.write_text('["url": "https://example.invalid/default-x86_64.jar", '
            f'"sha256": "{sha}", "destination": file("$buildDir/default-x86_64.jar")]')
        self.gradle_bytes = self.gradle.read_bytes()
        self.jar_bytes = self.original.read_bytes()

    def stage(self):
        return NativeLibraryOverride(self.gradle, self.root, self.native, self.staged, 'android-x64')

    def test_only_mpv_changes_and_gradle_restores_after_failure(self):
        staged = self.stage()
        self.assertEqual(Path(staged.manifest['originalGradleBackup']).read_bytes(), self.gradle_bytes)
        try:
            staged.apply()
            raise RuntimeError('simulated failed build')
        except RuntimeError:
            pass
        finally:
            staged.restore()
        self.assertEqual(self.gradle.read_bytes(), self.gradle_bytes)
        self.assertEqual(self.original.read_bytes(), self.jar_bytes)
        with zipfile.ZipFile(self.original) as old, zipfile.ZipFile(self.staged) as new:
            self.assertEqual(old.namelist(), new.namelist())
            for name in old.namelist():
                expected = self.native.read_bytes() if name.endswith('/libmpv.so') else old.read(name)
                self.assertEqual(new.read(name), expected)
        staged.verify_apk(self.staged)
        with self.assertRaises(RuntimeError):
            staged.verify_apk(self.original)

    def test_wrong_architecture_is_rejected_without_writing(self):
        with self.assertRaises(ValueError):
            NativeLibraryOverride(self.gradle, self.root, self.native, self.staged, 'android-arm64')
        self.assertFalse(self.staged.exists())
        self.assertEqual(self.gradle.read_bytes(), self.gradle_bytes)

    def test_tampered_original_archive_is_rejected(self):
        self.original.write_bytes(self.jar_bytes + b'tamper')
        with self.assertRaises(ValueError):
            self.stage()
        self.assertFalse(self.staged.exists())

    def test_concurrent_gradle_edit_is_preserved(self):
        staged = self.stage()
        self.gradle.write_bytes(b'concurrent edit')
        with self.assertRaises(RuntimeError):
            staged.apply()
        staged.restore()
        self.assertEqual(self.gradle.read_bytes(), b'concurrent edit')

    def test_concurrent_edit_during_build_is_preserved(self):
        staged = self.stage()
        staged.apply()
        self.gradle.write_bytes(b'concurrent edit')
        with self.assertRaises(RuntimeError):
            staged.restore()
        self.assertEqual(self.gradle.read_bytes(), b'concurrent edit')


if __name__ == '__main__':
    unittest.main()
