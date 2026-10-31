"""Separate output-state observation, stability completion and cover readiness."""
import hashlib
import json
from pathlib import Path
import statistics
import sys

folder=Path(sys.argv[1]).resolve()
rows=[]
for label in ['01-control','02-candidate','03-candidate','04-control','05-control','06-candidate']:
    run=folder/label
    summary=json.loads((run/'summary.json').read_text(encoding='utf-8'))
    identity=summary['sourceIdentity']
    events=[json.loads(line) for name in summary['traceFiles'] if name.startswith('flutter-')
            for line in (run/'app'/name).read_text(encoding='utf-8').splitlines()]
    same=[event for event in events if all(event.get(key)==identity[key]
          for key in ['cid','requestId','sourceRevision','playerId'])]
    waits=[event for event in same if event['event']=='output.stable.wait']
    stable=[event for event in same if event['event']=='output.stable']
    assert len(waits)==1 and len(stable)==1
    start,end=waits[0],stable[0]
    parameters=[event for event in same if event['event']=='media.videoParams'
                and event.get('params',{}).get('dw') and event['elapsedUs']<=end['elapsedUs']]
    assert parameters
    params=parameters[-1]
    times={event['event']:event['afterInputMs'] for event in summary['milestones']}
    row={'run':label,'kind':label.split('-')[1],
         'waitToStableMs':(end['elapsedUs']-start['elapsedUs'])/1000,
         'validParametersToStableMs':(end['elapsedUs']-params['elapsedUs'])/1000,
         'parametersAfterWaitMs':(params['elapsedUs']-start['elapsedUs'])/1000,
         'parametersSnapshotSameRectAsStable':params.get('textureRect')==end.get('textureRect'),
         'parametersSnapshotSameDecodedSizeAsStable':params.get('decodedDisplaySize')==end.get('decodedDisplaySize'),
         'revealAfterPositiveTextureMs':times['ui.frameReady.after']-summary['firstChangedTextureConsumedAfterInputMs'],
         'reportedObservations':end.get('samples'),'eventDriven':end.get('eventDriven',False),
         'stabilityMode':end.get('stabilityMode','three-timer-observations'),
         'waitSequence':start['seq'],'parametersSequence':params['seq'],'stableSequence':end['seq']}
    rows.append(row)
keys=['waitToStableMs','validParametersToStableMs','parametersAfterWaitMs','revealAfterPositiveTextureMs']
report={'rows':rows,'medians':{kind:{key:statistics.median(row[key] for row in rows if row['kind']==kind)
                                  for key in keys} for kind in ['control','candidate']},
        'boundary':'Source-matched Dart event snapshots, not proof of a physical resize or presentation fence. Use snapshot equality fields before attributing the interval entirely to stability checking.',
        'reviewerSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
with (folder/'output-stability-stages.json').open('x',encoding='utf-8') as output:
    json.dump(report,output,indent=2)
print(json.dumps(report['medians'],indent=2))
