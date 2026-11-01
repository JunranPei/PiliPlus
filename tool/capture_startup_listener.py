"""Measure the real search-to-player path using listeners; never capture pixels.

The summary names the observed boundaries. Texture consumption is not a physical
present fence. Preserves failed runs and refuses to overwrite earlier captures.
"""
import argparse
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import shlex
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

from playback_trace_files import announced_trace_pair, validate_trace_pair
from startup_home_card import prepare_home_card
from startup_input_target import input_target
from startup_resource_profile import startup_resource_profile, wait_startup_memory

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'com.personal.piliplus'
spec = importlib.util.spec_from_file_location(
    'startup_memory', ROOT/'diagnostics/startup-20261018/rollback-baseline/capture_timing.py')
memory_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory_module)


def force_stop_before_capture(adb, package, sleep=time.sleep):
    for attempt in range(3):
        try:
            adb('shell', 'am', 'force-stop', package)
            return
        except subprocess.TimeoutExpired:
            # A lost/late shell completion is not proof the stop failed. Verify
            # the requested state before considering another destructive call.
            def read(*args):
                value = adb(*args)
                return value.decode('utf-8', errors='replace') if isinstance(value, bytes) else value
            try:
                user = read('shell', 'am', 'get-current-user')
                details = read('shell', 'dumpsys', 'package', package)
                processes = read('shell', 'ps', '-A', '-o', 'NAME')
                if not all(isinstance(v, str) for v in [user, details, processes]):
                    raise ValueError('Preparation adapter did not return observations')
                user = user.strip()
                stopped = user.isdigit() and re.search(
                    rf'^\s*User {user}:.*\bstopped=true\b', details, re.MULTILINE)
                alive = any(name.strip() == package or name.strip().startswith(package + ':')
                            for name in processes.splitlines())
                if stopped and not alive:
                    return {'commandTimedOut': True, 'verifiedStopped': True,
                            'currentUser': user, 'packageProcessCount': 0,
                            'packageState': stopped.group(0).strip()}
            except (subprocess.SubprocessError, ValueError):
                pass
            raise
        except subprocess.CalledProcessError as error:
            stderr = (error.stderr or b'').decode('utf-8', errors='replace').lower()
            transient = any(message in stderr for message in [
                'could not read ok from adb server',
                'cannot connect to daemon',
                'failed to start daemon',
            ])
            if not transient or attempt == 2:
                raise
            sleep(1)


def dump_pre_input_ui(adb, remote, out, sleep=time.sleep):
    """Retry only a read-only UI dump before measured input; preserve attempts."""
    for attempt in range(3):
        record = {'remote': remote, 'attempt': attempt + 1,
                  'hostNs': time.perf_counter_ns()}
        try:
            result = adb('shell', 'uiautomator', 'dump', remote)
            record['exit'] = 0
            return result
        except subprocess.TimeoutExpired:
            record['timeout'] = True
            if attempt == 2:
                raise
        except subprocess.CalledProcessError as error:
            stderr = (error.stderr or b'').decode('utf8', errors='replace')
            stdout = (error.stdout or b'').decode('utf8', errors='replace')
            record.update(exit=error.returncode, stdout=stdout, stderr=stderr)
            empty_transport_exit = error.returncode == 255 and not (stdout.strip() or stderr.strip())
            transient = any(s in stderr.lower() for s in [
                'could not read ok from adb server', 'cannot connect to daemon',
                'device offline', 'error: closed',
            ])
            if not (empty_transport_exit or transient) or attempt == 2:
                raise
        finally:
            with (out/'pre-input-ui-dump-attempts.jsonl').open('a', encoding='utf8') as stream:
                stream.write(json.dumps(record) + '\n')
        sleep(.25)


def search_video_uri(video, progress_ms=0, history_resume=False):
    uri = f'bilibili://video/{video["bvid"]}?cid={video["cid"]}'
    return uri if history_resume else f'{uri}&start_progress={progress_ms}'


def search_clear_target(xml):
    root=ET.fromstring(xml)
    def bounds(node):
        match=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',node.get('bounds',''))
        if not match:
            raise ValueError('Search control has no valid bounds')
        left,top,right,bottom=map(int,match.groups())
        if right<=left or bottom<=top:
            raise ValueError('Search control has empty bounds')
        return left,top,right,bottom
    editors=[node for node in root.iter('node')
             if node.get('package')==PACKAGE
             and node.get('class')=='android.widget.EditText'
             and node.get('enabled')=='true']
    if len(editors)!=1:
        raise ValueError('Expected one enabled search field')
    _,field_top,field_right,field_bottom=bounds(editors[0])
    nodes=[node for node in root.iter('node')
           if node.get('package')==PACKAGE and node.get('content-desc')=='清空'
           and node.get('clickable')=='true' and node.get('enabled')=='true']
    # Search history has a second identically labelled clear button. Use the
    # input row's semantic geometry, never a global first-match or fixed tap.
    nodes=[node for node in nodes if bounds(node)[0]>=field_right
           and field_top<=(bounds(node)[1]+bounds(node)[3])/2<=field_bottom]
    if len(nodes)!=1:
        raise ValueError('Expected one enabled clear button beside the search field')
    left,top,right,bottom=bounds(nodes[0])
    return [(left+right)//2,(top+bottom)//2]


def fill_verified_search_uri(adb, out, uri, sleep=time.sleep):
    """Repair pre-input key loss in place; never submit or replay a measured tap."""
    observations=[]
    def read(label):
        remote='/sdcard/piliplus-listener-input.xml'
        dump_pre_input_ui(adb,remote,out,sleep=sleep)
        xml=adb('shell','cat',remote)
        (out/(label+'.xml')).write_bytes(xml)
        nodes=list(ET.fromstring(xml).iter('node'))
        if any('发现新版本' in n.get('content-desc','') for n in nodes):
            raise RuntimeError('Update dialog obscures search; no measured tap')
        editors=[n for n in nodes if n.get('package')==PACKAGE and
                 n.get('class')=='android.widget.EditText' and n.get('enabled')=='true']
        editor=editors[0] if len(editors)==1 else None
        observations.append({'stage':label,'text':editor.get('text') if editor is not None else None,
                             'focused':editor.get('focused') if editor is not None else None})
        (out/'search-input-preparation.json').write_text(json.dumps(observations,indent=2),encoding='utf-8')
        return xml,editor
    def clear(xml):
        adb('shell','input','touchscreen','tap',*map(str,search_clear_target(xml)))
    xml,editor=read('search-editor-ready-0')
    for attempt in range(3):
        if editor is not None and editor.get('focused')=='true':break
        if editor is not None:
            coords=list(map(int,re.findall(r'\d+',editor.get('bounds',''))))
            if len(coords)!=4:raise RuntimeError('Search field has no valid bounds')
            adb('shell','input','touchscreen','tap',str((coords[0]+coords[2])//2),str((coords[1]+coords[3])//2))
        sleep(.3)
        xml,editor=read(f'search-editor-ready-{attempt+1}')
    if editor is None or editor.get('focused')!='true':
        raise RuntimeError('Search editor not ready; no text or measured tap sent')
    if editor.get('text'):clear(xml)
    for offset in range(0,len(uri),12):
        adb('shell','input','text',shlex.quote(uri[offset:offset+12]))
        sleep(.1)
    xml,editor=read('search-input-first')
    if editor is None or editor.get('text')!=uri or editor.get('focused')!='true':
        # Android input text emits a burst of key events; an IME/Flutter editing
        # update can lose a character. Refill once with paced individual events.
        clear(xml)
        command='for ch in '+' '.join(shlex.quote(c) for c in uri)+'; do input text "$ch"; sleep 0.04; done'
        adb('shell',command)
        xml,editor=read('search-input-paced')
    (out/'input.xml').write_bytes(xml)
    if editor is None or editor.get('text')!=uri or editor.get('focused')!='true':
        raise RuntimeError('Search text still differs after paced repair; no measured tap')
    return xml


def hide_search_ime_before_input(adb, out, uri):
    """Cancellation fixture: finish hiding the IME before the measured tap."""
    observations=[]
    def state():
        raw=adb('shell','dumpsys','input_method').decode(errors='replace')
        shown=re.findall(r'mInputShown=(true|false)',raw)
        visible=re.findall(r'mImeWindowVis=(0x[0-9a-fA-F]+|[0-9]+)',raw)
        if not shown or not visible:
            raise RuntimeError('Cannot determine IME state before cancellation fixture')
        hidden=all(v=='false' for v in shown) and all(int(v,0)==0 for v in visible)
        observations.append({'hostNs':time.perf_counter_ns(),'shown':shown,'visible':visible})
        (out/'ime-before-input.json').write_text(json.dumps(observations,indent=2))
        return hidden
    if not state():
        adb('shell','input','keyevent','4')
        deadline=time.monotonic()+5
        while not state():
            if time.monotonic()>=deadline:
                raise RuntimeError('IME did not hide before measured input')
            time.sleep(.04)
    remote='/sdcard/piliplus-listener-hidden-ime.xml'
    dump_pre_input_ui(adb,remote,out)
    xml=adb('shell','cat',remote)
    (out/'search-with-hidden-ime.xml').write_bytes(xml)
    editors=[n for n in ET.fromstring(xml).iter('node')
             if n.get('package')==PACKAGE and n.get('class')=='android.widget.EditText']
    if len(editors)!=1 or editors[0].get('text')!=uri:
        raise RuntimeError('IME dismissal changed the verified search entry')


def records(path, selected_names=None):
    result, errors = [], []
    names = validate_trace_pair(selected_names if selected_names is not None
                                else [file.name for file in path.glob('*.jsonl')])
    for name in names:
        file = path/name
        for number, line in enumerate(file.read_text(encoding='utf-8').splitlines(), 1):
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                errors.append({'file': file.name, 'line': number})
    return result, errors


def collect_trace_snapshot(adb, remote, traces, names, sleep=time.sleep):
    """Preserve each pull; retry only an incomplete final record, never corruption."""
    previous = {}
    audit = []
    for attempt in range(3):
        destination = traces.parent / f'trace-pull-{attempt + 1:02d}'
        destination.mkdir(exist_ok=False)
        retryable = False
        current = {}
        for name in names:
            adb('pull', remote + '/' + name, str(destination / name))
            data = (destination / name).read_bytes()
            if name in previous and not data.startswith(previous[name]):
                raise ValueError('Trace changed instead of extending: ' + name)
            current[name] = data
            lines = data.splitlines()
            for number, line in enumerate(lines, 1):
                try:
                    json.loads(line)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    if number != len(lines) or data.endswith(b'\n'):
                        raise ValueError(f'Corrupt complete trace record: {name}:{number}')
                    retryable = True
            if data and not data.endswith(b'\n'):
                retryable = True
        audit.append({'attempt': attempt + 1, 'incompleteTail': retryable,
                      'files': {name: {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                                       'extendsPrevious': name in previous}
                                for name, data in current.items()}})
        (traces.parent / 'trace-pull-audit.json').write_text(
            json.dumps(audit, indent=2), encoding='utf-8')
        if not retryable:
            for name, data in current.items():
                (traces / name).write_bytes(data)
            return
        previous = current
        if attempt < 2:
            sleep(1.2)
    raise ValueError('Trace tail remained incomplete after three preserved pulls')


def summarize(path, cid, selected_names=None, after_native_sequence=None):
    names = validate_trace_pair(selected_names if selected_names is not None
                                else [file.name for file in path.glob('*.jsonl')])
    events, errors = records(path, names)
    native = sorted((e for e in events if e.get('stream') == 'android'),
                    key=lambda e: e['monoNs'])
    if after_native_sequence is not None:
        native = [e for e in native if e['seq'] > after_native_sequence]
    dart = sorted((e for e in events if 'elapsedUs' in e), key=lambda e: e['elapsedUs'])
    opens = [e for e in native if e['event'] == 'source.open.begin' and
             e.get('data', {}).get('cid') == cid]
    result = {'expectedCid': cid, 'parseErrors': errors, 'traceFiles': names,
              'afterNativeSequence': after_native_sequence,
              'physicalDisplayTimeMs': None,
              'boundary': 'Input dispatch, API delivery and Flutter-consumed texture metadata; not image recognition or physical display',
              'nativeRecords': len(native), 'dartRecords': len(dart)}
    if not opens:
        return result | {'validSource': False, 'reason': 'No native source-open marker for expected CID'}
    opened = opens[0]
    taps = [e for e in native if e['event'] == 'input.touch' and
            e.get('data', {}).get('action') == 0 and e['monoNs'] <= opened['monoNs']]
    if not taps:
        return result | {'validSource': True, 'validInput': False,
                         'reason': 'Missing native input anchor; do not substitute host adb time'}
    tap = taps[-1]
    # eventTime has millisecond resolution in the uptime clock; use the
    # dispatch event's mono time for the explicit input-dispatch metric.
    origin = tap['monoNs']
    result.update(validSource=True, validInput=True,
                  inputDispatchMonoNs=origin, inputEventUptimeMs=tap['data']['eventUptimeMs'],
                  sourceOpenNativeMarkAfterInputMs=(opened['monoNs']-origin)/1e6,
                  input= {'x':tap['data']['x'], 'y':tap['data']['y']})
    identity = opened['data']
    consumed = []
    for event in native:
        if event['event'] != 'texture.consumed' or event['monoNs'] < opened['monoNs']:
            continue
        data = event['data']
        context = data.get('requestContext', {})
        if not all(context.get(key) == identity.get(key) for key in ('cid', 'requestId', 'sourceRevision')):
            continue
        if data.get('textureId') != identity.get('textureId'):
            continue
        consumed.append(data)
    changed = [e for e in consumed if not e.get('sameTimestampAsPrevious', True)
               and e.get('textureTimestampNs', 0) > 0 and e.get('surfaceValid')]
    result.update(textureSamples=len(consumed),
                  validTextureObservation=bool(changed),
                  firstChangedTextureConsumedAfterInputMs=(changed[0]['callbackMonoNs']-origin)/1e6 if changed else None,
                  firstChangedTextureTimestampNs=changed[0]['textureTimestampNs'] if changed else None,
                  lastTextureConsumedAfterInputMs=(consumed[-1]['callbackMonoNs']-origin)/1e6 if consumed else None,
                  observedTextureFrames=max((e.get('observedFrames',0) for e in consumed), default=0),
                  changedTextureTimestamps=max((e.get('changedTimestampFrames',0) for e in consumed), default=0),
                  maxTextureCallbackGapMs=max((e.get('maxCallbackGapNs',0) for e in consumed), default=0)/1e6,
                  sourceIdentity={key:identity.get(key) for key in ('cid','requestId','sourceRevision','textureId','playerId')})
    clocks = [e for e in dart if e['event']=='clock.sync' and e.get('native',{}).get('monoNs')]
    if clocks:
        sync = min(clocks, key=lambda e:e['dartReceiveUs']-e['dartSendUs'])
        offset = sync['native']['monoNs']/1000-(sync['dartSendUs']+sync['dartReceiveUs'])/2
        uncertainty = (sync['dartReceiveUs']-sync['dartSendUs'])/2000
        result['dartToNativeClockUncertaintyMs'] = uncertainty
        def after(event):
            return (event['elapsedUs']+offset-origin/1000)/1000
        selected = [e for e in dart if after(e)>=0]
        result['milestones'] = [{'event':e['event'],'afterInputMs':after(e)} for e in selected
            if e['event'] in ('query.primary.begin','query.primary.end','source.open.begin',
                             'source.open.accepted','source.open.return','command.play',
                             'startup.urlPrefetch.claim','startup.mediaPrefetch.claim',
                             'ui.frameReady.after','media.playing','media.buffering')]
        requests = {}
        for event in selected:
            if event['event'].startswith('http.') and 'httpRequestId' in event:
                row = requests.setdefault(event['httpRequestId'],{})
                row[event['event']] = after(event)
                for key in ('host','path','status','bytes','reason'):
                    if key in event: row[key]=event[key]
        result['apiRequests'] = list(requests.values())
        result['buffering'] = [{'afterInputMs':after(e),'value':e.get('value')} for e in selected
                               if e['event']=='media.buffering']
        result['pauses'] = [after(e) for e in selected if e['event']=='command.pause']
        frames = [e for e in selected if e['event']=='frame.raster']
        result['flutterFrames'] = {'count':len(frames),
            'maxBuildMs':max((e['buildUs'] for e in frames), default=0)/1000,
            'maxRasterMs':max((e['rasterUs'] for e in frames), default=0)/1000}
    result['textureObserverErrors'] = [e['data'] for e in native if e['event'] in
        ('texture.observerUnavailable','texture.readError')]
    window=[e['data'] for e in native if e['event']=='window.frameMetrics' and e['monoNs']>=origin]
    result['nativeWindowFrames']={'count':len(window),
        'maxTotalMs':max((e.get('totalNs',0) for e in window),default=0)/1e6,
        'reportedMissingMetrics':sum(e.get('reportedDropped',0) for e in window)}
    result['droppedNativeRecords'] = max((e.get('droppedBefore',0) for e in native),default=0)
    result['traceEnded'] = any(e['event']=='trace.stop' for e in native)
    result['dartDroppedRecords'] = max((e.get('droppedRecords', 0) for e in dart
                                       if e['event']=='trace.end'), default=0)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    parser.add_argument('--serial',required=True)
    parser.add_argument('--expected-avd',default='PiliPlusStartupIsolated_20261018')
    parser.add_argument('--index',type=int,default=5)
    parser.add_argument('--verify-input-target',action='store_true',help='Reject a tap covered by another Android input window')
    parser.add_argument('--hide-ime-before-input',action='store_true',help='Search cancellation fixture only: hide keyboard before measured input; separate from normal timing cohorts')
    parser.add_argument('--home-card',action='store_true',help='Tap an actual visible recommendation card, verified through layout events and UI semantics')
    parser.add_argument('--home-rearm-stage',choices=['immediate','visible'],help='After setup, invalidate old speculation by inverse scrolls and tap without waiting for media readiness')
    parser.add_argument('--reuse-home',type=Path,help='Previous successful capture from the same live process; keep the exact home card')
    parser.add_argument('--reuse-search',type=Path,help='Reuse the prior live search process after return; explicitly set the next progress')
    parser.add_argument('--media-age-seconds',type=float,help='Home-card experiment: target the age of its latest media warmup before tapping')
    parser.add_argument('--start-progress-ms',type=int,default=0,help='Nonzero resume regression; never mix into zero-start speed comparisons')
    parser.add_argument('--history-resume',action='store_true',help='Search entry without a progress override; observe the actual saved history position')
    parser.add_argument('--seconds',type=int,default=25)
    parser.add_argument('--resource-profile',choices=['default','lean-short','lean-monitored','minimum-startup-v2'],default='default',
        help='Explicit calibrated profile for22..25s lean release only; heavy/default limits unchanged')
    parser.add_argument('--pre-input-memory-wait-seconds',type=float,default=0,
        help='Lean-only bounded settling after app setup, before measured input; unchanged memory floors')
    parser.add_argument('--perfetto',action='store_true')
    parser.add_argument('--wait-trace',action='store_true',help='With Perfetto, include Binder/audio/memory waits; diagnostic only')
    parser.add_argument('--host-thread-trace',action='store_true',help='Diagnostic Windows emulator thread snapshots; requires --wait-trace')
    parser.add_argument('--engine-skia-trace',action='store_true',help='Cold-home profile diagnosis only: Skia engine events into system trace, never comparable to lean release timing')
    parser.add_argument('--vm-skia-trace',action='store_true',help='Profile-only six-second Skia/Embedder VM timeline; excludes systrace recorder')
    parser.add_argument('--native-cpu-trace',action='store_true',help='With VM Skia diagnosis, sample only the native raster thread for eight seconds')
    parser.add_argument('--native-process-stacks',action='store_true',help='With wait-trace and an explicitly profileable diagnostic release, sample native process stacks for eight seconds')
    parser.add_argument('--native-offcpu-trace',action='store_true',help='With native CPU sampling, also capture raster-thread descheduling stacks')
    parser.add_argument('--back-after',type=float,help='Return once during capture, after this many seconds')
    parser.add_argument('--seek-after',type=float,help='Exercise the existing horizontal seek gesture after startup (regression sample only)')
    parser.add_argument('--seek-to-fraction',type=float,help='With --seek-after, locate the accessible progress bar and tap this fraction')
    parser.add_argument('--pause-after', type=float, help='Regression only: send Android media pause after this many seconds')
    parser.add_argument('--resume-after', type=float, help='Regression only: send Android media play after the pause')
    parser.add_argument('--apk',type=Path,required=True,help='Expected already-installed APK; never installs')
    parser.add_argument('--conditions-lock',type=Path,help='Reviewed fixed hardware/app condition manifest; checked before the only measured tap')
    parser.add_argument('--expire-url-before-rearm',action='store_true',help='Same-card diagnostic: wait for original 10s URL TTL before immediate scroll/click')
    args = parser.parse_args()
    if args.wait_trace and not args.perfetto:
        parser.error('--wait-trace requires --perfetto')
    if args.host_thread_trace and not args.wait_trace:
        parser.error('--host-thread-trace requires --wait-trace')
    build_manifest=json.loads(args.apk.with_suffix('.build.json').read_text(encoding='utf-8'))
    if args.native_process_stacks and (not args.wait_trace or not build_manifest.get('nativeStackProfiling')
                                      or args.native_cpu_trace or args.native_offcpu_trace or args.host_thread_trace):
        parser.error('--native-process-stacks requires wait-trace and a diagnostic profiling manifest, without another native/host sampler')
    try:
        resource_profile=startup_resource_profile(args.resource_profile,seconds=args.seconds,
            build=build_manifest,heavy=any([args.perfetto,args.engine_skia_trace,args.vm_skia_trace,
                                          args.native_cpu_trace,args.native_offcpu_trace]))
    except ValueError as error:
        parser.error(str(error))
    if args.native_offcpu_trace and not args.native_cpu_trace:
        parser.error('--native-offcpu-trace requires --native-cpu-trace')
    if args.native_cpu_trace and not args.vm_skia_trace:
        parser.error('--native-cpu-trace requires the profile-only --vm-skia-trace mode')
    if args.resource_profile == 'minimum-startup-v2' and (
            args.start_progress_ms != 61500 or args.back_after != 18 or not args.verify_input_target
            or args.index != 5 or args.home_card or args.reuse_home or args.reuse_search
            or args.history_resume or args.seek_after is not None or args.pause_after is not None
            or args.resume_after is not None or args.hide_ime_before_input):
        parser.error('minimum-startup-v2 requires the fixed first-process 61.5s search fixture and 18s return')
    if args.resource_profile == 'minimum-startup-v2' and not args.conditions_lock:
        parser.error('A fixed condition manifest is required before minimum-startup-v2 can start')
    if args.vm_skia_trace and (args.perfetto or args.engine_skia_trace or not args.home_card or args.reuse_home is not None):
        parser.error('--vm-skia-trace requires cold home without Perfetto/systrace')
    if args.engine_skia_trace and (not args.perfetto or not args.home_card or args.reuse_home is not None):
        parser.error('--engine-skia-trace requires --perfetto and a cold --home-card entry')
    if args.expire_url_before_rearm and args.home_rearm_stage != 'immediate':
        parser.error('--expire-url-before-rearm requires --home-rearm-stage immediate')
    if args.home_rearm_stage and (not args.home_card or args.media_age_seconds is not None or args.perfetto):
        parser.error('--home-rearm-stage requires home-card without media-age or heavy Perfetto')
    if args.reuse_home is not None and not args.home_card: parser.error('--reuse-home requires --home-card')
    if args.reuse_search is not None and (args.home_card or args.reuse_home is not None):
        parser.error('--reuse-search requires search entry without --reuse-home')
    if args.media_age_seconds is not None and (not args.home_card or not 0<=args.media_age_seconds<=9):
        parser.error('--media-age-seconds requires --home-card and 0..9 seconds')
    if args.start_progress_ms < 0: parser.error('start-progress-ms must be nonnegative')
    if args.history_resume and (args.start_progress_ms or args.home_card or args.reuse_home is not None):
        parser.error('--history-resume requires search entry without an explicit nonzero progress')
    if not 22<=args.seconds<=60: parser.error('seconds must be 22..60')
    if args.back_after is not None and not 0<args.back_after<args.seconds-3:
        parser.error('back-after must be positive and leave 3 seconds to observe cleanup')
    if args.seek_after is not None and not 3<args.seek_after<args.seconds-5:
        parser.error('seek-after must leave time for startup and at least 5 seconds for recovery')
    if args.seek_to_fraction is not None and (args.seek_after is None or not 0<args.seek_to_fraction<1):
        parser.error('seek-to-fraction requires seek-after and must be between 0 and 1')
    if (args.pause_after is None) != (args.resume_after is None):
        parser.error('pause-after and resume-after must be supplied together')
    if args.pause_after is not None and not 3<args.pause_after<args.resume_after<args.seconds-3:
        parser.error('pause/resume must be ordered and leave time to observe recovery')
    if args.resume_after is not None and args.back_after is not None and args.resume_after>=args.back_after:
        parser.error('resume must precede return')
    if not 0 <= args.pre_input_memory_wait_seconds <= 90:
        parser.error('pre-input-memory-wait-seconds must be0..90')
    if args.pre_input_memory_wait_seconds and args.resource_profile not in ('lean-short','lean-monitored'):
        parser.error('pre-input memory settling requires a qualified lean-short capture')
    out=args.output.resolve()
    out.mkdir(parents=True,exist_ok=False)
    base=['adb','-s',args.serial]
    metadata={'pixelsCaptured':False,'errors':[], 'seconds':args.seconds, 'serial':args.serial,
              'perfetto':args.perfetto,'waitTrace':args.wait_trace,'memorySamples':[], 'status':'preparing',
              'resourceProfile':resource_profile}
    def save():
        (out/'capture.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2),encoding='utf-8')
    def adb(*parts,check=True,timeout=45):
        if args.resource_profile == 'lean-monitored':
            check_memory()
        result = subprocess.run(base+list(parts),capture_output=True,timeout=timeout)
        if result.returncode:
            metadata.setdefault('adbFailures', []).append({
                'command': base+list(parts), 'returncode': result.returncode,
                'stdout': result.stdout.decode('utf-8', errors='replace'),
                'stderr': result.stderr.decode('utf-8', errors='replace')})
        if check: result.check_returncode()
        return result.stdout
    def check_memory(start=False):
        if args.resource_profile == 'minimum-startup-v2':
            return None
        sample=memory_module.memory()
        metadata['memorySamples'].append(sample)
        if args.resource_profile == 'lean-monitored':
            metadata['resourceObservationOnly'] = True
            return sample
        if (sample['commitHeadroomGiB']<resource_profile['startCommitGiB' if start else 'abortCommitGiB']
                or sample['availableRamGiB']<resource_profile['startPhysicalGiB' if start else 'abortPhysicalGiB']):
            raise RuntimeError('Memory gate refused capture')
    def optional_guest_file(filename, remote):
        data=adb('shell','cat',remote,check=False)
        if data:
            (out/filename).write_bytes(data)
        else:
            (out/(filename+'.unavailable.txt')).write_text(
                'Unavailable to adb shell; see adbFailures. Missing data is not zero pressure.',
                encoding='utf-8')
    logcat=None
    trace_remote=None
    log_file=None
    pid=None
    previous=None
    vm_timeline=None
    native_cpu=None
    host_threads=None
    def host_clock_brackets(label):
        rows=[]
        for _ in range(3):
            before=time.perf_counter_ns()
            uptime=adb('shell','cat','/proc/uptime').decode().split()[0]
            after=time.perf_counter_ns()
            rows.append({'hostBeginNs':before,'hostEndNs':after,
                         'guestBootTimeNs':round(float(uptime)*1e9),
                         'guestResolutionNs':10000000})
        metadata.setdefault('hostClockBrackets',{})[label]=rows
    try:
        if args.resource_profile == 'minimum-startup-v2':
            (out/'resource-policy.txt').write_text(
                'No host sampling or resource thresholds; only fixed sparse timing observers.\n', encoding='utf-8')
        elif args.resource_profile == 'lean-monitored':
            # Process presence does not establish contention: idle/shared
            # compilers caused valid short captures to be vetoed before input.
            # This profile measures live resources throughout the capture.
            (out/'resource-gate.txt').write_text(
                'Lean monitored capture: use live resource samples; no duplicate '
                'PowerShell process-presence veto.\n', encoding='utf-8')
        else:
            gate=subprocess.run(['powershell','-NoProfile','-File',
                str(ROOT/'diagnostics/startup-20261018/rollback-baseline/memory-gate.ps1'),
                '-Kind','capture','-MinimumCommitHeadroomGiB',str(resource_profile['startCommitGiB']),
                '-MinimumPhysicalAvailableGiB',str(resource_profile['startPhysicalGiB'])],capture_output=True)
            (out/'resource-gate.txt').write_bytes(gate.stdout+gate.stderr)
            if gate.returncode: raise RuntimeError('Resource gate refused capture; see resource-gate.txt')
        check_memory(start=True)
        avd=adb('emu','avd','name').decode().splitlines()[0]
        if avd!=args.expected_avd or not avd.startswith('PiliPlusStartup'):
            raise RuntimeError('Refusing to change an unrelated emulator: '+avd)
        metadata['avd']=avd
        # Runtime version/renderer changes define a new comparison cohort.
        # Collect outside the measured input interval; never inspect pixels.
        try:
            import psutil
            hosts = []
            for process in psutil.process_iter(['pid','name','cmdline']):
                if not (process.info['name'] or '').startswith('qemu-system-'):
                    continue
                command = process.info['cmdline'] or []
                if avd not in command:
                    continue
                properties = Path(command[0]).parents[2]/'source.properties'
                hosts.append({'pid':process.pid,'command':command,
                              'sourceProperties':properties.read_text(encoding='utf-8') if properties.exists() else None})
            metadata['emulatorHostProcesses'] = hosts
        except (ImportError, OSError) as error:
            metadata['emulatorHostMetadataError'] = type(error).__name__
        remote_apk=adb('shell','pm','path',PACKAGE).decode().strip().removeprefix('package:')
        actual=adb('shell','sha256sum',remote_apk).decode().split()[0]
        expected=hashlib.sha256(args.apk.read_bytes()).hexdigest()
        metadata['apkSha256']=actual
        if actual!=expected: raise RuntimeError('Installed APK differs from requested build')
        metadata['build']=json.loads(args.apk.with_suffix('.build.json').read_text(encoding='utf-8'))
        engine_extras=[]
        if args.vm_skia_trace:
            if metadata['build'].get('buildMode')!='profile':
                raise RuntimeError('VM Skia diagnosis requires a separate profile build')
            engine_extras=['--ez','trace-skia','true']
            metadata['vmSkiaTraceRequested']=True
            metadata['releaseSpeedComparable']=False
        if args.engine_skia_trace:
            if metadata['build'].get('buildMode')!='profile':
                raise RuntimeError('Skia diagnosis requires the explicitly separate profile build')
            engine_extras=['--ez','trace-skia','true','--ez','trace-systrace','true']
            metadata['engineSkiaTraceRequested']=True
            metadata['releaseSpeedComparable']=False
        reuse_from = args.reuse_home or args.reuse_search
        if reuse_from is not None:
            previous=json.loads((reuse_from/'capture.json').read_text(encoding='utf-8'))
            if previous['status']!='captured' or previous['errors'] or previous['apkSha256']!=actual:
                raise RuntimeError('Previous capture is not a successful run of the same APK')
            if not previous.get('backSentAfterSeconds'):
                raise RuntimeError('Previous capture did not return to the home page')
            metadata['reusedHomeFrom' if args.reuse_home else 'reusedSearchFrom']=str(reuse_from.resolve())
            if args.reuse_search is not None:
                if previous.get('requestedStartProgressMs') is None and not previous.get('historyResumeRequested'):
                    raise RuntimeError('Previous capture did not use search entry')
                if adb('shell','pidof',PACKAGE).decode().strip()!=previous['pid']:
                    raise RuntimeError('Search process changed before reuse')
        if previous is None:
            # Retry only this idempotent pre-launch operation on an ADB server
            # handshake failure. Never retry a measured tap or restart the
            # shared server. Each failed attempt remains in adbFailures.
            stop_recovery = force_stop_before_capture(adb, PACKAGE)
            if stop_recovery is not None:
                metadata['forceStopRecovery'] = stop_recovery
                save()
        log_file=(out/'logcat.txt').open('wb')
        log_tags = ['flutter:I','PiliPlaybackTrace:I','AndroidRuntime:E','*:S'] if args.resource_profile == 'minimum-startup-v2' else [
            'flutter:I','PiliPlaybackTrace:V','MediaCodec:I','CCodec:I','AudioTrack:I',
            'AndroidRuntime:E','StartupListener:I','PiliOrientationTiming:I',
            'PiliCodecReserve:I','PiliCodecFlush:I','PiliAudioLead:I','PiliDecodeOnly:I','PiliCodecCallbacks:I','PiliCodecSignal:I','PiliPrerollQueue:I','*:S']
        logcat=subprocess.Popen(base+['logcat','-v','epoch','-T','1']+log_tags,stdout=log_file,stderr=subprocess.STDOUT)
        if args.home_card:
            if previous is None:
                adb('shell','am','start','-W','-a','android.intent.action.MAIN',
                    '-c','android.intent.category.LAUNCHER','-n',PACKAGE+'/com.personal.piliplus.MainActivity',*engine_extras)
                time.sleep(2)
            pid,video,tap=prepare_home_card(adb,out,PACKAGE,metadata['build'].get('visibleUrlPrefetch',False),
                                          reuse=previous,media_age=args.media_age_seconds)
            entry='actual visible recommendation card; native layout plus UI semantics'
        else:
            if previous is None:
                adb('shell','am','start','-W','-a','android.intent.action.VIEW',
                    '-n',PACKAGE+'/com.personal.piliplus.MainActivity','-d','bilibili://search')
                time.sleep(2)
            else:
                # Flutter's text editor did not reliably handle adb Ctrl+A.
                # Use its actual semantically identified clear action, then
                # require the entire replacement URI to match below.
                remote_clear='/sdcard/piliplus-listener-clear.xml'
                dump_pre_input_ui(adb,remote_clear,out)
                clear_xml=adb('shell','cat',remote_clear)
                (out/'search-before-clear.xml').write_bytes(clear_xml)
                clear_xy=search_clear_target(clear_xml)
                metadata['searchClearTarget']=clear_xy
                adb('shell','input','touchscreen','tap',*map(str,clear_xy))
                adb('shell','input','touchscreen','tap','480','135')
            video=json.loads((ROOT/'diagnostics/startup-20261016/videos.json').read_text(encoding='utf-8'))[args.index]
            uri=search_video_uri(video,args.start_progress_ms,args.history_resume)
            fill_verified_search_uri(adb,out,uri)
            if args.hide_ime_before_input:
                hide_search_ime_before_input(adb,out,uri)
                metadata['imeHiddenBeforeMeasuredInput']=True
            pid=adb('shell','pidof',PACKAGE).decode().strip()
            if previous is not None and (pid!=previous['pid'] or video['cid']!=previous['video']['cid']):
                raise RuntimeError('Search reuse changed process or video identity')
            tap=[990,135]
            entry='in-app search submit of verified video URI'
        metadata['video']=video
        metadata['requestedStartProgressMs']=None if args.home_card or args.history_resume else args.start_progress_ms
        metadata['historyResumeRequested']=args.history_resume
        metadata.update(pid=pid,appForceStoppedBeforeSearch=previous is None,
                        mediaPreloadEnabled=metadata['build'].get('mediaPreload',False),
                        mediaPreloaded=False,
                        entry=entry,tap=tap)
        if previous is not None:
            native_name=next(n for n in previous['traceFiles'] if n.startswith('native-'))
            before=adb('shell','cat',f'/sdcard/Android/data/{PACKAGE}/files/playback-diagnostics/{native_name}')
            (out/'native-before-input.jsonl').write_bytes(before)
            metadata['afterNativeSequence']=max(json.loads(line)['seq'] for line in before.splitlines(keepends=True) if line.endswith(b'\n'))
        for filename,remote in [('guest-before.txt','/proc/meminfo'),('vmstat-before.txt','/proc/vmstat')]:
            (out/filename).write_bytes(adb('shell','cat',remote))
        if args.native_process_stacks:
            check_memory(start=True)
            from startup_native_cpu import StartupNativeCpu
            native_cpu=StartupNativeCpu(adb,base,out,pid,PACKAGE,scope='process')
            metadata['nativeCpuTrace']=True
            metadata['nativeProcessStacks']=True
        if args.perfetto:
            metadata['perfettoDurationSeconds'] = 8
            session='pili_listener_'+uuid.uuid4().hex
            config=out/'capture.pbtxt'
            wait_events = '''
  ftrace_events: "sched/sched_blocked_reason"
  ftrace_events: "sched/sched_wakeup_new"
  ftrace_events: "task/task_newtask"
  ftrace_events: "task/task_rename"
  ftrace_events: "vmscan/mm_vmscan_direct_reclaim_begin"
  ftrace_events: "vmscan/mm_vmscan_direct_reclaim_end"
  ftrace_events: "vmscan/mm_vmscan_kswapd_wake"
  ftrace_events: "vmscan/mm_vmscan_kswapd_sleep"
  atrace_categories: "audio"
  atrace_categories: "binder_driver"
  atrace_categories: "aidl"
  atrace_categories: "dalvik"
''' if args.wait_trace else ''
            config.write_text(f'''buffers {{ size_kb: 32768 fill_policy: RING_BUFFER }}
duration_ms: 8000
data_sources {{ config {{ name: "android.surfaceflinger.frametimeline" }} }}
data_sources {{ config {{ name: "linux.ftrace" ftrace_config {{
  ftrace_events: "sched/sched_switch"
  ftrace_events: "sched/sched_waking"
{wait_events}
  atrace_categories: "gfx"
  atrace_categories: "video"
  atrace_categories: "view"
  atrace_apps: "{PACKAGE}"
  compact_sched {{ enabled: true }}
}} }} }}
data_sources {{ config {{ name: "linux.process_stats" process_stats_config {{ scan_all_processes_on_start: true }} }} }}
''',encoding='utf-8')
            config_remote='/data/misc/perfetto-configs/'+session+'.pbtxt'
            trace_remote='/data/misc/perfetto-traces/'+session+'.pftrace'
            adb('push',str(config),config_remote)
            response=adb('shell','perfetto','--background-wait','--txt','-c',config_remote,'-o',trace_remote)
            (out/'perfetto-start.txt').write_bytes(response)
        if args.pre_input_memory_wait_seconds and args.resource_profile != 'lean-monitored':
            settled=wait_startup_memory(memory_module.memory,resource_profile,
                args.pre_input_memory_wait_seconds,observe=metadata['memorySamples'].append)
            metadata['preInputMemorySettling']=settled
            save()
            if not settled['ready']:
                raise RuntimeError('Memory did not settle before measured input')
        check_memory(start=True)
        if args.resource_profile == 'lean-monitored':
            (out/'monitored-vmstat-before.txt').write_bytes(adb('shell','cat','/proc/vmstat'))
            optional_guest_file('memory-pressure-before.txt','/proc/pressure/memory')
        if args.home_rearm_stage:
            from startup_home_card import rearm_verified_home_card
            tap=rearm_verified_home_card(adb,out,PACKAGE,pid,video,tap,args.home_rearm_stage,
                                        reuse=previous,expire_url=args.expire_url_before_rearm)
            metadata['tap']=tap
            metadata['homeRearmStage']=args.home_rearm_stage
        if args.verify_input_target:
            dispatcher=adb('shell','dumpsys','input')
            (out/'input-dispatcher-before.txt').write_bytes(dispatcher)
            target=input_target(dispatcher.decode('utf-8',errors='replace'),*tap)
            metadata['inputTarget']=target
            if target['window'].split(' ',1)[-1] != PACKAGE+'/com.personal.piliplus.MainActivity':
                raise RuntimeError('Measured input is covered by '+target['window'])
        if args.resource_profile == 'minimum-startup-v2':
            from startup_conditions import verify_pre_input
            metadata['preInputConditions']=verify_pre_input(
                adb,pid,args.conditions_lock,metadata['apkSha256'],out/'conditions-before-input.json')
            save()
        adb('shell','log','-t','StartupListener','measured-input')
        if args.vm_skia_trace:
            from startup_vm_timeline import StartupVmTimeline
            vm_timeline=StartupVmTimeline(adb,out,pid,
                (out/'logcat.txt').read_text(encoding='utf-8',errors='replace'))
        if args.native_cpu_trace:
            from startup_native_cpu import StartupNativeCpu
            native_cpu=StartupNativeCpu(adb,base,out,pid,PACKAGE,off_cpu=args.native_offcpu_trace)
            metadata['nativeCpuTrace']=True
        if args.host_thread_trace:
            from windows_thread_trace import WindowsThreadTrace
            hosts=metadata.get('emulatorHostProcesses',[])
            if len(hosts)!=1:
                raise RuntimeError('Host sampler requires one identified QA emulator')
            owner=psutil.Process(hosts[0]['pid'])
            if owner.cmdline()!=hosts[0]['command'] or args.expected_avd not in owner.cmdline():
                raise RuntimeError('QA emulator identity changed before host sampler')
            host_clock_brackets('before')
            host_threads=WindowsThreadTrace(owner.pid,out/'host-threads.json.gz')
            host_threads.start()
            metadata['hostThreadTrace']=True
        # Specify the input source and retain both streams. A shell exit code
        # alone is not proof that Android delivered the event to the activity.
        tap_command=base+['shell','input','touchscreen','tap',*map(str,tap)]
        tap_host_begin=time.perf_counter_ns()
        tap_result=subprocess.run(tap_command,capture_output=True,timeout=45)
        tap_host_end=time.perf_counter_ns()
        metadata['measuredInputCommand']={
            'command':tap_command,'returncode':tap_result.returncode,
            'hostBeginNs':tap_host_begin,'hostEndNs':tap_host_end,
            'stdout':tap_result.stdout.decode('utf-8',errors='replace'),
            'stderr':tap_result.stderr.decode('utf-8',errors='replace')}
        tap_result.check_returncode()
        metadata['status']='capturing'
        if args.resource_profile != 'minimum-startup-v2':
            save()
        print(json.dumps({'event':'capturing','output':str(out),'cid':video['cid']}),flush=True)
        capture_start=time.monotonic()
        until=capture_start+args.seconds
        returned=False
        sought=False
        media_actions=[] if args.pause_after is None else [
            (args.pause_after,'KEYCODE_MEDIA_PAUSE','pauseSentAfterSeconds'),
            (args.resume_after,'KEYCODE_MEDIA_PLAY','resumeSentAfterSeconds')]
        while time.monotonic()<until:
            next_wake = until if args.resource_profile == 'minimum-startup-v2' else min(until, time.monotonic()+2)
            if args.back_after is not None and not returned:
                next_wake = min(next_wake, capture_start+args.back_after)
            if args.seek_after is not None and not sought:
                next_wake = min(next_wake, capture_start+args.seek_after)
            if media_actions:
                next_wake = min(next_wake, capture_start+media_actions[0][0])
            if vm_timeline is not None and not vm_timeline.stopped:
                next_wake = min(next_wake, capture_start+6)
            time.sleep(max(0,next_wake-time.monotonic()))
            check_memory()
            if vm_timeline is not None and not vm_timeline.stopped and time.monotonic()-capture_start>=6:
                vm_timeline.stop()
            if media_actions and time.monotonic()-capture_start>=media_actions[0][0]:
                _, key, field = media_actions.pop(0)
                metadata[field]=time.monotonic()-capture_start
                adb('shell','input','keyevent',key)
            if args.back_after is not None and not returned and time.monotonic()-capture_start>=args.back_after:
                metadata['backSentAfterSeconds']=time.monotonic()-capture_start
                adb('shell','input','keyevent','4')
                returned=True
            if args.seek_after is not None and not sought and time.monotonic()-capture_start>=args.seek_after:
                metadata['seekGestureAfterSeconds']=time.monotonic()-capture_start
                if args.seek_to_fraction is None:
                    metadata['seekInputAfterSeconds']=time.monotonic()-capture_start
                    adb('shell','input','swipe','300','350','650','350','400')
                else:
                    adb('shell','input','tap','900','350')
                    xml=adb('exec-out','uiautomator','dump','/dev/tty',timeout=12)
                    (out/'seek-controls.xml').write_bytes(xml)
                    xml_text=xml.decode('utf-8',errors='strict')
                    hierarchy=ET.fromstring(xml_text[xml_text.index('<?xml'):xml_text.rindex('</hierarchy>')+12])
                    sliders=[]
                    for node in hierarchy.iter('node'):
                        if node.get('class')!='android.widget.SeekBar': continue
                        bounds=list(map(int,re.findall(r'\d+',node.get('bounds',''))))
                        if len(bounds)==4 and bounds[3]<700 and bounds[2]-bounds[0]>500 and bounds[3]-bounds[1]>=20:
                            sliders.append(bounds)
                    if len(sliders)!=1: raise RuntimeError('No unique accessible video progress bar')
                    x1,y1,x2,y2=sliders[0]
                    x=round(x1+(x2-x1)*args.seek_to_fraction)
                    metadata['seekFraction']=args.seek_to_fraction
                    metadata['seekBounds']=sliders[0]
                    metadata['seekInputAfterSeconds']=time.monotonic()-capture_start
                    adb('shell','input','tap',str(x),str((y1+y2)//2))
                sought=True
        if args.resource_profile == 'minimum-startup-v2':
            from startup_conditions import device_conditions
            after=device_conditions(adb)
            (out/'conditions-after-window.json').write_text(json.dumps(after,indent=2),encoding='utf8')
            if after!=metadata['preInputConditions']['observed']['device']:
                raise RuntimeError('Conditions changed during capture; sample is invalid')
        metadata['status']='captured'
    except Exception as error:
        metadata['status']='failed'
        metadata['errors'].append(type(error).__name__+': '+str(error))
    finally:
        if host_threads is not None:
            try:
                metadata['hostThreadReport']=host_threads.stop()
                if metadata['hostThreadReport']['errors']:
                    metadata['errors'].append('Host thread snapshots contain collection errors')
                host_clock_brackets('after')
            except Exception as error:
                metadata['errors'].append('Host thread trace: '+str(error))
        if native_cpu is not None:
            native_cpu.close()
            if not native_cpu.report.get('pulled'):
                metadata['errors'].append('Native CPU collection failed; inspect native-cpu-collection.json')
        if vm_timeline is not None:
            try:
                vm_timeline.stop()
                vm_timeline.close()
            except Exception as error:
                metadata['errors'].append('VM timeline: '+str(error))
                vm_timeline.close()
        if pid:
            try:
                remote=f'/sdcard/Android/data/{PACKAGE}/files/playback-diagnostics'
                traces=out/'app'
                traces.mkdir(exist_ok=True)
                selected = validate_trace_pair(previous['traceFiles'],pid) if previous is not None else announced_trace_pair(
                    (out/'logcat.txt').read_text(encoding='utf-8', errors='replace'), None, pid)
                metadata['traceFiles'] = selected
                metadata['traceSelection'] = ('Previously announced exact pair; same live PID verified before reuse; successful pulls verify existence'
                    if previous is not None else 'Exact current-process announcements; existence verified by successful pulls, without directory enumeration')
                collect_trace_snapshot(adb, remote, traces, selected)
                metadata['summary']=summarize(traces,metadata['video']['cid'], selected,metadata.get('afterNativeSequence'))
                metadata['mediaPreloaded']=any(event['event']=='startup.mediaPrefetch.claim'
                    for event in metadata['summary'].get('milestones',[]))
                (out/'summary.json').write_text(json.dumps(metadata['summary'],indent=2),encoding='utf-8')
                if metadata['summary'].get('parseErrors'):
                    metadata['errors'].append('Incomplete or malformed trace records; preserve raw files and recollect before accepting the run')
                (out/'media-session.txt').write_bytes(adb('shell','dumpsys','media_session'))
                (out/'audio-flinger.txt').write_bytes(adb('shell','dumpsys','media.audio_flinger'))
                if metadata['build'].get('warmOrientationService'):
                    (out/'sensor-service-after.txt').write_bytes(adb('shell','dumpsys','sensorservice'))
                (out/'vmstat-after.txt').write_bytes(adb('shell','cat','/proc/vmstat'))
                if args.resource_profile == 'lean-monitored':
                    optional_guest_file('memory-pressure-after.txt','/proc/pressure/memory')
                if trace_remote: adb('pull',trace_remote,str(out/'system.pftrace'),timeout=60)
            except Exception as error:
                metadata['errors'].append('salvage: '+str(error))
        if logcat:
            logcat.terminate()
            logcat.wait(timeout=5)
        if log_file: log_file.close()
        save()
    print(json.dumps({'status':metadata['status'],'errors':metadata['errors'],
                      'summary':metadata.get('summary')}),flush=True)
    return int(metadata['status']!='captured' or bool(metadata['errors']) or
               not metadata.get('summary',{}).get('validInput') or
               ((metadata.get('build',{}).get('frameTrace') or args.resource_profile == 'minimum-startup-v2') and
                not metadata.get('summary',{}).get('validTextureObservation')))


if __name__=='__main__':
    sys.exit(main())
