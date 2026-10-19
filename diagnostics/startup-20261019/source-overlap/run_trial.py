"""One installed-hash-verified cold-App trial; no pre-click media opened."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
p = argparse.ArgumentParser()
p.add_argument('mode', choices=['control','candidate'])
p.add_argument('label')
p.add_argument('--index', type=int, default=5)
a = p.parse_args()
apk = OUT/f'source-overlap-{a.mode}.apk'
m = json.loads(apk.with_suffix('.build.json').read_text(encoding='utf8'))
assert m['standbyEnabled'] and 'PLAYBACK_STARTUP_DEEP=true' not in m['defines']
assert m['sourcePreparationOverlapsPresentation'] == (a.mode=='candidate')
assert hashlib.file_digest(apk.open('rb'),'sha256').hexdigest() == m['sha256']
adb = ['adb','-s','emulator-5556']
def run(*args):return subprocess.check_output(adb+list(args), timeout=60)
assert run('shell','getprop','sys.boot_completed').strip()==b'1'
run('shell','am','force-stop','com.personal.piliplus')
run('install','-r','-d',str(apk))
remote = run('shell','pm','path','com.personal.piliplus').decode().strip().removeprefix('package:')
assert run('shell','sha256sum',remote).decode().split()[0]==m['sha256']
base = ROOT/'diagnostics/startup-20261018/rollback-baseline'
label = f'source-overlap-{a.label}-20261019'
subprocess.run([sys.executable,str(base/'capture_timing.py'),label,
    '--serial','emulator-5556','--index',str(a.index),'--cold-app','--keep-player','--collect-standby'],cwd=ROOT,check=True)
meta=base/f'{label}-{a.index}-capture.json'
(OUT/meta.name).write_bytes(meta.read_bytes())
