from pathlib import Path
BASE=Path(__file__).resolve().parent
s=(BASE/'run-r69-audio-bound-early-cancel.py').read_text().replace('r69-audio-bound-cancel-02','r69-audio-bound-callback-cancel-01').replace('r69-audio-bound-candidate.apk','r69-audio-bound-callback.apk')
anchor="try:\n apk=HERE/"
s=s.replace(anchor,"cbprop='debug.piliplus.codec_callbacks'\ncb_original=subprocess.check_output(ADB+['shell','getprop',cbprop],timeout=10).decode().strip()\nsubprocess.run(ADB+['shell','setprop',cbprop,'1'],check=True,capture_output=True,timeout=10)\ntry:\n apk=HERE/",1)
s=s.replace('finally:\n r=subprocess.run',"finally:\n subprocess.run(ADB+['shell','setprop',cbprop,cb_original or \"''\"],check=True,capture_output=True,timeout=10)\n r=subprocess.run",1)
name='run-r69-audio-bound-callback-cancel.py';compile(s,name,'exec');(BASE/name).write_text(s)
s=(BASE/'review-r69-audio-bound-early-cancel.py').read_text().replace('r69-audio-bound-cancel-02','r69-audio-bound-callback-cancel-01')
s+='''
callbacks=[]
for line in(c/'logcat.txt').read_text(errors='replace').splitlines():
 if '[CODEC_CALLBACK] ' in line and line.split()[1]==str(m['pid']):callbacks.append(json.loads(line.split('[CODEC_CALLBACK] ',1)[1]))
closed=[e for e in callbacks if e['event']=='close']
assert len(closed)==1 and all(closed[0][k]==0 for k in ['threadAlive','pendingInput','pendingOutput','error']) and closed[0]['closed']==1
report['callbackClose']=closed[0]
(p/'queue-restoration-reviewed.json').write_text(json.dumps(report,indent=2))
'''
name='review-r69-audio-bound-callback-cancel.py';compile(s,name,'exec');(BASE/name).write_text(s)
s=(BASE/'run-r69-audio-bound-seek.py').read_text().replace('r69-audio-bound-seek-01','r69-audio-bound-callback-seek-01').replace('r69-audio-bound-candidate.apk','r69-audio-bound-callback.apk')
s=s.replace("props=['debug.piliplus.decode_only']","props=['debug.piliplus.decode_only','debug.piliplus.codec_callbacks']")
name='run-r69-audio-bound-callback-seek.py';compile(s,name,'exec');(BASE/name).write_text(s)
s=(BASE/'review-r69-audio-bound-seek.py').read_text().replace('r69-audio-bound-seek-01','r69-audio-bound-callback-seek-01')
s+='''
cb=[]
for line in(p/'logcat.txt').read_text(errors='replace').splitlines():
 if '[CODEC_CALLBACK] ' in line and line.split()[1]==str(m['pid']):cb.append(json.loads(line.split('[CODEC_CALLBACK] ',1)[1]))
cl=[e for e in cb if e['event']=='close']
assert len(cl)==1 and cl[0]['closed']==1 and cl[0]['flushes']==3 and all(cl[0][k]==0 for k in ['threadAlive','pendingInput','pendingOutput','error'])
report['callbackClose']=cl[0]
assert all(e['data'].get('continuityObserved')for e in after)
report['postSeekMaxPositiveGapMs']=max(e['data']['positiveTimestampGapNs']for e in after[1:])/1e6
assert report['postSeekMaxPositiveGapMs']<500
(out/'seek-reviewed.json').write_text(json.dumps(report,indent=2))
'''
name='review-r69-audio-bound-callback-seek.py';compile(s,name,'exec');(BASE/name).write_text(s)
print('91 callback/decode1/audioBound regressions prepared; run only after comparison decision.')
