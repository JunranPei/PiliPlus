"""Record the original player UI from before opening a video through playback.

Native callbacks and position logs are supporting evidence. The recording is
retained for visual review; callback timestamps are never labeled pixel timing.
"""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('label')
parser.add_argument('--index', type=int, default=6)
parser.add_argument('--seconds', type=int, default=22)
parser.add_argument('--cold', action='store_true')
parser.add_argument('--tap', nargs=2, type=int, metavar=('X', 'Y'))
parser.add_argument('--no-back', action='store_true')
args = parser.parse_args()
if args.cold and args.tap:
    parser.error('Open the app home before measuring a card tap')
out = ROOT / 'diagnostics/startup-20261016/startup-recordings' / args.label
out.mkdir(parents=True, exist_ok=True)
adb_command = ['adb', '-s', 'emulator-5554']
package = 'com.personal.piliplus'


def adb(*arguments):
    return subprocess.run(adb_command + list(arguments), capture_output=True,
                          check=True, timeout=40).stdout


def pid():
    return subprocess.run(adb_command + ['shell', 'pidof', package],
                          capture_output=True, timeout=10).stdout.decode().strip()


active_builds = subprocess.run([
    'powershell', '-NoProfile', '-Command',
    "Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^java' "
    "-and $_.CommandLine -match 'GradleWrapperMain' } | "
    "Select-Object -ExpandProperty ProcessId"
], capture_output=True, check=True).stdout.strip()
if active_builds:
    raise RuntimeError('An active build would invalidate the performance comparison')

videos = json.loads((ROOT / 'diagnostics/startup-20261016/videos.json').read_text(encoding='utf-8'))
video = videos[args.index]
if args.cold:
    adb('shell', 'am', 'force-stop', package)
elif not args.no_back:
    adb('shell', 'input', 'keyevent', '4')
    time.sleep(.8)
adb('logcat', '-c')
pid_before = pid()
remote = '/sdcard/media3-startup-review.mp4'
recording = subprocess.Popen(adb_command + [
    'shell', 'screenrecord', '--bugreport', '--size', '540x1200', '--bit-rate', '2000000',
    '--time-limit', str(args.seconds), remote
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(.8)
if recording.poll() is not None:
    raise RuntimeError('Screen recording failed before the video was opened')
adb('shell', 'log', '-t', 'Media3Test', 'open-request ' + args.label)
begin = time.monotonic()
uri = f'bilibili://video/{video["bvid"]}?cid={video["cid"]}&start_progress=0'
if args.tap:
    launch = adb('shell', 'input', 'tap', *map(str, args.tap))
else:
    launch = adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW',
                 '-n', package + '/com.personal.piliplus.MainActivity', '-d', shlex.quote(uri))
(out / 'launch.txt').write_bytes(launch)
recording.wait(timeout=args.seconds + 8)
adb('pull', remote, str(out / 'screen.mp4'))
log = adb('logcat', '-d', '-v', 'epoch', '-s', 'Media3Startup',
          'Media3Playback', 'Media3Input', 'Media3Test', 'flutter', 'AndroidRuntime').decode('utf-8', 'replace')
(out / 'playback.log').write_text(log, encoding='utf-8')
states = re.findall(r'positionMs=(\d+) state=(\d+) playWhenReady=(true|false) bufferMs=(\d+)', log)
intents = re.findall(r'intent id=\d+ source=\d+ playWhenReady=(true|false)', log)
first = re.search(r'firstFrame id=\d+ source=\d+ elapsedMs=(\d+)', log)
request_line = next((line for line in log.splitlines() if 'open-request ' + args.label in line), None)
frame_line = next((line for line in log.splitlines() if 'firstFrame id=' in line), None)
request_to_frame = (round((float(frame_line.split()[0]) - float(request_line.split()[0])) * 1000)
                    if request_line and frame_line else None)
tap_line = next((line for line in log.splitlines() if 'Media3Input' in line and 'action=0 ' in line), None)
tap_epoch_ms = None
if tap_line:
    timing = re.search(r'eventUptimeMs=(\d+) dispatchUptimeMs=(\d+)', tap_line)
    tap_epoch_ms = float(tap_line.split()[0]) * 1000 - (int(timing[2]) - int(timing[1]))
source_cid = re.search(r'open id=\d+ source=\d+ cid=(\d+)', log)
result = {
    'video': ({'cid': int(source_cid[1]) if source_cid else None, 'entry': 'UI card tap'} if args.tap else video),
    'coldProcess': args.cold, 'preservedDiskCache': True,
    'recordedSeconds': args.seconds, 'observationSeconds': round(time.monotonic() - begin, 2),
    'nativeFirstFrameMs': int(first[1]) if first else None,
    'requestToNativeFirstFrameMs': request_to_frame,
    'tapDownEpochMs': tap_epoch_ms,
    'tapToNativeFirstFrameMs': round(float(frame_line.split()[0]) * 1000 - tap_epoch_ms) if frame_line and tap_epoch_ms is not None else None,
    'pidBeforeRequest': pid_before,
    'pidAfterRequest': pid(),
    'playIntents': intents, 'lastPositionMs': int(states[-1][0]) if states else None,
    'postStartPauseIntent': 'false' in intents[intents.index('true') + 1:] if 'true' in intents else None,
    'boundary': 'Emulator recording; native first-frame timing starts at source open, not UI tap. Review video for visible motion and pauses.'
}
(out / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(result, ensure_ascii=True), flush=True)
if first is None or 'FATAL EXCEPTION' in log:
    raise RuntimeError('No first frame or application crash; inspect retained recording/log')
