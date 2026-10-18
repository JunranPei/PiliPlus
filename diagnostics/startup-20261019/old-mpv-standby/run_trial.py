"""One verified-install historical mpv standby trial; no media preload."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).resolve().parent
BASE=ROOT/'diagnostics/startup-20261018/rollback-baseline'
p=argparse.ArgumentParser();p.add_argument('mode',choices=['control','standby']);p.add_argument('label');p.add_argument('--home-probe',action='store_true');args=p.parse_args()
apk=OUT/f'old-mpv-{args.mode}.apk'
adb=['adb','-s','emulator-5556']
def run(*a):return subprocess.check_output(adb+list(a),timeout=60)
run('shell','am','force-stop','com.personal.piliplus');run('install','-r','-d',str(apk))
remote=run('shell','pm','path','com.personal.piliplus').decode().strip().removeprefix('package:')
sha=run('shell','sha256sum',remote).decode().split()[0]
assert sha==hashlib.file_digest(apk.open('rb'),'sha256').hexdigest()
if args.home_probe:
    folder=OUT/args.label;folder.mkdir(exist_ok=False)
    run('logcat','-c')
    (folder/'activity-launch.txt').write_bytes(run('shell','am','start','-W','-n','com.personal.piliplus/com.personal.piliplus.MainActivity'))
    time.sleep(5)
    (folder/'home.png').write_bytes(run('exec-out','screencap','-p'))
    (folder/'idle-meminfo.txt').write_bytes(run('shell','dumpsys','meminfo','com.personal.piliplus'))
    pid=run('shell','pidof','com.personal.piliplus').decode().strip()
    (folder/'idle-cpu.txt').write_bytes(run('shell','top','-b','-n','2','-d','1','-p',pid))
    log=run('logcat','-d','-v','epoch','-s','flutter').decode('utf8','replace')
    (folder/'standby.log').write_text('\n'.join(l for l in log.splitlines() if any(tag in l for tag in ['[OUTPUT_STANDBY]','[PLAYER_STANDBY]','[SURFACE_CALL]'])),encoding='utf8')
    (folder/'idle-native.log').write_bytes(run('logcat','-d','-v','epoch','--pid='+pid,'-s','media_kit','MediaCodec','CCodec','AudioTrack'))
    (folder/'metadata.json').write_text(json.dumps({'mode':args.mode,'pid':pid,'apkSha256':sha,'mediaOpened':False,'launchTimeIsNotVisualTiming':True,'expectedOutput':'mediacodec_embed'},indent=2))
    print((folder/'standby.log').read_text(encoding='utf8'),flush=True)
else:
    label=f'old-mpv-standby-{args.label}-20261019'
    subprocess.run([sys.executable,str(BASE/'capture_timing.py'),label,'--serial','emulator-5556','--index','5','--cold-app','--keep-player','--collect-standby'],cwd=ROOT,check=True)
    m=BASE/f'{label}-5-capture.json';(OUT/m.name).write_bytes(m.read_bytes())
