from pathlib import Path
import json,hashlib
base=Path(__file__).resolve().parent;out=base/'r69-audio-bound-seek-01';p=out/'capture'
m=json.loads((p/'capture.json').read_text());s=m['summary'];origin=s['inputDispatchMonoNs']
native=[json.loads(l)for n in s['traceFiles']if n.startswith('native')for l in(p/'app'/n).read_text().splitlines()]
up=next(e for e in native if e['event']=='input.touch'and e['data']['action']==1 and e['data']['x']==650 and e['data']['y']==350)
assert any(e['event']=='texture.consumed' and e['monoNs']<up['monoNs'] and 61500000000<=e['data'].get('textureTimestampNs',0)<85000000000 for e in native), 'No actual pre-seek playback'
consumed=[e for e in native if e['event']=='texture.consumed'and e['monoNs']>up['monoNs']]
jump=next(e for e in consumed if e['data']['textureTimestampNs']>85000000000)
after=[e for e in consumed if e['monoNs']>=jump['monoNs']]
pts=[e['data']['textureTimestampNs']for e in after]
assert len(pts)>15 and all(b>=a for a,b in zip(pts,pts[1:])) and pts[-1]-pts[0]>10000000000
callbacks=[];flush=[]
for line in(p/'logcat.txt').read_text(errors='replace').splitlines():
 for marker,dest in [('[DECODE_ONLY] ',callbacks),('[CODEC_FLUSH] ',flush)]:
  if marker in line and line.split()[1]==str(m['pid']):dest.append(json.loads(line.split(marker,1)[1]))
closed=[e for e in callbacks if e['event']=='close'];assert len(closed)==1
c=closed[0];assert c['enabled']==1 and c['applied']>0 and c['applied']==c['eligible']
seeking=[e for e in flush if e['event']=='flush.begin'and up['monoNs']<=e['monoNs']<jump['monoNs'] and e['receiveStarted']]
assert len(seeking)==2 and all(e['skipped']==0 for e in seeking)
durations=[(next(x['monoNs']for x in flush if x['event']=='flush.end'and x['ordinal']==e['ordinal'])-e['monoNs'])/1e6 for e in seeking]
report={'passed':True,'pid':m['pid'],'gestureReleaseAfterInputMs':(up['monoNs']-origin)/1e6,'firstNewPositionAfterGestureMs':(jump['monoNs']-up['monoNs'])/1e6,'firstPostSeekPtsSeconds':pts[0]/1e9,'lastPostSeekPtsSeconds':pts[-1]/1e9,'postSeekObservedPoints':len(pts),'postSeekMonotonicPts':True,'actualSeekFlushes':durations,'decodeOnlyClose':c,'returnCleanup':json.loads((p/'return-cleanup-reviewed.json').read_text()),'boundary':'Listener-based actual horizontal seek on round69 plus bounded startup audio queue, then>10s observed progress and return; no pixel-content equivalence claim. Not included in startup performance cohort.'}
(out/'seek-reviewed.json').write_text(json.dumps(report,indent=2))
print(json.dumps({k:report[k]for k in ['passed','pid','firstNewPositionAfterGestureMs','firstPostSeekPtsSeconds','lastPostSeekPtsSeconds','decodeOnlyClose']}),flush=True)
