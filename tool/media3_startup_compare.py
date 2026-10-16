"""Compare new-content startup and immediate same-content reopen by phase.

This is a controlled diagnostic, not a ten-video acceptance run. It never
clears app data/cache, and does not equate first-frame callbacks with pixels.
"""
from pathlib import Path
import argparse
import json
import shlex
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--first-index', type=int, default=9)
parser.add_argument('--next-index', type=int, default=8)
parser.add_argument('--output', default='diagnostics/startup-20261016/startup-phases')
args = parser.parse_args()
OUT = ROOT / args.output
OUT.mkdir(parents=True, exist_ok=True)
ADB = ['adb', '-s', 'emulator-5554']
PACKAGE = 'com.personal.piliplus'

def adb(*args):
    return subprocess.run(ADB + list(args), capture_output=True, check=True).stdout

def logs():
    return adb('logcat', '-d', '-v', 'epoch', '-s', 'Media3Startup', 'Media3Playback', 'AndroidRuntime').decode('utf-8', 'replace')

videos = json.loads((ROOT / 'diagnostics/startup-20261016/videos.json').read_text(encoding='utf-8'))
for label, video in [('new-content', videos[args.first_index]), ('same-content-reopen', videos[args.first_index]), ('other-new-content', videos[args.next_index])]:
    adb('shell', 'input', 'keyevent', '4')
    time.sleep(.7)
    adb('logcat', '-c')
    uri = f'bilibili://video/{video["bvid"]}?cid={video["cid"]}&start_progress=0'
    begin = time.monotonic()
    adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW',
        '-n', PACKAGE + '/com.personal.piliplus.MainActivity', '-d', shlex.quote(uri))
    deadline = begin + 25
    while time.monotonic() < deadline:
        lines = logs()
        if 'firstFrame id=' in lines and f'cid={video["cid"]}' in lines:
            break
        time.sleep(.25)
    else:
        (OUT / (label + '.log')).write_text(lines, encoding='utf-8')
        raise RuntimeError(f'{label}: no first frame')
    time.sleep(2)
    lines = logs()
    (OUT / (label + '.log')).write_text(lines, encoding='utf-8')
    print(label, video['bvid'], flush=True)
    for line in lines.splitlines():
        if 'Media3Startup' in line or 'firstFrame id=' in line:
            print(line, flush=True)
