"""Build the frozen116 phone release; preserve all ongoing workspace edits."""
from pathlib import Path
import hashlib,json,subprocess,sys,zipfile,traceback
O=Path(__file__).resolve().parent;R=O.parents[3];B=O.parent
sha=lambda d:hashlib.sha256(d).hexdigest()
native=json.loads((O/'native-build.json').read_bytes())
assert native['buildPassed'] and native['unmounted'] and native['originalSourcesRestored']
library=O/'libmpv-inline116-arm64.so';assert sha(library.read_bytes())==native['librarySha256']
base=B/'inline-video116-candidate.apk';historical=json.loads(base.with_suffix('.build.json').read_bytes())
assert sha(base.read_bytes())==historical['sha256']
target=O/'release-unsigned-delivery-check.apk'
originals={};staged={};report={'baseline':str(base),'baselineSha256':historical['sha256'],'playbackVersion':116}
try:
    with zipfile.ZipFile(base.with_suffix('.sources.zip'))as z:
        for name in z.namelist():
            p=R/name
            if name.startswith(('lib/','android/')) and p.is_file() and p.read_bytes()!=z.read(name):
                originals[name]=p.read_bytes();staged[name]=z.read(name)
                q=O/'workspace-before'/name;q.parent.mkdir(parents=True,exist_ok=True);q.write_bytes(originals[name])
        for name,data in staged.items():(R/name).write_bytes(data)
    flags='--async-source-frame-gate --prefetch-resume-body --reuse-resume-index --persist-resume-index --hedge-resume-prefetch --hedge-fresh-resume-prefetch --defer-auxiliary --prioritize-play-url --aaudio-first --audio-decode-queue --bounded-audio-decode-queue --bounded-resume-init --inline-video --filtered-audio-lead --reserve-selected-codec --skip-unused-codec-flush --visible-url-prefetch --visible-media-prefetch --visible-native-preload --visible-resume-preload --retain-ready-url --source-buffer-ready-gate --source-frame-ready-gate --warm-orientation-service --async-orientation-registration --early-source --parallel-audio --cancel-closed-media-delivery --parallel-resume-media --prefetch-resume-range --prefetch-resume-audio-master --prefetch-resume-presentation-time --isolated-media --hedge-audio --hedge-media --hedge-delay-ms 0 --uncut-dash'.split()
    cmd=[sys.executable,'-X','utf8',str(R/'tool/build_startup_standby.py'),'--output',str(target),
         '--target-platform','android-arm64','--native-mpv',str(library),'--no-trace','--observe-build-resources','--offline',*flags]
    report['command']=cmd;report['stagedSourceHashes']={n:sha(d)for n,d in staged.items()}
    (O/'app-command.json').write_text(json.dumps(report,indent=2))
    print('Building phone ARM64 release from frozen116; measurement features disabled',flush=True)
    with(O/'app-session.log').open('xb')as log:
        subprocess.run(cmd,cwd=R,stdout=log,stderr=subprocess.STDOUT,check=True)
    report['buildPassed']=True
except BaseException:
    report['failure']=traceback.format_exc();raise
finally:
    conflicts=[];errors=[]
    for name,data in originals.items():
        try:
            if (R/name).read_bytes()==staged[name]:(R/name).write_bytes(data)
            elif (R/name).read_bytes()!=data:conflicts.append(name)
        except Exception as e:errors.append({'path':name,'error':repr(e)})
    report['workspaceRestored']=not conflicts and not errors;report['restoreConflicts']=conflicts;report['restoreErrors']=errors
    (O/'app-build.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({k:report.get(k)for k in ['buildPassed','workspaceRestored','failure','restoreErrors']}),flush=True)
