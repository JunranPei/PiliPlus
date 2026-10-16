"""Profile an already running app during video startup; not acceptance timing."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('connection', type=Path)
parser.add_argument('label')
parser.add_argument('--source', choices=['dash', 'progressive'], default='dash')
parser.add_argument('--index', type=int, default=6)
args = parser.parse_args()
connection = json.loads(args.connection.read_text(encoding='utf-8'))
out = ROOT / 'diagnostics/startup-20261016/startup-cpu' / args.label
out.mkdir(parents=True, exist_ok=True)
adb = ['adb', '-s', 'emulator-5554']
pid = subprocess.check_output(adb + ['shell', 'pidof', 'com.personal.piliplus']).decode().strip()
if pid != connection['pid']:
    raise RuntimeError('The diagnostic connection belongs to a different app process')


def rpc(method, params=None):
    with urllib.request.urlopen(connection['base'] + method + '?' +
                                urllib.parse.urlencode(params or {}), timeout=20) as response:
        result = json.load(response)
    if 'error' in result:
        raise RuntimeError(str(result['error']))
    return result['result']


isolate = connection['isolate']
rpc('setFlag', {'name': 'profiler', 'value': 'true'})
try:
    rpc('ext.piliplus.media3StartupMode', {
        'isolateId': isolate, 'batch': 'true', 'source': args.source, 'cache': 'false',
    })
    # Emulator wall time can drift from the host by seconds. Both clocks used
    # for this mapping must come from the Android device.
    wall_before = round(float(subprocess.check_output(adb + ['shell', 'date', '+%s.%N'])) * 1_000_000)
    timeline_before = rpc('getVMTimelineMicros')['timestamp']
    wall_after = round(float(subprocess.check_output(adb + ['shell', 'date', '+%s.%N'])) * 1_000_000)
    offset = (wall_before + wall_after) // 2 - timeline_before
    subprocess.run([sys.executable, str(ROOT / 'tool/media3_startup_recording.py'),
                    args.label, '--index', str(args.index), '--seconds', '8', '--no-back'], check=True)
    samples = rpc('getCpuSamples', {
        'isolateId': isolate, 'timeOriginMicros': timeline_before,
        'timeExtentMicros': rpc('getVMTimelineMicros')['timestamp'] - timeline_before,
    })
    (out / 'samples.json').write_text(json.dumps(samples), encoding='utf-8')
    recording = ROOT / 'diagnostics/startup-20261016/startup-recordings' / args.label
    lines = (recording / 'playback.log').read_text(encoding='utf-8').splitlines()
    rendered = next(line for line in lines if 'phase=video.surfaceRendered' in line)
    delay = int(re.search(r'callbackDelayMs=(\d+)', rendered)[1])
    finish = round(float(rendered.split()[0]) * 1_000_000) - offset
    begin = finish - delay * 1000
    window = [sample for sample in samples['samples'] if begin <= sample['timestamp'] <= finish]
    functions = samples['functions']
    inclusive = Counter(index for sample in window for index in set(sample['stack']))
    top = [{'name': functions[index]['function']['name'],
            'url': functions[index].get('resolvedUrl', ''), 'samples': count}
           for index, count in inclusive.most_common(25)]
    application = [{'name': functions[index]['function']['name'],
                    'url': functions[index].get('resolvedUrl', ''), 'samples': count}
                   for index, count in inclusive.most_common()
                   if any(part in functions[index].get('resolvedUrl', '')
                          for part in ['/PiliPlus/lib/', '/Pub/Cache/'])][:25]
    report = {'callbackDelayMs': delay, 'samplesInBlockedWindow': len(window),
              'clockMappingRoundTripUs': wall_after - wall_before, 'topInclusive': top,
              'applicationFrames': application, 'clockMappingOffsetMicros': offset,
              'blockedTimelineMicros': [begin, finish],
              'boundary': 'CPU sampling perturbs timing; this run diagnoses work, not startup acceptance.'}
    (out / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))
finally:
    rpc('setFlag', {'name': 'profiler', 'value': 'false'})
    rpc('ext.piliplus.media3StartupMode', {
        'isolateId': isolate, 'batch': 'true', 'source': 'dash', 'cache': 'true',
    })
    subprocess.run(adb + ['shell', 'input', 'keyevent', '4'], check=True)
