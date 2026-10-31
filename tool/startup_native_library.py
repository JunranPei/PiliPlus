"""Stage a single ABI libmpv experiment without replacing official cached JARs."""
import hashlib
from pathlib import Path
import re
import struct
import zipfile


ABIS = {'android-x64': ('x86_64', 2, 62),
        'android-arm64': ('arm64-v8a', 2, 183),
        'android-arm': ('armeabi-v7a', 1, 40)}


def digest(data):
    return hashlib.sha256(data).hexdigest()


class NativeLibraryOverride:
    def __init__(self, gradle, cache_root, library, staged_jar, platform):
        self.gradle = Path(gradle)
        self.original = self.gradle.read_bytes()
        self.applied = False
        self.abi, elf_class, machine = ABIS[platform]
        self.entry = f'lib/{self.abi}/libmpv.so'
        library = Path(library).resolve()
        native_bytes = library.read_bytes()
        if (len(native_bytes) < 64 or native_bytes[:4] != b'\x7fELF'
                or native_bytes[4:6] != bytes([elf_class, 1])
                or struct.unpack_from('<H', native_bytes, 18)[0] != machine):
            raise ValueError('Native libmpv ELF architecture does not match target platform')
        text = self.original.decode('utf-8')
        pattern = (r'\["url": "[^"\n]+/default-' + re.escape(self.abi)
            + r'\.jar", "sha256": "(?P<hash>[0-9a-f]{64})", '
            + r'"destination": file\("\$buildDir/(?P<cache>[^"\n]+)"\)\]')
        matches = list(re.finditer(pattern, text))
        if len(matches) != 1:
            raise ValueError('Expected exactly one native dependency archive definition')
        match = matches[0]
        cache_root = Path(cache_root).resolve()
        original_jar = (cache_root / match['cache']).resolve()
        if not original_jar.is_relative_to(cache_root):
            raise ValueError('Native cache archive escapes its build directory')
        original_bytes = original_jar.read_bytes()
        if digest(original_bytes) != match['hash']:
            raise ValueError('Official cached native archive hash does not match dependency definition')
        staged_jar = Path(staged_jar).resolve()
        if staged_jar.exists():
            raise FileExistsError(staged_jar)
        with zipfile.ZipFile(original_jar) as source:
            if source.namelist().count(self.entry) != 1:
                raise ValueError('Expected exactly one libmpv entry in official native archive')
            with zipfile.ZipFile(staged_jar, 'x') as target:
                for item in source.infolist():
                    target.writestr(item, native_bytes if item.filename == self.entry else source.read(item))
        staged_hash = digest(staged_jar.read_bytes())
        replacement = (f'["url": "{staged_jar.as_uri()}", "sha256": "{staged_hash}", '
            f'"destination": file("$buildDir/startup-native-{staged_hash[:16]}/default-{self.abi}.jar")]')
        self.patched = (text[:match.start()] + replacement + text[match.end():]).encode('utf-8')
        backup = staged_jar.with_suffix('.gradle.original')
        with backup.open('xb') as file:
            file.write(self.original)
        self.manifest = {'abi': self.abi, 'library': str(library), 'librarySha256': digest(native_bytes),
            'officialJar': str(original_jar), 'officialJarSha256': digest(original_bytes),
            'stagedJar': str(staged_jar), 'stagedJarSha256': staged_hash,
            'originalGradleBackup': str(backup), 'originalGradleSha256': digest(self.original),
            'patchedGradleSha256': digest(self.patched)}

    def apply(self):
        if self.gradle.read_bytes() != self.original:
            raise RuntimeError('Native dependency changed after staging; refusing to overwrite it')
        self.gradle.write_bytes(self.patched)
        self.applied = True

    def restore(self):
        if not self.applied:
            return
        if self.gradle.read_bytes() != self.patched:
            raise RuntimeError('Native dependency changed during build; refusing to overwrite concurrent edits')
        self.gradle.write_bytes(self.original)
        self.applied = False

    def verify_apk(self, apk):
        with zipfile.ZipFile(apk) as archive:
            actual = digest(archive.read(self.entry))
        if actual != self.manifest['librarySha256']:
            raise RuntimeError('Built APK does not contain the requested native library bytes')
        self.manifest['apkLibrarySha256'] = actual
