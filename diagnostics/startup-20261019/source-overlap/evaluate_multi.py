"""Evaluate the fixed ten-video cohort without filling unreviewed visual times."""
import json
from pathlib import Path
import re
from statistics import median

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
videos = json.loads((ROOT/'diagnostics/startup-20261016/videos.json').read_text(encoding='utf8'))
review = {(r['index'], r['mode']): r for r in json.loads((OUT/'visual-review.json').read_text())['rows']}
rows, pending, failed = [], [], []
for index, video in enumerate(videos):
    for mode in ['control', 'candidate']:
        label = f'source-overlap-paired-v{index}-{mode}-20261019-{index}'
        folder = ROOT/'diagnostics/startup-20261017/mpv-phase1'/label
        if not (folder/'result.json').exists():
            pending.append(label)
            continue
        result = json.loads((folder/'result.json').read_text(encoding='utf8'))
        if video['cid'] not in result['observedOpenedCids']:
            failed.append(label)
            continue
        meta = json.loads((OUT/(label+'-capture.json')).read_text())
        assert meta['appForceStoppedBeforeSearch'] and meta['searchUriVerifiedBeforeTiming']
        manifest = json.loads((OUT/f'source-overlap-{mode}.build.json').read_text())
        assert manifest['sha256'] == meta['apkSha256']
        trace = next((folder/'traces').glob('flutter*'))
        pid = trace.name.split('-')[1]
        events = [json.loads(s) for s in trace.read_text(encoding='utf8').splitlines()]
        first = lambda name: next(e for e in events if e['event'] == name)
        query = first('query.primary.begin')['utcUs']
        opened = first('source.open.begin')
        play = first('command.play')['utcUs']
        unbuffered = next((e for e in events if e['event']=='media.buffering'
                          and not e['value'] and e['utcUs'] > play), None)
        problems = [{'event': e['event'], 'positionMs': e.get('positionMs'),
                     'afterQueryMs': round((e['utcUs']-query)/1000, 3), 'value': e['value']}
                    for e in events if unbuffered and e['utcUs'] > unbuffered['utcUs'] and
                    ((e['event']=='media.buffering' and e['value']) or
                     (e['event']=='media.playing' and not e['value']))]
        own = lambda text: '\n'.join(l for l in text.splitlines() if re.search(r'\s'+pid+r'\s+'+pid+r'\s+I flutter', l))
        before = own((folder/'pre-click-output.log').read_text(encoding='utf8'))
        log = own((folder/'playback.log').read_text(encoding='utf8'))
        ready = re.search(r'\[OUTPUT_STANDBY\] \d+ ready \{wid: (\d+), currentVo: mediacodec_embed, configured: yes, mediaCount: 0', before)
        handoff = re.search(r'\[OUTPUT_STANDBY\] \d+ handoff \{wid: (\d+)\}', log)
        params = next((e['params'] for e in events if e['event']=='media.videoParams'
                       and (e.get('params', {}).get('w') or 0) > 1
                       and e.get('params', {}).get('pixelformat') != 'rgba'), None)
        ms = lambda name: round((first(name)['utcUs']-query)/1000, 3)
        visual = review.get((index, mode))
        pointer = json.loads((folder/'startup-pts.json').read_text())['pointerCandidatePts'] if visual else None
        row = dict(index=index, mode=mode, bvid=video['bvid'], cid=video['cid'],
            apkSha256=meta['apkSha256'], apiMs=ms('query.primary.end'),
            uiMountRequestMs=ms('ui.mount.request'), sourceOpenBeginMs=ms('source.open.begin'),
            sourceOpenAcceptedMs=ms('source.open.accepted'), mediaAndPageJoinedMs=ms('source.open.return'),
            commandPlayMs=ms('command.play'), coverReleasedMs=ms('ui.frameReady.after'),
            realVideoParams=params, sameStandbySurfaceHandedOff=bool(ready and handoff and ready[1]==handoff[1]),
            initialBufferEnded=bool(unbuffered), postInitialBufferPauseEvents=problems,
            traceSpanSeconds=round((events[-1]['utcUs']-events[0]['utcUs'])/1e6, 3),
            minimumAvailableRamGiB=min(s['availableRamGiB'] for s in meta['memorySamples']),
            minimumCommitHeadroomGiB=min(s['commitHeadroomGiB'] for s in meta['memorySamples']),
            visualReview=visual, pointerPts=pointer,
            firstImageAfterClickSeconds=round(visual['firstImagePts']-pointer, 3) if visual else None,
            confirmedMotionAfterClickSeconds=round(visual['motionPts']-pointer, 3) if visual else None)
        rows.append(row)
pairs=[]
for index in range(10):
    rs={r['mode']:r for r in rows if r['index']==index and r['visualReview']}
    if len(rs)==2:
        pairs.append(dict(index=index, controlSeconds=rs['control']['confirmedMotionAfterClickSeconds'],
            candidateSeconds=rs['candidate']['confirmedMotionAfterClickSeconds'],
            candidateMinusControlSeconds=round(rs['candidate']['confirmedMotionAfterClickSeconds']-rs['control']['confirmedMotionAfterClickSeconds'],3)))
data=dict(plannedTrials=20, validCapturedTrials=len(rows), distinctCapturedVideos=len(set(r['index'] for r in rows)),
    reviewedTrials=sum(r['visualReview'] is not None for r in rows), reviewedPairs=len(pairs),
    pending=pending, failedTargetTrials=failed, excludedInputFailure='source-overlap-v0-candidate-20261019-0 (truncated CID, -404)',
    pairs=pairs, rows=rows, acceptedPerformanceFix=False,
    boundary='One new emulator boot, fixed ten videos, alternating order, cold App, verified search URI, no media preload. Do not pool means with the earlier four trials. Picture timing requires original-frame inspection. Delivered logs do not measure native first bytes or exact decode execution.')
data['status'] = 'Stopped after five completed pairs: four did not improve; no stable benefit, no ten-video acceptance claim.'
data['unrunPairsAreSkippedAfterFutility'] = True
if pairs:
    data['reviewedPairMedianCandidateMinusControlSeconds']=median(r['candidateMinusControlSeconds'] for r in pairs)
    data['reviewedCandidateFasterVideos']=sum(r['candidateMinusControlSeconds']<0 for r in pairs)
if len(pairs)==10:
    data['medianCandidateMinusControlSeconds']=median(r['candidateMinusControlSeconds'] for r in pairs)
    data['candidateFasterVideos']=sum(r['candidateMinusControlSeconds']<0 for r in pairs)
(OUT/'multi-evaluation.json').write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps({k:data[k] for k in ['validCapturedTrials','distinctCapturedVideos','reviewedTrials','reviewedPairs','pairs']},ensure_ascii=False))
