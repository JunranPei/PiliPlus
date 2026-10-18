"""Separate reviewed WebM timing from delivered mpv milestones and codec logs."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
# Reviewed at original PTS. Motion is a conservative confirmation upper bound.
VISUAL = {'a1r': (6.472, 6.505, 6.639),
          'b1': (3.842, 3.879, 3.913),
          'b2': (4.768, 4.802, 4.834),
          'a2': (3.350, 3.384, 3.453)}
rows = []
for label, (last_loading, image, motion) in VISUAL.items():
    folder = ROOT / f'diagnostics/startup-20261017/mpv-phase1/old-mpv-standby-{label}-20261019-5'
    trace = next((folder / 'traces').glob('flutter*'))
    pid = trace.name.split('-')[1]
    events = [json.loads(line) for line in trace.read_text(encoding='utf8').splitlines()]
    first = lambda name: next(e for e in events if e['event'] == name)
    query = first('query.primary.begin')['utcUs']
    opened = first('source.open.begin')
    op = opened['utcUs']
    pointer = json.loads((folder / 'startup-pts.json').read_text())['pointerCandidatePts']
    own = lambda txt: '\n'.join(l for l in txt.splitlines() if re.search(r'\s' + pid + r'\s+' + pid + r'\s+I flutter', l))
    before = own((folder / 'pre-click-output.log').read_text(encoding='utf8'))
    log = own((folder / 'playback.log').read_text(encoding='utf8'))
    ready = re.search(r'\[OUTPUT_STANDBY\] (\d+) ready \{wid: (\d+), currentVo: mediacodec_embed, configured: yes, mediaCount: 0, playing: false', before)
    handoff = re.search(r'\[OUTPUT_STANDBY\] (\d+) handoff \{wid: (\d+)\}', log)
    claimed = re.search(r'\[PLAYER_STANDBY\] (\d+) claimed \{playerId: (\d+), mediaCount: 0\}', log)
    pending, calls = {}, []
    for utc, ident, phase, name, args in re.findall(r'\[SURFACE_CALL\] (\d+) (\d+) (begin|end) (\S+) (.*)', log):
        if phase == 'begin':
            pending[ident] = (int(utc), name, args)
        elif ident in pending:
            start, name, args = pending.pop(ident)
            calls.append({'call': name, 'args': args, 'afterQueryMs': (start-query)/1000,
                          'durationMs': (int(utc)-start)/1000})
    native = (folder / 'codec-audio.log').read_text(encoding='utf8')
    codec = {}
    for name, term in [('allocate','allocate('), ('created','Created component'), ('inputFormat','setup formats input')]:
        line = next(l for l in native.splitlines() if term in l and re.search(r'\s'+pid+r'\s', l))
        codec[name] = round((float(line.split()[0])*1e6-query)/1000, 3)
    params = next(e for e in events if e['event']=='media.videoParams' and e.get('params',{}).get('w')==1920)
    # Startup playing=true while buffering is not continuous playback. Detect
    # renewed buffering or pause only after initial buffering has ended.
    unbuffered = next(e for e in events if e['utcUs']>op and e['event']=='media.buffering' and not e['value'] and e['utcUs']>first('command.play')['utcUs'])
    problems = [{'event': e['event'], 'afterQueryMs': (e['utcUs']-query)/1000,
                 'value': e['value'], 'positionMs': e.get('positionMs')}
                for e in events if e['utcUs']>unbuffered['utcUs'] and
                ((e['event']=='media.buffering' and e['value']) or
                 (e['event']=='media.playing' and not e['value']))]
    meta = json.loads((OUT / f'old-mpv-standby-{label}-20261019-5-capture.json').read_text())
    row = {'label':label, 'mode':'standby' if label.startswith('b') else 'control',
           'pid':pid, 'playerId':opened['playerId'], 'apkSha256':meta['apkSha256'],
           'coldApp':meta['appForceStoppedBeforeSearch'], 'mediaPreloaded':False,
           'pointerPts':pointer, 'lastLoadingOrCoverPts':last_loading,
           'firstImagePts':image, 'confirmedMotionPts':motion,
           'firstImageAfterClickSeconds':round(image-pointer,3),
           'confirmedMotionAfterClickSeconds':round(motion-pointer,3),
           'motionIsConservativeConfirmationUpperBound':True,
           'apiMs':round((first('query.primary.end')['utcUs']-query)/1000,3),
           'apiEndToOpenMs':round((op-first('query.primary.end')['utcUs'])/1000,3),
           'openToRealResolutionParamsMs':round((params['utcUs']-op)/1000,3),
           'milestonesAfterQueryMs':[{'event':e['event'], 'stage':e.get('stage'),
               'ms':round((e['utcUs']-query)/1000,3)} for e in events if
               e['event'] in ['source.open.begin','startup.player.create.begin','startup.player.create.end',
                   'startup.videoController.create.begin','startup.videoController.create.end',
                   'startup.surfaceHook.begin','startup.surfaceHook.end','command.play',
                   'output.stable','ui.frameReady.after','startup.mpv']],
           'sameStandbySurfaceHandedOff':bool(ready and handoff and ready[2]==handoff[2]),
           'sameStandbyPlayerClaimed':bool(claimed and int(claimed[2])==opened['playerId']),
           'postClickCalls':calls, 'codecMarkersAfterQueryMs':codec,
           'allocateToCreatedMs':round(codec['created']-codec['allocate'],3),
           'postInitialBufferPauseEvents':problems,
           'traceSpanSeconds':round((events[-1]['utcUs']-events[0]['utcUs'])/1e6,3),
           'minimumCommitHeadroomGiB':min(s['commitHeadroomGiB'] for s in meta['memorySamples']),
           'minimumAvailableRamGiB':min(s['availableRamGiB'] for s in meta['memorySamples']),
           'recordingFolder':str(folder),
           'boundary':'mpv stages use Dart delivery time; exact HTTP first byte, decoder first input/output and compositor fences are absent. Motion comes from original recording.'}
    if row['mode']=='standby':
        assert row['sameStandbySurfaceHandedOff'] and row['sameStandbyPlayerClaimed']
        assert not any(c['call']=='VideoOutputManager.CreateSurface' for c in calls)
    rows.append(row)
    print(json.dumps({k:row[k] for k in ['label','firstImageAfterClickSeconds','confirmedMotionAfterClickSeconds','apiMs','apiEndToOpenMs','openToRealResolutionParamsMs','allocateToCreatedMs','postInitialBufferPauseEvents']}, ensure_ascii=False))
(OUT/'evaluation.json').write_text(json.dumps({'validVideoTrials':4,'distinctVideos':1,
    'order':['control','standby','standby','control'], 'recordedSecondsEach':35,
    'result':'Standby handoff works but stable click-to-motion benefit is not demonstrated; no ten-video expansion.',
    'continuity':'Startup and ~2-second later frame samples reviewed; bounded trace has no renewed buffering/pause. Later brief stalls are not excluded.',
    'rows':rows}, ensure_ascii=False, indent=2), encoding='utf8')
