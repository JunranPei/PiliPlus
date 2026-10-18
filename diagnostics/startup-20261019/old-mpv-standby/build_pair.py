"""Build the controlled historical pair sequentially while the emulator is off."""
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).resolve().parent
for label,extra in [('control',['--control']),('standby',[])]:
    print('BUILDING '+label,flush=True)
    subprocess.run([sys.executable,str(ROOT/'tool/build_startup_standby.py'),
        '--output',str(OUT/f'old-mpv-{label}.apk'),*extra],cwd=ROOT,check=True)
print('BOTH HISTORICAL VARIANTS BUILT',flush=True)
