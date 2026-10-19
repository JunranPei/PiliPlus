"""Keep visual timing separate from delivered diagnostic milestones."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
# Inspected original PTS, including the touch overlay and adjacent media frames.
# These are confirmation upper bounds, not a decoder callback substituted for video.
VISUAL = {
    'a1': (4.782, 4.815, 4.855, 0.040),
    'b1': (3.823, 3.857, 3.891, 0.034),
    'b2': (3.864, 3.897, 4.032, 0.135),
    'a2': (4.733, 4.767, 4.800, 0.033),
}
rows = []
for label, (cover, image, motion, initial_hold) in VISUAL.items():
    folder = ROOT / f'diagnostics/startup-20261017/mpv-phase1/source-overlap-{label}-20261019-5'
    trace = next((folder/'traces').glob('flutter*'))
    events = [json.loads(s) for s in trace.read_text(encoding='utf8').splitlines()]
    first = lambda name: next(e for e in events if e['event'] == name)
    query = first('query.primary.begin')['utcUs']
    pointer = json.loads((folder/'startup-pts.json').read_text())['pointerCandidatePts']
    play = first('command.play')['utcUs']
    unbuffered = next(e for e in events if e['event'] == 'media.buffering'
                      and e['utcUs'] > play and not e['value'])
    problems = [e for e in events if e['utcUs'] > unbuffered['utcUs'] and
                ((e['event'] == 'media.buffering' and e['value']) or
                 (e['event'] == 'media.playing' and not e['value']))]
    meta = json.loads((OUT/f'source-overlap-{label}-20261019-5-capture.json').read_text())
    ms = lambda name: round((first(name)['utcUs']-query)/1000, 3)
    stages = [{'stage': e.get('stage'), 'ms': round((e['utcUs']-query)/1000, 3)}
              for e in events if e['event'] == 'startup.mpv']
    row = dict(label=label, candidate=label.startswith('b'),
               apkSha256=meta['apkSha256'], coldApp=meta['appForceStoppedBeforeSearch'],
               mediaPreloaded=False, recordedSeconds=35, pointerPts=pointer,
               lastCoverPts=cover, firstImagePts=image, confirmedMotionPts=motion,
               firstImageAfterClickSeconds=round(image-pointer, 3),
               confirmedMotionAfterClickSeconds=round(motion-pointer, 3),
               motionIsConfirmationUpperBound=True,
               firstImageToConfirmedMotionSeconds=initial_hold,
               apiMs=ms('query.primary.end'),
               uiMountRequestMs=ms('ui.mount.request'),
               sourceOpenBeginMs=ms('source.open.begin'),
               sourceOpenAcceptedMs=ms('source.open.accepted'),
               mediaAndPageJoinedMs=ms('source.open.return'),
               commandPlayMs=ms('command.play'), outputStableMs=ms('output.stable'),
               coverReleasedMs=ms('ui.frameReady.after'), mpvDeliveredStages=stages,
               postInitialBufferPauseEvents=problems,
               traceSpanSeconds=round((events[-1]['utcUs']-events[0]['utcUs'])/1e6, 3),
               minimumAvailableRamGiB=min(s['availableRamGiB'] for s in meta['memorySamples']),
               minimumCommitHeadroomGiB=min(s['commitHeadroomGiB'] for s in meta['memorySamples']),
               recordingFolder=str(folder))
    rows.append(row)
    print(json.dumps({k: row[k] for k in ['label', 'confirmedMotionAfterClickSeconds',
        'apiMs', 'uiMountRequestMs', 'sourceOpenBeginMs', 'sourceOpenAcceptedMs',
        'mediaAndPageJoinedMs', 'postInitialBufferPauseEvents']}, ensure_ascii=False))
data = dict(validVideoTrials=4, distinctVideos=1, order=['control','candidate','candidate','control'],
    conditions='One emulator boot, cold App before each search, empty player/output standby, no media preload.',
    result='Both candidates reach motion earlier in this video. Overlap mechanism works; network and decoder variation prevent attributing the entire gap to this change.',
    acceptedPerformanceFix=False,
    continuity='No renewed buffering or pause in ~20s traces. Original onset and ~2s later frame samples reviewed. b2 holds its first image ~135ms; later brief stalls remain unexcluded.',
    boundary='Click and motion use original WebM PTS. mpv stages use Dart log delivery time, not native execution. source.open.accepted is asynchronous load acceptance, not first bytes or decode completion.',
    rows=rows)
(OUT/'evaluation.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf8')
