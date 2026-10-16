"""UI-driven Android acceptance capture for the Media3-only build.

Keeps every recording and reports preparation separately from an explicit play
tap. These are emulator measurements, not real-device or cold-start guarantees.
"""
import json
import argparse
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding='utf-8')
ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--package', default='com.personal.piliplus.debug')
parser.add_argument('--output', default='diagnostics/startup-20261016/ten-videos')
parser.add_argument('--autoplay-aware', action='store_true')
args = parser.parse_args()
OUT = ROOT / args.output
ADB = ['D:/Android_Studio_Sdk/platform-tools/adb.exe', '-s', 'emulator-5554']
PACKAGE = args.package

def adb(*args, timeout=30):
    return subprocess.run(ADB + list(args), capture_output=True, check=True, timeout=timeout)

def logcat():
    return adb('logcat', '-d', '-v', 'epoch', '-s', 'Media3Playback', 'Media3Test', 'flutter', 'AndroidRuntime').stdout.decode('utf-8', 'replace')

def capture(path):
    path.write_bytes(adb('exec-out', 'screencap', '-p').stdout)

def epoch(line):
    return float(line.split()[0])

def sample(number, video):
    folder = OUT / f'{number:02d}-{video["bvid"]}'
    folder.mkdir(parents=True, exist_ok=False)
    adb('shell', 'input', 'keyevent', '4')
    time.sleep(.8)
    adb('logcat', '-c')
    uri = f'bilibili://video/{video["bvid"]}?cid={video["cid"]}&start_progress=0'
    launched = adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-n', PACKAGE + '/com.personal.piliplus.MainActivity', '-d', shlex.quote(uri))
    (folder / 'launch.txt').write_bytes(launched.stdout)
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        logs = logcat()
        if 'firstFrame id=' in logs and f'cid={video["cid"]}' in logs:
            break
        if 'FATAL EXCEPTION' in logs:
            raise RuntimeError('App crashed during source preparation')
        time.sleep(.5)
    else:
        (folder / 'failed-log.txt').write_text(logs, encoding='utf-8')
        capture(folder / 'failed.png')
        return {**video, 'number': number, 'error': 'No prepared first frame within 25 seconds'}
    capture(folder / 'prepared.png')
    remote = f'/sdcard/pili-native-acceptance-{number:02d}.mp4'
    recording = subprocess.Popen(ADB + ['shell', 'screenrecord', '--size', '540x1200', '--time-limit', '40', '--bit-rate', '1500000', remote], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(.6)
    adb('shell', 'log', '-t', 'Media3Test', f'play-tap sample={number}')
    tap_time = time.monotonic()
    intents = re.findall(r'intent id=\d+ source=\d+ playWhenReady=(true|false)', logs)
    autoplaying = args.autoplay_aware and bool(intents) and intents[-1] == 'true'
    if not autoplaying:
        adb('shell', 'input', 'tap', '500', '350')
    time.sleep(5)
    capture(folder / 'playing-5s.png')
    while time.monotonic() - tap_time < 32:
        time.sleep(min(5, 32 - (time.monotonic() - tap_time)))
    capture(folder / 'playing-32s.png')
    adb('shell', 'input', 'tap', '500', '600')
    time.sleep(.5)
    capture(folder / 'controls.png')
    logs = logcat()
    retained = '\n'.join(line for line in logs.splitlines()
        if any(tag in line for tag in ['Media3Playback', 'Media3Test', '[PLAYBACK_UI]', '[PLAYBACK]', 'FATAL EXCEPTION']))
    (folder / 'playback-log.txt').write_text(retained, encoding='utf-8')
    recording.wait(timeout=12)
    adb('pull', remote, str(folder / 'screen.mp4'))
    lines = retained.splitlines()
    tap = next(line for line in lines if f'play-tap sample={number}' in line)
    after_tap = [line for line in lines if epoch(line) >= epoch(tap)]
    state = []
    for line in after_tap:
        match = re.search(r'positionMs=(\d+) state=(\d+) playWhenReady=(\w+) bufferMs=(\d+)', line)
        if match:
            state.append({'epoch': epoch(line), 'positionMs': int(match[1]), 'state': int(match[2]), 'playing': match[3] == 'true', 'bufferMs': int(match[4])})
    presented = next((line for line in after_tap if '[PLAYBACK_UI] presented' in line), None)
    prepared = re.search(r'firstFrame id=\d+ source=\d+ elapsedMs=(\d+)', retained)
    result = {**video, 'number': number, 'preparedFirstFrameMs': int(prepared[1]) if prepared else None,
        'tapToPresentationEventMs': round((epoch(presented)-epoch(tap))*1000) if presented else None,
        'lastPositionMs': state[-1]['positionMs'] if state else 0,
        'minimumPlayingBufferMs': min((s['bufferMs'] for s in state if s['playing']), default=0),
        'pausedWithoutUser': any('playWhenReady=false' in line and 'intent ' in line for line in after_tap),
        'bufferingSamples': sum(s['state'] == 2 for s in state),
        'observedSeconds': round(time.monotonic()-tap_time, 2),
        'autoplaying': autoplaying,
        'boundary': ('Autoplay already active at observation start' if autoplaying else 'Explicit play after source preparation')
            + '; presentation event is not a pixel-measured moving frame'}
    gaps = [b['epoch'] - a['epoch'] for a, b in zip(state, state[1:])]
    result['maximumStateLogGapSeconds'] = round(max(gaps, default=0), 3)
    result['passContinuousPlayback'] = (result['lastPositionMs'] >= 29000
        and not result['pausedWithoutUser'] and result['bufferingSamples'] == 0
        and result['maximumStateLogGapSeconds'] < 1.8)
    (folder / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    return result

if __name__ == '__main__':
    videos = json.loads((ROOT / 'diagnostics/startup-20261016/videos.json').read_text(encoding='utf-8'))
    OUT.mkdir(parents=True, exist_ok=True)
    results = []
    for number, video in enumerate(videos, 1):
        result = sample(number, video)
        results.append(result)
        (OUT / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps(result, ensure_ascii=False), flush=True)
    print(json.dumps({'tested': len(results), 'distinctCids': len({r['cid'] for r in results}),
        'continuousPass': sum(r.get('passContinuousPlayback', False) for r in results)}, ensure_ascii=False), flush=True)
