"""Measure changes in the recorded video region, excluding most UI/danmaku.

Static authored content and overlapping danmaku still require visual review;
this is supporting evidence, not a decoder stall oracle or cold-start timer.
"""
from pathlib import Path
import json
import subprocess
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'diagnostics/startup-20261016/ten-videos'
FFMPEG = r'D:/Program Files/FFmpeg/bin/ffmpeg.exe'

results = []
for folder in sorted(OUT.glob('[0-9][0-9]-*')):
    raw = subprocess.run([FFMPEG, '-v', 'error', '-i', str(folder / 'screen.mp4'),
        '-vf', 'fps=10,crop=360:90:90:170,scale=120:30', '-pix_fmt', 'gray',
        '-f', 'rawvideo', '-'], capture_output=True, check=True).stdout
    frames = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 30, 120).astype(np.float32)
    delta = np.mean(np.abs(np.diff(frames, axis=0)), axis=(1, 2))
    # The first/last seconds contain poster reveal and controls.
    moving = delta[20:320]
    longest = run = 0
    for change in moving:
        run = run + 1 if change < .15 else 0
        longest = max(longest, run)
    result = {'sample': folder.name, 'frames': len(frames),
        'changingFrameFraction': round(float(np.mean(moving >= .15)), 4),
        'longestNearStaticSeconds': round(longest / 10, 2),
        'medianChange': round(float(np.median(moving)), 3),
        'boundary': 'Recorded crop can contain authored static scenes and danmaku; not cold-start timing'}
    results.append(result)
    print(json.dumps(result), flush=True)
(OUT / 'recording-analysis.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
