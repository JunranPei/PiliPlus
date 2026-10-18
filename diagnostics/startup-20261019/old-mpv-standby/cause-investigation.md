# 旧版待命未能证明提速：本轮证据

已录制同一视频 4 次，A/B/B/A，冷 App、点击前不打开媒体，同一台模拟器同一次启动，无构建并行。画面时间来自原始 WebM PTS 和可见点击指针，未使用首帧通知或封面开关代替画面。

| 样本 | 首个媒体画面 | 确认动态画面上界 | 主接口 | 接口结束→open | open→真实1920参数 |
| --- | ---: | ---: | ---: | ---: | ---: |
| A1 关闭 | 5.065s | 5.199s | 1626ms | 654ms | 2482ms |
| B1 待命 | 2.901s | 2.935s | 524ms | 21ms | 1747ms |
| B2 待命 | 3.726s | 3.758s | 839ms | 96ms | 2142ms |
| A2 关闭 | 2.377s | 2.446s | 604ms | 80ms | 1471ms |

A1 是本模拟器重启后的第一个 App 视频样本，慢样本保留，不删除、不与 A2 拼成趋势。两条 B 确认同一个预建 Player 和 Surface 被接管，点击后没有 CreateSurface；机制成功不等于端到端收益。两个控制均未接管待命。构建和安装 SHA 见 evaluation.json 及两份 build.json。

## 为什么空播放器待命没有产生稳定收益

1. A2 的 Player.create 42.4ms、VideoController.create 17.6ms、Surface hook 43.6ms，总计约104ms。待命提前的是这些步骤。它没有提前主接口、真实音视频打开、媒体参数和真实解码。
2. A1 中上述创建步骤约826ms，说明开机首轮环境成本波动很大；不能把这一条相对 B 的差值视作稳定可回收收益。A1 同时主接口慢约1.1s。
3. A2 的现有稳定输出检查在960×540占位参数时就通过，elapsedMs=131、buffering=true、position=0。这没有生成真实媒体画面，随后录屏确实先出现黑色加载。
4. B1/B2 的稳定检查等到1920×1080才通过（elapsedMs=1832/2078，position=300/133ms），mpv.video.start到ui.frameReady.after又经过407/223ms。预建输出没有消除这个UI等待；两条B首次可见画面已经跳过片头的部分内容。占位参数是否到达和监听时机有关，现有门槛不能用作可靠真实首帧判据。
5. A2 中接口之后的大段耗时是打开真实媒体及解码。空Player不能绕过这些步骤。仅凭4条数据不能断言待命一定变慢，也没有证据说稳定变快。

## A2 的2.45秒分段

以下阶段以query.primary.begin为0，是Dart收到事件的时间，并非逐条原生执行时间。它与录屏指针没有经过精确跨时钟对齐；不可把剩余差额全算成显示延迟。

| 累计时间 | 观察到的过程 |
| --- | --- |
| 0–604ms | 主取流接口请求；偏好读取已经与之重叠 |
| 604–685ms | 创建Player/VideoController、挂载UI并进入source.open |
| 685–735ms | open提交、Surface附着、进入EDL |
| 735–1062ms | 第一媒体源连接、读取及格式识别，包含58ms TCP连接事件间隔 |
| 1062–1340ms | 第二媒体源连接、读取及识别，包含57ms TCP连接事件间隔 |
| 1340–2153ms | 视频解码链打开至hardware/output.configured，含组件选择、创建、配置、输入、解码和输出；不是全在创建组件 |
| 录屏确认2.446s | 1920真实媒体图像出现，随后烟雾/车体确实变化 |

视频decoder.open后约113ms才看到Android CCodec.allocate；allocate到Created component为117ms，配置输入格式在其后27ms。余下等待中尚缺first queued packet/first output buffer边界，不能把约0.8秒归因于某一个函数或假定可全部删除。

codec为c2.goldfish.hevc.decoder，属于本次模拟器路径。不能把mpv的hardware标签等同于手机真实芯片速度；本轮不要求手机。

## 源码与尚缺证据

- 当前lib/plugin/pl_player/controller.dart的_waitForStableVideoOutput检查宽高和重复签名，未排除mpv的960×540占位输出。B等待真实参数、A提前通过的分歧由本轮output.stable事件直接证实；清理占位误判不能直接声称提速。
- mpv v0.41.0 demux/demux_edl.c逐路调用demux_open_url；!new_stream本身不创建并发。源码与当前日志顺序相符，但不重新采用已失败的并行转发。
- FFmpeg n9.0.1 mediacodecdec_common.c先create、configure、start，再queueInput和dequeueOutput。Android要求H.265的CSD配置，空Player/空Surface不等于真实解码器已经配置。
- 当前日志只标了TCP连接成功与格式识别；没有精确HTTP首个媒体数据字节。HTTP响应行也不是首个媒体数据包。
- 新增PLAYBACK_STARTUP_DEEP诊断开关只记录分类后的首次HTTP响应/解码器启动/最初3次输入输出事件，不保存URL/头/媒体内容，不改变选流或输出顺序。它不是提速候选。首次分析工具等待未完成，已结束本任务分析进程，不能称分析检查通过。
- 相册完成并释放模拟器后，诊断包已构建成功（6m14s），SHA256 e00b8dcca376e5782d34af9a932a2e50adcf07c8c02e71ba46216c8be63d5a17；构建后恢复依赖缓存并结束本任务Gradle后台69164。源码快照及散列见deep-diagnostic-source.json/zip。新增诊断有效播放样本仍为0。
- 单台原AVD启动后，首次诊断录制因可用物理内存5.881GiB低于不变的6GiB门槛，在创建样本前被拒绝（提交余量9.693GiB）。此后恢复通知并关闭本任务模拟器。相册任务虽完成，其两个编译后台仍占约3.5GB；尚未关闭，已询问用户授权。见deep-resource-refusal.json。后续启动前额外要求至少10GiB物理可用内存，避免重复启动后拒录；没有放宽录制门槛。

参考：

- https://github.com/mpv-player/mpv/blob/v0.41.0/demux/demux_edl.c
- https://github.com/FFmpeg/FFmpeg/blob/n9.0.1/libavcodec/mediacodecdec_common.c
- https://developer.android.com/reference/android/media/MediaCodec#codec-specific-data
- https://github.com/FFmpeg/FFmpeg/blob/n9.0.1/libavformat/http.c

## 连续播放和内存

4条均录35秒；启动细帧和后续约2秒间隔画面已人工检查，约20秒有效日志中未出现起播后再缓冲或暂停。不能排除后半段短于抽帧间隔的卡顿。没有十视频验收或0.8秒达标结论。

4条录制中的宿主最小提交余量均超过12.3GiB，可用物理内存均超过8.9GiB，未触发中止。随后为原因诊断安装了e00b8dcc…关闭待命诊断包，但未产生新录制；PiliPlus模拟器已关闭、临时通知设置已恢复。
