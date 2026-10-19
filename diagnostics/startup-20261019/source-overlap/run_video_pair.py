"""One new video, two APKs, alternating pair order; no retries for a fast result."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
p = argparse.ArgumentParser()
p.add_argument('index', type=int)
a = p.parse_args()
assert a.index in range(10)
order = ['candidate', 'control'] if a.index % 2 == 0 else ['control', 'candidate']
for mode in order:
    print(json.dumps({'index': a.index, 'mode': mode, 'state': 'start'}), flush=True)
    subprocess.run([sys.executable, str(OUT/'run_trial.py'), mode,
                    f'paired-v{a.index}-{mode}', '--index', str(a.index)], cwd=ROOT, check=True)
    print(json.dumps({'index': a.index, 'mode': mode, 'state': 'captured'}), flush=True)
