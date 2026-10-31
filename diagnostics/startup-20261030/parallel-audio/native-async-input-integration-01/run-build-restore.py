from pathlib import Path
import json,os,psutil,subprocess,sys,time,traceback
out=Path(__file__).resolve().parent;base=out.parent;root=base.parents[2]
assert json.loads((out/'embedded-device-reviewed.json').read_text())['passed']
adb='D:/Android_studio_sdk/platform-tools/adb.exe'
qa=json.loads((base/'resume-body-progress-qa145/emulator-process.json').read_text())
gallery=json.loads((base/'phone-fastest69-01/gallery-restore.json').read_text())['runningProcesses'][0]
targets=[{'kind':'QA','port':'5554','pid':qa['pid'],'createTime':qa['createTime'],'command':qa['command'],'launcher':str(root/'tmp/startup-test-emulator-37.2.12/emulator/emulator.exe')},
 {'kind':'Gallery','port':'5556','pid':gallery['pid'],'createTime':gallery['create_time'],'command':gallery['cmdline'],'launcher':'D:/Android_studio_sdk/emulator/emulator.exe'}]
# Stop only the known QA and already-authorized Gallery. Preserve their exact data/arguments.
for item in targets:
 p=psutil.Process(item['pid']);assert p.create_time()==item['createTime'] and p.cmdline()==item['command'],item
r=subprocess.run(['wsl.exe','--list','--running','--quiet'],capture_output=True,check=True)
running=r.stdout.decode('utf-16-le',errors='replace').replace('\x00','').strip()
(out/'wsl-before.txt').write_text(running)
assert 'Ubuntu-20.04' not in running,'Existing build VM needs live inspection before reuse'
report={'reason':'Serialize known Android emulators with native build VM after previously observed platform conflict. User authorized Gallery temporary close/restore. No data reset or resource thresholds.','targets':targets,'closed':[],'restored':[]}
build_rc=None
try:
 for item in targets:
  p=psutil.Process(item['pid'])
  r=subprocess.run([adb,'-s','emulator-'+item['port'],'emu','kill'],capture_output=True,timeout=15)
  (out/(item['kind']+'-close.txt')).write_bytes(r.stdout+r.stderr);r.check_returncode()
  try:p.wait(timeout=90)
  except psutil.TimeoutExpired:raise RuntimeError('Known emulator still exiting; inspect same process')
  report['closed'].append(item);(out/'build-platform-state.json').write_text(json.dumps(report,indent=2))
  print(item['kind']+' closed, data retained',flush=True)
 with(out/'build-session.log').open('xb')as log:
  proc=subprocess.Popen(['wsl.exe','-d','Ubuntu-20.04','-u','root','--','python3','/mnt/d/workplace/antigravity/PiliPlus/diagnostics/startup-20261030/parallel-audio/native-async-input-integration-01/build-native.py'],stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
  (out/'build-process.json').write_text(json.dumps({'pid':proc.pid,'createTime':psutil.Process(proc.pid).create_time()}))
  build_rc=proc.wait()
 (out/'build-session.json').write_text(json.dumps({'returncode':build_rc}))
 print('Native build exit '+str(build_rc),flush=True)
finally:
 # The VM was started here, after no pre-existing instance was found.
 subprocess.run(['wsl.exe','--terminate','Ubuntu-20.04'],capture_output=True,timeout=45)
 env=os.environ.copy();env.update(ANDROID_SDK_ROOT='D:/Android_studio_sdk',ANDROID_HOME='D:/Android_studio_sdk',ANDROID_AVD_HOME='D:/Android/.android/avd')
 for item in report['closed']:
  assert not psutil.pid_exists(item['pid']) or psutil.Process(item['pid']).create_time()!=item['createTime']
  with(out/(item['kind']+'-restore.stdout.log')).open('xb')as stdout,(out/(item['kind']+'-restore.stderr.log')).open('xb')as stderr:
   cmd=[item['launcher'],*item['command'][1:]]
   proc=subprocess.Popen(cmd,env=env,stdout=stdout,stderr=stderr,creationflags=subprocess.CREATE_NO_WINDOW)
  report['restored'].append({'kind':item['kind'],'launcherPid':proc.pid,'command':cmd})
  (out/'build-platform-state.json').write_text(json.dumps(report,indent=2))
  print(item['kind']+' restore launched',flush=True)
 if any(i['kind']=='QA'for i in report['closed']):
  subprocess.run([sys.executable,'-X','utf8',str(base/'wait-qa-ready-persistent.py'),str(out/'qa-ready.json')],check=True)
 for item in report['closed']:
  deadline=time.monotonic()+300
  while time.monotonic()<deadline:
   r=subprocess.run([adb,'-s','emulator-'+item['port'],'shell','getprop','sys.boot_completed'],capture_output=True,timeout=5)
   if r.returncode==0 and r.stdout.strip()==b'1':break
   time.sleep(2)
  else:raise RuntimeError(item['kind']+' boot observation expired; inspect retained process')
 actual=[]
 for p in psutil.process_iter(['name']):
  try:
   cmd=p.cmdline() if (p.info['name']or'').startswith('qemu-system-') else []
   for item in report['closed']:
    if '-avd'in cmd and cmd[cmd.index('-avd')+1]==item['command'][item['command'].index('-avd')+1]:
     actual.append({'kind':item['kind'],'pid':p.pid,'createTime':p.create_time(),'command':cmd,'status':p.status()})
  except(psutil.NoSuchProcess,psutil.AccessDenied):pass
 report['runningAfterRestore']=actual;report['bootVerified']=True
 (out/'build-platform-state.json').write_text(json.dumps(report,indent=2))
 print(json.dumps({'restored':actual}),flush=True)
assert build_rc==0,build_rc
