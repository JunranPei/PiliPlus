from pathlib import Path
import json
BASE=Path(__file__).resolve().parent
OUT=BASE/'r69-audio-bound-observed-01'
result=json.loads((OUT/'net-gains-reviewed.json').read_text())
cancel=json.loads((BASE/'r69-audio-bound-cancel-02/queue-restoration-reviewed.json').read_text())
seek_path=BASE/'r69-audio-bound-seek-01/seek-reviewed.json'
seek=json.loads(seek_path.read_text())
assert result['mechanismVerified'] and result['returnPassedCount']==8 and not result['continuousConcerns']
assert cancel['passed'] and seek['passed'] and seek['returnCleanup']['passed']
capture=BASE/'r69-audio-bound-seek-01/capture'
m=json.loads((capture/'capture.json').read_text())
events=[json.loads(l)for n in m['summary']['traceFiles']if n.startswith('native')for l in(capture/'app'/n).read_text().splitlines()]
after=[e for e in events if e['event']=='texture.consumed' and e['data'].get('textureTimestampNs',0)>85000000000]
assert all(e['data'].get('continuityObserved') for e in after)
# Healthy per-frame observations are aggregated before JSON emission. Use the
# per-callback continuity counters, not the spacing between emitted log rows.
gap=max(e['data']['positiveTimestampGapNs'] for e in after[1:])/1e6
assert gap<500, gap
seek['postSeekMaxConsumedGapMs']=gap
seek['firstNewPositionPositiveGapMs']=after[0]['data']['positiveTimestampGapNs']/1e6
seek['postSeekMaxUnchangedTimestampAgeMs']=max(e['data']['unchangedPositiveTimestampAgeNs']for e in after[1:])/1e6
seek_path.write_text(json.dumps(seek,indent=2))
report={'round':90,'netGainMs':result['netGainsMs']['textureMs'],'candidateMedianMs':result['medians']['candidate']['textureMs'],
    'minimumCandidateMs':min(r['textureMs']for r in result['samples']if r['variant']=='candidate'),
    'fourAdjacentPairsFaster':all(v>0 for v in result['adjacentPairGainsMs']),
    'mechanismVerified':True,'continuousAndReturnCount':8,'exactConsumedPtsCount':6,
    'nativeTargetCount':8,'actualPreFrameCancel':cancel,'actualSeek':seek,
    'earlierCancelSample':'r69-audio-bound-cancel-01: command applied after frame; retained as successful postframe return, not preframe cancel proof.',
    'decision':'Retain69+86 combination and next test70 callback notification in it. No phone build. Overall0.8goal remains active.',
    'goalComplete':False,'scope':'Matched8sample observational gain,4 perarm; no universal-device speed or physicalpresentation claim.'}
(OUT/'device-reviewed.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
with(BASE/'round90-r69-audio-bound.md').open('a',encoding='utf-8')as f:
    f.write(f'\n取消PID10190：首次receive后触发返回，无正PTS纹理、无drain，清理64帧；队列在同一源代次恢复0.08→2，资源在离开后556–599ms关闭。初次取消PID9767晚于首帧，原始记录保留，不冒充起播前取消通过。\n\n拖动PID10601：已监听到当前源实际纹理后发出手势，新位置恢复416.6815ms，90.7→106.466688秒，后续消费间隔最大{gap:.4f}ms，返回通过。此项无同批拖动速度对照，不宣称独立拖动净收益。\n\n决定：保留69+86组合，继续叠加下一项。手机包未修改，0.8秒未达成。\n')
with(BASE/'experiment-ledger.md').open('a',encoding='utf-8')as f:
    f.write('\nRound90 after user-requested checkpoint439603734: restored exact69source/native for build and backported only86 audio bound/restoration. 36tests+analyze passed. Dart-only candidate109.550s/control143.761s, same signer/assets/native, onlylibapp changes; workspace restored. Same5572 BAABABBA8freshprocess61.5s: B1666.9582/1577.7982/1470.3236/1673.3501 vsA1770.0352/1789.8675/1910.3463/1835.0151ms. MedB1622.3782 vsA1812.4413,net+190.0631ms(+10.4866%); fourpairsallpositive; firstReceive+8.8083ms, receive-to-drain+187.87385ms. All8mechanism/native61.5/continuity/return; exact consumed6/8. Candidate minimum1470.3236ms. Retaincombination, no crosscohortsum. Actualearlycancel10190 noframe/nodrain,64framescleared, samegeneration audio.08→2,decoder/requestsclosed. Priorcancel9767 occurredafterframe andwasretainedwithphasefailure. Actualseek10601 recovered416.6815ms, monotonic90.7→106.466688 thenreturn; notcomparativeseekgain. Nextcallbacknotification on69+audioBound; goal0.8unachieved.\n')
print(json.dumps({'round90Recorded':True,'netGainMs':report['netGainMs'],'bestMs':report['minimumCandidateMs'],'cancelPassed':True,'seekPassed':True,'seekMaxGapMs':gap}))
