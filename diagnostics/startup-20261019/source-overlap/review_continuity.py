"""Produce timestamped later-frame sheets for inspected completed pairs."""
from pathlib import Path
import subprocess
import sys
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
helper = ROOT/'diagnostics/startup-20261018/rollback-baseline/review_pts.py'
for index in range(5):
    parts=[]
    for mode in ['control','candidate']:
        folder=ROOT/f'diagnostics/startup-20261017/mpv-phase1/source-overlap-paired-v{index}-{mode}-20261019-{index}'
        subprocess.run([sys.executable,str(helper),str(folder),'--start','10','--end','35',
                        '--stride','60','--name','continuity-pts'],check=True,capture_output=True)
        with Image.open(folder/'continuity-pts.jpg') as src:
            sheet=Image.new('RGB',(src.width,src.height+28),'black')
            sheet.paste(src,(0,28)); ImageDraw.Draw(sheet).text((8,8),f'video {index} {mode}',fill='white')
            parts.append(sheet)
    result=Image.new('RGB',(max(p.width for p in parts),sum(p.height for p in parts)),'black')
    top=0
    for part in parts:
        result.paste(part,(0,top)); top+=part.height
    result.save(OUT/f'continuity-pair-{index}.jpg')
    print(f'pair {index} ready for visual review',flush=True)
