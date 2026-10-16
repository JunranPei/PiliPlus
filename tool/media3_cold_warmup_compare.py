"""Compare the local warmup clip in cold profile launches, in ABBA order.

Only the profile APK honors the intent switch. All cases keep the same source,
quality, cache and recorder. First-frame notifications are not pixel timings.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('label')
parser.add_argument('--index', type=int, default=6)
args = parser.parse_args()
out = ROOT / 'diagnostics/startup-20261017/cold-warmup' / args.label
out.mkdir(parents=True, exist_ok=False)
results = []
try:
    for number, skip in enumerate([False, True, True, False], 1):
        mode = 'direct-source' if skip else 'local-warmup'
        label = f'{args.label}-{number}-{mode}'
        command = [sys.executable, str(ROOT / 'tool/media3_startup_recording.py'),
                   label, '--index', str(args.index), '--seconds', '35',
                   '--cold', '--host-recording']
        if skip:
            command.append('--skip-player-warmup')
        completed = subprocess.run(command, capture_output=True, text=True)
        if completed.returncode:
            (out / f'{number}-failure.txt').write_text(completed.stderr, encoding='utf-8')
            raise RuntimeError('Cold launch failed; retain the partial evidence')
        folder = ROOT / 'diagnostics/startup-20261016/startup-recordings' / label
        result = json.loads((folder / 'result.json').read_text(encoding='utf-8'))
        log = (folder / 'playback.log').read_text(encoding='utf-8')
        if f'warmupMode enabled={str(not skip).lower()}' not in log:
            raise RuntimeError('The requested warmup mode was not selected; use the profile APK')
        first_format = re.search(r'phase=video.format codec=(\S+) size=(\S+)', log)
        if not first_format:
            raise RuntimeError('No actual source format was recorded')
        identity = (first_format[1], first_format[2])
        if results and identity != (results[0]['actualCodec'], results[0]['actualResolution']):
            raise RuntimeError('The source codec or resolution changed between cases')
        flow = [json.loads(line.split('[Media3Flow] ', 1)[1])
                for line in log.splitlines() if '[Media3Flow] ' in line]
        phases = {event['phase']: event['epochUs'] for event in flow}
        requested = next(line for line in log.splitlines() if 'open-request ' + label in line)
        request_us = round(float(requested.split()[0]) * 1_000_000)
        result.update({
            'number': number, 'mode': mode,
            'actualCodec': identity[0], 'actualResolution': identity[1],
            'requestToUiRevealMs': round((phases['ui.reveal.end'] - request_us) / 1000),
            'primaryApiMs': round((phases['query.primary.end'] - phases['query.primary.begin']) / 1000),
            'recordingFolder': str(folder.relative_to(ROOT)),
            'nativeErrors': len(re.findall(r'error id=|FATAL EXCEPTION', log)),
        })
        results.append(result)
        (out / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps({key: result[key] for key in [
            'number', 'mode', 'primaryApiMs', 'requestToNativeFirstFrameMs',
            'requestToUiRevealMs', 'lastPositionMs', 'postStartPauseIntent',
            'nativeErrors', 'audioUnderrunCountLowerBound',
        ]}), flush=True)
finally:
    subprocess.run(['adb', '-s', 'emulator-5554', 'shell', 'input', 'keyevent', '4'], check=True)
