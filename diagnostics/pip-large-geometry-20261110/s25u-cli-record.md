# S25 Ultra 跳转监听和 CLI 控制

设备已经由用户连接并授权。ADB serial `R5CY13T5Z3J`，型号 `SM-S9380`，系统实际返回 SDK 36、One UI 80500。

更改前已保存手机原安装 APK 和 SHA-256 于 `s25u-baseline/installed.json`，原包为 `6c7e8302763f289039390e5fc14b4dbd9127bf83ca41bb158af4a0a12041262c`。

本次只加诊断和控制，不改变音频输出、视频解码、取流或起播参数。已读上游报告为 https://github.com/mpv-android/mpv-android/issues/1283 和 https://github.com/midasvo/ephyra/issues/52，三星 Android 16 的 AAudio 跳转故障与用户症状吻合，但本机根因须用当前手机监听和单变量验证确认。

## 控制接口

- 主机 `tool/pili_cli.py --serial R5CY13T5Z3J`。
- 命令包含 `open BV...`、`status`、`seek 秒数`、`play`、`pause`、`export`；`audio-output` 只用于后续明确的运行时单变量对照。
- APK 仅在 `SEEK_RUNTIME_TRACE=true` 时注册控制桥，广播发送者必须持有 `android.permission.DUMP`，不监听网络端口。
- 每条命令用唯一 requestId，返回 accepted/complete/error/timeout 和时间戳，不以广播命令成功代替应用操作成功。
- 状态读取使用独立 mpv 弱客户端的异步属性请求，800ms 超时；跳转监听每500ms采样，最长10秒，含实际 current-ao、音频/视频PTS、time-pos、seeking、paused-for-cache 和 Dart 缓存进度。
- “关于”页可导出当前进程的 Dart/Android 监听、设备信息及自身音频相关 logcat；CLI 也可直接导出并拉取 ZIP。导出测试确认只导出当前进程、不含旧 QA 或无关文件，并等待 native flush。

## 验证记录

- Dart 控制、导出和播放控制模块分析通过；导出 ZIP 内容及隔离测试通过。
- 第一份 CLI 候选 `753e14fc64abc0326d64b55ac7e67b7d989727207c044a85feb727a90fa15cc0` 的原生接收类存在，但 Dart 控制入口字符串和构建依赖缺失；手机控制请求没有回复，判失败。不能称 CLI 已可用。
- 独立 `lib/seek_diagnostics_main.dart` 入口已在三星收到结构化回复；首条 `NO_PLAYER` 当时未打开视频，随后唤醒并进入视频后正常返回。失败包和日志保留，不作为完成结果。

## CLI 扩展及三星实际操作

已安装控制版 `output/releases/PiliPlus-2.1.7+7-S25U-CLI-controls-20261110.apk`，SHA-256 `1ec970ae37d130760bccf75f4833c73ec5deba02cc8bcc8f3533ccfb8065b291`，原生 libmpv SHA-256 保持 `5d93acb683355870dc8cc5a1f119f92f9a421565e049072a51542fe60497748f`。手机进程 PID 31278，当前视频 BV1xU4E6iE9y，CID 43406134202，3840×2160，时长 192354ms。

进度条最初用普通点击显示，控制条在 UI 树采集期间自动隐藏，未执行跳转。这是 CLI 的失败，已用诊断专属控制条保持命令解决。点击／拖动仍通过真实触摸和实际 ProgressBar 处理，未用播放器直接 seek 冒充触摸。

| 功能 | 实际结果 | 证据 |
| --- | --- | --- |
| BV／网址选择视频 | 通过，打开指定视频并回读 CID | s25u-cli-controls/open.json |
| 列表选视频 | 通过，选中可见《再飞行！》后 CID 变为 43375264631 | s25u-baseline/cli-select-video.json、cli-selected-status.json |
| 点击进度条 | 通过触发播放器，50% 对应约 96 秒；同时复现原有卡顿 | s25u-cli-controls/click50.json、after-click.json |
| 拖动进度条 | 通过触发播放器，25% 对应约 48 秒、70% 对应约 134.5 秒 | drag25.json、audiotrack-drag70.json |
| 暂停／继续 | 原生 pause 从 yes 切至 no | pause.json、play.json |
| 全屏进／出 | 回读 fullscreen 为 true／false | fullscreen-on.json、fullscreen-off.json |
| 倍速 | 回读 1.25 后恢复 1.0 | speed125.json、speed1.json |
| 小窗／恢复 | 系统任务 mode=pinned；launch 恢复 | pip.json、pip-window.txt、restore.json |
| 应用主页再退桌面 | 应用任务 visible=false、mode=fullscreen，无 pinned | app-home.json、phone-home.json、home-window.txt |
| 导出 | 当前 PID 的 native／flutter JSONL、设备信息和自身音频日志已拉到电脑 | baseline-export.zip、audiotrack-export.zip、aaudio-recheck-export.zip |

表中未写完整前缀的证据均在 `s25u-cli-controls/`。

## 同包单变量音频输出对照

同一手机、安装包、进程、视频、画质、playerId 19294717、sourceRevision 1，不修改同步、解码或 PiP；仅运行时切换 ao。切换期间系统音频焦点使播放器暂停过一次，因此先恢复播放，确认原生 pause=no 后，才执行有效点击对照。暂停状态的 audiotrack-click50.json 不用作连续播放结论。

| 条件／实际操作 | 第一次回读 | 后一次回读 | 结论 |
| --- | --- | --- | --- |
| AAudio 点击 50% | 96.133313s | 2.413s 后仍 96.133313s | 进度冻结复现 |
| AAudio 拖动 25% | 48.033313s | 6.903s 后 48.100000s | 进度接近停止 |
| AudioTrack 播放中拖动 70% | 135.166687s | 3.369s 后 138.533312s | 正常推进 |
| AudioTrack 播放中点击 50% | 96.966688s | 3.468s 后 100.433312s | 正常推进 |
| 切回 AAudio，播放中点击 50% | 96.233312s | 3.363s 后仍 96.233312s | 冻结再次复现 |

原始 JSON 的 native.current-ao 确认实际后端；native.pause=no、buffering=false。AAudio 复现后，native texture.consumed 最后一个媒体时间戳为 96000000000ns，之后没有持续帧；AudioTrack 跳转后纹理时间戳持续增长，Dart 的 uiPositionSeconds 也从 134 推进到 143。video-pts 在当前 mpv 返回空值，不作为结论依据。纹理监听不是物理屏幕显示围栏。

## 针对性修复

仅三星 SDK 36、音频候选列表包含 AAudio 时，把 AudioTrack 放到首位并移除 AAudio；三星其他 SDK、其他厂商和无 AAudio 的显式设置保持原值。设备厂商通过 JNI 读取一次，不增加每次打开视频的平台通道等待。此处修复是音频时钟选择，未改原生加速库、解码、取流或视频同步参数。

策略测试 3 项通过。修复监听 APK `PiliPlus-2.1.7+7-S25U-audio-clock-fix-listener-20261110.apk` SHA-256 `ed8491384cf181734f1236a923eded0076984506f5747f6c7b83d70521592d79` 已安装三星，新的 PID 5295、playerId 921839700 首次打开即选中 audiotrack，未临时切换后端。

CLI 点击 50% 后回读 97.166688s、pause=no。随后手机还发生了原始触摸（804.1992,479.31152 和 357.2754,553.0078），对应新跳转目标 152088ms、59366ms，因此这段不作为同条件计时对照；CLI 拖动因当时没有可见进度条而拒绝执行，不能记为通过。原始触摸、跳转和导出保留在 `s25u-audio-clock-fix/`。用户随后在手机上明确确认“修好了”，并要求提升版本号、提交、推送及打包 release。

起播耗时净收益未测，不把此次诊断结果当作性能成绩。用户指定发布版本为 2.2.0+8，替代此前 2.1.8+8。旧版本构建作废、不交付；最终包重新按 2.2.0+8 构建并核对。

正式 release 使用普通入口，不安装 Dart CLI 处理器；Android 的 SEEK_DIAGNOSTICS 构建常量为 false，控制桥分支由 R8 裁掉。详细跳转采样、导出入口只在 SEEK_RUNTIME_TRACE=true 的独立诊断入口启用。最终 APK 还须核对版本号、签名、libmpv 哈希和控制桥／诊断字符串是否移除。

## 2.2.0 正式包及安装

`output/releases/PiliPlus-2.2.0+8-arm64-release-20261110.apk` 已完成构建及 v2 签名验证。APK 中版本为 2.2.0-功耗修复、versionCode=8，SHA-256 为 `4c06cffc25e2910b7b5da4e807ee61956608b737056bdac42fdec54b1f1a6c39`。libmpv 哈希仍为 r116 的 `5d93acb683355870dc8cc5a1f119f92f9a421565e049072a51542fe60497748f`。

独立扫描 APK 的 DEX／libapp.so 确认原生 CLI 接收 action 和控制桥类、Dart CLI handler、详细 seek trace 及诊断导出文件名前缀均不存在；三星设备策略仍在。构建清单 diagnosticCollectionEnabled=false、seekDiagnostics=false。核对结果见 `release-2.2.0-verification.json`。

按用户追加要求，已通过 install -r 覆盖安装三星，未清除数据；手机实际安装 APK 的 sha256sum 与上述 APK 完全一致，系统读回 versionCode=8、versionName=2.2.0-功耗修复。启动 Activity 返回 ok，进程 PID=10084；手机当时前台为锁屏 Bouncer，不宣称已经显示应用界面。
