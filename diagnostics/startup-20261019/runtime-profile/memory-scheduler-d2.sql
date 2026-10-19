CREATE PERFETTO TABLE w AS SELECT 397741748200 AS q, 400822756200 AS begin_ns, 401697636200 AS end_ns;
SELECT t.name,p.name AS process_name,s.state,s.io_wait,round(sum(min(s.ts+s.dur,w.end_ns)-max(s.ts,w.begin_ns))/1e6,3) AS ms
FROM thread_state s JOIN thread t USING(utid) LEFT JOIN process p USING(upid) CROSS JOIN w
WHERE s.ts<w.end_ns AND s.ts+s.dur>w.begin_ns AND (t.name IN ('MediaCodec_loop','Thread-6','CodecLooper','sh.hevc.decoder','kswapd0'))
GROUP BY s.utid,s.state,s.io_wait ORDER BY t.name,ms DESC;
SELECT s.name,count(*) AS n,round(sum(s.dur)/1e6,3) AS duration_ms FROM slice s
WHERE s.name LIKE '%reclaim%' OR s.name LIKE '%kswapd%' GROUP BY s.name ORDER BY duration_ms DESC LIMIT 12;
SELECT p.pid,p.name,ct.name AS counter_name,min(c.value)/1024/1024 AS minimum_mib,max(c.value)/1024/1024 AS maximum_mib
FROM counter c JOIN process_counter_track ct ON c.track_id=ct.id JOIN process p USING(upid) CROSS JOIN w
WHERE c.ts BETWEEN w.q AND w.q+5500000000 AND ct.name IN ('mem.rss','mem.swap','mem.rss.anon','mem.rss.shmem')
GROUP BY ct.id HAVING p.name LIKE '%piliplus%' ORDER BY maximum_mib DESC;
SELECT p.name,ct.name,min(c.value)/1024/1024 AS minimum_mib,max(c.value)/1024/1024 AS maximum_mib,(max(c.value)-min(c.value))/1024/1024 AS range_mib
FROM counter c JOIN process_counter_track ct ON c.track_id=ct.id JOIN process p USING(upid) CROSS JOIN w
WHERE c.ts BETWEEN w.q AND w.q+5500000000 AND ct.name='mem.rss' GROUP BY ct.id ORDER BY range_mib DESC LIMIT 12;
SELECT ct.name,min(c.value) AS minimum,max(c.value) AS maximum,max(c.value)-min(c.value) AS delta
FROM counter c JOIN counter_track ct ON c.track_id=ct.id CROSS JOIN w
WHERE c.ts BETWEEN w.q AND w.q+5500000000 AND (ct.name LIKE '%allocstall%' OR ct.name LIKE '%pswp%' OR ct.name LIKE '%pgscan%') GROUP BY c.track_id;
