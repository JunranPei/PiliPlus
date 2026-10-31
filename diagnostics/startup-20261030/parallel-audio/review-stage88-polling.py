from pathlib import Path
import csv,json,collections
b=Path(__file__).resolve().parent;o=b/'codec-stages-native-spans-02/capture/time-attribution-01'
s=json.loads((o/'summary.json').read_text());tid=s['decoderTid'];rows=list(csv.DictReader((o/'spans.csv').read_text().splitlines()))
for r in rows:
 for k in ['ts','dur','tid']:r[k]=int(r[k])
release=next(r for r in rows if r['name']=='MediaCodec::releaseOutputBuffer#native')
first=next(r for r in rows if r['name']=='pili.codec.input.submit'and r['tid']==tid)
group=collections.defaultdict(lambda:{'count':0,'wallMs':0})
for r in rows:
 if r['tid']==tid and r['name'].startswith('pili.codec.'):
  period='beforeFirstReleasedPreroll'if r['ts']<release['ts']else'afterFirstReleasedPreroll'
  v=group[period+' / '+r['name'].split(' bytes=')[0]];v['count']+=1;v['wallMs']+=r['dur']/1e6
report={'firstInputToFirstPrerollReleaseMs':(release['ts']-first['ts'])/1e6,'stages':group,'boundary':'First actual unrendered preroll release is after first decoded output; extra poll count may reflect scheduler/tracing. Runtime wait switch already exists; test unchanged87 APK with only callback_wait toggled on top of async1/audioBound, rather than extrapolating old72.'}
(o/'polling-reviewed.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
