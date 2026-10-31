from pathlib import Path
import json
BASE=Path(__file__).resolve().parent
OUT=BASE/'r69-audio-bound-callback-observed-01'
reports=[]
for row in json.loads((OUT/'completed-samples.json').read_text()):
    folder=OUT/row['label'];m=json.loads((folder/'capture.json').read_text());summary=m['summary']
    events=[json.loads(line)for name in summary['traceFiles']if name.startswith('flutter')for line in(folder/'app'/name).read_text().splitlines()]
    opened=next(e for e in events if e['event']=='source.open.begin'and e.get('playerId')==summary['sourceIdentity']['playerId'])
    video=[]
    for e in events:
        ms=row['openMs']+(e['elapsedUs']-opened['elapsedUs'])/1000
        if e['event'].startswith('isolated.video.resume.')and 0<=ms<=row['textureMs']+100:
            video.append({k:v for k,v in e.items()if k not in ['source','utcUs','elapsedUs','seq','workerUtcUs','requestId','cid','url','headers','authorizedUrls']}|{'afterInputMs':ms})
    reports.append({'label':row['label'],'textureMs':row['textureMs'],'firstReceiveMs':row['firstReceiveMs'],'events':video})
(OUT/'delivery-reviewed.json').write_text(json.dumps(reports,indent=2))
for r in reports:
    first=next((e for e in r['events']if e['event'].endswith('bodyWarmup.firstChunk')),None)
    claim=next((e for e in r['events']if e['event'].endswith('bodyWarmup.claim')),None)
    progress=[e for e in r['events']if e['event'].endswith('body.progress')and e['afterInputMs']<r['textureMs']]
    last=progress[-1]if progress else None
    print(json.dumps({'label':r['label'],'textureMs':r['textureMs'],'firstReceiveMs':r['firstReceiveMs'],
        'firstBodyMs':first['afterInputMs']if first else None,'claimBytes':claim.get('prefetchedBytes')if claim else None,
        'lastPreframeBytes':last.get('receivedBytes')if last else None,'lastPreframeProgressMs':last['afterInputMs']if last else None,
        'workerBodyElapsedMs':(last['workerElapsedUs']-first['workerElapsedUs'])/1000 if last and first else None}))
