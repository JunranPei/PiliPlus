"""Verify that the unclaimed home-card warmup expires after a measured return."""
import argparse
import hashlib
import json
import re
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
before_audio=adb('shell','dumpsys','media.audio_flinger').decode(errors='replace')
(out/'audio-flinger-before-expiry.txt').write_text(before_audio,encoding='utf-8')
before_audio_utc_ns=int(adb('shell','date','+%s%N').strip())
(out/'audio-focus-before-expiry.txt').write_bytes(adb('shell','dumpsys','audio'))
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
native_opens=[e for e in rows if e['event']=='startup.nativePreload.openAccepted' and e.get('cid')==latest['cid']]
native_closed=[e for e in rows if e['event']=='startup.nativePreload.closed' and e.get('cid')==latest['cid']]
before_tracks=[int(n) for n in re.findall(r'Tracks of which (\d+) are active',before_audio)]
before_deadline=latest['utcUs']*1000 <= before_audio_utc_ns < (latest['utcUs']+8000000)*1000
expected_start=metadata['build'].get('testResumeFixtureMs', 0)
report = {'expectedStartMs':expected_start,'nativeOpens':native_opens,'nativeClosed':native_closed,'beforeDeadlineVerified':before_deadline,
          'beforeAudioUtcNs':before_audio_utc_ns,'beforeActiveTracks':before_tracks,'previousCapture': str(previous), 'traceFiles': names, 'hashAudit': audit,
          'unclaimedBegin': latest, 'closure': closed, 'claims': claims, 'sourceOpens': source_opens,
          'audioFlingerTracks': tracks, 'pixelsCaptured': False,
          'applicationPrefixPreloaded': None, 'nativePreloadExperiment':True,
          'closeAfterBeginMs': [(e['elapsedUs']-latest['elapsedUs'])/1000 for e in closed]}
passed = (len(closed) == 3 and not claims and not source_opens and
          all(7500 <= delta <= 10000 for delta in report['closeAfterBeginMs']) and
          any(e.get('expected') is True for e in closed) and
          len(native_opens)==1 and len(native_closed)==1 and before_deadline and bool(before_tracks) and all(n==0 for n in before_tracks) and
          native_opens[0].get('playing') is False and
          native_opens[0].get('requestedStartMs',0)==expected_start and
          native_opens[0].get('positionMs') in (0,expected_start) and
          7500 <= (native_closed[0]['elapsedUs']-latest['elapsedUs'])/1000 <= 10000 and
          bool(tracks) and all('of which 0 are active' in line for line in tracks))
report['passed'] = passed
(out/'expiry-reviewed.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps({'nativeClosed':len(native_closed),'beforeDeadlineVerified':before_deadline,'passed': passed, 'closeAfterBeginMs': report['closeAfterBeginMs'],
                  'audioFlingerTracks': tracks}), flush=True)
raise SystemExit(0 if passed else 1)
