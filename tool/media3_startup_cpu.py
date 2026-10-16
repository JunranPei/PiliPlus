"""Capture Dart CPU samples for the blocked startup callback, not playback acceptance."""
from pathlib import Path
import json
import re
import subprocess
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'diagnostics/startup-20261016/startup-cpu'
OUT.mkdir(parents=True, exist_ok=True)
ADB = ['adb', '-s', 'emulator-5554']

def adb(*args):
    return subprocess.run(ADB + list(args), capture_output=True, check=True).stdout

adb('shell', 'am', 'force-stop', 'com.personal.piliplus')
adb('logcat', '-c')
adb('shell', 'am', 'start', '-a', 'android.intent.action.VIEW',
    '-n', 'com.personal.piliplus/com.personal.piliplus.MainActivity',
    '--ez', 'enable-dart-profiling', 'true',
    '-d', 'bilibili://video/BV15BJX6dEoR?cid=42790290231')
deadline = time.monotonic() + 25
match = None
while time.monotonic() < deadline:
    log = adb('logcat', '-d', '-v', 'epoch', '-s', 'flutter', 'Media3Startup', 'Media3Playback').decode('utf-8', 'replace')
    match = re.search(r'The Dart VM service is listening on (http://127.0.0.1:(\d+)/\S+/)', log)
    if match:
        break
    time.sleep(.15)
if not match:
    raise RuntimeError('No VM profiler endpoint')
base = match[1]
adb('forward', 'tcp:' + match[2], 'tcp:' + match[2])

def request(method, params=None):
    return json.load(urllib.request.urlopen(base + method + '?' + urllib.parse.urlencode(params or {}), timeout=15))

enabled = request('setFlag', {'name': 'profiler', 'value': 'true'})
if enabled.get('result', {}).get('type') != 'Success':
    raise RuntimeError('CPU profiling could not be enabled')
isolates = []
while time.monotonic() < deadline:
    isolates = request('getVM')['result']['isolates']
    if isolates:
        break
    time.sleep(.1)
isolate = isolates[0]['id']
while time.monotonic() < deadline:
    log = adb('logcat', '-d', '-v', 'epoch', '-s', 'Media3Startup', 'Media3Playback').decode('utf-8', 'replace')
    if 'phase=firstFrame' in log:
        break
    time.sleep(.15)
(OUT / 'startup.log').write_text(log, encoding='utf-8')
now = request('getVMTimelineMicros')['result']['timestamp']
result = request('getCpuSamples', {'isolateId': isolate, 'timeOriginMicros': max(0, now-20_000_000), 'timeExtentMicros': 20_000_000})
(OUT / 'cpu-samples.json').write_text(json.dumps(result), encoding='utf-8')
print({'keys': list(result.get('result', {})), 'error': result.get('error')})
