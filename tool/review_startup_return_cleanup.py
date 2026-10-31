"""Review source-matched track closure after the recorded return operation."""
import hashlib
import json
from pathlib import Path
import re
import sys

folder = Path(sys.argv[1]).resolve()
metadata = json.loads((folder/'capture.json').read_text(encoding='utf-8'))
summary = metadata['summary']
assert metadata.get('backSentAfterSeconds') and not metadata['errors']
identity = summary['sourceIdentity']
name = next(name for name in summary['traceFiles'] if name.startswith('flutter-'))
events = [json.loads(line) for line in (folder/'app'/name).read_text(encoding='utf-8').splitlines()]
opens = [event for event in events if event['event']=='source.open.begin'
         and event.get('playerId')==identity['playerId'] and event.get('cid')==identity['cid']]
assert len(opens)==1
after = [event for event in events if event['seq']>opens[0]['seq']]
leaves = [event for event in after if event['event']=='route.leave' and event.get('cid')==identity['cid']]
assert leaves
closed = [event for event in after if event['event'] in ('isolated.video.closed','isolated.audio.closed','isolated.closed')
          and event.get('cid')==identity['cid'] and event.get('requestId')==identity['requestId']]
assert len(closed)==3 and all(event['elapsedUs']>=leaves[0]['elapsedUs'] for event in closed)
assert any(event.get('expected') is True for event in closed)
active = [int(value) for value in re.findall(r'Tracks of which (\d+) are active',
          (folder/'audio-flinger.txt').read_text(encoding='utf-8'))]
assert active and all(value==0 for value in active)
report = {'passed':True,'sourceIdentity':identity,'sourceOpenSequence':opens[0]['seq'],
          'firstRouteLeaveSequence':leaves[0]['seq'],'closure':closed,'activeAudioTrackCounts':active,
          'closeAfterLeaveMs':[(event['elapsedUs']-leaves[0]['elapsedUs'])/1000 for event in closed],
          'reviewerSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
with (folder/'return-cleanup-reviewed.json').open('x',encoding='utf-8') as output:
    json.dump(report,output,indent=2)
print(json.dumps({'capture':folder.name,'passed':True,'closeAfterLeaveMs':report['closeAfterLeaveMs']}))
