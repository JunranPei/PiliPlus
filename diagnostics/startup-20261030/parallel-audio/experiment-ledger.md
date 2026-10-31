# 起播优化逐轮记录

本表持续追加。目标为 0.8 秒；保留已有改善，独立检验叠加项。所有数值均为输入至首个正时间戳且变化的纹理消费，尚不等同物理屏幕呈现；不使用图像识别。源文件快照、APK SHA256、编译开关见各包 `.build.json` / `.sources.zip`，原始采集目录保留，不以失败样本填补性能结果。

| 轮次 | 修改及假设 | 构建与实测 | 结果与决定 |
| --- | --- | --- | --- |
| 01 | 仅提前选定音频 HTTP，视频仍由 mpv 原生读取；运输生命周期随已加载源 | candidate.apk d023607f…；control-03/04/05 对 candidate-01/02/03-return | 中位数 1812.8 → 1453.8 ms，API 中位数约相同，约省359 ms。保留。单视频小样本，不宣布总体完成。 |
| 02 | 在页面挂载期间提前准备选定媒体，叠加音频提前 | combined.apk ec5fa9e1…；combined-01/02 对 audio-07 | API→open 约1–2 ms；相近API下1411.9 对1433.8 ms，增量22 ms，未证实稳定收益。保留实验。 |
| 03 | 首帧前缓存目标1秒，首帧后恢复16秒，5秒截止保护 | read-ahead.apk afa747b0…；read-ahead-03/04 对 combined-05 | 1302.6/1398.3 对1232.6 ms；实际1→16恢复已验证，但无优势，后续有效组合不开启。代码保留。 |
| 04 | 原生 FFmpeg TCP_NODELAY，检验连接等待 | tcp-nodelay.apk 51115b36…；tcp-pair-02，预热+ABBAAB共7次全部完成 | 控制1541.2/1346.6/1352.6，候选1388.5/1521.9/1431.9 ms；中位数1352.6→1431.9 ms，无收益，后续不开启。 |
| 05 | 视频与音频均提前请求；字节转发放到独立Dart isolate，避免UI线程转发争用 | isolated_media_sources.dart + 新生命周期测试；待接线/构建/实测 | 进行中。沿用音频提前的范围回退与关闭机制；必须验证连续播放、拖动、返回、取消，不以单次起播数字验收。 |
| 06 | 叠加选定视频线路的延迟备用请求：主线路120ms未返回有效头才尝试一个API已有备用URL | HEDGE_MEDIA_SOURCE默认false；只用于默认基础/备用URL选择，明确指定CDN或手改URL不变；待构建实测 | 进行中。胜出后关闭败方连接；不变清晰度/编码，不请求未选视频。 |

## 功能、异常与样本处理

- 音频运输9项与源队列7项测试通过；页面准备重叠3项测试通过。新独立isolate测试尚未运行。既有孤立失效测试文件不计入通过。
- candidate-01/02连续采集25秒，首帧后无再次缓冲和≥100ms纹理间隔；AudioFlinger活动音轨48kHz双声道、underruns=0。candidate-03-return在10秒返回后连接关闭、无应用活动音轨。
- candidate-04-cancel实际0.668秒返回，连接关闭，无有效纹理属取消用例预期；不把采集器exit1当起播失败。
- 冷启动样本独立记录：control-02=3109ms；audio-boot-06=2711ms；read-ahead-02-boot=2934ms；tcp-pair-02/warmup=3022.5ms。API首轮可达1.5秒，原因仍待证实，不能全归因于Flutter构建。
- combined-03-perfetto是重采样诊断，不混入轻监听速度比较；解码首次输入→释放约282ms。
- 第三次模拟器会话运行combined基线后ADB及console冻结；新read-ahead尚未安装。见hung-emulator.json，不能归因候选或断言OOM。
- 第五次模拟器会话的TCP七次采集完成之后，查询系统服务和getprop超时。见hung-emulator5.json；正常关闭也超时，仅终止核对过的本任务QEMU PID71440。性能采集完成与之后的环境冻结分别记录。Gallery数据保留，测试结束仍须恢复。
- tcp-pair首轮在安装后内存余量7.87GiB被采集门槛拒绝，稍后自然恢复9.466GiB才运行tcp-pair-02；未降低门槛，未关闭无关应用。

## 后续每轮记录要求

记录假设、改动文件与快照、安装包完整哈希、编译开关、AVD/视频/清晰度、对照顺序、输入/API/open/解码/纹理各边界、连续帧和音频状态、异常与排除原因、保留或关闭决定。未测或缺失证据明确写明，不覆盖旧目录。

### 第05轮接线与构建前检查

- controller.dart 接入默认关闭的 ISOLATED_MEDIA_SOURCES，替换选定的两路URL；建立失败保留原URL，换源及最终dispose关闭worker；本地URL错误加入既有原生重试分支。原音频单路方案保留为对照。
- isolated-tests-cached.txt：22/22通过。最初测试命令自动等待依赖下载，保留isolated-tests.txt后终止该命令；用现有锁定依赖重新测试，无包版本变更。
- isolated-analyze.txt：没有错误/警告，仅一处cascade风格提示，已修正。Python采集/构建/对照脚本语法检查通过。
- 首次构建请求因分析进程尚在运行被memory-gate拒绝，未绕过；分析退出后构建门槛通过（提交余量13.13GiB/物理余量11.75GiB/模拟器0），开始isolated.apk离线缓存构建。
- TCP对照复核：02-candidate有124.7ms、04-control有110.5ms、05-control有122.0ms首帧后的纹理间隔；其余正常对照无≥100ms间隔。不能将整轮描述为所有样本连续帧均无长间隔。详见comparison.json。
- worker稀疏事件目前记录UI isolate收到通知的时间，不冒充socket字节到达的原始时间；性能主指标继续使用原生输入及纹理自身单调时间戳。
- 首次实际编译失败：自动pub步骤重写package_config，将material_ui指到共享缓存未打补丁版本，出现BottomSheetState/IndicatorPainterNotifier等缺失。失败日志isolated-build-failed-unpatched-dependency.log、错误配置isolated-package-config-before-repair.json保留。恢复已存在tmp/patched-deps/material_ui-1.5.0引用，不修改共享缓存；构建脚本增加补丁标识检查和package_config归档。随后重新构建。并非候选播放逻辑编译错误。
- 现有network-07深日志：视频成功响应到下一段探测约42ms，音频成功响应到解码器打开约29ms（均Dart收到日志时间）。尚无“大量时间浪费在流探测”的证据，暂不凭官方选项描述盲改。
- 第05轮构建成功（3分18秒）：isolated.apk，SHA256 b3ce3211cf9016e1efb7297047ba46c7757e08c73752f95040f1a7e0afdaceb5。开关：SOURCE_EARLY_PREPARE、PARALLEL_AUDIO_SOURCE、ISOLATED_MEDIA_SOURCES及相同轻监听；不启用STARTUP_READ_AHEAD/TCP_NODELAY。源码、测试、采集器、包配置均归档isolated.sources.zip。开始第六次AVD会话，参数保持不变。
- 第六次会话isolated-pair-01：00-warmup控制2998.6ms，其中query.primary1625.8ms；01-control在首帧回调后模拟器冻结，最终回收超时，无summary。候选尚未安装，不作候选结论。见hung-emulator6.json；正常关闭超时后仅结束已核对的QEMU77996。主机available约8.7GiB，没有OOM证据。
- 冷启动进一步分层：query.primary.begin到playurl的http.begin达1389.3ms，HTTP本身响应/读完约227.5ms。api.bilibili.com在点击前已有多次成功请求，故“DNS首次解析”不能直接解释此段；需查请求前应用执行/调度。
- 第七次模拟器会话改用 `-gpu swiftshader`，其余AVD、分辨率、清晰度、编译包和数据不变。这是排除反复图形/模拟器冻结的环境实验；所有速度仅与同一新环境内基线比较，绝不与之前host数据混算。参考Android官方故障排查推荐的软件图形回退：https://developer.android.com/studio/run/emulator-troubleshooting 。尚不能据此认定GPU为冻结根因。
- 第7次swiftshader启动器退出；第8次swiftshader详细日志停在图形初始化且ADB未出现；第9次swangle同样未启动完成。第9次QEMU所有线程处于Suspended，Windows同时记录本SDK的crashpad_handler.exe 0x80000003异常。保存emulator7-windows-events.txt、emulator8-abort.json、emulator9-thread-state.json及各启动日志。均无性能样本，不把启动失败算候选回退。
- 第10次恢复host图形，在本次命令加入官方帮助列出的 `-crash-report-mode disabled`，隔离崩溃报告子程序本身异常/悬挂的干扰；不变更全局SDK、AVD数据或系统防护。先验证新候选能连续播放，再开展同会话对照。尚未认定该开关解决冻结。
- 第6次warmup帧时序补证：最大raster1279.687ms、对应total1354.663ms，build73.599ms；绘制长停顿与HTTP发出前等待时间相合。旧“可能DNS慢”已不成立为主解释，继续查首次绘制及UI调度。
- 第10次会话首次候选isolated-first-01完整采集25秒：输入→有效纹理2036.1ms、API276.9ms、open后1725.0ms；仅首段缓冲，纹理持续至20.1秒观测窗口，尚需检查音轨及间隔。视频响应头在open后486.8ms、音频238.7ms，均206，两路已实际并发。该冷会话样本独立保留。随后运行isolated-pair-02预定ABBAAB，不以首次样本定性能结论。
- 第6次失败记录在重启后回收，原3814进程两份日志均为0字节，不能补出有效性能或帧证据；回收文件保留在01-control/recovered-after-reboot。首次手动启动采集遗漏必填serial参数，仅参数检查退出，补齐后才实际采集。
- isolated-pair-02仅完成00-control=1754.6ms/API268.8ms，01-candidate=1496.0ms/API315.8ms，02-candidate=1453.9ms/API316.4ms；03-control再次冻结且最终pull超时。原定ABBAAB未完成，不发布完整对照中位数或稳定增益。新候选的两次视频头均约open后0.5秒，支持继续测试备用线路。
- 第10次冻结仍有4个线程Running，并非软件启动时全部Suspended；崩溃报告关闭未解决播放冻结。见hung-emulator10.json/emulator10-thread-state.json。仅终止确认过的本任务QEMU63080，Gallery仍待本轮测试后恢复。
- 第06轮代码：NetworkSource增加可选videoAlternatives；视频页面仅传入当前同画质同编码轨道的API URL；worker把备选交给运输层。主线路快时不增加下载，慢时最多一个备用连接，首个有效200/完整206响应头胜出并关闭另一连接；两者失败回退原URL。取消同步取消计时器、关闭两个HttpClient并释放等待。
- hedged-tests.txt：26/26通过，新增4项涵盖慢主线路备用胜出且败方断连、快主线路不发备用、无效响应不能胜出/拖延、取消关闭两条待响应连接。静态分析及构建继续进行。
- hedged-analyze.txt：No issues found。hedged.apk构建门槛通过，提交余量17.97GiB/物理13.43GiB/模拟器0。
- 为摆脱37.3.5反复冻结，核查官方repository2-3.xml及版本记录，下载channel-0稳定版37.2.12到tmp/startup-test-emulator-37.2.12，455342868字节/SHA1 488ed747e82de7e9bb5247becd1ac043c7e5e85d与官方相符。见stable-emulator-download.json、fetch-stable-emulator.py。未替换原SDK；Gallery恢复仍使用原来启动路径。后续稳定版组重新建立基线，禁止跨版本混算。
- 采集器增加测量前的宿主QEMU路径、命令及source.properties记录；不会增加输入后的采集负担。第05轮两个常规候选样本无首帧后≥100ms纹理间隔，实际1920×1080；独立首轮存在340.2/102.1/117.4ms间隔，不能忽略。
- 第06轮hedged.apk构建成功2分22秒，SHA256 66c4696c01d95a4af827f663b5d9b219322aa882664d2a8a3567432461dcaaf9，源码/包配置/26测试与采集脚本归档hedged.sources.zip。尚未实测。
- 稳定版第11/12次启动在Windows loader退出0xC0000135，尚未进入Android。只在独立副本内，将同一已校验压缩包的14个根目录/lib64运行库复制到qemu/windows-x86_64相邻目录，避免动态库搜索路径问题；映射见stable-emulator-local-dll-layout.json，无覆盖既有文件。修复后headless QEMU `-version`退出0、37.2.12确认。普通launcher `-version`会走GUI二进制，仍报错，不代表本次无界面运行失败。第13次按相同host参数加show-kernel启动，开始新环境验证。
- 第13次会话hedged-stable-pair-01预热+ABBAAB全部7次完成。对照isolated三次1753.1/1412.5/1601.5ms，候选hedged三次1357.4/1239.7/1346.2ms；中位数1601.5→1346.2ms，约省255.3ms（15.94%）。API中位数304.3→240.8ms，open后中位数1253.4→1033.8ms，故不能把全部255ms都归因备用线路。保留叠加候选，仍未达0.8秒，单视频小样本。
- 02-candidate实际在open后125.6ms启动API备用mcdn，306.2ms收到完整200头并胜出，308ms开始交付；败方被关闭时出现isolated.video.error属于取消的原请求，不是播放失败。后续日志分类应区分该预期取消。
- hedged-seek-return-01：8.020秒发送正常水平拖动，原生纹理PTS由7.47秒跳至33.40秒并继续增长，证明实际执行seek；8.572–10.943秒有约2.37秒寻址缓冲，不能称瞬间恢复。17.018秒返回后两路连接关闭、worker expected=true退出，AudioFlinger活动音轨0。没有发生运输fallback事件，本次主要覆盖缓冲内seek，尚需跨缓冲范围验证。
- hedged-cancel-01：实际0.684秒返回；没有正PTS有效纹理，采集器exit1属本用例预期；两路连接关闭/worker正常退出、AudioFlinger活动音轨0。关闭时delivery.error随取消出现，不能列为未处理播放错误。
- 正在采集hedged-perfetto-01定向系统跟踪，单独诊断剩余取流/解码/提交耗时，不混入速度中位数。所有数据与结论只基于监听，不声称物理屏幕完成时间。

- hedged-far-seek-01：采集器新增通过UI语义SeekBar定位80%位置，实际10.276秒点击（XML采集延后了原7秒计划，保留实际时间），视频与音频均出现seek-or-reopen回退。纹理PTS跳到约596秒并持续至599秒以上；10.438–12.152秒约1.714秒缓冲。18秒返回，两路关闭/worker正常退出，AudioFlinger活动音轨0。覆盖真正跨缓存寻址，不宣称瞬间恢复。
- hedged-perfetto-01：重采样输入到纹理1405.7ms，codec初始化840.1ms开始/72.7ms，configure7.4ms、start45.7ms，首次输入999.2ms、首次释放1281.4ms（间隔282.3ms）。此区间goldfish HEVC线程运行177ms、主线程99ms、raster73ms、DartWorker81ms，多线程有明显Runnable等待；页面/取流CPU竞争是下一步诊断方向，尚未证明单一根因。stage-analysis.sql/txt保留。
- 排除一个假设：当前Dart SDK HttpServer.listen已默认为接受的TCP连接设置tcpNoDelay（http_impl.dart:3561），无需再为loopback重复实现。官方API说明与本地实现一致。

### 第07轮：更早启动同轨道备用请求（准备）
- 保留第06轮全部有效路径；仅将备用启动延时做成显式编译参数，计划120ms与0ms同环境交错比较。仍最多两条同画质同编码视频连接，赢家确定后关闭败方。
- 同时修正预期关闭的事件分类（cancelled/hedge-loser），避免把正常取消误记作真实传输失败；旧包原始日志不改写。
- 后续另测数据转发每块flush的开销，暂不与此轮混改；CPU竞争、画质/持续播放与取消仍需验证。

- 第13次稳定模拟器通过emu kill正常退出，见emulator13-close.json，无强制终止。第07轮27/27测试通过（含0ms同时尝试与败方连接关闭），Dart分析无问题，Python语法检查通过。构建门槛提交余量17.82GiB/物理13.30GiB/模拟器0，正在构建hedge-zero.apk。原120ms行为仍为默认值。

- 第07轮构建成功3分55秒，hedge-zero.apk SHA256 4e76e30cc0140fbce4b77cf50dcf109bade322865a6a53800acb27834f456afc；源码快照hedge-zero.sources.zip。编译开关与hedged相同，仅MEDIA_HEDGE_DELAY_MS=0与预期取消事件分类调整。已释放确认属于本次构建的Gradle6764，启动门槛18.06/13.40GiB通过。第14次稳定版会话参数与第13次相同，准备同会话120ms/0ms ABBAAB。


### 第08轮：去掉新网络源显式start=0（准备，尚未构建/实测）
- 查证当前media_kit _add把非null的Duration.zero转换为loadfile start=0.000；mpv v0.41.0 player/loadfile.c:1775–1783在play_start非空时排队并执行初始seek。与当前trace首次codec输入之前的flush一致，但具体可节省多少尚未知。
- controller.dart新增默认false的OMIT_ZERO_MEDIA_START，仅新网络非直播源且请求精确为零时，传Media.start=null；非零恢复进度/跳片头以及本地文件保持原值。新source.startPosition事件记录requested/native/是否省略，避免凭代码断言运行生效。
- builder新增--omit-zero-start。第07轮当前正在模拟器实测，暂不同时运行编译或Dart测试；下一轮独立对照此改动。每块flush实验继续列为后续候选，不混入本轮。

- 第07轮hedge-zero-pair-01预热+ABBAAB七次全部完成，控制1903.7/1369.1/1272.8ms，0ms候选1323.0/1324.8/1166.4ms；中位数1369.1→1323.0ms（46.1ms），API328.2→292.2ms，open后1014.1→941.1ms（72.9ms）。单视频小样本、波动明显，0ms保留为叠加候选但不称稳定46ms净收益；未达到0.8秒。实际hedge-loser关闭记录分类正常，全部只出现初始缓冲。第14次AVD正常关闭（QEMU62056），见emulator14-close.json。
- 第08轮采集器新增--start-progress-ms，真实URI传指定毫秒进度，默认0与旧对照一致；计划在零定位优化包验证60秒续播，而非仅用单元逻辑判断恢复进度。当前无模拟器，开始格式/分析和构建准备。

- 第07轮连续帧补充：02候选首帧后一次106.1ms间隔，另外两次候选无≥100ms；控制01有144.4/174.9ms、04有170.4ms、05有107.0ms。全部无首帧后buffering不等于全部无帧间隔，详见comparison.json。
- 第08轮controller.dart静态分析No issues found；采集器/构建器语法检查通过。已开始omit-zero.apk构建，叠加第07轮0ms备用、原音视频提前请求与独立worker，其他参数保持。

- 第08轮构建成功2分20秒，omit-zero.apk SHA256 61e215c26836d974415007eee1d246be77bf9014e3850e91df473aefea25f7e1，源码/测试/采集器快照omit-zero.sources.zip。未做速度结论；将与hedge-zero.apk同环境比较。

### 第09轮：持续流转发（准备，独立于省略零定位）
- ParallelAudioSource新增默认false的STREAM_MEDIA_FORWARD。当原生消费者取完整响应时，使用response.addStream及同步map维护256KiB前缀/计数，保留socket背压；不收集整个文件。有限范围探测沿用旧分块flush，seek回退和取消仍使用既有路径。
- 新增64MiB上游/暂停消费者测试，要求传输受到背压、不能把全部响应预读进内存。STREAM_MEDIA_FORWARD=true时18/18测试通过，包括确切字节、首块及时到达、探测前缀/范围回退、超时、关闭与双线路获胜/败方关闭。
- builder新增--stream-forward；下一包不启用OMIT_ZERO_MEDIA_START，避免混淆两个假设。先跑原路径回归/分析，随后构建；模拟器仍关闭。

- 第08轮假设修正：继续追到VideoDetailController.playerInit及BlockMixin.getFirstSegment，常规入口已把零位置转成null。因此省略显式零值对当前fixture很可能无作用，不能把flush归因start=0。本包保留作一次监听确认，不再盲跑整组；源码门控仍默认false，尚无收益可宣称。
- 第09轮原转发路径10/10测试也通过，Dart分析无问题，stream-forward.apk构建成功，SHA256 2243b60da2bb73e9a4f98adc35daebe38c15f93d272b740a8547afc032791985。源码快照stream-forward.sources.zip。此包启用STREAM_MEDIA_FORWARD，不启用省零定位，实测尚未开始。

### 第10轮：完整网络轨道避免EDL分段重置（准备）
- 官方mpv v0.41.0 demux_timeline.c:298–307把普通EDL包标为segmented；f_decoder_wrapper.c:808–815及983–1003在新segment执行reset_decoder。当前输入每轨道都是单一完整URL，无裁剪/时间偏移，额外分段边界可能解释启动flush。
- 官方EDL文档no_clip用于保留原轨道时间戳、不做分段裁剪；它不是可随意用于多分段的通用开关。本轮仅NetworkSource非直播、音视频两条完整http(s)资源，在两个track header都加!no_clip；本地/嵌套EDL/非http保持原拼接。音视频统一缓存与画质/编码保持，新增默认false UNCUT_DASH_TRACKS。
- source.timeline记录实际是否启用。需要系统跟踪确认flush是否消失、连续音视频与跨缓存seek/非零进度回归，不能只凭代码/编译通过接受。此包暂不启用STREAM_MEDIA_FORWARD，分别判断收益。

- 第10轮Dart分析无问题；uncut-dash.apk构建成功1分45秒，SHA256 96e9109cc9d082901779feb21685e7aecd90ddb82d621c233695272df1352ba3，快照uncut-dash.sources.zip。不启用省零定位/持续流转发，分别与hedge-zero基线对照。
- 新增tool/summarize_startup_codec.py：按目标PID、原生输入及Perfetto MONOTONIC时钟快照关联codec阶段，保存SQL/CSV/报告，不覆盖已有分析。用hedged-perfetto-01复核得到输入→释放1281.45ms、queue→release282.255ms，首帧前flush14.467ms；时钟修正仅-18.9微秒，与旧手工计算一致。物理显示仍未覆盖。

- 第08轮omit-zero-confirm-01运行确认requestedMs=null/nativeStartMs=null/omittedZero=false，证明常规入口已省略零值。重采样首帧1893.8ms（冷首轮，不作为速度比较），仍有11.26ms初始flush；不再为此假设跑ABBAAB，候选与原始结果保留，默认不开启。
- 第09轮stream-forward-pair-01预热+ABBAAB七次全部完成：控制1191.6/1362.9/1127.7ms，候选1367.8/1094.6/1205.4ms。中位1191.6→1205.4ms，API275.1→244.1ms，open后902.6→924.2ms；没有提速证据，不将持续流转发升为默认，代码/测试/数据保留。现有音视频提前请求和0ms备用候选不撤销。全部只出现初始缓冲，连续帧间隔另行核对。
- 第15次稳定会话继续测试第10轮hedge-zero vs uncut-dash，前一组已预热，同会话ABBAAB六次，不加入重Perfetto样本。

- 第10轮uncut-dash-pair-01同会话ABBAAB六次全部完成。控制1080.3/1190.4/1361.1ms，候选1100.6/1112.3/1160.0ms；中位1190.424→1112.321ms（78.103ms），API210.938→247.250ms，open后951.729→838.856ms（112.874ms）。保留可叠加候选，单视频小样本未达0.8秒。全部仅初始buffering，但控制两次有155.8/130.6ms连续帧间隔，候选各有151.5、107.9/124.3、181.4ms间隔，不能说完全流畅。输出尺寸日志包含初始化960×540及实际1920×1080，未改变选中清晰度。
- 正在uncut-perfetto-01单独确认启动flush；随后执行非零进度、跨缓存seek与快速返回。修正汇总脚本只收有同目录capture.json的真实采集，排除新增codec-analysis/summary.json派生报告。首次中位数临时命令因Windows路径分隔符过滤为空失败，修正筛选后成功；原始采集无影响。

- uncut-perfetto-01定向跟踪完成，输入→纹理1368.918ms（重采样，不加入中位数）；codec init744.510ms开始/104.555ms、configure15.437ms、start26.271ms、首次queue930.165ms、release1161.187ms，queue→release231.022ms。首帧前flush为0，确认no_clip确实消除了上一候选的初始重置。物理显示仍未知。
- uncut-resume-01在启动采集前被资源门槛拒绝：提交余量8.88GiB、物理5.86GiB（低于6），没有进到播放测试，失败记录保留。宿主QEMU76496私有8.95GiB/驻留6.53GiB，连续多轮后占用明显；不是单纯AVD配置2.5GiB。仅正常关闭本任务AVD（emulator15-close.json），释放后提交17.95GiB/物理13.26GiB，启动门槛通过。第16次相同稳定版会话用于功能回归，不与旧会话混算速度。

### 第11轮：附加页面请求让出起播窗口（准备）
- 当前trace显示标签/相关推荐/简介在播放接口同一时段启动，作者统计在媒体初始化时返回；保留必要简介、弹幕、字幕、用户显式刷新，单独测试延后自动相关推荐/标签/作者统计。
- 新默认false DEFER_VIDEO_AUXILIARY：仅自动播放、已知cid的UGC网络视频，通过frameReady监听释放附加请求；最长1500ms兜底，不让起播失败永远阻塞页面。离开销毁或切换源取消等待，核对cid/bvid防止旧请求发出。暂停/本地/PGC直接沿用原路径，用户主动刷新和主动获取下一推荐沿用原路径。
- StartupAuxiliaryGate管理监听/计时器，在释放/取消/流关闭后清理；新增5项测试覆盖就绪、已就绪、失败超时、批量取消后新源及流关闭，尚未运行（当前模拟器正在回归，避免同时编译）。构建器加入--defer-auxiliary及新源码/测试快照。
- uncut-resume-02（第16次会话）已完成：指定60秒，首个纹理PTS精确60.000秒并继续；输入到有效纹理4699.5ms，非零进度不走提前取流，不加入零起播性能统计。仍需和基线非零进度对比检查异常等待，不能只报功能通过。

- 第11轮资料取舍：mpv官方video-latency-hacks说明可能降低1–2帧等待，但会破坏插帧等选项，不作为通用默认；本轮优先处理实际观测到的并发页面任务。https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/DOCS/man/options.rst （1104–1121）。FFmpeg当前MediaCodec实现只暴露delay_flush/ndk_codec/operating_rate，未找到可直接可靠传入的通用low-latency选项，不凭Android API存在就盲设。https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/mediacodecdec.c （558–564）。
- uncut-far-seek-01操作无效：XML耗时超过控件3秒可见窗口，定位到[0,663][1080,671]的8px只读细进度条；点击后PTS仍16–17秒，无fallback，不计跨缓存seek通过。后续采集必须排除此只读条，并延长测试AVD的控件显示设置/恢复；原始失败证据保留。20秒返回晚于20秒监听窗口，缺乏关闭事件，只能确认AudioFlinger0活动，不据此宣称worker回收。
- uncut-cancel-01约0.65秒返回，无有效纹理（exit1预期），记录到isolated.video.closed/audio.closed/isolated.closed；进一步核对worker expected及音轨。正在用hedge-zero-resume-01对照非零续播4.7秒现象。

- hedge-zero-resume-01同会话对照：60秒续播输入→纹理4493.5ms（uncut4699.5ms），两者都在初次buffering结束后约3秒才消费纹理，说明4秒级续播等待并非no_clip独有；仍列为未解决问题，不混入零位置速度收益。需后续定向诊断，单次差206ms不足以定性回退。
- 通过实际设置界面的语义节点，确认测试AVD“延长播放控件显示时间”原false，临时改true（30秒）以可靠定位交互进度条；before/after XML及restore.json在control-settings。只影响回归操作窗口，速度对照前恢复false。采集器排除高度<20px只读进度条；正在uncut-far-seek-02重测。导航临时脚本首次遗漏json import，仅本地输出失败，读取已保存XML后继续，无重复操作。
- uncut-far-seek-02有效回归：实际8.375秒点击交互条[53,497][1028,534]的80%，两路seek-or-reopen回退，11.330秒首次采到PTS597.05秒，随后增长到603.73秒；8.477–10.168秒约1.691秒buffering，18.023秒返回后两路closed及worker expected=true、活动音轨0。初次far-seek-01仍保留为无效操作，不覆盖。
- uncut-cancel-01实际0.667秒返回，无码后正纹理，双方closed及worker expected=true、AudioFlinger活动音轨0。测试AVD延长控件设置已按语义Switch核对恢复false（control-settings/restore.json及restore XML）。第16次模拟器正常关闭，开始第11轮静态分析/测试/构建。

- 第11轮5/5门控测试通过，6文件Dart分析No issues found，Python语法检查通过。auxiliary.apk构建门槛提交18.04GiB/物理13.36GiB通过，构建中；其快照完成前不修改入包源码。
- 后续线索：uncut-dash-pair-01/02-candidate视频头open后136.4ms，音频头273.6ms；uncut-perfetto-01视频头150.2ms，音频264.9ms。视频已有备用竞速，音频尚无，可能仍多等约100–140ms；下一轮可在同一选定音轨的API备用URL上复用有界竞速，不能改音质/使用别的音轨。先实测而非把这段差直接当收益。
- 排除重复调参：mpv v0.41.0 demux_lavf.c:167已给MP4设置skipinfo=true，正常auto不会做昂贵find_stream_info；当前无显式覆盖，不再盲测全局关闭探测。https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/demux/demux_lavf.c

- 第11轮auxiliary.apk构建成功3分47秒，SHA256 a3b6eccfaaa2eaf2f36f08403e09f85a4ae6980de5d59fccab41029d783fb9aa，快照auxiliary.sources.zip。保留与uncut对照，尚未实测。

### 第12轮：选定音轨备用线路（准备）
- HEDGE_AUDIO_SOURCE默认false。NetworkSource/worker消息新增audioAlternatives；仅实际音频URL与当前API某条音轨的既有选择相同、没有指定CDN host时提供该音轨备用URL。音质/编码/音轨不变，手改URL不匹配则不竞速。每轨最多一个备用，沿用获胜后关闭败方、取消/超时/seek回退；最多视频2+音频2个初始请求。
- worker音频使用同一MEDIA_HEDGE_DELAY_MS，计划本轮0ms；构建器新增--hedge-audio并要求isolated-media。此包叠加uncut与视频0ms竞速，但暂不启用第11轮附加请求门控，分别对照决定是否叠加。
- 新增worker集成测试：音频主连接悬挂、备选返回精确音频字节；视频字节仍来自原轨，音频败方连接关闭、不触发视频额外备用、无错误事件。与既有5项竞速/3项worker回归一起测试中。

- 第12轮9/9测试通过（worker4项、竞速5项），Dart分析No issues found，Python语法检查通过。audio-hedged.apk构建门槛提交16.69GiB/物理11.76GiB通过，正在构建；auxiliary.apk独立保留。
- 连续播放证据边界补充：采集进程通常25秒，但当前应用事件监听约20秒后结束；连续纹理证据以summary.lastTextureConsumedAfterInputMs实际值为准，不能把采集进程时长直接当作已观察的视频帧时长。后续长播放验收需明确延长监听窗口。far-seek-02/取消均在有效窗口内回收。
- 第12轮audio-hedged.apk构建成功1分42秒，SHA256 da69fb247ac0fcb45bcd69e84f981cf7958771f8342ab1e3b2ea00dfa4191813，快照audio-hedged.sources.zip。与第11轮包分开、附加请求门控不启用，尚无速度结论。
- 确认Gradle58264最后命令currentDir为本仓库且已completed后释放；启动门槛提交18.11GiB/物理13.12GiB通过。第17次稳定版会话启动，计划先uncut与auxiliary预热+ABBAAB，随后检查资源再决定新会话音频竞速对照。
- 汇总脚本补充revealReadyMs（ui.frameReady.after）及两项就绪条件的较晚值presentationPrerequisitesMs，保留原textureMs用于旧轮匹配，不改变物理显示未知的边界。仅离线派生分析，不改正在采集的应用/操作时序。较晚值仍不是屏幕present证据。
- 音视频头事件差的解释边界：isolated.*由worker发到主isolate后记时，属于父isolate收到通知的时刻，并非socket自身的硬时间戳；观察到音频通知晚110–140ms只是实验线索，不能先断言都是CDN耗时或可全部省掉。最终仍按同条件原生输入/纹理、接口及阶段结果判断。

- 第11轮auxiliary-pair-01预热+ABBAAB全部7次完成：控制1548.9/1249.1/1201.9ms，候选1163.8/1147.5/1280.5ms；中位1249.086→1163.811ms（85.275ms）。API中位315.005→223.811ms，open后924.436→1010.352ms，后半段没有改善；不能把总体差归因纯媒体提速。两项呈现前置条件较晚值中位1249.086→1201.941ms（仅47.145ms），未达0.8秒。保留附加请求候选以待叠加，多视频/复测仍需做。
- 02候选标签/相关/作者分别在12.82/19.37/233.16ms等待，frameReady1185.17ms，1185–1187ms按ready释放，实际三类HTTP在1204–1209ms发起并于1279–1382ms完成；证明没有删除这些功能。final-page.xml在整组结束后确认作者名/粉丝数/视频数、标题与相关推荐语义内容已显示，不参与速度计时。
- 连续帧：控制04有249.8/769.9ms间隔，其他控制无≥100ms；候选02一次106.2ms，03/06无≥100ms；全部仅初始buffering。仍不能把无buffering等同零卡顿。现在auxiliary-cancel-01验证快速离开取消等待/连接回收。
- auxiliary-cancel-01实际0.667秒返回，tags/related/author三项等待均以cancelled/current=false释放，未发出相应三类HTTP；音视频连接closed、worker expected=true、活动音轨0，无有效纹理（采集exit1预期）。第11轮功能恢复与取消均有监听证据。
- 第17次QEMU6752正常关闭（emulator17-close.json），第18次相同稳定版环境用于第12轮独立对照，避免累积宿主占用跨多组污染；不合并第17/18次会话的绝对速度。启动门槛再次通过，Gallery仍待恢复。

### 第13轮：已知cid入口优先获取播放地址（准备）
- 当前HTTP/1.1默认连接池15秒保活；多个样本简介HTTP略早于播放地址发起。可能是并发请求/连接及解析竞争，尚未证明复用了哪条socket。本轮只安排优先次序，不全局更换HTTP版本或修改认证。
- 新默认false PRIORITIZE_PLAY_URL：自动播放、已知cid、UGC网络源的简介请求，监听primary URL请求结束后再启动，最多500ms兜底。cid未知/本地/PGC/暂停直接原路径，避免阻塞获取cid、番剧和手动浏览。播放地址失败也释放简介；切源/销毁取消等待并检查cid/bvid，沿用已测试监听门控。
- 计划独立于音频竞速看效果，再组合。当前第12轮仍在模拟器实测，所以这里只改默认关闭的源码，不同时跑编译/分析。将记录新包快照和具体开关，不把准备代码当结果。
- 第12轮前两次候选确认音频备用真正获胜：02在open后134.9ms收到mcdn头、135.3ms选中，03为206.7/206.9ms；原upos请求按hedge-loser取消。仍需完整ABBAAB判断整体收益，不能因备用获胜就宣称提速。
- 为避免重复手工导航/误点只读进度条，新增tool/set_startup_controls_visibility.py：先核对唯一指定QA AVD，测量之外启动应用，通过实际语义节点切换30秒控件显示，保存每步XML与before/requested/verified JSON，限定滚动次数。脚本语法通过；尚未运行，不作为功能测试通过。每次启用后须用新输出目录恢复false并验证，不能保留到速度比较。

- 第12轮audio-hedged-pair-01预热+ABBAAB全部完成：控制1538.7/1258.1/1288.4ms，候选1187.4/1295.2/1347.1ms；中位1288.361→1295.242ms（没有整体提速），API253.669→264.956ms，open后1004.232→988.502ms（仅15.73ms差，噪声内）。两项呈现前置条件较晚值1288.361→1308.491ms。保留实验代码/包/数据，不能把备用音频抢先响应当作已确认的起播收益；不升默认。
- 全部仅初始buffering；候选02无≥100ms后续间隔，03有202.5/110.0ms，06有115.4ms；控制04有110.0/119.0/101.2ms，另两控制无。准备音频备用跨缓存seek/取消回归，以便后续组合实验可复用验证过的路径。
- 下一步第13轮独立测试播放地址优先（叠加已保留auxiliary），另备全组合包加入音频备用，检验相互影响；不把不同包/不同会话的最佳样本拼作达标结果。
- 设置持久性发现：audio-controls-enable读到原值true，和第16次restore-09.xml当时显示false不一致。此前UI检查只能证明当时状态，不能证明重启后已持久保存；现更正这点，不覆盖旧记录。第17/18次速度组内均未切换该项，且计时不显示控件，但跨会话不据此做绝对对比。可能是立即退出模拟器前guest文件页未刷盘，尚未证明根因。
- 设置脚本新增adb shell sync，后续恢复false后再次冷启应用读取核对，并在关闭AVD前同步文件系统。当前保持30秒供第12轮远距离seek回归，恢复仍待办。

- 第12轮audio-hedged-far-seek-01：实际9.096秒点击80%交互进度条，10.999秒采到PTS597.117秒并继续增长；两路seek-or-reopen，9.218–10.795秒缓冲约1.578秒，18.019秒返回后两路closed/worker expected=true/活动音轨0。
- audio-hedged-cancel-01实际0.669秒返回，未消费有效正时间戳纹理（exit1预期）；双方closed及worker expected=true，AudioFlinger活动音轨0。音频备用回归通过，起播整体提速仍未证实。
- 控件设置恢复：audio-controls-restore显示true→false并sync；audio-controls-verify冷启应用后before=false/verified=true并再次sync。模拟器跨重启持久性待下一会话复核，保留旧UI-only恢复记录及更正，不掩盖不一致。
- 监听指标边界复核：现有postStartGapsOver100Ms来自相邻texture consumed回调间隔；回调可能重复同一timestamp，因此此前“连续帧间隔”应精确读作“纹理消费回调间隔”，不能保证新视频帧持续更新。当前probe有累计changedTimestampFrames，但稀疏采样不能恢复每个新帧间隔。后续持续播放验证需要补充原生不同正时间戳的间隔统计；本轮性能对照暂不改probe以保持同等监听开销。

- 第18次QEMU75112已在guest sync后正常退出，emulator18-close.json保存内存/命令/退出证据。第13轮4文件Dart分析No issues found，门控5/5测试通过，Python语法通过；开始url-priority.apk构建，监听实现保持与auxiliary.apk相同。

- 第13轮url-priority.apk构建成功，SHA256 7420464ed17036d1361825d725d3a2f0dbfe3bd46c70af41c79b6ff23daa8d99；sources.zip和build.json记录完整开关/源码哈希。继续构建同源码stacked.apk，唯一额外开关HEDGE_AUDIO_SOURCE=true，用来测试组合。

- 第13轮主包耗时3分22秒。组合stacked.apk构建成功，SHA256 81f84e656a7842b6fe4c6f0088e7ca500e0dff241253cdbe06355536f56a1e0b，与url-priority同源码及监听，额外音频备用开关。当前两包尚待实测。

- stacked.apk耗时1分43秒。本次Gradle30016确认仓库内构建完成后释放；启动门槛提交17.97GiB/物理13.04GiB通过。第19次launcher72384/QEMU75908稳定版启动成功；session19-controls-verify确认AVD跨重启before=false，设置恢复的持久性现有证据。开始auxiliary vs url-priority预热+ABBAAB，期间无其它ADB/编译。

### 持续播放补充观测（独立诊断，尚未构建）
- 不改正在运行的第13轮APK。新增默认关闭PLAYBACK_TRACE_CONTINUITY，以及默认20秒、可编译设为60秒的监听时长。独立--continuity-trace包统计不同正texture timestamp之间的消费间隔与旧timestamp重复年龄；按源上下文重置，保留上一timestamp防止复用旧图被当新帧。
- 只在首次长重复、恢复更新的长间隔或原500ms节流条件下输出，避免重复帧每回调刷JSON。暂停/seek可能正常造成长间隔，分析必须和操作事件对齐，不能一律称卡顿；这仍不是物理显示证据。
- 目的为修补既有callbackGap无法识别重复旧视频图像的缺口，单独用于长播放回归，不拿其重采样速度与旧包对比。当前源码未分析/编译；正在第13轮对照，不同时启动编译器。

- 第13轮中途发现采集关联错误：同一AVD多次重启后Android PID复用，旧采集器按PID拉取全部历史文件，01-control/02-candidate各混入旧native/flutter一对，造成重复primary/open及02的负afterOpen。原始日志不覆盖，不使用当前自动results作结论；完成本组后按当前logcat启动时间和文件UTC代次筛选，保留单独重算报告并修采集器。全量目录初审目前只有本组两次受影响，后续样本完成后重审。
- 另已发现辅助请求组部分样本累计changedTimestampFrames持续不变超过500ms，证实回调间隔指标不够。因该组控制也有同类停留，不能直接归因辅助延后；后续必须使用新帧时间戳指标和相同版本独立长播放回归。此项与PID复用分别记录。

- 第13轮全组结束后的审计：01-control/02-candidate/04-control共3次混入历史PID日志，其他历史组未发现多代文件；每次当前logcat同时宣布精确native/flutter文件名，UTC代次一致。原始summary/capture/results和所有日志保留；generation-audit保存筛选依据/哈希及重算summary，process-generation-audit-v2.json汇总。后续采集只拉本次明确宣布的文件，缺失/混代直接失败；4项回归通过，汇总只读已验证文件。
- 重算第13轮url-priority-pair-01：控制1062.214/1132.248/1233.503ms，候选1166.925/1014.888/1145.472ms；中位1132.248→1145.472ms，无整体提速。API188.245→175.411ms（约12.834ms），open后917.586→922.525ms；呈现前置条件1132.248→1157.290ms，未达0.8秒。保留独立开关/记录，暂不升默认。
- 03候选证明门控按设计执行：主接口结束173.811ms后，intro在175.037ms以ready释放，实际简介HTTP218.548ms发起；related/tags/author在frameReady后恢复。数字相对query.primary.begin，不是输入。准备0.15秒返回检验主接口未结束时取消，再独立测stacked组合。

- url-priority-cancel-01实际发返回0.171秒，但简介等待在主接口约0.172秒完成后已ready释放；不能把这次称为“主接口等待中取消”的运行证明。related/tags/author三等待cancelled/current=false，未消费正纹理，音视频closed/worker expected=true/活动音轨0；快速返回资源回收通过。新采集器只拉当前两份明确宣布文件，summary带traceFiles，未混代。
- 第19次末资源提交余量11.14GiB/物理7.06GiB；为避免多组累积占用，第19次QEMU75908在sync后正常关闭，emulator19-close.json。下一次同配置新会话比较url-priority与stacked，不能跨会话绝对速度相减。

- 持续播放诊断Dart分析No issues found，Python采集/汇总/构建语法通过；uncut-continuity.apk开始构建，门槛提交18.04GiB/物理13.28GiB。不含附加请求/优先URL/音频备用，用保留uncut基线检查新时间戳统计。其60秒窗口及额外事件不混入起播对照。
- 取消事件复核：url-priority-cancel-01首次route.leave比onClose约早286ms，现有门控直到onClose才取消；期间已在途简介可能继续触发作者门控。无持续泄漏，但未来保留候选时应在确定didPop永久退出时提前取消门控，并防止退出期间新等待；临时覆盖后返回要保留数据恢复，不能直接把所有route.leave都当永久销毁。此轮尚未改该逻辑。

- uncut-continuity.apk构建成功5分28秒（含Kotlin编译），SHA256 e6b32699b1790aaf56ab3904e6c831b72547ac396f6354be6281c9a671a78cd1，源码快照/开关已保存。新增离线summarize_startup_continuity.py只匹配当前请求/player/texture，输出新正时间戳间隔及操作标注，语法通过，尚未实跑。

### 提前取消修正（准备，未进入现有测试包）
- didPop已确定永久退出时，leavePlaybackRoute(permanently:true)立即关闭附加请求门控，并阻止退出动画期间新建等待；等待结果也检查永久退出标记。普通临时覆盖仍用原调用，不把临时覆盖误当永久销毁。
- 依据是取消日志中首次route.leave与onClose相差约286ms。当前仅源码修改，待本组完成后分析/构建/回归；url-priority.apk、stacked.apk和uncut-continuity.apk均为此前已保存版本，不把此修改算作它们的测试结果。构建快照新增view.dart及离线连续性汇总工具。
- Gradle77756已确认本仓库构建完成后释放；第20次启动门槛17.09/12.57GiB通过，launcher21592稳定版启动中。

- 第20次QEMU73940组内控制url-priority/候选stacked，host-tools保存实际采集脚本版本。前三次正式样本仍只作过程数据，未提前宣布收益；本组06结束后统一中位数和新旧时间戳关联检查。

- 第20次stacked-pair-01全部7次完成：控制1172.835/1007.322/966.466ms，候选1119.996/959.758/899.909ms；首纹理中位1007.322→959.758ms（47.565ms），API139.835→143.544ms，open后838.396→771.882ms（66.513ms）。但封面解除中位991.661→1113.469ms，两呈现前置条件中位1007.322→1113.469ms，不能判整体观看体验提升。保留组合取流候选与全部结果，不把最佳0.900秒称达标。
- 全部仅初始buffering；候选03有100.9/299.2/102.5ms回调间隔，06有315.5ms，控制也有约365–446ms间隔。原生实际解码尺寸均1920×1080（另含初始化960×540），无清晰度降级。final-page.xml保存功能恢复语义；新采集关联排除了旧PID文件，host-tools可复查。
- 末资源提交10.52GiB/物理7.35GiB通过采集门槛，安装独立uncut-continuity包，计划60秒监听、55秒返回并单独8秒Perfetto，用于定位新帧停留/观察覆盖/回收，不加入性能中位数。

- uncut-long-01独立60秒采集完成，实际不同视频timestamp观察1.339–54.963秒，1510次正timestamp更新；55.021秒返回，两路closed、worker expected=true、活动音轨0。原生观察未丢记录，物理呈现仍未知。traceEnded=false因为再次arm延长窗口而拉日志时未到最终关闭，并非把采集时长冒充播放证据。
- 新监听确认输入1.373–2.498秒有1125.036ms无新视频timestamp；期间无暂停/seek/返回且buffering一直false。旧callback最大仅527.947ms，确实漏掉重复图像停留。另有约100–150ms六个更新间隔，见continuity-analysis/summary.json。
- 同时Perfetto：首次codec输入990.386ms/输出释放1224.401ms，no_clip仍无初始flush；输入队列1326.577→2430.175ms中断，输出释放1362.084→2477.505ms中断，和纹理停留对应。因此问题已经在播放器/解码输入输出前发生，不能只归因Flutter封面。两线程多次短睡眠，未见单个>20ms应用slice阻塞；freeze-analysis保存SQL/CSV。继续查取流/音画时钟，尚无根因结论。
- 第20次QEMU73940正常sync关闭，emulator20-close.json。Gallery仍待最终恢复。当前所有实验包未达0.8秒，组合取流线索保留但呈现等待和起播后停留未解决。

### 第14轮：启动后长停留与音画时钟（准备）
- 明确观察到native输入与输出同步停约1.1秒，两个线程反复短睡眠；不是仅Flutter回调稀疏。Pref.autosync在Android默认30，videoSync默认audio。mpv官方说明autosync30处理较大音画偏差可需1–2秒，源码update_avsync_before_frame按预测与音频报告差做平滑；这是可测试线索，不是已确认根因。
- 新STARTUP_AUTOSYNC_ZERO默认false，仅Android实验包选用mpv不平滑的音频延迟计时；不改用户保存设置、不改videoSync/音轨/清晰度、不用desync/untimed。增加startup.sync.options记录原设置和有效值（若日志未记录不能假称实际设置已确认）。
- 将构建同源码sync-control与sync-zero（都开60秒连续监听），保留uncut/videohedge0/worker/early，不混附加请求等候选，先看首帧后长停留和音画同步；如果恶化则保留记录关闭实验开关。两包同时包含提前永久退出取消修正，需取消回归。
- 来源：https://mpv.io/manual/stable/#options-autosync ；https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/player/video.c （update_avsync_before_frame）。

- 第14轮3文件Dart分析通过；新增实际mpv options/autosync及options/video-sync读取标记，再次单文件分析通过后构建。候选显式传autosync=0而不是依赖默认省略，用户持久设置保持原值。两包包含相同标记/监听与永久退出取消修正。

- sync-control.apk构建成功2分18秒，SHA256 b591c5594470202169a6792bb7356b8ccc93277256cf787ff787552cbb573b66。相同源码sync-zero.apk正在构建，唯一额外STARTUP_AUTOSYNC_ZERO=true；实际参数读取标记两包都有。

- sync-zero.apk构建成功1分43秒，SHA256 ad32323bc7ca09a24d72741b9d840bc25ef9e6d95fa12424b33a0512b08c45d2。与sync-control同源码/60秒观察设置，只额外autosync0；进入第21次稳定会话对照，不引用旧轻监听包绝对时间作效果。

- 第21次sync-zero-pair-01预热完成，但01-control没有任何原生input.touch/播放query/source.open，仍停在搜索页，组自动停止。已保存failure-page.xml及power/window信息：文字完整、搜索按钮[928,74][1054,200]覆盖测量点，Awake且焦点在本应用，资源12.19/9.60GiB通过。点击为何未被应用收到尚不明，不把这次算网络/播放器慢或静默补成功。
- 该样本启动记录已确认实际autosync=30、videoSync=audio，与项目默认一致。原失败组完整保留，重跑新目录sync-zero-pair-02的完整ABBAAB（第21次已预热，不重复预热），继续使用相同安装包和监听。

- sync-zero-pair-02/00-control再次无source/input，保留失败原始记录。测量结束后，显式input touchscreen tap同一点能进入目标视频，explicit-touch-page.xml含BV15BJX6dEoR/进度条/详情；这是诊断操作，不补算有效性能样本。此前打印诊断时遗漏json导入，XML已成功保存，输出异常不影响其原始内容。
- 采集器仅将测量输入显式指定touchscreen，并保存命令/退出码/stdout/stderr；仍必须有原生ACTION_DOWN和当前CID source-open才算有效，不以shell成功替代事件。默认input tap与显式source按Android设计应等价，当前尚不能断言根因；先独立试采，成功后新目录完整同条件ABBAAB，失败则进一步定位输入分发。

- sync-input-pilot-01显式触摸试采有效：native ACTION_DOWN/当前CID/source/texture均通过，首纹理1131.957ms，命令返回0且stderr为空；只作输入可用性验证，不纳入正式ABBAAB。第一次启动命令缺--serial，在参数解析阶段退出且未操作设备，补齐后使用上述新目录。
- 开始sync-zero-pair-03完整ABBAAB，两包同一显式touchscreen输入/60秒连续性监听开关；保存host-tools快照。候选尚未完成对照，不能预判autosync是根因。

- 第14轮sync-zero-pair-03六次正式样本完成：autosync30控制首纹理1250.562/1221.607/1150.477ms；autosync0候选1090.935/1179.596/1168.957ms。中位1221.607→1168.957ms（52.651ms），呈现前置条件1221.607→1170.949ms。各自实际mpv参数均已读取确认，均无丢原生记录。comparison-reviewed.json及逐样本continuity-analysis可复查。
- 起播后最长新timestamp间隔控制988.142/1006.311/730.023ms，候选1149.014/1105.087/1132.642ms，中位988.142→1132.642ms；关闭autosync没有解决长停留，反而此指标更差。保留独立开关及约53ms首纹理线索，不升默认、不宣称整体成功，不因未达0.8撤销其他取流改进。

### 第15轮：音频输出与正文传输进度（准备）
- 继续查mpv官方AudioTrack/AAudio源码。同步平滑不是长停留的充分解释，下一轮单独比较AAudio优先与现有AudioTrack优先，保留fallback和用户设置，实际current-ao必须监听确认。来源：https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/audio/out/ao_audiotrack.c 及 https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/audio/out/ao_aaudio.c 。
- 新STARTUP_AAUDIO_FIRST默认false，仅实验改输出优先顺序。新增STARTUP_TRANSFER_TRACE默认false，两个对照包共同启用：正文数据到达事件前8秒/每100ms至多一次，保存worker自身UTC/相对时间、received与此前delivered计数；依赖已有position监听前8秒/每100ms至多一次读取current-ao/audio-pts/avsync/cache-duration。不增播放控制或图像识别，不把父isolate收信时间当网络到达时间。
- 本轮autosync保留原设置30，只改变输出后端，新的额外监听不与第14轮绝对速度直接相减。源码尚待分析/构建，准备正常关闭第21次模拟器释放构建资源。

- 第21次QEMU76552在guest sync后正常退出，emulator21-close.json；无模拟器时进行分析/测试。第15轮两文件Dart分析No issues found；显式开启STARTUP_TRANSFER_TRACE运行并行取流/worker测试14项全部通过（含seek绕过阻塞、消费者背压、关闭回收），transfer-trace-tests.txt保留输出。
- 开始ao-control.apk构建：原autosync30、原AudioTrack优先、uncut/videohedge0/worker/early，额外60秒连续监听+transfer trace。候选同源码aaudio-first，保持单因素。

- ao-control.apk构建成功2分20秒，SHA256 49a12c0863115dacf94b3fe2d6c4fc34c59e99ad1be975dff907382be5219a06；build.json/sources.zip已保存。开始同源码aaudio-first.apk，唯一额外STARTUP_AAUDIO_FIRST。

- aaudio-first.apk成功1分44秒，SHA25615ddd1ee6ff5498bbd9479b2a0caefa1d11a5da8f30dded576410ed0477e27ae，与ao-control源码哈希相同，仅后端优先开关差异。Gradle78260确认完成后释放；第22次launcher24108，门槛17.14/12.59GiB通过。首次50秒有界boot等待未就绪，内核日志持续推进至59秒，保留日志继续检查，不记作应用性能失败。

- 第22次boot最终sys.boot_completed=1，aaudio-pair-01预热+ABBAAB开始；host-tools保存实际采集与新增离线transport汇总工具/哈希。
- 预热00-warmup（不纳正式速度）出现关键线索：2.150秒position监听读到currentAo=audiotrack/audioPts=-1.033977/avsync=-1.137686，cacheDuration=9.258667秒；期间两路worker正文byte计数持续增长。随后约3.208秒position推进到166ms。表明本样本冻结期间已有多秒解复用缓存，不宜再归因整体未收到媒体。正式样本继续复核，尚不能仅凭预热认定根因。
- 新离线summarize_startup_transport.py按当前源CID/request和已确认日志代次匹配，保存worker到达时间与parent收信分开、位置事件和音频属性、UTC偏移波动及工具SHA256，结果在transport-analysis。它不修改APK/设备；收到字节不等于解码器消费，音频属性不等于扬声器实际输出。

- 第15轮前两候选均实际currentAo=aaudio：02最长新timestamp间隔153.007ms、音频PTS最低0.027472/avsync最低-0.084052；03最长148.883ms、PTS最低0.008021/avsync最低-0.131094。对照01仍976.554ms停留，同时PTS=-1.070006/avsync=-1.169551且缓存3.648秒；04/05最长1139.512/700.195ms。尚待最后候选，全组再出中位数；不把预热混入。
- 为音频后端回归，采集器新增显式成对pause-after/resume-after，发送Android媒体暂停/继续键并记录实际发送时间；参数检查顺序/结束与返回边界。不开参数不变现有ABBAAB流程，当前正在运行的进程使用旧加载脚本。媒体键是否真的触发必须回看command.pause/play和纹理，不能用发送成功替代功能验证。回归前保存新host工具快照。

- 第15轮完整aaudio-pair-01：控制AudioTrack首纹理1379.686/1065.709/1122.123ms，候选AAudio1275.571/1154.236/1182.648ms；中位1122.123→1182.648ms，呈现前置条件同样1122.123→1182.648，首帧没有提升（API中位284.840→306.147，open后849.534→869.440）。不把连续播放改善写成首帧加速。
- 持续性则稳定改善：控制最长新timestamp间隔976.554/1139.512/700.195ms，候选153.007/148.883/138.435ms，中位976.554→148.883ms。所有实际后端确认，候选音频PTS初始最小均为正，avsync最低-0.084/-0.131/-0.098秒。control04在position停发期间没有音频属性样本，不能补写负1秒值；control01实际捕获负1秒和多秒缓存。完整comparison-reviewed.json与原始/transport/continuity报告保留。
- 本轮证明当前模拟器上后端选择会显著影响起播后的长停留，不代表所有设备或真实扬声器音画同步已验收。保留AAudio候选，继续远距离seek/暂停恢复/返回，之后可与取流候选组合。

- aaudio-seek-resume-01失败：9.017秒请求显示控件，13.046秒实际点击80%进度条[53,497][1028,534]；18.019/20.018秒发送媒体暂停/继续，50.014秒返回命令超时45秒，随后ls采集也超时45秒。没有拉回app日志，不能声称seek或pause/resume通过。末资源提交余量10.192GiB/物理7.082GiB，未触碰停止门槛。
- 独立8秒探测guest shell echo与emu avd name均超时，responsiveness.json保留。先做恢复后再取回当前PID6341已宣布的原始文件，检查实际最后帧/命令时间；现阶段不能把整机失联直接等同AAudio特定已知bug。计划同配置独立control回归、分离seek与pause，以缩小触发范围。
- 读取capture.json第一次因默认GBK失败，改显式UTF-8后成功；首次失败在任何设备命令之前，不改变测试样本。

- 第22次QEMU47692的sync/正常关闭各8秒均超时，仅终止已验证的该测试QEMU进程，未清空AVD；emulator22-close.json。第23次launcher60312启动门槛17.28/12.78GiB通过，boot等待后恢复成功。
- 原失败样本PID6341日志已按故障前logcat宣布的精确文件名取回，保存recovery/app原文件及哈希；两文件各有且只有末行不完整。保留原件，仅在recovery/validated-prefix去除不完整末行，truncation-audit.json记录行号/哈希；不掩盖原capture失败。
- 部分恢复证据：实际13.046秒seek后14.581秒新PTS596.916688且继续增长；18.152秒观察到pause，约20.217秒恢复新PTS600.416688，持续到27.496秒/PTS607.733313。故不能把这次描述为seek立即永久冻结；失联发生在恢复后，50秒返回无证据、整体55秒回归未通过。
- 修正离线连续性报告操作标注：原脚本只判断pause/seek瞬间是否落在gap中，会漏掉暂停后仍输出最后一帧再停住的正常间隔。现按已观察command.pause→下一个command.play区间及media.buffering区间标注；不改原报告，新增continuity-analysis-v2并标partialRecovery=true。2.003秒间隔因此正确归为暂停期间，1.428秒seek恢复间隔标为缓冲期间，均不冒充无操作卡顿。
- 第23次安装ao-control后开始同样55秒/seek9/暂停18/继续20/返回50的对照回归ao-control-seek-resume-01；此时延长控件设置仍true，结束必须恢复false并冷启验证。

- 第23次ao-control-seek-resume-01完整55秒采集成功：实际13.955秒seek、18.018秒暂停键、20.020秒继续键、50.018秒返回；原生纹理持续至50.036秒，观察到pause/play，返回后音视频closed、worker expected=true、AudioFlinger活动音轨0。actualAo=audiotrack。报告在continuity-analysis/transport-analysis。该运行不能单独排除AAudio相关问题，因此接着同会话安装AAudio重复相同操作。
- aaudio-seek-resume-02正在运行（exec94101），原失败01及其raw/recovery/validated-prefix/v2分析均保留，不覆盖。延长控件设置仍true，完成后恢复false并冷启验证。前两包源码未变，当前只修改了离线分析及测试工具。

- aaudio-seek-resume-02完整55秒操作完成，实际12.289秒seek、18.015秒暂停、20.018秒继续、50.018秒返回。第一轮拉取native末行正在写入，parseErrors=末行172，但旧采集器错误地仍返回0。未直接接受该结果：同会话同精确文件名重新拉取到stable-repull，原文件均为新文件字节前缀，hash-audit.json证实原件未被替换/拼接；完整重取parseErrors=[]、traceEnded=true。
- stable-repull证实actualAo=aaudio，音频初期PTS最低0.040978/avsync最低-0.072437；13.904秒消费PTS596.916688，seek缓冲约1.515秒，18.251–20.298约2.047秒间隔属于主动暂停；此后持续更新至49.717秒。返回后音视频closed、worker expected=true、原采集时AudioFlinger活动音轨0。当前这一轮seek/暂停恢复/返回回收通过；前一次27秒后模拟器失联仍保留为未解释环境失败，不能抹掉。
- 修正采集器接受门槛：出现parseErrors即把不完整/损坏日志列入errors并返回失败，要求保留原件后重取核验，不再把解析缺口默认为成功。此为工具问题，未改变测试APK。
- 下一步恢复延长控件false并冷启核对，再补另一视频/快速返回，随后正常关闭测试AVD构建AAudio与此前取流组合的同监听对照。首帧0.8尚未完成，持续目标保持active。

- 设置恢复首次aaudio-controls-restore在am force-stop超时12秒；第二次restore-02返回exit20，均未到设置修改步骤。随后shell echo和直接TCP5554控制台能响应，说明这次不等同QEMU完全无响应。保留failure-responsiveness.json。
- 取回emulator23-watchdog/crash.txt/system.txt（dropbox输出0字节，无该项可读证据）。system日志7048起明确Watchdog因AMS/display/animation/ActivityManager阻塞62秒杀死system_server，PID739→5097；kernel517秒转储见native composer PID582及另一个RenderThread在goldfish_pipe_read_write等待，PID582启动记录为vendor.hwcomposer-3。多系统应用DeadSystemException为后果。只能确认系统/图形通道阻塞，不能直接认定由AAudio或freezer造成；没有据此擅改系统freezer。
- 当前稳定版37.2.12也出现系统级故障，原先“未冻结”历史状态已被新证据更新。AAudio55秒操作本身已在故障前完整记录，后续恢复设置稳定性尚未通过，候选不升生产默认。
- 第23次关闭记录emulator23-close.json；控件enableLongShowControl仍TRUE待下个短会话恢复false并冷启核验。准备第16轮AAudio基线与AAudio+已有stacked取流组合，两包用一致continuity监听、关闭transfer trace，不与第15轮重诊断绝对值混比。使用更短的独立AVD会话，完整ABBAAB后立即退出，避免长时间空闲/额外回归混在同一实例；设置恢复/其他回归另安排。

- 第16轮aaudio-speed-control.apk成功3分45秒，SHA256 6246e413b735b00dbe843700bb714f14988fb48502fd56f63c27baa82f759050；完整源码/开关快照保存，关闭transfer trace但保留60秒连续性观测。开始同源码aaudio-stacked.apk，额外defer-auxiliary/prioritize-play-url/hedge-audio。

- 第16轮aaudio-stacked.apk成功1分45秒，SHA256 7d6ee23ddaaf8254f5eb3c8d230cbc61f713226e2caa3a24f65e0773743cf427；源码哈希与aaudio-speed-control完全匹配，唯一开关增量为DEFER_VIDEO_AUXILIARY=true,HEDGE_AUDIO_SOURCE=true,PRIORITIZE_PLAY_URL=true。进入短会话24处理设置恢复与永久退出取消回归。

- 第24次launcher77508启动门槛17.32/12.71GiB通过；Gradle51252已确认本仓库两次构建完成后释放。aaudio-controls-restore-03明确before=true→false/verified=true并sync，后续aaudio-controls-verify正在冷启验证。前两次失败记录保留。
- 为减少测量后闲置时的系统异常，新增run-combination-pair.py仅运行指定两包新目录完整预热+ABBAAB，成功且原QEMU PID/创建时间/AVD身份仍匹配后立即sync/正常关闭，再离线分析；失败时保留模拟器供恢复，不删除数据。脚本语法验证通过，尚未执行。


- 第24次aaudio-controls-verify冷启确认enableLongShowControl=false；aaudio-stacked-cancel-01原始native末行49不完整，严格采集器返回失败。完整重取stable-repull按原文件字节前缀/哈希核验，parseErrors=[]；原raw不覆盖。host在0.0695秒发返回，但应用route.leave发生于primary.begin后181.110ms，primary.end在173.007ms，故不能声称这次覆盖了地址响应前的退出。route.leave后related/tags分别1.564/1.859ms释放reason=cancelled/current=false，未到source.open；只证明等待中的附加请求取消，不纳起播样本。
- 第24次QEMU45808 sync/emu kill正常退出，emulator24-close.json；Gallery仍关闭待最终恢复。
- 第16轮采集可靠性修正：PlaybackDiagnostics原按新事件触发的64条/1秒刷新，空闲时可能长期留半行。现仅有未刷新写入时在同一后台I/O线程安排一个1秒flush，后续主动flush/销毁取消任务；不在UI轮询，也不改播放。采集器每次拉取都保存trace-pull-NN，只对未换行末记录有界重取（最多3次/间隔1.2秒），必须同名文件为原字节前缀扩展；完整坏行/内容替换/持续半行均失败。app只保存验证成功的快照，trace-pull-audit记录每次哈希。
- trace-snapshot-tests.json四项故障用例通过：尾行续写可恢复、完整坏行拒绝、内容被替换拒绝、持续半行拒绝；每项验证首份raw不变。Kotlin将在两份新v2 APK编译验证。旧第16轮两包及cancel失败证据保留，未测速度；新包只增加相同诊断刷新修正，不把跨监听旧包数值相减。

- 新v2控制构建2分4秒，SHA256 7f65cebcf26af574a654aea2693923051d271cd61c1f556ac05a9355ce811173；候选29秒，SHA256 e54dfc173e9f126a82c9211fcf2e2a59ab40e8173b7b7ffd13878a65192e34b8。Kotlin编译成功，全部源码快照哈希相同；额外开关仅DEFER_VIDEO_AUXILIARY=true,HEDGE_AUDIO_SOURCE=true,PRIORITIZE_PLAY_URL=true。Gradle20944完成证据确认后释放，开始独立第25次完整ABBAAB，结束由runner立即sync退出。

- 第25次launcher74416，首次45秒boot等待未完成，后续sys.boot_completed=1；此为环境准备，不纳起播时间。aaudio-stacked-pair-01完整预热+ABBAAB完成，7次原始记录都首次拉取完整，无重取/丢失记录，host-tools与trace-pull-audit保留。结束runner正常sync/关闭QEMU，emulator-close.json exited=true。
- 第16轮正式首纹理：控制1270.115/1046.596/1157.847ms，候选950.307/1020.180/1097.930ms；中位1157.847→1020.180（137.667ms改善），呈现前置条件1157.847→1022.649（135.198ms）。API中位288.479→161.974，open后832.153→825.234，主要收益在接口阶段，不能声称本组合显著缩短了解码阶段。
- 最长不同正timestamp间隔控制137.926/131.240/139.273ms，候选109.247/132.880/137.437ms；中位137.926→132.880，没有回到约1秒冻结。该轻包不含actualAo属性读取，只能报告AAudio配置及此前同后端代码的实际验证，不虚报每次已读currentAo。仍是单视频/模拟器，真实屏幕呈现未知，0.8未达；保留组合继续叠加。
- review-combination-pair.py保存并逐项验证captured/无parseErrors/有效source/input/texture/无丢记录，生成comparison-reviewed及六份continuity-analysis。预热1678.209ms排除。当前实际解码器日志为c2.goldfish.hevc.decoder，模拟器特性不可推广到手机。
- 下一步第26次独立短会话，现安装的aaudio-stacked-v2先预热一次，再8秒Perfetto+25秒事件监听/22秒返回；仅用于分解取流后阶段，不与第16轮轻样本直接计算性能收益。run-aaudio-codec.py已保存/语法检查，尚未开始。

- 第26次预热aaudio-stacked-codec-warmup-01完成且日志完整，1774.304ms不纳性能对照。诊断启动参数back-after=22与25秒采集的严格<seconds-3校验相等，被参数解析拒绝，未创建采集目录、未开始设备操作。保留原runner，新增after-warmup runner仅继续诊断并改为21秒返回，不重复已完成预热。


### 第17轮：NDK MediaCodec 包装层（准备）
- 第26次aaudio-stacked-codec-01完成，25秒监听/8秒Perfetto/21.022秒返回，原始日志完整、无丢记录，runner正常sync退出。codec-analysis：初始化504.108ms（耗78.0ms），configure582.274（10.0ms），start592.341（33.4ms），首次native queue649.458，首次render/release933.923，间隔284.465ms，首个正纹理变化1102.327ms；首帧前flush=0。连续性最长232.288ms，属重诊断不能和第16轮轻包直接相减。返回后回收需补查事件/AudioFlinger。
- initial-slice-names.sql/csv保留全量初期slice名称：确有dequeueInputBuffer#java/queueInputBuffer#java及JNI；dequeueInputBuffer最长59.104ms。这些耗时包含native等待/调度，不足以把根因归为JNI本身。CCodec onWorkDone(ts=0)最早759.173ms，该事件可能含配置工作，不能仅凭它声称完整视频帧已经可显示。
- 基于官方FFmpeg mediacodecdec.c的ndk_codec选项，新增STARTUP_NDK_CODEC默认false，仅Android候选vd-lavc-o=ndk_codec=1，保持相同MediaCodec解码器/所选媒体/画质和现有AAudio取流组合。两包共同添加startup.decoder.options（读取实际options/vd-lavc-o），不把配置读回当真正NDK运行；实际需Perfetto检查JNI/NDK调用路径及同解码器。
- builder新增--ndk-codec写入构建清单。Dart已格式化，正在分析，尚未构建/测试。先同源码ndk-control和ndk-codec两包ABBAAB；若无收益，保留现有组合继续查输入队列/呈现，不撤回第16轮有效收益。

- 第26次返回回收补查cleanup-reviewed.json：21.508秒视频/音频closed、worker expected=true，AudioFlinger为1 Tracks of which 0 are active。第17轮Dart analyze No issues found；当前ndk-control构建，配套run-ndk-pair/review-ndk-pair脚本已保存并语法检查。

- ndk-control构建成功3分42秒，SHA256370e11248449b30afc1bb6b43429ccc6203f04e71f7a4323fbe261f7628d02b4；正在构建唯一新增--ndk-codec的候选。新增保存trace_snapshot_tests.py可复现采集故障测试，v2结果增加UTF-8多字节字符半写恢复，5/5通过，原v1结果保留。
- 第26次离线追加initial-dequeue-order.sql/csv和decoder-thread-states.sql/csv：649–934ms区间解码调用线程3951实际Running57.004ms、Runnable116.715ms、Sleeping110.720ms，MediaCodec_loop Running56.008/Runnable69.075ms。说明等待混合了调度/线程通信，不应把284ms统称纯解码计算或JNI开销；此系统跟踪自身较重，后续NDK收益仍须轻量同组实测。

- ndk-codec构建成功1分46秒，SHA2567e710e991fa304f7610f975e2f058196177af9ce826ed6ad0f3e13bca05193ca；与ndk-control源码哈希完全相同，唯一define增量STARTUP_NDK_CODEC=true。Gradle65164完成本repo构建日志确认后释放。第27次launcher78120，gate17.17/12.49GiB通过，准备运行ndk-pair-01预热+ABBAAB。

- 第27次ndk-pair-01完整预热+ABBAAB结束并正常sync关闭。控制texture949.908/869.828/1210.902，候选1058.592/1053.034/954.918ms；中位949.908→1053.034，呈现前置条件1015.911→1111.562，open后762.909→838.075，均未见收益。最长新timestamp间隔中位118.117→143.679ms。所有候选实际options/vd-lavc-o读回ndk_codec=1，但未做NDK专门Perfetto，故只确认配置生效，未完整证实后端路径；不升默认，保留独立实验开关及证据，保留第16轮组合。
- 下一步转向点击前的有限播放地址预取，先做已知CID普通UGC卡片/单项/Wi-Fi/短过期/不打开媒体；缓存保留原始JSON并在消费时新建PlayUrlModel，避免共享后续会补画质的可变对象，账号与请求参数必须一致。只预取可见卡片，滚动/后台/切页停止新预取，不把测试URI预热伪装成产品功能。此方案尚未实现或测试。

### 第18轮：可见卡片单项播放地址预取（实现与静态验证）
- 新增默认关闭 VISIBLE_URL_PREFETCH：首页推荐页静止600ms后，仅Wi-Fi、前台且当前可交互页面，从已知bvid/cid的普通UGC中选一张至少65%可见且靠近视口中心的卡片。只请求播放地址，不下载媒体、不建播放器；单项缓存10秒、未接管请求4秒取消、最短3秒新预取间隔。
- OneShotPrefetch以完整请求参数及播放账号对象为键，取消/替换/过期结果不能回写；点击消费后转交普通播放，重新解析原始JSON为独立模型，失败回退原请求。滚动/后台取消，路由覆盖停止调度但保留短时交接；代码与构建清单均保留为独立实验。
- 首次格式化因新import误落文件尾失败，已移到顶部；第一次分析无错误但有9条风格/废弃API提示，已逐条修正后再次分析。未构建、未做设备测试，不能登记性能收益。
- 新增5项缓存生命周期测试，覆盖单次消费、参数不匹配/过期、迟到失败不覆盖新项、取消后迟到成功、已接管请求失败。测试尚待执行；下一步真实首页卡片点击，不能用预热测试URI冒充首页功能。
- 缓存生命周期5/5测试通过（url-prefetch-tests-01.txt）。分析第二轮因格式化新增5条多行if风格提示，第三轮仅剩1条跨异步BuildContext提示，均继续修正；各次输出分别保留，不把有提示记录改写为无问题。
- 两组诊断包共同记录startup.visibleCard（目标CID/标题/布局边界/像素比例），只有候选实际预取。新增startup_home_card.py并接入采集器--home-card，必须同时有页面可见事件和真实UI语义标题，才点击封面区域；候选还需播放地址ready事件。所有准备快照另存，最后测量仍用完整、严格校验的原始日志，不采图像。
- 实际推荐内容会变化，首次首页采集只验功能/分段时间；不同视频之间不能计算预取净收益。后续同内容对照需要单独设计，不混入旧固定URI样本。
- 最终四文件Dart分析No issues found（url-prefetch-analyze-04.txt），5项测试通过；新采集/汇总/运行脚本Python语法检查通过。
- url-prefetch-control.apk构建成功3分31秒，SHA256 fff17d395968a8dc0b1f739d40375d3efc88d258a746e17c2ab1fd1e0a963e54。包含第16轮AAudio/附加请求延后/URL优先/双路竞速/uncut与本轮共同可见卡片监听，不含NDK；正在构建唯一增加VISIBLE_URL_PREFETCH的候选。
- 本轮安排短会话：固定入口预热一次、对照首页一次、候选首页两次，25秒采集/21秒返回。推荐视频不保证一致，严格登记为功能与阶段诊断，不能汇总成同内容AB测试；全部原始数据与选择依据独立保存。
- 候选url-prefetch.apk构建成功1分46秒，SHA256699c6520af52ce0d0ec373353c4a0119f9dd757bc1a0c6896ac7d539a5bbb06a；脚本核对两包全部快照源码哈希一致，唯一define增量VISIBLE_URL_PREFETCH=true。
- 释放构建进程时第一次所有权断言期待currentDir为android子目录，与日志实际repo根目录不符，因此未执行终止；读取完成记录后修正精确根路径核对，确认本次Gradle73568已完成才释放。未关闭其他进程。
- 第28次测试会话launcher49284，启动门槛提交17.09GiB/物理12.39GiB通过，使用同一稳定37.2.12/host/-Vulkan运行时和原隔离AVD。Gallery仍保留数据关闭；当前等待系统启动，尚未采集本轮性能。
- 第28次预热完成，首纹理1401.523ms，非正式速度样本。首页对照01在准备阶段失败：20秒未有可见可预取卡片事件，未执行测量点击，原始36份准备快照/日志和failure-ui.xml保留。
- 页面语义证实推荐卡片已显示且无弹窗；网络诊断发现Wi-Fi开关1但未连接，默认网络为CELLULAR。按实验Wi-Fi限定，不触发预取符合限制。url-prefetch-network-before.json保存Wi-Fi1/mobileData1/未连接及已有AndroidWifi配置。仅在隔离QA调用连接已有AndroidWifi，状态确认connected；本轮网络类型变化不能混旧蜂窝样本计算增益。
- 第28次正常sync关闭（emulator28-close.json）。为避免长会话系统卡死干扰，新开第29次短会话跑首页Wi-Fi对照一次、候选两次，不重复固定URI预热。新run-url-prefetch-home-wifi.py与独立url-prefetch-home-wifi-01目录；结束后须恢复测试前网络连接状态及Gallery。
- 第29次Wi-Fi三个真实首页样本完整采集并正常sync关闭。控制CID42791734673：首纹理1444.707ms/封面解除1433.363ms/主接口168.170ms；候选CID42798679843：1268.375/1191.473/13.853ms；候选CID42992271493：1041.805/1072.533/12.199ms。两个候选都有ready早于claim且无fallback，证明实际卡片接管成功。视频不同，不能把控制与候选耗时相减为净收益，0.8未达。
- 三份完整日志无解析错误/丢失，原生触摸坐标与卡片封面坐标一致。连续帧最长间隔分别116.822/228.207/202.186ms，持续到返回约21秒；三者均视频/音频closed、worker expected=true、活动音轨0。home-prefetch-reviewed/continuity-analysis/cleanup-reviewed保留。URL预取功能保留候选，仍默认关闭。

### 第19轮：可见卡片选定媒体HTTP连接预热（实现）
- 在URL预取完成后，按当前Wi-Fi画质/编码/音轨偏好预测两条资源，仅自动播放且零进度、已有目标质量时启动一个原有隔离worker；最多一组音视频，未接管8秒自动关闭。没有建立播放器、未修改实际轨道选择；播放时账号、视频完整URL、音频完整URL、请求头全一致才接管原worker与本地URL，否则关闭猜测资源按原路径播放。
- 这一层具体是提前发起媒体GET并复用响应，当前ParallelAudioSource尚不主动读取点击前的应用层字节前缀；其256KiB是消费时回读缓存，不能写成“点击前已缓存256KiB”。未订阅的响应受流/套接字背压，生命周期8秒有界；下一步实测headers是否在点击前完成及接管后的持续播放。
- 新SelectedMediaWarmup/visible_media_prefetch及独立VISIBLE_MEDIA_PREFETCH默认false。start URL已被点击接管或已取消时不再迟到创建媒体预热；滚动/后台取消未接管资源，已转交的资源由原播放器回收。网络检测改为异常时不预取，避免沿用旧isWiFi在插件失败时返回true的普通播放兜底；迟到检测失败不能清掉新一轮资源。
- 12/12测试通过（原5缓存+新7）：到期关闭、账号/URL/请求头不匹配、接管后清理不误关、worker失败、真实双HTTP响应接管且每条源只请求一次/字节完整、画质编码音轨选择、缺失画质与非零续播跳过。日志media-warmup-tests-01.txt。8文件分析正在运行，尚未构建或设备实测。
- 第19轮第一轮分析无错误但15条提示，已处理公开回调类型/多行if/级联风格，并避免为测试引入未声明的fake_async依赖。暂未构建。
- 第二轮扩展测试出现1项失败：为到期测试使用testWidgets初始化了Flutter的HTTP mock，导致同文件真实本地HTTP客户端被统一返回400；其余20项通过。原失败日志media-warmup-tests-02.txt保留。改为20ms可配置时限并等待真实关闭回调，不初始化widget HTTP mock，正在重新执行21项传输/生命周期回归。首次补丁上下文未匹配，未写入，重读实际格式后已修正。
- 另补实际非零seek/仅音频/本地或直播路径直接清理未接管媒体预热，避免预测失配时无用连接留到时限。
- 第19轮重跑21/21通过，日志media-warmup-tests-03.txt；8文件分析No issues found，media-warmup-analyze-02.txt。第二轮失败明确为widget绑定HTTP mock污染已消除，未放宽响应/字节断言。
- 采集元数据mediaPreloaded现在从实际构建清单读取，避免新媒体预热包仍写false；清单另标applicationPrefixPreloaded=false，准确区分提前请求媒体与主动读取应用层前缀。默认开关仍false。
- 已开始media-warmup-control.apk构建：包含URL预取、先前AAudio/双路竞速/uncut/辅助请求延后组合；配对候选只增加VISIBLE_MEDIA_PREFETCH。新run-media-warmup-home/review-media-warmup-home脚本及目录独立，不覆盖第18轮工具/数据。
- media-warmup-control.apk构建成功2分21秒，SHA2561772b37d7607c9ca4377f6ef86563021259726c6528faf86b8616cb7d1be97ca；候选同源码构建中，尚未设备实测。
- 后续需补未点击8秒到期/后台取消与已接管返回两类生命周期，不把单位测试等同设备回归。真实首页不同视频的样本仍仅作功能/阶段诊断；同内容比较另按方案验证。
- media-warmup.apk构建成功，SHA2565fdb8d144edad9eacaf2d198c9d758e70f6b2192f6d460d72279227b042f2b31。两包快照哈希完全相同，唯一define增量VISIBLE_MEDIA_PREFETCH=true。已核对完成日志/当前repo，释放本轮Gradle75560。
- 第30次launcher77168，启动门槛提交17.06GiB/物理12.32GiB通过；同稳定runtime37.2.12/host/-Vulkan，等待boot后连接已有AndroidWifi，开始media-warmup-home-01短会话。
- 第30次媒体预热候选02已实际播放/21秒返回，但结束列举诊断目录的adb ls退出1，原采集保留errors，原因因旧包装未留stderr而未明确。后续shell/目录/原PID3993均正常，不能称应用崩溃。按原logcat宣布的精确两文件直接拉取到stable-repull，原采集未覆盖；完整JSON/当前源/触摸/纹理校验通过，第30次随后正常sync关闭。候选03及独立idle工具未运行。
- 恢复样本CID42921299224：URL在点击前2.919秒ready；视频/音频有效206响应在点击前2.821/2.801秒完成，媒体在点击后63.520ms接管；首个正纹理759.632ms（PTS33ms，surface有效），封面解除844.682ms，呈现前置条件844.682ms。单次不同视频，不能算稳定0.8达标，也不能与首页控制1285.803ms直接相减。保留候选继续叠加。
- 剩余等待定位：output.stable.wait526.928ms，最终1920×1072视频参数/纹理尺寸746.508ms，三样本稳定检查844.243ms；最后约98ms在尺寸有效到封面门控之间。120ms最短等待早已满足，不可盲目只删这个常数。连续不同timestamp最长间隔339.775ms，早期还有261/223ms间隔，需同内容复测，不能只看快首帧忽略连续性。
- 恢复日志还完整包含返回后的未点击预热：视频/音频/worker分别在8005.414/8007.577/8008.012ms关闭，应用层receivedBytes/deliveredBytes均0；原播放两路closed/worker expected=true。AudioFlinger0是较晚恢复时读取，未冒充原捕获时刻观测。
- 恢复前缀审计第一次逐字节断言失败：准备阶段adb shell cat增加CRLF，而adb pull保留LF。原件未改；仅内存中统一准备样本换行后102条完整记录与恢复原文件前缀匹配，哈希和区别写入recovery-identity-audit.json。native原来未成功拉取，身份依靠原精确文件公告与未变化PID，不能虚报其原件字节比对。
- 采集修复：不再列举整个旧日志目录，直接按当前进程明确公告的精确文件路径读取/拉取，由成功拉取及严格解析确认存在；新增5项文件代次测试全部通过。ADB非零命令现在保存stdout/stderr/命令，避免再次缺失原因。下一第31次仅补候选两视频和独立8秒到期验证，应用包不变，宿主采集工具另存快照。
- 第31次两次真实首页均完整成功，工具修正后精确路径首次拉取均完整。CID42500228134首纹理1132.051ms/封面1202.464ms/接口32.791ms；CID42391113467为671.205/740.771/12.540ms。两者媒体均真正claim，画质80、HEVC、音频30280；不同视频/冷启动顺序不同，不作净改善计算。最长新timestamp间隔367.778/176.625ms，持续到返回约21秒，仍不能宣布稳定0.8或物理屏幕验收。
- 04-unclaimed-expiry独立设备验证通过：最后返回首页的新预热在8004.640/8007.131/8008.479ms关闭视频/音频/worker，应用层接收/交付0字节，无新source.open或claim，活动音轨0。新拉取完整文件逐字节延续上一份adb pull原件，hashAudit保存。第31次正常sync关闭，当前无模拟器。
- 新同内容对照工具准备：保留同一进程/卡片，短滚动取消重建预热并复核CID/语义；2秒媒体年龄命中与8.3秒过期交替，要求两组URL都仍命中，媒体claim恰好符合预期，首PTS<1秒且无丢记录。新采集按测量前native seq截断选择当前source，不能重用第一次同CID旧样本；单元测试证明重复CID选新请求/旧窗口不替代新缺失，已通过。
- run-media-warmup-same-card.py计划预热+expired/ready/ready/expired/expired/ready，22秒采集18秒返回，尚未执行。应用包不变；新宿主工具快照/计划/实验条件逐样本保存。若URL同时过期、卡片变更或续播非零，则该组失败保留，不强行计算收益。
- 第32次启动命令误写-feature Vulkan，启动前复核立即发现，尚未启动任何采集/应用测试。该会话作废，日志和emulator32-rejected-config.json保留，按已验证唯一QA进程关闭；不得并入此前-feature -Vulkan样本。下一会话恢复正确参数。
- 第33次通过新start_startup_qa.ps1固定稳定runtime37.2.12/host/-Vulkan启动，launcher78280/QEMU72400。Wi-Fi连接命令即刻返回时仍未关联，随后实际startup.visibleCard Wi-Fi eligible/预取证明连接已就绪；不把即刻状态写成已连接。相同APK/进程/CID43017113088交错六次全部通过URL命中、媒体命中/过期、零起始PTS和无丢记录条件，媒体预热有效首纹理665.304/605.031/695.307ms，过期908.547/898.422/870.207ms。中位898.422→665.304ms，呈现前置条件898.422→731.555ms；有效组全部前置条件702.683/750.239/731.555ms。仍只是单视频重复打开/受控停留，未测物理屏幕，不宣布通用稳定达标。
- 同组最长正timestamp间隔中位112.629→125.072ms，有效组三次125.072/91.182/146.552ms，持续到约18秒返回；原日志和逐样本continuity-analysis/comparison-reviewed保存。七次包含预热后脚本验证进程身份sync正常关闭，emulator-close.json。应用层预热收益保留，不因未覆盖冷启动/所有视频撤回。

### 第20轮：事件触发的输出稳定检查（实现与单测）
- 新默认关闭EVENT_DRIVEN_OUTPUT_GATE。尺寸/纹理ID/播放器size/PiP事件触发观察，有效状态再等待实际Flutter帧边界确认三次相同；无有效尺寸时不做16ms轮询、不连续请求UI帧。保留120ms最低等待、5秒超时与PiP转交。尺寸一帧内改变再恢复也重置稳定计数，取消/超时在没有新帧时仍能完成，结束移除监听。
- 保存真正正在加载的PlaybackSourceRequest，等待绑定该请求取消信号；返回bool让调用者取消后不揭开旧封面。避免读取队列中尚未执行的新request，阻塞旧操作退出。控制与候选源码相同，普通轮询路径也共享取消结果传播；候选仅改变稳定观察机制。
- 新stable_output_gate_test.dart六项：无效尺寸不排帧/重复事件不计样本、同帧变更重置、最短等待与停止排帧、阻塞帧时取消及迟到帧、无帧超时、PiP与取消优先。合并既有source queue/preparation共16/16通过，output-gate-tests-01.txt。静态检查进行中，尚未构建或设备验证此门控。
- 新review-media-warmup-same-card.py按同APK/进程/内容验证、每样本当前源身份连续性、新目录拒绝覆盖。第一次本机门槛调用误用-Phase参数，实际输出Kind=capture；没有因此开始构建，随后正确-Kind build通过（17.79/12.59GiB、无模拟器）才执行测试。失误与正确检查均保留会话记录。
- 第20轮首次分析仅两条测试cascade样式提示，修正后第二次四文件No issues found，output-gate-analyze-02.txt。控制包output-gate-control.apk开始构建（exec25641）；两包共同保留所有AAudio+stacked+URL/media预热开关，新候选只额外EVENT_DRIVEN_OUTPUT_GATE。构建期间不更改已纳入快照的应用/测试源码。
- 新run-output-gate-pair.py固定原视频index5，预热+ABBAAB、22秒/18秒返回，要求没有首页URL或媒体claim、实际output.stable机制与包一致、零进度首正PTS、无日志丢失。此组用于隔离门控增量，不能冒充媒体预热完整首页场景；后续真实首页另外验证。尚未执行。
- 补齐第33次返回回收审计：新review_startup_return_cleanup.py按当前playerId选择唯一source.open后，再检查该源route.leave后的视频/音频/worker关闭及AudioFlinger活动音轨。七次全部通过，关闭延迟约337–407ms，活动音轨全部0；每份return-cleanup-reviewed.json保存原事件及审计脚本哈希。没有用上一轮同CID旧回收记录充数。
- 第20轮两包构建完成：control SHA256fefa1f44aab305d5d1f955df26a58c55de1acffd6ce6681c8a969c7488b72a24（2m20）；candidate e47f77e64ae888f0c4948a644c00499763328640170f7b9320c49e59149a8559（1m54）。全部源码快照哈希一致，唯一define增量EVENT_DRIVEN_OUTPUT_GATE=true，依赖临时补丁已由builder恢复。核对daemon13820本repo最后构建完成后释放，开始第34次同runtime测试会话，尚未实测门控。
- 第34次output-gate-pair-01在预热采集参数检查即失败：新runner漏传必填--serial；APK已安装，未启动应用采集/测量点击。保留原host-tools、安装日志和错误driver。修复参数后使用新output-gate-pair-02，不覆盖01；当前短会话继续，无需把参数错误当应用失败或重建APK。
- output-gate-pair-02预热2163.749ms条件通过；01-control完整采集但无原生input.touch/该CID source.open，因此拒绝，不计测速。ADB tap退出0且搜索URI/语义正确，不能据shell成功虚报送达。诊断首次Python读文件漏UTF-8产生GBK异常，随后显式编码重读原件，无修改。
- 保存failure-input-state、failure-window-state、failure-systemui及系统日志，发现NetworkPolicy系统流量提醒处于HeadsUp/pinned，NotificationShade触摸区域[42,0][1038,349]覆盖搜索按钮[990,135]；MainActivity仍有focus不代表它拥有这次触摸区域。提醒横向清除后相同坐标归MainActivity，input-target-audit.json真实前后快照断言通过。这解释该次无触摸的具体环境干扰；此前其他无事件样本没有当时窗口证据，不能回填同一原因。
- AOSP InputShellCommand源码确认tap为同时间戳DOWN/UP，但无证据说明时长是此次根因，因此未改成延时手势、不额外加人为点击延迟。资料：https://android.googlesource.com/platform/frameworks/base/+/master/services/core/java/com/android/server/input/InputShellCommand.java 。
- 新startup_input_target.py从Input Dispatcher按窗口顺序/触摸区域检查实际目标，排除SPY/NOT_TOUCHABLE/NO_INPUT_CHANNEL，不依赖图像。采集新增可选--verify-input-target，遇遮挡在点击前拒绝并保留原状态，仍需事后input.touch证据。run-output-gate-pair启用此检查，后续新目录03。前后真实快照审计与Python语法检查通过，应用APK没有变化。
- 第34次QA连接AndroidWifi并确认connected，原网络备份恢复义务不变；QEMU31384正常sync关闭，emulator34-close.json。第35次短会话已启动；之后须等待Wi-Fi确实关联再跑03，不把旧蜂窝失败组混入新Wi-Fi对照。
- 第35次已确认Wi-Fi关联。output-gate-pair-03预热2205.408ms、01-control1722.462ms均有效；系统输入窗口检查证明点击目标属于MainActivity。02-candidate点击送达/开始解码，但18秒返回时adb error:closed，随后device offline；最后提交余量12.575GiB/物理8.911GiB，未越资源门槛。
- emulator35-stable.out.log末尾记录DisplaySurfaceGlContextHelper context preempted、Failed to restore previous context:12297及QEMU主循环/CPU线程挂起，随后宿主QEMU进程消失；并非正常关闭。原logcat包括goldfish HEVC创建和WaitUntilFirstFrameRenderedNotify，但原始app trace未成功拉取，当前不得计候选测速或通过回归，也不能据这一条直接断定门控代码根因。03停止，保留全部失败/ADB stderr。
- 第36次launcher27748同runtime启动；先恢复原PID4576明确公告的日志到新recovery目录，再用短候选会话验证。应用包未变。若问题重现，将做控制/图形后端诊断；不能把宿主模拟器崩溃当0.8未达就撤回此前媒体预热收益。
- 第36次重启后按原PID4576两精确路径拉取成功，但两个文件都是0字节；recovery/raw/validated-prefix/哈希审计/无效summary均保留。只找回文件名，未找回任何可用测速证据，recovery-assessment明确usableEvidenceRecovered=false，原失败不能修订为通过。
- 新run-output-gate-pilot.py正在同host后端单次候选22秒/18秒返回，目录output-gate-candidate-pilot-01，工具快照另存，实际Wi-Fi关联后启动。原APK不改，先验证候选在新短会话能否持续播放/返回。
- 采集元数据修正：mediaPreloadEnabled记录包中功能开关；mediaPreloaded仅在实际观察到startup.mediaPrefetch.claim后为true。此前固定入口03包开启预取但无claim，旧字段true只表示包能力，实验条件已明确noMediaWarmupClaim，不把旧字段当实际预热事实。旧原始记录不覆盖。
- 第36次候选单次完整通过，output-gate-candidate-pilot-01首纹理2789.118ms、封面2845.597ms，原生HEVC/1920x1080，媒体缓冲至2584.878ms；实际eventDriven=true/samples3，最终尺寸到稳定约258.831ms。最长正timestamp间隔141.356ms，持续到18秒返回；当前源视频/音频/worker在route.leave后311.355/311.878/312.178ms关闭，活动音轨0，QEMU正常sync关闭。不是同条件性能对照，不能据冷样本宣布门控有益或有害；默认仍关闭。
- 下一完整对照新目录output-gate-pair-04，原03不补凑成完整成功组。安装包替换前显式force-stop当前QA应用并等待1秒，停止结果逐轮保存；这是避免在运行中替换应用的测试准备改进，尚无证据证明它就是宿主GL挂起原因。此等待在测量点击前，不从首帧时间扣除。
- 第37次output-gate-pair-04完整预热+ABBAAB成功，严格实际输入/无预取claim/门控身份/无丢日志全部通过，正常sync关闭。control首纹理1529.417/1249.722/1207.743，candidate1317.943/1137.250/1083.841ms；中位1249.722→1137.250ms。但封面与纹理前置条件中位1255.027→1249.957ms，仅约5ms差异；最长正timestampgap中位132.446→171.816ms。六次返回双轨/worker正常关闭、音轨0，comparison-reviewed/continuity/return-cleanup均保存。
- 结论：帧驱动门控确实让被Flutter消费的纹理提前，但封面并未同步明显提前，不能把112ms纹理变化宣称为112ms用户可见提速。保持此候选默认关闭、保留代码与实验，不与媒体预热已经证明的收益混为一谈。继续第21轮事件触发连续稳定时长方案。

### 第21轮：事件触发32ms稳定区间，不主动要求绘制帧
- 第20轮实际帧边界等待可能被忙碌Flutter帧拖长，且额外安排帧会改变纹理消费时机。新增独立EVENT_DRIVEN_OUTPUT_DWELL默认false：仍由rect/id/size/PiP事件触发，几何有效后单次32ms定时器到期复核；收到任何几何变化立即取消重计，包含同一帧内变更再恢复。32ms对应原三个16ms轮询样本间的最短跨度，当前记录两次实际观察而不冒充三次帧；保留120ms总下限/5秒截止/PiP/请求取消。
- 不请求额外Flutter帧，不在无效尺寸时周期轮询，不使用图片。旧EVENT_DRIVEN_OUTPUT_GATE三帧候选完整保留，两实验开关互斥。实测收益待定。
- 补取消结果交接：等待finally取消订阅也是异步，完成返回后再检查加载request仍相同且current；同源复用调用也重新确认owner/CID，避免等待结束与回调之间发生取消/换源后揭开旧封面。该守卫在本轮控制/候选共同包含，不单算门控收益。
- 新六项dwell测试用可控测试时钟验证32ms边界、同帧变更重计、重复通知不延期、120ms下限、漏通知到期复核、取消/PiP/无帧超时；加上原帧门控/source queue/preparation共22/22通过，output-dwell-tests-01.txt。五文件分析进行中，尚未构建或设备实测。
- 第21轮首次分析只有取消守卫缺花括号风格提示，修正后五文件No issues found（output-dwell-analyze-02）。output-dwell-control.apk正在构建exec67768，候选随后同源码增加--event-output-dwell；没有新设备测速。接续文档第一次补丁因末尾字词不一致未匹配，重读后成功追加，旧原始测试不变。
- 准备run-output-dwell-home.py/review-output-dwell-home.py：随后五次真实首页/每次冷app，第一例模拟器冷播放保留；无额外指定2秒等待，仅原真实UI语义准备/URL ready条件。媒体预热未命中仍保留分布，不筛掉慢例，逐次记录claim、首PTS、实际dwell模式、完整连续性和返回回收。不同内容只给绝对分布，不伪称同内容A/B净收益；全部是否<=800ms单列。脚本尚未执行。
- output-dwell-control.apk构建成功3m49，SHA256eec54aca7969c75b51837c9b0ba6d87f239ca5dedd704a374c90b3c5113ea6d5；候选同源码构建中exec55866。无模拟器。
- 代码复核另发现待验证的取消尾部：play()在等待presentation返回后仍无条件setActive(true)/设置playing，若期间取消/释放，可能重新激活音频会话。当前构建快照不改，下一功能修正需在play异步边界后核验原player/请求/引用数，再执行尾部副作用；必须用提前返回回归确认，不把此前正常18秒返回视为覆盖此竞态。
- 第38次output-dwell-pair-01预热+ABBAAB完整成功/正常关闭，所有六次无日志丢失/条件通过/双轨worker返回关闭/音轨0。control texture中位1091.501、前置条件1117.280ms；candidate1308.212/1308.212ms，未见总体提速，最长正timestampgap中位127.150→160.698ms。候选三次1412.885/1308.212/1025.939，控制1350.978/1071.000/1091.501；完整顺序和冷预热另存，不能只选最后最快候选。
- 新review_output_stability_stages.py把最终videoParams、稳定完成和封面分开，所有样本参数快照与最终rect/decodedSize一致。第20轮参数→stable中位95.097→165.018ms；第21轮115.169→153.478ms。新门控没有稳定消除这段等待，两个实验继续默认关闭保留；不再把纯纹理提前当有效用户提速。
- 下一线索：本固定视频首段DM响应约160KB，在首帧前返回，可能占主Dart线程处理时段；尚未证实为根因，开始沿DmGrpc/解析路径检查。Flutter官方建议把耗时解析移到isolate，但不能在未读代码前假设现有实现没做。资料https://docs.flutter.dev/cookbook/networking/background-parsing 与 https://docs.flutter.dev/perf/isolates 。媒体HTTP预热已验证收益继续保留。

### 第22轮：弹幕中等响应后台解析与播放取消尾部保护
- 第21轮已完成output-dwell-pair-01，session38正常关闭；正式纹理中位1091.501→1308.212ms，呈现前置条件1117.280→1308.212ms，API164.808→163.291ms，最长正timestamp间隔127.150→160.698ms。最终尺寸→稳定中位115.169→153.478ms，六次返回回收和音轨0通过。32ms dwell没有提速证据，保持默认关闭，保留代码与全部样本；不按最后一个快样本挑选结论。
- 新假设：dmSegMobile虽然isolate=true，但GrpcReq仅在线上响应超过256KiB才compute；本固定视频此前响应约160KB，因此可能在主线程解压/解析，占用首帧阶段。当前未证明实际压缩方式与耗时。
- 提取相同gRPC解压/解析为GrpcDecode，默认256KiB不变；STARTUP_DM_PARSE_WORKER默认false，候选仅弹幕改16KiB。两包共同记录wireBytes/gzip/inflatedBytes/parseUs/dispatchAndParseUs/worker/threshold及cid/segment/dmRequestId；过滤另计时，不记录弹幕内容。后台解析统计在工作isolate产生，调度总时间由调用者计时。
- play()捕获实际player/output/source request/revision；native play和presentation await后确认仍属当前请求且仍playing再激活音频。原生写入仍等待完成以避免换源交错。新增异步取消、替换、暂停、异常测试；本改动两包共同包含，不把它当成解析候选净收益。
- 新grpc_decode_test.dart覆盖真实isolate序列化、gzip/未压缩字段等价、16KiB/256KiB门槛、小响应和坏包返回Error。测试与静态分析下一步执行，尚未新构建/设备验证。
- 第22轮21/21测试通过（dm-worker-tests-01.txt）；首次分析3项样式提示，无错误，已修const与测试不必要async，第二轮8文件No issues found（dm-worker-analyze-02.txt）。计时parseUs是执行解压/解析的墙钟耗时，含该isolate被调度暂停，不冒称纯CPU时间。
- 同视频runner/reviewer已生成独立dm-worker-pair-01，固定CID42790290231，预热+ABBAAB；要求两组16KiB<wireBytes≤256KiB，控制main/候选worker实际匹配、原输出门控、无预取claim、输入窗口与当前正PTS有效。保持既有AAudio/uncut/网络叠加项。
- 开始dm-worker-control.apk同源码构建。候选只追加STARTUP_DM_PARSE_WORKER；应用源码冻结到两包完成，保留build.json/source.zip和APK SHA256。
- 补充研究已写入further-research.md：media_kit官方06.paint_first_frame/09.seamless示例可提前open(play:false)实际媒体并复用，但其frame-ready回调不能当物理屏幕证据。下一突破口需单源有界生命周期/精确账号轨道匹配，当前未实现。构建期间仅阅读，没有改动冻结应用源码。
- 控制包dm-worker-control.apk构建成功，SHA256 cca8e5adc7f1dcc2bf39ec5d3fb153c798e0a1b3ad9ca1ff81a87b8349d74e24。候选dm-worker.apk开始同源码构建，仅加--dm-parse-worker，两类输出门控均关闭。当前未启动模拟器。
- 候选dm-worker.apk构建成功1分44秒，SHA256 af47f485d2de3e6cd38d3dd46e78393246513777afeda76f80ca628d4ac1f488；控制4分48秒。两包所有源码哈希完全一致，仅STARTUP_DM_PARSE_WORKER=true增量，APK重新校验通过。核对本轮Gradle38120后释放，dm-worker-build-verification.json保留。

### 第22轮设备对照结论（session39）
- dm-worker-pair-01七次（预热+ABBAAB）完整采集成功、实验条件全部通过，测试后正常关闭模拟器。控制/候选分别始终实际main/worker解析，响应160542字节、gzip=true、解压358015字节。无预取claim、原输出门控、首PTS正且<1秒、无丢记录。
- 正式首纹理1302.935/1231.679/1218.775 vs 1132.091/1237.192/1178.642ms；中位1231.679→1178.642。封面与纹理两前置条件中位1243.432→1236.327，仅约7.1ms；API183.617→160.192ms，不能把全部53ms纹理差归因解析。
- 关键否证：控制解析区间点击后1610.79–1698.13、1111.03–1125.53、1196.28–1239.94ms；候选1856.52–1964.50、1287.80–1355.05、1348.33–1412.86ms。多数解析发生在首纹理之后，因此它不是该组起播的主要阻塞。
- 主线程解析耗时87.311/14.471/43.637ms，后台44.436/22.363/21.807ms；包含调度/传回的后台总耗时107.979/67.248/64.531ms。过滤中位1.431→0.871ms，不支持搬移过滤作为主要突破。
- 最长正timestamp间隔中位162.718→146.666ms，但控制有550.950ms单次长间隔、候选有191.143ms；不能只报中位隐藏尾部。六次返回源匹配双轨/worker关闭与AudioFlinger活动音轨0均通过。
- 决定：保持STARTUP_DM_PARSE_WORKER默认false，保留可回查代码/计时与本轮原始数据；当前不足以确认起播净收益。既有媒体HTTP预热收益保留。进入第23轮实际媒体暂停预备设计与实现，仍需真实首页/早取消/PiP验证，不结束目标。

### 第23轮：单条预测视频的暂停实际源预备（实现中）
- VISIBLE_NATIVE_PRELOAD默认false，依赖既有Wi-Fi/可见卡片/URL+媒体HTTP预热。最多一个预备engine，优先使用既有空standby，open实际双轨DASH(play:false)；不创建页面controller、历史记录、播放音频焦点。8秒/滚动/后台取消随原lease释放，迟到创建结果也归取消方销毁。
- PreparedResource明确取消与接管所有权，不能二次take；取消后晚到结果dispose恰好一次，已接管后cache清理不得误关。新PreparedMediaEngine记录原media/engine设置/完整extras，匹配账号、两个URL、headers后再校验设置、缓冲/响度extras、pause=yes、idle-active非yes、path、零位置。失配销毁预备engine和已消费transport，普通路径重新开源。
- 仅初始普通网络、零续播、自动播放路径可接管；已有player/暂停模式/其它路径拿到带engine的lease也必须关闭二者并普通开源，避免取消8秒期限后泄漏第二播放器。开启超分、特殊TCP/read-ahead实验或已有活动播放器则不预备engine。
- DASH URI构造提取成公共函数，保留本地UTF-8长度、网络原长度、uncut开关语义。接管在source.open.begin附operation=adopt-paused-preload，真实提前open记录startup.nativePreload.openAccepted，避免把点击后的接管误说成再次原生open；仍以点击后当前request/texture的正timestamp与封面就绪测量。
- 此版沿用用户原缓冲（默认16秒/32MiB）并限制一条/8秒，未引入新的字节前缀下载器。native预读会使代理实际收到数据，因此build清单applicationPrefixPreloaded在该实验为null（必须看实际样本），不可沿用旧的零字节断言。未点击的实际流量、回收和无音轨需设备实测。
- 已写6项异步资源/DASH构造测试，下一步并入原缓存/传输/源队列/播放取消回归。尚未构建或实测，不声称已经提速。
- 第23轮34/34回归测试通过（native-preload-tests-01.txt）；首次分析仅4项样式提示，修正后第二次6文件No issues found（native-preload-analyze-02.txt）。新增匹配诊断仅记录布尔条件，原生path/账号/签名URL不写入日志；native pause和path也校验，不把Dart playing=false单独当暂停证据。
- 为避免已准备源在最终构造处变化还被错误跳过open，追加最终media等值复核，不同则退回普通open。engine设置签名纳入超分设置变化，原预备构造仍跳过开启超分。接下来先构建单候选作两次首页功能试跑，证明实际claim、起播、18秒返回与无未点击音轨，再安排正式对照；此试跑不作跨视频因果提速声明。
- native-preload.apk构建成功2分23秒，SHA256 7d41183f396afa34f860e17907b9432e2d54589d1c11f76e859c11d7eeb7c1e2；DM/frame-gate/dwell关闭，AAudio+既有网络组合+native预备开启。构建后APK与所有快照源码逐项哈希校验相符，核对本轮Gradle6044已完成后释放。下一session40两首页pilot和8秒未点击到期验证。
- 第23轮session40 native-preload-home-pilot-01两次首页全部真实native+HTTP+URL claim。CID42925362375：纹理589.662ms、封面733.825ms，首个冷模拟器/冷app；CID43066920049：503.192/577.189ms、冷app。两次实际open分别在点击前4525.869/3633.588ms，点击后同playerId接管，不能把它说成立即点击也达标。两次首正PTS100ms、无丢日志。不同视频功能试跑，非净增量A/B。
- 两次18秒返回后当前源双轨/worker回收、音轨0通过；最长正timestamp间隔307.588/80.470ms，第一条仍有明显长间隔，不能只看首帧。pilot-reviewed.json保留全部阶段与边界。
- 独立03-unclaimed-expiry通过：到期前采样经guest时间确认仍在8秒期限内、无活动音轨，到期后仍0；native engine closed一次、双轨/worker约8025ms关闭。未点击预读视频3685558/audio2211838字节（约5.9MB合计），不是旧HTTP-only的0字节。原日志逐字节延续、哈希审计通过。session40正常关闭。
- 后续增加五首页短停留覆盖：保持当前APK，宿主工具增加home-rearm-stage=visible/immediate。在UI语义与内存检查完成后用真实反向短滚动取消旧预备；visible只等新同CID/标题/布局事件、不等URL或媒体ready，immediate滚动后立即点击旧验证卡片位置，实际打开CID不符则拒收。所有miss保留，不用之前3.6–4.5秒准备窗口冒充短停留。
- 新run-native-preload-varied.py计划native-preload-home-varied-01：自然/新可见/立即/新可见/自然五次，每次cold app，首个cold emulator，依然22秒18秒返回，并补未点击回收。宿主脚本语法通过；应用包/源码未改，不重建。下一session41。
- session41首条natural已成功：CID42672327055，纹理570.308/封面612.200ms，native实际claim，首冷模拟器/冷app。第二条visible尚未任何ADB页面操作或测量输入就失败：新工具rearm插在第一个check_memory处，video未赋值，UnboundLocalError。原capture.json/driver/host-tools完整保留，不算应用故障或性能样本。
- 已将rearm移到完成卡片metadata/采集准备后、输入窗口核查前，读实际上下文并验证两位置顺序。新run-native-preload-varied-followup.py在native-preload-home-varied-followup-01继续原计划2..5，不覆盖失败目录；本会话仍41且未重启模拟器，后续不能标cold-emulator。原第一条冷样本另保留并联合汇总。
- session41四条可用样本审计：自然612.200ms（冷模拟器）；visible644.971/547.531ms，实际native open仅在点击前432.024/374.602ms；immediate未命中URL/HTTP/native，998.022ms。四条返回cleanup通过；最长正timestamp间隔455.768/170.569/210.107/189.317ms。新native-preload-varied-partial-reviewed.json，不能漏报长间隔或未达标的immediate。
- 第五条CID42625008496已点击，18秒返回的adb input超时45s，精确日志pull也超时45s，不能获得完整测量。系统/proc/uptime也8s超时；宿主QA QEMU38412为stopped，内存采集门槛仍12.61GiB提交/8.76GiB物理。保存failure-host-state/resume-attempt：仅恢复这个已验证AVD的暂停进程后status running，但guest仍不响应；稍后进程自行消失，准备正常关闭时NoSuchProcess发生在任何关闭命令前。没有执行强制终止，不能写成正常关闭；原因未确定，未认定native预备导致。原driver/capture/host日志保留，下一短会话尝试按旧公告路径恢复文件，不把失败纳入正常速度。
- 实测宿主该QA占用约3.30GiB工作集/5.61GiB私有提交（guest设2.5GiB之外还有图形/虚拟机开销）；未因内存门槛停止本轮，未关闭用户其它应用。
- immediate瓶颈：主接口21.782→167.260ms；源open204.485ms；视频/音频首块391.98/453.32ms；buffering直到876.420ms结束。门控在538.06ms误将960×540占位尺寸判稳定，封面538.217解除，实际1920×1080参数877.22ms才到。这里只证明占位尺寸被放行与事件顺序，未做像素判黑。
- 下一叠加方向（尚未实现）：滚动取消native/HTTP资源时保留已完成且未过期的单条URL响应（仍严格账号/CID/参数匹配），避免此类立即返回同卡片再付146ms接口；输出门控必须排除真实源仍buffering时的占位稳定，并相应延迟辅助请求释放。既有native预备快样本保留，不撤回。
- session42先恢复41故障样本的两个精确公告文件，均存在但0字节；recovery-after-boot42保留空原件哈希、命令返回和assessment，不能恢复性能。此前home-preparation仅点击前记录，不拼造点击后的完整数据。
- session42短会话补第五条natural：native-preload-home-varied-final-01/05-home，CID42641525869，纹理472.223ms/封面596.423ms、native/HTTP/URL真实claim、冷app且本次冷模拟器。当前源18秒返回回收通过，独立06-unclaimed-expiry通过，测试后正常关闭。
- 五种计划场景合并成native-preload-varied-completed-reviewed.json，四次前置条件≤800ms（612.200/644.971/547.531/596.423），immediate998.022ms保留为未达标。替代补测单列coldReplacementSession，不改写第五条原故障，不作跨视频净增量/物理呈现声明。

### 第24轮：滚动保留已完成地址（独立变量，输出门控留待下一轮）
- 针对第23轮immediate重新请求145.478ms：RETAIN_COMPLETED_PLAY_URL默认false，只在首页ScrollStart保留已完成且原10秒TTL未过期的单条原始URL响应；取消HTTP/native lease照旧，后台/dispose/失败仍清空。
- key仍含账号、CID、质量、语言、响度等完整参数；不延长TTL，不复用可变PlayUrlModel。重新可见时从raw创建新model并重启媒体预备；微任务受generation与原cache条目复核，避免滚动/后台/claim后迟到创建资源。
- 新增五项测试覆盖完成/未完成、过期不续期、完整key、一次claim、后台清除与旧成功迟到。输出占位尺寸问题本轮不改，单独测地址保留增量后继续修复；不是忽略已发现的问题。
- 当前session42已正常关闭，无模拟器，构建门槛18.09GiB提交/12.71GiB物理通过。应用改动未构建/未实测，保留此前native预备收益。
- 29/29测试通过retain-url-tests-01；首次分析2项cascade样式提示已修，第二次4文件No issues found。宿主增加同卡片URL过期等待（原begin+10.2秒，之后仍真实滚动关闭媒体），复用进程按已公告精确traceFiles读取，不依赖logcat重新公告。Python语法通过。下一构建retain-url.apk保持native预备组合，仅新增地址保留flag。
- 同内容测试计划：retain-url-same-card-01，单APK/单进程/单首页卡片，预热+过期/有效/有效/过期/过期/有效。两组点击前均真实滚动关闭媒体/native；过期组等待原URL begin+10.2秒，停留时间不同会明确列为限制。必须实际URL claim符合分组且均无media/native claim，全部样本保留。新宿主4项测试（复用公告/TTL时钟/错误PID/坏时钟拒绝）通过retain-url-host-tests-01。
- retain-url.apk构建3m45成功，SHAa21067511baea8ebe0262b012dff670a07ad38859be355a629ffb94c9fcc6936；构建清单所有源码哈希一致，唯一新增define为RETAIN_COMPLETED_PLAY_URL。本轮Gradle71848确认完成释放。session43启动，准备同卡片实测。
- session43正在采集，00冷预热前置1617.525ms（native实际接管，但native桥接标记迟到且单次raster1294.924ms，原因待查），保留不计正式中位。首正式过期929.727ms/API125.884，保留966.328ms/API4.812，第二保留789.311ms/API6.844，第二过期987.497ms/API108.001；未跑完不可下最终结论。审计发现compact milestones不含nativePreload.claim，runner的无native检查不能单独采信；reviewer已加原始事件精确request/player/sourceRevision关联审计，全部正式样本最终必须通过，运行中runner及快照不改写。

### 第24轮结论（session43）
- retain-url-same-card-01预热+六次完整完成，正常关闭；CID42817293927、PID3548、同APK。原始当前request/player/sourceRevision审计证实六次均没有native接管、均没有媒体HTTP claim，URL命中严格符合交错分组。compact milestone原不含nativeclaim的工具边界已独立修正审计，不篡改运行快照。
- 过期组三次前置929.727/987.497/933.138ms；保留966.328/789.311/791.567ms，中位933.138→791.567，约改善141.571ms。API中位125.884→6.844ms；source.open到首纹理中位725.164→725.695ms，说明主要节约来自接口前置等待，剩余开源链路仍约725ms。
- 最长正PTS间隔中位86.079→135.876ms，保留组160.393/96.770/135.876ms；不能称连续性已改善。六正式加预热返回回收/音轨0通过。预热冷样本1617.525ms单列，不能隐藏；同视频重复打开与不同URL到期等待不等于所有内容冷启动或物理显示。comparison-reviewed.json保留全部数据。
- 决定：保留默认关闭实验与有效地址保留收益，继续叠加，不因一次966ms回滚。还需重新可见native预备、早退、暂停拖动/PiP、物理呈现关联与多视频复核。

### 第25轮：输出稳定检查排除仍在缓冲的占位
- SOURCE_BUFFER_READY_GATE默认false：原轮询/已有事件门控的有效条件均增加当前播放器buffering=false；事件门控订阅buffering变化并在finally取消，缓冲重新开始会清除稳定计数。原120ms/三次尺寸一致/PiP优先/5秒deadline策略保留。
- 仅修复已观察到的仍buffering占位被算stable；不是承诺buffering=false就是首帧。5秒旧deadline fallback保留并明确日志标记，异常样本不得当稳定放行通过；PiP仍原策略，必须另验。
- 新3项异步测试：占位等待不主动调度帧、恢复buffering清计数、取消后ready不能复活。尚未运行测试/构建/实测。下一session44，当前无模拟器。
- 第25轮24/24回归通过source-buffer-tests-01，3文件分析No issues found（source-buffer-analyze-01）。开始单候选source-buffer-ready.apk，保持地址保留/native预备组合、两事件门控/DM仍关闭，仅加SOURCE_BUFFER_READY_GATE。实际同内容净性能仍未测，本轮先检验错误放行和首页回归。
- 第25轮source-buffer-ready.apk构建2m17成功，SHAebfb51a04627385a8bf04fded519f80e88b701dd67ae476aa33cfc25021a6a78；源码清单逐项匹配、仅新增SOURCE_BUFFER_READY_GATE define，本轮Gradle41608已释放。session44启动，四个首页/操作场景待采集，尚无第25轮设备结论。
- session44四首页全部完成，stable事件均sourceBuffering=false且无deadline fallback。前置1658.395（首冷）、955.930（立即URL命中/无native）、600.626（短停留native命中）、569.459ms（操作回归native命中），不同视频不能当门控净增益。前3最长gap275.360/169.565/146.145ms；四次返回回收/活动音轨0通过，05未点击到期通过。
- 操作回归实际暂停6.120秒、恢复9.090秒，正PTS恢复9.178秒；进度语义定位花约3.26秒，实际点击15.276秒（不能记成12秒），seek后正PTS137.5秒在17.333秒被读取，buffering17.436秒结束，18.015秒返回。3.005秒间隔是主动暂停；seek等待约1.927秒单列，不混成普通连续播放卡顿。
- driver已执行sync和emu kill，随后进程77668的15秒等待超时，脚本抛TimeoutExpired且未写正常close报告；后续检查进程已退出，emulator-close-followup.json记录。保留此宿主收尾异常，不当采集失败/正常15秒内退出。当前无模拟器。
- 第25轮决定：保留buffering稳定检查候选与地址/native预备收益，仍默认false；冷启动两轮~1.6秒需下一定向图形诊断。44首冷长raster在点击后112.775–1394.328ms，而media.claim1427.518ms；初始videoState仍未挂载播放器，不能直接认定外部Texture首次绘制是原因。此前外部纹理预绘制仅候选，暂不实施。

### 第26轮：冷启动首次页面长raster定向诊断（未改应用行为）
- 目标是解释连续session43/44首冷约1.28–1.29秒raster，非凭猜测启用预绘制或更换渲染器。应用源码保持第25轮；单独profile包开启PLAYBACK_FULL_PROFILE，仅用于诊断，不与lean release速度比较。
- capture新增--engine-skia-trace，强制profile清单+冷首页+Perfetto，启动Intent传trace-skia/trace-systrace；本地锁定Flutter profile.jar的FlutterShellArgs常量已核对，官方源码也支持这两个extras。仍要以实际trace中出现Skia切片证明生效，不能因参数存在就当已采到。
- 8秒Perfetto，先按native触摸时间对齐页面首次raster，再检查GPU/Skia/调度切片；不使用截图/图像识别。所有诊断原件新目录。下一session45，当前无模拟器。
- 第26轮第一次build被门槛拦截，尚未启动Gradle，driver原件source-buffer-profile-driver.txt保留。发现session44遗留子进程记录70288（父77668/已核验QA runtime），ThreadCount0、HandleCount0、WorkingSet28672、private73728、cmdline空；psutil等待因OpenProcess拒绝访问失败，未操作/强杀未知进程。CIM原件和状态保存。
- memory-gate旧版按名称把零线程残留也算运行模拟器。已先备份原脚本，新版仅对线程0+句柄0+工作集<1MiB+命令行空的明确残留不计运行，单列InactiveEmulatorRecords；未知/活动/大内存记录仍阻止构建，RAM阈值不变。6项模拟输入回归通过memory-gate-zombie-tests.json，真实门槛重新通过17.91GiB提交/13.11GiB物理。第一次失败和修改前原件不覆盖，下一driver02重试。
- 第26轮profile第二次构建成功3m10，SHA9ba3b8a6ff64cfc362ed668bfc55ba76775c9a59b1f2d7e12c460aba5294db25，profile清单releaseSpeedComparable=false，所有源码哈希核对通过，本轮Gradle59716释放。session45启动（39168），原零线程记录70288仍在但单列非活动，不关闭用户应用。下一冷首页一次Skia/Perfetto诊断。

### 第26轮诊断结果（session45）
- source-buffer-profile-home-01完成，8秒trace约5.88MB，sync/emu kill返回0且30秒内退出，回收通过。profile首纹理1242.727/封面1365.482ms仅诊断，不与release比较。skia-analysis保存SQL/CSV/原trace/时钟对齐。
- 最大初始raster1025.161ms，点击后67.688–1092.849ms；主线程DartMessenger native_device_orientation_events处理77.728–1042.343ms，共964.615ms，期间主线程约958ms睡眠。当前插件onListen在主线程构造SensorOrientationListener并同步启动，内部getSystemService/getDefaultSensor/registerListener，构造玩家controller即订阅。
- 同期raster线程约952ms处于Running，io约931ms Running；所以主线程方向通道长等待与长raster重叠尚不能证明是唯一根因。此次无Skia/GrGL编译切片，trace参数传入但细分Skia覆盖未证实，不能宣称排除着色器或完成物理呈现。先做可分离服务初始化实验。

### 第27轮：后台只初始化方向服务（实现中）
- WARM_ORIENTATION_SERVICE默认false。第一应用帧之后通过专用MethodChannel触发一次后台任务，在同Activity context调用getSystemService(SENSOR_SERVICE)+getDefaultSensor(ACCELEROMETER)，分别记录耗时。绝不registerListener、不采集传感器值、不改变旋转/设置；原native_device_orientation订阅时机和代码保留。
- 一Activity最多一次任务，线程任务结束shutdown；onDestroy关闭通道和执行器，后台系统调用不强行打断，迟到回复不发给销毁engine。Dart一次Future合并重复请求，3秒有界等待并吞预热失败，普通播放器继续原流程。诊断marker在稀疏日志文件创建前也能留logcat。
- 新StartupOrientationServices.kt/orientation_service_warmup.dart、MainActivity和main接线、builder开关/源码快照。capture在点击前/返回后采sensorservice状态以核对没有新增常驻监听；监听仍由原播放器管理。尚未构建/实测，不能声称已解决冷启动。
- 第27轮Dart两次分析No issues found；新增一次共享pending请求/3秒超时/Activity销毁迟到失败不向外抛回归通过orientation-service-tests-01。构建门槛16.86GiB提交/13.58GiB物理通过，零线程残留单列。开始orientation-service.apk release构建，唯一新增WARM_ORIENTATION_SERVICE实验，应用其余组合保持第25轮。
- 第26轮补充系统呈现覆盖核查：FrameTimeline并非完全为空，actual/expected各278条；其中269条属于SurfaceFlinger、9条属于SystemUI状态栏，PiliPlus PID3491无应用surface条目。已保存frame-timeline*.sql/csv/log，不能把全局显示时间套给视频，也不能声称采到了视频物理呈现。
- 第27轮orientation-service.apk成功4m25，SHA14f646aed5df4347a8996336788068d5c5b881bb9d7746f932c61a481ad1a2c4，源码逐项哈希核对通过；仅新define WARM_ORIENTATION_SERVICE。本轮Gradle31932及自己旧profile遗留Kotlin5764在构建结束后核对释放。session46启动。实际采集前修宿主工具：取消点击前dumpsys sensorservice，避免测量工具本身提前访问系统服务混淆初始化收益；返回后快照保留，若验证空闲无监听另单独做。APK不变，采集host-tools将保存新宿主版本，与APK包内旧宿主快照分别记录。
- session46首次等待Wi-Fi关联20秒未通过，未启动runner/安装/点击，失败未算性能样本。核对Wi-Fi开启但未连接，重新连接已有AndroidWifi后关联成功，emulator46-wifi.txt保存；开始orientation-service-home-01。

### 第27轮结论（session46）
- orientation-service.apk SHA14f646aed5df4347a8996336788068d5c5b881bb9d7746f932c61a481ad1a2c4，三次首页前置1529.285/949.028/580.399ms；首冷raster1264.176ms。背景查询服务仅12.177/5.150/6.505ms，不能解释或消除约一秒等待。不同视频不得当净增益。
- 三次返回回收/音轨0及04未点击到期通过，session46正常关闭。返回后的sensorservice只有系统UID1000活动连接；本app历史注册/注销存在，无活动连接。首次Wi-Fi等待20秒失败发生于安装/点击前，重连后成功，原始记录保留。
- capture点击前sensorservice查询已移除，避免测试工具自己预热服务；只保留返回后快照。以capture host-tools为实际工具版本，不能混称旧APK快照。

### 第28轮：方向插件分阶段计时（诊断，尚无修复结论）
- 管理副本tool/startup_orientation_timing三个Java文件仅添加Trace/单次阶段耗时日志，区分构造、初始显示方向查询、创建事件监听器、服务/设备查询、注册传感器。未改原有方向行为。
- builder --orientation-timing检查依赖精确Git版本与干净状态，保存原字节，构建try/finally恢复；APK清单记录原始文件哈希，源码ZIP保存计时副本。capture纳入PiliOrientationTiming标签，不使用图像识别。
- 保持之前native预备、地址保留、buffer-ready和背景查询组合。新orientation-timing.apk单独诊断构建，下一session47只采首冷首页，目标定位耗时后继续改，不把计时包视作0.8秒达成。
- 第28轮构建1m52成功，SHA7480f42e25d5cd3250b5b3c76bdd759e2234263589365ef978152e5fdc51376a；所有源码哈希一致，方向依赖Git干净且三个原字节哈希恢复。已核验释放本轮Gradle76268，下一session47冷首页计时。
- session47首次home-01在点击前失败：20秒没有startup.visibleCard/URL-ready，首页语义可见推荐列表，未发生方向监听/视频打开。完整probe、logcat、failure-ui.xml保留；当前尚未首次播放，使用新目录home-02冷app重试，不覆盖失败。
- 重试脚本启动前发现Wi-Fi已断关联（原before快照曾连接），所以未创建home-02/未安装。补连并连续核查后再试；连接记录emulator47-wifi-reconnect.json，可能解释首次无visible事件但不当成唯一证明。
- session47 home-02成功：CID43098836098，texture500.098/cover528.005ms，maxRaster61.624ms；方向construct0.369/start7.514/registerSensor6.409ms。此为冷app/该模拟器首次播放，但此前两次点击前app启动/联网重试使设备已运行约243秒，未复现长帧；不能声称计时修改提速或传感器就是病因。返回cleanup和连续性审计通过，reviewed.json保存原时钟关联。下一新冷session48同包复查。
- session48新冷模拟器复现慢样本：CID42803269440，texture1368.809/cover1457.465ms；registerSensor1192.810ms，start1193.801ms，显示方向0.113ms/查询服务0.070ms/设备0.065ms。返回回收与连续性审计通过，正常关闭。首次明确定位注册同步阻塞主线程，仍需修复后验证其对总耗时的因果贡献。

### 第29轮：传感器注册/注销串行移出主线程
- 计划只将registerListener/unregisterListener移到一个惰性单线程执行器，方向回调仍显式发给主线程，原方向计算/阈值/自动旋转偏好不变。
- 生命周期世代控制：退出/暂停立即禁止旧回调；排队注册可取消，已经开始的注册结束后如过期则立即注销；重新进入只能接受当前世代。测试真实阻塞注册期间取消、取消后重启、排队取消和失败，不靠截图。
- 构建实验默认不启用；用独立--async-orientation-registration及管理副本注入，构建后恢复缓存。保留前面各项有效改进。尚未完成实现/测试。
- 第29轮实现完成：SerialSensorRegistration管理世代和worker拥有的注册资源；仅一个惰性daemon执行器，后台串行注册/注销，显式主Looper传回原始SensorEvent。静态默认构建不注入，只async实验开关选择管理副本。六类真实线程/手动队列测试通过orientation-async-tests-01（阻塞取消重启、即时回调拒绝、重复enable、排队取消、false返回、异常清理），builder语法通过。开始orientation-async.apk。
- orientation-async.apk构建1m48成功，SHA2dd73d55411aef985ea8972cdc1a276763ed1a0692afb4428fa51aec1d0cabba，源码哈希一致/缓存所有原字节恢复/新增helper已清除/依赖Git干净。本轮Gradle52064已核验释放。下一session49三首页后expiry，再独立冷早取消。
- session49首次Wi-Fi关联20秒失败，尚未运行runner/安装/打开app；原wifi.json保留，第二次关联并连续验证后开始采集。
- session49完成：首冷1488.415ms、immediate807.009ms、visible588.267ms；三条返回cleanup与04expiry通过，正常关闭。首冷raster1259.132ms，方向construct在点击后1283ms才开始，start3.146ms/worker注册17.685ms，源接管1297.805ms。异步调用已生效，但长帧先阻塞，不能报整体修复/净改善。
- 与48区分：48raster仅68.273ms但main注册1192.810ms；49长raster在注册之前。两种阻塞位置不能混为单一病因，继续保留并分层诊断。下一50冷早退；随后用VM timeline而非此前未覆盖Skia的systrace定向检查首帧绘制。
- session50首次ready后三次已连接仍立即被系统断开，runner在创建目录前拒绝。dumpsys证实NETWORK_SELECTION_DISABLED_NO_INTERNET_PERMANENT；备份qa-network-validation-before.json后仅QA设置captive_portal_mode=0并重连稳定验证。此后是网络探测关闭的新环境，不能与旧速度样本无条件混比；最终必须恢复原值。未改DNS/CDN/画质。早取消为功能回归。
- session50早退采集正常关闭/回收通过/返回后无本app传感器连接/没有route.leave之后command.play。但未覆盖首纹理前取消：tap同步命令被长绘制拖住，host的0.140秒从tap命令返回才计；实际纹理1485.522ms、route.leave约1486ms。此缺口明确保留，不能用计划0.12秒代替实际时间。

### 第30轮：VM Skia时间线诊断
- 官方VM文档确认systrace recorder不能getVMTimeline；此前系统trace没有Skia细节不能当没有shader问题。新增--vm-skia-trace仅profile冷home，trace-skia=true但不启用trace-systrace，连接当前PID公告的VM服务，启用Dart/Embedder/GC，输入前clear，约6秒后停采保存完整事件，最后恢复streams并移除临时ADB转发。无像素采集。
- 复用第26轮source-buffer-profile.apk诊断同一首视频页绘制，包没有新async方向改动，不能作其速度对照。独立目录/工具快照。下一session51。
- session51 VM采集成功：当前PID3441 Ring recorder，20579事件/3.51MB，实际起止103.672–109.765s覆盖输入103.728s；采集后streams恢复/临时转发删除，返回回收通过，模拟器正常关闭。
- 同步旧profile包前置1687.254ms，source.claim1313.130ms；maxRaster305.192ms，真实shader_compile261.014ms（driver_compile141.597/link78.566ms）。这只定位约300ms绘制，不能用shader解释前置1.2秒未在VM内表示的原生注册。手工span解析边界5个begin/0个end未配对保留，原始JSON完整。

### 第31轮：在异步注册版本上采VM绘制时间线
- 用当前orientation-async同源码/开关，独立--full-profile诊断包orientation-async-profile.apk，保持网络探测关闭的新环境。目标分离注册与绘制两项，而不把旧profile/新release速度混比。下一session52，仍单次冷home/六秒VM窗口。尚未构建/实测。
- orientation-async-profile.apk构建2m30成功，SHAf2a891f4e59ab0bf657932da674be46c9c4268e310441f283556020e4db6c9a1，源码快照匹配/方向缓存恢复。尚未安装。构建结束后发现AudioServiceActivity.provideFlutterEngine经AudioServicePlugin直接new FlutterEngine(applicationContext)，忽略Activity传入trace-skia。51只确认默认shader覆盖，没有具体draw-op覆盖。不能沿用“全Skia已开启”的假设。
- 增加profile-only manifest授权的引擎预初始化，在MainActivity.super.onCreate之前仅按trace-skia布尔请求启用固定--trace-skia参数（普通release无该metadata不生效）。再构建orientation-async-skia-profile.apk；保留刚才的包但本轮不安装它，避免无效重测。
- 完整Skia profile修正包28秒构建成功，SHAc364920653c9075dd14298f7e02e9f7f6aac1f89b37a1d3fbb62431cf8f002d2，所有快照匹配/方向缓存干净。已核验释放本轮Gradle49700与此前自己构建留下的Kotlin55112。下一52，vm-skia-async-home-01，必须出现初始化日志和实际draw-op事件才认可完整覆盖。
- session52完成并正常关闭，native日志证实完整Skia在audio engine之前启用。texture1645.147/cover1635.294ms、raster1322.376ms；方向start8.188/worker注册9.943ms，但都在长raster末尾才开始。返回cleanup通过。
- VM结果不具备起播诊断覆盖：Ring最多约32768事件，实际32732条只剩113.934–114.529s，而输入108.489s，coversInputStart=false/未配对end9个。不能解释1322ms长帧；原文件保留，不把未发现shader当无shader。

### 第32轮：完整Skia记录避免循环覆盖
- profile授权且显式trace-skia时，在初始化固定参数中增加--endless-trace-buffer，仍限定采集六秒并收尾恢复/关闭。仅诊断包、非release测速。新orientation-async-skia-endless-profile.apk，新目录vm-skia-async-home-02；必须核对recorder、首输入覆盖和具体Skia父子操作再下结论。
- 第32轮57秒构建成功，SHA0f60114945755f94ea448dae42ee014435668c58e97e8dbf96ad52d943914d05；快照一致/方向依赖Git干净，已核验释放Gradle51492与Kotlin26972。启动53收集完整六秒Skia，结果待验。
- session53完整Endless采集成功126014事件/19.34MB，streams恢复/转发移除，返回回收通过，正常关闭。前置1544.680ms/profile诊断不可当release速度。
- 已完整捕获frame45：输入+68.191ms开始，Draw1313.204ms；onPrepare1242.332ms，其中AtlasTextOp1237.474ms（+102.306到+1339.780），内部没有shader子事件。shader累计278.666ms在其它操作/帧，不解释这个文字图集准备长等待。
- reviewer原coversInputStart=false只是最早事件比输入晚4.691ms，不能等同环形覆盖：collectorStart比输入早64.647ms且Endless，frame45的B/E和全部父子完整；atlas-interpretation.json明确这个指标区别，旧报告不改写。52是真实覆盖丢失5.4秒，两者不得混淆。
- 下一方向：定位视频页首帧文字/字体图标（尤其尚未挂载真实player时的tab/弹幕栏），定向预备相同字形，或针对实际贵操作修复；不盲目更换渲染器，不把AtlasTextOp无子事件进一步断言成某个字体。

### 第33轮：首视频页字形定向预备
- STARTUP_TEXT_WARMUP默认false：首次首页post-frame启动一次，分别绘制CustomIcons.dm_on/dm_off(22dp)、简介/评论(13dp)、发弹幕(12dp)，采用当前DPR/主题字体/文本缩放；逐项记录layout/raster时间。
- 仅离屏字形绘制并立刻dispose图像、picture、TextPainter，不保存/读取像素，不改界面、画质或媒体。导航/后台后不继续下一项；已提交绘制无法中断但资源finally释放。与旧预备组合并行，不把它加为点击前必等条件。
- 假设针对frame45 AtlasTextOp1237ms，但尚未证明哪种字形或离屏缓存能复用。必须测预备本身成本、首冷起播和立即点击，失败也留存。当前代码刚完成，未分析/构建/设备测试。
- 第33轮两文件首次分析1项cascade风格提示已修，第二次No issues found；原两份日志保留。开始text-atlas-warmup.apk轻监听release，保留async方向/URL/native/source-ready组合，只新增字形预备。新run-text-atlas-home.py三首页+expiry，下一54。
- text-atlas-warmup.apk构建3m19成功，SHA0aa76b0331942671cb55cf86b42a3c15d2ed26cbf9419fcc413469c02a842bf3，所有源码快照一致/方向依赖Git干净；release合并manifest没有StartupTraceAllowed，因此完整Skia/Endless授权不进入release。已核验释放本轮Gradle22960及其Kotlin子进程。下一54三首页+expiry。
- session54三首页完成，前置1612.115/1060.899/611.268ms，三次回收+04expiry通过，正常关闭。首轮四项预备合计332.189ms（dm_on111.363raster、dm_off121.975、tabs69.216、prompt14.889ms，另含layout），但冷长帧未消失。不同视频不报告负净增益；没有正收益证据，该新实验继续默认关闭，源码和数据保留，旧native/URL改进继续。
- 下一轮记录首页退出/视频首layout时实际RenderParagraph字形、字体、字号和变换，区分进入页文字与旧首页缩放相关绘制。不凭AtlasTextOp名称指定字体，也不直接更换用户动画。

### 第34轮：首过渡文字布局清单
- 第33轮数值勘误：预热四项总耗时为331.389ms，前述332.189ms是抄录错误；原reviewed.json正确。
- 新增默认关闭TRACE_STARTUP_TEXT_INVENTORY，只读取首页被覆盖/视频首layout的RenderParagraph字体、码点、字号、DPR和全局变换，最多128项，排除offstage/完全透明节点，不采图像。异常单独记录，不阻断播放。
- 目的定位AtlasTextOp对应字形及缩放；本次不启用上一轮text-atlas-warmup。保留所有URL/native/source-ready和方向异步改动。3文件Dart分析No issues found，日志text-inventory-analyze-01.txt。准备独立text-inventory.apk和单次冷首页text-inventory-home-01，下一session55。该额外监听仅诊断，不作为净提速对照。
- 用户询问指标口径：已核验results.json最低前置528.005ms（orientation-timing-home-02；设备前有联网准备，非纯新启动环境；命中native），该值是texture+cover条件就绪，不是物理呈现。第33轮immediate/visible不等待media-ready；visible实际额外等待卡片监听0.904秒，immediate未特意等待。两视频不同，不能将差额当净收益。
- 第34轮text-inventory.apk构建2m21成功，SHAbb6d148fd21b526a1f1455cfb4ab0db2b3da28621519e00c027937abb2d597aa，71项源码快照核验一致，方向依赖还原干净。尚未安装，用户插入手机release打包请求，完成后恢复session55。

### 用户手机release包（第34轮期间插入）
- 用户要求先提供三个场景综合较快版本，明确release，完成继续原工作。采用orientation-async组合，关闭第33轮未证明收益字形预热、第34轮字体诊断及所有Dart/texture持续采样。当前没有三个场景全部稳定0.8s版本，已告知。
- builder新增--target-platform和--no-trace，默认模拟器行为不变，no-trace与诊断参数互斥；手机ARM64，仍生成源码快照/构建日志/哈希。方向注册原生少量阶段日志保留，不启动持续采样。版本/签名沿用仓库既有配置；此包供用户实测，不能称为手机验收通过。
- 手机包2m42构建成功，output/startup-20261030/PiliPlus-startup-arm64-release.apk，SHA8b94198d246ac0baf735728859eae518bc6fa0dbe6d4708464f92c61912db557，39401134字节；签名验证通过且与旧手机2.0.10包同证书，manifest非debuggable、无profile Skia授权，仅ARM64 libapp/libflutter；所有71源码哈希核验。PLAYBACK_TRACE/STARTUP_TIMING=false；未做手机运行验收，交给用户实测。现在恢复第34轮session55诊断。
- session55 text-inventory-home-01完成，CID42482664780，texture1421.841/cover1591.743/maxRaster1243.471ms，最长正纹理gap95.278ms，返回回收通过，正常关闭。首视频layout26段含6个FontAwesome操作图标（Regular/Solid，18dp），上一轮预热未覆盖。首页两次清单各87段包含视口外已布局卡片，不当全部实际绘制；变换单位缩放也不排除SnapshotPainter后续变换。原字段完整存text-inventory-events.json，汇总reviewed.json。初次控制台输出私用区字符GBK失败，仅打印失败，原JSON未丢。

### 第35轮：仅预备实际首layout的六个操作图标
- STARTUP_ACTION_TEXT_WARMUP默认false，与旧STARTUP_TEXT_WARMUP独立；只按实际18dp字体预备thumbsUp/thumbsDown/b/star/clock/shareFromSquare，依次记录layout/raster耗时。不改UI或导航动画，不启用text inventory，不预备旧四项。保持一次/当前页/后台取消及image/picture/painter释放边界。
- 这仅验证漏掉字体是否与AtlasTextOp长等待有关，不提前认定根因。准备action-text-warmup.apk轻监听release，三首页+expiry，下一56。用户手机release文件保留原包，不受后续源码变化影响。
- 第35轮2文件Dart analyze No issues found（action-text-analyze-01.txt），开始action-text-warmup.apk；无活动模拟器。
- 首次action-text-warmup.apk构建6m22成功，SHAb1e81cc7e00e81153f693dcf238888eaf2fbbbaf8633402cacf9dace113146d2，源码快照核验一致，但未安装：构建期间只读复核ActionItem发现实际未选中图标colorScheme.outline，原实验用白色，存在字形缓存luminance不同的混杂。先保留首包，修正主题颜色后另包action-text-outline.apk再测，不能以已知不匹配测试否定候选。
- 修正outline色的action-text-outline.apk构建1m49成功，SHA33bfcad72edd3f9e214c89000045fb8c57ac7ad73ec9c5676312b2e480ed0111，71源码哈希核验一致，只启用actionTextWarmup；新日志包含colorArgb。下一56三首页+expiry。
- session56三首页完成1762.109/945.130/505.088ms，maxRaster1323.977/139.957/101.571ms，预备509.379/377.112/323.164ms；三次返回回收+04expiry通过/正常关闭。短停留505ms为新最低样本，但不同视频不可归因净收益；首冷长帧仍在，此预备继续默认关闭，保留代码与数据，下一原生栈诊断。warmup-reviewed.json完整保存每项成本/颜色/事件。

### 第36轮：绘制线程原生CPU调用栈
- 复用第32轮已有orientation-async-skia-endless-profile.apk，不增加构建，不启用任何字形预备。新startup_native_cpu.py通过系统simpleperf，仅当前进程唯一.raster线程，task-clock:u 200Hz/DWARF栈/8秒；与完整VM Skia窗口同轮关联。只在--vm-skia-trace已限定的profile模式可用，不作为release速度。
- 每次独立远程UUID数据文件，记录完整命令/线程/采样器哈希/返回码/原始data；finally等待有界采样结束并拉取，无全局kill、不改设备profiling配置。采样覆盖和符号可用性必须事后验证，不能凭工具启动声称拿到栈。语法解析通过。下一57单次冷首页native-raster-home-01，尚未设备验证。
- session57首次在输入前失败：toybox ps的NAME列给进程argv名，所有行同包名；已实查CMD给线程comm（1.raster TID3476），改为TID,CMD并记录发现失败。无有效起播数据。当前profile应用1秒system simpleperf -g/task-clock:u预检成功，idle0样本符合未操作状态，日志simpleperf-preflight.txt；未导航/未播放。57正常关闭，下一58新冷重试native-raster-home-02以排除设备已运行延长。
- session58成功采集/回收/VM streams恢复/正常关闭，texture1552.216/cover1713.477ms。VM162412条完整覆盖，首Draw1279.597ms但长在LayerTree::Paint1257.245ms；CPU仅30样本共150ms，首样本input+1596ms，目标长帧+169.664到1449.261ms内0样本。未等待采样就绪，仅固定300ms，不能据稀疏样本称offCPU，coverage-reviewed明确无覆盖。
- 改用AOSP正式--stdio-controls-profiling并等待stdout started（DoRecording在JIT/maps/event准备后发出）才允许点击，8秒确认上限/进程退出即失败；独立control.log，原8s采样上限保留，finally关自身pipe/reader。官方源码和NDK ProfileSession一致。下一59新冷native-raster-home-03，不构建应用。
- session59 ready确认成功（初始化635ms），但结束拉取Dart trace临时失败。原远端文件存在，recovery-01重新获取同公告文件、hash/全行JSON校验完整、原错误保留；恢复wrapper首次漏建app目录，原两文件已审计，创建后按哈希复制，未重测/未篡改原capture。texture1742.776ms/maxRaster1507.460ms，回收通过，59正常关闭。VM141473条首长Draw1507.863ms中drawGlyphRunList1244.002ms无用户态CPU样本；29 CPU样本中首个input+58.077ms确实覆盖长帧开头，整体长Draw内2个，文字长调用内0个。只能说此段未观察到用户态CPU执行，不能直接认定锁等待/驱动。
- 36继续：新增native-offcpu-trace（仅native CPU+profile VM模式），仍只当前raster线程8秒，采调度切出调用栈，保持started确认。下载官方当前引擎symbols.zip44.7MB，SHAa66a354e9f862cdeaf45c96ac6fb5b54465c5b80e3610a685154b6a93d4280e8，APK/符号Build ID均f934dda83861bb5d8bceeeb75809ebe0f802cd45，证明精确匹配。尚未取得offCPU样本。下一60 native-raster-home-04。

- session60 native-raster-home-04完整采集/回收/正常关闭：texture1723.815/cover1666.406ms，VM首Draw1377.958ms，shader_compile1312.759ms。mixed simpleperf报告glCreateProgram→QemuPipeStream→read链累计1218.586ms；但Python显式off-cpu仅90.954ms总量、该链0.658ms，两个口径不一致，不能把mixed累计说成已证明1.22秒offCPU等待。此前口头等待归因须保留此限定；原始data/两种报告保留待解释。

### 第37轮：依据手机反馈检查非零位置续播
- 用户实际手机release反馈：应用首次点击与后续点击差别不明显，同一视频再次打开似乎更慢；进一步确认会从上次位置续播。优先处理该路径，暂缓模拟器冷绘制长帧归因。
- 代码明确非零seekTo会跳过native preload及并行媒体源，且清理零位置预备。旧uncut-resume-02为4699.5ms、hedge-zero-resume-01为4493.5ms，两者首次buffer结束后仍约3秒才有正纹理；未解决。不能仅据分支断言全部原因。
- 计划复用orientation-async.apk轻监听release，同一固定CID先0/60秒/0秒对照，记录startPosition、source/open/buffering/纹理与回收；这是显式进度的路径隔离，随后另做真实同视频返回重进。应用暂无新增改动。

- session61第2条同CID60000ms续播已复现：texture4340.597/cover4386.911ms，buffering false1230.178ms，间隔3110.420ms；maxRaster109.402ms。第1条0起播3139ms含1013ms首冷长raster，不能直接当净差；第三条0仍采集中。下一只读分类解码/seek诊断，保留准确续播，不以关键帧偏移冒充加速。

- session61第三条0ms为1167.727/1229.634ms，完整三次采集/正常关闭；首冷3139ms单列，不与后两条净比较。新增StartupProbe有限seek阶段分类（无原始URL/报文），准备resume-deep.apk仅诊断精确seek/decoder首3次，复用所有最新优化；下一session62单次60000ms。

- resume-deep.apk构建3m34成功，SHA44f51654f53fe8abb036f94433d8bd9fb078dce70e52d9f7bbd03c6248cbaf78，71项源码哈希一致；Gradle74264按开始时间/命令及repo日志核对后释放。下一62非零60000ms定向诊断。

- session62 resume-deep-01捕获完整，但输出stable断言失败：输出超时、texture8473.222ms/首PTS62.5秒，不当性能样本。正常关闭。阶段日志：buffer false3139ms同刻发起精确seek；两轨范围请求依次完成3505/3708ms；首输入PTS55秒3775ms，首解码输出55秒4442ms，mpv.firstFrame5795ms；后续纹理更晚，重日志扰动不能与lean速度净比。已知非零重取范围+55→60预滚动是真实路径，尚不能把每段Dart投递间隔当原生执行时间。
- 宿主新增--reuse-search，核对上一capture成功/同APK/同PID/同CID，返回后替换已验证URI，再用native seq界定新请求，避免把首轮帧混到重复点击。旧同CID窗口测试通过，新UI重用待实测。

### 第38轮：非零续播启用并行媒体初始化范围
- 新PARALLEL_RESUME_MEDIA默认false。仅将现有普通网络双轨并行路径扩展到非零位置；保留精确Media.start，仍清理零位置可见预备，不接管其decoder。已有ParallelAudioSource范围重定向原样保持Range语义。假设仅缩短初始化HTTP串行部分，不预先声称解决全部3秒解码等待。
- 计划同源码resume-parallel-control/candidate轻监听，不启用deep；既有范围字节完整性/seek绕过阻塞测试及分析后构建，再同CID60秒ABBA。已交付手机包保持原文件。

- 38轮14/14范围及isolate生命周期测试通过，controller分析No issues found。准备两包同源码轻监听，60秒续播预热+ABBA，实际首PTS限定60–60.5秒，保持同画质/精确定位，异常保留。

- 38轮两包构建成功：control d789c9a18ebfe31bd75eeff3bae7545373a005f14bca0c25910b21f4bfa1a3aa；candidate c8181c80b49e3877966b4790ab21fedf2478ff917dc57410f4e9422217b53aa6。71项源码哈希一致，唯一define增量PARALLEL_RESUME_MEDIA=true。Gradle66124按开始时间/命令及repo日志核对后释放；下一63预热+ABBA。

### 第39轮准备：可见视频精确续播预加载（未测试）
- 第38轮APK已冻结并在session63交替采集，以下源码是下一实验，不进入38轮包。VISIBLE_RESUME_PRELOAD默认false且builder要求native preload+parallel resume。可见卡片预测允许API给出的非零进度，lease/cache key新增精确Duration，prepare Media.start使用相同值。接管额外核对immutable start与paused/pending-or-target position，原URL/账号/headers/settings/8秒取消边界保持；显式不同进度必丢弃旧预备，普通路径继续精确start。
- 新测试覆盖非零位置失配关闭且迟到结果不能重入、毫秒位置精准接管及UI clear不误关。尚未运行Dart工具/构建，遵守采集中不运行编译分析。

- 38轮session63预热+ABBA完成/正常关闭。控制4311.170/4021.143ms，候选3984.495/3850.575ms；首纹理中位4166.156→3917.535，前置中位4212.664→3954.949。全部首PTS精确60秒，返回活动音轨0，候选双轨+worker closed审计通过；连续性报告保存。两样本/组仅有限改善，不称稳定达标。保留parallel resume供下一轮叠加，默认false。
- 用户追问口径：点击→正纹理消费定义保持；旧0.x/1.x多为零位置及部分preload命中，这组为60秒续播，不可混比或暗示原零起播退化。后续必须在标题/汇总明确区分场景。
- 39轮增加STARTUP_TEST_RESUME_MS显式QA本地响应夹具，便于独立账号环境真实首页预备60秒；no-trace禁止该参数，需frame/continuity诊断。仅覆盖本地响应，正常播放历史行为仍保留；测试不冒称真实服务器历史。源码六文件分析No issues found，新测试运行中。

- 39轮30/30测试通过，六文件分析clean；resume-native.apk构建3m33成功，SHA91d89f61d618c58bd0fb77907da7ca51d136545903d256ce2e238d6e5d6af0a1，71项源码及原依赖恢复核验完成，已核身份释放本轮Gradle56160。首次释放核验把cwd误写为android而中止，无终止操作；查真实日志cwd为repo后严格重验完成。准备session64，同PID同首页卡片自然/立即/短停留，局部60秒响应夹具，实际首PTS必须60–60.5秒，另验未点击到期回收。

- 39轮session64完成/正常关闭，resume-native-home-01同PID3535/CID43124982954：自然首冷texture1512.156/cover1750.455ms，立即3712.466/521.016ms，短停留3212.988/3251.249ms；全部首PTS精确60秒，native接管分别是/否/是，三次返回清理与未点击8秒到期通过。属于本地响应60秒夹具，非真实服务器历史验收；不同于38轮CID，不能净A/B。保留实验但未达0.8。
- 新缺口：立即点击的output.stable在521ms依据960x540 rgba预备输出+buffering=false提前放行，真实1920x1080 mediacodec params/正纹理约3.7秒才到。首纹理口径未变；cover单独不能充当起播。下一轮优先修正placeholder有效性，继续精确续播取流/解码优化，不把延后cover称加速。

### 第40轮：当前媒体原生帧事件门控（默认关闭）
- 官方mpv force-window文档确认无视频也可960x540输出；不硬编码尺寸/像素格式过滤。SOURCE_FRAME_READY_GATE复用已有MpvFrameGate，加载前独立弱client记录START_FILE→匹配FILE_LOADED→有效VO的PLAYBACK_RESTART，排除旧队列/seek未完成；正常open不等待它，保持取流与界面重叠，封面放行时才要求本次事件。预备引擎携带同一gate接管，取消/替换/到期释放；原5秒fallback与PiP策略保持，事件不是物理呈现证明。
- 新开关builder记录，源码清单补入原有frame gate及其测试；尚无实机结果。下轮三次同PID60秒夹具、稳定事件须sourceFrameReady=true，回收/expiry再验。

- 40轮39/39原生事件协议/资源转移/输出门控测试通过，三文件分析clean。source-frame.apk构建中（exec8083），应用源码冻结。下一65 run-source-frame-home.py。

- 40轮source-frame.apk构建2m16成功，SHA933fc72bf9dc2d8de8a0ec2ae260855f6130e25c86d25c247943693e380a1904，73项源码哈希一致、方向依赖已还原，本轮Gradle11900核身份释放。启动65。

### 第41轮准备：MediaCodec工作速率提示（当前未验证）
- 40轮APK已冻结/核验；当前源码单独新增STARTUP_CODEC_OPERATING_RATE整数默认0，Android vd-lavc-o与原ndk选项合并，实验240，保持媒体流/精确位置/画质。builder拒绝负数及大于1000并记录manifest，诊断同时记请求值与mpv options读回值。当前不构建/分析以免干扰65采集。准备同源码0/240两包与固定CID60秒ABBA，首PTS限定60–60.5秒，另核原生配置与连续性，实验有功耗影响可能，未推广。

- 40轮session65完成/正常关闭：同PID3402/CID42787999571，首纹理1638.556/4064.133/3146.473ms，cover1890.045/4426.495/3382.954ms，全部PTS60秒；三条原生sourceFrameReady先于stable，未再接受占位输出。立即点击native ready4369.845晚于正纹理305.712ms，cover再晚56.65ms，额外等待有记录，不能当加速。三回收与未点击到期通过，连续性报告齐。不同39轮视频，不当净速度AB；实验仍默认关闭，接受条件并未全达。

- 41轮分析clean，control/candidate构建成功（2m15/1m45），73项源码完全一致；唯一define差STARTUP_CODEC_OPERATING_RATE=240。包哈希详见codec-rate-builds-verified.json，方向依赖恢复、本轮Gradle77628核身份释放。下一66固定CID60秒预热+ABBA。

- 41轮session66首冷warmup捕获完整但stable断言失败，原件codec-rate-pair-01保留。首纹理6364.361ms/PTS60秒，原生ready6662.556ms，稳定门控在6699.432ms达到原5秒上限（仅余约37ms不足三采样），fallback真实触发，不能算通过。返回回收通过；不中断已完成预热的同一AVD，另建codec-rate-pair-02接续正式ABBA（所有正式样本仍严格要求stable和sourceFrameReady，未放宽）。

- 41轮session66正式ABBA已完成/正常关闭；control3869.658/3820.632ms，candidate3877.028/3926.653ms；首纹理中位3845.145→3901.841ms（慢56.696ms），前置中位4158.906→4152.171ms（差6.735ms不足有效改善）。全部首PTS60秒、四条严格stable+sourceFrameReady及回收通过，连续性报告保存。mpv options读回operating_rate=240已证，硬件是否采纳提示未证；没有首纹理收益，保持默认0不推广，保留实验代码/原记录。

### 第42轮调查：续播范围索引
- session66已结束后，匿名公开API只读取同CID两轨各64KiB文件头，未改QA账号/画质。resume-index-probe-01/reviewed.json及两个prefix.bin保存：均206、有完整sidx（video1083..2970/audio837..2664），可映射60秒数据范围。所选匿名video track32/HEVC，非QA实际同画质轨证明；只证明机制可行，不作为性能测试。video60秒段offset1862693/170715bytes，audio覆盖55.1467..60.16秒offset628712/58528bytes。后续可以在双轨初始化期间并行预取目标范围，须兼容关键帧前滚与seek原始Range，不变精确进度。当前未实现。

### 第42轮实现：按 sidx 预请求续播范围（默认关闭，待设备对照）
- 新 PREFETCH_RESUME_RANGE 仅在 isolated parallel resume 组合启用。已消费的初始化前缀有完整 sidx 时，为每条选定原轨额外发起一次 Range 请求；仅与 native 请求匹配的字节区间接管，无匹配继续307原站。精确 Media.start、画质和编解码选择不变。每响应保留前缀256KiB；目标响应在 native claim 前不订阅正文，借 socket 背压，不将整段收集入内存。最多每轨一个额外响应，取消时一起关闭。
- mp4_resume_range.dart 支持顶层 sidx v0/v1、64位box与字段边界，拒绝不完整、嵌套、越界、零时长等；恰好段边界预测前一段以兼容精确向后定位，但最终请求字节仍由native决定。实际缓存前缀离线验证 parser-reviewed.json：video预测55秒offset1768123，audio预测55.146666秒offset628712。两轨按请求进度独立预测，音频native实际定位可能随主轨提前而不命中；必须实测记录，不把预测成功当接管。
- 新真实HTTP测试覆盖预测先发、未claim不消费正文、跳过前缀后精确字节与Content-Range、缓存重开、非匹配307、错误206、header超时回退、取消释放；连同旧并行/隔离/hedge/预备测试共38项通过（resume-range-tests-01.txt）。第一次分析1个fake override错误及10条style提示已修，二次八文件分析No issues found，首次日志保留。
- 下一同源码control/candidate两包唯一define差PREFETCH_RESUME_RANGE=true；source frame门控开，codec rate保持0，无本地进度fixture。session67固定CID42790290231显式60000ms，预热+ABBA。预热也保留稳定门控失败标志，正式样本仍严格要求native sourceFrameReady与PTS60–60.5秒；所有预测miss保留。

### 起播口径核对补记（回应用户0.x/1.x与3–4秒的疑问）
- 主textureMs仍为native ACTION_DOWN dispatch到Flutter消费本来源首个变化的正SurfaceTexture时间戳；不等于物理屏幕呈现。revealMs单列封面放行；prerequisitesMs=max(textureMs,revealMs)，不能将三个字段互换。
- 第35轮action-text-home-01：从头立即点击texture945.130/cover627.760/前置945.130ms；从头短停留texture459.053/cover505.088/前置505.088ms。因此历史“最快505ms”具体指前置条件，不是首纹理459ms。两条不同CID，无效归因到字形预备，不能称通用速度。
- 同包同视频第37轮resume-latest-pilot-01顺序0/60000/0：首冷texture3139.361，60秒续播4340.597，再从头1167.727ms。首冷也可能数秒；不同起点、预备和冷暖状态要分别列。第38–42轮固定60秒组不得直接和旧零位置预加载组作退化或收益比较。
- 第39轮确有cover521.016ms而texture3712.467ms的提前放行；既有首纹理数据未改，40轮修的是封面有效性。不能以封面消失冒称0.5秒已开始视频，也不能把新门控的等待当作播放加速。此前汇报中标签不够明确，后续固定写场景、texture、cover、前置三列。

- 用户最新将主要目标明确为全力解决续播起播慢。42两包77源码及唯一define差核验通过（resume-range-builds-verified.json），原依赖恢复、本轮Gradle78184释放。session67固定CID60秒ABBA开始；后续以真实重复打开的续播链路作为主线，零起播与其它功能只做必要回归。

- 42 session67 warmup5367.228ms/cover5694.612ms，PTS60秒、sourceStablePassed=true。01-control初门槛8.096GiB通过，准备18秒后commit余量7.881GiB低于8，点击前中止；不计速度。failure-reviewed.json保留两次内存值，QA45768经身份校验正常sync/emu kill并退出。仅结束自己的测试app未能恢复足够提交余量。
- 宿主launcher新增显式MemoryMiB参数，默认2560不变；session68临时2048MiB（AVD持久配置不改），全新resume-range-pair-02重新预热+ABBA，门槛仍8GiB/6GiB，旧环境不混入。runner保存真实QEMU命令，Python/PowerShell语法均通过。新环境下仍需全组通过才得出同条件结论。

- 68 warmup5539.936/cover5799.728，正式control3660.523/3913.028，均PTS60/stable通过；02-candidate初门槛commit7.42GiB/physical6.74GiB拒绝，尚无候选速度，不算应用失败。failure-reviewed.json/原件保存，QA69556核身份正常关闭。每次安装采集后QEMU宿主占用增长，改短会话：同2048MiB、每条正式前固定一条控制包冷预热。以68控制为A，69/70候选B/B，71控制A，独立cohort保存对照环境。全部结束后再汇总，不与67或旧2560MiB速度作净收益比较。没有修改内存采集阈值，也未关闭用户应用。

### 第43轮准备：音频预取跟随视频解码起点（仅工作区，尚未构建）
- 42的69/70候选分别4055.057/3776.395ms，video均成功claim offset5980301并消费4.5–4.7MB，audio均预测55.146666秒offset1183793但0消费，实际走seek-or-reopen回退；两会话正常关闭，71控制尚在采集。完整ABBA未汇总，不先认定改善。
- 基于两次实际audio miss，新增PREFETCH_RESUME_AUDIO_MASTER默认false且依赖PREFETCH_RESUME_RANGE。视频sidx预测出解码起点后通知audio，audio有界初始化前缀先到或后到均能准备同一预测；最多一次额外response，迟到对齐不替换已打开response。Media.start仍原始精确进度，requestedUs与predictionTargetUs分别记录。额外seek.miss只记字节数值，便于核对不命中的真实范围，不记录原始URL。
- 新HTTP测试覆盖audio前缀先到、对齐先到、无主轨索引回退、迟到不能另开response；新worker实连测试audio初始化先消费，再video产生目标，两轨都需正确字节并关闭。当前未运行测试/分析，遵守模拟器采集中不编译。42 APK及source ZIP不可变，此后工作区改动属于43，不能把工作区当42源码。

- 42完整原始ABBA已结束，全部四个正式样本PTS精确60秒：control3660.523/5677.110，candidate4055.057/3776.395ms；最后control的sourceFrameReady迟到并触发原5秒stable timeout，明确验收失败，不补抽样替换。保留8条含预热记录和所有失败。描述性首纹理中位4668.817→3915.726、前置4795.069→4217.770，但受最后control长尾/门控失败影响且每组仅2条，不认定已建立稳定速度收益；保留默认关闭实验继续修audio miss。八次返回清理/活动音轨0通过，连续性报告齐，69/70/71正常关闭。
- comparison-reviewed-02.json为最新汇总：首版reviewer从未包含API事件的milestones默认补0有误；02从原始source.url成对事件计算API中位191.1765/142.614ms，首版原件保留并被02替代，texture/cover数据不变。runner改为先保存失败正式行再触发断言，避免遗漏失败摘要；不降低原稳定门控要求。
- 43四文件首分析只有3条style提示，已修；二次分析与开关开启的七文件测试运行中。新build-resume-audio-master.py和run-resume-audio-master-pilot.py已准备，先单候选功能试跑确认两轨都被消费，再决定完整速度对照。下一session72，仍2048MiB短会话控制冷预热+候选一次，保持手机release原文件。

- 43带PREFETCH_RESUME_RANGE与PREFETCH_RESUME_AUDIO_MASTER两个开关的42/42测试通过，包含新worker实连用例，四文件二次分析No issues found。开始单候选resume-audio-master.apk构建，源码冻结；预计78源快照。下一72实际双轨接管功能试跑，不把与旧不同源码控制包预热的差值当净速度收益。

- 43构建4m19成功，SHA07b79154fcb8f38023c60b2323ef1f32dd1f831ef94d5d664c37aff60a2d5500，78源码与ZIP匹配、临时依赖恢复；resume-audio-master-build-verified.json列明与42有5个源码文件差异、一个define新增。已核身份释放Gradle17896，启动72-MemoryMiB2048功能预试。
- 42候选的video目标firstChunk交付在source.open后762/827ms，texture在open后3902/3577ms，仍有3139/2750ms后续等待。它包含数据持续供应/音频回退/解码/输出，不能直接全叫纯解码耗时。当前logcat组件是c2.goldfish.hevc.decoder，物理手机组件/速度尚未本机量化，不把模拟器3–4秒硬套手机；继续按实际监听拆分。

- 43 session72完成原始采集但功能验收失败：预热texture6387.056/cover5438.031，候选5884.768/5597.518ms，二者stable timeout；候选精确PTS60秒且video/audio两条resume.firstChunk均真实出现，两响应均回收、活动音轨0/连续性报告已存。reviewed.json明确functionalPilotPassed=false、speedGainEstablished=false，不能把双轨接管称起播已修。QA经保存pid/createTime/命令校验正常关闭，无活动模拟器/构建。
- 下一先做分片seek机制验证：Windows现有ffprobe是2025-10-09-git-469aad3897，非APK内嵌n9.0.1。probe-fragment-seek.py匿名读取同CID可用HEVC最高/80轨64KiB头，再只读60/60.6/61秒各首packet；保存版本/哈希/PTS-DTS/位置，不保存signed URL或原始HTTP错误，不当Android性能样本。目的是判断段边界是否额外回退，不更改用户实际续播位置。

### 第44轮调查：分片边界的 PTS/DTS 比较
- fragment-seek-probe-01 已完成：同 CID 匿名 480p HEVC，目标60.0秒首packet PTS55/DTS54.866687，60.6和61.0秒均PTS60/DTS59.866688；prefix内elst mediaTime2133、mdhd timescale16000，偏移0.1333125秒。匿名轨不同于QA 1080p，不当Android速度结果。
- 独立合成11秒HEVC闭合GOP，每5秒一个IDR，含global sidx、B帧。Windows ffprobe复现：目标5与5.033333秒仍取PTS0，5.066667秒起才取PTS5；目标10秒取PTS5，10.1秒取PTS10。完整11点结果及fixture hash保存fragment-seek-synthetic-01/windows-baseline-reviewed.json。测试不依赖网络，不是图像识别。
- 从当前依赖的20260906原生release对应commit 8e50ecc027cd2443a3ef9b1a87991d37f1acdc41核到FFmpeg9.0.1/mpv0.41.0，与APK内嵌版本一致。官方n9.0.1源码tar SHA195d54bebe1a27f84d77f4b989d193466f305b355da92292766a69f16880b18a已保存；实际下载mov.c行号不同于web缓存，以下载源码/hash为准，不声称已复现原二进制全部编译条件。
- 为最小同版本修正对照，在已有WSL Ubuntu-20.04安装gcc/make/libc6-dev/pkg-config，包管理原始日志保存在native-seek-01；没有升级整个发行版。无活动AVD，双作业编译最小FFmpeg/ffprobe基线，门槛检查通过（commit10.52/physical8.8GiB）。尚未修改App使用的libmpv或手机包。下一候选只区分sidx的PTS分片定位与DTS样本索引，并核精确解码帧哈希、开放GOP、无sidx等，不能直接删掉合法的PTS/DTS偏移。

- 原版n9.0.1最小工具复现相同回退；candidate1仅sidx分片查找保留原PTS，样本索引继续使用原DTS转换。首批合成文件无效：旧Windows muxer的global_sidx插入76字节后未修正绝对tfhd偏移，原版与候选都无法解码，matrix-01不算通过。原件保留，02使用default_base_moof重新生成有效文件，不改产品视频字节。该失败与“缺少解码BSF”无关，没有据此改构建功能。
- matrix-02有效9种文件×11位置共99组：98组两版都与从头连续解码后截取的8帧一致；一组empty-edit@9.9两版同样与参考不同，保留为原有/参考语义待查，不宣布全通过。99组候选与基线内容均一致，但candidate1在negative-ctts@10和empty-edit@10反而回退更多，不能推广。
- candidate2增加has_sidx、dts_shift=0、elst_count<=1、time_offset>=0适用条件，保留复杂时间轴原路径。matrix-03再次99组：内容仍98组符合独立参考、99组与原版一致；两个特殊时间轴的额外回退已消失。开放/闭合HEVC与H264的5秒边界仍从前段改为当前段，无sidx/普通MP4/无B帧路径未改变。
- 实际匿名公开轨保存fragment-seek-public-03，21,879,744字节，SHA b96cbcb9c6b3324487eb5ecf004fa4b5b6ce1fa201cc9b3bba04e4f26754df84，前64KiB哈希与早先完全相同。前两次下载探针因期望206而拒绝；实际CDN全范围回200且附完整Content-Range，03严格核总长度后接收，未保存signed URL。public-matrix-01/02各7点均准确帧通过；candidate2请求60/60.033333秒由首PTS55变60，其余5点保持原行为。不是Android速度证明，不等同QA1080p轨。
- 正在准备完整Android原生同源码对照。官方NDKr29 Linux SHA1 87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b、SHA256 4abbbcdc842f3d4879206e9695d52709603e52dd68d3c1fff04b3b5e7a308ecf核验；当前20260906 release recipe固定8e50ecc...，依赖版本与原JavaVM补丁保留。WSL直接git连接超时，改官方GitHub仓库/官方只读镜像codeload，tar PAX commit与SHA逐项保存native-archives-reviewed.json，含固定子模块，不改全局git配置。
- 原生准备环境：WSL新增g++/unzip/nasm/python3-venv/autoconf/automake/libtool/gettext，日志齐；venv工具meson1.11.2/cmake4.4.4/ninja1.13.2。直接在DrvFS解压>12分钟，已核精确命令/PID/startTicks仅停止本任务unzip499与prepare1170，部分目录保留。独立D盘12GiB ext4镜像build-filesystem.img，UUID25aadd94-b618-42f4-9d7d-f06ea083b789；首次空闲WSL自动停止导致挂载消失，后续解压NDK落在Linux根卷，已保留为/mnt/piliplus-native-seek-staged-20261030。keeper PID544/exec96122保持挂载；实际编译源在/mnt/piliplus-native-seek-20261030/recipe，NDK只读链接到staged，原tar/zip仍在D盘。结束原生工作后需写build-filesystem.stop，让keeper同步并正常卸载，不shutdown整个WSL。C盘约6.6GB空余，避免继续往根卷放大体积构建产物。
- tool/build_startup_standby.py新增可选--native-mpv；startup_native_library.py校验ELF架构、官方JAR哈希，另建只替换libmpv的JAR和独立缓存名，构建后核APK内SO字节，finally恢复原Gradle依赖。5/5测试验证原JAR/helper不变、失败恢复、错误ABI/坏哈希拒绝、并发修改不覆盖；语法检查通过。未使用该参数构建App，也未改官方缓存/手机原release。当前应用源码仍43，44仅添加宿主构建辅助。
- Android baseline源码已准备，FFmpeg mov.c仍原始SHA71f4cd...。首次完整原生构建前gate commit9.0/physical6.86GiB拒绝，尚未开编译。仅对本任务29,598个文件做POSIX_FADV_DONTNEED（不写global drop_caches、不关用户应用），own-cache-release-01.json记录，继续核资源再启动两个作业构建。

- 44原生同配方对照/候选均构建完成，六份配置逐字相同、mpv导出与系统依赖核验、guarded mov源码与宿主测试一致。APK对照e0207472...、候选edbbc443...，82源码与defines相同，仅libmpv替换；native-sidx-builds-verified.json确认原依赖恢复。native控制SO01d808e2...、候选154ebf16...。构建文件系统已正常卸载，核身份释放本轮Gradle73688，手机ARM64原包未改。
- session73采集控制预热成功（texture5840.376ms/PTS60秒），汇总读取capture.json采用Windows默认GBK导致UnicodeDecodeError，正式候选尚未开始；失败原件及failure-reviewed.json保留，模拟器正常关闭。runner明确UTF-8读取，plan-02重排74/75/76/77为B/A/A/B，每个新2048MiB会话均先同一控制包冷预热。74当前运行，不把预热失败包装为产品回归或速度收益。

- 44 session74控制预热5453.864ms/cover5750.758ms/PTS60且stable通过，正式候选尚未点击就被capture门槛拒绝（commit7.76GiB/physical6.6GiB）；正常关闭。plan-03改75/76/77/78同包预热→同进程返回重开60秒，BAAB，省掉第二次安装。所有组都采用相同流程；与旧“控制预热后重装”分开，阈值仍8/6，不关用户应用。runner筛本次player/request后的事件，避免旧预热stable污染重开验收。
- 新run-native-sidx-history.py已准备，第二次真实输入不带start_progress且复用同PID，记录App实际选择的历史位置和退出位置；历史为0时明确不算续播通过，未运行。

- 44重要环境更正：73/75请求2048、76请求1536，但guest-before与hardware-qemu.ini显示实际均2560MiB（guest MemTotal约2526652KiB）；此前“2048MiB组”只代表启动参数，不是生效内存。memory-effective-audit.json列出42–44已有记录。降参数没有实际释放内存，后续显式2560并核guest，不再据命令推断。
- 75/76候选冷预热2962.439/3358.649ms，video Range从控制5980301改为6300522，audio从1082874改1183793；候选首纹理PTS60.033313/60.166688秒且stable通过。73/74控制冷5840.376/5453.864。cold-exploratory-reviewed.json保留四条探索性AABB，不冒充已完成的正式同进程对照。75/76正式重开分别commit7.76/7.9GiB被旧8门槛拒绝，均正常关闭。
- 77真实历史试跑history-01使用相同已安装APK、先等待资源；seed完成准备后commit跌破旧8GiB而点击前取消，未得到播放结果，正常关闭。已经追加host helper，不重复安装相同哈希APK。
- 重新核资源门槛来源：capture_timing.py旧8GiB来自35秒重录制2.51GiB增长。lean-resource-calibration-02.json核现有短轻监听243份去重资源记录（含可用失败记录），最大提交增长0.971GiB。新增显式lean-short仅22–25秒release+lean、拒绝geometry/deep/CPU/VM/Perfetto；启动commit7/physical6，运行abort3/1，默认/重采集仍8/6，build/launcher仍10。保留4GiB提交余量缓冲为已观察最大增长4倍以上。3项测试含7种拒绝路径通过，未关闭用户应用/改系统虚拟内存。与先前“门槛不变”决定的差异已明确记录，此变更依据实测轻监听资源而非取消监控。
- session78运行history-02：新资源profile；不带进度参数第二次重开。原包没有source.startPosition trace（OMIT_ZERO_MEDIA_START未开），runner不伪造请求值，保留null并以首PTS和前次离开位置±2秒核是否确为非零历史；精确请求位置监听待下一包补足。手机原release未覆盖，目标active。

### 第45轮准备：修正后的原生定位叠加范围预取
- 44原生包冻结不改，工作区进入45：mp4ResumeRange新增preferPreviousAtBoundary默认true保留旧预测；ParallelAudioSource新增PREFETCH_RESUME_PRESENTATION_TIME默认false，开时预测当前sidx分段。原native字节Range仍决定接管；不匹配的更早seek保持307，不交付错误预测。builder要求native-mpv+prefetch-resume-range并记录开关。精确Media.start和画质不变。
- 补source.startPosition诊断为所有diagnostic包发出，不再取决于OMIT_ZERO_MEDIA_START；只增监听，不改实际seek。新v0/v1边界前/整点/边界后测试与真实HTTP字节测试、旧native更早Range回退、独立worker双轨同一边界接管测试已写。
- 默认44项通过、1项需要新defines的worker用例按条件跳过；带3个预取defines的专用测试与五文件分析进行中。未构建45包。
- 78/history-02 seed3163.768ms成功，但runner已加载旧next查缺失startPosition字段报StopIteration；修复允许缺失并显示null，原失败保留。79/history-03 seed3494.515ms/退出74.833秒，第二次输入准备失败：Ctrl+A没选中全文，新URI插入旧URI中间，未点击/没有历史续播结论。已改识别UI语义“清空”按钮，真实失败XML坐标865,137与缺失/多义/无效边界2项测试通过，不用截图识别；所有失败QA正常关闭。
- 下一80复测history；81–84正式native ABBA采用同一实效2560MiB和lean-short资源profile，plan-05保存。45源码已改，44 APK仍以各自82源ZIP为准，不能再用当前工作区验证旧包源码完全一致。

- 45专用预取测试8/8通过（包含真实isolated worker双轨当前分段），首分析仅2条新测试style提示，修后二次No issues found。新增source.resume.selected记录entry-override/server-history来源、服务器进度和实际选择进度；与source.startPosition联合核非零续播，不改选择逻辑。该最后监听新增待分析，尚未45构建。
- 新build-native-presentation-pair.py/verify-native-presentation-builds.py准备：两包同候选native，控制关闭范围预取，候选开Range+audioMaster+presentation三define；用于44改善上的叠加对照，尚未执行。80当前history-04，已冻结语义清空辅助；81–84旧native同源码对照先完成。

### 2026-10-30 用户纠正后的执行调整
- session81冷60秒仍取得5577.992ms纹理/5808.720ms封面；第二次输入时ADB宿主服务连接失败，尚未点击，失败原件保留。session82已启动且网络就绪，但采集进程未运行、没有播放样本；按用户反馈终止该反复预热/重开的计划，已核PID65716/完整命令正常关闭，见emulator82-retired.json。
- 不再继续44的83–85预热ABBA重试。44仅保留已获得的探索性冷样本和原生Range改变事实，不声称完成正式对照。
- 转入45已完成的产品改动：原生PTS定位修正叠加匹配分段的双轨范围预取，先构建一个candidate并执行一次22秒的固定60秒续播，直接使用已经成功的capture_startup_listener入口，不加暖机/重开步骤。先确认两轨消费、实际首PTS、输出稳定与返回回收，再决定下一次有用实验。所有失败照常保留；不以预期或构建替代实测。

- 45候选native-presentation-candidate.apk构建及86源码/包内SO/依赖恢复核验通过，SHA5f93167956141cea88a0b12cf9657f8d9b1f8082098cf2aa9ad337d41a0078fb。仅构建一候选，没有宣称同源码两包对照。自己的Gradle78028核身份释放。
- session83仅一次22秒60秒续播，native-presentation-pilot-01/60s，无流程失败，模拟器正常关闭。首纹理3004.4621ms、封面/前置3133.5106ms、首PTS60.000秒；input/source有效、两轨resume body实际消费并closed各1、严格output.stable通过，返回三资源关闭/活动audio0。15秒左右连续观察410个变化时间戳，最大间隔159.3544ms，不能称物理显示无卡顿。新增监听确认entry-override=60000、server history=0。
- 本次功能预试通过，速度净收益尚未成立，不能以单条3.004秒冒充达到0.8秒。继续保留44的原生修正和45实验。worker事件当前在主isolate接收时记时，headers→claim约550ms只能作线索，不能全部归为原生等待。源码复核mpv已默认skipinfo(mp4)，不重复添加无效probe-info选项。

### 用户纠正：只定位并缩短耗时，不制作交付手机包
- 已立即停止ARM64编译，只向本任务build.sh进程树发终止，父包装进程执行finally完成正常卸载；arm64-user-stop.json/android-arm64-candidate-build.json保留。没有生成新手机包，也不再继续交付包流程。
- 转46定向定位：45完整成功样本query.primary=1148.034ms，适配器请求开始到headers=1023.539ms；open后1811.1865ms到首纹理。现有worker事件排队到主线程才记时，不能直接判断内部半秒等待。
- 添加显式RESUME_STAGE_TIMING诊断开关：两轨worker自身Stopwatch与UTC时间、MpvFrameGate同步property读取的实际阻塞微秒。不开则保留原行为与开销。先用同视频60秒两次打开区分冷API和重复续播，精确首PTS/来源不变；只做一次冷和一次同进程重开，不补旧大组。诊断证据用于下一次实际缩时修改，不当收益。

### 第46轮实测：同步属性读取阻塞主线程；第47轮改异步等待
- session84两条固定60000ms续播均完成、无采集错误，模拟器正常关闭。首次texture3039.5225/cover3087.183ms，query1430.096ms，open后1566.5815ms；同进程再次texture1899.7149/cover2062.119ms，query189.913ms，open后1634.4249ms。两次首PTS60秒附近、严格output.stable/返回三资源closed/活动音轨0通过，连续时间戳单独报告，均非物理显示证明。原件resume-stage-01/reviewed.json及每条continuity-analysis。
- 已证UI同步阻塞：首次path读取346.141ms，两个续播轨事件实际执行与主线程接收相差331–356ms；重复path读取87.308及73.278ms。先前把主线程headers→claim全部当作原生等待不成立；worker自身video headers→claim首次99.724ms、重复203.418ms。
- 47新增MpvAsyncPropertyReader：独立weak client接收异步属性回复，每次只一项并等待后再查下一项，保留原帧事件队列及查询后再次排空，避免旧restart/SEEK/RECONFIG误放行；取消释放pending及client，迟到/旧id不满足新请求。ASYNC_SOURCE_FRAME_GATE默认关闭，实验开启。
- 23测试通过（18既有帧协议+5异步取消/迟到/顺序/不可用/提交失败）；分析无错误或warning，4条style info留存async-frame-analyze-01.txt。未为style重跑构建。
- 仅生成x64模拟器诊断版本async-frame.apk，保持46所有native及开关，只新开异步gate；88源快照预期。正在构建，源码冻结。随后session85同样首次+重复60秒，直接比较阶段耗时和阻塞消失与否；不能预先声称速度收益。手机包构建已按用户纠正取消，不再开展。

### 第47轮结果与第48轮继续压缩状态查询
- session85首次texture2682.2768ms/cover3127.6671ms/query1373.878/open后1272.8557ms；重复texture1516.9688/cover1730.5245/query141.257/open后1310.7793ms。对46分别缩短texture357.2457/382.7461ms，open后293.7258/323.6456ms；冷cover反慢40.4841ms，重复cover快331.5945ms。只两条探索性顺序样本，未声称总体分布。同步gate读取路径不再执行；异步awaitUs不计UI阻塞。两条PTS60秒、严格stable、返回回收/音轨0均通过，连续性报告原件已存。QA正常关闭。保留异步改善，不因未达0.8撤回。
- 47已核88源、native154ebf...、依赖恢复，APK2274f290...；原包/ZIP冻结。用户目标只定位缩短续播，不进行手机包工作。
- 48针对冷封面仍慢：restart的VO/path和最终path/VO/seeking只读查询各自成组同时发出，按request ID收齐后才处理源事件/排空队列，组间顺序保持；组内读取互不依赖且原串行读取也不是原子快照。SEEK/RECONFIG/新START仍必须先处理才能放行，未省检查。多个pending取消全部完成、乱序回复逐一关联。24项测试通过；分析结果见async-snapshot-analyze-01.txt。仅48的3源码变化，defines/native与47相同。下一86首次+同进程重复60秒复测。

- 48已构建并核88源，APK398ee80dfabfb959572b96e8108fe02364783139a1a933e15ba2f922f808f6d4；与47仅gate/async reader/对应测试3源码变化，defines/native相同，依赖恢复。本轮Gradle77984核身份释放。session86已启动，run-async-snapshot.py（exec82481）正在首次+重复60秒采集，APK/ZIP冻结，不能用接下来49工作区源码核48。
- 等待48采集时只做49源码编辑（没有并行Flutter测试/构建/ADB）：新增BoundedBodyWarmup单订阅有界正文预读，达到256KiB后暂停（最多超出最后一个网络chunk），claim立即交付已到字节、不等填满，暂停/恢复/取消传递；resume资源关闭时取消，Content-Range/总长仍先校验，原native Range及精确起点不变。PREFETCH_RESUME_BODY默认false，仅开启后作用于已选resume段，不改0秒流。新增4纯stream行为测试及1实际HTTP全剩余字节/跳过前缀接管测试，尚未运行/未构建/没有收益结论。下一步86结束后先审48结果，再运行49默认/开启的运输测试及分析，修复后构建49，仅诊断版本。下一QA87。

### 第48轮结果、宿主重复门槛修正；49正文预读测试
- session86冷60秒texture3152.7119/cover3295.8262/query1427.758/open后1694.5977ms，PTS60.033313、strict stable/返回三资源closed/音轨0通过。47冷texture→cover445.3903ms，本轮143.1143ms；最终三属性查询共约12.9ms而不是47的179.2ms串行等待。总耗时反慢，video.resume.headers实际worker到达由open后约858ms变1143ms，claim先到等待headers；不能把此条宣布整体提升或回退异步。保留阶段改善继续叠加。
- 第二条没有点击：settling额外硬编码6.2GiB门槛，前3次实际6.024/6.012/6.055GiB都已满足已校准lean-short的6GiB实际门槛却被拒；最终2次6.742/7.294但50秒期限使第三次来不及。failure-reviewed.json保留原始失败及数值；不重跑整组。helper现与实际7/6门槛一致仍需3连续样本，capture原有点击前再次检查/运行3/1abort未改，未关闭用户应用、未降低实际安全profile。
- 49默认运输/有界prefill测试28通过、1项需预取defines的worker跳过；四文件分析No issues found。带全部4预取defines的真实worker/字节接管测试进行中（exec34507），成功后才构建。48全部原件/90新源码分开；49尚无实测收益。

- 49源码验证完成：默认28通过/1条件skip；全部4预取defines的presentation worker+warmup6通过；legacy边界worker在旧时间预测配置下1通过；启用body的HTTP错误/回退/取消/精确剩余字节9通过；六相关文件分析No issues found。初次把旧boundary fixture与新presentation define一起运行导致其500000字节预期不兼容，原失败resume-body-defined-tests-01.txt保留；旧fixture明确仅旧边界配置启用，按两种配置分开通过，两worker新增bodyWarmup.claim断言。没有因失败放宽产品字节验证。
- 49仅诊断构建resume-body.apk已启动exec99024，预计90源，保持48native与所有开关，只增PREFETCH_RESUME_BODY。源码从此冻结；构建后verify-resume-body.py核新增2文件/改动5文件/全部90源/包内native/依赖恢复，再核身份释放自己的Gradle，session87执行run-resume-body.py（首次60秒+同进程重复60秒）。使用已对齐实际7/6门槛的资源settler，运行门槛保持；不重跑48缺失样本。非边界61.5秒续播仍待补，不能把当前整段边界结果泛化。当前无模拟器。

- 49构建与90源码/单一新增define/原native/依赖恢复全部核验通过，SHAef90fd1e847ff2eeb5919d8c0639c9c8713147f58151df92fe4de3c241298b8b。自己的Gradle35384严格核身份释放。session87已启动，exec1854执行run-resume-body.py，固定60秒首次与同进程重复，最终正常关闭。下一88可复用此包执行已准备run-resume-body-nonboundary.py（单次61500ms），reviewer按metadata.requestedStartProgressMs核PTS并列prefill实际字节；不要把不同起点当净速度对照。
- 纠正首次API归因：48源日志http.begin100.3ms→headers1404.5ms记的是UI接收事件；500ms intro deadline从16ms等待却到1379.4ms才释放，同一帧raster input+100.9至1356.4ms，提示主线程调度明显拖迟，不能将全部1.3秒宣称为服务器等待。此前32/36已在该模拟器完整Skia与QemuPipe链发现冷渲染长帧，两个字形预热未解决；37因真实手机反馈已明确优先续播，不重新陷入重型冷渲染采样。继续把冷进程/重复续播单列，保留这项口径限定。

### 第49轮结果与非分段边界复核
- session87首次与同进程重复60秒全部完成，模拟器正常关闭。首次texture2719.348/cover2975.2822ms/query1397.130/open后1260.9908ms；重复texture1077.2298/cover1301.5766/query160.584/open后863.8252ms。两者首PTS60.000、严格source/output stable、返回三资源关闭/活动音轨0通过；完整连续性在各自continuity-analysis，不作物理显示或全程无卡顿结论。
- 首次视频/音频native接管前正文分别已预读194780/97442字节，重复为0/38142字节；重复视频头到达几乎与claim同时，不能把本条全部440ms提升归于body预读，网络响应与native状态也不同。47→49组合重复texture1516.9688→1077.2298/cover1730.5245→1301.5766是实测探索性变化；尚未达到0.8，继续保留已实现改进。
- session88已启动exec90168，run-resume-body-nonboundary.py仅同一49 APK一次61500ms，目录resume-body-nonboundary-01/nonboundary。它是非边界准确性/连续性补测，不与60秒作净性能比较；结束finally正常关闭。下次QA89。
- 后续候选方向（尚未实现）：只复用近期同媒体的已解析sidx初始化索引，让目标Range在初始化HTTP开始时就并行发起；每次仍读取当前API URL和真实媒体，原生实际Range/总长检查决定接管，不复用旧进度/旧正文/旧授权URL。49重复video初始头179ms→目标头429ms，有可尝试消除的索引后第二轮请求延迟。需要有界/过期metadata缓存、变化后的fallback测试和原样字节校验。


### 第50轮：近期索引复用，提前发出目标片段请求
- 补49 session88结果：61500ms首纹理3519.7913ms、封面3888.8225ms、query1318.770ms、source.open1347.8165ms，open后2171.9748ms；首PTS61.500s准确，strict stable、返回三资源关闭/活动audio0通过，模拟器正常关闭。非整段边界样本不作为60s的净性能比较。
- 50增加REUSE_RESUME_INDEX，主isolate最多4个、每个64KiB、TTL2分钟的初始化索引提示；零位置首播也采集。复用时采用当前API地址/请求头发起目标HTTP，与当前初始化HTTP并行；不复用历史位置、签名URL或媒体正文。原生实际Range与当前Content-Range/总长仍决定是否接管，不匹配回退当前来源。
- 初次真实worker测试2秒超时，原件resume-index-defined-tests-01.txt保留，没有足够日志判定唯一根因。检查修正索引发布对累计prefix超过64KiB时直接跳过的问题，改为始终取至多64KiB；同时保留零位置采集，增加分阶段失败事件。第二次3项真实worker/presentation测试通过，证明当前初始化headers被阻塞时两个目标请求已发出、使用新请求头、字节一致。
- 默认运输/缓存/解析/预读回归34项通过，包含索引过期、容量/复制隔离、过期总长回退当前源及字节核对。分析二次结果另存；仅生成后续模拟器诊断版本，不制作手机交付包。尚无50实测速度结论。
- 术语固定：重启App后首次续播、同进程再次续播；本轮两次都显式指定60000ms。第一条就是重启后的第一次点击，不能描述为先从零首播后的第二次点击，也不能当真实服务器历史续播。

- 第50轮六文件分析No issues found。首次构建包装器错误把--prefetch-resume-body替换成不存在的--prefetch-resume-index，参数解析即拒绝、未开始编译；原失败resume-index-build-driver.txt保留。已修为保留body并新增--reuse-resume-index，第二次独立driver-02正在构建；产品源和93源快照冻结。

- 50诊断包resume-index.apk成功构建并核93源/只新增REUSE_RESUME_INDEX=true/native不变/依赖恢复，SHA412d8477e67bc1b46f3638cabb44fc6b030ecfaaf080797905742a1c04583d89。Gradle14168核PID/createTime/完整命令/本仓currentDir后释放。session89已启动，run-resume-index.py采集同一60000ms首次和同进程重复，下一session90。等待期间不运行并行Flutter测试/编译/额外ADB，当前源码冻结。

- 等待50采集时只读复核49：repeat两轨初始化均由backup地址获胜，video目标请求沿获胜host发出（open后207ms），audio225ms。50索引提示在尚未选出初始化获胜host前发起目标请求，当前只请求主地址；这可能抵消并行收益，需用50真实host/headers结果判断，不能提前宣布净提升。另49 repeat gate重启后先等2属性48.6ms再等3属性45.8ms，存在一次重复状态等待的后续候选；未改gate验收或50冻结源码。


### 第50轮结果与第51轮续播片段备用来源竞争
- session89两次60000ms全部成功，正常关闭。首次texture2843.2068/cover3031.1781ms/query1409.746/open后1394.8037；同进程重复texture994.359/cover1133.3307/query105.120/open后833.2833ms。首PTS均60秒，strict stable、返回三资源关闭/活动audio0通过。两次连续性原件已生成；不是物理呈现或性能分布证明。
- 重复两轨indexHint.lookup均true；worker约2ms已发出目标Range，而初始化video/audio头约131/159ms。索引并行成立。49→50重复texture下降82.8708ms、cover下降168.2459ms，API query同时缩短55.464ms，因此不能全部归因于索引；open后减少30.5419ms。仍未达0.8，保留改动继续叠加。
- 真正剩余来源等待：repeat视频hint先向upos-sz-estgoss发起，headers到worker471.610ms，native claim463.723ms；初始化备用xy223x247x68x187却130.596ms已返回。audio目标210.573ms到头/预读114688字节。50并行绕过了初始化获胜来源选择，视频仍在等较慢主地址。
- 51添加HEDGE_RESUME_PREFETCH：仅早期hint目标请求使用同一当前API提供的一个备用地址和相同hedge delay，合法Content-Range/总长先到者获胜，关闭落败连接，正文只预读赢家。fresh index的目标仍沿初始化已选中的来源，不再额外竞争。最大额外连接每轨1个，不改视频质量、目标位置或gate检查。
- 51增加真实HTTP用例：主地址挂起而备用先供正确完整字节并取消主连接、错误备用Range不能赢、取消时两个待响应目标连接均关闭。当前测试中，未构建51。下一QA90；source50已保存在93文件ZIP与412d8477...诊断包，不再用51工作区核50源码。

- 51默认37项回归通过、带全部当前defines的真实worker/presentation3项通过，二文件分析No issues found。新HTTP三场景全部通过。仅叠加一个HEDGE_RESUME_PREFETCH开关，94源诊断构建已开始；下一session90运行相同60秒两条。50已证明索引早发，但不是0.8达标；不改变既有正确性检查，不制作手机包。

- 51采集脚本追加同进程61500ms第三条，复用同一次QA启动及搜索语义准备，以区分整段边界与普通位置；前两条60000ms保持原方案。第三条不与此前88冷进程61500ms作净性能比较。不改变采集门槛和finally关闭规则。

- 51构建/94源/唯一新增define/native/依赖恢复核验通过，APK b6ed72e58df7cf092355940b2d43e99addc82aad3cad57d5afbbee366ef3efaa。Gradle46116核身份释放，session90运行中（run-resume-hedge.py，cold/repeat/nonboundary三个位置为60000/60000/61500ms），下一91。勿在采集期间启动其他ADB、Flutter测试或构建。


### 第51轮结果：目标视频已提前到达，后续原生消费/输出仍慢
- session90前两条60000ms成功。首次texture3038.3464/cover3216.6323ms/query1421.923/open后1579.6601；重复texture1105.3895/cover1327.6193/query125.609/open后897.2282。两条首PTS60s、strict stable、返回三资源closed/音轨0通过。总耗时比50慢，不能声称51总体提升。
- repeat video目标headers由50 worker471.610ms提前到141.706ms（约330ms），body在142.224ms开始预读；但native到437.934ms才claim，首次纹理在open后897.2282ms。音频目标255.960ms已到头、native482.928ms才claim。已证取流并行阶段改善，保留51开关继续定位native消费/解码/输出，不能把其余等待都归于网络。
- 同进程61500ms第三条在输入准备阶段失败：实际XML有两个“清空”，一个搜索框右侧、一个历史区域；旧helper要求全页唯一。未发送测量点击、无播放样本，原文件不覆盖。改为唯一输入框同行右侧语义按钮，实际失败XML与缺失/禁用/重复/无效bounds共3测试通过。模拟器finally正常关闭。
- 下一session91只用51现有APK一次61500ms，已有8秒Perfetto采集路径定向量原生MediaCodec初始化、送帧、输出释放与纹理消费。它是诊断样本，不与lean样本计算净速度。保留默认heavy资源门槛8GiB commit/6GiB RAM，不重新构建、不再补做整组预热。新runner run-resume-hedge-codec.py准备完成。
- 用户询问首次续播现状：最新为重启App后第一次点击直接60s的3.038/3.217秒；此前纹理最短2.682秒那次cover3.128秒，cover最短2.975秒那次texture2.719秒。不能把同进程再次续播0.994/1.133秒混入首次。

### 第51轮定向原生诊断：session91，61500ms
- 沿用 b6ed72e5... APK，无重编译；单次新进程61500ms、8秒Perfetto、默认8/6GiB门槛，22秒监听/18秒返回。完整采集成功，模拟器正常关闭；strict stable、精确首PTS61.500s、返回三资源closed/活动audio0通过。原件 resume-hedge-codec-01/nonboundary，分析 resume-codec-analysis。
- input→query1594.838ms→open1663.3241ms→texture4611.1538ms→cover4842.7561ms。此重型诊断不能与轻监听60s或61500ms样本计算净速度，更不能替换“首次续播最新3.038/3.217秒”的口径。
- 同源/同PID3323/时钟校准后：视频目标headers2096.2831ms、正文2096.7731；音频2254.0981/2254.7531。MediaCodecInit2309.6653ms耗166.1147；configure14.5105ms，start172.7968ms；flush在2783.9716/2822.8976ms分别38.7851/9.7318ms。视频native接管2850.6101ms，音频2875.2161ms。
- 首个实际queueInputBuffer2899.043ms，对应CCodec PTS60.000s；目标首release4547.3063ms，queue→release1648.2633ms，release→纹理63.8475ms。release前50次送包、45次不渲染释放。此区间包含解码、调用与调度，不能称纯CPU耗时；2668ms的TS0尚无flags证据，不能断言为错误从零播放。
- 源码发现：mpv先创建视频链，后执行初始seek；精确seek将目标前包设置AVDISCARD_NONREF，但当前FFmpeg MediaCodec实现不读取skip_frame，仍将所有包送入硬件。候选52拟检查保守识别非参考NAL并在明确NONREF要求下丢弃，参数集/SEI/未知或畸形包均保留；尚未实现、没有收益结论。资料 FFmpeg n9.0.1 mediacodecdec.c、hevc/hevcdec.c 与 mpv v0.41.0 f_decoder_wrapper.c/vd_lavc.c。

### 第52轮：原生执行明确的HEVC非参考帧丢弃要求
- 新 native-preroll-01/hevc-nonref-preroll.patch，在FFmpeg MediaCodec每次取得新包后、任何部分发送前检查：仅HEVC、skip_frame严格等于NONREF、有效PTS、无side data、非关键/损坏标志且Annex-B所有NAL均是单层TRAIL_N/TSA_N/STSA_N/RADL_N/RASL_N才跳过。其余全部原样送入；不改质量、精确目标位置、网络、Dart或输出gate。此要求也可能来自mpv普通播放framedrop，范围如实记录，不宣称只可能用于启动。
- 263项header/混合NAL/SEI/坏边界判断通过。host-review-02用3种已有HEVC视频（闭GOP/开GOP/无B帧）×6个目标共18组：先核Annex-B解码与原MP4所有像素哈希一致，再按可丢包的PTS构造应保留帧序列，候选逐帧全部一致。1.5秒前置区间闭/开GOP均少27包，无B帧0包；这是host软件解码正确性，不是Android或速度证明。
- host-review-01的ASAN批量程序异常持续写输出、无输入文件fd，核身份终止owned PID504；第一版runner未保存stderr，原因未证明。原输入与failure-reviewed.json保留。普通编译同文件5秒上限内完成；第二版runner增加子进程期限与失败输出记录，18组通过，不把原失败抹去。
- x64原生增量构建成功，libmpv SHA fb50aebba86c4df83380969d7a6bff21fabfa97f64fc59b74b4cf276dec57a9a；44的mov修正SHA3a221449...保持，原native154ebf...仍存。任务构建卷正常卸载，无ARM编译。
- 首次APK包装在实际commit9.39GiB（门槛10）前拒绝，未开始编译，native-preroll-build-driver.txt保留；只释放本任务9743个文件的clean缓存，再核commit10.07/physical8.28满足门槛。driver-02正在构建，沿用51的全部Dart源与defines，仅换native。
- 下一session92同一QA内：51旧native重启App后61500ms、52新native重启后61500ms、52同进程重复61500ms。全部轻监听22秒/18秒返回，gate7/6与运行3/1不变。这是小样本机制/表现对照，顺序与冷GPU缓存限制保留，不声称完整分布。run-native-preroll.py已准备。


### 第52轮包排队复核后的v2
- 52设计复核修正：FFmpeg内部读取全局skip_frame可能与buffered包错位，v1 APK已构建核验但从未安装，不进入实测。v1 APK e84abf4b...保留；94快照中两项host工具变动是此前清空按钮修复（不是产品Dart变动），verification已按真实2项记录。自己的Gradle15040已核身份释放。
- v2把判断移到mpv vd_lavc.send_packet中、avcodec_send_packet之前，仅ctx->framedrop_flags==2的精确seek包、hevc_mediacodec解码器生效；不改变包flags，不在FFmpeg队列中凭后续全局状态判断。FFmpeg mediacodecdec.c恢复原始版本，44的mov修正保留。新增长度前缀格式，770项检查通过，与先前像素一致性验证的3片共990包逐一同判（host-review-v2.json）。
- v2首次源码定位把并不存在的config.h当锚点，编译前断言拒绝并正常卸载；native-v2-build.json原失败保留。改用已核实mpv_talloc.h锚点。第二次native正在编译exec83164，成功报告native-v2-build-02.json；之后build-native-preroll-v2.py→verify-native-preroll-v2.py。下一92 runner已指定native-preroll-v2.apk；不要误装v1，也不要并行Flutter/native构建。当前无AVD。

- v2原生已构建成功，SHA89fe68a99f5a51c9235b45dc4f560477ddc6f1f975de6f4cb774d08a4c20beb5，正常卸载；FFmpeg MediaCodec恢复原始SHAf0f11349...，mov保留3a221449...。build-native-preroll-v2.py正在生成独立v2诊断APK（exec34580），v1不安装。

- 52 v2 APK构建及核验完成：9ab60f18bb921d89196f8783b3c93a5b27db53a27c08542536eb3e0efcf0264e，94源，产品Dart/defines与51相同，只有两项已测host清空按钮修复随snapshot更新；native89fe68a9...，依赖恢复。Gradle77960核身份释放。session92已启动，exec36586运行run-native-preroll.py，三条61500ms control/candidate/repeat；capture期间不运行并行构建/测试/额外ADB。

- session92已正常关闭。旧51 control61500ms texture6764.491/cover6396.5689，首PTS61.5；视频resume worker正文open后307.776ms，音频resume headers却3407.412ms（native音频1251.657ms已claim），有约2.16秒音频等待，不能将该异常慢条当作纯解码对照。candidate新52在准备界面后、测量点击前物理余量由6.196降到5.905GiB（commit7.592）被原6GiB门槛拒绝；没有新native播放结果，repeat未执行。failure-reviewed.json和全部原件保留。下一93只复用已安装52v2包单条61500ms，不重跑旧组，不降门槛；run-native-preroll-single.py已准备。

- 93采集宿主会话中断：exec19426已不存在且进程表无runner/本任务QEMU，device-02仅准备阶段日志，无capture.json/正常关闭记录，不伪造正常退出或速度；interruption-reviewed.json保留。94启动exec85732，复用已安装52v2，仅61500ms。
- 等待94期间仅编辑53（未并行编译/测试）：HEDGE_FRESH_RESUME_PREFETCH使当前索引新得到的目标范围也可与另一个当前API来源竞争，优先沿初始化赢家，主/备角色反转仍选另一个authority，最多多1连接。针对92音频目标headers3407ms，而初始headers210ms的实际慢链；新主先赢/备先赢及取消三项真实HTTP测试已写待跑。53尚未构建/没有速度结论，52 APK与native冻结不变。


### 第52轮 v2 首次续播实测与第53轮首次续播优先
- session94/device-03/nonboundary：新进程固定61500ms，texture4108.6796ms、cover4265.6335ms、query1233.333ms、open1305.6215ms、open后2803.0581ms。首PTS61.500秒，严格stable/返回三资源closed/活动audio0通过；399次时间戳变化、最大间隔145.0537ms，仅纹理消费监听，不是物理显示无卡顿证明。QA正常关闭。原件reviewed.json及return/continuity报告齐全。
- worker video目标headers/body为276.583/277.005ms，audio410.483/410.991ms；native claim864.532/881.040ms，主isolate收到claim却晚1130.505/1117.556ms。path异步await1003506us不能直接算UI阻塞；新增submitUs诊断区分同步提交与异步等待。DM解析仅15.837ms且位于长间隙后，不能归因该间隙。52尚无Android前置包减少计数，也未证明总体提速。
- 用户明确优先攻克首次续播；后续固定新进程61.5秒，取消此前repeat组计划，旧60秒/同进程repeat不混入对照。92旧51的6.764秒含音频目标3.407秒异常慢响应，不能作纯原生解码净收益基线。
- 53新增HEDGE_FRESH_RESUME_PREFETCH：新索引目标段也选当前API另一来源，初始化主/备赢家反转仍正确，最多额外1连接/轨，精确Range/总长验证及落败连接取消保持。24运输/缓存/正文/hedge测试通过；首defined命令写错不存在的isolated_resume_presentation_test.dart，1项实际通过、加载失败保留fresh-resume-hedge-defined-tests-01.txt。改为实际resume_presentation_source_test.dart后3项全部通过（defined-tests-02.txt）。两改动Dart分析No issues found。
- 下一53仅x64诊断构建，52v2 native不变，新开fresh hedge，gate仅增加submitUs记录；下一session95单次冷61500ms。没有手机交付包工作，目标未完成。


- 53构建/94快照/唯一新增fresh hedge开关/native89fe68a9不变/依赖恢复核验通过，APK7e61059db0ca4fa854f5f24f784abf2621ffd05ea5ef407047bfcf6a658ba626。Gradle49088第一清理命令在判断tail包含Idle时assert，未终止任何进程；改核完整日志最后一Build的cwd和完成记录后正常释放，fresh-resume-hedge-gradle-release.json存证。
- session95新进程61500ms：texture3258.6109、cover3754.3473、query392.805、open465.5863、open后2793.0246ms，首PTS61.5。strict stable/返回3资源closed/音轨0通过，无采集错误、正常关闭。连续319次变化、最大gap391.4397ms；不能称无卡顿。比94总体快850.069ms，但open后仅快10.0335ms，前段耗时下降占主要部分，不能归因fresh hedge已总体提速。
- 53property提交15–125us（异步等待29–143ms）；该样本不存在同步提交长阻塞。worker video目标头/正文434.499/436.978ms，audio712.764/721.881ms；native仍到1320.820/1359.139ms才claim，firsttexture在open后2793ms。接下来聚焦native消费前/出帧前等待，不将时间全部归网络。
- 下一96只复用53已安装APK，单次冷61500ms+8秒定向原生trace，核52v2是否实际减少前置送包，以及init/flush/队列等待。诊断与lean时间单列，不补repeat组；不进行手机包构建。


### 用户要求：先完成耗时归因，停止根据可疑点叠加优化
- 用户指出反复提出可疑点然后试改，要求增加监听弄清每段时间。当前立即冻结53产品行为及native优化；54如需构建只增加诊断，不修改seek/解码/预取策略。未实施曾推测的segment reset修改。
- session96诊断成功、正常关闭。texture5170.3527/cover5433.3459ms仅8秒Perfetto重采集，不与95轻监听3258.6109ms混算。首PTS61.5、strict stable/返回回收通过；连续最大gap3366.254ms不可称流畅。
- 包数事实：51重型50个→53重型34个目标送包后才首render release，52减少前置解码确有生效。因此之前关于segment reset可能令改动完全未生效的推测不成立，不据此改代码。精确skip计数与包身份仍需诊断。
- 新tool/analyze_first_resume_timeline.py从现有96原始slice/thread_state无重采集建立不重叠线程墙钟分区，保留time-attribution-01/sql,csv,summary。init490.415ms中本线程运行6.182、S437.365、R/R+40.864、D6.004；start227.038中S226.794；两flush156.757中S155.180。不能将这些叫纯CPU解码。
- target queue→release1450.0088ms精确分区：queueInput540.7793、dequeueInput148.6051、dequeueOutput420.6715、releaseOutput117.9886、录制API外221.9643ms。线程状态合计Running161.8922、S844.9613、R/R+436.9110、D6.2443ms。主要API睡眠由MediaCodec_loop唤醒（wakers.sql/csv），不能只用await总时长判断锁/网络。
- 34次queueInput整个Java外层540.8234ms（首目标native起点比Java晚0.0441ms）：进handler前62.353、handler内346.1283、handler后唤醒调用者132.3421ms。区间内MediaCodec_loop本身等调度624.332ms、运行179.516；服务端HEVC线程运行469.388、等数据/睡眠932.063。并行线程数字不能相加。kswapd同时运行465.736ms只是内存回收竞争线索，尚未用pagefault/压力栈确证因果。
- 官方Perfetto调度文档已核：https://perfetto.dev/docs/data-sources/cpu-scheduling；当前只录sched_switch/waking及gfx/video/view，未录binder因果、系统调用/阻塞函数或用户栈，必须明确这些缺失。下一步先完成前段API→主结果/decoder init前的同条时间线，再针对仍空白区间补调用和等待监听。


### 第54轮：只补监听，不改播放策略（跨入2026-10-31）
- UI前段96直接证据frontend-waits.sql/csv：API正文input+419.0339ms收完，主线程421.782ms开始R+并持续1118.777ms；raster在423.9916ms进入eglSwapBuffers持续1148.5977ms，其间虚拟CPU Running1116.555ms。source.url.response到1687.5809ms才交付。证明大部分是UI未得到调度；不能据重叠直接推断宿主/QEMU内部原因。旧36的QemuPipe mixed/offCPU两个报告冲突仍未消除，不能借旧报告把本次全算IO等待。
- 新Dart STARTUP_WAIT_TRACE仅记录http.transform、content.decode、utf8.decode、json.decode.submit、cookies.save、account.onChange、response.cookies、source.url.model进入/退出，保留原BackgroundTransformer及50KiB阈值、原Cookie保存顺序，日志不含正文/header/cookie/签名URL。首分析发现account.onChange返回Future<void>?类型，已保留null等效完成并修正；第二次五文件分析No issues found。无产品策略改动。
- 新native-wait-trace-01为52v2增加Android ATrace清理属性配对的函数scope，含open_demux_thread/reentrant、lavf探测/打开/读包/定位/IO、mp_seek、decoder init/flush/feed/send/receive及实际preroll_discard PTS。原52分类和44MOV修正不变。源码前后快照/patch/哈希保存。仅mpv增量编译成功，SO9dc15214181e924dc816174246c50483cadaee18f955cce587db1ccf4e9bbaa3，正常卸载；ffmpeg两源码SHA断言仍原已验证值。
- capture新增--wait-trace要求--perfetto，补Binder/audio/aidl/dalvik、sched_blocked_reason、任务名与vmscan事件。保留8秒/32MiB/default 8/6资源门槛；不录屏、不跑并行采集。
- wait-trace.apk v1构建核96源码/单新增define/依赖恢复通过，SHA02995172a8929225f9ebc0334744ba060608329e64dc288a2dd081ca0db4c94a；安装前schema review发现wait.span.end局部时长用了保留字段elapsedUs（会覆盖该事件全局相对时间，UTC未受影响）。v1从未安装，已退役保留；改durationUs防碰撞，只重建v2，不带这个错误采集。schema-review.json记录。wait-trace-v2正在构建，exec90429；完成verify-wait-trace-v2.py后释放本任务Gradle，session97单条冷61500ms+补充trace。下一runner run-wait-trace.py已指向v2，勿装v1。


### 第54轮 v2：完整监听成功；发现全模拟器调度空窗
- v2 APK b7ebe2d66922ec90e34dba432104941ef9be902bd67d2f1f1a493712a3bfc32b，96源码快照/唯一新增STARTUP_WAIT_TRACE/native9dc15214/依赖恢复核验通过；本任务Gradle75704核身份释放。v1退役从未安装。
- session97单条新进程61500ms，wait-trace-01/nonboundary：texture3545.5153ms、cover3648.2194ms，query1235.528ms、open1308.9734ms、open后2236.5419ms。首PTS61.500s，strict stable/返回3资源closed/audio0通过，无采集错误、正常关闭。连续403次变化、最大间隔144.2248ms；仍非物理显示或无卡顿证明。重型诊断，不作相对95或96的优化净收益。
- 应用wait.span共82组全部配对，native pili scopes均完成，trace-stats非零error/data_loss记录为空。Dart/native时钟不确定度7.775ms，因此短于此误差的Dart边界不能拿来判定对应线程状态；span内部Stopwatch时长可单独看，但不是无损微秒级CPU归因。
- 播放API headers回调1217.0494ms、bodyEnd1223.2544ms、queryEnd1262.3724ms。content.decode0.148ms、utf8.decode0.182、JSON提交0.116、response.cookies0.097、model0.118；本条前段长等待不由这些解析引起。
- 主线程199.0958ms起R持续953.3155ms。进一步查全系统：CPU0 surfaceflinger、CPU1 HwBinder、CPU2 idle、CPU3 kworker在约202–1131ms同时无sched切换；203–1130ms无任何已录ftrace事件。96旧trace亦四CPU从423到1539ms同时约1116ms无切换。必须修正此前仅归于UI调度竞争的解释：存在模拟器全局停顿/追踪时钟层面的空窗；guest Running并不能证明这1秒在物理CPU上运算。尚无宿主证据，不确定是虚拟机暂停、宿主等待还是其他原因，不可直接扣掉总耗时。两条whole-guest-gap.sql/csv存证。
- native on_load hook25.029ms，open_demux_reentrant230.2971ms（opener225.7684ms）；init_avctx1628.9711–2262.8813共633.9102ms。其中系统MediaCodec init216.2129/config29.3615/start237.976，另含此前codec发现/Java初始化约133.968ms。两flush41.2265ms。视频目标正文1668.3744ms、音频1844.5904ms已可用，native分别2350.0564/2394.1384才claim。
- 首target queue2405.7405→first render release3483.9563为1078.2158ms；release→texture61.559ms。该线程Running211.0384、R/R+469.1591、S395.6876、D2.3307。API不重叠分区：送input270.1847、取input93.2251、取output279.2308、释放旧output42.1271；其余有具体mpv scopes与API外255.4441ms，见wait-attribution-01。
- 首render前37次真正MediaCodec queue、16次preroll_discard（总53个send/discard事件）；第一批15个送包drop=0，到60.433312s才首次discard，后续drop=2按包生效。该事实暂只说明早期没有丢弃资格，不证明原因是segment reset，不据此盲改。
- Binder补齐部分等待：CodecLooper start内一次161.2826ms跨进程调用到系统codec服务，内部dequeueBuffer/allocateHelper31.97ms、图形服务查询约35.78/33.10/26.97ms（均嵌套，不相加到总时长）；mpv线程API外2573.5998–2690.9337ms有audio createTrack37.1115ms、media.metrics缓存14.5577ms、AudioSession2.5344ms等。主线程audio_service168.4733ms与之并发，不能重复加。
- sched_blocked_reason实际2681条、kswapd wake11/sleep1，direct reclaim事件0；blocked_function为NULL，原始caller是数字索引而非已符号化函数，不能宣称已知道所有锁/缺页原因。
- 下一98只复用v2同包并补Windows宿主线程只读快照、前后时钟括号；不动播放实现。WPR存在但当前非管理员，未尝试提权、未动其他应用。改用NtQuerySystemInformation+GetThreadDescription+QueryThreadCycleTime，先与psutil线程/CPU时间核验；20ms试采单次约11ms负担过高，正式改100ms间隔/最多12秒，第二次自检13样本/median12.33ms，无错误。它是采样，无法给出无损调度、栈或锁主。98runner已启动，当前无构建。


### 第54轮宿主补充：session98，同一个v2 APK，没有产品改动
- host-wait-trace-01/nonboundary单条新进程61500ms：texture3920.2641、cover4348.4395、query1206.659、open1254.0265、open后2666.2376ms；首PTS61.5，strict stable/返回回收通过，无采集错误，QA正常关闭。该样本额外带宿主采样，不能据与97/95的差值宣称速度退化或提升。
- 点击后231.3395–1164.5476ms，四个虚拟CPU同时没有调度切换（933.2081ms）；内区间无已录ftrace事件。host-attribution-01保存自动搜索最大全CPU切换间隔的SQL、CPU身份、事件计数和时钟映射。
- Windows采集121个快照，100ms间隔，单次median15.5971ms/max40.7252ms；前后guest/host时钟括号有共同交集，映射不确定度±26.8589ms。停顿前半段宿主线程31800/67344持续增加CPU周期、采样时是Running，后半段大部分线程Waiting且周期几乎不增加。不是简单把整个空窗当UI工作；仍无栈和锁主，也无线程名（170个GetThreadDescription全部空），不能仅凭ID把它们确定叫vcpu或绘制线程。无管理员权限，未尝试提权或取消其他WPR；既有WPR状态为未录制。
- 同一条可加和分段：input→source.open1254.0265；open→init_avctx694.5957（open_demux655.8764）；init_avctx→first queue968.7378（其中MediaCodec init205.2401/config23.5354/start204.3291/两flush86.8939）；first queue→render984.0101；render→texture18.8940；texture→cover prerequisites428.1754。Dart边界与native对齐误差±6.987ms，保留总耗时，不扣模拟器空窗。
- 首帧后cover等待：mpv事件output-invalidated约3915.157ms，第一组current-vo/path异步读取完成4196.8ms（并行等待约80.3ms），第二组path/current-vo/seeking完成4293.206（并行95.7ms），sourceFrameReady4294.673，stable4348.255，UI条件4348.4395ms。首次纹理至第一组查询实际提交前约196ms仍未有完整事件投递调用栈，不能当80+80或三个95ms串行相加，也不能把cover条件当真实屏幕呈现。
- 两条97/98各首批15包drop=0，后16包preroll_discard。源码filters-f_decoder_wrapper.c:407明确新decoder设has_broken_packet_pts=-10；691处每个decoded output递增，933处必须等于0才允许hrseek framedrop。已找到先验证10个解码帧时间戳的明确代码机制。97首discard前旧output release9次、98为10次（释放不等于解码完成），与重排/持有帧相符；还没直接监听该内部变量，不应把这一关联夸大成完整动态因果证明。下一次native诊断可只补该变量、目标PTS及每次feed的分类理由，先证实后修。
- 新tool/windows_thread_trace.py只读、有限时长、不暂停线程；两个ABI/CPU时间自检保留。新增analyze_startup_wait_trace.py与inspect-wait-chain.py、analyze-host-wait.py生成复查SQL/CSV/JSON。Dart短span对齐精度不足：工具改显式mainThreadStatesAtNominalAlignmentMs、TooShort和Clipped字段；旧01报告的mainThreadStatesMs仅为名义对齐，不得用于小于2倍时钟误差的CPU/等待判断。
- 当前无AVD、无构建、native卷未挂载。持续goal仍active、0.8秒未达到；Gallery恢复义务留到整个测试结束。当前已冻结播放策略，不因一个可疑点继续盲改。


### 第55轮：直接监听时间戳检查状态与事件队列，播放行为仍冻结于53
- native-state-trace-01新增3文件诊断：pts_reset/pts_check/set_target/drop_decision记录每次允许或禁止丢弃的状态；player/client.c记录事件广播、入队、出队，以及带clientId/requestId的异步属性提交与实际执行。不记录属性值、URL或请求内容，不改播放/定时器/检查策略。
- 首次构建前检查拒绝：实际player/client.c比官方v0.41.0多media_kit JNI适配（libavcodec/jni.h和mpv_lavc_set_java_vm），不是无关改动。核对baseline SHA16936c3119f6afb77246ccc8264de25041f91c51704d3867cef87dedb7038650及差异后保留适配；原失败native-build.json和preflight-review.json保留。第二次native-build-02成功，SO6c47efa34ef3c622bd272702e9d59fdcae488d38ba4309f302418220d2b21791，正常卸载。44 MOV与FFmpeg MediaCodec源码哈希不变。4条诊断宏局部变量shadow警告已保留，非格式/类型错误。
- Dart仅新增gate.poll/event与property.request/poll/reply监听；事件16ms、属性4ms轮询及原来源验证不变。24项既有gate/async property测试通过。分析只有两条prefer_initializing_formals提示，无error/warning；不得写No issues found。
- x64诊断APK state-trace.apk SHA169e57c89872798970b2a960822720e7d98be9194b5e6b9f76f920ffebfbea7b。96源码快照/defines与54v2一致/native哈希/依赖恢复核验通过，变化为两Dart监听文件及上轮host capture工具。没有手机交付构建。自己的已完成Gradle78160核身份释放，记录state-trace-gradle-release.json。
- session99已启动，run-state-trace.py exec63538：单条新进程固定61500ms，8秒Perfetto+wait-trace，无host sampler。state-trace-01/nonboundary新目录，不并行构建/额外ADB采样。等待直接证明前10帧检查及首帧后通知生成/投递/属性执行各段。
- 97/98启动日志另见TSC不同步并切到hpet、WHPX启动参数有clocksource=pit。这仅为宿主/虚拟时钟诊断背景，没有证明全模拟器空窗原因；未修改时钟源/CPU/启动配置。


### 第55轮session99完成：直接状态/事件链证据
- state-trace-01/nonboundary单条新进程61500ms：texture3540.6593/cover3808.1911ms，open1171.3381，open后2369.3212。首PTS61.5、strict stable/返回三资源closed/audio0通过，无采集错误、正常关闭。378次纹理变化、最大间隔171.031ms，不是物理显示或无卡顿证明。重型诊断，不称相对97/98或lean优化。
- 同条分段：1171.3381输入/API；349.7748媒体打开；970.4100解码器准备至first queue；1018.0479前置解码至release；31.0885到texture；267.5318到封面条件。Dart/native对齐误差±0.7345ms。核心队列区间Running148.8619、S537.8723、R/R+328.7594、D2.5543ms。
- 直接证实pts_check从-10到0恰好10输出，均errs=0；首queue2491.5229→第10检查3048.2676=556.7447ms；此前14次drop_decision为0，3055.089第15次变drop2。首render前实际34次send+16次discard；556.7ms不能直接称全部可省时间。
- path请求2355.2673提交→2743.6958执行，排队388.4285ms；执行至reply入队0.1357ms，queue→dequeue7.2249ms，Dart397.059ms。等待期间同core在flush114.725、dequeueOutput118.6731、queueInput120.8919、dequeueInput12.5029ms，均明确不重叠分区；与定位/前置解码重叠，不能额外累加397ms。gate等待path导致SEEK入队后276.8304ms才处理，不等于额外延后目标帧。
- first release3509.5708→PLAYBACK_RESTART queue3685.5379=175.9671ms；texture后144.8786ms才入队，queue→gate仅15.0475ms。故前述约196ms空白不能归为界面16ms定时器。此175.9671ms状态Running54.2245、R/R+99.9585、S21.7841；IAudioTrack.start20.6524ms含audioserver唤醒等待20.1894。仍有147.9796ms未标记调用，不能都叫音频启动。
- restart后两组属性最长10.771/31.296ms；sourceFrameReady3753.7141→stable/UI3808.1911约54.477ms。各组并行不重复加。
- 全模拟器空窗再次出现：127.6885–1066.9811ms=939.2926ms，四CPU均无调度切换、内区间无ftrace。宿主原因仍未知，不扣除总时长。
- 72Dart spans全部配对，trace stats无error/data_loss；3个native receive/decode/avcodec_receive scope从trace结束前20.8ms起未闭合（被窗口截断），不能说所有native scope完整。SQL/CSV/JSON保留state-attribution-01。
- round55-time-attribution.md给出完整表及因果边界，analyze-state-trace.py/extend-state-attribution.py为本轮关联工具。reviewed.json中的Two exploratory samples为旧模板文字，本次仅一条；报告明确修正，不伪称分布。
- 下一步：冻结现有53播放策略，补剩余原生主循环/音频链148ms具体调用或采样调用栈；官方Perfetto CPU profiling要求profileable/debuggable，当前release只profile manifest有授权，不能直接声称可采到栈。可用独立诊断授权和精确匹配native符号，需先核验采样就绪与范围。此前36轮raster simpleperf有started就绪机制，可复用但不能沿用只raster目标/错误offCPU解释。未开始新的native/APK构建；下一QA100。当前无AVD/运行构建，native卷未挂载，goal仍active，未完成0.8秒目标。


### 第56轮准备：原生进程调用栈，仍不改播放策略
- 55已取得直接状态/队列证据，上一goal turn为progress。下一目标是解释release→restart中的未标记调用，不凭怀疑修改定时器或时间戳检查。
- 官方Android profileable说明与AOSP simpleperf文档已查；独立release诊断包临时叠加profileable shell=true，完整Dart/native代码保持55。build-core-stack-trace.py会在finally仅删除已核内容的临时manifest并恢复原来不存在的release目录，快照另记录overlay、驱动和采样器。未启用Flutter full-profile/Skia，未构建手机包。
- core-stack-symbols-01只读挂载现有native卷，找到_build-x64/libmpv.so未剥离符号；所有SHF_ALLOC区段名称/地址/大小/flags/字节SHA与55实际17.96MB库完全一致。符号文件50.73MB SHA38993656ac83f74d870a0f497994c88c9b2da33cfd5fd1e2654055296e585755；实际库没有GNU Build ID，以逐区段一致性核实，未重编译原生。正常卸载。
- StartupNativeCpu新增显式process范围：8秒/task-clock:u/100Hz/DWARF/monotonic，仅当前App PID并继承其线程；保留旧raster200Hz路径。等待AOSP started确认才点击；未启用offCPU，避免此前mixed/offCPU歧义。capture --native-process-stacks只接受wait-trace和nativeStackProfiling诊断manifest，禁止与其他native/host sampler叠加。三Python源码语法解析通过。
- Windows simpleperf仅支持报告，其record --help明确不支持，未用于设备采集。GitHub镜像cmd_record.cpp返回404，转官方android.googlesource成功；源码确认--clockid monotonic，原文/hash保留core-stack-symbols-01。没有因资料获取失败盲目启动测量。
- core-stack-trace.apk正在构建exec96475；完成后verify-core-stack-trace.py将核99快照、与55三个原生/Dart库逐字节相同、defines一致、profileable但非debuggable manifest、所有依赖恢复。下一QA100 run-core-stack-trace.py单条新进程61500ms，尚未启动模拟器。


### 第56轮session100完成；采样未覆盖目标区间，转直接函数范围
- core-stack-trace.apk SHA3837773d250f067bb0a3fac9299c63b8bca30d82cf9fab82d66b4db2243b4bd5，99源码/defines及libmpv/libapp/libflutter与55逐字节相同、profileable非debuggable、临时overlay恢复均核验。Gradle43372核身份释放。
- 单条新进程61500ms，texture3744.5641/cover4179.0347ms、首PTS61.5，stable/返回三资源closed/audio0通过，无capture errors，正常关闭。重型采样不能与99作速度净对照。纹理总体回调最大gap2410.1638ms包含启动段；连续正PTS完成间隔最大280.5875ms，不能混用两者或宣称无卡顿。
- simpleperf started确认、单调时钟、8秒、121样本、无lost/truncated记录，采样覆盖input+44.993到6978.694ms。core3442仅8样本：初始化1858.030ms命中MediaCodecList能力枚举/解析→FFmpeg decoder init；之后样本到4225.606ms才再次命中。因此firstqueue2620.3294到release3685.4787以及release→restart3894.0127均0个core样本，不能归因为offCPU或宣称148ms已查明。native-cpu-coverage-reviewed.json明确缺口。未读取到libflutter/libapp符号警告保留，mpv已用匹配ELF符号解析，不猜其他库函数。
- 新增直接函数诊断第57轮：native-loop-trace-01，在原53播放行为及55状态记录基础上增加主循环25阶段、通用filter dispatch的实际filter名、音频init/send/receive/clip及其PTS和样本数、write_video/video_output/schedule_frame范围。通过这些直接scope确定音频等待视频PTS、前置解码、同步裁剪、缓冲、音频start各段。不改变同步规则、buffer大小或丢弃检查。
- 第57原生预检第一次函数定位正则误匹配注释中的mp_wait_events，断言在任何源码写入/编译前拒绝，已正常卸载。native-build.json原失败保留，改为只匹配明确返回类型的函数定义；第二次完整baseline断言通过，native-build-02成功，SOe9bb6fa69ef1ab15021f0e4c3efdc2a79f2795f7b83dbd1a85fd0d2f99527262，normal unmount。诊断宏shadow警告保留，FFmpeg44 MOV与MediaCodec原值仍核对。
- loop-trace.apk正在构建exec42682，无AVD。下一verify-loop-trace.py检查96快照/defines/native57/Dart二进制不变/依赖恢复；下一QA101 run-loop-trace.py固定冷61500ms，仅8秒直接监听与Perfetto，不再开simpleperf或host sampler。目标仍未达到，goal active。


- 第57 loop-trace.apk构建完成：SHA9be212aacd2b76d3140eff1dd29bd7986db56f59f0d195f3fa37b5c9ebd25f23。96源码快照/defines/57 native/55相同Dart和Flutter二进制/依赖恢复均核验；manifest无profileable，未沿用56采样授权。Gradle15408核身份释放。
- 启动101时主机启动器exec6261尚未结束，第一次runner在创建采集目录前因未发现QEMU退出；没有输入或测速。已等待同一启动器成功并核QEMU8388身份，沿用该模拟器而未重启。loop-trace-launch-order-reviewed.json保留；当前run-loop-trace.py exec82986，单条冷61500ms，等待系统启动与准备，不并行ADB/构建。

### 第57轮完成与第58轮独立音频解码实验
- session101已正常结束/关闭：loop-trace-01/nonboundary，首PTS61.5秒，texture5565.2966ms/cover6186.2124ms，strict stable与返回三资源关闭/audio0通过，无capture error。312次正PTS变化最大完成间隔533.8881ms（第一至第二目标纹理）。重型函数监听，不作为速度回归/净收益。
- 直接证据：首视频release5497.4288ms前音频仅送1包PTS59.989333，之后至restart5994.556ms送80包PTS60.010667–61.696。70个音频输出裁剪后样本数0，首保留5935.2092ms/PTS61.5/192样本；5974.95ms音视频均READY，AudioTrack.start17.4667ms；通知入队后0.2306ms取走。release→restart497.1272ms主要处于音频filter/解码/裁剪链，不能全部称解码或可省时间。
- 全模拟器空窗230.2523–1489.3505ms=1259.0982ms，四CPU无切换/内部无已录ftrace事件，宿主原因尚未确证，不扣除。详细同条分区、SQL/CSV与证据边界见round57-time-attribution.md及loop-details-01/loop-attribution-01。82组Dart spans与trace统计保留，非零error/data_loss为空。
- 用户明确授权信息足够后自行转入加速研究。第58轮单改：Android可关闭STARTUP_AUDIO_DECODE_QUEUE，启用mpv既有ad-queue独立解码，2秒/1MiB/192000样本上限。不改video queue、精确目标、最终同步或音频buffer。官方手册提示并非普遍加速，先证实音频是否在video目标输出前提前解码，再做lean对照。Dart controller分析No issues found，四Python源语法解析通过。
- build-audio-decode-queue.py复用57全部开关和native，仅增加audio-decode-queue。verify脚本核新增define、仅controller/build driver源变动、native/Flutter相同及依赖恢复。下一session102同条冷61.5s诊断，无手机交付包。Goal active，0.8秒未达到。
- 第58构建完成：audio-decode-queue.apk SHA23a3d5f1a9d129ea821068eeb14865084624fe5d1d5e3e0642e2b91d74336e9f，96源快照、唯一新增define、native/Flutter与57相同、依赖恢复核验通过。自有Gradle5748完成释放；首次释放保护因日志大小写断言拒绝，未终止进程，导致首次启动门槛physical9.99<10拒绝（无AVD/无输入）。按完整build id/currentDir/完成日志重新核实释放，原失败gate改名保留为emulator102-gate-before-gradle-release.json；随后15.35commit/11.24physical通过，同session102正常启动。
- QA102 run-audio-decode-queue.py exec10843运行中；仍22秒/18秒返回、固定首次61.5秒、8秒直接监听。新增analyze-audio-queue.py跨全部App线程收集音频，以免旧core-only工具漏掉dec/audio。已在101基线核实1包前/80包后，原文件未覆盖。
- 后续若机制成立，已准备103/104/105/106 A/B/B/A单条新进程对照，复用57/58两APK，仅关闭Perfetto采集，两包保留相同Dart wait监听；称匹配无系统跟踪样本，不与53轻监听绝对时长混算。尚未运行这些对照。
- QA102完成并正常关闭：texture4421.9582/cover4715.8934ms，open1449.9694ms，首PTS61.5，strict stable及返回3资源closed/audio0通过，无capture errors。连续正PTS变化357次/max215.6519ms，不是物理显示证明。
- 跨线程直接证实改动生效：video release4334.283ms之前dec/audio3750已解码96包59.989333–62.016s，覆盖61.5目标；之后80包62.037333–63.722667是后续预解码，不可误叫首播前置包。原控制101为1包前、80个目标前后相关包后。两者最终均裁掉70帧，第一保留音频均PTS61.5/192样本。候选首保留4459.5408ms，restart4501.5978ms，release→restart167.3148ms（控制重型497.1272）；仅说明机制和该次区间，不把不同启动状态的全部耗时差作净收益。
- 继续无Perfetto的A/B/B/A，使用57/58这两套完全匹配监听的诊断包。无需再次构建，无新增播放策略。若功能/内存检查失败则保留原始失败，不继续盲跑。
- 103–106无Perfetto A/B/B/A全部完成且正常关闭。控制texture/cover：3660.7873/3894.8584、3587.1732/3803.7351ms；候选3413.2566/3603.172、5155.4377/5517.2986ms。四次精确61.5及strict stable/返回回收均通过。候选第二次明显慢，保留且不剔除，当前不能宣称总起播稳定改善，也不把差值都归为网络（候选2主要慢在open后）。结果audio-queue-no-perfetto-pair-01。
- 改为107同一Android存活周期内00控制预热（排除统计）+A/B/B/A，每次force-stop并验证不同App PID，仍是每个新进程的第一次精确61.5秒续播，不使用reuse-search；协议独立记录为audio-queue-shared-system-01，不与前面冷Android混算。各次都重查7/6门槛、严格来源/PTS/stable/回收、连续间隔，最后统一正常关闭AVD。当前exec96423。
- 后续研究已核官方MediaCodecList.java：getCodecCount与构造器共用进程内initCodecList静态缓存，初始化会枚举并解析全部能力；56实际栈命中此调用。可考虑首次页面后后台预热该元数据，以提前一次性工作；尚未写实现，不把它称收益或确定的大头。官方来源https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/media/java/android/media/MediaCodecList.java。
- session107同Android/各全新App进程完成并正常关闭。预热PID2925 texture3788.3918/cover4137.7479ms排除比较；正式A/B/B/A：控制PID3861 3528.4032/3763.435，候选4427 2625.1122/2786.7895，候选4807 1811.3442/1957.1205，控制5258 2074.6602/2303.012ms。四条均精确61.5、strict stable、返回三资源/音轨0通过，最大正PTS完成间隔150.4228/104.0508/131.5796/168.1812ms。没有同进程reuse；本组是Android已运行的App首次续播，不能与103–106冷Android混算。方向支持保留，控制本身波动大且每组2条，不报固定净节省。
- 完整报告round58-audio-decode-queue.md。音频queue实验开关保留默认关闭，未宣称全面修复；尚待零起点/拖动/暂停继续/取消回归再考虑默认。当前无QA/构建，native卷保持未挂载。Goal active，0.8秒未达，Gallery仍按整体测试结束恢复。
- 利用现有native.csv新增preroll-waits-reviewed.json：101 demux3783的mp_read从3170.5938持续1171.0565ms，与core wait_events559.2337ms重叠；102对应core wait46.8899ms。尚未确证该长读属于哪条轨道/是否预取耗尽，不能算为纯解码或把全部差值归音频优化。下一步优先用现有父子调用/worker记录核轨道与缓存边界，再决定针对性取流改动；或以已命中栈的MediaCodecList元数据一次性准备作为可独立叠加项，不要重新无方向扩增监控。


### 第59轮：目标段大小约束的续播正文预读
- 101视频段579738字节；256KiB预读在268507字节暂停，worker+1017.538ms到1462.334ms接管前约444.796ms不再由应用继续取正文。音频同样前缀限制，但本段104055字节；现有mp_read1171.057ms无轨道身份，不能断言都由此引起。
- 新PREFETCH_RESUME_SEGMENT_BODY默认false，开启后按段长限制在256KiB至1MiB（可超最后一chunk）。不等填满、原Range/精确PTS/256KiB回放前缀/取消不变。控制候选均保留58音频队列，均增加现有100ms字节进度监听；同源码只一define不同。
- 分析首次仅测试cascade提示已改；首次34项测试两条新用例因沿用原夹具前缀期望失败，修正测试比对自身改后的sidx；原日志保留。第二次分析clean、34/34测试通过。计划同Android每次新App进程61500ms，预热后ABBAAB，下一108。
- 构建期间离线复核上一轮9条无Perfetto样本（含预热）：仅2条video预读达到上限后暂停（179.635ms、150.537ms）。5.155秒慢样本仅预读104669字节、未触及上限，本改动不能解释全部慢因。原始逐条结果存segment-body-prepare-01/prior-*-prefill.json；不预设总收益。
- 108预热与正式A/B成功，A1831.989/2237.577ms、B1923.715/2124.762ms；两条video均预读137437字节、未触及上限，当前无此项收益证明。第三条在点击前force-stop的ADB客户端握手失败，原server384仍存活，新60616抢5037端口失败；不是内存门槛或应用播放失败。正常关闭QA，原件/逐条运输报告保留。
- 仅测试准备加入最多3次幂等force-stop握手重试并先完成force-stop再开logcat；不重启共享ADB、不重发实际点击，全部失败尝试留档。12/12故障/搜索/历史/资源测试通过。新109重新独立预热+ABBAAB，不与不完整108合并。APK未改、没有重构建。


### 第60轮草稿：首次能力枚举移至后台首屏后
- 109仍采集冻结的59 APK时，仅编辑后续源码，没有并行编译/分析/设备命令。56实际CPU采样命中MediaCodecList能力枚举；重新核官方源码，共享静态initCodecList缓存。新WARM_CODEC_REGISTRY默认false，首Flutter帧后一次后台调用REGULAR_CODECS能力列表，保持播放不await；不创建解码器/Surface。
- 原生记录同input的System.nanoTime起止与线程；Dart3秒仅停止等待，不声称能取消系统调用。未编译/未安装/未测速；下一步59采集结束后分析并制作独立对照。plan在codec-registry-prepare-01。
- 109预热3509.504/3883.751ms通过；首控制采集本身成功、来源/输入/strict stable/回收通过，首观测PTS61.566688s而非61.5，texture2193.041/cover2322.352ms。精确首PTS验收不通过，原runner断言误把后续独立样本也终止，QA正常关闭。无producer trace不能断言只是合帧；保留不伪称精确通过。
- 修正仅host runner：验收异常逐条记录、后续全新App样本继续，不重发输入。新110改为独立预热+BAAB四条正式；108/109两组原件单列，避免再次为一个验收结果中止整组。59 APK冻结不变；60草稿未构建。
- 110完整预热+BAAB结束、QA正常关闭。候选1751.218/1869.028ms（PTS61.566688，精确首PTS不通过）、1904.075/2033.895ms；控制1718.883/1889.595、1644.383/1840.113ms均精确61.5。全部来源/输入/strict stable/回收通过；候选两条仅预读50113字节未达到旧上限，未证明新增空间利用或速度改善。默认保持关闭、源码保留，音频队列保留。round59-segment-body.md和transport-reviewed.json记录全部批次边界与异常，不把1.644当本项收益。
- 60初次格式检查发现dart:convert导入被补丁附在类后，构建前已移至顶部；随后格式化和两Dart文件分析clean。源码相对59控制仅main.dart/MainActivity/build驱动/host采集准备4旧文件变化，新增能力缓存Dart/Kotlin及ADB准备故障测试3项。60控制/候选驱动及核验器已准备，唯一候选开关WARM_CODEC_REGISTRY；当前开始控制构建，未安装，下一QA111。
- 60控制构建7m01、候选2m27成功；codec-registry-verified核99同源码、仅WARM_CODEC_REGISTRY=true差异、native e9bb6fa...相同、依赖恢复；新Gradle53536按已完成build4d4fd6b9...身份释放。QA111已启动，预热+ABBA各新App进程61.5秒。
- 补核本次recipe的FFmpeg9.0.1：原tar SHA195d54...与已验证构建源一致，mediacodec_wrapper.c逐字节对照原包，503行调用getCodecCount、513行getCodecInfoAt；确认是同一静态缓存路径，但不省其后的逐项匹配或解码器分配。副本与hash在codec-registry-prepare-01。Android16分支网页读取失败，未把失败当源码证据；已验证Android主线缓存和实际采样/本地FFmpeg调用仍有效。
- 111预热3730.155/4394.652ms排除；正式A2812.240/3026.020ms、B2806.634/3299.107ms均精确61.5、strict stable/回收通过。B后台缓存枚举62项耗81.5489ms，在点击前7581.2241ms完成，机制生效但首组未证明总起播收益。
- 第三条输入前物理余量5.297..5.990GiB，50.946s内未连续达到6GiB，未采集。111正常关闭。保留已完成AB，改以112同配置/固定控制预热后的BA补成两个短配对，避免重做成功样本。完整计划paired-short-plan.json；仅112准备等待上限90秒，不降7/6采集和10/10启动门槛、不改UI/AVD/分辨率。

- 112补对BA完成并正常关闭：候选2696.996/3056.938ms、控制2548.417/3144.970ms，均精确61.5/stable/返回通过。候选能力表62项104.1925ms，点击前7909.4505ms完成。结合111 AB，首纹理差首对−5.606ms、补对+148.580ms，无稳定总收益；实验代码保留默认关闭，第61轮不启用。round60-codec-registry.md及codec-registry-results-reviewed.json保留两Android寿命/前置内存失败边界。

### 第61轮：跨进程保留有界续播索引
- 现有索引仅内存4条/2分钟，force-stop后丢失。新增PERSIST_RESUME_INDEX默认关闭，复用已初始化localCache，32条/7天/每条≤64KiB并裁至sidx结尾，不存media payload/URL/headers/进度；实际字节仍使用当前授权请求并经现有原生Range/长度校验。候选先正常零起点seed后重启，明确记录disk命中，不把未看过的新视频称缓存命中。
- 新增磁盘close/reopen、全新isolate和当前HTTP token、请求早于init headers的屏障测试及TTL/容量/损坏测试；保留旧stale hint回退测试。草稿模式if表达式构建前改为显式非空判断并格式化；正在分析/测试，还未构建或声称收益。

- 61分析clean；新磁盘/新isolate/早请求8项通过，原range/index/MP4回退23项通过，共31。第一次将旧previous-boundary用例也误带presentation-time全局开关，10项500000/600000预期冲突失败原日志保留；按原合同分两组执行，未改断言或应用逻辑。Hive子isolate警告保留：主box已close才让子打开，产品端只在主isolate操作box。已准备61同源码对照构建、唯一PERSIST_RESUME_INDEX，native与58一致。

- 61两包构建成功（control6m30/candidate2m28），101快照一致且仅PERSIST_RESUME_INDEX=true差异；native e9bb6fa...及libflutter相同、依赖恢复核验通过。控制SHA9ac2682f5b8b517e92207aa5bf5df0bc6ab75e7ff280b35b6127e41e9337a5ee，候选SHA8e677ea15f631184b24d816ea834934418ca769ffa8302940b52efee12b77362。start-persist-index-validation.py exec56095开始，核对本轮已完成Gradle身份后释放、顺序QA113/114；每组候选零起点seed排除后AB/BA，全新App61.5，当前无额外源码改动。

- 113 seed已持久化video2971/audio2665字节、回收通过；first positive PTS0.2s，仅作seed不计续播/不宣称精确零首帧回归。发现host runner继承open后事件过滤漏掉open前lookup；原始事件完整。仅修后续runner和离线复核为requestId/CID关联全部事件，稳定门槛仍open后；不重采、不改APK。第一runner原统计保留，transport-reviewed明确原值及复核值，preopen-review-boundary.json记录。

- 113控制3253.776/3609.602ms，精确61.5/stable/回收通过；候选点击前初查physical6.078GiB，App就绪后5.933GiB<6被拒，无播放输入/source-open，正常关闭。原始失败保留。host新增可选90s App就绪后等待，lean-short限定，7/6门槛不降、3连过且输入前再检查，全部内存样本记录。4项故障测试连同原12项共16通过。114仅BA对照采用此等待协议，113部分不合并成同停留口径。APK冻结未重构建。

- 114 seed及候选成功：新App3869 disk命中两轨，resume.plan在worker1.503/1.916ms，接管预读video153819/audio163838字节。texture2938.967/cover3439.844ms，精确61.5/stable/返回通过，最大正PTS间隔404.606ms，不称无卡顿。随后控制在启动App前PowerShell门槛physical<6拒绝，无输入，正常关闭。下一115仅相同candidate零起点seed+控制一条，保持114的输入前5秒至少/最多90秒等待；与114首候选按不同Android寿命对照，不伪称同Android配对。无需重构建。

- 115单条控制完成正常关闭：texture2973.380/cover3342.964ms，open299.143ms，精确61.5/stable/回收通过，maxgap244.053ms。相同seed/5秒输入前等待协议的114候选2938.967/3439.844ms，首纹理差−34.412ms但cover+96.880ms，且不同Android寿命每版1条，无稳定总收益。目标计划worker视频1.503 vs261.413ms、音频1.916 vs379.121ms，机制已证。round61-persisted-index.md及persist-index-results-reviewed.json完整记录113–115，默认关闭实验代码保留。
- 下一62转向已量到的MediaCodec实际创建：96重型Init490.415ms、102重型243.276ms，与configure38.362/65.871和start227.038/203.407明确分开，不将这些重型时长当净可省。选定真实视频编码后后台创建一个未配置FFAMediaCodec，和文件头读取并行，FFmpeg按同名接管同一个对象；尚未集成/构建。native-codec-reservation-01/plan.json列单次所有权、取消/超时释放、pending共享与不匹配回退测试。已有VM桥是DartFFI而非JNI_OnLoad，采用mpv已有MPV_EXPORT封装方式，不从native附加线程FindClass查App类。

- 62原生所有权模块已实现：一次对象创建可被同名native调用共享，移交后不再释放；取消/过期/不匹配由后台回收，回退前确保旧对象释放；取消先于worker进入也阻止晚分配。9场景×20轮=180检查，严格C编译及ASan/UBSan非PIE均通过。早期PIE sanitizer两次在main前DEADLYSIGNAL/timeout124，plain和一次PIE也成功，全部日志保留；不把sanitizer启动异常算Android验证。
- Native01预检因WSL Python3.8不支持dict|失败，02因源码没有直接config.h include锚点失败，均在改源前正常卸载。03通过全部原57/source基线后编译，FFmpeg -Wmissing-prototypes拒绝两个新内部导出，已保留原日志；04补显式声明并核03源码后增量编译，FFmpeg成功、mpv正在重连，exec20932；外部卷在脚本finally正常卸载。
- Dart已接入草稿：NetworkSource只携带实际所选DASH codec，首次非零/自动播放/硬解/JNI路径在source queue开始时后台reserve，request取消只发信号；NativeLibrary.path/现有VM初始化已核，不额外查App Java类。新RESERVE_SELECTED_CODEC默认false，builder要求对应自定义native且拒绝NDK组合；两包后续均保留音频队列和61索引，唯一该开关不同。尚未Dart格式/分析或构建APK，等待当前native完成再运行，避免并行编译。


### 第62轮 接入与构建
- Native04成功，SHA 21cf379e7fe42d372c646a386d3f058314c3078e258d1165f40d1f7014732d41；编译脚本正常卸载专用卷。Dart4文件格式/分析通过。初次分析仅private resolver导入和cascade提示：保留与MediaKit同一个自定义库解析器，窄行说明并调整cascade，第二次No issues found。
- control/candidate两包同源同新native，保留61磁盘索引与58音频队列，关闭60能力表/59扩容。只RESERVE_SELECTED_CODEC不同。正在control构建。
- 首次QA116先固定零起点seed（排除速度统计），force-stop后首次61.5秒candidate；原生同一单调时钟记录create/ready/taken，不以配置回读当接管证据。后续117/118/119按A/A/B，每个Android只一条正式采集并正常关闭，避免连续第三条在输入前RAM不足。
- 在实测前审查采集过滤器，补上PiliCodecReserve:I；否则原生接管事件会被默认静音。仅主机采集白名单，control/candidate同源快照会一致收录，无额外轮询。语法检查初次使用系统默认GBK读文件失败，显式UTF-8后通过，未影响构建。

- 第62轮两包构建完成：control6m23、candidate2m34，102源码哈希一致，唯一RESERVE_SELECTED_CODEC开关不同；native 21cf379e7fe42d372c646a386d3f058314c3078e258d1165f40d1f7014732d41、Flutter相同，依赖恢复通过。控制SHA fb28221ec2880035178b9e7056dd5e086a280ef6df2a0f8322e5061984468db6，候选SHA 59cc42441f43b5173a90f6ca90cae2555cdd226bc69ce78cc1777aa226f72d80。自有Gradle已核最后build完成并释放；start-codec-reservation-validation.py exec57926运行QA116，首次接管检查，尚无速度结果。

- QA116首次启动在模拟器启动前被10GiB物理余量门槛拒绝（9.29GiB；提交14.09；无AVD/无输入）。保留codec-reservation-launch-refused-01和emulator116-gate-before-kotlin-release.json。查明Kotlin PID74308由本仓库已结束Gradle53536启动，日志完成成功并闲置98分钟；核父目录/最后build/command/createTime后仅释放该编译器0.653GiB，记录codec-reservation-kotlin-release.json。10/10三次采样通过后重新运行同QA116，exec52808；未降低任何门槛、未动其他应用。

- QA116实测机制通过：App PID3892首次精确61.5秒，texture2539.7325/cover2923.4086ms，open367.7476；create在input316.3504ms开始，531.9024ms ready，767.9955ms由另一native线程taken，创建215.552ms，提前236.0931ms已就绪，taken.value=0（未等pending）。c2.goldfish.hevc.decoder同名对象接管、Dart返回1；disk索引双命中，strict stable及返回三资源/音轨回收通过，max positive gap200.4953ms。零起点seed排除，首positivePTS0.233313而非0，不作零起点精确回归通过。正常关闭AVD。
- 对照QA117（同candidate零起点seed后control一次新App61.5）已启动exec67648。不能把116相对61的差值直接报为净收益；等同源同native控制。

- QA117控制完成正常关闭：texture2538.7477/cover2839.2751ms，open301.3451，首PTS61.5/stable/返回通过，max positive gap413.6391ms。同源对照首对B−A：texture+0.9848ms、cover+84.1335ms，尚无总起播收益；B source.open晚66.4025ms，open后纹理早65.4177ms，两者抵消，不能将215.552ms提前创建耗时称净省时。QA118第二控制已启动exec11162，依既定BAAB补对。

- QA119候选完成正常关闭：texture2287.4415/cover2437.3903ms，open303.1863，精确61.5/stable/返回通过，maxgap255.327；native创建188.9711ms，ready444.6219→take793.6111提前348.9892ms，未等pending。118控制3349.0093/3358.6209ms首PTS61.6失败保留。round62-codec-reservation.md和codec-reservation-results-reviewed.json已完整收尾，机制两次成立但不宣称固定净收益/完整回归，代码保留默认false。
- 63从已录传输入手：116初始流在目标段接管后到首纹理仍收到至少398291video+390427audio字节，119也有。FFmpegHTTPseek成功后关闭old_hd，而Dart分块flush循环没显式看response.done。initial-stream-retirement-01/downstream-close-probe.dart本地真实TCP关闭复现：默认路径下游关闭后541ms仍读278528字节直到source.close；streamForwarding对照停止本地读取但源端buffer仍写。未改生产代码；需要修复并真实HTTP回归后再建包。当前无AVD/Gradle/native挂载，下一QA120。

- 63复现后已实现CANCEL_CLOSED_MEDIA_DELIVERY默认false：把所有Range裁剪转为一个连续addStream订阅，使下游关闭传播到上游iterator；finally显式关闭当前实例客户端，保留server、已缓存prefix、独立resume实例。不是提前强杀native仍可能回退的旧流；只按实际下游流结束回收。SDK源码证明逐块flush在_socketError后可能正常完成，单独监听public response.done不够。
- 相同失败用例修复后34ms内停止读取、额外16KiB，后续500ms计数稳定。新增真实TCP读侧FIN/close回归通过：原始连接关闭、目标连接仍活着，HEAD/缓存字节/目标精确Range/未缓存307回退均正确。44运输测试+2presentation/isolated实际开关测试通过，Dart生产源/新test分析clean；第一次presentation遗漏range开关1pass1skip保留，再正确开关2pass。两次cascade提示是测试风格问题，已修复。
- 正在build-closed-delivery-control.py（exec见当前工具返回）；下一顺序candidate→verify-closed-delivery.py→start-closed-delivery-validation.py QA120。预计103同源快照，只新CANCEL_CLOSED_MEDIA_DELIVERY define差异，双方保留62codec reservation/61磁盘索引/58音频queue，native62不变。当前无AVD，勿并行native/Dart编译。尚无63APK或Android速度收益。

- 63control构建成功5m，103源快照，SHA83d98de9ff88764a907937d808680d5342bfc2dcaf592b80969bdb88fd92478b。candidate当前exec5873运行；完成后verify-closed-delivery.py，随后start-closed-delivery-validation.py释放本次已完成Gradle并启动QA120。不要重跑62verifier对当前改过的工作树；其冻结ZIP仍为权威。

- 63两包成功：control5m，candidate2m20；103源码完全一致，只CANCEL_CLOSED_MEDIA_DELIVERY=true差异，native62及Flutter一致，依赖恢复通过。候选SHA29944b9122667b42d1447579dc9300bf346de2bc888d009653d1a5373007d904。start-closed-delivery-validation.py当前exec52837，先核本轮已完成Gradle身份再释放，启动QA120候选首次接管/旧流回收实测。后续若机制通过按run-closed-delivery-shared-system.py 2/3/4补A/A/B（QA121–123），每次一个正式新App。

- QA120候选机制/功能通过并正常关闭：texture2493.7889/cover2966.3181ms，open326.6391，首PTS61.5，maxgap278.018；codec179.4451ms创建，ready488.2857/taken789.0356，提前300.7499ms。初始video最终162031、audio129263字节后上游关闭，到返回时receivedBytes严格相同；目标段继续输出。具体关闭时刻/claim后延迟见upstream-closure-reviewed.json。传输100ms抽样未再报告不等于claim后精确0字节，关闭后至返回计数不变才是实际停止证据。
- QA121同条件控制已运行exec56196，当前seed阶段。下一继续比较，0.8未达、不把局部回收改善当整体起播修复。


### 第63轮BAAB收尾与64准备
- 120B2493.7889/2966.3181、121A2467.985/2796.7876、122A2619.201/2975.7014、123B2160.6985/2580.9155ms；四条首PTS61.5/stable/返回通过。中位数B2327.2437/2773.6168、A2543.593/2886.2445，差值-216.3493/-112.6277ms，仅描述N2，不称稳定净收益。两B旧流upstreamClosed到return receivedBytes不变。四AVD正常关闭。完整round63-closed-delivery.md和closed-delivery-results-reviewed.json。
- 64 native-unused-flush-01准备：99同线程两次MediaCodec.flush78.4959+46.0409ms在第一次avcodec_receive前，内部CSD提交不等于应用视频输入。候选只在JNI Surface视频decoder从未receive时跳过backend flush，保留FFmpeg清理，首次receive入口永久置位（包括失败）。默认false、后续seek正常flush、时间戳规则不变。prepare-source.py已生成精确f0f113基线patch，生产Dart/build flag接入，尚未native构建/测试/速度结果。

- 64实际receive/flush函数提取后的9种生命周期测试通过（ASan/UBSan非PIE），Dart controller分析clean；native首构建成功并卸载，SHA d20932bd730e6dccbb90bc5a9ed518949c325341ce664b42992502c538e45a85，保留62代码基线。只改FFmpeg mediacodecdec.c及新增小日志header，SKIP_UNUSED_CODEC_FLUSH默认false、首次receive入口永久置位，既有CSD保留、后续flush原样。编译器继承的scope-shadow警告保留，非新增编译错误。
- native-unused-flush-01/build-and-verify-pair.py运行exec45601，顺序control→candidate→verify，两边均保留63回收和62/61/58开关。新日志PiliCodecFlush捕获双包共同的首次receive与最多8次flush配对。完成后运行start-unused-flush-validation.py释放已完成自有Gradle并启动124B，之后run-unused-flush-shared-system.py 2/3/4为125A126A127B。每Android相同排除seed+一次新App61.5，正式要求两次pristine flush的开关对应行为/同instance/first receive之前，所有已用decoder的flush必须不跳过。尚无Android64结果。

- 64两包完成并验证：control6m14、candidate2m31，103源码快照完全一致、native/Flutter一致、依赖恢复；唯一SKIP_UNUSED_CODEC_FLUSH=true。control SHAfd9cad5703055f91665d390f8422bbcf00f8f5b44aced38b08d88f53f5f394b8，candidate b4cf3037d52f8f5bebee6aaf10c0a83fed536abf2275c723b706f2932994eaf4，native d20932bd730e6dccbb90bc5a9ed518949c325341ce664b42992502c538e45a85。start-unused-flush-validation.py exec24269正在核本轮已完成Gradle并启动124B；进程清单仅当前Gradle48952，未见Kotlin，无其他程序关闭。native卷已正常卸载。正式run额外要求至少一次used flush不跳过（通常返回销毁阶段），并单独记录时刻，不能把销毁当主动拖动回归。

- QA124B完成并正常关闭：texture2348.8674/cover2731.3315ms，open335.8785，首PTS61.5/stable/返回通过，maxgap266.3024。原生两次pristine flush在829.1414/831.4491ms均skip=1，区间合计2.3084ms；first receive855.1762ms；返回18540.5364ms used flush实际执行10.7849ms，机制通过。codec创建210.5945ms，索引双disk命中、遗留流关闭通过。
- QA125A完成并正常关闭：texture2730.5584/cover2995.7049ms，open396.5869；首消费PTS61.633313未过精确起点，strict stable/返回通过，失败原件完整保留。两次pristine实际flush34.2705+13.4097=47.6802ms；first receive1167.9506ms，返回used flush9.4513ms。不能把此不合格控制当总起播收益证明。
- QA126第二A当前run-unused-flush-shared-system.py 3 exec3316，已seed完成并进入formal；后续4为127B。两份unused-flush-reviewed/transport-reviewed/first-receive-tail-reviewed已生成。124/125 first receive→texture1493.6912/1562.6078ms，只是尾段elapsed；视频resume body.progress不等于精确网络到包或native消费，禁止直接叫全网络或全解码。后续应在当前64库已有native57 scopes上定向Perfetto区分，或补最少前几帧producer PTS以解释控制首纹理61.633是否跳帧/消费合并；尚未选择/实现新的65行为改动。


### 第64轮BAAB收尾
- QA124candidate texture2348.8674/cover2731.3315ms、firstPTS61.500000、functional=True，pristineFlush2.3084ms、firstReceive855.1762。
- QA125control texture2730.5584/cover2995.7049ms、firstPTS61.633313、functional=False，pristineFlush47.6802ms、firstReceive1167.9506。
- QA126control texture2983.3113/cover3472.3718ms、firstPTS61.500000、functional=True，pristineFlush69.2542ms、firstReceive1037.0213。
- QA127candidate texture2752.8677/cover3097.6271ms、firstPTS61.500000、functional=True，pristineFlush1.8176ms、firstReceive1067.3585。
- 四条机制均验证，返回used flush均实际执行；125精确起点失败保留，不能靠重新定义口径过关。完整round64-unused-flush.md / unused-flush-results-reviewed.json。四实际AVD正常关闭，127首次RAM门槛拒绝在输入前保留，10/10稳定后继续。0.8未达，实验defaultfalse保留，下一定向跟踪当前64尾段或前几次producer PTS；还未实现65行为修改。

- 第64完整收尾已写round64-unused-flush.md及unused-flush-results-reviewed.json。127B2752.8677/3097.6271ms、PTS61.5，初始skip两次合计1.8176ms、返回实际flush8.4609ms。有效第二对B−A纹理-230.4436/封面-374.7447ms，但N1合格对且其他阶段变化，不称固定净收益。124B2348.8674/2731.3315同样合格；125A首PTS61.633失败保留。
- 当前run-unused-flush-current-tail.py exec90730，QA128：先原10/10三次稳定再启动，相同candidate排除zero seed，正式一次新App61.5使用default8/6与8秒Perfetto+wait-trace。复用64已验证APK，不再编译。目录unused-flush-current-tail-01，重型绝对时间不得与lean当净收益；目标区分当前firstReceive后1.5–1.9秒的mp_read/avcodec/主循环/调度分区。采集结束会正常关闭AVD。
- QA128分析顺序：tool/analyze_first_resume_timeline.py <formal>；tool/analyze_startup_wait_trace.py <formal>；parallel-audio/analyze-state-trace.py <formal>；extend-state-attribution.py；analyze-loop-trace.py；analyze-audio-queue.py。各输出x/create目录，勿重复覆盖。先核capture errors与perfetto，再分析，所有原件和失败保留。native仍64、卷未挂载、无编译器；0.8未达持续goal active。尚未选择/实现65行为修改；producer PTS与消费者合并仍未证明，不能把125失败改判通过。

- QA128完整分析结束：current64重型texture3038.1118/cover3693.0351ms，首queue1298.8071→release2997.7633，共1698.9562ms；queueInput589.4124ms其中睡眠466.8229，非纯解码。音频线程4083已解码96帧到62.016，但视频后仍过滤裁剪70帧，release→restart372.3701ms，首保留61.5/192。round64-current-tail.md包含时间表和边界；全部六分析完成，AVD关闭。修复工厂/核心/VO线程选择，extension新增独立查询输出，原拒绝/失败保留。
- 第65轮native-filtered-audio-01：原滤镜输出先存有限FIFO，待实际视频PTS后交回原裁切；最多96frames/2s/1MiB，保留完整PCM/PTS/顺序、EOF、原输出门槛；reset/uninit回收，格式变更先排空旧格式。默认false，可能争用核心使首帧变慢，必须同时对照texture/cover。原64/63/62/61/58叠加保留，未宣称收益。
- 65实际FIFO+prime函数host ASan/UBSan严格编译通过：16真实guard路径、PCM/PTS顺序、容量/NaN/EOF/unread、200次wrap、取消/reset所有权。首次native预检误用未加trace的只读filter.c参考，修改前拒绝；第二脚本生成误改64报告名在挂载前失败，均保留记录。修正只核四个修改基线且仍核完整57/62/64后，native-build-02成功，6f6b8eef12092f5f7e031a61f6958c02195fa44ba96126d6eb33df599ed84dff，卷正常卸载。当前Dart分析/两APK与Android验证尚待结束。

- QA128补充分解codec-input-waits-01：最长onQueueInput79.6953ms，消息线程4070 Running11.5404/R+68.1549；另一52.9646ms中R/R+50.0168，第三41.9882ms中R40.6431。同步输入调用的睡眠往往在等另一个未获调度的消息线程，不能等同硬解计算或固定timeout。只覆盖该重型guest跟踪，不能归因为host硬件。AOSP onQueueInput源码用于结构解释，无新的异步/优先级改动。

- QA129在排除seed点击之前未满足6GiB物理采集门槛，90s内5.28–5.99GiB，commit余量10GiB以上；没有测速输入、没有正式61.5s样本。原capture/failure/正常AVD关闭记录保留。无遗留自有Java/Dart/WSL构建进程。使用现有launcher MemoryMiB参数把仅本测试机2560→2048，完整新130–133 BAAB都同2048，保持CPU/分辨率/渲染器/原门槛和测量定义；新run-filtered-audio-2g-system.py。不和旧2560绝对时间算收益。已核同103源/同native/只STARTUP_FILTERED_AUDIO_LEAD变化，build控制ecc6ecd6/候选1e2d3e68，依赖恢复，Gradle28764完成后已核身份释放。

- QA130更正：2048请求被模拟器自动提高到2560MiB，guest MemTotal2526652KiB，RAM核验在任何App采集前拒绝，正常关闭；没有2GiB性能样本。memory-override-refused.json补齐。未使用-lowram、修改分辨率/CPU或降低采集门槛。新原2560同条件BAAB runner预留QA131–134，启动前额外要求11GiB可用RAM；原launcher10/10与采集7/6保持。当前未运行。
- 65补充实际ao_process vs原版、原mp_aframe_clip_timestamps/skip_samples、原reset及fill_audio_out_buffers主机对照，host-ao-test-05严格C+ASan/UBSan通过。96帧+EOF在1/1.5速、双浮点表示下PCM/PTS/顺序完全一致，30裁切边界、反压/节流、取消、EOF/unread/end点和延迟格式重建通过。原固定C裁切截断对相邻double可保留192或193samples（约一采样点差），两版相同；没有改生产裁切来迁就测试。03缺mock/01调用提取/02前向声明/04错误合成期望全部原件保留。不是真实重采样/设备速度或完整格式切换证明。
- 本轮临时内存查询两次误用了不存在的PS参数与字段，因此不能作为11GiB通过；没有依此启动模拟器。改用MinimumCommitHeadroomGiB/MinimumPhysicalAvailableGiB读取Allowed/PhysicalAvailableGiB，实际10.33GiB、未过加强启动门槛。

- QA128进一步调度归属：首queue→target四核合计6795.8248ms，其中idle1362.9337ms（20.06%）；App2694.5321ms，goldfish HEVC线程511.1999ms。主线程416.8811、DartWorker4029 377.4817、核心391.8509、codec消息线程181.3278、音频133.9551ms。最长codec-loop被抢占66.0248ms内，CPU1仍有45.238ms idle，同时kswapd0运行29.9748ms、kworker/3 37.059ms。不是“四核全满所以只能加优先级”的证据；仍缺affinity/cgroup/host物理CPU归属。重型采样负担包含在内，不能推算手机收益。新scheduler-contention-01原SQL/CSV/summary保留。
- 官方资料复查：mpv仍不建议硬解开启vd-queue；Android35 queueInputBuffers只支持异步模式，批处理涉及MultipleFrames能力，现FFmpeg同步JNI不能仅换方法名。没有据此增加猜测性开关或改变codec模式。下一先完成65原2560两包设备对照。

- 2026-10-31连续第三goal turn的同一设备资源阻挡核验：可用物理9.35GiB、commit余量14.94GiB、live emulator0。65原生及两包、主机实际AO对照均已完成；131–134未启动，没有65测速输入。此前pending关闭闲置应用/允许关闭Chrome的问题未答，不能擅自关闭无关程序；无剩余自有构建器。已到真正设备验证阻挡，准备将goal标blocked（非complete）；恢复资源/得到应用关闭授权后从原2560 BAAB131继续，不重复构建/主机检查或降低门槛。Gallery仍按既有授权等待PiliPlus实际测试结束再恢复。详见native-filtered-audio-01/resource-blocked-audit.json。

- 用户明确要求继续后，已恢复本聊天内实际工作。原生65两包不重建、不增猜测改动。重新审查资源门槛来源，现318份短轻监听去重记录的全流程最大物理回落2.476GiB、提交增长2.842GiB；56份有精确host输入时间记录的输入后物理最大回落1.724GiB。旧243份0.971GiB提交增长不再代表新增样本上界，physical-resource-calibration-01.json保留全部样本来源/哈希；尚未修改任何门槛或新增资源profile。随后可用RAM自然回升11.388GiB，直接启动原2560 QA131候选；prelaunch原10commit/加强11physical三次稳定通过，正式仍7/6，下一132A/133A/134B。先前goal被标blocked的判断不能代替后续资源复查；本次正在实际执行，无用户应用关闭。

- 用户已把原goal恢复active。此前本助手另建的10分钟heartbeat piliplus被用户明确质疑，已通过automation_update delete确认删除；今后继续原goal，不另加定时任务。
- QA131已完成排除seed（texture2993.1914/cover3436.5756、索引持久通过、PTS0.033313不作精确零起点通过），正式新App4177在点击前90秒物理余量约5.8–6.04GiB未达连续6GiB，未发送测速输入，正常关闭。原件和failure-reviewed.json保留。
- 不再重复原6GiB拦截：基于318份轻采集实际全流程物理最大回落2.476GiB，新增显式lean-monitored，限定22–25秒lean release并拒绝全部重型/geometry/deep。起始7GiB commit/5GiB physical，运行中止3/2（物理比旧1GiB更严格）；每次ADB前也核运行余量，测量循环仍每2秒核，额外采集guest vmstat/pressure。初始到中止3GiB缓冲大于全流程观测最大回落；不是性能保证，必须同条件对照。旧default/lean-short及构建门槛未改。8项profile测试通过，旧源码保存在131/host-tools。未关闭用户应用或修改系统内存/模拟器配置。
- 新run-filtered-audio-monitored-system.py预留132B/133A/134A/135B，原2560、原两APK、同视频/61.5/同seed流程；只与此新资源组内对照，记录host最小余量/guest换页回收，不与旧组差值称收益。原额外11GiB启动要求不沿用，新组使用原launcher10/10。

- QA132采集前因新增可选/proc/pressure/memory在GooglePlay user系统被adb shell拒绝，错误地中止了seed；无点击、无测速，正常关闭，failure-reviewed.json保留。已将这项可选统计独立记录unavailable及原stderr，缺失不等同0；必要vmstat与所有播放断言未放宽。下一完整同条件新cohort为133B/134A/135A/136B，run-filtered-audio-monitored-retry-system.py。原131/132两次失败未计性能样本。

- QA133首次65正式播放完成并正常关闭：PID3816、texture2190.0005/cover2536.8494ms、精确61.5、strict stable/返回通过、maxgap169.8086。62/63/64机制均成立，但AUDIO_LEAD完全无事件，new65机制未验证，不能报收益，暂停余下134A135A136B同版本无效重复。选中并安装的APK/native哈希及开关均已核。下一在实际ao_process入口有限记录全部分支状态，查清未进入原因；不改播放行为、不移除guard猜测。计划只替换诊断APK中native库并验同签名/其余payload字节，避免Flutter整包重复编译。

- 65机制诊断native-filtered-audio-gates-01已编译成功并正常卸载：native eea8160d63bcc2f4e6c90d37a72aaa4cdb10845f69bc4cc920d1ff58be4a77a9，仅增加ao_process入口每reset最多12条状态变化日志，不改播放路径。已直接替换原候选APK中的libmpv并重签/对齐，707个非签名payload仅libmpv有差异、Flutter/Dart原样、原签名证书一致，APK a96ba18cac627862878d6493f45f309515eb532f21230130a6e2cf0331fb2e21。避免完整Flutter重编译，约9秒完成。下一run-filtered-audio-gates.py QA134，相同seed后一次新App61.5，仅用于定位未激活原因；不称速度对照。


## Round66: actual audio format, not passthrough permission (2026-10-31)

QA134 played successfully: texture 2150.8661 ms / cover 2331.0327 ms, exact 61.5 s, continuity and return passed. New65 path did not activate. Bounded entry listener isolated mask2048: passthrough permission was the only rejected condition for about715.6 ms before video ready. mpv initializes this permission true for decoded AAC too. Fix66 checks actual filtered frame format and preserves genuine passthrough through unread. Host negative reproduces65 failure (expected assertion134); fixed host regression passes strict C11+ASan/UBSan, actual clip/PTS/bytes equivalence, backpressure, cancel/reset/EOF/format reinit, genuine passthrough preserved. Native and device verification pending; no speed gain claimed. Evidence: native-filtered-audio-format-01/root-cause-reviewed.json.

Round66 setup corrections: QA135 rejected before launch by duplicate10GiB startup checks; replaced startup veto with observation, actual input/runtime capture monitoring unchanged. QA136 boot still progressing at100s readiness timeout, no application/input; normal cleanup closed it. Next QA137 uses bounded300s boot readiness and one persistent Android instance for excluded seed + B/A/A/B, fresh app process each time. Prior failed setup preserved; no results promoted.


Round66 preparation failures and correction (2026-10-31): QA137 reached Android/Wi-Fi ready and installed the exact APK but failed before excluded seed input during concurrent Gallery emulator/full Gradle compilation; no playback trace and no speed result. QA138 QEMU itself exited during RAM allocation; old assertion hid the stderr. Exact records remain in filtered-audio-format-{shared,shared-retry}-system-01 and emulator138-stable.err.log. Verified external build had finished successfully and no Java build clients remained; Gradle --stop closed one idle daemon, then validated idle Kotlin daemon82036 was stopped. No foreground user applications or Gallery emulator were stopped. New persistent runner uses QA139, reuses an existing owned live emulator, preserves it on any preparation/capture exception, reports actual launcher errors, and keeps the shared-Android seed+B/A/A/B protocol. This fixes test control behavior only; Round66 speed remains unverified until measured input and valid playback listeners.

Round66 actual results: observed B/A/A/B now all four have real playback data, same live Android and fresh App processes. B1 texture1948.7654/cover2074.7912ms, exact61.5s, lead93frames, stable/return pass. A2 2013.8261/2285.7656ms and A3 2378.6081/2649.4012ms, exact61.5s and regressions pass. B4 2318.8803/2495.8784ms, lead93frames and stable/return pass but first consumed texture61.633313s FAILS exact position. Tail126.0/177.0ms vs271.9/270.8ms is observed, no overall distribution gain claimed. Separate early return: command1.520s, remaining12 queued frames at clear2.195s; three source closures and zero active audio pass. Did not cancel before drain, kept qualified scope. Diagnostic67 adds only native selected video/audio PTS to existing bounded events to locate first consumed PTS offset; no playback change.

Round67 bounded native-PTS listener succeeded: three real fresh-process resumes select video61.5/audio61.5. Consumed texture is61.533313,61.566688,61.533313; timings1858.8385/1960.2992,1987.5487/2133.7213,1597.7689/1697.2909ms (texture/cover). Selected-to-consumed gaps69.5004/72.5986/72.1590ms. Each stable/return passed; exact-first-consumed rule remains separately failed. Cause narrowed downstream of native selection, not wrong resume target. Android SurfaceTexture official contract can skip older frames on updateTexImage; does not alone identify scheduler/renderer cause. Runtime MediaCodecList capability probe (no decoder creation) reports selected goldfish HEVC lowLatency=false and multipleFrames=false; no ineffective option added. Next single app/video native-span trace excludes scheduler switches and stacks to split remaining pre-frame wall time, explicitly diagnostic-only.

Round67 native-span capture completed on retained QA139, PID8426, texture2343.5012/cover2477.7587ms; diagnostic-only, no scheduler/CPU coverage. Actual target output2195.4484 to restart queued2218.3257=22.8773ms. Identified serial audio priming93 frames1244.501–1530.137ms on video feed core; source mark_progress has no per-core-cycle quota. Detailed exact partition/boundaries in round67-native-spans.md. Round68 prepared bounded4-frame priming cycle, next-loop wakeup, unchanged clipping/FIFO/passthrough. Host before-negative must reject unlimited burst; candidate checks bytes/PTS/lifecycle and fairness. Device benefit remains unverified.

Round68 build preparation: WSL kernel panicked twice and once with temporary nestedVirtualization=false; config restored and raw crashes saved. No compiler ran in those failures. QA139 gracefully closed after its20s wrapper deadline, then actual PID disappearance verified; no data wiped. WSL host tests subsequently ran. Native pre-copy manifest rejected wrong oldheader (missed gate tracing additions), initially misdiagnosed as newline mismatch; actual67mountedheader read and matched66archive, all gate fields preserved. Both old-negative fairness and corrected candidate ASan/UBSan tests passed; native build03 now running. Device cohort will start QA140 with excluded control seed then BAAB, never combine with139as paired timings.

Round68 native build03 passed after QA139 closure; exact whole-source/native checks, unmounted. SHA3d4b266a8ec134eead4c196bd51effef78fad28a8fc6f767bad3ef4595cb9154. Repack cddac00288a85f335715f016486f9a06a08aefa060ae47a556b33edc273f67ea preserves707non-signature entries exceptlibmpv, same signer and16KiB alignment, Dart/Flutter unchanged. Host validation03 passed old-negative and new bounded burst plus clip/lifecycle regression. QA140 launched once, data retained; excluded control zero-start then BAAB formal fresh-app61.5s, lean observation-only. No device gain claimed yet.

Round68 QA140 completed excludedseed+BAAB. B2135.960/2211.730,1866.649/1910.773ms; A2070.707/2198.453,1793.374/1878.681ms. Every formal nativevideo/audio start61.5; firstconsumed61.633/61.533/61.600/61.567so old exact-firstconsumed gate remainsfailed. All strictstable/return passed. BothB93primedframes,max4/cycle,23yields. Mediantexture B2001.304 vsA1932.040;cover2061.252vs2038.567: no new overall speedgain. Keep experimental implementation/records. Listener-triggered cancellation PID5573 prime1012.037ms, clear1704.3765with88pendingframes,no drain/positivevideo; allsourceclosures/zeroactiveaudio passed. Capturegenericexit1is intentional no-frame boundary, not erased. round68-fair-audio.md anddevice-reviewed/test-matrix contain evidence. QA140 remainsrunning; goalactive/unachieved.

Round69 implemented API34+ HEVC decode-only reference preroll, native default off. Direct QA140 same-codec synchronous Surface probe:330 inputs both;121 marked, outputs330vs209, exact PTS-sequence difference equals marked set, EOS both. Native69 build0e4a8056c8e73619b6e563f15faf24fed89b69217df9d8be44ec1fd40ddadab7, APK189fdd155e1b4f9058ead5b96f8c942ab7cce2398ff7946b1e3e40ddb3b39cbe;707entries onlylibmpv changed; same signer16KiBalignment. Preserved timestamp confidence/nonref skip/audio clipping; added known-end/final-second/API/partial/EOS guards and per-packet flag. Extracted real queue-function tests ASanUBSan pass. QA140 closed gracefully once after completed captures, native build succeeded without WSL startup failure, QA141 launched once and retained.
Round69 preparation: source generator rejected ambiguous reset anchor before writing any snapshots, fixed exact anchor. First observer read experimental property before readiness and got adb offline, no playback; reordered after readiness, kept same emulator, records01 retained. New02seed and B1 real captures completed. B1 texture1560.7618/cover1699.1569ms, firstPTS61.5, native61.5, stable/return allpassed. Native marker missing from logcat whitelist caused mechanism auditfalse, not absent implementation: supplemented same PID3858 system log with original monotonic timestamps,15eligible/15appliedflags32. Original logs/failure retained; addedone bounded tag, continue A2/A3/B4 without replaying B1. A temporary suspicion of formatter escaping was disproved by compiled string bytes; running parser was canonical and correct, no native change. All details native-decode-only-01. Goalactive, no speedgain claim until matched comparison.

Round69 complete dataset: same QA141 BAAB B1560.7618/1699.1569ms,1807.2200/1920.8901; A1691.1846/1833.5811,1881.4866/1925.3652. All source/input/native61.5/stable/return verified. Existing exact-first-consumed acceptance onlyB1passes; others61.533313/61.566688 retainedfailed. Candidate15/14reference inputsflag32, controls14/15eligibleflag0. Total mediansB1683.9909/1810.0235 vsA1786.3356/1879.4732, but firstreceive137.3475ms earlier before optimization and receive-to-selected55.9621ms worse; eligible-to-selected only19.7928ms lower, overlapping. No stable attributable gain claimed, experimental code retained/defaultoff. Listener-triggered cancel5619 applied14, close1909.4594ms, audio clear1944.706ms,3requests+activeaudio cleanup pass; actualtarget/drain1614.2962beforeclose, NOT proof of pre-output cancellation. See round69-decode-only.md andnative-decode-only-01/device-reviewed.json/test-matrix.json. Debugproperty restored empty. QA141 PID28092kept alive; native volumeunmounted, no ongoingbuild/capture. Goalactive0.8unachieved. Next focus same synchronous codec wait before firsteligibleinput, no unrelated parameter probes.


Round70 mechanism comparison on retained QA141: thirteen real same-codec local480p HEVC runs completed, exact122-output PTS sequences match. Excluded seed0; neighboring pairs queue-worker319.463 vs sync322.735ms (~3.27ms, no clear benefit); callback-only295.831 vs338.098ms (~42.27ms lower); callback+queue-worker502.987 vs379.747ms (worse, one configure2521.7ms outlier retained). These are firstqueue-to-target codec times, NOT app/input/network timing or app1080p evidence. Chosen callback-only availability with synchronous queueing, no priority/quality changes. Initial01 standalone callback failed beforeconfigure because app_process lacked mainLooper; reportingKeyError also maskedthat. Fixed02mainLooper+8msmatchedwait.01source edited beforearchive, provenance qualified;01never used for performanceconclusion.
Round70 implementation: production Java callback helper owns localinput/outputqueues and onecallbackthread on the existing selectedMediaCodec; flushbarrier/restart, formatrestore, errors/EOS, closewake/idempotence. ActualJava lifecycle initial122, EOS-seek111, partial-seek111 exactPTS match freshsync; fourflushes andpartialcancel close withzeroqueued/threadstopped; blockedownerwoken. Repeated after loading helper-onlyDEX via publicInMemoryDexClassLoader, helper absentparentclasspath: allpass. No app performance claimed. JNI routes sameFFmpegwrapper; locallybuilt8184byteDEXembeddedinnative, defaultoffdebug.piliplus.codec_callbacks, HEVCSurfaceAPI26+. SameAPK BAAB scheduled,decode-onlyoffbotharms. Native-sourceguard rejected an outdated Round62archive beforewrites; corrected to its recordedprototype-repairarchive matchingnative69 hash289286. Actualdiskheaderhash differsfromoriginalLF-text-hash dueCRLF, bothrecorded. OwnedQA141 closedonce afterdirectcaptures, native70build started, no resourcegate or other-appclosure. Newcallbacklogtag included beforeappcapture.

Round70 native build succeeded, SHA22dddc4ca67b0671ba809a4129c996e3706eedf89059646a4742387f06b81369; APK8aeb386acf199c42918a0edc304cc37b661e3b67ca3be5d7f2f1cebbdb95655c,707payload entries onlylibmpvchanged. QA142 PID21852 launchedonce. Excludedseed01 failedbeforemeasuredtap: actualEditTextbilbili missingonei. Fixedpreparation withsemanticready/focus andexactURIverification plusonepaced-clear-refill recovery. Threehostinputcases+threeclearcontrolcasespass; actualAndroidinjectedmissingcharacter repaired in sameprocess withoutsubmit.01failurepreserved, emulatorretained,02same-QA newseed+BAAB nowrunning. No playbackresult or gainclaimed fromfailedpreparation.

Round70 actual QA142 BAAB completed: B4747texture1935.523/cover2094.524,B5883 1693.306/1827.899ms; A5108 2201.444/2382.938,A5518 2169.556/2269.587. All4mechanism/source/native61.5/stable/returnpass; exactfirstconsumedonlyB4pass, remaining61.566688retainfailed. Mediantexture1814.415vs2185.500(-371.086),cover1961.211vs2326.263(-365.051). Receive-to-selected1101.629vs1287.985(-186.357)butwidecontroloverlap, firstreceive141.847msearlier, so promisingnotstableattributable371msclaim. Callbacksetup10.768–21.172ms; allclosedzeroqueue/thread/noerror.
Round70 regressions: cancellation01BACKduringIMEhide producednorouteleave, rejected; rawsamePIDkeyboardlogsretained.02awaitedactualIMEhidden,7115cleanupclosedcallback2392.070ms,audioclear2425.056ms12framesremaining,3sourceclosures~499msafterleave/zeroactiveaudio. Targetdrain1973.936precededclose: NOTbeforetargetcancelproof. Wrapperindentationerrorcaughtbeforerunandarchived. Seek01wrong32secondarguments rejectedprelaunch,02existingUIprogressselectorfoundonly8pxminibaraftercontrolshide,no seek; bothrecordsretained.03existinghorizontalgesture7489passedactualseek: firstnewPTS91.766688s ~829.891msafterfingerup, progressesmonotonicallyto102.433313s; 2actualseekflushes36.375/12.094ms,1returnflush,callbackclosedzeroqueue/thread/error; return3closures~397ms/zeroactiveaudio. Allfailuresandfixesretained. SameQA142alive, nativevolumeunmounted, propertiesrestored. Nextstackexistingdecode-onlywithcallbacks, nofullbuild. Goalactive0.8unachieved.

Round71 started same QA142/native70: callbackavailabilityenabledbotharms, candidateaddsdecode-onlyreferencepreroll; controlcallbackonly. FreshApp61.5BAAB, priorverifieddiskindexes reusedandcheckedperrun, nosupplementalseed/rebuild/emulatorrestart. Outputcodec-callback-stack-observed-01. Bothswitchesrestoredbyrunnerfinally. Compareonlythisnewcohort; previous70timingsnotpooled.

Round71 fouractualsamples completed sameQA142/native70: stackedB7968texture1732.684/cover1823.248,B90812125.089/2349.206; callback-onlyA83531832.863/1938.000,A87121786.607/1883.859ms. Allmechanisms/native61.5/stable/returnpass, exactconsumedonlyB4pass. Medianstack1928.887/2086.227vs1809.735/1910.930: no supportedstackgain, retainedimplementations. Receive-to-firsteligible643.888–716.191ms repeatsbeforeinitial10-outputPTSconfidence; nexttargetthisdefinedintervalwithtimestampguarantees/fallbackreview, notblindguardremoval. Bothswitchesrestoredempty, noactivebuild/capture, QA142alive. round71-callback-decode-only-stack.md containsallcomparisons. Goalactive0.8unachieved.

Round72 diagnostic and mechanism: native70 PID9551 app/video trace firstReceive921.044→10-outputconfidence1616.460ms (695.416ms); PTScheck0.115ms, queueInput184.029, residualsend174.986, corewait95.691, filtergraph76.915, audioreinit65.165ms. No fixed10-frame sleep and no CPU attribution. Exact FFmpeg dual-EAGAIN beforefirstoutput overrideswaitto0 andspinscallbacklocalqueues. Fix adds bounded8ms monitor awaitActivity only there, wakesoninput/output/error/close; allPTSguards/quality/reference/clippingpreserved. RealAndroid480p4runs all122PTSidentical: old494/458polls CPU41.400/31.821ms; fixed7/6polls CPU4.336/3.738ms. Embeddedloader+EOS/partialseek/flush/repeatedclose/blockedwaitcancelpassed. Nativebuild+unmountpassed, SHA b07a6e3cdad94bc0fe8576f55abea584781733cb3500f68af8be4f9bd1b6fca4; APK12d18674384d4033a38afb5c001f3de29acee04fba076f86cd410b7e9abdebe6, onlylibmpvchangedamong707payloads,samecert/16KiBalign. QA142closedonceverifiedidentitybeforebuild; QA143retainedB/A/A/B nowrunning. Noappspeedclaimuntilformalcompleted. Reportround72-callback-wait.md. Two host-onlyediting/searchcommands had quoting/wildcarderrors, noappinterruptionormutation; correctedwithapply_patch/directoryrg. No playbackpreparationfailurethisroundsofar.

Round72 actualBAAB complete: B3877 texture2496.977/cover2591.672ms, A4326 1813.513/1982.308, A4751 2002.168/2087.360, B5152 2680.524/2787.109. All4mechanisms/native61.5/stable/returnpass; exactconsumed2/4. BemptyPolls8/8 vsA1077/96, wait110.173/94.927ms; overallmedian2588.750vs1907.840 noappgain. BothBchoseestgossCDN,bothAvariedmcdnbackups; B4downstream-coupledbodyprogress1252.434ms gap doesnotproveexclusivenetworkwait. Actualseek5564captured,butworkerunexpectedexitbeforeleave causedmissingtrackclosures; native3flush+closeclean/audio0. Keepfailure,notpassedregression. Round73 sanitizedworkererrorlisteneradded; originalparentdiscardedexceptionstrings. LocalTCPcancelandorigintruncationbothpassed,soAndroidcauseunresolved. Samedefines/native72diagnosticbuildactive98230; QA143keptalive; noadditionalemulatorlaunch. Addedexplicitbuildobservationmodeperuserexistinginstruction, noresourceveto.

Round73 diagnostic completed: sameQA143 seekPID6942/return passed, no repeat worker error; original intermittent failure unresolved. Firstattempt hostadb C0000409 preinput preserved; released only verified own finished idle Gradle18268, kept emulator. Native72 tracePID7369 identifies162ms initial send wait matching158ms callback monitor wait; audio firstdecoded1241.448 vs outputreinit1507.574ms. Mainloop already audiofirst. Defaultoff one-frame decoder-thread experiment prepared after queue/reset/lifetime review, actual validation pending. Dart-only rebuild avoids Android/Gradle rebuild. Full evidence round73-decoder-overlap.md. Goalactive/unachieved.

Round74 complete: one-frame decoder thread actualaudioinit82.517ms whollyoverlaps109.554msvideosend; real seek91.633→104.667s/return/callbackclosepassed. FormalQA143BAAB B1881.8865/2000.9115vsA1719.9875/1830.7730ms; overallmedian+166.019ms, notspeedwin. Receive-to-selectedmedian-143.703butfirstreceive+244.559ms; allnative61.5/stable/return, exactfirstconsumed1/4. Actualcancel10101cleanup passedbutaftertarget, beforetargetnotproved. B1targetrangeheaders473.858 vsinitialheaders768.305 explain specificfrontdelay; cachedftyp/moov/sidxcurrentlypredictiononly. Keepqueuecode/defaultoffandstudyfreshvalidatedinitialmetadata. TwoDart-onlybuilds132.547/97.277s preserveallpayloadexceptlibapp.so; noGradlebuild. Oneprecapturewrapperargumentfailurepreservedandfixed, QA143neverrestarted. Fullrecordround73-decoder-overlap.md/nativeresultsunder native-video-thread-01. Goalactive0.8unmet.

Round75 implemented defaultoffBOUNDED_RESUME_INIT: validhint+nonzeroresume requestsfresh0-65535initialrange; no cachebytes served. Explicit206subrange/totalpreserved, followonrangesretainnormalrouting; zerostart/nohint unchanged.32realHTTPtransport tests pass includingfreshbytesdifferentfromhint,target/cached/reopen,full200fallback,HEAD/noRangeGET,invalidpartial. Exactupstreamn9.0.1HTTPsource confirmsrange_end/EAGAINcontinuation. Source/protocol/plan savedbounded-init-01; Dart-onlycandidatebuildrunning, noAndroidtestyet. StackkeptRound74oneframequeue inbotharms.

Round75 actualcandidatecda0ea8b... completed: firstseekdiagnostic10641initialvideoheaders497.6msbutbodyonly3871bytes, native7.96sreopenat3871, texture10397.857ms.6sseekprecedesactualstartupanddidnotproveactualseekregression; returnpassed. Preservedfailure, noformalBAAB. No-gesturestartup11058sameAPK1855.501ms, exact61.5, bothfresh64KiBinitialranges andreturnpassed; so no deterministicprotocolbreak proved. Header-onlyhedge selects/cancelsbeforeanyusableinitialbody; nextRound76controlledslowbodytestandbody-readyselection. Range75retaineddefaultoff; stackbodyraceagainstbounded-onlybaselinewithsamequeue/native. ChainedsourcesZIPduplicateprovenancecorrectedwithoriginalarchivepreserved; APKunchanged.

Round76 implemented default-off HEDGE_INITIAL_BODY. Initial hedged requests require fresh bounded prefix before winner selection; target prefetch unchanged. Controlled HTTP test proves old header-only selection remains stuck on primary while body-aware selection uses completed backup. Pending consumers cancel without hanging. 39 focused tests pass. Build49088 and QA143 ended across host reboot18:34; no output APK/no playback data. Verified no live compiler, preserved incomplete builds and restored exact staged dependency to clean tracked original. LF checkout recovery failed clean guard and fixed with verified HEAD checkout conversion; no compiler launched by that failed attempt. Resumed output initial-body-hedge-resumed-candidate.apk; fresh emulator boot required, no old/new boot pooling. No speed improvement claimed.

Round76 resumed candidate built150.560s, SHA81ff49cfb24b05332ae0d67a41b69a502a021f9501fbc229f4eda001e3cff1b2; onlylibapp.so changed. First emulator launcher exited before boot with missing ANDROID_SDK_ROOT; corrected child environment explicitly and retained failed logs. Current QA PID20152/create1793439946.078732 boot completed,1080x2400/density420/data preserved. Control build active15329; real playback has not started yet. Prepared BAAB body-contract assertions and earlier reservation-triggered cancellation, preserving separate consumedPTS check.

Round76 actual new-boot mechanism3571: texture3246.6063ms, source-open1280.673ms, exactfirstconsumed61.6s; body-backed selection passed, return passed. Same-boot fresh-app BAAB4044/4520/4897/5343: B1689.5946/1647.6101, A1732.4158/1576.8960ms; medianB1668.60235 vsA1654.6559(+13.94645), no normal-start speed benefit. Cover+7.73435ms; firstreceive-65.127ms butreceive-to-selected+14.422 andselected-to-texture+64.652. Allmechanism/native61.5/stability/return passed, exactfirstconsumed1/4 only. Preserve defaultoffbodyhedge and controlled-stall evidence.
Round76 cancel5810 request1.808s aftertap was too late; IME state dumps delayed it. Corrected cancellation-only fixture hidesIME/revalidatesURI before measuredtap.6237 returnrequested349.7842ms, nopositiveframe/nodrain, reservedcodecreleased568.371ms, callbackclosedzeroqueues/thread, 3sourceclosures/audio0. Genericcapturerexit1expectedbecausepositive-texturerequired; statuscaptured/errors[]/validinput and independentcancelreviewpassed. Thisfixtureexcludedfromperformancecohort.
Round76 seek6674 had firsttexture8377.2767ms after6s gesture; cannotclaim steady-playback seek regression or pureinitial-resume timing. Freshinitial64KiBcompletedby~656ms; targetvideobodyselectedbyheaders at434ms, only112860bytes at1186ms beforestall; native laterreopenoffset6421575 (=121053bytesaftertargetbase6300522). Source/timeline rawrecord preserved. Nextfix extendsbody-based selection to targetrange.
Round77 defaultoffHEDGE_RESUME_BODY usesexistingbounded256KiB (orsegmentconfiguredlimit) warmup beforeselectingtargetwinner; currentrange/length/bytes/seek/close unchanged, reuseonewarmupsubscription. Controlled113KBprimary-body-stall negativeandpositive pluscancel pass; entire focused suite42passed. Fluttertest auto-pub replacedpatchedmaterial_ui root; builderrejectedbeforecompile. Preservedconfig, restoredexactarchivedmapping and reran42with--no-pub, allpass. Use--no-pub forfuturetests. Verified-candidateDartbuild14292 running; noactual77deviceproofyet.

Round77 firstactual7343 played2154.732ms/firstPTS61.633313s, noerrors/workerfaults, returnpassed. Video targetselected268507prefetchedbytes, butaudiohadno targetselected event: wrappercorrectlyfailedmechanismassertion afterplayback. Audiosyncarrivedworker2.505msduringlocalbind; _resumeBackup onlyassignedafterbind. ControlledalignmentDuringBindcase reproduces3pass/1fail withoutproductionchange. Moveendpointandhedgedelaypublicationbeforefirstawait;43focusedtests nowpass with--no-pub. Thisisactualsourceinitializationrace, notcapturepreparationfailure. Correctedalignmentcandidatebuild51360active; same native72, noquality/positionchanges. FormalpairrunnerpreparedbutcontrolAPKnotyetbuilt.

Round77 correctedalignmentcandidate SHA1103b7dcbc221a98f3962eac19cdbc3fdf08f7aaa53613314d973051d38f63d1 compiled100.964s. Actual7880 texture2073.3883ms, consumedPTS61.533313000s, strictStable=True, validinput/source, no workerfaults, returnpassed. Both audio/video targetselected268507prefetchedbytes; video1004.763ms/audio1037.086ms workerclock, provingbothpaths nowactive. No speedgainclaimed fromsinglemechanismrun. Same-sourcecontrol HEDGE_RESUME_BODY=false compiling39472; BAABrunnerready. Noactivecapture; currentQA20152 retained; native72unchanged; nootherappsclosed.


Round77 completed BAAB: B2238.9463/2004.8424 vs A1903.3247/1657.3668ms. Texture median B2121.89435 vs A1780.34575ms; net gain(control-candidate)=-341.5486ms(-19.1844%). Cover net=-328.5479ms. All native61.5/stable/return pass; exact consumed1/4, failures retained. Both audio/video target body selections activate on both candidate samples. Disable 256KiB winner gating for speed configurations, retain source initialization-order fix; its separate speed gain is unmeasured because both arms contain it. Exact phases and evidence hashes in resume-body-hedge-01/alignment-cohort-reviewed.json. No seek/cancel result claimed for77.

User requested per-change net gain. Added net-gains.md/json + deterministic update-net-gains.py for66/68/69/70/71/72/74/76/77 and explicit unknowns; .agents/AGENTS.md now requires baseline, complete samples, net ms/percent, local-vs-total distinction and retention decision. No cross-cohort addition or stable-causal claim.

Phone release completed: historical Round69 48 production files and all optimization flags verified; ARM64 native built from69, default decode-only on matches measured property1 while keeping all guards. Trace/fixture disabled, same previous phone signer, APK/ELF16KiB alignment and ARM64-only payload verified. APK D:\workplace\antigravity\PiliPlus\output\releases\PiliPlus-fastest-resume-r69-arm64-release-20261031.apk SHA256 8c6284a2aa7a95bc9fb4a7f51760e24a32d7232904a9bc388c653c75373198d5. Historical1.5607618s single emulator sample does not measure phone performance. Native current72 and four current Dart files restored byte-for-byte. ARM64 build passed; app BUILD SUCCESSFUL12m27s,87 tasks executed. No additional device speed test for packaging. QA20152 closed once preserving data; native volume unmounted. Original acceleration goal active.

Round78 completed same-native70 ABCDDCBA. Callback-onlymedian1758.1946 vsneither1913.9648ms net+155.7702; adddecode-onlytocallback median1852.8990 net-94.7044. FullnativePTS/flags8of8, exactfirstconsumed3of8. A8 originalreturnreviewfailed; samePID lateclosure4.01-4.06s preservedasfailed;102progressframes/maxgap2644.5ms unresolved. No replay or selective deletion. Seeround78-common-baseline-net-gains.md.
Round79 separate480p codecprobe earlyoutput-onlyflag preserves330inputs/alltargetlaterPTS/EOS, oldmedian648.51335→626.6279ms local+21.88545 only. No nativeproductionchange or appgainclaim.
Round80 callback1/wait0/decode0 videoqueueBAAB complete, net+278.35775ms; neighborpairs+312.6072/+244.1083. Firsthalf4+s/secondhalf2+s and foreignbuildconfound; bothcontinuousgapconcerns02/04 retained. All4return/native61.5 pass, exactconsumed0of4. Preservecandidate, notstablegain/default.
Round81 implemented defaultoffRESUME_BODY_FAILOVER: immediatebody then one350ms unpaused-stall alternate Range retry; bounded64KiB byte-overlap validation beforepromotion, no targetbuffer gate.52 focused tests passed including113KBstall throughactualproxywith/withoutwarmup, negativecontrol, malformedrange/total/200/encoding/overlap, pause, cancel, primaryrace, retrytimeout, truncation. Appgainunmeasured. Nativeunchanged; Dart-only pair pending.

Round81 candidate Dart-only build142.648s, SHA70dc44e824236f97e14c14d338ca044fe17bf8b86ae0f986e118fcc449d09550; native/engine/assets/signature/alignmentunchanged, newsourceincludedexactlyonceinarchive. ActualcancelPID9670 triggereddecoderreceive.first at0.677s hostaftertap, nopositiveframe/nodrain; bothbodyRecoveryarmed; return3sourceclosures722-724ms andcallbackclosedzeroqueues/thread/error. Genericcaptureexit1expectedfornopositiveframe; independentcancelreviewpassed. Matchedcontrolcompiling; timingsnotyetcollected.
Round81 actualseekPID10112: listenerprovedpositiveplaybackbeforegesture4.183s; firstnewPTS90.766688 afterfingerup482.69ms, monotonicthrough106.233313 (>15s);2actualseekflushes andreturnflush, callbackclosedzeroqueue/thread/error, returnpassed. Separatefunctionalrun initialtexture1534.0251ms notformalAB. ControlDartbuild99.803s, SHAcd5f31ec490b150aca9b81f3e84e4319ce7af7647b18b8f366ff542c52c91b67; sameallsources/native andonlyRESUME_BODY_FAILOVERdiff verified. Bothbuildscompletebefore81formalBAAB.
Round81 formalBAAB complete: B1673.5524/1708.7726 vsA1832.6436/2050.7833ms; med1691.1625 vs1941.71345, net+250.55095(+12.904%). Cover+198.54245. Allnative61.5/mechanisms/return4of4, exactconsumedB2of2/A0of2. Candidatecontinuousmax112/168ms, control02gap633msretained. Onlyretryafterfirstframe04video678109bytes, thenprimaryresumed119mslater; no actualswitch. Thusnoattributableswitchinggainclaim;52controlledHTTPtestsseparate. Preserveexperimentaldefaultoff; source/test/runnerhashesandledgerupdated.
Round82 actualcurrentbaseline targetednative/schedulertracePID12200 complete,17.4MB; returnclosures352-353ms, diagnostictexture2453.0566ms excludedfromlean comparisons. SameexistingQA144, no build/emulatorrestart. Analyze recorded waits to address remaining normal-path gap.
Round82 reviewed: receive848.9366→targetrelease2249.2384ms =1400.3018ms exclusive decoderwall. SynchronousMediaCodecqueue570.0006ms includes424.5128sleep/136.0621runnable/9.4257guestRunning; outsideinstrumentedwork545.1706 includes528.758sleep. No traceerrors/loss; wakerIDsallmissing, no exactsleepcauseclaim. Current72JavaqueueInputBufferconfirmed synchronous althoughavailabilitycallbacks exist. Next83dedicatedinputqueueprototype withstrictPTS/EOS/flush/cancel/errorownership before anynativebuild. Default81experimentaloffretained, phonepackageunchanged. Analyze4changedDartfiles clean.

Round83 actualsamecodec480p helper prototype: input queue worker+flush/close barrier, samecallbackavailability, waitoff. CompletePTS122/EOS/seek/partialflush/repeatedclose/blockedownerwake pass; deterministicpendingflush/close discard1inputafterbarrier andasyncinvalidrangeerrorforwarded/threadsclosed. BAABtargetasync262.7421/315.7528 vscontrol297.5911/300.2483ms: localnet+9.67225ms; ownerqueueoccupation-409.93565ms acrosswholeclip, firstoutputCPU+28.07297ms. Not appgain, nativeunchanged; preserveprototype. Old70combined-negativeevidence retained.
Round84 same83helper, onlyinitialdual-EAGAIN1msawaitActivity vsno wait. PTS/EOS/threadclosureallidentical. Targetmed255.6574 vs250.5757ms =>localnet-5.0817ms; ownerCPU50.06884→8.40639ms, usefulCPUreductionnotlatencywin. No nativebuild basedonthisevidence.
Round85 addressesmeasuredslowtrickle: progressdeadline andcatch-upvalidationwhileprimarykeepsflowing, defaultoffRESUME_BODY_PROGRESS_RACE. Initial5controlledHTTPtimeouts exposedrecomparisonafterpromotion; fixed !_promoted guard, retainedfailurelogs/reconstructedsource. Complete59suitepass andsourcewiringpass. Native/prototypecanonicalsourceunchanged. MatchedDartbuildandactualtestsnext; netgainunknown.

Round85 complete: candidate/control Dart-only builds109.275/114.406s; native72/assets/signature unchanged, same source hash map and only PROGRESS_RACE flag differs. Actual cancel13242 beforedrain/positiveframe, allcleanup passed. Actualseek13679 firstnewposition1597.2067ms then14.4s monotonicplay,3flush/return passed; no speedclaim. QA144 originalBAA1727.7389/3354.8359/2118.9423ms retained; fourth beganplayback but QEMU19164 stopped/no CPU then exited. Crashpad Event1000 0x80000003 andgraphicscontextfailures saved, exactcrashcause unknown. BACK/pulls timedout; guesttracefiles emptyafterrestart, rawlogcat retained. Recoveryhosthelpermissingcid fixedusingannouncedCID. No oldsample overwritten or counted as normalcompletepair.
Round85 QA14541636/create1793449197.0174248 samepreservedAVD: excluded0s seed, formalBAAB B1611.6720/1660.8562 vsA1816.3970/1842.8990ms. MedB1636.2641 vsA1829.6480; observednet+193.3839ms(+10.5695%), cover+151.0071. All4native61.5/stable/return, candidateexactconsumed2of2/control0of2, maxgapsbelow500ms, noworkerfaults; hostprocesslisteneralwaysrunning. No slow-prefixretry or actualswitch; candidate04onlyoldno-progress retryafterfirstframe. Do notattribute193ms toprogressrace. Preservedefaultoffexperiment and59controlledtests.
Round86 evidenceonly: re-read82rawnativePTS:189audioframes decoded59.989333→64.0 beforevideo61.5release; filteredFIFO93framesends61.952. 92frames decodedbeyond fullFIFO+0.08s, audio thread74.1912msguestRunning afterthatpointbeforevideo (overlapsvideo, notclaimedlatencygain). Officialmpv queueconfigschangeat runtime via m_config_cache_update/update_queue_config. Next boundonlystartupdecodequeue thenrestoreoncurrent-sourceframe/cancel/deadline; preserveFIFO/preroll/exactclip/outputqueue. No86codechangeorspeedclaimyet.

Round86 implemented defaultoffstartup audio decode queue capacity0.08s, restoredexactpreviousvalue oncurrent-sourceframe/cancel/replacement/dispose/error/5s; filters/preroll/AO untouched.35focusedtests passed. Initialfakeclock tests6failed dueCompletercreationoutsidefakezone; correctedand35passed; thenreplacedtransitivefake_async dependency withrealmicrotasks/zero-deadline tests,35passedagain. Failures/source retained. Nativeunchanged, candidateDartbuild23273 pending; no speedgainyet.

Round86 actualmechanism: originalcandidate5da0b6f5 build145.312s/control64860067 build137.219s. Cancel6563 noframe/nodrain andsourceclosures458–525ms/callbackclosure pass, but queue0.08restore was skipped becausecancelSource alreadyadvancedrevision; featurecancelnotpassed. Fixedsynchronousrestorebeforematching-ownerrevisionadvance, extraorderingtest,36pass. Originalfailedqueueevents retained. Fullnormaltrace7041 nativeaudio count189→99 andlastdecoded64→62.08 beforevideo61.5; filteredFIFO remains93 ending61.952; current-sourceevent restores0.08→2. Diagnostic2112.9253ms notcomparedtolean orattributedasnetgain. Fixedcandidatebuild74645active; newmatchingfixedcontrol thenactualcancel02/seek/BAAB.

Round86 fixedcandidate8cf17a27 build137.499s/control977ee9e6 build111.655s; allsource/native/engine/assets/signatureequal exceptBOUNDdefine/Dartpayload. Actualfixedcancel7671 restores0.08→2 before sourceRevisionadvance; nopositiveframe/nodrain,zeroqueue/thread/error andreturnpassed. Seek8119 actualnewPTS89.7 after1617.0613ms then104.0,3flush/returnpassed; no seekspeedclaim.
Round86 formalQA145BAAB B1936.8264/1682.7530 vsA1834.7250/2116.4439ms. MedB1809.7897 vsA1975.58445; net+165.79475ms(+8.39219%), cover+175.05915ms. Firstreceive B783.6724vsA780.9844(2.688mslater),receive→drain964.49585vs1140.7785(+176.28265ms),tail7.8msworse. Native61.5/allmechanisms/stable/return4of4, exactconsumed2of4, maxgaps122.4481/101.7183/109.8071/138.1244ms,noworkerfaults. Neighborpairs-102.1014/+433.6909ms: retaincandidate, no stablegeneralclaim,defaultoff/phoneunchanged. Hostprocesslisteneronlyrunning.


## 第87轮启动：将83异步输入原型接入实际播放器

控制和候选使用同一个native87/APK，继承86音频解码0.08秒限量，只切换debug.piliplus.async_input0/1；callbacks1/wait0/decode0/videoqueue1。Java完全复用83已验证原型；JNI增加布尔构造参数及15项回收快照，任何未退队列、存活线程、异步失败均记原生错误。真实内存DEX两模式通过122帧首段EOS、111帧换位置、部分解码后flush、重复close、等待者取消；异步实际取消1个排队输入且双线程退出。

原生构建成功，工作卷已卸载。APK仅libmpv不同，签名和16KiB对齐核验通过，Dart/Flutter字节相同。QA与已授权相册模拟器暂时关闭后均已恢复并完成启动检查；保留数据。新QA PID 35136，采集另起运行周期，不混入86样本。应用净收益未确定，先做实际取消/拖动，随后排除种子的BAAB。


## 第87轮完成 / 第88轮分解剩余提交等待

87正式BAAB候选1668.9571/1664.3367ms，对照1847.8953/1602.6630ms，中位净差+58.63225ms；首次receive晚40.81105ms，receive→drain快66.68395ms。N2每组、相邻对方向不同，保留候选不称稳定保证。取消PID3546、拖动PID4114（962.735ms后恢复、随后15.27秒）、四条连续和返回全部通过。诊断PID6621首纹理2459.2444ms，仅用于分段，17MB跟踪无丢失；decoder6890、inputworker6891。avcodec_send623.536ms，其中睡眠288.082；段外597.708ms含睡眠530.075，原因未由旧监听细分。

88只补input.dequeue/get/copy/submit和output.dequeue时段；不改变算法，不记速度收益。当前检测两台旧模拟器均已退出、adb无设备，未由本轮关闭；构建后启动原QA数据。


## 第88轮结果

诊断版从87原生库增加JNI输入槽获取、buffer取得、复制、输入提交、输出获取五类区间；不改变解码行为。跟踪运行在独立5572设备。

PID2840，decoder3757，inputworker3758。首纹理5935.5573ms仅作重监听诊断，不计速度。系统跟踪无丢失错误，返回回收通过。

|avcodec_send内部独占阶段|墙钟ms|运行ms|睡眠ms|
|---|---:|---:|---:|
|send.other|120.4705|50.2609|16.4251|
|pili.codec.output.dequeue|515.5557|23.5638|219.3252|
|pili.codec.input.get|11.8175|2.7174|0.0000|
|pili.codec.input.copy|0.9366|0.9366|0.0000|
|pili.codec.input.submit|9.9268|3.4197|0.0000|
|pili.codec.input.dequeue|151.5247|48.6985|0.0000|

首个未呈现参考帧释放前，零超时输出查询387次、输入查询369次（合计756），实际输入只9次；从首次输入提交到该参考帧释放456.3012ms。首输出已经发生后才会release，所以不能把全部756次都称为输出出现之前。

结论：缓冲区获取、复制、提交占比小；提交阶段内部主要是FFmpeg同时调用的输出等待。等待包含所需解码服务和调度，不可直接删除或当成可获得的提速。下一步在87轻监听同一APK上测试async1/audioBound1+callback_wait0/1，减少输出出现前双空端口循环，记录整体净收益。此轮没有速度收益。

原始第一次采集在点击前被另一项测试将前台切到cn.weibo.filedownloader，失败XML保留，非播放样本。仅将本线程原QA改到5572，未关闭其他测试设备。

构建工作卷当前是诊断88（wrapper/common增加区间），已卸载。后续速度库构建应从保存的87行为恢复这两份诊断文件，不能误把88重监听当成87控制。所有旧库保留。

## 第89轮开始

控制/候选同87轻监听APK，仅callback_wait0/1，async1与86音频限量相同。独立5572运行周期完整BAAB，不与87/88跨批相加。净收益待定。

Round89 completed negative: sameAPK87 BAAB wait1 vs0 on5572. Candidate1908.6403/3353.7166ms vscontrol1756.7305/1662.0060ms; median net-921.8102ms. Both adjacentpairs negative, B4 continuity gap1066.9763ms, exact consumedPTS1/4, native target4/4 and returns4/4. Callback wait explicitlydisabled; retainimplementation, rawdata and priorgains. B4 video body342236B over2612.164ms fromfirstchunk beforefirstframe; fullplaybackwaitsum109.1343ms, so do not blame all extra latency onwait. Continue slowcontinuousdelivery investigation; phone69release unchanged.
