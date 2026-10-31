"""Attribute a captured resume to recorded spans and guest scheduler states.

Wall time on different threads overlaps. This report never adds their CPU or
wait times together, and uninstrumented intervals remain explicitly unknown.
"""
from pathlib import Path
import csv
import io
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
capture = Path(sys.argv[1]).resolve()
metadata = json.loads((capture / 'capture.json').read_text(encoding='utf-8'))
summary = metadata['summary']
assert metadata.get('externalNativeSpans') and not metadata['errors']
out = capture / 'time-attribution-01'
out.mkdir(exist_ok=False)
processor = ROOT / 'diagnostics/startup-20261016/perfetto/trace_processor_shell.exe'
pid = int(metadata['pid'])


def query(name, sql):
    path = out / f'{name}.sql'
    path.write_text(sql, encoding='utf-8')
    result = subprocess.run([str(processor), 'query', '-f', str(path),
                             str(capture / 'system.pftrace')], check=True,
                            capture_output=True, text=True, encoding='utf-8')
    (out / f'{name}.csv').write_text(result.stdout, encoding='utf-8')
    (out / f'{name}.log').write_text(result.stderr, encoding='utf-8')
    return list(csv.DictReader(io.StringIO(result.stdout.strip())))


mono = summary['inputDispatchMonoNs']
clock = query('clock', f"""SELECT ts-clock_value AS offset_ns FROM clock_snapshot
WHERE clock_name='MONOTONIC' ORDER BY abs(clock_value-{mono}) LIMIT 1;""")
assert clock
anchor = mono + int(clock[0]['offset_ns'])
finish = anchor + round(summary['firstChangedTextureConsumedAfterInputMs'] * 1e6)
spans = query('spans', f"""SELECT s.id,s.parent_id,s.depth,s.ts,s.dur,s.name,t.tid,t.name AS thread
FROM slice s JOIN thread_track tt ON s.track_id=tt.id
JOIN thread t USING(utid) JOIN process p USING(upid)
WHERE p.pid={pid} AND s.dur>=0 AND s.ts<{finish} AND s.ts+s.dur>{anchor}
ORDER BY s.ts,s.depth;""")
states = query('states', f"""SELECT st.ts,st.dur,st.state,st.blocked_function,t.tid,t.name AS thread
FROM thread_state st JOIN thread t USING(utid) JOIN process p USING(upid)
WHERE p.pid={pid} AND st.dur>0 AND st.ts<{finish} AND st.ts+st.dur>{anchor}
ORDER BY st.ts;""")
trace_issues = query('trace-issues', """SELECT name,severity,value FROM stats
WHERE value>0 AND (severity IN ('error','data_loss') OR name LIKE '%overrun%');""")
for r in spans + states:
    for k in ['ts', 'dur', 'tid']:
        r[k] = int(r[k])
for r in spans:
    r['end'] = r['ts'] + r['dur']


def first(name):
    return next(r for r in spans if r['name'] == name)


queue = first('MediaCodec::queueInputBuffer#native')
release = first('MediaCodec::renderOutputBufferAndRelease#native')
# Codec reservation creates the factory object on a background worker. Attribute
# decode to the input queue thread, not that earlier factory thread. The VO
# render thread is independent and is included separately in thread totals.
input_submission_tid = queue['tid']
receive_events=[json.loads(line.split('[CODEC_FLUSH] ',1)[1]) for line in (capture/'logcat.txt').read_text().splitlines() if '[CODEC_FLUSH] ' in line and line.split()[1]==str(pid)]
receive_event=next(e for e in receive_events if e['event']=='receive.first')
decoder_tid = int(receive_event['tid'])
assert decoder_tid != input_submission_tid, 'Expected actual independent async input worker'
assert any(r['name'].startswith('pili.avcodec_receive') and r['tid']==decoder_tid for r in spans)
init = next((r for r in spans if r['name'] == 'pili.init_avctx'
             and r['tid'] == decoder_tid), None)
if init is None:
    # vd-queue transfers packet work to a worker after synchronous decoder
    # initialization on the playback core. Preserve both thread identities.
    candidates = [r for r in spans if r['name'] == 'pili.init_avctx'
                  and r['ts'] < queue['ts']]
    if len(candidates) == 1:
        init = candidates[0]
    else:
        init = next(r for r in spans if r['name'] == 'MediaCodec::Init#native'
                    and r['tid'] == decoder_tid)
factory_inits = [r for r in spans if r['name'] == 'MediaCodec::Init#native']
frame_end = release['ts']
native_calls = [r for r in spans if r['tid'] == decoder_tid
                and r['name'].startswith('MediaCodec::')]


def state_totals(tid, start, end):
    totals = {}
    for r in states:
        if r['tid'] != tid:
            continue
        overlap = max(0, min(end, r['ts'] + r['dur']) - max(start, r['ts']))
        if overlap:
            totals[r['state']] = totals.get(r['state'], 0) + overlap
    return {k: v / 1e6 for k, v in totals.items()}


def attribution(start, end, tid):
    relevant = [r for r in native_calls if r['ts'] < end and r['end'] > start]
    cuts = sorted({start, end, *[max(start, r['ts']) for r in relevant],
                   *[min(end, r['end']) for r in relevant]})
    rows = []
    for a, b in zip(cuts, cuts[1:]):
        active = [r for r in relevant if r['ts'] <= a and r['end'] >= b]
        # Retain the outermost MediaCodec API, not both Java/JNI/native spans.
        owner = min(active, key=lambda r: (int(r['depth']), -r['dur'])) if active else None
        label = owner['name'] if owner else 'outside recorded MediaCodec calls'
        if rows and rows[-1]['label'] == label and rows[-1]['endNs'] == a:
            rows[-1]['endNs'] = b
        else:
            rows.append({'label': label, 'startNs': a, 'endNs': b})
    for r in rows:
        r['afterInputMs'] = (r['startNs'] - anchor) / 1e6
        r['durationMs'] = (r['endNs'] - r['startNs']) / 1e6
        r['statesMs'] = state_totals(tid, r['startNs'], r['endNs'])
    assert sum(r['endNs'] - r['startNs'] for r in rows) == end - start
    return rows


periods = {
    'input_to_texture': (anchor, finish),
    'input_to_codec_init': (anchor, init['ts']),
    'codec_init_to_first_input_queue': (init['ts'], queue['ts']),
    'first_input_queue_to_release': (queue['ts'], frame_end),
}
threads = {r['tid']: r['thread'] for r in states}
thread_rows = []
for tid, name in threads.items():
    if tid not in [pid, decoder_tid, release['tid']] and not any(
            v in name for v in ['raster', 'demux', 'Codec', 'DartWorker']):
        continue
    thread_rows.append({'tid': tid, 'name': name, 'periods': {
        label: state_totals(tid, a, b) for label, (a, b) in periods.items()}})

codec_timeline = attribution(init['ts'], frame_end, decoder_tid)
aggregate = {}
for r in codec_timeline:
    v = aggregate.setdefault(r['label'], {'durationMs': 0, 'statesMs': {}})
    v['durationMs'] += r['durationMs']
    for state, value in r['statesMs'].items():
        v['statesMs'][state] = v['statesMs'].get(state, 0) + value

flutter = [json.loads(line) for name in summary['traceFiles'] if name.startswith('flutter')
           for line in (capture / 'app' / name).read_text(encoding='utf-8').splitlines()]
opened = next(e for e in flutter if e['event'] == 'source.open.begin')
open_ms = next(m['afterInputMs'] for m in summary['milestones'] if m['event'] == 'source.open.begin')
events = []
for e in flutter:
    time_ms = open_ms + (e['elapsedUs'] - opened['elapsedUs']) / 1000
    if 0 <= time_ms <= summary['firstChangedTextureConsumedAfterInputMs'] + 500:
        if e['event'].startswith(('query.', 'source.', 'http.', 'isolated.', 'mpv.', 'output.')):
            events.append({'event': e['event'], 'afterInputMs': time_ms,
                           **{k: e[k] for k in ['workerElapsedUs', 'workerUtcUs',
                              'submitUs', 'awaitUs', 'requestId', 'property', 'name'] if k in e}})

report = {
    'sample': str(capture.relative_to(ROOT)), 'pid': pid, 'decoderTid': decoder_tid,
    'initializationTid': init['tid'], 'inputSubmissionTid': input_submission_tid,
    'decoderThreadSelection': 'Actual receive.first decoder owner TID verified by avcodec_receive spans. MediaCodec input worker is separate; initialization and render remain separate.',
    'renderTid': release['tid'],
    'codecFactoryCalls': [{'tid': r['tid'], 'afterInputMs': (r['ts']-anchor)/1e6,
                           'durationMs': r['dur']/1e6,
                           'statesMs': state_totals(r['tid'],r['ts'],r['end'])}
                          for r in factory_inits],
    'inputToTextureMs': summary['firstChangedTextureConsumedAfterInputMs'],
    'firstTexturePtsNs': summary['firstChangedTextureTimestampNs'],
    'clockOffsetNs': int(clock[0]['offset_ns']),
    'dartClockUncertaintyMs': summary['dartToNativeClockUncertaintyMs'],
    'periodsMs': {k: {'start': (a-anchor)/1e6, 'end': (b-anchor)/1e6,
                       'duration': (b-a)/1e6} for k, (a, b) in periods.items()},
    'decoderApiAggregate': aggregate, 'threads': thread_rows,
    'codecTimeline': codec_timeline, 'dartEvents': events,
    'schedulerEventsCollected': bool(states),
    'traceIssues': trace_issues,
    'firstInputQueueIsPrerollNotTarget': True,
    'boundary': ('Scheduler states collected; missing intervals remain unobserved. ' if states else 'No scheduler switch coverage: empty states are missing coverage, never zero CPU or zero wait. ') + 'Exact partition of recorded decoder-thread wall time; overlapping threads are not summed. Running is guest scheduled time, not proof of physical host CPU execution; R/R+ is runnable, S/D are waits with cause unknown unless a recorded call establishes context. No stacks or syscall ownership were collected. First input queue is preroll, not the target PTS. This instrumented sample is not a lean performance result or physical-display proof.',
}
(out / 'summary.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps({k: report[k] for k in ['periodsMs', 'decoderApiAggregate', 'threads']}, indent=2))
