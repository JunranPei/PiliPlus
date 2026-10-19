# mpv原生解码与模拟器内存回收诊断

## 样本与实际画面

只新增1条原因诊断，各35秒，原PiliPlusStartupProbe_20261011 AVD、2048MB/4核、音频开启。实际安装SHA17b4cf41…，原Player/Surface待命开启，媒体/页面重叠候选关闭，深度trace关闭。没有编译新包。

使用20秒/32MiB的系统Perfetto，启用video/audio/gfx/view/binder与调度，不开启采样分析器或内存转储。计时器移到搜索URI预检完成后、开始录屏前，避免长输入准备耗尽诊断窗口。android.log只请求StartupTest标签；实际android_logs表未捕获该标签，不能声称获得了日志锚点。原生时间与Dart UTC使用trace内REALTIME时钟快照对齐，不与WebM PTS直接拼接。

原始录屏指针PTS1.883，封面最后10.055，首个媒体图像10.102，运动确认10.334：首图8.219秒、真实运动确认上界8.451秒。首图停留约232ms，后续也有重复画面和跳变，不能称正常平滑播放。约22秒有效Dart日志内未见初始buffering结束后再次缓冲或playing=false，但不能用这些标志否定画面卡顿。18–35秒抽帧继续前进，不能排除短卡。

此样本显著慢于此前速度对照；接口本身2099ms，环境/新启动模拟器与系统追踪的影响未分离，不能将它当代码回退，也不能把以下数值直接拆回最早2.446秒样本中的812ms。

## 系统计时补到的边界

| 真实原生调用或事件 | 时长/间隔 |
| --- | ---: |
| MediaCodec::Init#native | 501.366ms |
| MediaCodec::configure#native | 31.669ms |
| MediaCodec::start#native | 278.345ms |
| MediaCodec::flush#native | 63.410ms |
| flush后首个客户端queueInputBuffer开始→对应PTS0的Codec2工作完成回调 | 468.980ms |
| 同一客户端输入开始→首次renderOutputBufferAndRelease调用 | 626.248ms |

Init与allocate→Created component不是同一边界。前者包含更多调用/等待，后者这条也变慢到约313ms；不能将历史116/117ms与本条501ms相减求“可省开销”。

输入flags/size未在本次trace记录，故将边界命名为“flush后首个客户端输入”，不冒称已精确定位真实媒体首字节。start之后更早的CCodec queue@ts=0可能是配置数据，不能当首个真实视频包。Codec2 onWorkDone不保证有非空输出，469ms终点只是工作完成；首次Surface release是另一边界，也不是实际显示。

## 已证实存在的回收与调度争用

在从mpv视频解码器打开交付时间到首次原生Surface release的2736.263ms窗口内，guest的kswapd0实际运行1437.975ms CPU，位列所有线程第一；模拟器HEVC解码服务线程运行651.949ms CPU。

在上述468.980ms的输入→工作完成窗口，MediaCodec_loop处于Runnable/被抢占的时间合计343.972ms，实际运行29.041ms。同期kswapd0运行296.493ms CPU，HEVC服务运行262.092ms CPU。这些线程可以在不同核上并行，CPU时间不能相加为阻塞墙钟时间；也不能将所有Runnable等待都单独归罪于kswapd。可以确定：这不是解码器一直在做配置或单纯缺包，系统回收和CPU调度争用参与了此条等待。

线程优先级已较高：mpv Thread-6与MediaCodec_loop的调度priority为110，CodecLooper与HEVC服务为104–110；没有证据支持继续提高优先级作为下一方案。

主机录制最低可用物理内存7.876GiB、提交余量11.653GiB，未触发门槛。guest点击前总内存约1.92GiB，MemAvailable约804MiB，已经使用约397MiB swap；App点击前PSS约105MiB、SwapPSS约56MiB。主机余量充足不等于guest没有回收压力；但单次点击前快照也不能解释是哪一项分配触发了窗口内回收。

## 未知与下一步边界

1. 尚未区分guest内存回收的直接触发者、启动后台工作、App/媒体缓冲分配和追踪扰动的各自影响。没有擅自扩大AVD内存、关闭Google/其他应用、改变系统内核参数或降低既有门槛。
2. 旧2.45秒记录没有这组原生边界，不能说本条回收证明旧样本也有同样等待。历史2.x与4–5秒差异仍需分别标注App、Player、媒体和模拟器启动/资源条件。
3. 已给录制工具增加点击前/录制后的guest vmstat与memory PSI只读采集，缺失/无权限时保留unavailable而不中断。新采集项只做了语法检查，尚未在模拟器实际验证，不宣称它们提供了本条证据。本条结论来自已有Perfetto调度和meminfo。
4. 不推进被五组配对否定稳定收益的SOURCE_EARLY_PREPARE；不继续Media3、并行转发或!no_clip。先在下一次必要诊断中分清guest回收与有效解码/输出等待，再提出与主要耗时对应的改动。

## 证据与源码

inspect.sql/txt、scheduler.sql/txt、server-states.sql/txt可在保存的startup-bounded.pftrace上复核；原始录屏、traces和逐帧图在mpv-phase1/source-native-cause-d1-20261019-5。evaluation.json保存已核对的时间、安装SHA、内存和限制。

- [Linux对kswapd与内存回收的说明](https://docs.kernel.org/admin-guide/mm/concepts.html)：kswapd在低水位后后台扫描回收页面；不能将CPU运行时间直接当应用阻塞时长。
- [Perfetto系统ATrace与SQL切片](https://perfetto.dev/docs/data-sources/atrace)：系统类别跨进程采集，slice表示调用区间，追踪本身有开销。
- [FFmpeg MediaCodec接收路径](https://github.com/FFmpeg/FFmpeg/blob/n9.0.1/libavcodec/mediacodecdec_common.c)：首个输出前非阻塞读取，不能把draining的一秒等待分支泛化为首次输出必等一秒。

本条结束后本任务模拟器已关闭，未留下编译进程；本轮进入时通知值为0，按本轮备份保留0。更早old-mpv-standby备份为1，两者不同，不能宣称本轮恢复成1。最终安装为17b4cf41…对照包。主目标尚未达到。后续曾实际核实get_goal为blocked，此前写“持续目标保持进行”不准确；2026-10-19新一轮已实际核实原goal为active，继续完整调用栈/时间线诊断，当前状态见continuation.md。
