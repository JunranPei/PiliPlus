from pathlib import Path
import json
p=Path(__file__).resolve().parent/'r69-audio-bound-cancel-01';c=p/'capture'
r=json.loads((p/'reviewed.json').read_text());m=json.loads((c/'capture.json').read_text());s=m['summary']
events=[json.loads(x)for n in s['traceFiles'] if n.startswith('flutter')for x in(c/'app'/n).read_text(encoding='utf-8').splitlines()]
queue=[{k:v for k,v in e.items() if k in ['event','seq','elapsedUs','requestId','sourceRevision','playerId','cid','reason','actualSeconds','previousSeconds','ownerChanged']}for e in events if e['event'].startswith('startup.audioDecodeQueue.')]
passed=(r['cancelBeforeDrainVerified'] and r['decoderClosed'] and r['returnCleanupPassed'] and len(queue)==2 and queue[0]['event'].endswith('.limited') and queue[1]['event'].endswith('.restored') and queue[1]['reason']=='source-cancelled' and queue[0]['sourceRevision']==queue[1]['sourceRevision'] and queue[0]['playerId']==queue[1]['playerId'] and float(queue[0]['actualSeconds'])==.08 and float(queue[1]['actualSeconds'])==2)
report={'pid':m['pid'],'passed':passed,'nativeEarlyCancel':r['cancelBeforeDrainVerified'],'decoderClosed':r['decoderClosed'],'returnCleanup':r['returnCleanupPassed'],'queueEvents':queue,'priorFailure':'../startup-audio-decode-bound-cancel-01/audio-queue-cancel-events.json','fix':'Restore before owner sourceRevision increments; late request.cancelled callback cannot skip or repeat restoration.'}
(p/'queue-restoration-reviewed.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2));assert passed
