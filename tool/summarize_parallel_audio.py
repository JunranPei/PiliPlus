"""Summarize listener runs, separating startup gaps from post-start stalls."""
import json
from pathlib import Path
from playback_trace_files import validate_trace_pair

ROOT = Path(__file__).resolve().parents[1]
folder = ROOT/'diagnostics/startup-20261030/parallel-audio'
rows = []
for path in sorted(folder.glob('**/summary.json')):
    if not (path.parent/'capture.json').is_file():
        continue  # Derived codec reports are not independent captures.
    corrected = path.parent/'generation-audit'/'summary.json'
    summary = json.loads((corrected if corrected.is_file() else path).read_text(encoding='utf-8'))
    capture = json.loads((path.parent/'capture.json').read_text(encoding='utf-8'))
    times = {e['event']: e['afterInputMs'] for e in summary.get('milestones', [])}
    texture = summary.get('firstChangedTextureConsumedAfterInputMs')
    reveal = times.get('ui.frameReady.after')
    names = validate_trace_pair(summary.get('traceFiles',
        [file.name for file in (path.parent/'app').glob('*.jsonl')]))
    events = [json.loads(line) for file in [path.parent/'app'/name for name in names]
              for line in file.read_text(encoding='utf-8').splitlines()]
    opened = next((e['elapsedUs'] for e in events if e['event']=='source.open.begin'
                   and 'elapsedUs' in e), None)
    prefetch = [{'event': e['event'], 'afterOpenMs': round((e['elapsedUs']-opened)/1000, 3),
                 **{k:e[k] for k in ('status','reason','receivedBytes','deliveredBytes') if k in e}}
                for e in events if e['event'].startswith(('audio.prefetch.', 'isolated.')) and opened is not None]
    gaps = []
    if texture is not None:
        first_ns = summary['inputDispatchMonoNs']+texture*1e6
        # Only retain intervals wholly AFTER the first valid observed timestamp.
        gaps = [{'afterInputMs': (e['monoNs']-summary['inputDispatchMonoNs'])/1e6,
                 'gapMs': e['data']['callbackGapNs']/1e6}
                for e in events if e['event']=='texture.consumed' and
                e['monoNs']-e['data'].get('callbackGapNs', 0)>=first_ns and
                e['data'].get('callbackGapNs',0)>=100e6]
    dimensions = sorted({str(e['decodedDisplaySize']) for e in events
                         if e.get('decodedDisplaySize') and e['decodedDisplaySize']!=[0,0]})
    row = dict(run=str(path.parent.relative_to(folder)), status=capture['status'], errors=capture['errors'],
               validSource=summary.get('validSource', False),
               validInput=summary.get('validInput', False),
               validTextureObservation=summary.get('validTextureObservation', False),
               apk=capture.get('apkSha256'), index=capture.get('video',{}).get('bvid'),
               textureMs=texture, revealReadyMs=reveal,
               presentationPrerequisitesMs=max(texture, reveal) if texture is not None and reveal is not None else None,
               physicalDisplayTimeMs=None, traceFiles=names,
               correctedForProcessGeneration=corrected.is_file(),
               primaryApiMs=times['query.primary.end']-times['query.primary.begin']
                   if all(k in times for k in ('query.primary.begin', 'query.primary.end')) else None,
               afterPrimaryMs=texture-times['query.primary.end']
                   if texture is not None and 'query.primary.end' in times else None,
               afterOpenMs=texture-times['source.open.begin']
                   if texture is not None and 'source.open.begin' in times else None,
               buffering=summary.get('buffering'), postStartGapsOver100Ms=gaps,
               gapBoundary='Callback gaps; repeated timestamps can conceal unchanged video images',
               prefetch=prefetch, decodedDisplaySizes=dimensions,
               returnedAfterSeconds=capture.get('backSentAfterSeconds'),
               soughtAfterSeconds=capture.get('seekInputAfterSeconds',capture.get('seekGestureAfterSeconds')))
    rows.append(row)
(folder/'comparison.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
for row in rows:
    print(json.dumps({k:row[k] for k in ('run','textureMs','primaryApiMs','afterOpenMs',
                                       'postStartGapsOver100Ms','decodedDisplaySizes')}))
