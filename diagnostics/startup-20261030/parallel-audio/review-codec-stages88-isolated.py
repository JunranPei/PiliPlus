from pathlib import Path
import csv,json,collections
b=Path(__file__).resolve().parent;cap=b/'codec-stages-native-spans-02/capture';out=cap/'time-attribution-01'
m=json.loads((cap/'capture.json').read_text());s=json.loads((out/'summary.json').read_text());origin=m['summary']['inputDispatchMonoNs']+s['clockOffsetNs'];tid=s['decoderTid']
spans=list(csv.DictReader((out/'spans.csv').read_text().splitlines()));states=list(csv.DictReader((out/'states.csv').read_text().splitlines()))
for r in spans+states:
 for k in ['ts','dur','tid']:r[k]=int(r[k])
 r['end']=r['ts']+r['dur']
send=[r for r in spans if r['tid']==tid and r['name'].startswith('pili.avcodec_send')]
stages=[r for r in spans if r['tid']==tid and r['name'].startswith('pili.codec.')]
assert send and stages
def state_ms(a,z,t):
 agg=collections.defaultdict(float)
 for r in states:
  if r['tid']==t:agg[r['state']]+=max(0,min(z,r['end'])-max(a,r['ts']))/1e6
 return {k:v for k,v in agg.items()if v}
agg={};timeline=[]
for call in send:
 overlaps=[r for r in stages if r['ts']<call['end']and r['end']>call['ts']]
 cuts=sorted({call['ts'],call['end'],*[max(call['ts'],r['ts'])for r in overlaps],*[min(call['end'],r['end'])for r in overlaps]})
 for a,z in zip(cuts,cuts[1:]):
  active=[r for r in overlaps if r['ts']<=a and r['end']>=z]
  key=max(active,key=lambda r:int(r['depth']))['name'].split(' ')[0]if active else 'send.other'
  v=agg.setdefault(key,{'wallMs':0,'statesMs':collections.defaultdict(float)});v['wallMs']+=(z-a)/1e6
  for k,x in state_ms(a,z,tid).items():v['statesMs'][k]+=x
  timeline.append({'label':key,'afterInputMs':(a-origin)/1e6,'durationMs':(z-a)/1e6,'statesMs':state_ms(a,z,tid)})
total=sum(r['dur']for r in send)/1e6;assert abs(sum(v['wallMs']for v in agg.values())-total)<.001
counts=collections.Counter(r['name'].split(' ')[0]for r in stages)
report={'diagnosticOnly':True,'pid':m['pid'],'decoderTid':tid,'inputWorkerTid':s['inputSubmissionTid'],'sendWallMs':total,'sendExclusiveStages':agg,'allStageCounts':counts,'longestSubcalls':[dict(r,afterInputMs=(r['ts']-origin)/1e6,durationMs=r['dur']/1e6,statesMs=state_ms(r['ts'],r['end'],tid))for r in sorted(stages,key=lambda r:-r['dur'])[:20]],'timeline':timeline,'traceIssues':s['traceIssues'],'scope':'Exact exclusive avcodec_send partition on decoder owner. sleep/runnable not equivalent to avoidable delay. Extra subcall traces are diagnostic overhead; do not include this elapsed in87 lean comparisons.'}
(out/'codec-stages-reviewed.json').write_text(json.dumps(report,indent=2))
print(json.dumps({k:report[k]for k in ['decoderTid','inputWorkerTid','sendWallMs','sendExclusiveStages','allStageCounts','traceIssues']},indent=2))
