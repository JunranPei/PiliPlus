"""Record ten distinct full-UI videos, including startup and 30s of playback."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('label')
parser.add_argument('--host-recording', action='store_true')
args = parser.parse_args()
videos = json.loads((ROOT / 'diagnostics/startup-20261016/videos.json').read_text(encoding='utf-8'))
if len(videos) != 10 or len({video['cid'] for video in videos}) != 10:
    raise RuntimeError('This gate requires exactly ten different videos')
out = ROOT / 'diagnostics/startup-20261016/ten-video-regressions' / args.label
out.mkdir(parents=True, exist_ok=False)
results = []
try:
    for index, video in enumerate(videos):
        label = f'{args.label}-{index + 1:02d}'
        command = [sys.executable, str(ROOT / 'tool/media3_startup_recording.py'),
                   label, '--index', str(index), '--seconds', '35']
        if args.host_recording:
            command.append('--host-recording')
        if index == 0:
            command.append('--no-back')
        recording = subprocess.run(command, capture_output=True, text=True)
        folder = ROOT / 'diagnostics/startup-20261016/startup-recordings' / label
        if recording.returncode:
            (out / f'{index + 1:02d}-failure.txt').write_text(recording.stderr, encoding='utf-8')
            raise RuntimeError(f'Stopped at video {index + 1}; retain the partial results')
        result = json.loads((folder / 'result.json').read_text(encoding='utf-8'))
        lines = (folder / 'playback.log').read_text(encoding='utf-8').splitlines()
        frame = next(i for i, line in enumerate(lines) if 'firstFrame id=' in line)
        has_ready = False
        rebuffers = 0
        for line_index, line in enumerate(lines):
            state = re.search(r'\bstate=(\d+)', line)
            if state and state[1] == '3':
                has_ready = True
            if line_index > frame and has_ready and 'stateChange ' in line and state and state[1] == '2':
                rebuffers += 1
        result.update({
            'number': index + 1, 'recordingFolder': str(folder.relative_to(ROOT)),
            'networkRequestsBeforeFirstFrame': sum('phase=net.begin' in line for line in lines[:frame]),
            'rebufferEventsAfterReady': rebuffers,
            'sourceOpenCount': sum('Media3Playback' in line and 'open id=' in line for line in lines),
            'nativeErrors': sum('error id=' in line or 'FATAL EXCEPTION' in line for line in lines),
            'visualReview': 'pending; native positions do not prove continuous visible motion',
        })
        result['nativeContinuityPassed'] = (
            not result['postStartPauseIntent'] and not rebuffers and not result['nativeErrors']
            and result['sourceOpenCount'] == 1 and (result['lastPositionMs'] or 0) >= 30_000
            and result['pidBeforeRequest'] == result['pidAfterRequest']
        )
        results.append(result)
        (out / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps({key: result[key] for key in [
            'number', 'requestToNativeFirstFrameMs', 'lastPositionMs', 'postStartPauseIntent',
            'rebufferEventsAfterReady', 'networkRequestsBeforeFirstFrame', 'nativeContinuityPassed',
        ]}), flush=True)
finally:
    subprocess.run(['adb', '-s', 'emulator-5554', 'shell', 'input', 'keyevent', '4'], check=True)
