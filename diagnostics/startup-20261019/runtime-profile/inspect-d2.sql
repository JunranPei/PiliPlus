-- VM Timeline -> native BOOTTIME midpoint from clock-start.json.
-- RPC interval is 5616us: map uncertainty is about +/-2.808ms, not nanosecond precision.
CREATE PERFETTO TABLE q AS SELECT 397741748200 AS ns;
SELECT 'clock',clock_name,ts,clock_value FROM clock_snapshot WHERE clock_name IN ('REALTIME','BOOTTIME','MONOTONIC') LIMIT 8;
SELECT 'input',ts,tag,msg FROM android_logs WHERE tag='StartupTest';
SELECT round((s.ts-q.ns)/1e6,3) AS after_primary_ms,round(s.dur/1e6,3) AS duration_ms,t.tid,t.name AS thread_name,s.name
FROM slice s JOIN thread_track tt ON s.track_id=tt.id JOIN thread t USING(utid) CROSS JOIN q
WHERE s.name IN ('MediaCodec::Init#native','MediaCodec::configure#native','MediaCodec::start#native','MediaCodec::flush#native','MediaCodec::queueInputBuffer#native','MediaCodec::renderOutputBufferAndRelease#native')
AND s.ts BETWEEN q.ns AND q.ns+6000000000 ORDER BY s.ts LIMIT 50;
SELECT round((s.ts-q.ns)/1e6,3) AS after_primary_ms,round(s.dur/1e6,3) AS duration_ms,t.tid,t.name,s.name
FROM slice s JOIN thread_track tt ON s.track_id=tt.id JOIN thread t USING(utid) CROSS JOIN q
WHERE (s.name LIKE 'CCodecBufferChannel::queue(%@ts=0)' OR s.name LIKE 'CCodecBufferChannel::onWorkDone(%@ts=0)') ORDER BY s.ts LIMIT 12;
SELECT t.name,p.name AS process_name,round(sum(min(s.ts+s.dur,q.ns+5500000000)-max(s.ts,q.ns))/1e6,3) AS running_ms
FROM sched s JOIN thread t USING(utid) LEFT JOIN process p USING(upid) CROSS JOIN q
WHERE s.ts<q.ns+5500000000 AND s.ts+s.dur>q.ns GROUP BY s.utid ORDER BY running_ms DESC LIMIT 16;
SELECT name,value FROM stats WHERE value>0 AND (name LIKE '%lost%' OR name LIKE '%overrun%' OR name LIKE '%error%');
SELECT name,count(*) AS n FROM counter_track WHERE name LIKE '%mem%' OR name LIKE '%swap%' OR name LIKE '%rss%' GROUP BY name ORDER BY n DESC LIMIT 16;
