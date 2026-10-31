"""Review complete synchronous VM slices without double-counting shader children."""
import collections
import hashlib
import json
from pathlib import Path
import sys

folder = Path(sys.argv[1]).resolve()
metadata = json.loads((folder/'capture.json').read_text(encoding='utf-8'))
assert metadata.get('vmSkiaTraceRequested') and metadata['build']['buildMode'] == 'profile'
timeline = json.loads((folder/'vm-timeline.json').read_text(encoding='utf-8'))
collection = json.loads((folder/'vm-timeline-collection.json').read_text(encoding='utf-8'))
events = timeline['traceEvents']
stack = collections.defaultdict(list)
last_timestamp = {}
spans = []
missing_begin = 0
for event in events:
    if event['ph'] not in ('B', 'E', 'X'):
        continue
    key = (event['pid'], event['tid'])
    # Async/flow records can be emitted out of timestamp order. Synchronous
    # per-thread scopes must be ordered and match by name before accepting them.
    assert event['ts'] >= last_timestamp.get(key, 0), 'Unordered synchronous slices'
    last_timestamp[key] = event['ts']
    if event['ph'] == 'B':
        stack[key].append(event)
    elif event['ph'] == 'E':
        if not stack[key]:
            missing_begin += 1
            continue
        begin = stack[key].pop()
        assert begin['name'] == event['name'], 'Mismatched timeline scopes'
        spans.append({**begin, 'durationMs': (event['ts']-begin['ts'])/1000})
    else:
        spans.append({**event, 'durationMs': event['dur']/1000})
input_us = metadata['summary']['inputDispatchMonoNs']/1000
window = [span for span in spans if input_us <= span['ts'] <= input_us+3e6]
for span in window:
    span['startAfterInputMs'] = (span['ts']-input_us)/1000
shaders = [span for span in window if span.get('args', {}).get('devtoolsTag') == 'shaders']
shader_roots = [span for span in shaders if span['name'] == 'shader_compile']
timestamps = [event['ts'] for event in events if 'ts' in event]
report = {
    'profileOnly': True, 'releaseSpeedComparable': False,
    'eventCount': len(events), 'coversInputStart': min(timestamps) <= input_us <= max(timestamps),
    'inputMonoUs': input_us, 'timelineRangeUs': [min(timestamps), max(timestamps)],
    'unmatchedBeginAtStop': sum(map(len, stack.values())), 'unmatchedEnd': missing_begin,
    'shaderCoverageVerified': bool(shaders),
    'firstThreeSecondsShaderCompileMs': sum(span['durationMs'] for span in shader_roots),
    'shaderCompiles': shader_roots,
    'longestCompleteSlices': sorted(window, key=lambda span: span['durationMs'], reverse=True)[:40],
    'streamsRestored': collection.get('streamsRestored'),
    'forwardRemoved': collection.get('forwardRemoved'),
    'boundary': 'Complete per-thread VM scopes only; Android native platform-channel work may be absent. Nested shader slices are not summed. Texture consumption is not physical presentation.',
    'reviewerSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
}
with (folder/'vm-timeline-reviewed.json').open('x', encoding='utf-8') as output:
    json.dump(report, output, indent=2)
print(json.dumps({key: report[key] for key in ['eventCount', 'coversInputStart',
    'shaderCoverageVerified', 'firstThreeSecondsShaderCompileMs', 'unmatchedEnd']}))
