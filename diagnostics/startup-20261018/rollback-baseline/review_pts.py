"""Review original WebM timestamps without FPS resampling or inferred onset."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from PIL import Image, ImageDraw

parser = argparse.ArgumentParser()
parser.add_argument('folder', type=Path)
parser.add_argument('--start', type=float, default=0)
parser.add_argument('--end', type=float, default=9)
parser.add_argument('--stride', type=int, default=6)
parser.add_argument('--name', default='review-pts')
parser.add_argument('--pointer', action='store_true')
args = parser.parse_args()
ffmpeg = 'D:/Program Files/FFmpeg/bin/ffmpeg.exe'
selection = f'between(t,{args.start},{args.end})*not(mod(n,{args.stride}))'.replace(',', r'\,')
result = subprocess.run([ffmpeg, '-v', 'info', '-copyts', '-i', str(args.folder/'screen.webm'),
    '-an', '-vf', f'select={selection},showinfo,crop=540:400:0:80,scale=270:200',
    '-pix_fmt', 'rgb24', '-fps_mode', 'passthrough', '-f', 'rawvideo', '-'], capture_output=True, check=True)
times = [float(x) for x in re.findall(rb'\bn:\s*\d+\s+pts:\s*-?\d+\s+pts_time:([\d.]+)', result.stderr)]
size = 270*200*3
assert len(result.stdout) == len(times)*size
columns = 6
sheet = Image.new('RGB', (columns*270, ((len(times)+columns-1)//columns)*224), '#202020')
draw = ImageDraw.Draw(sheet)
for index, pts in enumerate(times):
    frame = Image.frombytes('RGB', (270,200), result.stdout[index*size:(index+1)*size])
    x,y = index%columns*270, index//columns*224
    sheet.paste(frame,(x,y+24)); draw.text((x+5,y+5),f'original PTS {pts:.3f}',fill='white')
sheet.save(args.folder/(args.name+'.jpg'), quality=90)
metadata={'originalPts':times,'onset':'requires visual review'}
if args.pointer:
    pointer=subprocess.run([ffmpeg,'-v','info','-copyts','-i',str(args.folder/'screen.webm'),
        '-an','-vf',r'select=lt(t\,4),showinfo,crop=540:80:0:0',
        '-pix_fmt','rgb24','-fps_mode','passthrough','-f','rawvideo','-'],capture_output=True,check=True)
    pts=[float(x) for x in re.findall(rb'\bn:\s*\d+\s+pts:\s*-?\d+\s+pts_time:([\d.]+)',pointer.stderr)]
    size=540*80*3
    for i,t in enumerate(pts):
        frame=Image.frombytes('RGB',(540,80),pointer.stdout[i*size:(i+1)*size])
        reds=sum(r>160 and g<90 and b<90 for r,g,b in frame.crop((470,0,540,10)).getdata())
        if reds>35:
            metadata['pointerCandidatePts']=t
            metadata['previousPointerFramePts']=pts[i-1] if i else None
            strip=Image.new('RGB',(540,160),'white')
            if i:strip.paste(Image.frombytes('RGB',(540,80),pointer.stdout[(i-1)*size:i*size]),(0,0))
            strip.paste(frame,(0,80));strip.save(args.folder/'pointer-before-after.png')
            break
(args.folder/(args.name+'.json')).write_text(json.dumps(metadata,indent=2))
print(json.dumps({'sheet':str(args.folder/(args.name+'.jpg')),'frames':len(times)}))
