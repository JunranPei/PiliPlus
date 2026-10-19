"""Record original-UI mpv startup; pixel timing requires review of the video."""
import argparse
import atexit
import json
from pathlib import Path
import shlex
import subprocess
import time
import xml.etree.ElementTree as ET
from urllib.parse import quote

from ordinary_playback_capture import file_info, selected_logs

ROOT = Path(__file__).resolve().parents[1]
ADB = ['adb', '-s', 'emulator-5554']
PACKAGE = 'com.personal.piliplus'


def adb(*args, timeout=40):
    return subprocess.run(ADB + list(args), capture_output=True, check=True,
                          timeout=timeout).stdout


def capture(label, index, seconds, tap, cold, local_link=False, verify_search_uri=False,
            before_recording=None):
    video = json.loads((ROOT / 'diagnostics/startup-20261016/videos.json').read_text(
        encoding='utf-8'))[index]
    out = ROOT / 'diagnostics/startup-20261017/mpv-phase1' / label
    out.mkdir(parents=True, exist_ok=False)
    (out / 'recorder-pid.txt').write_text(str(__import__('os').getpid()))
    if cold:
        adb('shell', 'am', 'force-stop', PACKAGE)
    elif local_link:
        # Submit an ordinary video URI through the existing search field. This
        # keeps the measured action inside the app without remote search APIs.
        adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW',
            '-n', PACKAGE + '/com.personal.piliplus.MainActivity', '-d',
            'bilibili://search')
        time.sleep(.8)
        uri = f'bilibili://video/{video["bvid"]}?cid={video["cid"]}&start_progress=0'
        if verify_search_uri:
            # Cold guest/IME startup can drop the tail of a long input burst.
            # This is untimed setup; never measure a different CID by accident.
            for offset in range(0, len(uri), 12):
                adb('shell', 'input', 'text', shlex.quote(uri[offset:offset+12]))
                time.sleep(.1)
        else:
            adb('shell', 'input', 'text', shlex.quote(uri))
        time.sleep(2)
        if verify_search_uri:
            remote_ui = '/sdcard/piliplus-startup-input.xml'
            adb('shell', 'uiautomator', 'dump', remote_ui)
            ui = adb('shell', 'cat', remote_ui)
            (out/'verified-entry-ui.xml').write_bytes(ui)
            nodes = ET.fromstring(ui).iter('node')
            if not any(n.get('text') == uri and n.get('focused') == 'true'
                       for n in nodes):
                raise RuntimeError('Search input is incomplete before timing; no video tap was measured')
    elif tap:
        adb('shell', 'input', 'keyevent', '4')
        # Searching a BV id navigates directly to playback in PiliPlus. Search
        # the title so the measured action is an actual result-card tap.
        uri = 'bilibili://search?keyword=' + quote(video['title'])
        adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW',
            '-n', PACKAGE + '/com.personal.piliplus.MainActivity', '-d', shlex.quote(uri))
        time.sleep(4)
    else:
        adb('shell', 'input', 'keyevent', '4')
        time.sleep(.8)
    before_pid = subprocess.run(ADB + ['shell', 'pidof', PACKAGE],
                                capture_output=True).stdout.decode().strip()
    adb('logcat', '-c')
    if local_link:
        # The persistent pointer overlay supplies a visible input anchor in the
        # same recording clock as the decoded picture. Reset its last position.
        adb('shell', 'settings', 'put', 'system', 'pointer_location', '0')
        adb('shell', 'settings', 'put', 'system', 'pointer_location', '1')
        time.sleep(.3)
    recording = out / 'screen.webm'
    if before_recording is not None:
        before_recording()
    recording_start_before = time.time_ns()
    response = adb('emu', 'screenrecord', 'start', '--size', '540x1200',
                   '--bit-rate', '2000000', '--fps', '30', '--time-limit',
                   str(seconds + 5), str(recording))
    recording_start_after = time.time_ns()
    if b'KO:' in response:
        raise RuntimeError('Host recording rejected')
    try:
        time.sleep(.8)
        adb('shell', 'log', '-t', 'StartupTest', 'open-request ' + label)
        started = time.monotonic()
        if tap:
            adb('shell', 'input', 'tap', *map(str, tap))
        else:
            uri = f'bilibili://video/{video["bvid"]}?cid={video["cid"]}&start_progress=0'
            adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW',
                '-n', PACKAGE + '/com.personal.piliplus.MainActivity', '-d', shlex.quote(uri))
        time.sleep(max(0, started + seconds - time.monotonic()))
    finally:
        adb('emu', 'screenrecord', 'stop')
    if not recording.is_file() or recording.stat().st_size == 0:
        raise RuntimeError('Recording is missing')
    log = adb('logcat', '-d', '-v', 'epoch', '-s', 'StartupTest', 'flutter',
              'AndroidRuntime').decode('utf-8', 'replace')
    (out / 'playback.log').write_text(log, encoding='utf-8')
    codec_log = adb('logcat', '-d', '-v', 'epoch', '-s', 'MediaCodec', 'CCodec',
                    'ACodec', 'AudioTrack', 'AudioFlinger',
                    'CCodecBufferChannel').decode('utf-8', 'replace')
    (out / 'codec-audio.log').write_text(codec_log, encoding='utf-8')
    sessions = adb('shell', 'dumpsys', 'media_session').decode('utf-8', 'replace')
    (out / 'media-session.txt').write_text(sessions, encoding='utf-8')
    input_state = adb('shell', 'dumpsys', 'input').decode('utf-8', 'replace')
    (out / 'input-state.txt').write_text(input_state, encoding='utf-8')
    current_pid = adb('shell', 'pidof', PACKAGE).decode().strip()
    remote = f'/sdcard/Android/data/{PACKAGE}/files/playback-diagnostics'
    names = adb('shell', 'ls', remote).decode().split()
    names = [name for name in names if name.startswith(
        (f'flutter-{current_pid}-', f'native-{current_pid}-'))]
    trace_dir = out / 'traces'
    trace_dir.mkdir()
    files = []
    for name in selected_logs(names):
        target = trace_dir / name
        adb('pull', remote + '/' + name, str(target), timeout=60)
        files.append(file_info(target))
    traces = {'files': files, 'pid': current_pid}
    request_line = next((line for line in log.splitlines()
                         if 'open-request ' + label in line), None)
    requested_us = float(request_line.split()[0]) * 1_000_000 if request_line else None
    opened_cids = set()
    for item in traces.get('files', []):
        path = out / 'traces' / item['file']
        if not path.name.startswith('flutter-'):
            continue
        for line in path.read_text(encoding='utf-8').splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (event.get('event') == 'source.open.begin' and requested_us is not None
                    and event.get('utcUs', 0) >= requested_us):
                opened_cids.add(event.get('cid'))
    result = {
        'video': video, 'coldProcess': cold,
        'entry': ('existing search button submitting a video URI' if local_link
                  else 'search result card tap' if tap else 'Android VIEW intent'),
        'tap': tap, 'recordedPlaybackSeconds': seconds, 'recording': str(recording),
        'pidBefore': before_pid, 'traces': traces,
        'observedOpenedCids': sorted(cid for cid in opened_cids if cid is not None),
        'visibleMotionMs': None,
        'hostRecordStartUnixNsBounds': [recording_start_before, recording_start_after],
        'boundary': 'Review recorded video for click-to-motion timing; logs do not prove visible motion.',
    }
    (out / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2),
                                    encoding='utf-8')
    adb('shell', 'input', 'keyevent', '4')
    if video['cid'] not in opened_cids:
        raise RuntimeError('The expected video was not opened after the measured input')
    print(json.dumps({'label': label, 'cid': video['cid'], 'recordedSeconds': seconds,
                      'pixelReviewRequired': True}, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('label')
    parser.add_argument('--indices', default='0')
    parser.add_argument('--seconds', type=int, default=35)
    parser.add_argument('--tap', nargs=2, type=int)
    parser.add_argument('--cold', action='store_true')
    parser.add_argument('--local-link', action='store_true')
    args = parser.parse_args()
    if args.cold and args.tap:
        parser.error('A cold process requires the Android VIEW entry')
    if args.local_link and (not args.tap or args.cold):
        parser.error('--local-link requires --tap and a running app')
    builds = subprocess.run([
        'powershell', '-NoProfile', '-Command',
        "Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^java' "
        "-and $_.CommandLine -match 'GradleWrapperMain' } | Select-Object -ExpandProperty ProcessId"
    ], capture_output=True, check=True).stdout.strip()
    if builds:
        raise RuntimeError('A live build invalidates the performance comparison')
    old = {key: adb('shell', 'settings', 'get', 'system', key).decode().strip()
           for key in ('show_touches', 'pointer_location')}

    def restore():
        for key, value in old.items():
            operation = ['delete', 'system', key] if value == 'null' else [
                'put', 'system', key, value]
            adb('shell', 'settings', *operation)

    atexit.register(restore)
    adb('shell', 'settings', 'put', 'system', 'show_touches', '1')
    for index in map(int, args.indices.split(',')):
        capture(f'{args.label}-{index}', index, args.seconds, args.tap, args.cold,
                args.local_link)


if __name__ == '__main__':
    main()
