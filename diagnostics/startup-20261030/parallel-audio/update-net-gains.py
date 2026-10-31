"""Recompute matched-cohort observations without changing historical samples."""
from pathlib import Path
import hashlib, json, statistics

BASE = Path(__file__).resolve().parent
SPECS = [
 (66, '修正普通音频被误判直通，提前处理音频', 'filtered-audio-format-observed-01', '同原生版本，关闭/开启 filtered-audio-lead', '保留正确性修复；总收益待复核', '音频尾段缩短，但样本少且首消费位置不全通过'),
 (68, '音频预处理每轮最多4帧', 'audio-lead-fair-observed-01', '66/67无限量预处理 / 有界4帧', '保留公平调度和取消修复；不记为起播加速', '取消时实际清理88个待处理帧；本轮整体更慢'),
 (69, '参考帧只解码、不输出', 'decode-only-observed-02', '同69库 decode_only=0 / 1', '保留实验；最快历史样本配置用于用户指定打包', '首次receive已提前137ms；不能把总差102ms全归本改动'),
 (70, '解码缓冲区可用时回调通知', 'codec-callback-observed-02', '同70库 callbacks=0 / 1，decode_only两组关闭', '保留有希望的实验，待共同基线复核', '首次receive提前142ms，receive到目标帧缩短186ms；网络/调度仍混杂'),
 (71, '回调之上叠加只解码标志', 'codec-callback-stack-observed-01', '70回调开启；decode_only=0 / 1', '不采用此叠加为提速组合，保留两项实现', '整体变慢；不能直接与69差值相加'),
 (72, '初始空队列最多等待8ms通知', 'callback-wait-observed-01', '72库回调开启；callback_wait=0 / 1', '起播加速配置关闭；保留省CPU实验', '独立解码测试CPU减少约32ms，应用整体反而更慢；CDN不同，非纯等待成本'),
 (74, '视频解码移入单帧队列', 'video-thread-observed-01', '同72库及等待配置；视频队列关 / 开', '起播加速配置关闭；保留局部重叠机制', '诊断中83ms音频初始化与视频送包重叠；整轮起播仍慢166ms'),
 (76, '初始请求等待小段正文后选源', 'initial-body-hedge-observed-01', '同74队列+75初始64KiB；HEDGE_INITIAL_BODY关 / 开', '保留防慢正文机制，默认关闭；无正常起播收益', '本地故障场景修复有效；实际正常组更慢14ms'),
 (77, '续播目标请求等256KiB正文后选源', 'resume-body-alignment-observed-01', '两组均含音频初始化顺序修复；HEDGE_RESUME_BODY关 / 开', '关闭256KiB等待，保留音频初始化修复', '候选开始交付前增加等待；整轮净差342ms不能全等同纯等待指令成本'),
 (80, '关闭中间等待后重新加入视频单帧队列', 'video-thread-no-wait-observed-01', '同72库，callbacks1/wait0/decode0；视频队列关 / 开', '保留候选继续复核；尚不改变默认/手机包', '相邻两对方向均为加快；首两条普遍>4s，后两条约2s，同期另有实际构建，不能宣称稳定因果收益'),
 (81, '正文停顿后验证重叠字节再续接', 'resume-body-failover-observed-01', '同72库、callbacks1/wait0/decode0/videoqueue1及同源码；RESUME_BODY_FAILOVER关 / 开；所有前置正文等待关闭', '保留默认关闭实验；已通过实际取消/拖动/返回，切换收益仍待实际触发', '候选1674/1709ms、对照1833/2051ms；无起播前重试或切换，正常组差251ms不能归因于续接；其中119ms已出现在首次receive之前'),
 (85, '慢速连续正文触发备用连接追赶', 'resume-body-progress-observed-02', '同72库及85全部源码；FAILOVER两组开启，仅PROGRESS_RACE关 / 开；QA145排除种子后BAAB，不混入中断的QA144', '保留默认关闭实验和59项控制测试；正常路径收益未确立', '候选1612/1661ms、对照1816/1843ms；中位差+193ms，但无慢速进度重试或实际切换，不能归因于追赶。实际取消/拖动/返回通过，拖动恢复1597ms仍慢。旧队列3条有效和第4条模拟器崩溃失败全部保留'),
 (86, '起播音频解码队列临时缩至0.08秒，首帧后恢复', 'startup-audio-decode-bound-observed-01', '同72库及86修正后全部源码；callbacks1/wait0/decode0/videoqueue1，FAILOVER开启/PROGRESS关闭；仅STARTUP_AUDIO_DECODE_QUEUE_BOUNDED关 / 开，QA145完整BAAB', '保留候选继续叠加和复核；暂不改默认或手机包', '原生跟踪确认首视频帧前音频189→99帧，过滤FIFO仍93帧；实际首帧/取消均恢复2秒。本轮中位快166ms，其中receive到drain快176ms，首次receive中位仅差2.7ms；每组仅2条且相邻对方向不同，稳定性仍待验证。精确首消费位置2/4，偏后样本保留'),
 (87, '在86音频限量上叠加异步视频送包', 'async-input-observed-01', '同一native87及同一APK；callbacks1/wait0/decode0/videoqueue1与音频0.08秒限量均相同，仅debug.piliplus.async_input0 / 1；新Android运行周期种子排除后完整BAAB', '保留默认关闭候选继续查剩余等待；未改手机包', '候选1668.9571/1664.3367ms，对照1847.8953/1602.663ms；中位快58.6323ms，首次receive反而晚40.8111ms，receive到drain快66.6839ms。相邻对+178.9382/-61.6737ms，N2每组，稳定归因未确立。实际首帧前取消、拖动后持续15秒、全部返回与双线程回收通过；精确首消费2/4'),
 (89, '异步送包与音频限量之上启用回调等待', 'async-wait-stacked-observed-01', '同87轻监听APK/native，callbacks1/async1/decode0/videoqueue1/audioBound1，FAILOVER开启/PROGRESS关闭；仅callback_wait0 / 1，5572同一Android运行周期完整BAAB', '关闭此等待叠加；保留实现及全部负收益样本', '控制1756.7305/1662.0060ms，候选1908.6403/3353.7166ms；中位净收益-921.8102ms，两对均变慢。第二候选连续帧最大间隔1066.9763ms，精确首消费1/4，返回4/4。慢样本视频正文2.612秒仅收到342236字节，而全段回调等待合计109.1343ms，不能把全部减慢归因于等待；网络交付也是明确混杂因素'),
 (90, '第69轮基线上仅叠加音频解码队列临时限量', 'r69-audio-bound-observed-01', '精确69原生/应用源码加86限量及恢复；两包源码相同，decode_only1，仅STARTUP_AUDIO_DECODE_QUEUE_BOUNDED关 / 开；5572同一Android运行周期8条BAABABBA', '保留此叠加，继续在该组合上验证下一项；手机包未改', '每组4条：控制中位1812.4413ms，候选1622.3782ms，净快190.0631ms（10.4866%），四对均快103.077/212.0693/440.0227/161.665ms；首次receive仅提前8.8083ms，receive到drain提前187.8739ms。候选最低1470.3236ms；原生起点8/8，精确首消费6/8，连续播放与返回8/8。实际首帧前取消及原值恢复通过；小样本与网络调度影响仍保留，不能承诺手机同速或0.8秒达成'),
 (91, '第69轮与音频限量之上叠加回调通知', 'r69-audio-bound-callback-observed-01', '第90轮应用源码/音频限量保持一致；改用从69原生构建的70回调库，同一APK/native，decode_only1与音频限量均开，仅callbacks0 / 1；8条BAABABBA', '保留为可叠加候选；两对快两对慢，最终采用仍待组合对照', '控制中位1602.0736ms，候选1567.36205ms，净快34.71155ms，封面只快4.2783ms。候选最低1314.2205ms，另有2466.2538ms慢样本完整计入；相邻对+39.6057/+267.0026/-817.8638/-14.1377ms。首次receive中位晚108.763ms，receive到drain快89.7613ms，不将不同阶段中位数直接相加。原生起点/连续播放/返回8/8，精确首消费7/8；实际首帧前取消、恢复和拖动后15秒播放通过'),
]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

rows = []
for num, title, cohort, baseline, decision, caveat in SPECS:
    path = BASE/cohort/'completed-samples.json'
    raw = json.loads(path.read_text(encoding='utf-8-sig'))
    samples = [r for r in raw if not r.get('warmup') and not r['label'].startswith('00-')]
    assert len(samples) >= 4 and len(samples) % 2 == 0 and len({r['pid'] for r in samples}) == len(samples)
    groups = {v: [r for r in samples if r['variant'] == v] for v in ['control', 'candidate']}
    assert all(len(g) == len(samples)//2 for g in groups.values())
    stats = {}
    for metric in ['textureMs', 'coverMs', 'openMs', 'firstReceiveMs']:
        if not all(metric in r for r in samples): continue
        a, b = [statistics.median(r[metric] for r in groups[v]) for v in ['control', 'candidate']]
        stats[metric] = {'controlMedianMs': a, 'candidateMedianMs': b, 'netGainMs': a-b, 'netGainPercent': 100*(a-b)/a}
    rows.append({'round': num, 'change': title, 'baseline': baseline, 'cohort': cohort,
        'source': str(path.relative_to(BASE)), 'sourceSha256': digest(path),
        'sampleCount': len(samples), 'samplesPerVariant': len(samples)//2,
        'stats': stats, 'decision': decision, 'attributionLimit': caveat,
        'stableAttributableGainEstablished': False,
        'samples': [{k:r.get(k) for k in ['label','variant','pid','textureMs','coverMs','openMs','firstReceiveMs','firstTexturePtsNs','strictStable','functionalCleanup','exactFirstPts','nativeSelectedPtsVerified']} for r in samples]})

pending = [
 {'round':'88','change':'分解异步送包后解码线程内部各调用耗时','netGainMs':None,'reason':'实际PID2840独占提交段810.232ms：输出获取515.556ms含睡眠219.325ms，输入槽查询151.525ms但无睡眠，buffer获取11.818ms、复制0.937ms、提交9.927ms。首个未呈现参考帧释放前756次零超时查询、9次输入。20MB跟踪无丢失，5935.557ms诊断耗时不混入轻监听。首次采集在点击前被另一测试切换到WeiDownloader，原XML保留，已把本QA从5554隔离至5572，随后实际播放/返回通过'},
 {'round':'65','change':'提前处理音频的初版','netGainMs':None,'reason':'实际被错误的直通判断拦住，未触发；第66轮修正，不能记作有效优化'},
 {'round':'67','change':'补原生音视频起点监听','netGainMs':None,'reason':'诊断变化，无匹配性能对照'},
 {'round':'73','change':'补worker异常和原生阶段监听','netGainMs':None,'reason':'诊断变化，无匹配性能对照'},
 {'round':'75','change':'初始请求限制为新鲜64KiB','netGainMs':None,'reason':'没有完成同条件A/B；10.398秒样本包含起播前拖动，不作正常起播成绩'},
 {'round':'77b','change':'音频备选地址在第一次await之前赋值','netGainMs':None,'reason':'失败/修复后43项测试证实修复；77正式A/B两组均包含，无法分离其独立速度收益'},
 {'round':'79','change':'提前使用只解码标志，保留全部输入','netGainMs':None,'reason':'独立480p解码夹具机制通过、旧/新中位648.51/626.63ms；局部观察+21.89ms，未改应用/未测应用净收益'},
 {'round':'82','change':'当前组合增加原生调用与线程调度监听','netGainMs':None,'reason':'纯诊断，实际样本2453ms不加入轻监听比较；同步输入调用570ms含425ms睡眠，调用外另529ms睡眠；下一步研究异步提交，不等同已取得提速'},
 {'round':'83','change':'同回调解码器改为独立线程提交输入','netGainMs':None,'reason':'真实Android解码器局部BAAB：控制297.5911/300.2483ms，候选262.7421/315.7528ms，中位净差+9.67225ms（+3.24%）；122个输出PTS、EOS、拖动、待提交输入取消及异步错误传回验证通过。整个片段调用占用减少409.94ms不能冒充起播收益；首次输出前CPU增加28.07ms。原生应用未修改，保留独立原型'},
 {'round':'84','change':'83原型初始双空队列等待1ms通知','netGainMs':None,'reason':'真实Android解码器局部BAAB：控制246.6732/254.4782ms，候选261.2370/250.0778ms，中位净差-5.0817ms（-2.03%）；PTS/EOS和关闭一致，首次输出前CPU减少41.66ms，但目标帧更慢。保留省CPU原型，未合入应用'},
 {'round':'86b','change':'返回取消时先恢复音频解码队列，再递增源代次','netGainMs':None,'reason':'初版实际取消PID6563误报ownerChanged而跳过恢复；调整cancelSource顺序后PID7671实际在同代次恢复0.08→2，零输出/无drain、返回及线程回收通过。36项测试通过；第86轮正式两组均含此正确性修复，没有独立速度对照，旧失败记录保留'},
]
report = {'metric':'实际输入事件到首个正PTS纹理消费完成；封面消失单列，均非物理显示完成证明',
 'protocol':'各轮同一Android运行周期，每条新应用进程第一次61.5秒续播；主表包含4条BAAB和8条BAABABBA，数量与顺序见各轮基线，排除种子，保留全部正式慢样本。仅轮内比较，不跨轮相加。',
 'signConvention':'净收益=控制中位数-候选中位数；正值加快，负值变慢；无对照为null。',
 'scope':'回填第66轮起现有完整同条件队列；重点覆盖最快第69轮之后；更早轮次仍保留原实验记录，尚未迁入本表。',
 'rows':rows, 'unmeasured':pending}
factorial_path=BASE/'common-baseline-observed-01/net-gains-reviewed.json'
factorial=json.loads(factorial_path.read_text(encoding='utf-8')) if factorial_path.exists() else None
if factorial:report['sameBaselineFactorial']=factorial
(BASE/'net-gains.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
lines = ['# 每轮修改净收益', '', report['metric']+'。', '', report['protocol'], '', report['signConvention'], '',
 '这些是小样本的实际组间差，不等于已证明稳定、可归因的提速。首次消费位置偏后仍单列失败，不删除其耗时。', '',
 '|轮次|改动|控制→候选中位数（秒）|净收益（毫秒 / %）|封面净收益（毫秒）|首消费恰为61.5秒 / 全部|决定|',
 '|---|---|---:|---:|---:|---:|---|']
for r in rows:
    s=r['stats']['textureMs']; c=r['stats']['coverMs']
    exact=sum(x['firstTexturePtsNs']==61500000000 for x in r['samples'])
    lines.append(f"|{r['round']}|{r['change']}|{s['controlMedianMs']/1000:.3f} → {s['candidateMedianMs']/1000:.3f}|{s['netGainMs']:+.1f} / {s['netGainPercent']:+.1f}%|{c['netGainMs']:+.1f}|{exact}/{r['sampleCount']}|{r['decision']}|")
if factorial:
    lines += ['', '## 第78轮：同一安装包的四组合对照', '', factorial['protocol'], '',
      '|改动|控制→候选中位数（秒）|净收益（毫秒 / %）|封面净收益（毫秒）|',
      '|---|---:|---:|---:|']
    for r in factorial['comparisons']:
        lines.append(f"|{r['change']}|{r['controlMedianMs']/1000:.3f} → {r['candidateMedianMs']/1000:.3f}|{r['netGainMs']:+.1f} / {r['netGainPercent']:+.1f}%|{r['coverNetGainMs']:+.1f}|")
    lines += ['', factorial['lateCleanupNote'], '', '选择：回调单项是当前待叠加基线；不把这组观察差当作稳定因果收益，保留历史最快版本与全部样本。', '',
      '[完整第78轮报告](round78-common-baseline-net-gains.md)；[逐条证据](common-baseline-observed-01/net-gains-reviewed.json)。']
lines += ['', '## 无法独立计量的修改', '']
for p in pending: lines.append(f"- 第{p['round']}轮，{p['change']}：**净收益未确定**。{p['reason']}。")
lines += ['', '## 各轮基线、原始样本和归因限制', '']
for r in rows:
    lines += [f"### 第{r['round']}轮", '', f"基线：{r['baseline']}。{r['attributionLimit']}。", '', f"[原始数据]({r['source']})；SHA256 `{r['sourceSha256']}`。", '',
      '|样本|进程|纹理毫秒|封面毫秒|首消费PTS秒|连续播放/返回|', '|---|---:|---:|---:|---:|---|']
    for x in r['samples']:
        lines.append(f"|{x['label']}|{x['pid']}|{x['textureMs']:.4f}|{x['coverMs']:.4f}|{x['firstTexturePtsNs']/1e9:.9f}|{x['strictStable']}/{x['functionalCleanup']}|")
    lines.append('')
lines += ['## 后续登记规则', '', '每轮先写控制版本、唯一变化与待测值，再补全所有正式样本。整体净收益、局部阶段变化和功能结果分开记录。负收益项关闭其加速配置；正确性修复保留；不确定项隔离复核。不能把各轮差值相加推算一个未测版本。', '', report['scope'], '']
(BASE/'net-gains.md').write_text('\n'.join(lines),encoding='utf-8')
print(json.dumps([{'round':r['round'],**r['stats']['textureMs']} for r in rows],ensure_ascii=False,indent=2))
