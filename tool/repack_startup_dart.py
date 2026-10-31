"""Compile a Dart-only startup experiment and preserve the verified Android payload."""
import argparse
import base64
import hashlib
import json
import subprocess
import time
import zipfile
from pathlib import Path
from urllib.parse import urljoin, urlsplit
from urllib.request import url2pathname

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--base', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--define', action='append', default=[])
parser.add_argument('--allow-source', action='append', default=[])
args = parser.parse_args()
old, target = args.base.resolve(), args.output.resolve()
work = target.with_suffix('.dart-build')
assert not target.exists() and not work.exists()
work.mkdir(parents=True)
sha = lambda b: hashlib.sha256(b).hexdigest()
meta = json.loads(old.with_suffix('.build.json').read_text())
assert sha(old.read_bytes()) == meta['sha256']
assert meta['buildMode'] == 'release' and meta['targetPlatform'] == 'android-x64'
config = ROOT/'.dart_tool/package_config.json'
assert sha(config.read_bytes()) == meta['packageConfigSha256']
changes = []
for name, previous in meta['diagnosticSourcesSha256'].items():
    if not name.startswith(('lib/', 'android/')):
        continue
    current = sha((ROOT/name).read_bytes())
    if current != previous:
        assert name in args.allow_source, name
        changes.append({'path':name,'before':previous,'after':current})
for name in args.allow_source:
    if name in meta['diagnosticSourcesSha256']:
        continue
    source = ROOT/name
    assert name.startswith('lib/') and source.is_file(), name
    assert source.resolve().is_relative_to((ROOT/'lib').resolve()), name
    changes.append({'path':name,'before':None,'after':sha(source.read_bytes())})
flags = list(meta['defines'])
for value in args.define:
    key, setting = value.split('=', 1)
    assert key and setting and key.replace('_', '').isalnum()
    flags = [v for v in flags if not v.startswith(key+'=')] + [value]
packages = json.loads(config.read_text())['packages']
package = next(p for p in packages if p['name']=='media_kit_video')
package_root = Path(url2pathname(urlsplit(urljoin(config.as_uri(),package['rootUri'])).path))
dependency = package_root/'lib/src/video_controller/android_video_controller/real.dart'
original = dependency.read_bytes()
assert not subprocess.check_output(['git','status','--porcelain'],cwd=package_root.parent).strip()
staged = (ROOT/'tool/startup_gpu_standby/android_video_controller.dart').read_bytes()
assert sha(staged) == meta['dependencySourceSha256']
bundle = work/'flutter'
command = [str(ROOT/'tmp/flutter-sdk-3.47.6/flutter/bin/flutter.bat'),'--quiet','assemble','--no-version-check',
    '--output',str(bundle),'--depfile',str(work/'flutter_build.d'),'-dTargetFile=lib/main.dart',
    '-dTargetPlatform=android','-dBuildMode=release','-dTrackWidgetCreation=true',
    '--DartDefines='+','.join(base64.b64encode(v.encode()).decode()for v in flags),
    '-dAndroidArchs=android-x64','-dMinSdkVersion=24','android_aot_bundle_release_android-x64']
(work/'command.json').write_text(json.dumps(command,indent=2))
began=time.monotonic()
try:
    dependency.write_bytes(staged)
    with(work/'compile.log').open('xb')as log:
        result=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
    result.check_returncode()
finally:
    dependency.write_bytes(original)
    assert sha(dependency.read_bytes())==sha(original)
elapsed=time.monotonic()-began
lib=bundle/'x86_64/app.so'
assert lib.exists(), list(bundle.rglob('*.so'))
entry='lib/x86_64/libapp.so'
signature=lambda n: n=='META-INF/MANIFEST.MF' or (n.startswith('META-INF/')and n.endswith(('.SF','.RSA','.DSA','.EC')))
with zipfile.ZipFile(old)as src:
    assets={n for n in src.namelist() if n.startswith('assets/flutter_assets/') and not n.endswith('/')}
    fresh={f'assets/flutter_assets/{p.relative_to(bundle/"flutter_assets").as_posix()}'for p in(bundle/'flutter_assets').rglob('*')if p.is_file()}
    assert assets==fresh, {'added':sorted(fresh-assets),'missing':sorted(assets-fresh)}
    assert all(sha(src.read(n))==sha((bundle/n.removeprefix('assets/')).read_bytes())for n in assets),'Flutter asset change requires an explicit full build'
    with zipfile.ZipFile(work/'unsigned.apk','x')as dst:
        for info in src.infolist():
            if not signature(info.filename):dst.writestr(info,lib.read_bytes()if info.filename==entry else src.read(info))
sdk=Path('D:/Android_studio_sdk/build-tools/36.0.0')
signer=['D:/Program Files/Eclipse Adoptium/jdk-21.0.7.6-hotspot/bin/java.exe','-jar',str(sdk/'lib/apksigner.jar')]
def run(command,name):
    r=subprocess.run(command,capture_output=True,timeout=120)
    (work/name).write_bytes(r.stdout+r.stderr);r.check_returncode();return r.stdout.decode(errors='replace')
import re
prior=run(signer+['verify','--print-certs',str(old)],'prior-signature.txt')
run([str(sdk/'zipalign.exe'),'-f','-P','16','4',str(work/'unsigned.apk'),str(work/'aligned.apk')],'align.txt')
run(signer+['sign','--ks','C:/Users/10540/.android/debug.keystore','--ks-key-alias','androiddebugkey',
    '--ks-pass','pass:android','--key-pass','pass:android','--out',str(target),str(work/'aligned.apk')],'sign.txt')
signed=run(signer+['verify','--verbose','--print-certs',str(target)],'signature.txt')
pattern=r'Signer #1 certificate SHA-256 digest: (\w+)'
assert re.search(pattern,prior).group(1)==re.search(pattern,signed).group(1)
run([str(sdk/'zipalign.exe'),'-c','-P','16','4',str(target)],'alignment.txt')
with zipfile.ZipFile(old)as a,zipfile.ZipFile(target)as b:
    names={n for n in a.namelist()if not signature(n)}
    assert names=={n for n in b.namelist()if not signature(n)}
    differences=[n for n in names if sha(a.read(n))!=sha(b.read(n))]
    assert differences==[entry],differences
    assert sha(b.read('lib/x86_64/libmpv.so'))==meta['nativeLibraryOverride']['librarySha256']
changed={c['path']for c in changes}
with zipfile.ZipFile(old.with_suffix('.sources.zip'))as a,zipfile.ZipFile(target.with_suffix('.sources.zip'),'x',zipfile.ZIP_DEFLATED)as b:
    for info in a.infolist():b.writestr(info,(ROOT/info.filename).read_bytes()if info.filename in changed else a.read(info))
    for name in sorted(changed - set(a.namelist())):
        b.writestr(name,(ROOT/name).read_bytes())
    ordinal = 1
    provenance = 'dart-refresh-provenance.json'
    while provenance in a.namelist():
        ordinal += 1
        provenance = f'dart-refresh-provenance-{ordinal:03}.json'
    b.writestr(provenance,json.dumps({'base':str(old),'baseSha256':meta['sha256'],'changes':changes,'defines':flags},indent=2))
for c in changes:meta['diagnosticSourcesSha256'][c['path']]=c['after']
meta.update(apk=str(target),sha256=sha(target.read_bytes()),defines=flags,dartOnlyRefresh={
    'baseApk':str(old),'compileSeconds':elapsed,'sourceChanges':changes,'payloadDifferences':differences,
    'assetsIdentical':True,'sameCertificate':True,'sameNativeAndEngine':True,'alignment16KiB':True})
target.with_suffix('.build.json').write_text(json.dumps(meta,indent=2))
print(json.dumps({'apk':str(target),'sha256':meta['sha256'],'compileSeconds':elapsed,'payloadDifferences':differences}),flush=True)
