"""Keep Android running; force-stop app for each fixed-position first resume."""
from pathlib import Path
import hashlib,json,shutil,subprocess,sys,time,traceback
import psutil
from native_sidx_host import wait_capture_memory,install_if_different
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
ADB=['D:/Android_studio_sdk/platform-tools/adb.exe','-s','emulator-5554']
sys.path.insert(0,str(ROOT/'tool'))
from capture_startup_listener import force_stop_before_capture
batch=1
out=HERE/'async-input-observed-01';out.mkdir(exist_ok=False)
variant='candidate' if batch in (1,4) else 'control'
plan=[('00-seed','control'),('01-candidate','candidate'),('02-control','control'),('03-control','control'),('04-candidate','candidate')]
apks={v:HERE/'async-input-candidate.apk' for v in ['control','candidate']}
metas={v:json.loads(p.with_suffix('.build.json').read_text())for v,p in apks.items()}
assert metas['control']==metas['candidate']
assert 'STARTUP_AUDIO_DECODE_QUEUE_BOUNDED=true' in metas['candidate']['defines']
assert json.loads((HERE/'native-async-input-integration-01/embedded-device-reviewed.json').read_text())['passed']
(out/'plan.json').write_text((HERE/'native-async-input-integration-01/plan.json').read_text())
# Prelaunch is observation only; actual input and running capture retain lean-monitored checks.
from native_sidx_host import memory_module
(out/'prelaunch-observation.json').write_text(json.dumps(memory_module.memory(),indent=2),encoding='utf-8')
def owned_emulators():
    found=[]
    for p in psutil.process_iter(['name']):
        try:
            if (p.info['name'] or '').startswith('qemu-system-') and p.num_threads()>0 and 'PiliPlusStartupIsolated_20261018' in p.cmdline():found.append(p)
        except (psutil.NoSuchProcess,psutil.AccessDenied):pass
    return found
owned=owned_emulators()
assert len(owned)<=1,'Multiple matching owned emulator processes; inspect instead of launching another'
assert len(owned)==1,'Use restored QA from native87; inspect missing process instead of restarting it'
process=owned[0];created=process.create_time();command=process.cmdline()
(out/'emulator-process.json').write_text(json.dumps({'pid':process.pid,'createTime':created,'command':command},indent=2),encoding='utf-8')
# Read-only process-state listener: record host suspension immediately.
import threading
hostStop=threading.Event();hostStates=[]
def watchHost():
    last=None
    while not hostStop.is_set():
        try:state=process.status() if process.create_time()==created else 'identity-changed'
        except psutil.NoSuchProcess:state='exited'
        if state!=last:
            hostStates.append({'hostTime':time.time(),'hostPerfNs':time.perf_counter_ns(),'status':state})
            (out/'host-process-states.json').write_text(json.dumps(hostStates,indent=2))
            if state!='running':print('Owned Android process state: '+state,flush=True)
            last=state
        if state=='exited':return
        hostStop.wait(1)
hostThread=threading.Thread(target=watchHost,daemon=True);hostThread.start()
rows=[];pids=set()
property_name='debug.piliplus.async_input'
callback_property='debug.piliplus.codec_callbacks'
original_callback=None
original_property=None
original_wait=None
try:
    assert subprocess.check_output(ADB+['get-state'],timeout=10).strip()==b'device'
    assert subprocess.check_output(ADB+['shell','getprop','debug.piliplus.decode_only'],timeout=10).decode().strip() in ['', '0']
    original_wait=subprocess.check_output(ADB+['shell','getprop','debug.piliplus.callback_wait'],timeout=10).decode().strip()
    subprocess.run(ADB+['shell','setprop','debug.piliplus.callback_wait','0'],capture_output=True,check=True,timeout=10)
    original_property=subprocess.check_output(ADB+['shell','getprop',property_name],timeout=10).decode().strip()
    original_callback=subprocess.check_output(ADB+['shell','getprop',callback_property],timeout=10).decode().strip()
    (out/'callback-switch-original.json').write_text(json.dumps({'original':original_callback}))
    subprocess.run(ADB+['shell','setprop',callback_property,'1'],capture_output=True,check=True,timeout=10)
    assert subprocess.check_output(ADB+['shell','getprop',callback_property],timeout=10).strip()==b'1'

    (out/'switch-original.json').write_text(json.dumps({'property':property_name,'original':original_property}),encoding='utf-8')
    guest_mem=subprocess.check_output(ADB+['shell','cat','/proc/meminfo'],timeout=12).decode()
    (out/'guest-meminfo-before.txt').write_text(guest_mem,encoding='utf-8')
    guest_total=int(next(line.split()[1] for line in guest_mem.splitlines() if line.startswith('MemTotal:')))
    assert 2400000<guest_total<2700000,guest_total
    snapshot=out/'host-tools';snapshot.mkdir()
    for source in [Path(__file__),HERE/'native_sidx_host.py',ROOT/'tool/capture_startup_listener.py',ROOT/'tool/startup_resource_profile.py']:
        shutil.copy2(source,snapshot/source.name)
    for label,variant in plan:
        print(f'Shared Android / new app process: {label}',flush=True)
        value='1' if variant=='candidate' else '0'
        subprocess.run(ADB+['shell','setprop',property_name,value],check=True,capture_output=True,timeout=10)
        actual=subprocess.check_output(ADB+['shell','getprop',property_name],timeout=10).decode().strip()
        assert actual==value,(label,actual,value)
        (out/f'{label}-switch.json').write_text(json.dumps({'requested':value,'verified':actual}),encoding='utf-8')
        attempts=[]
        def prepare_adb(*args):
            result=subprocess.run(ADB+list(args),capture_output=True,timeout=15)
            attempts.append({'command':list(args),'returncode':result.returncode,'stderr':result.stderr.decode(errors='replace')})
            result.check_returncode()
        try:force_stop_before_capture(prepare_adb,'com.personal.piliplus')
        finally:(out/f'{label}-force-stop.json').write_text(json.dumps(attempts,indent=2),encoding='utf-8')
        apk=apks[variant]
        install_if_different(ADB,apk,hashlib.sha256(apk.read_bytes()).hexdigest(),out/f'{label}-installed.json')
        (out/f'{label}-resource-observation.json').write_text(json.dumps(memory_module.memory(),indent=2),encoding='utf-8')
        with (out/f'{label}-capture.txt').open('xb') as log:
            subprocess.run([sys.executable,str(ROOT/'tool/capture_startup_listener.py'),str(out/label),
                '--serial','emulator-5554','--apk',str(apk),'--start-progress-ms',str(0 if label=='00-seed' else 61500),
                '--seconds','25','--back-after','18','--verify-input-target','--resource-profile','lean-monitored','--pre-input-memory-wait-seconds','0'],
                cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
        m=json.loads((out/label/'capture.json').read_text(encoding='utf-8'))
        assert not m['errors'] and m['pid'] not in pids and not m.get('reusedSearchFrom')
        pids.add(m['pid'])
        with (out/f'{label}-review.txt').open('xb') as log:
            for script in ['review_startup_return_cleanup.py','summarize_startup_continuity.py']:
                reviewed=subprocess.run([sys.executable,str(ROOT/'tool'/script),str(out/label)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=False,timeout=30)
                if script=='summarize_startup_continuity.py':reviewed.check_returncode()
        cleanup_file=out/label/'return-cleanup-reviewed.json'
        cleanup=json.loads(cleanup_file.read_text(encoding='utf-8')) if cleanup_file.exists() else {'passed':False,'reason':'Original reviewer failed; preserve evidence and continue independent sample'}
        if not cleanup['passed']:(out/label/'return-failure-retained.json').write_text(json.dumps(cleanup))
        s=m['summary'];milestones={r['event']:r['afterInputMs'] for r in s['milestones']}
        assert s['validSource'] and s['validInput']
        exactFirstPts=s['firstChangedTextureTimestampNs']==(0 if label=='00-seed' else 61500000000)
        events=[json.loads(line) for name in s['traceFiles'] if name.startswith('flutter')
                for line in (out/label/'app'/name).read_text(encoding='utf-8').splitlines()]
        allEvents=events
        opened=next(e for e in events if e['event']=='source.open.begin' and e.get('playerId')==s['sourceIdentity']['playerId'])
        events=[e for e in events if e['seq']>=opened['seq']]
        strictStable=any(e['event']=='output.stable' for e in events) and not any(e['event']=='output.stable.failed' for e in events)
        continuity=json.loads((out/label/'continuity-analysis/summary.json').read_text(encoding='utf-8'))
        row={'label':label,'variant':variant,'warmup':label=='00-seed','pid':m['pid'],
             'textureMs':s['firstChangedTextureConsumedAfterInputMs'],'coverMs':milestones['ui.frameReady.after'],
             'openMs':milestones['source.open.begin'],'functionalCleanup':cleanup['passed'],'strictStable':strictStable,
             'firstTexturePtsNs':s['firstChangedTextureTimestampNs'],'exactFirstPts':exactFirstPts,
             'functionalPassed':cleanup['passed'] and strictStable and exactFirstPts,
             'maxPositiveGapMs':continuity['maxCompletedPositiveTimestampGapMs']}
        relevant=[e for e in allEvents if e.get('requestId')==s['sourceIdentity']['requestId'] and e.get('cid')==s['sourceIdentity']['cid']]
        lookup=[{k:e.get(k) for k in ['video','audio','videoOrigin','audioOrigin']} for e in relevant if e['event']=='isolated.indexHint.lookup']
        persisted=[{k:e.get(k) for k in ['kind','cached','bytes']} for e in relevant if e['event']=='isolated.indexHint.persisted']
        hinted={kind:any(e['event']==f'isolated.{kind}.resume.indexHint' for e in relevant) for kind in ['video','audio']}
        if label=='00-seed':
            cacheVerified={e['kind'] for e in persisted if e['cached'] and 0<e['bytes']<=65536}=={'video','audio'}
        else:
            cacheVerified=len(lookup)==1 and lookup[0]['videoOrigin']=='disk' and lookup[0]['audioOrigin']=='disk' and all(hinted.values())
        row.update(indexLookups=lookup,persistedIndexes=persisted,hintedPlans=hinted,cacheMechanismVerified=cacheVerified)
        # A mechanism miss is retained and must not be reported as a speed win.
        row['functionalPassed']=row['functionalPassed'] and cacheVerified
        native=[]
        for line in (out/label/'logcat.txt').read_text(encoding='utf-8',errors='replace').splitlines():
            marker='[CODEC_RESERVATION] '
            if marker in line and line.split()[1]==str(m['pid']):
                event=json.loads(line.split(marker,1)[1])
                event['afterInputMs']=(event['monoNs']-s['inputDispatchMonoNs'])/1e6
                native.append(event)
        reservation=[e for e in relevant if e['event'].startswith('startup.codecReservation.')]
        row['reservationDartEvents']=reservation
        row['reservationNativeEvents']=native
        byName={e['event']:e for e in native}
        expected=label!='00-seed'
        verified=(len([e for e in native if e['event']=='taken'])==1 and
                  all(n in byName for n in ['create.begin','ready','taken']) and
                  byName['create.begin']['monoNs']<byName['ready']['monoNs']<=byName['taken']['monoNs'] and
                  byName['ready']['codec']==byName['taken']['codec'] and
                  not any(e['event'] in ['create.failed','release.begin','take.fallbackAfterRelease'] for e in native) and
                  any(e['event']=='startup.codecReservation.finished' and e.get('result')==1 for e in reservation)
                  ) if expected else not native and not reservation
        row['reservationMechanismVerified']=verified
        if expected and verified:
            row['reservationCreateMs']=(byName['ready']['monoNs']-byName['create.begin']['monoNs'])/1e6
            row['reservationReadyBeforeTakeMs']=(byName['taken']['monoNs']-byName['ready']['monoNs'])/1e6
            row['sharedPendingCreation']=bool(byName['taken']['value'])
        row['functionalPassed']=row['functionalPassed'] and verified
        closed={kind:[e for e in relevant if e['event']==f'isolated.{kind}.delivery.upstreamClosed'] for kind in ['video','audio']}
        row['initialUpstreamClosure']=closed
        if label!='00-seed':
            retired=(all(len(closed[kind])==1 and closed[kind][0]['rangeComplete'] is False and
                     not any(e['event']==f'isolated.{kind}.body.progress' and e['seq']>closed[kind][0]['seq'] for e in relevant)
                     for kind in ['video','audio']))
            row['closedDeliveryMechanismVerified']=retired
            row['functionalPassed']=row['functionalPassed'] and retired
        flush=[]
        for line in (out/label/'logcat.txt').read_text(encoding='utf-8',errors='replace').splitlines():
            marker='[CODEC_FLUSH] '
            if marker in line and line.split()[1]==str(m['pid']):
                event=json.loads(line.split(marker,1)[1])
                event['afterInputMs']=(event['monoNs']-s['inputDispatchMonoNs'])/1e6
                flush.append(event)
        row['flushNativeEvents']=flush
        if label!='00-seed':
            receives=[e for e in flush if e['event']=='receive.first' and 0<=e['afterInputMs']<row['textureMs']]
            pristine=[e for e in flush if e['event']=='flush.begin' and not e['receiveStarted']]
            used=[e for e in flush if e['event']=='flush.begin' and e['receiveStarted']]
            enabled=1
            verified=(len(receives)==1 and len(pristine)==2 and len(used)>=1 and
                      all(e['enabled']==enabled and e['skipped']==enabled and e['instance']==receives[0]['instance'] and e['monoNs']<receives[0]['monoNs'] for e in pristine) and
                      all(e['skipped']==0 and e['instance']==receives[0]['instance'] and e['monoNs']>receives[0]['monoNs'] for e in used) and
                      all(any(end['event']=='flush.end' and end['instance']==e['instance'] and end['ordinal']==e['ordinal'] and end['monoNs']>=e['monoNs'] for end in flush) for e in pristine+used))
            row['unusedFlushMechanismVerified']=verified
            row['functionalPassed']=row['functionalPassed'] and verified
            row['firstReceiveMs']=receives[0]['afterInputMs'] if len(receives)==1 else None
            row['pristineFlushTotalMs']=sum((next(end['monoNs'] for end in flush if end['event']=='flush.end' and end['instance']==e['instance'] and end['ordinal']==e['ordinal'])-e['monoNs'])/1e6 for e in pristine) if verified else None
            row['usedFlushCount']=len(used)
        lead=[]
        for line in (out/label/'logcat.txt').read_text(encoding='utf-8',errors='replace').splitlines():
            marker='[AUDIO_LEAD] '
            if marker in line and line.split()[1]==str(m['pid']):
                event=json.loads(line.split(marker,1)[1])
                event['afterInputMs']=(event['monoNs']-s['inputDispatchMonoNs'])/1e6
                lead.append(event)
        gates=[]
        for line in (out/label/'logcat.txt').read_text(encoding='utf-8',errors='replace').splitlines():
            if '[AUDIO_LEAD_GATE] ' in line and line.split()[1]==str(m['pid']):
                e=json.loads(line.split('[AUDIO_LEAD_GATE] ',1)[1]);e['afterInputMs']=(e['monoNs']-s['inputDispatchMonoNs'])/1e6;gates.append(e)
        row['audioLeadGates']=gates
        row['filteredAudioLeadEvents']=lead
        if label!='00-seed':
            prime=[e for e in lead if e['event']=='prime.first']
            drain=[e for e in lead if e['event']=='drain.begin']
            empty=[e for e in lead if e['event']=='drain.empty']
            clear=[e for e in lead if e['event']=='clear']
            leadVerified=(len(prime)==1 and len(drain)==1 and len(empty)==1 and len(clear)>=1 and
                          prime[0]['monoNs']<drain[0]['monoNs']<=empty[0]['monoNs'] and
                          prime[0]['afterInputMs']<row['textureMs'] and
                          all(e['instance']==prime[0]['instance'] for e in lead) and
                          0<drain[0]['count']<=96 and drain[0]['bytes']<=1048576 and drain[0]['seconds']<=2.000001 and
                          all(e['count']==0 and e['pushed']==e['popped'] for e in empty+clear)
                          )
            row['fairPrimingMechanismVerified']=(len(drain)==1 and drain[0].get('yieldedCycles',0)>0 and drain[0].get('maxCycleFrames')==4)
            row['nativeSelectedPtsVerified']=len(drain)==1 and drain[0].get('videoPtsKnown')==1 and drain[0].get('audioStartKnown')==1 and abs(drain[0]['videoPts']-61.5)<0.0001 and abs(drain[0]['audioStartPts']-61.5)<0.0001
            row['filteredAudioLeadMechanismVerified']=leadVerified
            row['functionalPassed']=row['functionalPassed'] and leadVerified
        decode_only=[]
        for line in (out/label/'logcat.txt').read_text(encoding='utf-8',errors='replace').splitlines():
            marker='[DECODE_ONLY] '
            if marker in line and line.split()[1]==str(m['pid']):
                e=json.loads(line.split(marker,1)[1]);e['afterInputMs']=(e['monoNs']-s['inputDispatchMonoNs'])/1e6;decode_only.append(e)
        row['decodeOnlyEvents']=decode_only
        first=[e for e in decode_only if e['event']=='queue.first']
        close=[e for e in decode_only if e['event']=='close']
        if label!='00-seed':
            row['decodeOnlyMechanismVerified']=(len(first)==1 and len(close)==1 and
                first[0]['instance']==close[0]['instance'] and first[0]['sdk']>=34 and
                all(e['enabled']==0 for e in decode_only) and
                0<=first[0]['afterInputMs']<row['textureMs'] and
                first[0]['flags']==0 and
                close[0]['eligible']>0 and close[0]['applied']==0)
        callbacks=[]
        for line in (out/label/'logcat.txt').read_text(encoding='utf-8',errors='replace').splitlines():
            marker='[CODEC_CALLBACK] '
            if marker in line and line.split()[1]==str(m['pid']):
                e=json.loads(line.split(marker,1)[1]);e['afterInputMs']=(e['monoNs']-s['inputDispatchMonoNs'])/1e6;callbacks.append(e)
        row['callbackEvents']=callbacks
        configured=[e for e in callbacks if e['event']=='configure']
        closed=[e for e in callbacks if e['event']=='close']
        callbackVerified=(len(configured)==1 and configured[0]['requested']==1 and
            configured[0]['eligible']==1 and configured[0]['active']==1 and configured[0]['error']==0)
        if True:
            callbackVerified=callbackVerified and len(closed)==1 and all(
                e['codec']==configured[0]['codec'] and e['inputCallbacks']>0 and e['outputCallbacks']>0 and
                e['pendingInput']==0 and e['pendingOutput']==0 and e['closed']==1 and e['threadAlive']==0 and e['error']==0 for e in closed)
        asyncVerified=(callbackVerified and configured[0].get('asyncInputRequested')==int(value) and
            closed[0].get('asyncInput')==int(value) and
            all(closed[0].get(k)==0 for k in ['pendingSubmissions','inputThreadAlive','inputFailure']) and
            closed[0].get('inputPosted')==closed[0].get('inputCompleted')+closed[0].get('inputCancelled') and
            (closed[0]['inputCompleted']>0 if value=='1' else closed[0]['inputPosted']==0))
        row['asyncInputMechanismVerified']=asyncVerified
        callbackVerified=callbackVerified and asyncVerified
        row['callbackMechanismVerified']=callbackVerified
        waitVerified=(len(closed)==1 and closed[0].get('waitEnabled')==0 and
            closed[0].get('emptyPolls',-1)>=0 and
            closed[0].get('waitCalls')==0 and closed[0].get('waitNs')==0)
        row['waitMechanismVerified']=waitVerified
        row['waitCounters']={k:closed[0].get(k) for k in ['waitEnabled','emptyPolls','waitCalls','waitNs']} if len(closed)==1 else None

        selected_options=[e for e in allEvents if e['event']=='startup.sync.options']
        row['videoQueueMechanismVerified']=len(selected_options)==1 and selected_options[0].get('videoDecodeQueueFrames')==1
        row['functionalPassed']=row['functionalPassed'] and callbackVerified and waitVerified and row['videoQueueMechanismVerified']
        row['resourceProfile']=m['resourceProfile']
        row['minPhysicalGiB']=min(x['availableRamGiB'] for x in m['memorySamples'])
        row['minCommitHeadroomGiB']=min(x['commitHeadroomGiB'] for x in m['memorySamples'])
        def vmstat(name):
            return {a:int(v) for a,v in (line.split() for line in (out/label/name).read_text().splitlines())}
        vm0,vm1=vmstat('monitored-vmstat-before.txt'),vmstat('vmstat-after.txt')
        row['guestVmstatDelta']={k:vm1.get(k,0)-vm0.get(k,0) for k in vm0 if k in ['pgmajfault','pswpin','pswpout'] or k.startswith(('pgscan_direct','pgscan_kswapd','pgsteal_direct'))}
        row['continuousPlaybackConcern']=row['maxPositiveGapMs']>500
        row['bodyRecoveryEvents']=[e for e in relevant if '.bodyRecovery.' in e['event']]
        armed=[e for e in row['bodyRecoveryEvents'] if e['event'].endswith('.armed')]
        row['bodyRecoveryMechanismVerified']=len(armed)==2 and all(e.get('progressRace') is False for e in armed)
        row['bodyRecoverySwitches']=[e for e in row['bodyRecoveryEvents'] if e['event'].endswith('.switched')]
        row['bodyRecoveryRetries']=[e for e in row['bodyRecoveryEvents'] if e['event'].endswith('.begin')]
        row['audioDecodeQueueEvents']=[e for e in relevant if e['event'].startswith('startup.audioDecodeQueue.')]
        limited=[e for e in row['audioDecodeQueueEvents'] if e['event'].endswith('.limited')]
        restored=[e for e in row['audioDecodeQueueEvents'] if e['event'].endswith('.restored')]
        row['audioDecodeQueueMechanismVerified']=(len(limited)==len(restored)==1 and float(limited[0]['previousSeconds'])==2 and float(limited[0]['actualSeconds'])==.08 and float(restored[0]['actualSeconds'])==2 and restored[0]['reason']=='source-frame' and len(row['audioDecodeQueueEvents'])==2) if label!='00-seed' else not row['audioDecodeQueueEvents']
        row['workerFaults']=[e for e in relevant if e['event']=='isolated.workerError' or (e['event']=='isolated.closed' and e.get('expected') is False)]
        row['functionalPassed']=row['functionalPassed'] and row['bodyRecoveryMechanismVerified'] and not row['workerFaults'] and row['audioDecodeQueueMechanismVerified']
        row['textureAfterOpenMs']=row['textureMs']-row['openMs'];rows.append(row)
        (out/'completed-samples.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
        print(json.dumps({k:row.get(k) for k in ['label','pid','textureMs','coverMs','strictStable','functionalCleanup','firstTexturePtsNs','fairPrimingMechanismVerified','nativeSelectedPtsVerified','decodeOnlyMechanismVerified','callbackMechanismVerified','waitMechanismVerified','waitCounters','videoQueueMechanismVerified','bodyRecoveryMechanismVerified','bodyRecoveryRetries','bodyRecoverySwitches','workerFaults','audioDecodeQueueMechanismVerified','asyncInputMechanismVerified']}),flush=True)
        if label=='00-seed':assert cacheVerified,'No verified disk seed; refuse misleading cache comparison'
        if label=='01-candidate':assert row['videoQueueMechanismVerified'] and row['callbackMechanismVerified'] and row['decodeOnlyMechanismVerified'] and row['waitMechanismVerified'] and row['audioDecodeQueueMechanismVerified'],'Callback wait mechanism/lifecycle failed; retain sample and inspect before extra comparisons'
except BaseException:
    (out/'failure.txt').write_text(traceback.format_exc(),encoding='utf-8')
    raise
finally:
    hostStop.set();hostThread.join(timeout=2)
    if original_wait is not None:
        subprocess.run(ADB+['shell','setprop','debug.piliplus.callback_wait',original_wait or "''"],capture_output=True,check=True,timeout=10)
    if original_callback is not None:
        subprocess.run(ADB+['shell','setprop',callback_property,original_callback or "''"],capture_output=True,check=True,timeout=10)
        (out/'callback-switch-restored.json').write_text(json.dumps({'original':original_callback,'actual':subprocess.check_output(ADB+['shell','getprop',callback_property],timeout=10).decode().strip()}))
    if original_property is not None:
        restored=subprocess.run(ADB+['shell','setprop',property_name,original_property or "''"],capture_output=True,timeout=10)
        (out/'switch-restored.json').write_text(json.dumps({'exit':restored.returncode,'original':original_property,'actual':subprocess.check_output(ADB+['shell','getprop',property_name],timeout=10).decode().strip()}),encoding='utf-8')
    alive=process.is_running() and process.create_time()==created and process.cmdline()==command
    report={'pid':process.pid,'createTime':created,'command':command,'keptRunning':alive,'reason':'Preserve this same emulator through preparation delays and follow-up cancellation verification. Close explicitly after actual testing.'}
    (out/'emulator-retained.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps({'emulatorRetained':alive}),flush=True)
