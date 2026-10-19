"""Build two serial candidates with identical standby and trace configuration."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
for mode, flags in [('control', []), ('candidate', ['--early-source'])]:
    subprocess.run([sys.executable, str(ROOT/'tool/build_startup_standby.py'),
        '--output', str(OUT/f'source-overlap-{mode}.apk'), *flags], cwd=ROOT, check=True)
