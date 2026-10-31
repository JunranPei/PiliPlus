"""Report distinct video timestamp consumption gaps, without claiming display."""
import argparse
import json
from pathlib import Path

from capture_startup_listener import records

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('capture', type=Path)
parser.add_argument('--output-name', default='continuity-analysis', help='New analysis directory; never overwrites prior reports')
args = parser.parse_args()
if Path(args.output_name).name != args.output_name or args.output_name in ('.', '..'):
    parser.error('output-name must be a plain new directory name')
capture = args.capture.resolve()
corrected = capture/'generation-audit'/'summary.json'
summary = json.loads((corrected if corrected.is_file() else capture/'summary.json').read_text(encoding='utf-8'))
if not summary.get('validSource') or not summary.get('validInput'):
    raise ValueError('Capture has no valid source/input; continuity cannot be measured')
metadata = json.loads((capture/'capture.json').read_text(encoding='utf-8'))
events, errors = records(capture/'app', summary.get('traceFiles'))
if errors:
    raise ValueError('Malformed raw trace records')
origin = summary['inputDispatchMonoNs']
identity = summary['sourceIdentity']
samples = []
for event in events:
    if event['event'] != 'texture.consumed':
        continue
    data = event['data']
    context = data.get('requestContext', {})
    if not data.get('continuityObserved') or not data.get('surfaceValid'):
        continue
    if not all(context.get(k) == identity.get(k) for k in
               ('cid', 'requestId', 'sourceRevision', 'playerId')):
        continue
    if data.get('textureId') != identity.get('textureId') or data['callbackMonoNs'] < origin:
        continue
    samples.append(data)
samples.sort(key=lambda d: d['callbackMonoNs'])
if not samples:
    raise ValueError('No source-matched continuity observations; do not infer from callback gaps')

def after(ns):
    return (ns-origin)/1e6


gaps = []
play_commands = [m['afterInputMs'] for m in summary.get('milestones', [])
                 if m['event'] == 'command.play']
pause_windows = [(pause, next((play for play in play_commands if play > pause), float('inf')))
                 for pause in summary.get('pauses', [])]
buffer_windows = []
buffer_start = None
for event in summary.get('buffering', []):
    if event['value']:
        buffer_start = event['afterInputMs']
    elif buffer_start is not None:
        buffer_windows.append((buffer_start, event['afterInputMs']))
        buffer_start = None
if buffer_start is not None:
    buffer_windows.append((buffer_start, float('inf')))
for sample in samples:
    gap_ns = sample['positiveTimestampGapNs']
    if gap_ns < 100_000_000:
        continue
    end = after(sample['callbackMonoNs'])
    start = end-gap_ns/1e6
    notes = []
    seek = metadata.get('seekInputAfterSeconds', metadata.get('seekGestureAfterSeconds'))
    back = metadata.get('backSentAfterSeconds')
    if seek is not None and start <= seek*1000 <= end:
        notes.append('overlaps host-recorded seek request')
    if back is not None and end >= back*1000:
        notes.append('after host-recorded back request')
    if any(start <= resume and end >= pause for pause, resume in pause_windows):
        notes.append('overlaps observed player pause-to-play interval')
    if any(start <= done and end >= began for began, done in buffer_windows):
        notes.append('overlaps observed media buffering interval')
    gaps.append({'startAfterInputMs': start, 'endAfterInputMs': end,
                 'gapMs': gap_ns/1e6, 'newProducerTimestampNs': sample['textureTimestampNs'],
                 'operationNotes': notes})

report = {
    'traceFiles': summary.get('traceFiles'), 'sourceIdentity': identity,
    'observationStartAfterInputMs': after(samples[0]['callbackMonoNs']),
    'observationEndAfterInputMs': after(samples[-1]['callbackMonoNs']),
    'distinctPositiveTimestampChanges': max(s['positiveTimestampChanges'] for s in samples),
    'maxCompletedPositiveTimestampGapMs': max(s['maxPositiveTimestampGapNs'] for s in samples)/1e6,
    'maxObservedUnchangedTimestampAgeMs': max(s['unchangedPositiveTimestampAgeNs'] for s in samples)/1e6,
    'completedGapsOver100Ms': gaps, 'buffering': summary.get('buffering'),
    'pauseCommandsAfterInputMs': summary.get('pauses'),
    'backRequestedAfterSeconds': metadata.get('backSentAfterSeconds'),
    'nativeRecords': summary.get('nativeRecords'),
    'droppedNativeRecords': summary.get('droppedNativeRecords'),
    'physicalDisplayTimeMs': None,
    'partialRecovery': summary.get('partialRecovery', False),
    'boundary': 'Time between distinct positive producer timestamps consumed by Flutter. Includes intentional pause/seek and source cadence; not physical display or an automatic dropped-frame classification.',
}
out = capture/args.output_name
out.mkdir(exist_ok=False)
(out/'summary.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
