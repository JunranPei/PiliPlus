from pathlib import Path
import hashlib
import json
import statistics

BASE=Path(__file__).resolve().parent
OUT=BASE/'r69-audio-bound-observed-01'
raw=OUT/'completed-samples.json'
rows=json.loads(raw.read_text())
assert len(rows)==8 and len({r['pid']for r in rows})==8
assert all(sum(r['variant']==v for r in rows)==4 for v in ['candidate','control'])
meta={v:json.loads((BASE/f'r69-audio-bound-{v}.build.json').read_text())for v in ['control','candidate']}
metrics=['textureMs','coverMs','openMs','firstReceiveMs','receiveToDrainMs','drainToTextureMs']
for r in rows:
    drain=next(e for e in r['filteredAudioLeadEvents']if e['event']=='drain.begin')
    r['receiveToDrainMs']=drain['afterInputMs']-r['firstReceiveMs']
    r['drainToTextureMs']=r['textureMs']-drain['afterInputMs']
med={v:{key:statistics.median(r[key]for r in rows if r['variant']==v)for key in metrics}for v in ['control','candidate']}
gain={key:med['control'][key]-med['candidate'][key]for key in metrics}
pair_gains=[]
for a,b in zip(rows[::2],rows[1::2]):
    pair={r['variant']:r for r in [a,b]}
    pair_gains.append(pair['control']['textureMs']-pair['candidate']['textureMs'])
mechanisms=['audioDecodeQueueMechanismVerified','decodeOnlyMechanismVerified','cacheMechanismVerified',
    'reservationMechanismVerified','unusedFlushMechanismVerified','filteredAudioLeadMechanismVerified','nativeSelectedPtsVerified']
report={'round':90,'sourceSha256':hashlib.sha256(raw.read_bytes()).hexdigest(),
    'baseline':'Round69 native/source plus only86 temporary audio decode queue bound; decode_only1 in both; no later video queue/callback/body recovery',
    'apkSha256':{v:m['sha256']for v,m in meta.items()},'medians':med,'netGainsMs':gain,
    'netGainPercent':100*gain['textureMs']/med['control']['textureMs'], 'adjacentPairGainsMs':pair_gains,
    'mechanismVerified':all(r[k]for r in rows for k in mechanisms),
    'exactConsumedPtsCount':sum(r['exactFirstPts']for r in rows),
    'nativeSelectedPtsCount':sum(r['nativeSelectedPtsVerified']for r in rows),
    'returnPassedCount':sum(r['functionalCleanup']for r in rows),
    'continuousConcerns':[r['label']for r in rows if r['continuousPlaybackConcern']],
    'workerFaults':[{'label':r['label'],'events':r['workerFaults']}for r in rows if r['workerFaults']],
    'attributionLimit':'Four samples per arm; same Android lifetime, fresh process61.5s BAABABBA. Source/network/scheduling variation remains. Do not sum historical gains. Texture consumed is not physical display.',
    'samples':[{k:r[k]for k in ['label','variant','pid',*metrics,'firstTexturePtsNs','maxPositiveGapMs',
        'functionalCleanup','strictStable','audioDecodeQueueEvents',*mechanisms]}for r in rows]}
(OUT/'net-gains-reviewed.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
text=['# 第90轮：第69轮基线上只加入音频解码限量','',report['baseline'],'',
    '|样本|首纹理ms|封面ms|首次receive ms|receive→drain ms|首消费PTS秒|最大连续帧间隔ms|返回|',
    '|---|---:|---:|---:|---:|---:|---:|---|']
for r in rows:
    text.append(f"|{r['label']}|{r['textureMs']:.4f}|{r['coverMs']:.4f}|{r['firstReceiveMs']:.4f}|{r['receiveToDrainMs']:.4f}|{r['firstTexturePtsNs']/1e9:.9f}|{r['maxPositiveGapMs']:.4f}|{r['functionalCleanup']}|")
text+=['',f"控制中位数{med['control']['textureMs']:.4f}ms，候选{med['candidate']['textureMs']:.4f}ms；净收益{gain['textureMs']:+.4f}ms（{report['netGainPercent']:+.2f}%）。",'',
    f"封面净收益{gain['coverMs']:+.4f}ms；首次receive净差{gain['firstReceiveMs']:+.4f}ms；receive到drain净差{gain['receiveToDrainMs']:+.4f}ms。相邻四对{pair_gains}ms。",'',
    f"首消费精确61.5秒{report['exactConsumedPtsCount']}/8；原生起点{report['nativeSelectedPtsCount']}/8；返回{report['returnPassedCount']}/8；连续播放问题{report['continuousConcerns']}。",'',report['attributionLimit']]
(BASE/'round90-r69-audio-bound.md').write_text('\n'.join(text)+'\n',encoding='utf-8')
print(json.dumps({k:report[k]for k in ['medians','netGainsMs','adjacentPairGainsMs','mechanismVerified','exactConsumedPtsCount','returnPassedCount','continuousConcerns']},indent=2))
