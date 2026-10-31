# 后续可叠加方向

1. **已验证机制：音频提前。** mpv v0.41.0 在主 demux 打开后才调用 load_external_opts；换成外挂 audio-files 本身不能实现并行。现候选只提前音频，避免旧全视频 Dart 转发方案的连续播放风险。原生视频流未变。
   https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/player/loadfile.c
2. **正在验证：启动期预读竞争。** mpv 官方手册说明后台网络预取可能占用大量 CPU，造成开头掉帧。现 trace 确有 decoder/主线程/demux/kswapd 同期运行。试验只在首帧前将缓存目标降至1秒，首帧后恢复原配置；不关闭 underrun recovery。是否有效取决于设备对照，不把 cache-secs=16 误解成必须等16秒。
   https://mpv.io/manual/stable/#options-cache-pause-initial
3. **可单独测试：TCP_NODELAY。** FFmpeg tcp.c 默认 tcp_nodelay=0；http.c 将未消耗选项留在 chained_options，TLS继续传给底层 TCP，因此 stream-lavf-o=tcp_nodelay=1 有源码支持。旧诊断 connect.end→GET 约45ms只是提示，不能据此断言是 Nagle。尚未改代码/实测。
   https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/tcp.c
   https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/http.c
   https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavformat/tls.c
4. **需原生构建才能进一步判断：MediaCodec low-latency。** Android API30有相关键；2023 FFmpeg补丁建议根据AV_CODEC_FLAG_LOW_DELAY设置MediaFormat，但本次核读当前FFmpeg master mediacodecdec.c没有该映射，不能直接宣称 flags=low_delay 有效。Firefox另有已落地ffvpx补丁。不能通过去掉必要B帧重排来换错误画面；先判断设备支持与现用库，且不替换mpv后端。
   https://ffmpeg.org/pipermail/ffmpeg-devel/2023-May/310004.html
   https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/mediacodecdec.c
   https://bugzilla.mozilla.org/show_bug.cgi?id=2009769

排除直接套用 low-latency 整套配置：会关闭 cache-pause、改变线程和同步等，无法单独归因且有卡顿/其他功能风险。官方 video-latency-hacks 只省1–2帧并可能破坏插帧，需个别场景再评估。

第三次模拟器启动期间，运行已测试的combined基线后，ADB shell与emulator console同时失去响应；主机available约7.2GiB、commit headroom约8.4GiB，没有证明是宿主OOM。新read-ahead尚未成功安装，因此不能将失败归因于第三候选。保存combined-boot-04、read-ahead-01失败记录与hung-emulator.json；正常关闭请求也超时，只终止了已确认的PiliPlus专用QEMU。第四次使用完全相同参数重启，数据未清除。

## 后续核查（第五轮构建期间）

- 预读与TCP已实测无收益，前文“正在/尚未”对应当时状态；最新结果见experiment-ledger.md。
- mpv v0.41.0的demux_lavf.c在auto模式按格式白名单决定是否调用avformat_find_stream_info，nostreams则仅nb_streams==0才调用。官方说明它可能拖慢启动，但跳过影响信息完整性；下一步先查现有深日志是否真的花时间于该阶段，再对选定DASH MP4做定向实验，不降低全局探测可靠性。
  https://mpv.io/manual/stable/#options-demuxer-lavf-probe-info
  https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/demux/demux_lavf.c
- Android官方低延迟模式需要编解码器驱动支持，开启后会改变解码器等待及节能行为，不能仅因有API就保证收益。未作为本轮开关加入。
  https://source.android.com/docs/core/media/low-latency-media?hl=en


## 2026-10-30 第07轮后续排查
- Dart HttpServer当前源码已设置TCP_NODELAY，不再重复实现。HttpResponse.bufferOutput官方说明指出关闭缓冲后大量小块会导致性能差：https://api.dart.dev/dart-io/HttpResponse/bufferOutput.html 。当前helper每块flush又重新建立sink消费，值得单独对照addStream持续消费；不能直接去掉背压或改成无限内存队列。https://api.dart.dev/dart-io/IOSink/addStream.html / https://api.dart.dev/dart-io/IOSink/flush.html
- Flutter官方建议避免build重复昂贵工作、把超过帧间隙的任务移出主isolate，同时说明isolate自身有启动/复制开销：https://docs.flutter.dev/perf/best-practices / https://docs.flutter.dev/perf/isolates 。当前运输已经在worker；后续须区分页面重建、解析任务和运输，不把所有DartWorker都当作运输线程。
- mpv audio-buffer默认200ms为输出最小缓冲，不等于起播必须等待200ms；官方只建议测试并提醒小缓冲音频断续：https://mpv.io/manual/stable/#options-audio-buffer 。新trace的首次有效codec工作完成约1226.8ms、输出释放1281.4ms，仅约55ms后；尚无通过降低音频缓冲省200ms的证据，所以暂不盲调。

- 新网络零位置起播：当前media_kit原生_add明确生成start=0.000；mpv官方版本源码https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/player/loadfile.c 第1775–1783行说明非空play_start会触发初始seek。拟仅省略零位置测试，非零resume/skip保持。

- EDL第一包边界与decoder reset对应源码：https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/demux/demux_timeline.c（298–307）、https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/filters/f_decoder_wrapper.c（808–815、983–1003）。完整单轨文件可单独实验no_clip：https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/DOCS/edl-mpv.rst（131–138）；不得对多分段/带offset的源泛化。此机制属mpv内部支持，依赖版本升级时须复核。
- mpv也支持audio-files-append单项原样参数（无需冒险按冒号分割URL），但改为外部音轨会改变统一缓存方式；先选更小的no_clip对照。https://mpv.io/manual/stable/#list-options

## 2026-10-30 后续验收与预加载资料
- Perfetto官方FrameTimeline区分应用帧完成/提交（max GPU与post时间）和SurfaceFlinger显示帧的呈现完成；可以用surface_frame_token/display_frame_token关联，但还必须把当前视频纹理和已解除封面的Flutter帧关联进去，不能把任意应用帧或SF帧算作视频首帧。https://perfetto.dev/docs/data-sources/frametimeline
- Android官方预加载管理资料说明在开始播放前加载可减少切换等待，按离当前项的距离排优先级。可借鉴有界预加载策略，不能因此把mpv替换成Media3，也不能把已有缓存的样本混成冷网络起播收益。当前所有候选仍mediaPreload=false，未添加可见列表预加载。https://developer.android.com/media/media3/exoplayer/preloading-media/preloadmanager

- 47查阅mpv v0.41.0官方client.h：https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/include/mpv/client.h；94–124行说明同步调用等待播放核心、耗时无上限；异步回复通过事件，若要保持顺序必须等前一回复。因此采用单一pending串行await和独立回复client，不并发请求、不中途丢弃原source队列。此资料与46实测346ms UI阻塞吻合，但不代表异步会同等缩短原生解码时间，须实测。

- 后续取流突破口（尚未实现/未宣称收益）：ParallelAudioSource的resume预取目前只提前等headers，正文直到native Range claim后才开始应用层消费；256KiB是消费时重播缓存。47首条video headers约open后858ms/claim约882ms，audio headers约616ms/claim约905ms，有不同的可重叠窗口。可试只对已选续播段提前读取有上限正文，达到上限暂停、真正claim后无缝接管。需严格保护原Range、取消、迟到响应、Content-Range/总长校验、流暂停传递与内存上限；不能把StreamController无限缓存当预取。
- Dart官方HttpClientResponse说明正文是单订阅Stream（https://api.dart.dev/dart-io/HttpClientResponse-class.html）；StreamSubscription.pause会缓冲并尽可能通知非广播源暂停（https://api.dart.dev/dart-async/StreamSubscription/pause.html）；官方创建stream指南明确unlistened controller会积累事件，需要onListen/onPause/onResume/onCancel传递背压（https://dart.dev/libraries/async/creating-streams）。这支持有界单订阅接管设计，不证明网络性能收益。
- 当前性能比较固定60秒，便于隔离变量；并不代表所有续播位置。后续保留60秒对照，再补非整段边界（例如61.5或63秒），避免只验证最有利I帧边界。已有99组FFmpeg机制内容检查不能替代这些Android延迟样本。

- 50解释首播/续播差别时再次核mpv官方hr-seek文档：https://mpv.io/manual/stable/#options-hr-seek 。精确seek需从前一个关键帧解码到目标位置，解码性能影响等待；hr-seek-demuxer-offset过大会额外解码，hr-seek-framedrop默认yes。此机制不证明61.5秒样本所有差值都属于解码；当前lean样本没有独立codec队列时间戳，不作过度归因。


### 53：确认异步属性查询与UI阻塞不能混为一谈
- 官方mpv v0.41.0 player/client.c：mpv_get_property_async只分配request后run_async；run_async reserve_reply锁客户端并mp_dispatch_enqueue，不等待属性结果。同步mpv_get_property走run_locked。源码支持需分开计量同步提交与异步等待，不支持仅凭awaitUs推断UI阻塞。
- https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/player/client.c （行1375–1422、1002–1010、655–665）。53增加submitUs，未改变查询顺序/ready条件。
- 当前media_kit onLoadHooks的surface调用已带begin/end；94在open附近setOption wid约1.65ms、vo约1.14ms，不能解释随后约1秒事件空白。首帧参数通知前没有showPlayerInfo调用证据；其同步getProperty仅手动播放信息对话框使用，不盲改。
