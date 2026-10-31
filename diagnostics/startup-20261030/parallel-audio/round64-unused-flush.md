# 第64轮：省去首次取帧前的重复清空

新解码器在首次receive前不可能已向应用交付输出buffer，因此仅此状态、JNI Surface视频且显式开关启用时，跳过FFmpeg后端MediaCodec.flush。保留外层FFmpeg清理和buffered packet释放。第一次receive入口永久标记已使用，包括失败/EAGAIN；后续拖动/重播/销毁继续正常flush。不会重置标志来猜测“再次为空”。原10输出时间戳检查、画质、目标PTS和输出核验均不变。

|QA/版本|首纹理ms|封面条件ms|初始两flush合计ms|首PTS|功能验收|
|---|---:|---:|---:|---:|---|
|124/candidate|2348.867|2731.331|2.3084|61.500000|通过|
|125/control|2730.558|2995.705|47.6802|61.633313|未通过|
|126/control|2983.311|3472.372|69.2542|61.500000|通过|
|127/candidate|2752.868|3097.627|1.8176|61.500000|通过|

候选两次初始flush均skip=1，控制均实际调用；四条返回阶段used flush都实际执行，配对齐全。此处返回销毁不是主动拖动回归。

- B124−A125：纹理-381.691、封面-264.373ms；双方功能验收未全部通过，不能作为合格收益对照。
- B127−A126：纹理-230.444、封面-374.745ms；双方功能验收通过。

总时间还受接口、初始化与后续取流/解码变化影响，不能把一个阶段差值直接当总收益。QA125首消费PTS61.633313未过61.5精确起点，保留原件；尚无本条producer PTS证据，不能自行解释成正常合并并改判。排除seed的零起点首正PTS不为0，也不冒充完整零起点精确回归。

九个实际C函数提取生命周期检查（ASan/UBSan非PIE）通过；Dart分析clean。native一次编译成功并卸载。两APK同103源快照、同native/Flutter，只SKIP_UNUSED_CODEC_FLUSH不同；native d20932bd730e6dccbb90bc5a9ed518949c325341ce664b42992502c538e45a85；control fd9cad5703055f91665d390f8422bbcf00f8f5b44aced38b08d88f53f5f394b8；candidate b4cf3037d52f8f5bebee6aaf10c0a83fed536abf2275c723b706f2932994eaf4。两版都保留63关闭遗留下载、62codec reservation、61索引与58音频队列。

QA127第一次启动前physical9.76<10被拒，无AVD/无输入；原目录和gate分别保留unused-flush-launch-refused-01与emulator127-gate-before-settling.json。等待原10/10门槛三次连续通过后一次重启采集，没有重试测量点击。首恢复脚本误用UTF8读取PowerShell UTF16在改动前失败，修正BOM解析后继续。前两轮report默认GBK、未引用的gcc参数逗号解析错误也保留在host-validation.json，未影响播放采集。

实现默认false保留，尚未完成Android主动seek、早取消和重复打开组合。0.8秒未达到。下一项诊断需说明当前firstReceive之后的实际调用，优先复用现有范围，不凭代理字节计数断言网络或解码瓶颈。当前轻监听纹理消费仍不是物理屏幕显示证明。
