"""Build the preserved r116 release profile, with the current PiP fixes."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.parse import urljoin, urlsplit
from urllib.request import url2pathname
import zipfile

from startup_native_library import NativeLibraryOverride

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--target-platform', choices=['android-arm64', 'android-x64'], default='android-arm64')
    parser.add_argument('--benchmark', action='store_true')
    parser.add_argument('--seek-diagnostics', action='store_true')
    parser.add_argument('--target', default='lib/main.dart')
    args = parser.parse_args()
    output = args.output.resolve()
    work = output.with_suffix('.build')
    if output.exists() or work.exists():
        raise FileExistsError('Use a fresh output path; existing artifacts are preserved')
    work.mkdir(parents=True)
    profile_path = ROOT / 'tool/release_profile.json'
    profile = json.loads(profile_path.read_bytes())
    flags = dict(profile['defines'])
    if args.benchmark or args.seek_diagnostics:
        from startup_minimum_profile import DEFINES
        flags.update(DEFINES)
    if args.seek_diagnostics:
        flags['SEEK_RUNTIME_TRACE'] = 'true'
    artifact = profile['native'][args.target_platform]
    source = ROOT / artifact['artifact']
    assert digest(source.read_bytes()) == artifact['artifactSha256']
    with zipfile.ZipFile(source) as archive:
        library = archive.read(artifact['entry'])
    assert digest(library) == artifact['sha256']
    native = work / 'libmpv.so'
    native.write_bytes(library)
    config = ROOT / '.dart_tool/package_config.json'
    packages = json.loads(config.read_bytes())['packages']

    def package_root(name):
        p = next(p for p in packages if p['name'] == name)
        return Path(url2pathname(urlsplit(urljoin(config.as_uri(), p['rootUri'])).path))

    dependency = package_root('media_kit_video') / 'lib/src/video_controller/android_video_controller/real.dart'
    original = dependency.read_bytes()
    staged = (ROOT / profile['dependencySource']).read_bytes()
    assert digest(staged) == profile['dependencySourceSha256']
    (work / 'dependency-original.dart').write_bytes(original)
    override = NativeLibraryOverride(
        package_root('media_kit_libs_android_video') / 'android/build.gradle',
        ROOT / 'build/media_kit_libs_android_video', native, work / 'native.jar', args.target_platform)
    version = next(line.split(':', 1)[1].strip() for line in (ROOT / 'pubspec.yaml').read_text().splitlines() if line.startswith('version:'))
    name, code = version.split('+')
    flags.update({'pili.name': name, 'pili.code': code})
    encoded = ','.join(base64.b64encode((key + '=' + value).encode()).decode()
                       for key, value in flags.items())
    command = [str(ROOT / 'android/gradlew.bat'), '-p', 'android', 'assembleRelease',
               '-Ptarget-platform=' + args.target_platform, '-Ptarget=' + args.target,
               '-Pdart-defines=' + encoded, '--max-workers=1', '--no-daemon',
               '-Dorg.gradle.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=768m -Dfile.encoding=UTF-8',
               '-Pkotlin.compiler.execution.strategy=in-process', '--console=plain']
    (work / 'command.json').write_text(json.dumps(command, indent=2))
    try:
        override.apply()
        dependency.write_bytes(staged)
        with (work / 'build.log').open('w', encoding='utf-8') as log:
            subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        built = ROOT / 'build/app/outputs/apk/release/app-release.apk'
        override.verify_apk(built)
        shutil.copy2(built, output)
    finally:
        override.restore()
        if dependency.read_bytes() != staged:
            raise RuntimeError('Dependency changed concurrently; original backup retained')
        dependency.write_bytes(original)
    sources = [p for base in ['lib', 'android/app/src/main'] for p in (ROOT / base).rglob('*') if p.is_file()]
    hashes = {p.relative_to(ROOT).as_posix(): digest(p.read_bytes()) for p in sources}
    manifest = {'apk': str(output), 'sha256': digest(output.read_bytes()), 'version': version,
                'profile': profile['name'], 'profileSha256': digest(profile_path.read_bytes()),
                'buildMode': 'release', 'targetPlatform': args.target_platform,
                'defines': [key + '=' + value for key, value in flags.items()],
                'nativeLibraryOverride': override.manifest, 'diagnosticSourcesSha256': hashes,
                'packageConfigSha256': digest(config.read_bytes()),
                'dependencySourceSha256': digest(staged), 'mediaPreload': True,
                'visibleUrlPrefetch': True, 'frameTrace': False, 'continuityTrace': args.benchmark or args.seek_diagnostics,
                'diagnosticCollectionEnabled': args.benchmark or args.seek_diagnostics,
                'seekDiagnostics': args.seek_diagnostics, 'dependencyRestored': True}
    output.with_suffix('.build.json').write_text(json.dumps(manifest, indent=2))
    with zipfile.ZipFile(output.with_suffix('.sources.zip'), 'x', zipfile.ZIP_DEFLATED) as archive:
        for p in sources + [profile_path, ROOT / 'pubspec.yaml']:
            archive.write(p, p.relative_to(ROOT).as_posix())
    print(json.dumps({'apk': str(output), 'sha256': manifest['sha256'], 'nativeSha256': artifact['sha256']}), flush=True)


if __name__ == '__main__':
    main()
