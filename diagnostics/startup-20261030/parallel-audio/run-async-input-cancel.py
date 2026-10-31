"""Request return when this process announces the active codec callback configuration."""
from pathlib import Path
import hashlib,json,subprocess,sys,time,re
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'tool'))
from capture_startup_listener import force_stop_before_capture
from native_sidx_host import install_if_different
ADB=['D:/Android_studio_sdk/platform-tools/adb.exe','-s','emulator-5554']
out=HERE/'async-input-cancel-01';out.mkdir(exist_ok=False)
prop='debug.piliplus.codec_callbacks'
original=subprocess.check_output(ADB+['shell','getprop',prop],timeout=10).decode().strip()
(out/'switch-original.json').write_text(json.dumps({'property':prop,'original':original}))
subprocess.run(ADB+['shell','setprop',prop,'1'],capture_output=True,check=True,timeout=10)
assert subprocess.check_output(ADB+['shell','getprop',prop],timeout=10).strip()==b'1'
wait_prop='debug.piliplus.callback_wait'
wait_original=subprocess.check_output(ADB+['shell','getprop',wait_prop],timeout=10).decode().strip()
(out/'wait-switch-original.json').write_text(json.dumps({'original':wait_original}))
subprocess.run(ADB+['shell','setprop',wait_prop,'0'],capture_output=True,check=True,timeout=10)
async_prop='debug.piliplus.async_input'
async_original=subprocess.check_output(ADB+['shell','getprop',async_prop],timeout=10).decode().strip()
subprocess.run(ADB+['shell','setprop',async_prop,'1'],capture_output=True,check=True,timeout=10)
try:
 apk=HERE/'async-input-candidate.apk';capture=out/'capture';attempts=[]
 def adb(*args):
  r=subprocess.run(ADB+list(args),capture_output=True,timeout=15)
  attempts.append({'command':list(args),'exitCode':r.returncode});r.check_returncode()
 force_stop_before_capture(adb,'com.personal.piliplus')
 (out/'prepare.json').write_text(json.dumps(attempts,indent=2))
 install_if_different(ADB,apk,hashlib.sha256(apk.read_bytes()).hexdigest(),out/'installed.json')
 trigger=None;back=None;deadline=time.monotonic()+180
 with (out/'capture-command.txt').open('xb') as log:
  proc=subprocess.Popen([sys.executable,str(ROOT/'tool/capture_startup_listener.py'),str(capture),
   '--serial','emulator-5554','--apk',str(apk),'--start-progress-ms','61500','--seconds','22',
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
      trigger=e
      assert m.get('imeHiddenBeforeMeasuredInput') is True
      detected=time.perf_counter_ns()
      begin=time.perf_counter_ns();adb('shell','input','keyevent','4');end=time.perf_counter_ns()
      back={'hostBeginNs':begin,'hostEndNs':end,'triggerEvent':e,'pid':m['pid'],
            'afterMeasuredInputCommandSeconds':(begin-m['measuredInputCommand']['hostEndNs'])/1e9,'triggerDetectedHostNs':detected,'imeHiddenBeforeMeasuredInput':True}
      (out/'listener-triggered-back.json').write_text(json.dumps(back,indent=2))
      print('Return requested after current decoder first receive',flush=True);break
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
  'boundary':'Actual current-source decoder receive.first triggered return; phase determined by route.leave, positive texture and native drain events. No positive texture expected for cancellation before target.'}
 callback_events=[]
 for line in (capture/'logcat.txt').read_text(errors='replace').splitlines():
  if '[CODEC_CALLBACK] ' in line and line.split()[1]==str(m['pid']):
   e=json.loads(line.split('[CODEC_CALLBACK] ',1)[1]);e['afterInputMs']=(e['monoNs']-s['inputDispatchMonoNs'])/1e6;callback_events.append(e)
 report['callbackEvents']=callback_events
 closed=[e for e in callback_events if e['event']=='close']
 report['callbackClosedVerified']=len(closed)==1 and all(e['error']==0 and e['closed']==1 and e['threadAlive']==0 and e['pendingInput']==0 and e['pendingOutput']==0 and e.get('asyncInput')==1 and e.get('pendingSubmissions')==0 and e.get('inputThreadAlive')==0 and e.get('inputFailure')==0 and e['inputPosted']==e['inputCompleted']+e['inputCancelled'] for e in closed)
 reservation=[]
 for line in (capture/'logcat.txt').read_text(errors='replace').splitlines():
  if '[CODEC_RESERVATION] ' in line and line.split()[1]==str(m['pid']):reservation.append(json.loads(line.split('[CODEC_RESERVATION] ',1)[1]))
 report['reservationEvents']=reservation
 report['unclaimedReservationReleased']=not callback_events and any(e['event']=='released' for e in reservation) and not any(e['event']=='taken' for e in reservation)
 assert report['callbackClosedVerified'] or report['unclaimedReservationReleased']

 (out/'reviewed.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items()if k not in ['leadEvents','callbackEvents']}),flush=True)

finally:
 subprocess.run(ADB+['shell','setprop',async_prop,async_original or "''"],capture_output=True,check=True,timeout=10)
 subprocess.run(ADB+['shell','setprop',wait_prop,wait_original or "''"],capture_output=True,check=True,timeout=10)
 (out/'wait-switch-restored.json').write_text(json.dumps({'original':wait_original,'actual':subprocess.check_output(ADB+['shell','getprop',wait_prop],timeout=10).decode().strip()}))
 r=subprocess.run(ADB+['shell','setprop',prop,original or "''"],capture_output=True,timeout=10)
 (out/'switch-restored.json').write_text(json.dumps({'exit':r.returncode,'actual':subprocess.check_output(ADB+['shell','getprop',prop],timeout=10).decode().strip(),'original':original}))
