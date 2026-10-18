"""Summarize classified milestones, without treating them as visible frames."""
import argparse
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('folder', type=Path)
folder = p.parse_args().folder
trace = next((folder/'traces').glob('flutter*'))
events = [json.loads(l) for l in trace.read_text(encoding='utf8').splitlines()]
start = next(e['utcUs'] for e in events if e['event']=='query.primary.begin')
selected = []
for e in events:
    if e['event'] in ['query.primary.begin','query.primary.end','source.open.begin',
            'startup.surfaceHook.begin','startup.surfaceHook.end','startup.mpv',
            'startup.deep','output.stable','ui.frameReady.after','media.buffering']:
        selected.append({'afterQueryMs':round((e['utcUs']-start)/1000,3),
            **{k:v for k,v in e.items() if k in ['event','stage','prefix','occurrence',
                'size','pts','value','positionMs','signature','elapsedMs']}})
native = [json.loads(l) for l in next((folder/'traces').glob('native*')).read_text(encoding='utf8').splitlines()]
first_texture = next((e for e in native if e['event']=='texture.consumed' and
                      e.get('data',{}).get('textureTimestampNs',0)>0), None)
report = {'events':selected,
    'firstNonzeroTextureTimestampAfterQueryMs':
        round((first_texture['utcMs']*1000-start)/1000,3) if first_texture else None,
    'boundary':'Dart log delivery timestamps, except Android texture callback wall clock. Neither proves actual display; HTTP header receipt is not media first byte.',
    'actualMotionSeconds':None}
(folder/'deep-stages.json').write_text(json.dumps(report,indent=2),encoding='utf8')
print(json.dumps(report,indent=2))
