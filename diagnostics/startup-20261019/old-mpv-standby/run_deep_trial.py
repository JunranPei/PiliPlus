"""Install the bounded diagnostic control and record one ordinary URI click."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
p = argparse.ArgumentParser()
p.add_argument('label', choices=['d1', 'd2'])
args = p.parse_args()
apk = OUT / 'old-mpv-deep-control.apk'
manifest = json.loads(apk.with_suffix('.build.json').read_text(encoding='utf8'))
assert not manifest['standbyEnabled']
assert 'PLAYBACK_STARTUP_DEEP=true' in manifest['defines']
assert manifest['sha256'] == hashlib.file_digest(apk.open('rb'), 'sha256').hexdigest()
adb = ['adb', '-s', 'emulator-5556']
def run(*a):
    return subprocess.check_output(adb+list(a), timeout=60)
assert run('shell', 'getprop', 'sys.boot_completed').strip() == b'1'
run('shell', 'am', 'force-stop', 'com.personal.piliplus')
run('install', '-r', '-d', str(apk))
remote = run('shell', 'pm', 'path', 'com.personal.piliplus').decode().strip().removeprefix('package:')
assert run('shell', 'sha256sum', remote).decode().split()[0] == manifest['sha256']
label = f'old-mpv-deep-{args.label}-20261019'
base = ROOT / 'diagnostics/startup-20261018/rollback-baseline'
subprocess.run([sys.executable, str(base/'capture_timing.py'), label,
    '--serial', 'emulator-5556', '--index', '5', '--cold-app',
    '--keep-player', '--collect-standby'], cwd=ROOT, check=True)
meta = base / f'{label}-5-capture.json'
(OUT/meta.name).write_bytes(meta.read_bytes())
