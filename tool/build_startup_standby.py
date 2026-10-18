"""Build the committed standby checkpoint and restore the dependency cache afterward."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from urllib.parse import urljoin, urlsplit
from urllib.request import url2pathname

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--control', action='store_true', help='Same source, with startup standby disabled')
args = parser.parse_args()
output = args.output.resolve()
if output.exists():
    raise SystemExit(f'Refusing to overwrite an existing APK: {output}')
config = ROOT/'.dart_tool/package_config.json'
packages = json.loads(config.read_text(encoding='utf-8'))['packages']
package = next(p for p in packages if p['name']=='media_kit_video')
package_uri = urljoin(config.as_uri(), package['rootUri'])
package_root = Path(url2pathname(urlsplit(package_uri).path))
dependency = package_root/'lib/src/video_controller/android_video_controller/real.dart'
original = dependency.read_bytes()
dependency_tree = package_root.parent
if subprocess.check_output(['git','status','--porcelain'],cwd=dependency_tree).strip():
    raise SystemExit('Dependency checkout has local changes; preserve them before building.')
revision = subprocess.check_output(['git','rev-parse','HEAD'],cwd=dependency_tree,text=True).strip()
if revision!='fd8421d21eade4d6d12de137fa7df902fec20292':
    raise SystemExit(f'Unexpected media_kit_video revision: {revision}')
guard = subprocess.run(['powershell','-NoProfile','-File',
    str(ROOT/'diagnostics/startup-20261018/rollback-baseline/memory-gate.ps1'),'-Kind','build'],cwd=ROOT)
if guard.returncode: raise SystemExit(guard.returncode)
output.parent.mkdir(parents=True,exist_ok=True)
try:
    dependency.write_bytes((ROOT/'tool/startup_gpu_standby/android_video_controller.dart').read_bytes())
    flags = ['PLAYBACK_TRACE=true','PLAYBACK_STARTUP_VERBOSE=true','STARTUP_TIMING=true',f'PLAYER_STANDBY={str(not args.control).lower()}']
    defines = ','.join(base64.b64encode(f.encode()).decode() for f in flags)
    command = [str(ROOT/'android/gradlew.bat'),'-p','android','assembleRelease',
        '-Ptarget-platform=android-x64','-Ptarget=lib/main.dart',f'-Pdart-defines={defines}',
        '-Dorg.gradle.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=768m -Dfile.encoding=UTF-8',
        '--max-workers=1','--console=plain']
    env=dict(os.environ)
    env['JAVA_HOME']='D:/Program Files/Eclipse Adoptium/jdk-21.0.7.6-hotspot'
    env['PATH']=env['JAVA_HOME']+'/bin;'+env['PATH']
    with output.with_suffix('.build.log').open('w',encoding='utf-8') as log:
        result=subprocess.run(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
    if result.returncode: raise SystemExit(result.returncode)
    shutil.copy2(ROOT/'build/app/outputs/apk/release/app-release.apk',output)
    manifest={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        'apk':str(output),'sha256':hashlib.file_digest(output.open('rb'),'sha256').hexdigest(),
        'defines':flags,'dependencyRevision':revision,
        'dependencySourceSha256':hashlib.sha256(dependency.read_bytes()).hexdigest(),
        'standbyEnabled':not args.control,'mediaPreload':False,'acceptedPerformanceFix':False}
    output.with_suffix('.build.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print(json.dumps(manifest),flush=True)
finally:
    dependency.write_bytes(original)
