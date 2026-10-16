"""Quantify recorder overhead with the same app, video, UI tap and process."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('label')
parser.add_argument('--seconds', type=int, default=15)
parser.add_argument('--tap', nargs=2, type=int, default=[280, 500])
args = parser.parse_args()
out = ROOT / 'diagnostics/startup-20261016/recorder-ab' / args.label
out.mkdir(parents=True, exist_ok=False)
results = []
try:
    for number, host in enumerate([False, True, True, False], 1):
        mode = 'host' if host else 'Android'
        label = f'{args.label}-{number}-{mode}'
        command = [sys.executable, str(ROOT / 'tool/media3_startup_recording.py'), label,
                   '--seconds', str(args.seconds), '--tap', *map(str, args.tap), '--show-touches']
        if host:
            command.append('--host-recording')
        subprocess.run(command, check=True)
        folder = ROOT / 'diagnostics/startup-20261016/startup-recordings' / label
        result = json.loads((folder / 'result.json').read_text(encoding='utf-8'))
        if result['pidBeforeRequest'] != result['pidAfterRequest']:
            raise RuntimeError('The app process changed during a sample')
        if results and (result['pidAfterRequest'] != results[0]['pidAfterRequest']
                        or result['video']['cid'] != results[0]['video']['cid']):
            raise RuntimeError('The app process or video changed between samples')
        result.update({'number': number, 'recordingFolder': str(folder.relative_to(ROOT))})
        results.append(result)
        (out / 'results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
finally:
    subprocess.run(['adb', '-s', 'emulator-5554', 'shell', 'input', 'keyevent', '4'], check=True)
