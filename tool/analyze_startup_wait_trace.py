"""Join diagnostic Dart boundaries and native call scopes without double counting.

Requires analyze_first_resume_timeline.py output from the same capture. This is
causal evidence for a heavy trace, never a comparison with lean startup timing.
"""
from pathlib import Path
import csv
import io
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
capture = Path(sys.argv[1]).resolve()
metadata = json.loads((capture / 'capture.json').read_text(encoding='utf-8'))
summary = metadata['summary']
assert metadata['waitTrace'] and metadata['perfetto'] and not metadata['errors']
prior = capture / 'time-attribution-01'
timeline = json.loads((prior / 'summary.json').read_text(encoding='utf-8'))
out = capture / (sys.argv[2] if len(sys.argv) > 2 else 'wait-attribution-01')
out.mkdir(exist_ok=False)
processor = ROOT / 'diagnostics/startup-20261016/perfetto/trace_processor_shell.exe'
anchor = summary['inputDispatchMonoNs'] + timeline['clockOffsetNs']
texture = anchor + round(summary['firstChangedTextureConsumedAfterInputMs'] * 1e6)
pid, decoder_tid = int(metadata['pid']), timeline['decoderTid']


def query(name, sql):
    path = out / f'{name}.sql'
    path.write_text(sql, encoding='utf-8')
    result = subprocess.run([str(processor), 'query', '-f', str(path),
                             str(capture / 'system.pftrace')], check=True,
                            capture_output=True, text=True, encoding='utf-8')
    (out / f'{name}.csv').write_text(result.stdout, encoding='utf-8')
    (out / f'{name}.log').write_text(result.stderr, encoding='utf-8')
    return list(csv.DictReader(io.StringIO(result.stdout.strip())))


spans = list(csv.DictReader((prior / 'spans.csv').open(encoding='utf-8')))
states = list(csv.DictReader((prior / 'states.csv').open(encoding='utf-8')))
for r in spans + states:
    for key in ['ts', 'dur', 'tid']:
        r[key] = int(r[key])
    r['end'] = r['ts'] + r['dur']
for r in spans:
    r['depth'] = int(r['depth'])


def state_totals(tid, start, end):
    totals = {}
    for r in states:
        if r['tid'] != tid:
            continue
        overlap = max(0, min(end, r['end']) - max(start, r['ts']))
        if overlap:
            totals[r['state']] = totals.get(r['state'], 0) + overlap
    return {k: v / 1e6 for k, v in totals.items()}


def describe(r):
    return {'name': r['name'], 'tid': r['tid'],
            'startMs': (r['ts'] - anchor) / 1e6, 'durationMs': r['dur'] / 1e6,
            'statesMs': state_totals(r['tid'], r['ts'], r['end'])}


flutter = [json.loads(line) for name in summary['traceFiles'] if name.startswith('flutter')
           for line in (capture / 'app' / name).read_text(encoding='utf-8').splitlines()]
opened = next(e for e in flutter if e['event'] == 'source.open.begin'
              and e.get('playerId') == summary['sourceIdentity']['playerId'])
open_ms = next(m['afterInputMs'] for m in summary['milestones'] if m['event'] == 'source.open.begin')


def event_ms(e):
    return open_ms + (e['elapsedUs'] - opened['elapsedUs']) / 1000


begins, ends = {}, {}
for e in flutter:
    if e['event'] == 'wait.span.begin':
        assert e['spanId'] not in begins
        begins[e['spanId']] = e
    if e['event'] == 'wait.span.end':
        assert e['spanId'] not in ends
        ends[e['spanId']] = e
waits = []
for id_, e in begins.items():
    end = ends.get(id_)
    if end is None:
        waits.append({'spanId': id_, 'name': e['name'], 'startMs': event_ms(e), 'incomplete': True})
        continue
    assert e['name'] == end['name'] and end['elapsedUs'] >= e['elapsedUs']
    assert 'durationUs' in end
    a = anchor + round(event_ms(e) * 1e6)
    b = anchor + round(event_ms(end) * 1e6)
    waits.append({'spanId': id_, 'name': e['name'], 'startMs': event_ms(e),
                  'endMs': event_ms(end), 'durationMs': end['durationUs'] / 1000,
                  'boundaryDurationMs': (b-a)/1e6,
                  'submitMs': end.get('submitUs', 0)/1000,
                  'synchronous': end['synchronous'],
                  'requestId': e.get('httpRequestId'), 'path': e.get('path'),
                  'clockUncertaintyMs': summary['dartToNativeClockUncertaintyMs'],
                  'stateAttributionTooShort': (b-a)/1e6 < 2*summary['dartToNativeClockUncertaintyMs'],
                  'stateAttributionClippedAtTexture': b > texture,
                  'mainThreadStatesAtNominalAlignmentMs': state_totals(pid, a, b)})
assert not (set(ends) - set(begins))

init = next((r for r in spans if r['name'] == 'pili.init_avctx'
             and r['tid'] == decoder_tid), None)
if init is None:
    init = next(r for r in spans if r['name'] == 'MediaCodec::Init#native'
                and r['tid'] == decoder_tid)
queue = next(r for r in spans if r['name'] == 'MediaCodec::queueInputBuffer#native')
release = next(r for r in spans if r['name'] == 'MediaCodec::renderOutputBufferAndRelease#native')


def partition(start, end):
    relevant = [r for r in spans if r['tid'] == decoder_tid and r['ts'] < end and r['end'] > start
                and r['name'].startswith(('pili.', 'MediaCodec::'))]
    cuts = sorted({start, end, *[max(start, r['ts']) for r in relevant],
                   *[min(end, r['end']) for r in relevant]})
    aggregate = {}
    rows = []
    for a, b in zip(cuts, cuts[1:]):
        active = [r for r in relevant if r['ts'] <= a and r['end'] >= b]
        codec = [r for r in active if r['name'].startswith('MediaCodec::')]
        if codec:
            owner = min(codec, key=lambda r: r['depth'])
        else:
            owner = max(active, key=lambda r: r['depth']) if active else None
        label = owner['name'].split(' pts=')[0] if owner else 'outside instrumented calls'
        counts = state_totals(decoder_tid, a, b)
        entry = aggregate.setdefault(label, {'durationMs': 0, 'statesMs': {}})
        entry['durationMs'] += (b-a)/1e6
        for key, value in counts.items():
            entry['statesMs'][key] = entry['statesMs'].get(key, 0) + value
        rows.append({'name': label, 'startMs': (a-anchor)/1e6,
                     'durationMs': (b-a)/1e6, 'statesMs': counts})
    assert abs(sum(r['durationMs'] for r in rows) - (end-start)/1e6) < 1e-6
    return {'durationMs': (end-start)/1e6, 'statesMs': state_totals(decoder_tid, start, end),
            'aggregate': aggregate, 'intervals': rows}


stats = query('trace-stats', "SELECT * FROM stats WHERE value!=0 AND severity!='info' ORDER BY name,idx;")
native_counts = query('native-scope-counts', f"""SELECT s.name,count(*) AS count,
sum(s.dur<0) AS incomplete,sum(max(s.dur,0))/1000000.0 AS inclusive_ms
FROM slice s JOIN thread_track tt ON s.track_id=tt.id
JOIN thread t USING(utid) JOIN process p USING(upid)
WHERE p.pid={pid} AND s.name GLOB 'pili.*' GROUP BY s.name ORDER BY s.name;""")
blocked = query('blocked', f"""SELECT t.tid,t.name,st.state,st.blocked_function,
sum(min(st.ts+st.dur,{texture})-max(st.ts,{anchor}))/1000000.0 AS duration_ms
FROM thread_state st JOIN thread t USING(utid) JOIN process p USING(upid)
WHERE p.pid={pid} AND st.ts<{texture} AND st.ts+st.dur>{anchor} AND st.dur>0
AND st.state IN ('S','D') GROUP BY t.tid,t.name,st.state,st.blocked_function
ORDER BY duration_ms DESC;""")

native_before_init = [describe(r) for r in spans if r['name'].startswith('pili.') and r['ts'] < init['ts']]
packets = [describe(r) for r in spans if r['ts'] < release['ts']
           and r['name'].startswith(('pili.preroll_discard', 'pili.avcodec_send'))]
report = {
    'capture': str(capture.relative_to(ROOT)), 'pid': pid, 'decoderTid': decoder_tid,
    'clockUncertaintyMs': summary['dartToNativeClockUncertaintyMs'],
    'dartSpans': waits, 'nativeBeforeInit': native_before_init, 'prerollPackets': packets,
    'initToFirstQueue': partition(init['ts'], queue['ts']),
    'queueToFirstRelease': partition(queue['ts'], release['ts']),
    'traceStats': stats, 'nativeScopes': native_counts, 'blocked': blocked,
    'boundary': 'Diagnostic-only. Durations include time not scheduled. Parallel and nested calls overlap; only partition aggregates can be summed. Dart/native clock uncertainty applies. Native scope inclusive durations are not CPU time. Incomplete end-of-trace scopes need not indicate data loss. Physical display and host/QEMU internals are not established.'
}
(out / 'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({'dartSpans': len(waits), 'prerollPackets': len(packets),
                  'traceStats': stats, 'queueToFirstRelease': report['queueToFirstRelease']['aggregate']}, indent=2))
