"""ARM64 build of frozen116 native112 with the measured flags as phone defaults."""
from pathlib import Path
import hashlib,json,os,subprocess,traceback,time,zipfile,shutil
R=Path('/mnt/d/workplace/antigravity/PiliPlus');B=R/'diagnostics/startup-20261030/parallel-audio';O=B/'phone-inline116-01'
W=Path('/mnt/piliplus-native-seek-20261030');recipe=W/'recipe/buildscripts';volume=R/'tmp/native-android-seek/build-filesystem.img'
sha=lambda b:hashlib.sha256(b).hexdigest()
current=json.loads((B/'native-video-scheduling-124/native-build-01.json').read_text())
expected=json.loads((O/'native116-exact-hashes.json').read_text())
report={'architecture':'arm64-v8a','playbackVersion':116,'nativeSourceRound':112,'started':time.time(),
        'measuredX64NativeSha256':'35e8847edc59d9cd4ac84ee3e47506929ed079d0b0cad62f41fa479981c8ee86',
        'defaultSwitches':['codec_callbacks','decode_only','skip_empty_info','video_progress'],
        'explicitZeroStillDisables':True,'phonePerformanceMeasured':False}
assert not W.is_mount() and not any(W.iterdir())
assert subprocess.check_output(['blkid','-s','UUID','-o','value',str(volume)],text=True).strip()=='25aadd94-b618-42f4-9d7d-f06ea083b789'
subprocess.run(['mount','-o','loop,noatime',str(volume),str(W)],check=True)
originals={};staged={}
patches={
 'ffmpeg/libavcodec/pili_codec_callbacks_jni.h':(b'requested = !strcmp(value, "1");',b'requested = !value[0] || !strcmp(value, "1");'),
 'ffmpeg/libavcodec/mediacodecdec.c':(b's->ctx->pili_decode_only_enabled = !strcmp(pili_decode_only_value, "1");',b's->ctx->pili_decode_only_enabled = !pili_decode_only_value[0] || !strcmp(pili_decode_only_value, "1");'),
 'ffmpeg/libavcodec/pili_output_info_trace.h':(b't->skip_empty = surface && !strcmp(value, "1");',b't->skip_empty = surface && (!value[0] || !strcmp(value, "1"));'),
 'mpv/player/pili_video_progress.h':(b'return __system_property_get("debug.piliplus.video_progress", value) > 0 && value[0] == \'1\' && value[1] == 0;',b'int length = __system_property_get("debug.piliplus.video_progress", value);\n    return length == 0 || (value[0] == \'1\' && value[1] == 0);'),
}
try:
    for n,h in {**current['effectiveSourceHashes'],**current['additionalUnchangedSources']}.items():
        assert sha((recipe/'deps'/n).read_bytes())==h,n
    assert sha((recipe/'prefix/x86_64/lib/libmpv.so').read_bytes())==current['librarySha256']
    report['volumeSpaceBefore']=shutil.disk_usage(W)._asdict()
    for n,h in expected.items():
        source=O/'native116-exact'/n;data=source.read_bytes();assert sha(data)==h,n
        target=recipe/'deps'/n;originals[n]=target.read_bytes()
        backup=O/'volume-before'/n;backup.parent.mkdir(parents=True,exist_ok=True);backup.write_bytes(originals[n])
        if n in patches:
            before,after=patches[n];assert data.count(before)==1,n;data=data.replace(before,after)
        staged[n]=data;target.write_bytes(data)
    report['effectiveSourceHashes']={n:sha(data)for n,data in staged.items()}
    report['packagingOnlyDefaultChanges']={n:{'before':expected[n],'after':report['effectiveSourceHashes'][n]}for n in patches}
    with zipfile.ZipFile(O/'native-sources.zip','x',zipfile.ZIP_DEFLATED)as z:
        for n,data in staged.items():z.writestr(n,data)
    env=dict(os.environ,PATH=f'{W}/tools/bin:{W}/venv/bin:'+os.environ['PATH'],cores='2')
    print('Building frozen116 ARM64 FFmpeg and mpv; existing ARM64 dependencies reused',flush=True)
    for name in ['ffmpeg','mpv']:
        with(O/f'{name}-arm64.log').open('xb')as log:
            subprocess.run(['bash','build.sh','--arch','arm64','-n',name],cwd=recipe,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    data=(recipe/'prefix/arm64-v8a/lib/libmpv.so').read_bytes()
    assert data[:6]==b'\x7fELF\x02\x01' and int.from_bytes(data[18:20],'little')==183
    assert all(k in data for k in [b'[VIDEO_PROGRESS]',b'[CODEC_CALLBACK]',b'[CODEC_INFO]',b'[DECODE_ONLY]'])
    assert not any(k in data for k in [b'[VIDEO_SCHED]',b'[CODEC_SIGNAL]',b'[CODEC_PRIORITY]',b'asyncInputRequested'])
    for n,h in report['effectiveSourceHashes'].items():assert sha((recipe/'deps'/n).read_bytes())==h,n
    (O/'libmpv-inline116-arm64.so').write_bytes(data)
    report.update(buildPassed=True,librarySha256=sha(data),libraryBytes=len(data))
except BaseException:
    report['failure']=traceback.format_exc();raise
finally:
    conflicts=[]
    for n,data in originals.items():
        target=recipe/'deps'/n
        if target.read_bytes()==staged.get(n):target.write_bytes(data)
        elif target.read_bytes()!=data:conflicts.append(n)
    report['restoreConflicts']=conflicts;report['originalSourcesRestored']=not conflicts
    subprocess.run(['sync','-f',str(W)],check=True);subprocess.run(['umount',str(W)],check=True)
    report['unmounted']=not W.is_mount();report['finished']=time.time()
    (O/'native-build.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({k:v for k,v in report.items()if k not in ['effectiveSourceHashes','packagingOnlyDefaultChanges']}),flush=True)
