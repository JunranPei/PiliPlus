"""Read private PiP text logs without starting/stopping the app or taking images."""
import argparse
import json
from pathlib import Path
import re
import subprocess


def pull(adb, serial, package, destination):
    command = [str(adb), '-s', serial]
    listing = subprocess.run(
        command + ['shell', 'run-as', package, 'ls', 'files/pip-diagnostics'],
        check=True, capture_output=True,
    ).stdout.decode('utf-8').split()
    names = [n for n in listing if re.fullmatch(r'flutter-\d+\.jsonl', n)]
    if not names:
        raise RuntimeError('No Flutter trace file exists; no app action was taken.')
    latest = max(names, key=lambda name: int(name.split('-')[1].split('.')[0]))
    destination.mkdir(parents=True, exist_ok=True)

    def read(name):
        if not re.fullmatch(r'(?:flutter-\d+\.jsonl|mpv-\d+\.log)', name):
            raise ValueError('Invalid trace filename')
        data = subprocess.run(
            command + ['exec-out', 'run-as', package, 'cat', f'files/pip-diagnostics/{name}'],
            check=True, capture_output=True,
        ).stdout
        (destination / name).write_bytes(data)
        return data

    raw = read(latest)
    rows, invalid = [], []
    for index, line in enumerate(raw.decode('utf-8').splitlines(), 1):
        try:
            rows.append(json.loads(line))
        except ValueError as error:
            invalid.append({'line': index, 'error': str(error)})
    # Pull every mpv session referenced by this process's Flutter trace.
    mpv_names = sorted({Path(row['path']).name for row in rows
                        if row.get('event') == 'mpv.file'})
    for name in mpv_names:
        read(name)
    sequences = [row['seq'] for row in rows if 'seq' in row]
    gaps = [{'after': a, 'before': b} for a, b in zip(sequences, sequences[1:]) if b != a + 1]
    summary = {
        'flutterFile': latest, 'records': len(rows), 'invalidRecords': invalid,
        'sequenceGaps': gaps, 'mpvFiles': mpv_names,
        'visualAcceptance': 'not inferred from text logs',
    }
    (destination / 'capture.json').write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8',
    )
    print(json.dumps({'records': len(rows), 'invalid': len(invalid),
                      'gaps': len(gaps), 'mpvFiles': len(mpv_names)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--adb', type=Path, default=Path('D:/Android_studio_sdk/platform-tools/adb.exe'))
    parser.add_argument('--serial', default='emulator-5554')
    parser.add_argument('--package', default='com.personal.piliplus.debug')
    args = parser.parse_args()
    pull(args.adb, args.serial, args.package, args.destination)
