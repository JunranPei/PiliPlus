"""Summarize bounded codec slices beside a listener capture, without pixels."""
import argparse
import csv
import io
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('capture', type=Path)
args = parser.parse_args()
capture = args.capture.resolve()
summary = json.loads((capture/'summary.json').read_text(encoding='utf-8'))
metadata = json.loads((capture/'capture.json').read_text(encoding='utf-8'))
pid = int(metadata['pid'])
mono_anchor = int(summary['inputDispatchMonoNs'])
out = capture/'codec-analysis'
out.mkdir(exist_ok=False)
processor = ROOT/'diagnostics/startup-20261016/perfetto/trace_processor_shell.exe'


def query(name, sql):
    source = out/(name+'.sql')
    source.write_text(sql, encoding='utf-8')
    result = subprocess.run([str(processor), 'query', '-f', str(source),
                             str(capture/'system.pftrace')], check=True,
                            capture_output=True, text=True, encoding='utf-8')
    (out/(name+'.csv')).write_text(result.stdout, encoding='utf-8')
    (out/(name+'.log')).write_text(result.stderr, encoding='utf-8')
    return list(csv.DictReader(io.StringIO(result.stdout.strip())))


clock = query('clock', f"""SELECT ts,clock_value,ts-clock_value AS offset_ns
FROM clock_snapshot WHERE clock_name='MONOTONIC'
ORDER BY abs(clock_value-{mono_anchor}) LIMIT 1;""")
if not clock:
    raise RuntimeError('Missing MONOTONIC clock mapping; cannot align input')
anchor = mono_anchor+int(clock[0]['offset_ns'])
slices = query('codec', f"""SELECT s.ts,s.dur,s.name,t.tid,t.name AS thread
FROM slice s JOIN thread_track tt ON s.track_id=tt.id
JOIN thread t USING(utid) JOIN process p USING(upid)
WHERE p.pid={pid} AND s.ts>={anchor} AND s.ts<{anchor}+3000000000
AND s.name IN ('MediaCodec::Init#native','MediaCodec::configure#native',
'MediaCodec::start#native','MediaCodec::flush#native',
'MediaCodec::queueInputBuffer#native','MediaCodec::renderOutputBufferAndRelease#native')
ORDER BY s.ts;""")
events = [{'event':r['name'], 'afterInputMs':(int(r['ts'])-anchor)/1e6,
           'durationMs':int(r['dur'])/1e6, 'tid':int(r['tid'])} for r in slices]
first = {}
for event in events:
    first.setdefault(event['event'], event)
queue = first.get('MediaCodec::queueInputBuffer#native')
release = first.get('MediaCodec::renderOutputBufferAndRelease#native')
report = {'pid':pid, 'monoToTraceOffsetNs':int(clock[0]['offset_ns']),
          'firstStages':first,
          'flushesBeforeFirstRelease':[e for e in events if 'flush#native' in e['event']
            and (release is None or e['afterInputMs']<release['afterInputMs'])],
          'firstQueueToReleaseMs':release['afterInputMs']-queue['afterInputMs']
            if queue and release else None,
          'inputToChangedTextureMs':summary.get('firstChangedTextureConsumedAfterInputMs'),
          'physicalDisplayTimeMs':None,
          'boundary':'Codec API slices and Flutter texture consumption; no physical display fence'}
(out/'summary.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report))
