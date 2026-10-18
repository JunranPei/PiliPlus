# GPU 输出待命：可待命和沿用，稳定画面收益尚未证实

本轮继续了空 Player 之后的视频输出准备，没有重新推进 Media3 或本地转发。c35b53769正式源码和依赖缓存仍干净；原型代码、补丁、可重建脚本和APK单独保留，尚未合入性能修复。

## 已核实的机制

1. 在App首页、无媒体情况下创建原mpv/media_kit Player、Surface和GPU输出。本次首页检查从空引擎准备开始到输出ready约328ms；GPU准备自身约187ms。current-vo=gpu、vo-configured=yes、mediaCount=0、playing=false、video-codec为空；原生日志没有MediaCodec创建。
2. B1、B2首次onLoad分别明确记录handoff；与各自App进程预先创建的Surface wid相同，点击后的调用记录没有再次CreateSurface，也没有vo=null的卸载。媒体仍然只在点击后打开。
3. 控制两条均先出现1920×1080 yuv420p，再经历占位输出和1920×1080 mediacodec。两个候选实际视频尺寸参数直接为mediacodec，未出现这个软件到硬件的过渡。
4. 首页空闲GPU本身也发出了WaitUntilFirstFrameRenderedNotify；这不是视频首帧，不能作为任何起播验收依据。实际画面时间仍只按录屏内容复核。

GPU的空闲准备说明该层可以提前待命。它不等于解码器已经准备完毕；也不能将原来播放中vo=gpu同步调用的全部0.48–0.62秒归作纯GPU创建时间，因为该调用还受mpv核心忙碌影响。

## 实际定向结果

1次首页机制检查，4条有效视频记录，只有1个不同视频（BV15BJX6dEoR，CID42790290231）。顺序A/B/B/A，同一原AVD重启会话，均强停App后首次播放，搜索URI点击，无媒体预加载，原UI和画质/编码选择规则保持。每条35秒。A1录制标签误写成home-control，但实际是视频控制记录，不是首页检查；evaluation.json与目录完整保留该标签。

| 顺序 | 版本 | 首图/点击后 | 明显运动确认/点击后 | 主接口 | source.open→内部UI就绪（不是画面） |
|---|---|---:|---:|---:|---:|
| A1 | c35控制观察包 |4.218s|4.388s（约4.4）|671.602ms|2594.012ms|
| B1 | GPU待命 |3.485s|3.518s（约3.5）|518.783ms|2504.689ms|
| B2 | GPU待命 |3.303s|3.337s（约3.3）|668.423ms|2123.670ms|
| A2 | c35控制观察包 |3.443s|3.677s（约3.7）|504.721ms|2609.437ms|

原始PTS见evaluation.json及各目录exact-onset.jpg/json；同录屏指针作为起点，确认汽车/烟雾内容运动，转圈、弹幕、封面与首帧通知不计。运动数值是保守确认上界，首图的源内容短暂保持不直接认定缓冲。A2首图比B1还略早，而明确运动确认较晚，说明必须同时报告这两个终点，不能把确认运动的差额全称性能收益。

候选两条动态确认都较快，但B1与较快控制A2的内部打开后等待仅相差约105ms，真实运动确认差约159ms，处在条件波动与源初始画面保持的影响范围。B2内部阶段较A2少约486ms，但只有一个这种样本，仍不能认定稳定净收益。结论为机制成立、画面结果有希望但未证实稳定提速，未达到0.8秒，不进入十视频/正式采用验收，不靠反复追加同视频样本挑好结果。

## 连续播放与内存

前约20秒诊断窗口中，四条开始播放后均没有buffering=true或playing=false事件。35秒录屏起播逐帧复核、之后约每2秒抽查内容持续推进，未看到持续卡住或自动暂停；后半段短于抽样间隔的停顿仍未排除。未做完整音画同步、旋转、拖动、切画质、音频播放及长时空闲验收。

首页单次GPU待命PSS175082KiB（约171MiB），无本次同条件首页内存对照，不据此宣称净增多少。编译时模拟器关闭，测试仅一个模拟器；每次录制由既有内存门槛和监控保护，最低宿主提交余量见evaluation.json。模拟器临时heads-up设置在测后恢复为1。没有修改宿主页文件或停止其他项目进程。

## 解码器待命边界与剩余等待

本轮原生CCodec日志allocate→Created component，四条分别约57、131、87、55ms。这只是组件建立的观测跨度，不能把打开媒体到硬解输出的约1.5–2.3秒全称为“创建解码器”；相邻的输入格式日志也不等于整个配置已完成。输出待命后仍有取流/识别、解码器配置、首批数据处理与flush、首次输出、声音开始、显示稳定等等待，日志跨线程交付也有误差。

Android文档要求用输入MediaFormat配置解码器，H.264/H.265解码前需要对应的参数集。可以研究预建组件/预热驱动，但无法在未选视频、未知格式时把一个任意解码器完整准备好供所有视频直接解码；FFmpeg mediacodecdec_common.c目前自行createCodecByName/createDecoderByType再configure，不会自动接管另建的Java MediaCodec。需要先证明实例能复用，或证明系统预热能减少实际这段，不能靠猜测片段预播宣称目标视频已待命。

下一阶段沿用此归档原型进行解码/输出分段调查，原型机制与正式验收分开。未再把“未合入”当成停止整个待命方向的理由。当前只有首次尚未使用的Surface会被接管，后续视频沿用原生命周期，尚未解决所有视频的等待。

一手来源：[MediaCodec参数与codec-specific data](https://developer.android.com/reference/android/media/MediaCodec#codec-specific-data)、[FFmpeg解码器创建/配置](https://github.com/FFmpeg/FFmpeg/blob/n9.0.1/libavcodec/mediacodecdec_common.c)、[mpv空闲输出](https://github.com/mpv-player/mpv/blob/v0.41.0/player/playloop.c)、[mpv输出复用入口](https://github.com/mpv-player/mpv/blob/v0.41.0/player/video.c)。源码可行性不是端到端性能证明。

候选APK SHA-256：51a4eb198abe20df0ac08eb44ffce2a534c646a00a85b5244dcdbdc40fe08b73。控制观察包aa452704…；可随时复现的纯回退包caac87ad…均保留。最终安装状态以installed-state.json为准。
