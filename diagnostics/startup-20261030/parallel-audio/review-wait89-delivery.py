from pathlib import Path
import json,collections
b=Path(__file__).resolve().parent;o=b/'async-wait-stacked-observed-01';reports=[]
for r in json.loads((o/'completed-samples.json').read_text()):
 p=o/r['label'];m=json.loads((p/'capture.json').read_text());s=m['summary'];events=[json.loads(l)for n in s['traceFiles']if n.startswith('flutter')for l in(p/'app'/n).read_text().splitlines()]
 opened=next(e for e in events if e['event']=='source.open.begin'and e.get('playerId')==s['sourceIdentity']['playerId']);openms=next(e['afterInputMs']for e in s['milestones']if e['event']=='source.open.begin')
 out=[]
 for e in events:
  ms=openms+(e['elapsedUs']-opened['elapsedUs'])/1000
  if not 0<=ms<=min(r['textureMs']+500,5000):continue
  if e['event'].startswith('isolated.') and any(k in e['event']for k in ['warmup','prefetch','resume.','read.end','read.begin','range.']):
   out.append({k:v for k,v in e.items()if k not in ['source','utcUs','elapsedUs','seq','workerUtcUs','requestId','cid','url','headers','authorizedUrls']}|{'afterInputMs':ms})
 report={'label':r['label'],'textureMs':r['textureMs'],'waitNs':r['waitCounters']['waitNs'],'events':out};reports.append(report)
(o/'delivery-timeline-reviewed.json').write_text(json.dumps(reports,indent=2))
print(json.dumps([{'label':r['label'],'events':r['events'][:8],'eventNames':dict(collections.Counter(e['event']for e in r['events']))}for r in reports if r['label']=='04-candidate'],indent=2))
