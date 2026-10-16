"""Compare one startup change in one process, with the original UI recorded.

ABBA order balances warm-up/order effects. These are diagnostic comparisons,
not a replacement for ten different videos or pixel-measured acceptance.
"""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('label')
parser.add_argument('--index', type=int, default=6)
parser.add_argument('--seconds', type=int, default=16)
args = parser.parse_args()
out = ROOT / 'diagnostics/startup-20261016/startup-ab' / args.label
out.mkdir(parents=True, exist_ok=True)
adb_command = ['adb', '-s', 'emulator-5554']
package = 'com.personal.piliplus'
video = json.loads((ROOT / 'diagnostics/startup-20261016/videos.json').read_text(encoding='utf-8'))[args.index]
uri = f'bilibili://video/{video["bvid"]}?cid={video["cid"]}&start_progress=0'


def adb(*arguments):
    return subprocess.run(adb_command + list(arguments), capture_output=True,
                          check=True, timeout=40).stdout


adb('shell', 'am', 'force-stop', package)
adb('logcat', '-c')
adb('shell', 'am', 'start', '-a', 'android.intent.action.VIEW',
    '-n', package + '/com.personal.piliplus.MainActivity', '-d', shlex.quote(uri))
deadline = time.monotonic() + 40
while time.monotonic() < deadline:
    log = adb('logcat', '-d', '-v', 'epoch', '-s', 'flutter', 'Media3Startup', 'Media3Playback').decode('utf-8', 'replace')
    service = re.search(r'The Dart VM service is listening on (http://127.0.0.1:\d+/\S+/)', log)
    if service and 'phase=firstFrame' in log:
        break
    time.sleep(.3)
else:
    raise RuntimeError('Setup did not reach the first frame and VM service')

parts = urllib.parse.urlsplit(service[1])
port = int(adb('forward', 'tcp:0', 'tcp:' + str(parts.port)).strip())
base = urllib.parse.urlunsplit(('http', f'127.0.0.1:{port}', parts.path, '', ''))


def rpc(method, params=None):
    with urllib.request.urlopen(base + method + '?' + urllib.parse.urlencode(params or {}), timeout=20) as response:
        result = json.load(response)
    if 'error' in result:
        raise RuntimeError('VM request failed: ' + method + ' ' + str(result['error'].get('message')))
    return result['result']


isolates = rpc('getVM')['isolates']
isolate = next((item for item in isolates if item.get('name') == 'main'), isolates[0])['id']
pid = adb('shell', 'pidof', package).decode().strip()
# Local, ephemeral diagnostic connection. Never add this file to version control.
(out / 'vm-connection.json').write_text(json.dumps({'base': base, 'isolate': isolate, 'pid': pid}), encoding='utf-8')
time.sleep(1)
results = []
try:
    for number, batch in enumerate([False, True, True, False], 1):
        mode = 'batched' if batch else 'baseline'
        selected = rpc('ext.piliplus.media3StartupMode', {'isolateId': isolate, 'batch': str(batch).lower()})
        if selected.get('batch') != batch or selected.get('backend') != 'Media3':
            raise RuntimeError('The requested Media3 startup mode was not selected')
        label = f'{args.label}-{number}-{mode}'
        completed = subprocess.run([sys.executable, str(ROOT / 'tool/media3_startup_recording.py'),
            label, '--index', str(args.index), '--seconds', str(args.seconds)], capture_output=True, text=True)
        folder = ROOT / 'diagnostics/startup-20261016/startup-recordings' / label
        if completed.returncode:
            (out / f'{number}-failure.txt').write_text(completed.stderr, encoding='utf-8')
            raise RuntimeError('Recording failed; inspect retained diagnostics')
        result = json.loads((folder / 'result.json').read_text(encoding='utf-8'))
        if result['pidBeforeRequest'] != pid or result['pidAfterRequest'] != pid:
            raise RuntimeError('The process changed during the comparison')
        lines = (folder / 'playback.log').read_text(encoding='utf-8').splitlines()
        flow = [json.loads(line.split('[Media3Flow] ', 1)[1]) for line in lines if '[Media3Flow] ' in line]
        phases = {event['phase']: event['epochUs'] for event in flow}
        request_line = next(line for line in lines if 'open-request ' + label in line)
        request_us = round(float(request_line.split()[0]) * 1_000_000)
        result.update({
            'mode': mode, 'number': number,
            'primaryApiMs': round((phases['query.primary.end'] - phases['query.primary.begin']) / 1000),
            'postApiToUiRevealMs': round((phases['ui.reveal.end'] - phases['query.primary.end']) / 1000),
            'requestToUiRevealMs': round((phases['ui.reveal.end'] - request_us) / 1000),
            'recordingFolder': str(folder.relative_to(ROOT)),
        })
        results.append(result)
        (out / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps({key: result[key] for key in ['number', 'mode', 'primaryApiMs', 'postApiToUiRevealMs',
            'requestToNativeFirstFrameMs', 'requestToUiRevealMs', 'postStartPauseIntent', 'lastPositionMs']}), flush=True)
finally:
    rpc('ext.piliplus.media3StartupMode', {'isolateId': isolate, 'batch': 'false'})
