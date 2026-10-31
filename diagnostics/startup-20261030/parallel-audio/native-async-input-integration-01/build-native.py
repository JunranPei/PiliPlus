from pathlib import Path
import hashlib,json,os,subprocess,shutil,traceback
root=Path('/mnt/d/workplace/antigravity/PiliPlus');out=root/'diagnostics/startup-20261030/parallel-audio/native-async-input-integration-01'
base=Path('/mnt/piliplus-native-seek-20261030');recipe=base/'recipe/buildscripts';volume=root/'tmp/native-android-seek/build-filesystem.img'
prior=json.loads((out.parent/'native-callback-wait-01/native-build-01.json').read_text())
sha=lambda b:hashlib.sha256(b).hexdigest();library=out/'libmpv-async-input-x86_64.so'
patch=json.loads((out/'source-provenance.json').read_text())
assert json.loads((out/'embedded-device-reviewed.json').read_text())['passed']
assert not library.exists() and not (out/'native-build-01.json').exists()
assert prior['unmounted'] and not base.is_mount() and not any(base.iterdir())
assert subprocess.check_output(['blkid','-s','UUID','-o','value',str(volume)],text=True).strip()=='25aadd94-b618-42f4-9d7d-f06ea083b789'
report={'pid':os.getpid(),'architecture':'x86_64','baselineNativeSha256':prior['librarySha256']}
subprocess.run(['mount','-o','loop,noatime',str(volume),str(base)],check=True)
try:
 effective=dict(prior['effectiveSourceHashes'])
 for name,expected in effective.items():assert sha((recipe/'deps'/name).read_bytes())==expected,name
 assert sha((recipe/'prefix/x86_64/lib/libmpv.so').read_bytes())==prior['librarySha256']
 for name,expected in patch['before'].items():assert sha((recipe/'deps'/name).read_bytes())==expected,name
 for name,expected in patch['after'].items():assert sha((out/(name.replace('/','-')+'.after')).read_bytes())==expected,name
 for name,expected in patch['added'].items():assert not (recipe/'deps'/name).exists() and sha((out/Path(name).name).read_bytes())==expected,name
 for name,h in patch['replaced'].items():assert sha((recipe/'deps'/name).read_bytes())==h['before'] and sha((out/Path(name).name).read_bytes())==h['after'],name
 for name in patch['after']:shutil.copy2(out/(name.replace('/','-')+'.after'),recipe/'deps'/name)
 for name in patch['added']:shutil.copy2(out/Path(name).name,recipe/'deps'/name)
 for name in patch['replaced']:shutil.copy2(out/Path(name).name,recipe/'deps'/name)
 report['sourceHashes']=patch['after'];report['addedSourceHashes']=patch['added'];report['replacedSourceHashes']=patch['replaced']
 effective.update(patch['after']);effective.update(patch['added']);effective.update({n:h['after']for n,h in patch['replaced'].items()});report['effectiveSourceHashes']=effective
 env=dict(os.environ,PATH=f'{base}/tools/bin:{base}/venv/bin:'+os.environ['PATH'],cores='2')
 for target in ['ffmpeg','mpv']:
  print('Building '+target,flush=True)
  with (out/f'build-{target}.log').open('xb') as log:
   subprocess.run(['bash','build.sh','--arch','x86_64','-n',target],cwd=recipe,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
 shutil.copy2(recipe/'prefix/x86_64/lib/libmpv.so',library)
 assert all(x in library.read_bytes() for x in [b'asyncInputRequested',b'pendingSubmissions',b'PiliCodecInput',b'emptyPolls',b'awaitActivity',b'[CODEC_CALLBACK]',b'InMemoryDexClassLoader',b'[DECODE_ONLY]',b'[AUDIO_LEAD_GATE]',b'[AUDIO_LEAD]',b'[CODEC_FLUSH]',b'mpv_pili_reserve_codec'])
 assert (out/'embedded-dex/classes.dex').read_bytes() in library.read_bytes()
 report['librarySha256']=sha(library.read_bytes());report['buildPassed']=True
except BaseException:
 report['failure']=traceback.format_exc();raise
finally:
 subprocess.run(['sync','-f',str(base)],check=True);subprocess.run(['umount',str(base)],check=True)
 report['unmounted']=not base.is_mount()
 with (out/'native-build-01.json').open('x') as f:json.dump(report,f,indent=2)
 print(json.dumps(report),flush=True)
