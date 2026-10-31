# 第64轮当前尾段：QA128重型跟踪

固定64候选，新App进程3819首次精确续播61.5秒。目标纹理3038.1118ms、封面放行3693.0351ms；这是8秒Perfetto和wait监听诊断，不能和轻监听样本计算收益。精确首PTS61.5、strict stable、返回回收通过，最大正PTS回调间隔504.748ms；AVD正常关闭。

| 输入后的阶段 | 实测耗时 |
|---|---:|
| 输入→source.open.begin | 519.8461ms |
| open→核心init_avctx | 463.0866ms |
| 核心init→首视频输入队列 | 315.8744ms |
| 首输入→目标视频帧释放 | 1698.9562ms |
| 释放→首变化纹理消费 | 40.3485ms |
| 首纹理消费→封面条件完成 | 654.9233ms |

选定解码器后台工厂线程3895、核心视频输入3868和画面释放3889必须分开。时间分析现从实际queueInput线程选择核心；不再按提前创建线程推断解码线程。首receive1125.9091ms；初始两个flush跳过区间1.2659ms，返回used flush实际执行7.9384ms。

首包→释放1698.9562ms的核心线程状态为Running391.8509、睡眠720.3857、可运行但未调度583.5085、不可中断等待3.2111ms。其互斥调用分区：queueInput589.4124、dequeueOutput299.5504、dequeueInput164.5013、releaseOutput62.9963ms；其余为滤镜调度/其他工作。queueInput内部Running仅12.2316ms、睡眠466.8229ms；不能叫整段CPU解码或全部JNI开销。10帧PTS可信检查到2037.2958ms才完成，首drop2为2063.2223ms；不缩短这项正确性检查。

本轮没有出现早期0.9秒级全guest事件空白，输入前1.5秒最大switch间距17.1926ms，不能复用旧样本的host推断。

音频已经由4083 dec/audio线程在目标视频释放前解码96帧，PTS59.989333–62.016秒。但核心仍在视频READY之后才让旧数据通过最终filter链，70帧被全部裁掉，3305.8911ms才保留61.500秒/192样本。目标释放到restart通知入队共372.3701ms，其中filter_graph互斥179.5604、ao49.9712、user_filter_wrapper47.8745、系统音轨启动15.5167ms。不是372毫秒纯AAC解码；包含重型监听和调度，不能直接当可省值。

restart入队3370.1334→取出3377.2581ms；后续属性排队约57和48ms、实际ready3564.366ms、稳定条件3693.0351ms。两次属性查询等待仍在，但本轮先实现有明确数据所有权边界的“原音频处理链提前运行并有限暂存”，随后等同条件结果再决定保留组合。

分析修复：旧extension依赖手工all-app-spans.csv，本次自己查询并新写state-extension-attribution-01；旧失败及部分SQL保留。早期把工厂/渲染/输入视为同线程的拒绝保存在time-attribution-refused-01，没有伪造报告。六类分析现全部完成。图像识别未使用，物理显示/扬声器完成未证明。

- QA128进一步调度归属：首queue→target四核合计6795.8248ms，其中idle1362.9337ms（20.06%）；App2694.5321ms，goldfish HEVC线程511.1999ms。主线程416.8811、DartWorker4029 377.4817、核心391.8509、codec消息线程181.3278、音频133.9551ms。最长codec-loop被抢占66.0248ms内，CPU1仍有45.238ms idle，同时kswapd0运行29.9748ms、kworker/3 37.059ms。不是“四核全满所以只能加优先级”的证据；仍缺affinity/cgroup/host物理CPU归属。重型采样负担包含在内，不能推算手机收益。新scheduler-contention-01原SQL/CSV/summary保留。
- 官方资料复查：mpv仍不建议硬解开启vd-queue；Android35 queueInputBuffers只支持异步模式，批处理涉及MultipleFrames能力，现FFmpeg同步JNI不能仅换方法名。没有据此增加猜测性开关或改变codec模式。下一先完成65原2560两包设备对照。
