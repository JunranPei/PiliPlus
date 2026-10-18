# 旧 2 秒与本轮 4–5 秒：版本、条件、计时口径核对

结论：不能表述为“同一基线从 2 秒退化到 4–5 秒”。已确认同时存在输出路径/启动顺序不同、进程冷热条件不同、首个图像与明确运动确认口径不同，以及实测波动；不能只归因于网络或冷热。当前也没有证据把全部差额唯一归给某一项。

## 同一视频中找到的直接证据

视频均为 BV15BJX6dEoR / CID42790290231，App 搜索框提交视频 URI，录屏 PTS 与触点叠层作为时间锚。

| 记录 | 进程/播放器条件 | 实际输出配置与时序 | 首图 | 明显运动确认 |
|---|---|---|---:|---:|
| noclip-control-v1-5（旧实验“控制”） | PID9017 已运行并用过播放器；本次新 Player172560359，之前为176537666，不是同一个 Player 保留 | startup.output.config 明确 vo=mediacodec_embed、attachSurfaceAfterVideoParameters=false；open 后约12ms调用 play | 2.102s | 本次重审约2.44s以内确认明显运动 |
| standby-a2-20261019-5（c35回退代码控制） | 每次强停 App；首次 Player782047362；无媒体预加载 | 原 gpu，attachSurfaceAfterVideoParameters=true；open 后约2154ms调用play | 3.755s | 3.791s |
| standby-a1-20261019-5（c35回退代码控制） | 每次强停 App；首次Player925684601；无媒体预加载 | 同上；open 后约2876ms调用play | 5.060s | 5.094s |

旧“控制”APK SHA-256为09213586a9437f3ccf543bbdb0a7651dd549cfee2a73e2b026ff2891e35e119f；它用于当时 !no_clip 的单变量对照，已经有其他启动实验代码，不是 c35 原始回退包。Git 中 c35→e79 对比也包含 vo=mediacodec_embed、autoplay/startWhenReady、帧等待条件等运行差异。不能把旧目录名 control/baseline 当成一直固定的版本。

以上仅用于解释可比性，不推荐恢复整个旧实验，更不重新推进 Media3。视频输出 mediacodec_embed 是 mpv 的输出选项，与 Media3 是不同概念。

## 差异不只在接口

旧 noclip-control 最后一次请求的主接口约535.6ms；新 A2约513.2ms，接口几乎一样快。旧打开媒体到实际1920×1080 mediacodec参数约1349ms，新 A2约2116ms，新 A1约3597ms。新 A2先在约1025ms收到1920×1080 yuv420p，再经过占位输出和硬解输出。内部参数不是可见画面，只能说明媒体打开后的路径与等待确实不同。

旧 play 提前本身不是收益证明：历史已证实 play 调用提前不一定使画面等量提前。输出选项、打开时序、首帧门槛、进程条件等同时不同，不能从这几条历史记录分摊各自因果贡献。

同一回退控制包、同一AVD重启会话 A1/A2，主接口约806/513ms，打开媒体到内部UI就绪约3773/2324ms，真实运动约5.1/3.8秒。约1.3秒画面差额中，主接口仅约0.29秒，不能全称网络波动；媒体连接、探测、解码/输出、主线程调度仍需分段。两条样本不足以建立稳定分布，更不能称“基线稳定4–5秒”。

## 口径也存在差别

- diagnostics/startup-20261011/results.json 的 baseline 三条是 query→ui.frameReady.after 的3355/4328/2600ms。起点不是录屏点击，终点不是动态画面，且视频CID137649199不同，不能拿2600ms与本轮真实画面直接比较。
- 旧 noclip-evaluation.json 的2.102秒明确是 appearanceMinusPointerSeconds，即首图。旧原始录像本次逐帧重审：指针0.983s，首图3.085s，首图保持一小段，到PTS3.420s可明确看到汽车位置/烟雾变化，即约2.437秒以内确认运动。不能把2.102秒原样当成已严格量到最早运动的时间。
- 新记录分别保留首图和动态确认上界，首次图片保持不自动判成缓冲。约0.3秒的口径差解释不了全部2→4/5秒差距。
- 旧记录的“App已运行并用过播放器”不等于同一播放器保留。旧记录Player编号已核对不同，必须单列进程热/播放器新建；不得再次将其简化成“热播放器”。
- 0.8秒原始记录的版本、预加载及真实画面终点仍未全数对齐，本次未宣称找回了0.8秒稳定基线。

原始证据：noclip-control-v1-5的pixel-timing.json、result.json、traces/flutter-9017-1792212485065395.jsonl、screen.webm；本次新增audit-onset-20261019.jpg、audit-motion-20261019.jpg，时间标记在每格上方。当前控制的逐帧证据与阶段详见player-standby/evaluation.json。

## 待命方向的处理纠正

恢复 c35 运行包用于不把未证实候选作为常用版本；归档与构建脚本没有删除。但空 Player 候选未证实，并不否定 Surface/GPU 或解码器的其他可预备部分。之前将空 Player 的有界验证结果当成可以结束整个待命方向，停得过早。

GPU输出有源码依据继续定向验证：mpv player/playloop.c 的 handle_force_window 可无媒体建立 video_out；player/video.c 的 reinit_video_chain_src 若已有 video_out 可以沿用。当前插件 onLoad 通常新建Surface，必须验证第一次从未用于解码的待命Surface/GPU是否真的沿用，不能仅在首页创建又在点击时销毁。详见 gpu-standby/protocol.md。

解码器不能简单地为任意未选视频配置为可解码：Android MediaCodec configure 使用输入 MediaFormat，H.264/H.265正常解码需要目标参数集。可预建组件、可预热驱动与“能被mpv接管并复用的已配置解码器”是不同层次；mpv/FFmpeg目前自己管理解码器实例，不能假设另建一个Java MediaCodec就会被它使用。没有把猜测的片段、分辨率或预先播放另一个媒体混入本次GPU测试。

一手资料：[Android MediaCodec](https://developer.android.com/reference/android/media/MediaCodec#codec-specific-data)、[mpv playloop](https://github.com/mpv-player/mpv/blob/v0.41.0/player/playloop.c)、[mpv video chain](https://github.com/mpv-player/mpv/blob/v0.41.0/player/video.c)、[当前media_kit_video插件](https://github.com/bggRGjQaUbCoE/media-kit/blob/fd8421d21eade4d6d12de137fa7df902fec20292/media_kit_video/lib/src/video_controller/android_video_controller/real.dart)。源码分析为候选可行性依据，不等于实际收益。
