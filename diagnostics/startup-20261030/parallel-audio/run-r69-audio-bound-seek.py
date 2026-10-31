"""Actual seek only after the current source has produced a positive texture."""
from pathlib import Path
import hashlib,json,subprocess,sys,time

ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'tool'))
from capture_startup_listener import force_stop_before_capture
from playback_trace_files import announced_trace_pair
from native_sidx_host import install_if_different

out=HERE/'r69-audio-bound-seek-01';out.mkdir(exist_ok=False)
capture=out/'capture';apk=HERE/'r69-audio-bound-candidate.apk'
ADB=['D:/Android_studio_sdk/platform-tools/adb.exe','-s','emulator-5572']
def adb(*args):return subprocess.run(ADB+list(args),capture_output=True,check=True,timeout=20).stdout
props=['debug.piliplus.decode_only']
original={p:adb('shell','getprop',p).decode().strip()for p in props}
(out/'switch-original.json').write_text(json.dumps(original))
action=None;proc=None
try:
 for p in props:adb('shell','setprop',p,'1')
 force_stop_before_capture(adb,'com.personal.piliplus')
 install_if_different(ADB,apk,hashlib.sha256(apk.read_bytes()).hexdigest(),out/'installed.json')
 with(out/'capture-command.txt').open('xb')as log:
  proc=subprocess.Popen([sys.executable,str(ROOT/'tool/capture_startup_listener.py'),str(capture),
    '--serial','emulator-5572','--apk',str(apk),'--start-progress-ms','61500',
    '--seconds','25','--back-after','21','--verify-input-target','--resource-profile','lean-monitored'],
    cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
  deadline=time.monotonic()+180;polls=[]
  while proc.poll() is None:
   if time.monotonic()>deadline:raise TimeoutError('Owned capture exceeded 180s; retain emulator and raw capture')
   if action is None and (capture/'capture.json').exists():
    try:m=json.loads((capture/'capture.json').read_text())
    except json.JSONDecodeError:m={}
    if m.get('status')=='capturing':
     age=(time.perf_counter_ns()-m['measuredInputCommand']['hostEndNs'])/1e9
     if 4<=age<=8:
      names=announced_trace_pair((capture/'logcat.txt').read_text(errors='replace'),None,m['pid'])
      name=next(n for n in names if n.startswith('native'))
      raw=adb('shell','tail','-n','240',f'/sdcard/Android/data/com.personal.piliplus/files/playback-diagnostics/{name}')
      (out/f'pre-seek-native-{len(polls):02}.jsonl').write_bytes(raw)
      events=[]
      for line in raw.splitlines(keepends=True):
       if not line.endswith(b'\n'):continue
       events.append(json.loads(line))
      positive=[e for e in events if e['event']=='texture.consumed' and e['data'].get('surfaceValid') and 61500000000<=e['data'].get('textureTimestampNs',0)<85000000000]
      polls.append({'hostAgeSeconds':age,'positiveObservations':len(positive),'trace':name})
      (out/'pre-seek-observations.json').write_text(json.dumps(polls,indent=2))
      if positive:
       begin=time.perf_counter_ns();adb('shell','input','swipe','300','350','650','350','400');end=time.perf_counter_ns()
       action={'hostBeginNs':begin,'hostEndNs':end,'afterTapCommandSeconds':(begin-m['measuredInputCommand']['hostEndNs'])/1e9,'positiveBeforeGesture':positive[-1],'nativeTrace':name,'pid':m['pid']}
       (out/'observed-seek-action.json').write_text(json.dumps(action,indent=2));print('Gesture sent after current source positive texture',flush=True)
   time.sleep(.2)
  ret=proc.returncode
 m=json.loads((capture/'capture.json').read_text());s=m['summary']
 assert m['status']=='captured' and not m['errors'] and s['validInput']
 assert action is not None,'No steady-playback seek was issued before8s; preserve startup observation, do not mark seek passed'
 (out/'capture-before-external-seek-metadata.json').write_bytes((capture/'capture.json').read_bytes())
 m['externalSeekAction']=action;(capture/'capture.json').write_text(json.dumps(m,indent=2))
 with(out/'return-review.txt').open('xb')as log:
  subprocess.run([sys.executable,str(ROOT/'tool/review_startup_return_cleanup.py'),str(capture)],check=True,stdout=log,stderr=subprocess.STDOUT,timeout=30)
 (out/'capture-exit.json').write_text(json.dumps({'exit':ret,'seekIssuedAfterPositiveTexture':True}))
 print(json.dumps({'pid':m['pid'],'textureMs':s['firstChangedTextureConsumedAfterInputMs'],'actualGestureAfterTapSeconds':action['afterTapCommandSeconds'],'returnPassed':True}),flush=True)
finally:
 if proc is not None and proc.poll() is None:
  proc.terminate();proc.wait(timeout=15)
 for p,v in original.items():adb('shell','setprop',p,v or "''")
 restored={p:adb('shell','getprop',p).decode().strip()for p in props}
 (out/'switch-restored.json').write_text(json.dumps(restored));assert restored==original
