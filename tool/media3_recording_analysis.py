"""Measure changes in the recorded video region, excluding most UI/danmaku.

Static authored content and overlapping danmaku still require visual review;
this is supporting evidence, not a decoder stall oracle or cold-start timer.
"""
from pathlib import Path
import argparse
import json
import re
import subprocess
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'diagnostics/startup-20261016/ten-videos'
FFMPEG = r'D:/Program Files/FFmpeg/bin/ffmpeg.exe'
parser = argparse.ArgumentParser()
parser.add_argument('--regression', type=Path)
parser.add_argument('--overview', action='store_true')
args = parser.parse_args()
if args.regression:
    records = json.loads(args.regression.read_text(encoding='utf-8'))
    if len(records) != 10:
        raise RuntimeError('Finish all ten recordings before running CPU-heavy frame analysis')
    OUT = args.regression.parent
    folders = [ROOT / record['recordingFolder'] for record in records]
else:
    records = None
    folders = sorted(OUT.glob('[0-9][0-9]-*'))

results = []
actual_cids = set()
overview_rows = []
for number, folder in enumerate(folders):
    if records:
        log = (folder / 'playback.log').read_text(encoding='utf-8')
        opened = re.search(r'open id=\d+ source=\d+ cid=(\d+)', log)
        cid = int(opened[1]) if opened else None
        if cid != records[number]['video']['cid'] or cid in actual_cids:
            raise RuntimeError('Recorded source is missing, repeated, or differs from the requested video')
        actual_cids.add(cid)
    raw = subprocess.run([FFMPEG, '-v', 'error', '-i', str(folder / 'screen.mp4'),
        '-vf', 'fps=10,crop=360:90:90:170,scale=120:30', '-pix_fmt', 'gray',
        '-f', 'rawvideo', '-'], capture_output=True, check=True).stdout
    frames = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 30, 120).astype(np.float32)
    delta = np.mean(np.abs(np.diff(frames, axis=0)), axis=(1, 2))
    # The first/last seconds contain poster reveal and controls.
    moving = delta[60:-10] if records else delta[20:320]
    longest = run = 0
    for change in moving:
        run = run + 1 if change < .15 else 0
        longest = max(longest, run)
    result = {'sample': folder.name, 'frames': len(frames),
        'actualCid': cid if records else None,
        'changingFrameFraction': round(float(np.mean(moving >= .15)), 4),
        'longestNearStaticSeconds': round(longest / 10, 2),
        'medianChange': round(float(np.median(moving)), 3),
        'boundary': 'Recorded crop can contain authored static scenes and danmaku; not cold-start timing'}
    results.append(result)
    print(json.dumps(result), flush=True)
    if args.overview:
        row = OUT / f'overview-{number + 1:02d}.jpg'
        subprocess.run([FFMPEG, '-v', 'error', '-y', '-ss', '3', '-i', str(folder / 'screen.mp4'),
            '-vf', 'fps=1/5,crop=540:340:0:0,scale=270:170,tile=7x1',
            '-frames:v', '1', str(row)], check=True)
        overview_rows.append(row)
(OUT / 'recording-analysis.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
if overview_rows:
    command = [FFMPEG, '-v', 'error', '-y']
    for row in overview_rows:
        command.extend(['-i', str(row)])
    command.extend(['-filter_complex', f'vstack=inputs={len(overview_rows)}',
                    '-frames:v', '1', str(OUT / 'continuity-overview.jpg')])
    subprocess.run(command, check=True)
