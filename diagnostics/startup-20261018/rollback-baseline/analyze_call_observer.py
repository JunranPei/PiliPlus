"""Pair explicit begin/end timestamps from the temporary call observer."""
import argparse
import json
from pathlib import Path
import re

p = argparse.ArgumentParser()
p.add_argument('folder', type=Path)
folder=p.parse_args().folder
log=(folder/'playback.log').read_text(encoding='utf-8')
marker=float(next(line for line in log.splitlines() if 'open-request' in line).split()[0])*1e6
pending={}; calls=[]
for utc,id,phase,name,args in re.findall(r'\[SURFACE_CALL\] (\d+) (\d+) (begin|end) (\S+) (.*)',log):
    if phase=='begin': pending[id]=(int(utc),name,args.strip())
    elif id in pending:
        start,name,args=pending.pop(id)
        calls.append({'id':int(id),'call':name,'args':args,'beginMs':round((start-marker)/1000,2),'durationMs':round((int(utc)-start)/1000,2)})
assert calls,'No call observers found'
events=[]
for f in (folder/'traces').glob('flutter*'):
    for line in f.open(encoding='utf-8'):
        e=json.loads(line)
        if e['utcUs']<marker: continue
        if e['event'] in ('media.videoParams','source.prepare.begin','command.play','source.gate.ready','output.stable','ui.frameReady.after','timing.preferences.begin','timing.preferences.end','timing.api.request.begin','timing.api.request.end','source.open.begin','timing.buffering','timing.mpv'):
            events.append({'event':e['event'],'ms':round((e['utcUs']-marker)/1000,2),**{k:v for k,v in e.items() if k in ('params','value','stage','prefix','playerId','previous')}})
report={'calls':calls,'unpairedCalls':pending,'events':events,'requestMarkerBoundary':'before adb input tap; exact motion timing requires original WebM PTS review'}
(folder/'call-durations.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'calls':calls,'unpairedCalls':pending},ensure_ascii=False,indent=1))
