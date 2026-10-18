"""Record mechanism evidence separately from manually reviewed motion timing."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).resolve().parent
BASE=ROOT/'diagnostics/startup-20261018/rollback-baseline'
visual={
    # Label, last cover PTS, first media image PTS, unequivocal motion confirmation.
    'home-control':(5.279,5.319,5.489),
    'b1':(4.460,4.493,4.526),
    'b2':(4.377,4.412,4.446),
    'a2':(4.381,4.419,4.653),
}
rows=[]
for label,(last_cover,image,motion) in visual.items():
    p=ROOT/f'diagnostics/startup-20261017/mpv-phase1/gpu-standby-{label}-20261019-5'
    subprocess.run([sys.executable,str(BASE/'analyze_call_observer.py'),str(p)],check=True,capture_output=True)
    trace=next((p/'traces').glob('flutter*'));pid=trace.name.split('-')[1]
    es=[json.loads(l) for l in trace.open(encoding='utf8')]
    def first(name):return next(e for e in es if e['event']==name)
    def elapsed(a,b):return round((first(b)['utcUs']-first(a)['utcUs'])/1000,3)
    opened=first('source.open.begin');op=opened['utcUs']
    pointer=json.loads((p/'startup-pts.json').read_text())['pointerCandidatePts']
    played=next(e['utcUs'] for e in es if e['event']=='media.playing' and e['value'])
    problems=[e for e in es if e['utcUs']>played and
              ((e['event']=='media.playing' and not e['value']) or (e['event']=='timing.buffering' and e['value']))]
    def own_lines(text):return '\n'.join(l for l in text.splitlines() if re.search(r'\s'+pid+r'\s+'+pid+r'\s+I flutter',l))
    pre=own_lines((p/'pre-click-output.log').read_text(encoding='utf8'))
    playback=own_lines((p/'playback.log').read_text(encoding='utf8'))
    warm=label.startswith('b')
    ready=re.search(r'\[GPU_STANDBY\] (\d+) ready \{wid: (\d+), currentVo: gpu, configured: yes, mediaCount: 0, playing: false',pre)
    handoff=re.search(r'\[GPU_STANDBY\] (\d+) handoff \{wid: (\d+)\}',playback)
    params=[{'afterOpenMs':round((e['utcUs']-op)/1000,3),**e['params']} for e in es
            if e['event']=='media.videoParams' and e.get('params',{}).get('w')==1920]
    calls=json.loads((p/'call-durations.json').read_text(encoding='utf8'))['calls']
    row={'label':label,'mode':'gpu-standby' if warm else 'control','pid':pid,'playerId':opened['playerId'],
         'recording':str(p),'appColdStarted':True,'mediaPreloaded':False,
         'pointerPts':pointer,'lastCoverPts':last_cover,'firstImagePts':image,'motionConfirmedPts':motion,
         'firstImageAfterClickSeconds':round(image-pointer,3),'motionConfirmedAfterClickSeconds':round(motion-pointer,3),
         'motionIsConservativeConfirmationUpperBound':True,
         'apiMs':elapsed('timing.api.request.begin','timing.api.request.end'),
         'openToUiReadyMs':elapsed('source.open.begin','ui.frameReady.after'),
         'realResolutionParams':params,'sameStandbySurfaceHandedOff':bool(ready and handoff and ready[2]==handoff[2]),
         'postClickSurfaceCreates':[c for c in calls if c['call']=='VideoOutputManager.CreateSurface'],
         'postClickVoSets':[c for c in calls if c['call']=='setOption' and c['args'].startswith('vo=')],
         'postPlayBufferOrPauseEvents':problems,
         'boundedTraceSpanSeconds':round((es[-1]['utcUs']-es[0]['utcUs'])/1e6,3),
         'continuity':'35-second recording; startup frame review plus ~2-second later samples. Bounded trace shows no post-play pause/buffering; later brief stalls not ruled out.'}
    if warm:
        assert row['sameStandbySurfaceHandedOff'] and not row['postClickSurfaceCreates']
        assert params and all(e['pixelformat']=='mediacodec' for e in params)
        assert 'discarded-on-unload' not in playback
    native=(p/'codec-audio.log').read_text(encoding='utf8')
    native_points={}
    for tag,term in [('allocate','allocate('),('created','Created component'),('inputFormatLogged','setup formats input')]:
        line=next(l for l in native.splitlines() if term in l and re.search(r'\s'+pid+r'\s',l))
        native_points[tag]=round((float(line.split()[0])*1e6-op)/1000,3)
    row['nativeCodecMarkersAfterOpenMs']=native_points
    row['nativeAllocateToCreatedMs']=round(native_points['created']-native_points['allocate'],3)
    metadata=json.loads((OUT/f'gpu-standby-{label}-20261019-5-capture.json').read_text())
    row['minimumHostCommitHeadroomGiB']=min(s['commitHeadroomGiB'] for s in metadata['memorySamples'])
    rows.append(row)
    print(json.dumps({k:row[k] for k in ['label','firstImageAfterClickSeconds','motionConfirmedAfterClickSeconds','apiMs','openToUiReadyMs','sameStandbySurfaceHandedOff','nativeAllocateToCreatedMs']}))

(OUT/'evaluation.json').write_text(json.dumps({'validVideoTrials':4,'distinctVideos':1,'homeProbes':1,
    'order':['control','gpu-standby','gpu-standby','control'],
    'labelNote':'home-control is the first VIDEO control capture, despite its label; it is not a homepage probe.',
    'mechanism':'Idle GPU output configured and first-load handoff confirmed in both candidates; no software-to-hardware transition in candidate params.',
    'acceptance':'Mechanism works, candidate timings promising but small and within broad control variation. Stable end-to-end benefit remains unproven; no ten-video extension or production adoption.',
    'rows':rows},ensure_ascii=False,indent=2),encoding='utf8')
