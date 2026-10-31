"""Bounded cold raster/system trace diagnosis. Never report as release speed."""
import argparse
import csv
import io
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('capture',type=Path)
args=parser.parse_args();capture=args.capture.resolve()
metadata=json.loads((capture/'capture.json').read_text(encoding='utf-8'))
assert metadata.get('engineSkiaTraceRequested') and metadata['build']['buildMode']=='profile'
summary=metadata['summary'];pid=int(metadata['pid']);mono=int(summary['inputDispatchMonoNs'])
out=capture/'skia-analysis';out.mkdir(exist_ok=False)
processor=ROOT/'diagnostics/startup-20261016/perfetto/trace_processor_shell.exe'

def query(name,sql):
    source=out/(name+'.sql');source.write_text(sql,encoding='utf-8')
    result=subprocess.run([str(processor),'query','-f',str(source),str(capture/'system.pftrace')],
                          capture_output=True,text=True,encoding='utf-8',check=True)
    (out/(name+'.csv')).write_text(result.stdout,encoding='utf-8')
    (out/(name+'.log')).write_text(result.stderr,encoding='utf-8')
    return list(csv.DictReader(io.StringIO(result.stdout.strip())))

clocks=query('clock',f"SELECT ts,clock_value,ts-clock_value AS offset_ns FROM clock_snapshot WHERE clock_name='MONOTONIC' ORDER BY abs(clock_value-{mono}) LIMIT 1;")
assert clocks,'No clock mapping'
offset=int(clocks[0]['offset_ns']);anchor=mono+offset
names=query('slice-names',f"""SELECT s.name,t.name AS thread,count(*) AS n,
round(max(s.dur)/1e6,3) AS max_ms,round(sum(s.dur)/1e6,3) AS total_ms
FROM slice s JOIN thread_track tt ON s.track_id=tt.id JOIN thread t USING(utid)
JOIN process p USING(upid) WHERE p.pid={pid} AND s.ts>={anchor} AND s.ts<{anchor}+3000000000
GROUP BY s.name,t.name ORDER BY max_ms DESC;""")
long=query('long-slices',f"""SELECT s.id,s.parent_id,s.name,t.name AS thread,t.tid,
round((s.ts-{anchor})/1e6,3) AS begin_ms,round(s.dur/1e6,3) AS duration_ms
FROM slice s JOIN thread_track tt ON s.track_id=tt.id JOIN thread t USING(utid)
JOIN process p USING(upid) WHERE p.pid={pid} AND s.ts>={anchor} AND s.ts<{anchor}+3000000000
AND s.dur>10000000 ORDER BY s.dur DESC LIMIT 100;""")
events=[json.loads(line) for name in summary['traceFiles'] if name.startswith('flutter-')
        for line in (capture/'app'/name).read_text(encoding='utf-8').splitlines()]
frames=[e for e in events if e['event']=='frame.raster' and
        0<e['timestamps']['rasterStart']*1000-mono<3_000_000_000]
assert frames,'No post-input raster frame'
frame=max(frames,key=lambda e:e['rasterUs']);start=frame['timestamps']['rasterStart']*1000+offset
end=frame['timestamps']['rasterFinish']*1000+offset
states=query('long-raster-thread-states',f"""SELECT t.tid,t.name,s.state,
round(sum(min(s.ts+s.dur,{end})-max(s.ts,{start}))/1e6,3) AS ms
FROM thread_state s JOIN thread t USING(utid) JOIN process p USING(upid)
WHERE p.pid={pid} AND s.dur>0 AND s.ts<{end} AND s.ts+s.dur>{start}
GROUP BY t.tid,t.name,s.state ORDER BY ms DESC LIMIT 60;""")
shader=[r for r in names if any(word in r['name'].lower() for word in ['grgl','shader','compile','skia'])]
report={'pid':pid,'monoToTraceOffsetNs':offset,'releaseSpeedComparable':False,
        'largestInitialRaster':frame,'rasterStartAfterInputMs':(start-anchor)/1e6,
        'rasterEndAfterInputMs':(end-anchor)/1e6,'shaderRelatedSlices':shader,
        'longestAppSlices':long[:20],'longRasterThreadStates':states,
        'physicalPresentationMeasured':False,'boundary':'Profile/system tracing is diagnostic only. Shader names or long raster alone do not establish the cause.'}
(out/'summary.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps({'rasterMs':frame['rasterUs']/1000,'shaderRelatedSliceNames':len(shader),
                  'longestSlices':long[:8],'output':str(out)}))
