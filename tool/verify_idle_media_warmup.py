"""Verify that the unclaimed home-card warmup expires after a measured return."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

from capture_startup_listener import collect_trace_snapshot, records

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('previous_capture', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
previous = args.previous_capture.resolve()
out = args.output.resolve()
out.mkdir(exist_ok=False)
metadata = json.loads((previous/'capture.json').read_text(encoding='utf-8'))
assert metadata['status'] == 'captured' and not metadata['errors']
assert metadata['build']['visibleMediaHttpWarmup'] and metadata.get('backSentAfterSeconds')
base = ['adb', '-s', metadata['serial']]
def adb(*parts):
    return subprocess.check_output(base + list(parts), timeout=15)
assert adb('emu', 'avd', 'name').decode().splitlines()[0] == 'PiliPlusStartupIsolated_20261018'
assert adb('shell', 'pidof', 'com.personal.piliplus').decode().strip() == metadata['pid']
time.sleep(8)
names = metadata['traceFiles']
traces = out/'app'
traces.mkdir()
collect_trace_snapshot(adb, '/sdcard/Android/data/com.personal.piliplus/files/playback-diagnostics', traces, names)
audit = {}
for name in names:
    before = (previous/'app'/name).read_bytes()
    after = (traces/name).read_bytes()
    assert after.startswith(before), 'Snapshot did not extend the previous exact trace'
    audit[name] = {'previousSha256': hashlib.sha256(before).hexdigest(),
                   'sha256': hashlib.sha256(after).hexdigest(), 'extendsPrevious': True}
events, errors = records(traces, names)
assert not errors
begins = [e for e in events if e['event'] == 'startup.mediaPrefetch.begin']
assert len(begins) >= 2, 'No fresh unclaimed media warmup after returning home'
latest = begins[-1]
rows = [e for e in events if e.get('elapsedUs', -1) >= latest['elapsedUs']]
closed = [e for e in rows if e['event'] in (
    'startup.mediaPrefetch.isolated.video.closed', 'startup.mediaPrefetch.isolated.audio.closed',
    'startup.mediaPrefetch.isolated.closed') and e.get('cid') == latest['cid']]
claims = [e for e in rows if e['event'] == 'startup.mediaPrefetch.claim']
source_opens = [e for e in rows if e['event'] == 'source.open.begin']
audio = adb('shell', 'dumpsys', 'media.audio_flinger').decode(errors='replace')
(out/'audio-flinger.txt').write_text(audio, encoding='utf-8')
tracks = [line.strip() for line in audio.splitlines() if 'Tracks of which' in line]
report = {'previousCapture': str(previous), 'traceFiles': names, 'hashAudit': audit,
          'unclaimedBegin': latest, 'closure': closed, 'claims': claims, 'sourceOpens': source_opens,
          'audioFlingerTracks': tracks, 'pixelsCaptured': False,
          'applicationPrefixPreloaded': False,
          'closeAfterBeginMs': [(e['elapsedUs']-latest['elapsedUs'])/1000 for e in closed]}
passed = (len(closed) == 3 and not claims and not source_opens and
          all(7500 <= delta <= 10000 for delta in report['closeAfterBeginMs']) and
          any(e.get('expected') is True for e in closed) and
          all(e.get('deliveredBytes', 0) == 0 and e.get('receivedBytes', 0) == 0 for e in closed) and
          bool(tracks) and all('of which 0 are active' in line for line in tracks))
report['passed'] = passed
(out/'expiry-reviewed.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps({'passed': passed, 'closeAfterBeginMs': report['closeAfterBeginMs'],
                  'audioFlingerTracks': tracks}), flush=True)
raise SystemExit(0 if passed else 1)
