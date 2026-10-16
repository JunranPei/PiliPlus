"""Short cold-process comparison of the first-frame callback scheduling delay."""
from pathlib import Path
import argparse
import json
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('label')
parser.add_argument('--runs', type=int, default=3)
parser.add_argument('--index', type=int, default=5)
args = parser.parse_args()
video = json.loads((ROOT / 'diagnostics/startup-20261016/videos.json').read_text(encoding='utf-8'))[args.index]
OUT = ROOT / 'diagnostics/startup-20261016/callback-compare' / args.label
OUT.mkdir(parents=True, exist_ok=True)
ADB = ['adb', '-s', 'emulator-5554']
def adb(*args):
    return subprocess.run(ADB + list(args), capture_output=True, check=True).stdout
results = []
for number in range(1, args.runs+1):
    adb('shell', 'am', 'force-stop', 'com.personal.piliplus')
    adb('logcat', '-c')
    adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW',
        '-n', 'com.personal.piliplus/com.personal.piliplus.MainActivity',
        '-d', f'bilibili://video/{video["bvid"]}?cid={video["cid"]}')
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        log = adb('logcat', '-d', '-v', 'epoch', '-s', 'Media3Startup', 'Media3Playback').decode('utf-8', 'replace')
        if 'phase=firstFrame' in log:
            break
        time.sleep(.2)
    (OUT / f'{number}.log').write_text(log, encoding='utf-8')
    phases = {}
    for line in log.splitlines():
        match = re.search(r'tMs=(\d+) phase=(\S+)\s*(.*)', line)
        if match and match[2] not in phases:
            phases[match[2]] = {'ms': int(match[1]), 'detail': match[3]}
    result = {'run': number, 'label': args.label, 'video': video, 'phases': phases,
        'boundary': 'Same video with retained disk cache, cold process each run; callback timestamps are not pixel timing'}
    results.append(result)
    print(json.dumps({k:v for k,v in phases.items() if k in ['video.firstOutput','main.afterVideoOutput','firstFrame','video.surfaceRendered']}), flush=True)
    (OUT / 'results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
