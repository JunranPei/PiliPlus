"""Exercise retained-player callbacks while pages are closed during preparation."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
out = ROOT / 'diagnostics/startup-20261016/rapid-navigation-20261017'
out.mkdir(parents=True, exist_ok=True)
videos = json.loads((ROOT / 'diagnostics/startup-20261016/videos.json').read_text(encoding='utf-8'))
command = ['adb', '-s', 'emulator-5554']


def adb(*args):
    return subprocess.check_output(command + list(args), timeout=25)


old_volume = int(re.search(r'volume is (\d+)', adb('shell', 'cmd', 'media_session', 'volume', '--stream', '3', '--get').decode())[1])
remote_video = out / 'screen.webm'
started = False
try:
    adb('shell', 'cmd', 'media_session', 'volume', '--stream', '3', '--set', '0')
    adb('logcat', '-c')
    adb('emu', 'screenrecord', 'start', '--size', '540x1200', '--time-limit', '90', str(remote_video))
    started = True
    for number, index in enumerate([0, 6, 1, 7, 2, 6]):
        video = videos[index]
        marker = f'rapid-open-{number}'
        adb('shell', 'log', '-t', 'Media3Test', marker)
        uri = f'bilibili://video/{video["bvid"]}?cid={video["cid"]}&start_progress=0'
        adb('shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-n',
            'com.personal.piliplus/.MainActivity', '-d', shlex.quote(uri))
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            log = adb('logcat', '-d', '-v', 'epoch', '-s', 'Media3Playback', 'Media3Test').decode('utf-8', 'replace')
            if re.search(r'open id=\d+ source=\d+ cid=' + str(video['cid']), log.split(marker)[-1]):
                break
            time.sleep(.1)
        else:
            raise RuntimeError(f'Video {number} did not reach native preparation')
        if number < 5:
            time.sleep(.1)
            adb('shell', 'input', 'keyevent', '4')
            time.sleep(.7)
        else:
            time.sleep(10)
    log = adb('logcat', '-d', '-v', 'epoch', '-s', 'Media3Playback', 'Media3Test', 'AndroidRuntime').decode('utf-8', 'replace')
    (out / 'playback.log').write_text(log, encoding='utf-8')
    (out / 'final.png').write_bytes(adb('exec-out', 'screencap', '-p'))
    owner = None
    stale = 0
    opens = []
    for line in log.splitlines():
        opened = re.search(r'open id=(\d+) source=(\d+) cid=(\d+).*epoch=(\d+)', line)
        if opened:
            owner = (opened[1], opened[2])
            opens.append({'player': opened[1], 'source': opened[2], 'cid': opened[3], 'epoch': opened[4]})
        frame = re.search(r'firstFrame id=(\d+) source=(\d+)', line)
        if frame and (frame[1], frame[2]) != owner:
            stale += 1
    result = {'opens': opens, 'staleFirstFrameCallbacks': stale,
              'nativeErrors': len(re.findall(r'error id=|FATAL EXCEPTION', log)),
              'expectedFinalCid': videos[6]['cid']}
    (out / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result), flush=True)
    if len(opens) != 6 or stale or result['nativeErrors']:
        raise RuntimeError('Rapid navigation did not pass; inspect retained evidence')
finally:
    if started:
        adb('emu', 'screenrecord', 'stop')
    adb('shell', 'input', 'keyevent', '4')
    adb('shell', 'cmd', 'media_session', 'volume', '--stream', '3', '--set', str(old_volume))
