"""Prepare an actual recommendation-card tap from semantic/layout events.

No image sampling. Preparation snapshots are not accepted measurement traces;
the ordinary capture path still pulls and validates the full announced pair.
"""
import json
from pathlib import Path
import time
import xml.etree.ElementTree as ET

from playback_trace_files import announced_trace_pair, validate_trace_pair


def rearm_verified_home_card(adb, out, package, pid, video, tap, stage, reuse=None, expire_url=False):
    """Invalidate earlier speculation after semantic/setup work, then tap soon.

    Two short inverse scrolls keep the previously verified card. A visible-stage
    run additionally requires a fresh layout event for that same CID; neither
    mode waits for URL/media/decoder readiness. Actual opened CID is checked by
    the ordinary capture reviewer, so a displaced/wrong card is never accepted.
    """
    remote = f'/sdcard/Android/data/{package}/files/playback-diagnostics'
    selected = json.loads((out/'home-preparation/selected.json').read_text(encoding='utf-8'))
    files = (validate_trace_pair(reuse['traceFiles'],pid) if reuse is not None else
             announced_trace_pair((out/'logcat.txt').read_text(encoding='utf-8',errors='replace'),None,pid))
    name = next(n for n in files if n.startswith('flutter-'))
    before = adb('shell','cat',remote+'/'+name)
    (out/'home-rearm-before.jsonl').write_bytes(before)
    before_events = [json.loads(line) for line in before.splitlines(keepends=True) if line.endswith(b'\n')]
    minimum = max(e['seq'] for e in before_events)
    expiry_wait = None
    if expire_url:
        starts = [e for e in before_events if e['event']=='startup.urlPrefetch.begin' and e.get('cid')==video['cid']]
        if not starts:
            raise RuntimeError('No original URL request start for expiry comparison')
        start = starts[-1]
        guest_us = int(adb('shell','date','+%s%N').decode().strip())//1000
        delay = max(0,(start['utcUs'] + 10_200_000 - guest_us)/1e6)
        if delay > 11:
            raise RuntimeError('URL expiry clock mismatch')
        time.sleep(delay)
        expiry_wait = {'originalBegin':start,'guestUtcUsBeforeWait':guest_us,'hostWaitSeconds':delay,
                       'targetUrlAgeSeconds':10.2}
    adb('shell','input','touchscreen','swipe','540','1250','540','1190','500')
    adb('shell','input','touchscreen','swipe','540','1190','540','1250','500')
    started = time.monotonic()
    fresh = None
    if stage == 'visible':
        while time.monotonic()-started < 8:
            raw = adb('shell','cat',remote+'/'+name)
            events = [json.loads(line) for line in raw.splitlines(keepends=True) if line.endswith(b'\n')]
            cards = [e for e in events if e['event']=='startup.visibleCard' and e['seq']>minimum]
            if cards:
                fresh = cards[-1]
                (out/'home-rearm-fresh.jsonl').write_bytes(raw)
                if (fresh['cid'],fresh['bvid']) != (video['cid'],video['bvid']):
                    raise RuntimeError('Rearm chose another card; reject input')
                if fresh.get('title') != selected.get('title'):
                    raise RuntimeError('Rearm title changed after semantic validation')
                left,top,right,bottom = fresh['bounds']
                scale = fresh['devicePixelRatio']
                tap = [round((left+right)*.5*scale),round((top+(bottom-top)*.25)*scale)]
                break
            time.sleep(.05)
        else:
            raise RuntimeError('No fresh same-card layout after rearm')
    record = {'stage':stage,'minimumDartSequence':minimum,'verifiedCard':video,
              'freshLayout':fresh,'hostSecondsAfterScroll':time.monotonic()-started,
              'waitedForUrlOrMediaReady':False,'urlExpiryWait':expiry_wait,'tap':tap}
    (out/'home-rearm.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
    return tap


def prepare_home_card(adb, out, package, prefetch_enabled, reuse=None, media_age=None):
    pid = adb('shell', 'pidof', package).decode().strip()
    remote = f'/sdcard/Android/data/{package}/files/playback-diagnostics'
    deadline = time.monotonic() + 20
    selected = None if reuse is None else validate_trace_pair(reuse['traceFiles'], pid)
    minimum_seq = -1
    chosen = None
    probe = out / 'home-preparation'
    probe.mkdir(exist_ok=False)
    attempts = []
    if reuse is not None:
        if pid != reuse['pid']:
            raise RuntimeError('Home-card process changed; cannot use the previous card or traces')
        name = next(n for n in selected if n.startswith('flutter-'))
        before = adb('shell', 'cat', remote + '/' + name)
        (probe/'before-scroll.jsonl').write_bytes(before)
        minimum_seq = max(json.loads(line)['seq'] for line in before.splitlines(keepends=True) if line.endswith(b'\n'))
        # Real short scrolls cancel and reschedule speculation, without refreshing
        # recommendations. The chosen CID and title must still match afterward.
        adb('shell', 'input', 'touchscreen', 'swipe', '540', '1250', '540', '1190', '500')
        adb('shell', 'input', 'touchscreen', 'swipe', '540', '1190', '540', '1250', '500')
    while time.monotonic() < deadline:
        if selected is None:
            try:
                selected = announced_trace_pair(
                    (out / 'logcat.txt').read_text(encoding='utf-8', errors='replace'), None, pid)
            except ValueError:
                time.sleep(.5)
                continue
        name = next(n for n in selected if n.startswith('flutter-'))
        raw = adb('shell', 'cat', remote + '/' + name)
        (probe / f'probe-{len(attempts):02d}.jsonl').write_bytes(raw)
        events = []
        # An in-flight final line can be partial. Preserve it here; only a later
        # complete validated pull is used for the actual measurement report.
        lines = raw.splitlines(keepends=True)
        for line in lines:
            if line.endswith(b'\n'):
                events.append(json.loads(line))
        cards = [e for e in events if e['event'] == 'startup.visibleCard' and e['seq'] > minimum_seq]
        ready = [e for e in events if e['event'] == 'startup.urlPrefetch.ready']
        attempts.append({'hostMonotonic': time.monotonic(), 'bytes': len(raw),
                         'visibleCards': len(cards), 'readyEvents': len(ready)})
        if cards:
            chosen = cards[-1]
            if reuse is not None and (chosen['cid'], chosen['bvid']) != (reuse['video']['cid'], reuse['video']['bvid']):
                raise RuntimeError('Scrolling selected a different card; reject the same-content comparison')
            if not prefetch_enabled or any(
                    e.get('cid') == chosen['cid'] and e.get('bvid') == chosen['bvid']
                    and e['elapsedUs'] >= chosen['elapsedUs'] for e in ready):
                break
        time.sleep(.5)
    else:
        (probe / 'attempts.json').write_text(json.dumps(attempts, indent=2), encoding='utf-8')
        raise RuntimeError('No eligible visible card with the required URL-ready state')
    (probe / 'attempts.json').write_text(json.dumps(attempts, indent=2), encoding='utf-8')
    (probe / 'selected.json').write_text(json.dumps(chosen, ensure_ascii=False, indent=2), encoding='utf-8')
    remote_ui = '/sdcard/piliplus-listener-home.xml'
    adb('shell', 'uiautomator', 'dump', remote_ui)
    xml = adb('shell', 'cat', remote_ui)
    (out / 'input.xml').write_bytes(xml)
    root = ET.fromstring(xml)
    title = chosen.get('title') or ''
    if not title or not any(title in (n.get('text', '') + '\n' + n.get('content-desc', ''))
                            for n in root.iter('node')):
        raise RuntimeError('Visible-card title is not present in the actual UI semantics')
    if any('发现新版本' in n.get('content-desc', '') for n in root.iter('node')):
        raise RuntimeError('Update dialog obscures recommendation cards')
    if media_age is not None:
        starts = [e for e in events if e['event'] == 'startup.mediaPrefetch.begin'
                  and e.get('cid') == chosen['cid'] and e['seq'] > minimum_seq]
        if not starts:
            raise RuntimeError('No media warmup to age; cannot substitute a URL-only miss')
        start = starts[-1]
        sent = time.monotonic()
        guest_us = int(adb('shell', 'date', '+%s%3N').strip()) * 1000
        received = time.monotonic()
        delay = max(0, (start['utcUs'] + media_age * 1e6 - guest_us) / 1e6)
        if delay > 12:
            raise RuntimeError('Unexpected device clock difference while aging the response')
        (probe/'age-wait.json').write_text(json.dumps({
            'targetMediaAgeSeconds': media_age, 'begin': start, 'guestUtcUs': guest_us,
            'hostMonotonicMidpoint': (sent + received) / 2,
            'clockReadRoundtripMs': (received - sent) * 1000, 'waitSeconds': delay,
            'acceptance': 'Expected claim/miss must be proven by post-input events, not this host wait.'
        }, indent=2), encoding='utf-8')
        time.sleep(delay)
    left, top, right, bottom = chosen['bounds']
    scale = chosen['devicePixelRatio']
    # Upper quarter lies in the cover, away from author and overflow actions.
    tap = [round((left + right) * .5 * scale), round((top + (bottom - top) * .25) * scale)]
    return pid, {'bvid': chosen['bvid'], 'cid': chosen['cid'], 'title': title}, tap
