"""Backport only round86 to round69 sources, build a pair, restore workspace."""
from pathlib import Path
import difflib
import hashlib
import json
import subprocess
import sys
import traceback
import zipfile

ROOT = Path(__file__).resolve().parents[3]
BASE = Path(__file__).resolve().parent
OUT = BASE/'r69-audio-bound-build-01'
OUT.mkdir(exist_ok=False)
sha = lambda data: hashlib.sha256(data).hexdigest()
meta = json.loads((BASE/'decode-only-candidate.build.json').read_text())
assert sha((BASE/'decode-only-candidate.apk').read_bytes()) == meta['sha256']
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT).decode().strip() == '43960373442bf22516a7a13435ea529d393ca6ae'
assert not subprocess.check_output(['git','diff','--name-only','--','lib','android','tool'],cwd=ROOT).strip()
changed = ['lib/plugin/pl_player/controller.dart', 'lib/plugin/pl_player/playback/parallel_audio_source.dart',
    'lib/plugin/pl_player/playback/bounded_body_warmup.dart', 'lib/plugin/pl_player/playback/isolated_media_sources.dart']
originals = {name:(ROOT/name).read_bytes() for name in changed}
controller = originals[changed[0]].decode().replace('\r\n','\n')
video_chunks = [
"""    // Experimental: keep decoder waits off the playback thread without a
    // multi-frame hardware buffer backlog. Remains off in ordinary builds.
    final videoDecodeQueue =
        Platform.isAndroid &&
        const bool.fromEnvironment('STARTUP_VIDEO_DECODE_QUEUE');
""",
"""      if (videoDecodeQueue) ...{
        'vd-queue-enable': 'yes',
        'vd-queue-max-samples': '1',
        'vd-queue-max-bytes': '16777216',
        'vd-queue-max-secs': '0.05',
      },
""",
"""      'videoDecodeQueueFrames': videoDecodeQueue ? 1 : 0,
""",
]
for chunk in video_chunks:
    assert controller.count(chunk) == 1
    controller = controller.replace(chunk, '')
assert 'videoDecodeQueue' not in controller
staged = {}
with zipfile.ZipFile(BASE/'decode-only-candidate.sources.zip') as archive:
    actual = [name for name in archive.namelist() if name.startswith(('lib/','android/'))
        and (ROOT/name).is_file() and (ROOT/name).read_bytes() != archive.read(name)]
    assert set(actual) == set(changed), actual
    for name in changed:
        staged[name] = archive.read(name)
    old_controller = staged[changed[0]].decode().replace('\r\n','\n')
    patch = ''.join(difflib.unified_diff(old_controller.splitlines(True),controller.splitlines(True),
        fromfile='round69/controller.dart', tofile='round69-plus-audio-bound/controller.dart'))
    assert '+    final videoDecodeQueue' not in patch and 'limitStartupAudioDecode' in patch
    (OUT/'only-audio-bound.patch').write_text(patch, encoding='utf-8')
    staged[changed[0]] = controller.replace('\n','\r\n').encode()

for name,data in originals.items():
    path = OUT/'workspace-before'/name
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_bytes(data)
for name,data in staged.items():
    path = OUT/'staged-sources'/name
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_bytes(data)
helper='lib/plugin/pl_player/playback/startup_audio_decode_queue.dart'
(OUT/'startup_audio_decode_queue.dart').write_bytes((ROOT/helper).read_bytes())
plan={'round':90,'savedHead':'43960373442bf22516a7a13435ea529d393ca6ae',
    'baseline':'Round69 exact native and source archive, decode_only1, callbacks/wait/async off; no video queue or later body recovery. Only backported86 audio limit differs.',
    'control':'Identical backported source with STARTUP_AUDIO_DECODE_QUEUE_BOUNDED=false',
    'candidate':'Identical backported source with STARTUP_AUDIO_DECODE_QUEUE_BOUNDED=true',
    'change':'Audio decoder queue2s to0.08s until current source frame, cancel, replacement, disposal, error or deadline;86 corrected cancel-before-revision order retained.',
    'protocol':'Same retained5572 Android lifetime, fresh process61.5s BAAB with disk index verified each sample; no timing during builds. Native PTS, consumed PTS, continuity and cleanup recorded separately.',
    'laterCandidates':['70 callback notification','80 video decoder queue','81 stalled body recovery','85 slow progress race','87 asynchronous video input'],
    'netGainMs':None,'originalSourceHashes':{n:sha(v)for n,v in originals.items()},
    'stagedSourceHashes':{n:sha(v)for n,v in staged.items()},'helperSha256':sha((ROOT/helper).read_bytes()),
    'baselineApkSha256':meta['sha256'],'baselineNativeSha256':meta['nativeLibraryOverride']['librarySha256']}
(BASE/'r69-audio-bound-plan.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2))
report={'plan':plan,'steps':[]}
try:
    for name,data in staged.items(): (ROOT/name).write_bytes(data)
    flutter=str(ROOT/'tmp/flutter-sdk-3.47.6/flutter/bin/flutter.bat')
    commands=[('focused-tests',[flutter,'test','--no-pub','test/startup_audio_decode_queue_test.dart',
        'test/mpv_frame_gate_test.dart','test/playback_source_queue_test.dart']),
        ('analyze',[flutter,'analyze','--no-pub','lib/plugin/pl_player/controller.dart',helper])]
    for name,command in commands:
        print(name,flush=True)
        with (OUT/f'{name}.txt').open('xb') as log:
            subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        report['steps'].append({'step':name,'passed':True})
    for variant in ['candidate','control']:
        print('Building round69 plus audio bound '+variant,flush=True)
        command=[sys.executable,'-X','utf8',str(ROOT/'tool/repack_startup_dart.py'),
            '--base',str(BASE/'decode-only-candidate.apk'), '--output',str(BASE/f'r69-audio-bound-{variant}.apk'),
            '--define','STARTUP_AUDIO_DECODE_QUEUE_BOUNDED='+('true'if variant=='candidate'else'false'),
            '--allow-source',changed[0],'--allow-source',helper]
        with (OUT/f'{variant}-build.txt').open('xb') as log:
            subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        report['steps'].append({'step':variant,'passed':True})
    a=json.loads((BASE/'r69-audio-bound-control.build.json').read_text())
    b=json.loads((BASE/'r69-audio-bound-candidate.build.json').read_text())
    assert a['diagnosticSourcesSha256']==b['diagnosticSourcesSha256']
    for data in [a,b]:
        assert data['nativeLibraryOverride']==meta['nativeLibraryOverride']
        assert data['dartOnlyRefresh']['payloadDifferences']==['lib/x86_64/libapp.so']
    flags=[dict(value.split('=',1)for value in data['defines'])for data in [a,b]]
    assert flags[0].pop('STARTUP_AUDIO_DECODE_QUEUE_BOUNDED')=='false'
    assert flags[1].pop('STARTUP_AUDIO_DECODE_QUEUE_BOUNDED')=='true'
    assert flags[0]==flags[1]
    report['pairedBuildPassed']=True
except BaseException:
    report['failure']=traceback.format_exc()
    raise
finally:
    conflicts=[]
    for name,data in originals.items():
        current=(ROOT/name).read_bytes()
        if current==staged[name]: (ROOT/name).write_bytes(data)
        elif current!=data: conflicts.append(name)
    report['workspaceRestored']=not conflicts
    report['restoreConflicts']=conflicts
    (OUT/'build-reviewed.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps({'pairBuilt':report.get('pairedBuildPassed',False),
        'workspaceRestored':not conflicts,'failure':report.get('failure')}),flush=True)
