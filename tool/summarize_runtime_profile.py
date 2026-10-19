"""Summarize captured CPU samples and async intervals without inventing waits."""
import argparse
from collections import Counter
import json
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('folder', type=Path)
args = p.parse_args()
out = args.folder
stream = out/'dart-timeline-stream.jsonl'
events = ([json.loads(line) for line in stream.read_text().splitlines()] if stream.exists()
          else json.loads((out/'dart-timeline.json').read_text())['traceEvents'])
events.sort(key=lambda e: e.get('ts', 0))
marks = [e for e in events if e.get('name', '').startswith('PiliPlus.')]
origin = next((e['ts'] for e in marks if e['name'] == 'PiliPlus.query.primary.begin'), None)
pending = {}
requests = []
for event in events:
    if event.get('name') != 'HTTP adapter':
        continue
    key = event.get('id')
    if event.get('ph') == 'b':
        pending[key] = event
    elif event.get('ph') == 'e' and key in pending:
        begin = pending.pop(key)
        request_id = begin.get('args', {}).get('requestId')
        request_marks = [e for e in marks if e.get('args', {}).get('requestId') == request_id]
        requests.append({'id': request_id, 'path': begin.get('args', {}).get('path'),
            'beginRelativePrimaryMs': (begin['ts']-origin)/1000 if origin is not None else None,
            'durationMs': (event['ts']-begin['ts'])/1000,
            'end': event.get('args'),
            'deliveryMarks': [{'name': e['name'], 'sinceAdapterBeginMs': (e['ts']-begin['ts'])/1000}
                              for e in request_marks]})
cpu = []
for file in out.glob('dart-cpu-*.json'):
    data = json.loads(file.read_text())
    if 'unavailable' in data:
        cpu.append({'file': file.name, **data})
        continue
    functions = data.get('functions', [])
    samples = data.get('samples', [])

    def name(index):
        item = functions[index]
        return item.get('function', {}).get('name', '<unknown>')

    def statistics(selected):
        inclusive = Counter(i for s in selected for i in set(s.get('stack', [])))
        self_count = Counter(s['stack'][0] for s in selected if s.get('stack'))
        def rows(counts):
            return [{'function': name(i), 'url': functions[i].get('resolvedUrl'), 'samples': n}
                    for i, n in counts.most_common(30)]
        return {'sampleCount': len(selected), 'emptyStack': sum(not s.get('stack') for s in selected),
                'truncatedStacks': sum(bool(s.get('truncated')) for s in selected),
                'topSelf': rows(self_count), 'topInclusive': rows(inclusive)}

    windows = {'wholeCapture': statistics(samples)}
    if origin is not None:
        for begin, finish in [(0, 700), (700, 1500), (1500, 2500), (2500, 5000)]:
            windows[f'primary+{begin}-{finish}ms'] = statistics([
                s for s in samples if origin+begin*1000 <= s['timestamp'] < origin+finish*1000])
    cpu.append({'file': file.name, 'samplePeriodUs': data.get('samplePeriod'),
                'timeOriginMicros': data.get('timeOriginMicros'),
                'timeExtentMicros': data.get('timeExtentMicros'), 'windows': windows})
    # Sample weights are estimated CPU cost, not off-CPU wall-clock time.
    frames = [{'name': name(i), 'file': item.get('resolvedUrl', '')}
              for i, item in enumerate(functions)]
    profiles = []
    for tid in sorted(set(s.get('tid', 0) for s in samples)):
        selected = [s for s in samples if s.get('tid', 0) == tid and s.get('stack')]
        profiles.append({'type': 'sampled', 'name': f'{file.stem} thread {tid} CPU samples',
            'unit': 'microseconds', 'startValue': 0,
            'endValue': len(selected)*data.get('samplePeriod', 1000),
            'samples': [list(reversed(s['stack'])) for s in selected],
            'weights': [data.get('samplePeriod', 1000)]*len(selected)})
    file.with_suffix('.speedscope.json').write_text(json.dumps({
        '$schema': 'https://www.speedscope.app/file-format-schema.json',
        'shared': {'frames': frames}, 'profiles': profiles,
        'exporter': 'PiliPlus diagnostic CPU samples; excludes waits'}))
report = {'primaryBeginTimelineUs': origin, 'eventCount': len(events),
    'timelineNameCounts': Counter(e.get('name', '') for e in events).most_common(30),
    'playbackMarks': [{'name': e['name'], 'relativePrimaryMs': (e['ts']-origin)/1000
                      if origin is not None else None, 'args': e.get('args')} for e in marks
                      if e['name'] not in ('PiliPlus.geometry','PiliPlus.frame.raster',
                        'PiliPlus.frame.afterDrawFrame','PiliPlus.frame.postFrame','PiliPlus.probe.collection')],
    'httpAdapterSpans': requests, 'unclosedHttpSpans': len(pending), 'cpu': cpu,
    'boundary': 'Sample counts are CPU observations, not a decomposition of wall time. '
                'HTTP marks are adapter delivery, not native media packet arrival. '
                'Actual motion must be reviewed in screen.webm.'}
(out/'runtime-summary.json').write_text(json.dumps(report, indent=2), encoding='utf8')
print(json.dumps({'events': len(events), 'requests': len(requests),
                  'isolates': len(cpu), 'primaryTimelineUs': origin}))
