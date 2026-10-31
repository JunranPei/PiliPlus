from pathlib import Path
import json
import subprocess
import sys
BASE=Path(__file__).resolve().parent
OUT=BASE/'r69-audio-bound-callback-observed-01'
result=json.loads((OUT/'net-gains-reviewed.json').read_text())
cancel=json.loads((BASE/'r69-audio-bound-callback-cancel-01/queue-restoration-reviewed.json').read_text())
seek=json.loads((BASE/'r69-audio-bound-callback-seek-01/seek-reviewed.json').read_text())
assert result['mechanismVerified'] and result['returnPassedCount']==8 and not result['continuousConcerns']
assert cancel['passed'] and cancel['callbackClose']['closed']==1
assert seek['passed'] and seek['returnCleanup']['passed'] and seek['callbackClose']['closed']==1
report={'round':91,'netGainMs':result['netGainsMs']['textureMs'],'candidateMedianMs':result['medians']['candidate']['textureMs'],
    'minimumCandidateMs':min(r['textureMs']for r in result['samples']if r['variant']=='candidate'),
    'mechanismVerified':True,'continuousAndReturnCount':8,'exactConsumedPtsCount':7,
    'nativeTargetCount':8,'actualPreFrameCancel':cancel,'actualSeek':seek,
    'decision':'Keep optional callback candidate for stacking; N4 each and two opposite-direction pairs do not establish stable gain. Next video queue comparison; final common69-vs-combination remains required.',
    'goalComplete':False,'stableCausalGainEstablished':False}
(OUT/'device-reviewed.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
with(BASE/'round91-r69-audio-bound-callback.md').open('a',encoding='utf-8')as f:
    f.write(f'\n取消PID14040：首帧前返回，无正PTS/无drain，68个音频帧被清理，音频队列同代次0.08→2，回调线程与缓冲区全部回收。拖动PID14445：实际正PTS后手势，新位置恢复743.0078ms，90.633313→105.866688秒，稳态正PTS变化最大间隔{seek["postSeekMaxPositiveGapMs"]:.4f}ms，三次flush及回收通过。\n\n慢样本06在1154.424ms才首次receive；1750.7924ms前已交付653532字节，2466.2538ms才首纹理。现有轻监听不能把全部减慢归给网络或回调。\n\n决定：保留回调作为可叠加候选，收益不稳定，最终采用仍需组合整体对照。继续下一项视频解码队列；不相加90与91差值。\n')
with(BASE/'experiment-ledger.md').open('a',encoding='utf-8')as f:
    f.write('\nRound91 same90Dart+native70 (exact69ancestor), onlycallback0/1; no native/Dartcompile, onlylibmpvrepack707entriesverified. Same5572 BAABABBA8freshprocess61.5s: B1583.3184/1314.2205/2466.2538/1551.4057 vsA1622.9241/1581.2231/1648.39/1537.268ms. MedB1567.36205 vsA1602.0736,net+34.71155ms,cover+4.2783; pairs+39.6057/+267.0026/-817.8638/-14.1377ms. FirstReceive candidate109mslater while receive-drain90msfaster; mediansnotadditive. Allmechanisms/native61.5/continuity/return8of8, exactconsumed7of8. Actualpreframecancel14040 queue.08→2,68framescleared,decoder/callbackworkerclosed. Actualseek14445 recovered743.0078ms then15.233375s media progress,callbackflush3/closepassed. Keepoptionalcandidate, stablecausalgainnotproven; nextvideoqueue, finalcommon69vsstackrequired.\n')
r=subprocess.run([sys.executable,str(BASE/'update-net-gains.py')],capture_output=True,text=True);r.check_returncode()
p=BASE/'active-continuation.json';state=json.loads(p.read_text())
state.update(previousTurn='Progress:90 positive190ms/4positivepairs withcancel/seek;91 positive34.7msbut2mixedpairs, actualcancel/seekpassed. Newbest1314.2205ms, notstableclaim.',
    captureHandle=None,currentCapture=None,lastCompletedCohort=OUT.name,lastTextureMs=1314.2205,
    latestNetGainMs=report['netGainMs'],latestCausalGainEstablished=False,
    cancelRegression='r69-audio-bound-callback-cancel-01/queue-restoration-reviewed.json',
    seekRegression='r69-audio-bound-callback-seek-01/seek-reviewed.json',
    next='92: add existing video decoder queue only to91candidate69+86+callbacks. Samecurrentcontroller already contains queue; stage69legacy transport files from91source archive for Dart-only matching builds, keep native70/decode1/callback1/audioBound1. Run8BAABABBA andregressions. Still finalpure69vscombined required;0.8unachieved.')
p.write_text(json.dumps(state,ensure_ascii=False,indent=2))
print(json.dumps({'round91Recorded':True,'netGainMs':report['netGainMs'],'minimumMs':report['minimumCandidateMs'],
    'cancelPassed':True,'seekPassed':True,'seekSteadyGapMs':seek['postSeekMaxPositiveGapMs']}))
