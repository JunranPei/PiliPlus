CREATE PERFETTO TABLE q AS SELECT ts+(1792376173270208000-clock_value) AS ns FROM clock_snapshot WHERE clock_name='REALTIME' LIMIT 1;
CREATE PERFETTO TABLE windows AS
SELECT 'init' AS label,q.ns+4794384000 AS lo,q.ns+5295750000 AS hi FROM q
UNION ALL SELECT 'configure',q.ns+5295953000,q.ns+5327622000 FROM q
UNION ALL SELECT 'start',q.ns+5327667000,q.ns+5606012000 FROM q
UNION ALL SELECT 'start_to_media_input',q.ns+5606012000,q.ns+6492405000 FROM q
UNION ALL SELECT 'media_input_to_workdone',q.ns+6492405000,q.ns+6961385000 FROM q
UNION ALL SELECT 'workdone_to_first_release',q.ns+6961385000,q.ns+7118653000 FROM q
UNION ALL SELECT 'decoder_chain',q.ns+4382390000,q.ns+7118653000 FROM q;
SELECT w.label,t.tid,t.name,s.state,round(sum(min(s.ts+s.dur,w.hi)-max(s.ts,w.lo))/1e6,3) AS ms FROM thread_state s JOIN thread t USING(utid) CROSS JOIN windows w WHERE t.tid IN (3395,68) AND s.ts<w.hi AND s.ts+s.dur>w.lo AND s.dur>0 GROUP BY w.label,t.utid,s.state ORDER BY w.label,t.tid,ms DESC;
SELECT t.tid,t.name,min(s.priority),max(s.priority) FROM sched s JOIN thread t USING(utid) WHERE t.tid IN (2078,3386,3388,3395,68) GROUP BY t.utid;