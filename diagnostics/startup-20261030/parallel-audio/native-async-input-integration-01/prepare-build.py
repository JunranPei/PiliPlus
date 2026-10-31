from pathlib import Path
import hashlib,json
out=Path(__file__).resolve().parent;old=out.parent/'native-callback-wait-01'
sha=lambda data:hashlib.sha256(data).hexdigest()
prior=json.loads((old/'native-build-01.json').read_text())
patch={'before':{},'after':{},'added':{},'replaced':{}}
for n in ['pili_codec_callbacks_jni.h','pili_codec_callbacks_dex.h']:
 key='ffmpeg/libavcodec/'+n
 patch['replaced'][key]={'before':prior['effectiveSourceHashes'][key],'after':sha((out/n).read_bytes())}
(out/'source-provenance.json').write_text(json.dumps(patch,indent=2))
s=(old/'build-native.py').read_text().replace("out=root/'diagnostics/startup-20261030/parallel-audio/native-callback-wait-01'","out=root/'diagnostics/startup-20261030/parallel-audio/native-async-input-integration-01'")
s=s.replace("out.parent/'native-codec-callback-01/native-build-01.json'","out.parent/'native-callback-wait-01/native-build-01.json'")
s=s.replace('libmpv-callback-wait-x86_64.so','libmpv-async-input-x86_64.so')
s=s.replace("[b'emptyPolls',", "[b'asyncInputRequested',b'pendingSubmissions',b'PiliCodecInput',b'emptyPolls',")
compile(s,'build-native.py','exec');(out/'build-native.py').write_text(s)
s=(old/'repack-candidate.py').read_text().replace("old=base/'codec-callback-candidate.apk';target=base/'callback-wait-candidate.apk'","old=base/'startup-audio-decode-bound-fixed-candidate.apk';target=base/'async-input-candidate.apk'")
s=s.replace('libmpv-callback-wait-x86_64.so','libmpv-async-input-x86_64.so')
s=s.replace(",'callback-wait.patch'",'')
s=s.replace("'native-callback-wait/'","'native-async-input/'").replace("'nativeSourceHashes':native['sourceHashes']","'nativeSourceHashes':native['effectiveSourceHashes']")
s=s.replace('Callback first-output dual-EAGAIN path waits for input/output notification instead of spinning. Same native binary callback_wait switch defaultoff; callbacks1/decode-only0 botharms.10-outputPTSconfidence/quality/audio preserved; bounded empty-poll and wait counters.','Reviewed asynchronous input worker behind debug.piliplus.async_input defaultoff. Same APK/native toggle, callbacks1/wait0/decode0 and bounded startup audio queue in both arms; no changes to PTS/confidence/audio clipping. Native closed snapshot reports all pending submissions and both worker states.')
compile(s,'repack-candidate.py','exec');(out/'repack-candidate.py').write_text(s)
print('Native build and unchanged-Dart APK replacement prepared.')
