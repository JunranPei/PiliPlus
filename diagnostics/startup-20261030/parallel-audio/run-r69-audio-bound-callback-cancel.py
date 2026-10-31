"""Request return when this process announces the first decode-only reference frame."""
from pathlib import Path
import hashlib,json,subprocess,sys,time
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'tool'))
from capture_startup_listener import force_stop_before_capture
from native_sidx_host import install_if_different
ADB=['D:/Android_studio_sdk/platform-tools/adb.exe','-s','emulator-5572']
out=HERE/'r69-audio-bound-callback-cancel-01';out.mkdir(exist_ok=False)
prop='debug.piliplus.decode_only'
original=subprocess.check_output(ADB+['shell','getprop',prop],timeout=10).decode().strip()
(out/'switch-original.json').write_text(json.dumps({'property':prop,'original':original}))
subprocess.run(ADB+['shell','setprop',prop,'1'],capture_output=True,check=True,timeout=10)
assert subprocess.check_output(ADB+['shell','getprop',prop],timeout=10).strip()==b'1'
cbprop='debug.piliplus.codec_callbacks'
cb_original=subprocess.check_output(ADB+['shell','getprop',cbprop],timeout=10).decode().strip()
subprocess.run(ADB+['shell','setprop',cbprop,'1'],check=True,capture_output=True,timeout=10)
try:
 apk=HERE/'r69-audio-bound-callback.apk';capture=out/'capture';attempts=[]
 def adb(*args):
  r=subprocess.run(ADB+list(args),capture_output=True,timeout=15)
  attempts.append({'command':list(args),'exitCode':r.returncode});r.check_returncode()
 force_stop_before_capture(adb,'com.personal.piliplus')
 (out/'prepare.json').write_text(json.dumps(attempts,indent=2))
 install_if_different(ADB,apk,hashlib.sha256(apk.read_bytes()).hexdigest(),out/'installed.json')
 trigger=None;back=None;deadline=time.monotonic()+180
 with (out/'capture-command.txt').open('xb') as log:
  proc=subprocess.Popen([sys.executable,str(ROOT/'tool/capture_startup_listener.py'),str(capture),
   '--serial','emulator-5572','--apk',str(apk),'--start-progress-ms','61500','--seconds','22',
   '--verify-input-target','--hide-ime-before-input','--resource-profile','lean-monitored'],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
  while proc.poll() is None and time.monotonic()<deadline:
   if trigger is None and (capture/'capture.json').exists() and (capture/'logcat.txt').exists():
    try:m=json.loads((capture/'capture.json').read_text())
    except json.JSONDecodeError:m={}
    if m.get('status')=='capturing' and m.get('pid'):
     for line in (capture/'logcat.txt').read_text(errors='replace').splitlines():
      if '[CODEC_FLUSH] ' not in line or line.split()[1]!=str(m['pid']):continue
      try:e=json.loads(line.split('[CODEC_FLUSH] ',1)[1])
      except json.JSONDecodeError:continue
      if e['event']!='receive.first':continue
      trigger=e;begin=time.perf_counter_ns();adb('shell','input','keyevent','4');end=time.perf_counter_ns()
      back={'hostBeginNs':begin,'hostEndNs':end,'triggerEvent':e,'pid':m['pid'],
            'afterMeasuredInputCommandSeconds':(begin-m['measuredInputCommand']['hostEndNs'])/1e9}
      (out/'listener-triggered-back.json').write_text(json.dumps(back,indent=2))
      print('Return requested after current decoder receive.first',flush=True);break
   time.sleep(.04)
  ret=proc.wait(timeout=30)
 m=json.loads((capture/'capture.json').read_text());s=m['summary']
 assert m['status']=='captured' and not m['errors'] and s['validInput'] and trigger is not None
 (out/'capture-before-external-action-metadata.json').write_bytes((capture/'capture.json').read_bytes())
 m['externalBackAction']=back
 # Preserve this external action's actual host timing and distinguish it from the
 # capture tool's internal capture_start timer. Native route.leave is reviewed below.
 m['backSentAfterSeconds']=back['afterMeasuredInputCommandSeconds']
 m['backTimingOrigin']='External listener; host perf-counter relative to measured input-command completion'
 (capture/'capture.json').write_text(json.dumps(m,indent=2))
 subprocess.run([sys.executable,str(ROOT/'tool/review_startup_return_cleanup.py'),str(capture)],check=True,timeout=30)
 lead=[]
 for line in (capture/'logcat.txt').read_text(errors='replace').splitlines():
  if '[AUDIO_LEAD] ' in line and line.split()[1]==str(m['pid']):
   e=json.loads(line.split('[AUDIO_LEAD] ',1)[1]);e['afterInputMs']=(e['monoNs']-s['inputDispatchMonoNs'])/1e6;lead.append(e)
 report={'captureExit':ret,'pid':m['pid'],'inputValid':True,'back':back,'leadEvents':lead,
  'hasPositiveTexture':s['validTextureObservation'],'returnCleanupPassed':True,
  'cancelBeforeDrainVerified':not s['validTextureObservation'] and not any(e['event']=='drain.begin' for e in lead),
  'boundary':'Actual native receive.first triggered external return request; cancellation phase determined by native drain/clear events, not intended command time. No positive texture expected for cancellation before target.'}
 decode_events=[]
 for line in (capture/'logcat.txt').read_text(errors='replace').splitlines():
  if '[DECODE_ONLY] ' in line and line.split()[1]==str(m['pid']):
   e=json.loads(line.split('[DECODE_ONLY] ',1)[1]);e['afterInputMs']=(e['monoNs']-s['inputDispatchMonoNs'])/1e6;decode_events.append(e)
 report['decodeOnlyEvents']=decode_events
 report['decodeOnlyWasApplied']=any(e['event']=='queue.first' and e['enabled']==1 and e['flags']==32 for e in decode_events)
 report['decoderClosed']=any(e['event']=='close' and e['enabled']==1 for e in decode_events)
 assert report['decoderClosed']
 (out/'reviewed.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)

finally:
 subprocess.run(ADB+['shell','setprop',cbprop,cb_original or "''"],check=True,capture_output=True,timeout=10)
 r=subprocess.run(ADB+['shell','setprop',prop,original or "''"],capture_output=True,timeout=10)
 (out/'switch-restored.json').write_text(json.dumps({'exit':r.returncode,'actual':subprocess.check_output(ADB+['shell','getprop',prop],timeout=10).decode().strip(),'original':original}))
