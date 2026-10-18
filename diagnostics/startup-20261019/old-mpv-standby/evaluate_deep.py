"""Save two bounded diagnosis samples; never promote log events to pictures."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
visual = {'d1':(6.898,6.937,7.708),'d2':(4.162,4.197,4.233)}
rows = []
for label,(last_loading,image,motion) in visual.items():
    folder = ROOT / f'diagnostics/startup-20261017/mpv-phase1/old-mpv-deep-{label}-20261019-5'
    events = [json.loads(l) for l in next((folder/'traces').glob('flutter*')).read_text(encoding='utf8').splitlines()]
    first = lambda name:next(e for e in events if e['event']==name)
    stage = lambda name:next(e for e in events if e.get('stage')==name)
    q = first('query.primary.begin')['utcUs']
    decoder = next(e for e in events if e.get('stage')=='decoder.open' and e.get('prefix')=='vd')
    started,input_,output = [stage(n) for n in ['codec.started','codec.input.queued','codec.output.received']]
    assert output['size']>0 and output['pts']==0 and input_['pts']==0
    pid = next((folder/'traces').glob('flutter*')).name.split('-')[1]
    native = (folder/'codec-audio.log').read_text(encoding='utf8')
    codec = {}
    for key,term in [('allocate','allocate('),('created','Created component'),('inputFormat','setup formats input')]:
        line = next(l for l in native.splitlines() if term in l and pid in l.split()[1:3])
        codec[key]=round((float(line.split()[0])*1e6-q)/1000,3)
    played=first('command.play')['utcUs']
    unbuffered=next(e['utcUs'] for e in events if e['utcUs']>played and e['event']=='media.buffering' and not e['value'])
    problems=[{'event':e['event'],'afterQueryMs':(e['utcUs']-q)/1000,'positionMs':e.get('positionMs'),'value':e['value']}
        for e in events if e['utcUs']>unbuffered and ((e['event']=='media.buffering' and e['value']) or (e['event']=='media.playing' and not e['value']))]
    meta=json.loads((OUT/f'old-mpv-deep-{label}-20261019-5-capture.json').read_text(encoding='utf8'))
    pointer=json.loads((folder/'startup-pts.json').read_text())['pointerCandidatePts']
    rows.append({'label':label,'recordingFolder':str(folder),'apkSha256':meta['apkSha256'],
        'coldApp':meta['appForceStoppedBeforeSearch'],'mediaPreloaded':False,
        'pointerPts':pointer,'lastLoadingPts':last_loading,'firstImagePts':image,
        'motionConfirmedPts':motion,'firstImageAfterClickSeconds':round(image-pointer,3),
        'motionConfirmedAfterClickSeconds':round(motion-pointer,3),
        'motionConfirmationIsConservativeUpperBound':True,
        'motionReviewNote':'Wide first scene holds until a jump to a later scene; visible startup discontinuity.' if label=='d1' else 'Car and smoke movement visible in adjacent frames.',
        'apiMs':round((first('query.primary.end')['utcUs']-q)/1000,3),
        'decoderOpenToStartedMs':round((started['utcUs']-decoder['utcUs'])/1000,3),
        'startedToFirstInputMs':round((input_['utcUs']-started['utcUs'])/1000,3),
        'firstInputToFirstOutputMs':round((output['utcUs']-input_['utcUs'])/1000,3),
        'decoderOpenToFirstOutputMs':round((output['utcUs']-decoder['utcUs'])/1000,3),
        'nativeCodecAfterQueryMs':codec,'nativeAllocateToCreatedMs':round(codec['created']-codec['allocate'],3),
        'postInitialBufferPauseEvents':problems,
        'traceSpanSeconds':round((events[-1]['utcUs']-events[0]['utcUs'])/1e6,3),
        'minimumAvailableRamGiB':min(x['availableRamGiB'] for x in meta['memorySamples']),
        'minimumCommitHeadroomGiB':min(x['commitHeadroomGiB'] for x in meta['memorySamples']),
        'boundary':'Classifier events are Dart delivery times, not pure native decode CPU time. Trace instrumentation may affect latency. Do not transfer these durations directly onto the historical 2.446-second recording.'})
    (folder/'deep-stages.json').write_text(json.dumps({**json.loads((folder/'deep-stages.json').read_text()),
        'actualMotionSeconds':round(motion-pointer,3),'actualMotionBoundary':'Manually reviewed conservative motion confirmation'},indent=2))
report={'newVideoTrials':2,'newDistinctVideos':1,'secondsEach':35,'purpose':'Cause diagnosis only; no playback optimization',
    'result':'Input-to-first-output waiting confirmed; pure computation versus queueing, reorder, resets and scheduling not isolated. No new optimization accepted.',
    'continuity':'No post-start buffering or pause flags in bounded logs. d1 visibly holds its first image and jumps; smooth playback is not established. Later ~2-second frame samples cannot exclude brief stalls.',
    'rows':rows}
(OUT/'deep-evaluation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
for row in rows:
    print(json.dumps({k:v for k,v in row.items() if k not in ['recordingFolder','boundary','apkSha256']},ensure_ascii=False))
