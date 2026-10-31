# 第82轮：当前组合的原生调用与线程等待

沿用 QA144、native72、callbacks=1、wait=0、decode-only=0、videoqueue=1，应用为第81轮候选。没有重新构建或启动模拟器。首播位置61.5秒，没有拖动。增加原生调用和调度事件采集，**这条诊断样本不加入轻监听速度比较**。

实际 PID12200；跟踪17,403,291字节。输入到纹理消费2453.0566ms，返回三项资源关闭分别352.148/352.806/353.156ms。解析器未报告数据丢失或错误。原始数据保留在 `current-resume-native-spans-01/capture/`。

解码线程12481，初始化线程12253，渲染线程12264。首次receive848.9366ms，首次输入入队1050.1752ms，目标帧提交2249.2384ms。**首次入队是续播前需要解码的参考数据，不是61.5秒目标帧**；修正分析器旧命名，旧原始记录未改。

从首次receive到目标提交的1400.3018ms，按同一个解码线程上的嵌套调用去重划分：

|位置|墙钟时间ms|其中睡眠ms|其中可运行但未调度ms|其中guest Running ms|
|---|---:|---:|---:|---:|
|MediaCodec.queueInputBuffer|570.0006|424.5128|136.0621|9.4257|
|记录到的解码工作之外|545.1706|528.7580|14.1758|2.2368|
|avcodec_send，扣除上述MediaCodec调用|131.7514|0|100.9636|30.7878|
|avcodec_receive|54.1463|0|46.7491|7.3972|
|其余解码/过滤调用|99.2329|0|47.0470|52.1859|

这些数值只解释本条跟踪，不能从正常样本里直接减掉570ms，也不能把不同线程的时间相加。guest Running只证明虚拟机认为线程被调度，不等于宿主机持续执行。所有睡眠区间的waker字段均为空，当前数据**不足以断言每次睡眠由谁唤醒、或全部是网络等待**。最长调用外睡眠194.4812ms，位于第一次送包之前。

应用取流事件显示目标视频响应约490ms、首块约499ms已到；原生约918ms才认领续播流，约1050ms第一次向解码器送包。因此“响应头已到”不能当作“解码器已经收到参考帧”。这些应用事件也包含跨线程投递延迟，精细计算应使用事件中的worker时间。

核对当前实际native72对应Java源码：缓冲区可用性已经走回调，但 `queueInputBuffer` 仍在解码线程同步调用MediaCodec。这与大量时间落在该同步调用中相符。

下一轮针对这一具体同步点，先验证输入提交与输出消费能否独立推进。AndroidX提供了[异步输入入队实现](https://raw.githubusercontent.com/androidx/media/release/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/mediacodec/AsynchronousMediaCodecBufferEnqueuer.java)及[适配器的生命周期处理](https://raw.githubusercontent.com/androidx/media/release/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/mediacodec/AsynchronousMediaCodecAdapter.java)：独立提交线程、错误转回调用者、flush/close前清空并等待正在运行的提交。其注释特别涉及加密输入场景，不能据此宣称本项目的非加密HEVC也一定受益。

实现前后必须保留相同输入与输出PTS、EOS、flush代次和取消释放；先用现有Android解码夹具验证再决定是否构建原生库。另一个528.758ms调用外睡眠区间继续保留为独立待解释项，不假定异步提交会一并消除。第79轮提前只解码的实验也保留，不以这次研究为由删除。

完整去重区间、各线程状态和缺失字段在 [decoder-waits-reviewed.json](current-resume-native-spans-01/capture/time-attribution-01/decoder-waits-reviewed.json)。目标仍未达到0.8秒。
