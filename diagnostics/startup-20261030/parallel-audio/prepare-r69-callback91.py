from pathlib import Path
import json
BASE=Path(__file__).resolve().parent
OUT=BASE/'r69-audio-bound-callback-repack-01';OUT.mkdir(exist_ok=False)
assert json.loads((BASE/'r69-audio-bound-observed-01/device-reviewed.json').read_text())['actualPreFrameCancel']['passed']
s=(BASE/'native-codec-callback-01/repack-candidate.py').read_text()
s=s.replace("old=base/'decode-only-candidate.apk';target=base/'codec-callback-candidate.apk'", "native_dir=base/'native-codec-callback-01'\nold=base/'r69-audio-bound-candidate.apk';target=base/'r69-audio-bound-callback.apk'")
s=s.replace("lib=out/'libmpv-codec-callback-x86_64.so'","lib=native_dir/'libmpv-codec-callback-x86_64.so'")
s=s.replace("(out/'native-build-01.json')","(native_dir/'native-build-01.json')")
s=s.replace("assert native['buildPassed'] and native['unmounted']", "assert native['buildPassed'] and native['unmounted']\nassert native['baselineNativeSha256']==meta['nativeLibraryOverride']['librarySha256']\nassert all(native['effectiveSourceHashes'][k]==v for k,v in meta['nativeLibraryOverride']['nativeSourceHashes'].items())")
s=s.replace('p in out.iterdir()','p in native_dir.iterdir()').replace("b.write(out/n,'native-codec-callback/'+n)","b.write(native_dir/n,'native-codec-callback/'+n)").replace('sha((out/n).read_bytes())','sha((native_dir/n).read_bytes())')
s=s.replace("'nativeSourceHashes':native['sourceHashes']", "'nativeSourceHashes':native['effectiveSourceHashes']")
s=s.replace('Decode-only kept off in both arms','Round69 decode-only1 and round90 audioBound1 kept on in both arms')
compile(s,'repack.py','exec');(OUT/'repack.py').write_text(s)

s=(BASE/'run-r69-audio-bound.py').read_text().replace('r69-audio-bound-observed-01','r69-audio-bound-callback-observed-01')
s=s.replace("apks={v:HERE/f'r69-audio-bound-{v}.apk'", "apks={v:HERE/'r69-audio-bound-callback.apk'")
s=s.replace("assert flags['control'].pop('STARTUP_AUDIO_DECODE_QUEUE_BOUNDED')=='false'", "assert flags['control'].pop('STARTUP_AUDIO_DECODE_QUEUE_BOUNDED')=='true'")
s=s.replace("HERE/'r69-audio-bound-plan.json'", "HERE/'r69-audio-bound-callback-plan.json'")
s=s.replace("property_name='debug.piliplus.decode_only'", "property_name='debug.piliplus.codec_callbacks'")
s=s.replace('original_property=None','original_property=None\noriginal_decode=None')
needle="    original_property=subprocess.check_output"
s=s.replace(needle,"    original_decode=subprocess.check_output(ADB+['shell','getprop','debug.piliplus.decode_only'],timeout=10).decode().strip()\n    subprocess.run(ADB+['shell','setprop','debug.piliplus.decode_only','1'],capture_output=True,check=True,timeout=10)\n"+needle,1)
s=s.replace("value='1'", "value='1' if variant=='candidate' else '0'")
s=s.replace("all(e['enabled']==int(value) for e in decode_only)","all(e['enabled']==1 for e in decode_only)")
s=s.replace("first[0]['flags']==(32 if value=='1' else 0)","first[0]['flags']==32")
s=s.replace("close[0]['applied']==(close[0]['eligible'] if value=='1' else 0)","close[0]['applied']==close[0]['eligible']")
s=s.replace(" if variant=='candidate' else not row['audioDecodeQueueEvents']",'')
source=(BASE/'run-codec-callback-observed.py').read_text()
callback=source[source.index('        callbacks=[]'):source.index("        row['resourceProfile']")]
s=s.replace("        row['resourceProfile']",callback+"        row['resourceProfile']",1)
s=s.replace("'audioDecodeQueueMechanismVerified','maxPositiveGapMs']", "'audioDecodeQueueMechanismVerified','callbackMechanismVerified','maxPositiveGapMs']")
s=s.replace("assert row['decodeOnlyMechanismVerified'] and row['audioDecodeQueueMechanismVerified']", "assert row['decodeOnlyMechanismVerified'] and row['audioDecodeQueueMechanismVerified'] and row['callbackMechanismVerified']")
s=s.replace("    alive=process.is_running()", "    if original_decode is not None:\n        subprocess.run(ADB+['shell','setprop','debug.piliplus.decode_only',original_decode or \"''\"],capture_output=True,check=True,timeout=10)\n    alive=process.is_running()")
name='run-r69-audio-bound-callback.py';compile(s,name,'exec');(BASE/name).write_text(s)
s=(BASE/'review-r69-audio-bound.py').read_text().replace('r69-audio-bound-observed-01','r69-audio-bound-callback-observed-01')
s=s.replace("BASE/f'r69-audio-bound-{v}.build.json'", "BASE/'r69-audio-bound-callback.build.json'")
s=s.replace("'round':90", "'round':91").replace("mechanisms=['audioDecodeQueueMechanismVerified'", "mechanisms=['callbackMechanismVerified','audioDecodeQueueMechanismVerified'")
s=s.replace('Round69 native/source plus only86 temporary audio decode queue bound; decode_only1 in both; no later video queue/callback/body recovery', 'Round69+86 sources and native70 callback wrapper; sameAPK callbacks0/1, decode_only1/audioBound1 in both; no later wait/videoqueue/bodyrecovery/asyncinput')
s=s.replace('round90-r69-audio-bound.md','round91-r69-audio-bound-callback.md').replace('第90轮：第69轮基线上只加入音频解码限量','第91轮：第69轮与音频限量之上叠加回调通知')
name='review-r69-audio-bound-callback.py';compile(s,name,'exec');(BASE/name).write_text(s)
plan={'round':91,'baseline':'Retained90:69source/decode_only1 plus86 audioBound. Replaceonlynative witharchived70 that wasbuiltfromexact69, sameAPKtoggle callbacks0/1.',
    'sourceScope':'No Dart/Android/assetchange; native70 wrapper plus reviewedembeddedhelper only. No callback_wait, videoqueue, asyncinput or bodyrecovery.',
    'protocol':'Same5572 lifetime,8freshprocess61.5s BAABABBA4each; verifyruntime callbackactivation,decodeflags,audio restore andallcontinuity/cleanup. Separate actualcancel/seek ifretained.',
    'netGainMs':None,'doNotAddPriorGains':True,'previousCombination':'90 net+190.0631ms, actualcancel/seekpassed; minimum1470.3236ms butnotphysicaldisplay/phoneclaim.'}
(BASE/'r69-audio-bound-callback-plan.json').write_text(json.dumps(plan,indent=2))
print('Prepared91 archive-native repack and sameAPK8sample callback comparison; no native rebuild.')
