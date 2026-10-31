"""Correlate opt-in transport and audio timing with the captured input clock."""
import argparse
import hashlib
import json
from pathlib import Path

from capture_startup_listener import records

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('capture', type=Path)
args = parser.parse_args()
capture = args.capture.resolve()
summary = json.loads((capture/'summary.json').read_text(encoding='utf-8'))
if not summary.get('validInput') or not summary.get('validSource'):
    raise ValueError('No valid input/source for timing analysis')
events, errors = records(capture/'app', summary['traceFiles'])
if errors:
    raise ValueError('Malformed trace records')
dart = [e for e in events if 'elapsedUs' in e]
clocks = [e for e in dart if e['event'] == 'clock.sync' and e.get('native', {}).get('monoNs')]
sync = min(clocks, key=lambda e: e['dartReceiveUs']-e['dartSendUs'])
offset = sync['native']['monoNs']/1000-(sync['dartSendUs']+sync['dartReceiveUs'])/2
origin = summary['inputDispatchMonoNs']/1000
identity = summary['sourceIdentity']


def after(event):
    return (event['elapsedUs']+offset-origin)/1000


progress = []
positions = []
for event in dart:
    if event.get('cid') != identity['cid'] or event.get('requestId') != identity['requestId']:
        continue
    if event['event'].endswith('.body.progress'):
        delivery_lag_ms = (event['utcUs']-event['workerUtcUs'])/1000
        progress.append({
            'track': event['event'].split('.')[1],
            'workerAfterInputMs': after(event)-delivery_lag_ms,
            'parentReceiveAfterInputMs': after(event),
            'workerToParentDeliveryMs': delivery_lag_ms,
            **{key: event[key] for key in ('workerElapsedUs', 'receivedBytes', 'deliveredBytesBeforeChunk')},
        })
    elif event['event'] == 'startup.timing.position':
        positions.append({'afterInputMs': after(event), **{
            key: event.get(key) for key in ('positionEventMs', 'currentAo', 'audioPts', 'avsync', 'cacheDuration')
        }})
if not progress or not positions:
    raise ValueError('Capture lacks the opt-in transfer/position observations')
utc_offsets = [e['utcUs']-e['elapsedUs'] for e in dart if after(e) >= 0]
report = {
    'traceFiles': summary['traceFiles'], 'sourceIdentity': identity,
    'toolSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'clockUncertaintyMs': summary.get('dartToNativeClockUncertaintyMs'),
    'dartUtcOffsetRangeMs': (max(utc_offsets)-min(utc_offsets))/1000,
    'actualAudioOutputs': sorted({p['currentAo'] for p in positions if p['currentAo']}),
    'positions': positions, 'bodyProgress': progress,
    'physicalDisplayTimeMs': None,
    'boundary': 'Worker chunk callback time mapped through same-device UTC; parent delivery kept separately. Byte counters are not decoder-consumption timestamps. Audio properties are read on position stream delivery, not physical speaker output. No samples between events are inferred.',
}
out = capture/'transport-analysis'
out.mkdir(exist_ok=False)
(out/'summary.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps({'capture': capture.name, 'actualAudioOutputs': report['actualAudioOutputs'],
                  'progressSamples': len(progress), 'positionSamples': len(positions),
                  'minAudioPts': min((p['audioPts'] for p in positions if p['audioPts'] is not None), default=None),
                  'minAvsync': min((p['avsync'] for p in positions if p['avsync'] is not None), default=None)}))
