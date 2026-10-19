"""Bounded whole-app Dart/native diagnostic; never a release speed result."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import websocket

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'com.personal.piliplus'
NDK = Path('D:/Android_Studio_Sdk/ndk/28.2.13676358/simpleperf')
BASE = ROOT/'diagnostics/startup-20261018/rollback-baseline'
spec = importlib.util.spec_from_file_location('bounded_capture', BASE/'capture_timing.py')
bounded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bounded)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('apk', type=Path)
    p.add_argument('label')
    p.add_argument('--index', type=int, default=5)
    args = p.parse_args()
    label = f'{args.label}-{args.index}'
    out = ROOT/'diagnostics/startup-20261017/mpv-phase1'/label
    if out.exists():
        raise SystemExit(f'Refusing to overwrite: {out}')
    manifest = json.loads(args.apk.with_suffix('.build.json').read_text())
    assert manifest['buildMode'] == 'profile'
    assert 'PLAYBACK_FULL_PROFILE=true' in manifest['defines']
    assert not manifest['sourcePreparationOverlapsPresentation']
    assert hashlib.file_digest(args.apk.open('rb'), 'sha256').hexdigest() == manifest['sha256']
    subprocess.run(['powershell', '-NoProfile', '-File', str(BASE/'memory-gate.ps1'),
                    '-Kind', 'capture', '-MinimumCommitHeadroomGiB', '8'], check=True)
    adb_command = ['adb', '-s', 'emulator-5556']

    def adb(*parts):
        return subprocess.check_output(adb_command+list(parts), timeout=45)

    assert adb('shell', 'getprop', 'sys.boot_completed').strip() == b'1'
    adb('shell', 'am', 'force-stop', PACKAGE)
    adb('install', '-r', '-d', str(args.apk.resolve()))
    remote_apk = adb('shell', 'pm', 'path', PACKAGE).decode().strip().removeprefix('package:')
    assert adb('shell', 'sha256sum', remote_apk).decode().split()[0] == manifest['sha256']
    # Do not alter perf_event_paranoid, kernel permissions, AVD RAM or app data.
    simpleperf_remote = '/data/local/tmp/piliplus-simpleperf'
    adb('push', str(NDK/'bin/android/x86_64/simpleperf'), simpleperf_remote)
    adb('shell', 'chmod', '755', simpleperf_remote)
    feature = subprocess.run(adb_command+['shell', simpleperf_remote, 'list', '--show-features'],
                             capture_output=True, timeout=30)
    features = (feature.stdout+feature.stderr).decode('utf8', 'replace')
    adb('logcat', '-c')
    adb('shell', 'am', 'start', '-W', '-n', PACKAGE+'/com.personal.piliplus.MainActivity',
        '--ez', 'enable-dart-profiling', 'true', '--es', 'dart-flags',
        shlex.quote('--profiler --profile_period=1000 --sample_buffer_duration=12'))
    deadline = time.monotonic()+25
    match = None
    while time.monotonic() < deadline:
        log = adb('logcat', '-d', '-s', 'flutter').decode('utf8', 'replace')
        match = re.search(r'The Dart VM service is listening on (http://127.0.0.1:(\d+)/\S+/)', log)
        if match:
            break
        time.sleep(.2)
    if match is None:
        raise RuntimeError('Profile build has no Dart VM service; no playback trial recorded')
    port = adb('forward', 'tcp:0', 'tcp:'+match[2]).decode().strip()
    service_base = match[1].replace(':'+match[2]+'/', ':'+port+'/')

    def rpc(method, parameters=None):
        url = service_base+method+'?'+urllib.parse.urlencode(parameters or {})
        with urllib.request.urlopen(url, timeout=30) as response:
            result = json.load(response)
        if 'error' in result:
            raise RuntimeError(f'{method}: {result["error"]}')
        return result['result']

    isolate = None
    while time.monotonic() < deadline:
        isolates = rpc('getVM')['isolates']
        isolate = next((i['id'] for i in isolates if i['name'] == 'main'), None)
        if isolate:
            details = rpc('getIsolate', {'isolateId': isolate})
            if 'ext.piliplus.runtimeProfile' in details.get('extensionRPCs', []):
                break
        time.sleep(.2)
    if not isolate:
        raise RuntimeError('No main isolate')
    original_capture = bounded.recorder.capture
    profiler_process = None
    profiler_log = None
    begin_us = None
    initial_isolates = []
    timeline_socket = None
    timeline_reader = None
    timeline_done = threading.Event()

    def save(name, value):
        (out/name).write_text(json.dumps(value, indent=None if name.startswith('dart-') else 2), encoding='utf8')

    def wrapped_capture(*parts, **kwargs):
        nonlocal profiler_process, profiler_log, begin_us, initial_isolates
        before = kwargs.get('before_recording')

        def start():
            nonlocal profiler_process, profiler_log, begin_us, initial_isolates
            nonlocal timeline_socket, timeline_reader
            save('profile-build.json', manifest)
            save('capture-context.json', {
                'processForceStoppedBeforeHomeLaunch': True,
                'waitedForVmServiceBeforeSearch': True,
                'playerStandby': manifest['standbyEnabled'],
                'mediaPreloaded': False,
                'releaseSpeedComparable': False,
                'nativeSamplesRequestedHz': 1000,
                'nativeSamplingDurationSeconds': 15,
                'dartSampleBufferDurationSeconds': 12,
                'nativeUserBufferMiB': 8,
                'nativeFileLimitMiB': 64,
                'nativeDwarfStackBytes': 8192,
                'boundary': 'CPU stacks are sampled; missing samples are not proof of idle time.',
            })
            (out/'simpleperf-features.txt').write_text(features)
            save('vm-flags.json', rpc('getFlagList'))
            save('timeline-flags-before.json', rpc('getVMTimelineFlags'))
            rpc('setFlag', {'name': 'profiler', 'value': 'true'})
            # The HTTP VM service uses enum-list syntax, not a quoted JSON array.
            rpc('setVMTimelineFlags', {'recordedStreams':
                '[Compiler,Dart,Embedder,GC,Isolate,Microtask,VM]'})
            rpc('clearVMTimeline')
            timeline_socket = websocket.create_connection(
                service_base.replace('http://', 'ws://')+'ws', timeout=3,
                http_no_proxy=['127.0.0.1', 'localhost'])
            timeline_socket.send(json.dumps({'jsonrpc':'2.0', 'id':1,
                'method':'streamListen', 'params':{'streamId':'Timeline'}}))
            reply = json.loads(timeline_socket.recv())
            if reply.get('id') != 1 or 'error' in reply:
                raise RuntimeError(f'Timeline subscription failed: {reply}')
            def receive_timeline():
                with (out/'dart-timeline-stream.jsonl').open('w', encoding='utf8') as sink:
                    while not timeline_done.is_set():
                        try:
                            batch = json.loads(timeline_socket.recv())
                        except websocket.WebSocketTimeoutException:
                            continue
                        except (websocket.WebSocketException, ValueError, OSError) as error:
                            if not timeline_done.is_set():
                                save('timeline-stream-error.json', {'type':type(error).__name__})
                            return
                        event = batch.get('params', {}).get('event', {})
                        for item in event.get('timelineEvents', []):
                            sink.write(json.dumps(item, separators=(',',':'))+'\n')
                        sink.flush()
            timeline_reader = threading.Thread(target=receive_timeline, daemon=True)
            timeline_reader.start()
            initial_isolates = rpc('getVM')['isolates']
            for item in initial_isolates:
                rpc('clearCpuSamples', {'isolateId': item['id']})
            begin_us = rpc('getVMTimelineMicros')['timestamp']
            save('clock-start.json', rpc('ext.piliplus.runtimeProfile',
                 {'isolateId': isolate, 'action': 'arm'}))
            if before:
                before()
            native_command = [simpleperf_remote, 'record', '-e', 'task-clock:u', '-f', '1000',
                              '--call-graph', 'dwarf,8192', '--no-callchain-joiner',
                              '--clockid', 'monotonic', '--user-buffer-size', '8M',
                              '--size-limit', '64M', '--duration', '15', '--app', PACKAGE,
                              '-o', '/data/local/tmp/piliplus-runtime-perf.data']
            # d1r proved feature advertisement does not imply sched_switch access.
            # On-CPU app sampling passed a separate 0.5s capability probe.
            # Off-CPU durations still come from the bounded Perfetto scheduler.
            save('native-command.json', native_command)
            profiler_log = (out/'simpleperf-record.log').open('wb')
            profiler_process = subprocess.Popen(adb_command+['shell']+native_command,
                                                stdout=profiler_log, stderr=subprocess.STDOUT)
            time.sleep(.3)
        kwargs['before_recording'] = start
        return original_capture(*parts, **kwargs)

    bounded.recorder.capture = wrapped_capture
    sys.argv = ['capture_timing.py', args.label, '--serial', 'emulator-5556',
                '--index', str(args.index), '--seconds', '25', '--keep-player',
                '--collect-standby', '--verify-search-uri', '--perfetto', '--memory-counters']
    try:
        bounded.main()
    finally:
        # Preserve whatever succeeded, including explicit profiler failures.
        if begin_us is not None:
            finish_us = rpc('getVMTimelineMicros')['timestamp']
            save('clock-end.json', rpc('ext.piliplus.runtimeProfile',
                 {'isolateId': isolate, 'action': 'stop'}))
            save('dart-timeline.json', rpc('getVMTimeline'))
            final_isolates = rpc('getVM')['isolates']
            save('isolates.json', {'before': initial_isolates, 'after': final_isolates,
                                  'beginUs': begin_us, 'endUs': finish_us})
            for item in final_isolates:
                try:
                    samples = rpc('getCpuSamples', {'isolateId': item['id'],
                                  'timeOriginMicros': begin_us, 'timeExtentMicros': finish_us-begin_us})
                except RuntimeError as error:
                    samples = {'unavailable': str(error)}
                save('dart-cpu-'+item['id'].replace('/', '-')+'.json', samples)
            rpc('setFlag', {'name': 'profiler', 'value': 'false'})
            rpc('setVMTimelineFlags', {'recordedStreams': '[]'})
        if timeline_socket is not None:
            timeline_done.set()
            timeline_socket.close()
            timeline_reader.join(timeout=4)
        if profiler_process is not None:
            try:
                profiler_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # --duration is bounded; retain timeout as a failure, no broad pkill.
                save('simpleperf-timeout.json', {'hostPid': profiler_process.pid})
            profiler_log.close()
            save('simpleperf-result.json', {'returncode': profiler_process.poll()})
            if profiler_process.returncode == 0:
                adb('pull', '/data/local/tmp/piliplus-runtime-perf.data', str(out/'native-perf.data'))
        adb('forward', '--remove', 'tcp:'+port)


if __name__ == '__main__':
    main()
