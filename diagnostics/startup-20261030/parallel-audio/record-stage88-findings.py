from pathlib import Path
import json,psutil
b=Path(__file__).resolve().parent;o=b/'native-codec-stages-01';trace=b/'codec-stages-native-spans-02/capture';analysis=trace/'time-attribution-01'
r=json.loads((analysis/'codec-stages-reviewed.json').read_text());poll=json.loads((analysis/'polling-reviewed.json').read_text());m=json.loads((trace/'capture.json').read_text());cleanup=json.loads((trace/'return-cleanup-reviewed.json').read_text())
assert not m['errors'] and m['summary']['validTextureObservation'] and cleanup['passed']and not r['traceIssues']
text=['# 第88轮：提交阶段的独立调用监听','',
 '诊断版从87原生库增加JNI输入槽获取、buffer取得、复制、输入提交、输出获取五类区间；不改变解码行为。跟踪运行在独立5572设备。',
 '',f"PID{r['pid']}，decoder{r['decoderTid']}，inputworker{r['inputWorkerTid']}。首纹理{m['summary']['firstChangedTextureConsumedAfterInputMs']:.4f}ms仅作重监听诊断，不计速度。系统跟踪无丢失错误，返回回收通过。",'',
 '|avcodec_send内部独占阶段|墙钟ms|运行ms|睡眠ms|', '|---|---:|---:|---:|']
for k,v in r['sendExclusiveStages'].items():text.append(f"|{k}|{v['wallMs']:.4f}|{v['statesMs'].get('Running',0):.4f}|{v['statesMs'].get('S',0):.4f}|")
text+=['',f"首个未呈现参考帧释放前，零超时输出查询387次、输入查询369次（合计756），实际输入只9次；从首次输入提交到该参考帧释放{poll['firstInputToFirstPrerollReleaseMs']:.4f}ms。首输出已经发生后才会release，所以不能把全部756次都称为输出出现之前。",'',
 '结论：缓冲区获取、复制、提交占比小；提交阶段内部主要是FFmpeg同时调用的输出等待。等待包含所需解码服务和调度，不可直接删除或当成可获得的提速。下一步在87轻监听同一APK上测试async1/audioBound1+callback_wait0/1，减少输出出现前双空端口循环，记录整体净收益。此轮没有速度收益。', '',
 '原始第一次采集在点击前被另一项测试将前台切到cn.weibo.filedownloader，失败XML保留，非播放样本。仅将本线程原QA改到5572，未关闭其他测试设备。', '',
 '构建工作卷当前是诊断88（wrapper/common增加区间），已卸载。后续速度库构建应从保存的87行为恢复这两份诊断文件，不能误把88重监听当成87控制。所有旧库保留。']
(b/'round88-codec-stages.md').write_text('\n'.join(text)+'\n',encoding='utf-8')
with(b/'experiment-ledger.md').open('a',encoding='utf-8')as f:f.write('\n\n## 第88轮结果\n\n'+ '\n'.join(text[2:])+'\n\n## 第89轮开始\n\n控制/候选同87轻监听APK，仅callback_wait0/1，async1与86音频限量相同。独立5572运行周期完整BAAB，不与87/88跨批相加。净收益待定。\n')
qa=json.loads((o/'port-isolation/emulator-process.json').read_text());proc=psutil.Process(qa['pid']);assert proc.create_time()==qa['createTime']
state=json.loads((b/'active-continuation.json').read_text());state.update(previousTurn='Progress:88 actual exclusive codecstage trace resolved send waiting asoutputdequeue, notcopy/post;89 waitstack sameAPK collecting',buildHandle=None,buildOutput='async-input-candidate.apk',buildSha256='f61c8fdbe6537a5c68356d3320fae9bcc01aef24dd86441c937d015865e6b06f',emulatorPid=qa['pid'],emulatorCreateTime=qa['createTime'],serial='emulator-5572',emulatorRecord=str(o/'port-isolation/emulator-process.json'),captureHandle=85269,currentCapture='async-wait-stacked-observed-01',lastCompletedCohort='async-input-observed-01',lastCompletedDiagnostic='codec-stages-native-spans-02',lastCapturePid=m['pid'],trace=str(trace/'system.pftrace'),latestNetGainMs=58.63225,latestCausalGainEstablished=False,cancelRegression='async-input-cancel-01/queue-restoration-reviewed.json',seekRegression='async-input-seek-01/seek-reviewed.json',next='Finish89 sameAPK wait0/1 BAAB on5572 and determinedecision. Ifgain then actualcancel/seek withwait1. Nativebuildfilesystem isdiagnostic88, restore87 wrapper/common beforefuturetimingbuild. Keepgoalactive,no0.8proof.',unaccepted='0.8unachieved;87N2arms/oppositepairdirections;exactfirstconsumed2/4. Allrawfailurestimingretained.',nextRunner=str(b/'run-async-wait-stacked.py'))
(b/'active-continuation.json').write_text(json.dumps(state,indent=2))
print('88 complete recorded, isolated5572 live,89 active capture recorded.')
