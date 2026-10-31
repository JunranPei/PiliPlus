from pathlib import Path
import json

BASE=Path(__file__).resolve().parent
s=(BASE/'run-decode-only-observed.py').read_text()
s=s.replace('emulator-5554','emulator-5572')
s=s.replace("out=HERE/f'decode-only-observed-{batch:02}'", "out=HERE/'r69-audio-bound-observed-01'")
start=s.index('plan=[');end=s.index('# Prelaunch',start)
s=s[:start]+'''plan=[('01-candidate','candidate'),('02-control','control'),('03-control','control'),('04-candidate','candidate'),
    ('05-control','control'),('06-candidate','candidate'),('07-candidate','candidate'),('08-control','control')]
apks={v:HERE/f'r69-audio-bound-{v}.apk' for v in ['control','candidate']}
metas={v:json.loads(p.with_suffix('.build.json').read_text())for v,p in apks.items()}
assert metas['control']['nativeLibraryOverride']==metas['candidate']['nativeLibraryOverride']
assert metas['control']['diagnosticSourcesSha256']==metas['candidate']['diagnosticSourcesSha256']
assert json.loads((HERE/'r69-audio-bound-build-01/build-reviewed.json').read_text())['workspaceRestored']
flags={v:dict(x.split('=',1) for x in m['defines']) for v,m in metas.items()}
assert flags['control'].pop('STARTUP_AUDIO_DECODE_QUEUE_BOUNDED')=='false'
assert flags['candidate'].pop('STARTUP_AUDIO_DECODE_QUEUE_BOUNDED')=='true'
assert flags['control']==flags['candidate']
(out/'plan.json').write_text((HERE/'r69-audio-bound-plan.json').read_text())
''' + s[end:]
start=s.index("if not owned:raise RuntimeError")
end=s.index('process=owned[0]',start)
s=s[:start]+"assert len(owned)==1,'Inspect current QA process; no automatic replacement'\n"+s[end:]
anchor='rows=[];pids=set()'
watch=(BASE/'run-async-wait-stacked.py').read_text()
watch=watch[watch.index('# Read-only process-state listener:'):watch.index('rows=[];pids=set()')]
s=s.replace(anchor,watch+anchor)
old="    subprocess.run([sys.executable,str(HERE/'wait-qa-ready-persistent.py'),str(out/'existing-emulator-ready.json')],check=True,timeout=390)"
assert old in s
s=s.replace(old,"    assert subprocess.check_output(ADB+['get-state'],timeout=10).strip()==b'device'\n    assert 'PiliPlusStartupIsolated_20261018' in subprocess.check_output(ADB+['emu','avd','name'],timeout=10).decode()")
s=s.replace("value='1' if variant=='candidate' else '0'","value='1'")
s=s.replace("'--seconds','22'","'--seconds','25'")
old="""                subprocess.run([sys.executable,str(ROOT/'tool'/script),str(out/label)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=30)
        cleanup=json.loads((out/label/'return-cleanup-reviewed.json').read_text(encoding='utf-8'))
        assert cleanup['passed'],cleanup"""
new="""                result=subprocess.run([sys.executable,str(ROOT/'tool'/script),str(out/label)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=False,timeout=30)
                if script=='summarize_startup_continuity.py':result.check_returncode()
        cleanup_file=out/label/'return-cleanup-reviewed.json'
        cleanup=json.loads(cleanup_file.read_text()) if cleanup_file.exists() else {'passed':False,'reason':'Reviewer failure retained'}
        if not cleanup['passed']:(out/label/'return-failure-retained.json').write_text(json.dumps(cleanup))"""
assert old in s;s=s.replace(old,new)
anchor="        row['textureAfterOpenMs']=row['textureMs']-row['openMs'];rows.append(row)"
extra="""        row['continuousPlaybackConcern']=row['maxPositiveGapMs']>500
        row['audioDecodeQueueEvents']=[e for e in relevant if e['event'].startswith('startup.audioDecodeQueue.')]
        limited=[e for e in row['audioDecodeQueueEvents']if e['event'].endswith('.limited')]
        restored=[e for e in row['audioDecodeQueueEvents']if e['event'].endswith('.restored')]
        row['audioDecodeQueueMechanismVerified']=(len(limited)==len(restored)==1 and float(limited[0]['previousSeconds'])==2 and float(limited[0]['actualSeconds'])==.08 and float(restored[0]['actualSeconds'])==2 and restored[0]['reason']=='source-frame' and len(row['audioDecodeQueueEvents'])==2) if variant=='candidate' else not row['audioDecodeQueueEvents']
        row['workerFaults']=[e for e in relevant if e['event']=='isolated.workerError' or(e['event']=='isolated.closed' and e.get('expected')is False)]
        row['functionalPassed']=row['functionalPassed'] and row['audioDecodeQueueMechanismVerified'] and row['decodeOnlyMechanismVerified'] and not row['workerFaults'] and not row['continuousPlaybackConcern']
"""
assert anchor in s;s=s.replace(anchor,extra+anchor)
s=s.replace("'nativeSelectedPtsVerified','decodeOnlyMechanismVerified']}),", "'nativeSelectedPtsVerified','decodeOnlyMechanismVerified','audioDecodeQueueMechanismVerified','maxPositiveGapMs']}),")
s=s.replace("assert row['decodeOnlyMechanismVerified'],'Decode-only", "assert row['decodeOnlyMechanismVerified'] and row['audioDecodeQueueMechanismVerified'],'Decode-only/audio-bound")
s=s.replace('finally:\n    if original_property','finally:\n    hostStop.set();hostThread.join(timeout=2)\n    if original_property')
compile(s,'run-r69-audio-bound.py','exec')
(BASE/'run-r69-audio-bound.py').write_text(s)
plan=json.loads((BASE/'r69-audio-bound-plan.json').read_text())
plan['protocol']='Same5572 lifetime,8 freshprocess61.5s samples BAABABBA,4 each; disk indexes verified; only withincohort net gain. No heavy tracing/building duringtiming. Preserve every slow sample and exactPTS/continuity failure.'
(BASE/'r69-audio-bound-plan.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2))
state_path=BASE/'active-continuation.json';state=json.loads(state_path.read_text())
state.update(previousTurn='Progress:pre-stack checkpoint439603734;90 backported only86 to69,36 tests passed; analyze/build handle62121 active.',
    buildHandle=62121,buildOutput='r69-audio-bound-candidate.apk + control',buildFinished=False,
    nextRunner=str(BASE/'run-r69-audio-bound.py'),next='Wait62121 build/analyze; verify same69native and onlyboundflag. Run8samecondition freshprocess61.5s BAABABBA on5572, then actualcancel/seek. Laterpositivecandidates queued; goalactive.')
state_path.write_text(json.dumps(state,ensure_ascii=False,indent=2))
print('Round90 matched8sample runner prepared; no playback started duringbuild.')
