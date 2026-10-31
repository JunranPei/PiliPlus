from pathlib import Path
import hashlib,json,statistics
b=Path(__file__).resolve().parent;o=b/'async-input-observed-01'
raw=o/'completed-samples.json';allrows=json.loads(raw.read_text());rows=[r for r in allrows if not r['warmup']]
assert len(rows)==4 and len({r['pid']for r in rows})==4
meta=json.loads((b/'async-input-candidate.build.json').read_text())
keys=['textureMs','coverMs','openMs','firstReceiveMs','receiveToDrainMs','drainToTextureMs']
for r in rows:
 d=next(e for e in r['filteredAudioLeadEvents']if e['event']=='drain.begin')
 r['receiveToDrainMs']=d['afterInputMs']-r['firstReceiveMs'];r['drainToTextureMs']=r['textureMs']-d['afterInputMs']
 assert all(r[k]for k in ['strictStable','functionalCleanup','cacheMechanismVerified','nativeSelectedPtsVerified','callbackMechanismVerified','waitMechanismVerified','asyncInputMechanismVerified','audioDecodeQueueMechanismVerified']),r['label']
 assert not r['workerFaults']
med={v:{k:statistics.median(r[k]for r in rows if r['variant']==v)for k in keys}for v in ['control','candidate']}
gains={k:med['control'][k]-med['candidate'][k]for k in keys}
report={'round':87,'sourceSha256':hashlib.sha256(raw.read_bytes()).hexdigest(),'apkSha256':meta['sha256'],'nativeSha256':meta['nativeLibraryOverride']['librarySha256'],
 'medians':med,'netGainsMs':gains,'netGainPercent':100*gains['textureMs']/med['control']['textureMs'],
 'adjacentPairGainsMs':[rows[1]['textureMs']-rows[0]['textureMs'],rows[2]['textureMs']-rows[3]['textureMs']],
 'exactConsumedPtsCount':sum(r['exactFirstPts']for r in rows),'nativeSelectedPtsCount':sum(r['nativeSelectedPtsVerified']for r in rows),
 'returnPassedCount':sum(r['functionalCleanup']for r in rows),'continuousConcerns':[r['label']for r in rows if r['continuousPlaybackConcern']],
 'scope':'Same Android lifetime, same APK/native87 and bounded audio decode queue. callbacks1/wait0/decode0/videoqueue1, old body failover enabled, progress race off. Only debug.piliplus.async_input0/1 differs. BAAB fresh processes61.5s with separate excluded0sseed;25s/back18. Texture consumption is not physical presentation.',
 'attributionLimit':'N2 per arm. Network and scheduler variation remain; compare firstReceive and receive-to-drain. Do not add local83 or prior86 differences to measured87.',
 'mechanismVerified':True,
 'samples':[{**{k:r[k]for k in ['label','pid','textureMs','coverMs','firstReceiveMs','receiveToDrainMs','drainToTextureMs','firstTexturePtsNs','maxPositiveGapMs','functionalCleanup','exactFirstPts','asyncInputMechanismVerified','audioDecodeQueueMechanismVerified']},'close':next(e for e in r['callbackEvents']if e['event']=='close')}for r in rows]}
(o/'net-gains-reviewed.json').write_text(json.dumps(report,indent=2))
text=['# 第87轮：实际播放器异步视频送包','',report['scope'],'',
 '|样本|首纹理ms|封面ms|首次receive ms|receive→drain ms|首消费PTS秒|连续帧最大间隔ms|输入提交/完成/取消|',
 '|---|---:|---:|---:|---:|---:|---:|---|']
for r in report['samples']:
 c=r['close'];text.append(f"|{r['label']}|{r['textureMs']:.4f}|{r['coverMs']:.4f}|{r['firstReceiveMs']:.4f}|{r['receiveToDrainMs']:.4f}|{r['firstTexturePtsNs']/1e9:.9f}|{r['maxPositiveGapMs']:.4f}|{c['inputPosted']}/{c['inputCompleted']}/{c['inputCancelled']}|")
text+=['',f"控制中位数{med['control']['textureMs']:.4f}ms，候选{med['candidate']['textureMs']:.4f}ms；净收益{gains['textureMs']:+.4f}ms（{report['netGainPercent']:+.2f}%）。封面净收益{gains['coverMs']:+.4f}ms。",'',report['attributionLimit'],'',f"首次receive净差{gains['firstReceiveMs']:+.4f}ms，receive→drain净差{gains['receiveToDrainMs']:+.4f}ms。相邻两对{report['adjacentPairGainsMs']}ms。",'',f"精确首消费61.5秒{report['exactConsumedPtsCount']}/4，原生目标61.5秒{report['nativeSelectedPtsCount']}/4；返回{report['returnPassedCount']}/4；超过500ms连续帧间隔：{report['continuousConcerns']}。"]
(b/'round87-async-input.md').write_text('\n'.join(text)+'\n',encoding='utf-8')
print(json.dumps({k:report[k]for k in ['medians','netGainsMs','adjacentPairGainsMs','exactConsumedPtsCount','returnPassedCount','continuousConcerns']},indent=2))
