# 当前接续点（以本文件和最新用户指令覆盖旧目标快照）

用户要求自主继续修改，禁止再提问。目标未达成0.8秒。2026-10-19本轮get_goal已实际核实原目标为active（updatedAt=1792404573）；此前曾核实为blocked，期间说仍在进行的回复不准确。现在继续原目标，不以其他任务卡片替代。当前对话中的授权有效，不应标complete，不要求手机，不触碰其他任务，不扩大已失败方案。

源码候选已提交6317c4ef6，两个APK已成功构建，不能按旧goal文字误认候选未构建。后续证据提交5054506bc/e8983cf12。SOURCE_EARLY_PREPARE默认关闭。当前按最新指令补全profile诊断：Dart CPU与异步timeline、Dio adapter headers/首chunk/结束（仅交付时刻）、平台channel、Perfetto调度/回收和simpleperf原生采样。不是新提速候选；构建、运行和符号覆盖需逐项实测，不得提前声称已成功。

最新已完成runtime-profile诊断：4个Dart文件analyze无问题，profile APK构建成功，SHA a4fa155e…；1次点击前参数错误不算播放，随后同一视频2条25秒有效录屏，确认动态画面4.739/5.089秒。这是profile+重监听原因诊断，不能替换2.45秒release旧基线。d1r环形timeline覆盖开头、off-CPU采样失败；d2改实时Timeline订阅，61045事件/8个HTTP区间、2242个Dart样本（1000us）、1790原生样本（零丢失、82截断）；原生未解析叶样本606，主要libflutter/AOT，Codec2服务未采函数栈。所有失败保留，未取第三条播放来追好结果。

d2已把主API1129ms、真实source.open到codec Init约1230ms、Init/configure/start合计约327ms、flush后首客户端输入到首Surface release约875ms分开；后者HEVC服务调度Running约697ms，客户端仍有睡眠/就绪等待。主API前5.5秒kswapd Running约3257ms，有swap计数和多个进程RSS增长。监听本身占明显样本：421/1790原生样本涉及诊断类或采样线程；profile继承Android debuggable=true。不能把5秒当新基线、不能把875ms全部称初始化或把Surface提交当实际显示。详细证据、SQL、原生火焰图在runtime-profile/findings.md与native-cpu.html。

当前最新接续应先降低重复geometry/JSON观测扰动，同时保留调用栈、异步区间与系统调度；校准点击原生时钟及实际显示链，重建同条件release基线；补全原生媒体取流/符号和Codec2服务缺口后，才按证据推进对应提速改动。不重复原四ABBA/五配对、不推进已否定候选。AVD和本次Java编译后台已关闭，安装已恢复17b4cf41…release对照，通知按本轮进入值恢复0。原目标保持active，不能把本条诊断结束标成主目标完成或自行blocked。

本次已做：同视频4条ABBA，真实运动对照3.795/3.786秒、候选2.886/3.020秒；再5个不同视频配对10条，只有一个候选更快，四个持平或更慢，中位差+46ms。明确停止剩余5组，不能为凑好结果继续，也不能宣称十视频验收。总计14条速度对照、6个不同视频；另有1条搜索输入截断CID/-404，已留证据不计速度。source-overlap/findings.md与multi-evaluation.json是结论。

随后只做1条Perfetto原因诊断：真实运动8.451秒，画面存在停留/跳变，不能混入速度对照。2736ms原生解码窗口内guest kswapd运行1438ms CPU；469ms客户端输入→Codec2工作完成内MediaCodec_loop就绪未运行344ms，说明存在回收/调度争用。不能把本条套回旧812ms，也不能把onWorkDone说成非空首帧。见native-codec-cause/findings.md和SQL。没有提出新的提速参数候选。

现在模拟器/本任务编译均关闭。最后安装17b4cf41…对照（已有Player/Surface待命，重叠关闭、深度日志关闭）。通知本轮进入时即为0，当前保持0；更早备份为1，后续若恢复全任务前临时状态，应核实这项差异，不要误报恢复成1。

工具新加vmstat/PSI只读采集（无权限记录unavailable），只检查过语法，尚未运行。下一步先明确guest回收与启动后台/解码分配的影响，采用最小必要原生观测。无需重编已有两APK，不重复四条ABBA或全部五配对。资源严格保持：一台原AVD2048MB/4核/音频，编译与模拟器不并行，launch物理可用至少10GiB且既有门槛通过；不降低门槛，不为了快样本关闭无关App或更改AVD内存。所有优化要对应主要延迟证据。
