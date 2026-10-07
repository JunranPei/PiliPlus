# 普通播放的换源与画面交接（2026-10-07）

## 范围与基线

基线为 `bacab3022`，它在 `b4b0f1fae` 的封面占位版本上保留全程原尺寸 PiP。
本轮修复普通播放、打开另一视频、返回上一视频、画质切换的请求与显示顺序。
没有恢复此前的小尺寸 PiP 实验，没有替换弹幕、字幕、控制条、手势和播放器内核。

用户已经确认的问题包括：离开前闪当前封面、返回时黑屏、点击后封面扩大、先出声后出画面。
这些是输入事实；自动检查与日志不能替代用户对闪烁和流畅度的验收。

## 已定位的竞态

1. `didPushNext` 在离开动画开始时就把 `videoState` 清为 false，旧页面尚可见时换成封面。
2. 原 `plPlayer` 把自动播放、初始化状态与整个播放器挂载绑定；开播前存在两层拟合方式不同的封面。
3. `open` 完成后先触发播放，再通过 `onInit` 挂载界面，声音可能早于画面。
4. 多个页面共享播放器，但地址请求、换源回调和位置事件没有完整的所有者检查。
5. `player.open(play:false)` 只证明命令执行，不证明本视频已经输出；VideoController 的一次性首帧 future 不能重复用于换源。
6. Android 后端先以 `vo=null` 获取视频参数，再配置 SurfaceTexture 并启用 GPU；第一条播放重启事件不一定属于真实显示输出。

## 当前顺序

地址请求可以在路由动画期间进行。换用共享输出则等路由覆盖完成，避免新源进入尚可见的旧页面。

`PlaybackSourceQueue` 只串行化播放器换源；最新请求立即使旧请求失效，取消能释放首帧等待。
路由身份、每次准备的 revision、cid 和请求所有者共同拦住迟到回调。直播进入相同队列并补充路由取消检查。

`VideoPresentation` 保持 player 在固定槽位，用单一不透明封面遮盖准备状态。加载点击会保留播放意图。
离开页面保留当前画面，完全被遮住后卸下该页控件；NativePlayer/VideoController 仍由共享控制器持有。
从另一视频返回先显示本页封面；从设置等未换源页面返回保留同一资源状态。

每次普通视频加载：

1. 挂载播放器和 Texture，封面保持可见。
2. 用独立 mpv weak client 监听本次 `START_FILE → FILE_LOADED → PLAYBACK_RESTART`。
3. 必须确认匹配资源和实际 VO，排空事件；seek/输出重配会撤销过早的 restart。
4. 等待非零纹理尺寸；Android 的 rect 与当前视频显示尺寸必须一致。
5. 更新显示状态并等待前台 Flutter 提交该帧，再启动声音与播放。后台已经就绪的播放恢复不等待 Flutter 帧。

这个信号链仍不等于 Android 合成器的最终显示回执，因此不能仅根据日志断言绝对无闪烁。

## 流畅度取舍

- 保留单个共享播放器与视频控制器，避免双解码器的额外资源和交接复杂度。
- 网络准备与路由动画重叠；解码等待发生在需要保护旧画面的共享源切换点。
- 不引入固定等待时长、截图冻结、额外 crossfade 或 PiP 小尺寸切换。
- 首帧事件轮询间隔 16ms，仅在加载期间存在；完成、取消、失败均销毁 weak client。
- 30 秒首帧超时和 10 秒输出尺寸超时只处理失败，不作为正常路径延时。
- 加载中的播放点击合并为意图；后台通知恢复已有资源直接播放。

## 参考实现与采用边界

- [NewPipe VideoPlayerUi](https://github.com/TeamNewPipe/NewPipe/blob/dev/app/src/main/java/org/schabi/newpipe/player/ui/VideoPlayerUi.java)：使用首帧事件撤去遮挡。
- [NewPipe VideoDetailFragment](https://github.com/TeamNewPipe/NewPipe/blob/dev/app/src/main/java/org/schabi/newpipe/fragments/detail/VideoDetailFragment.java)：返回历史详情与重新播放分离。
- [NextPlayer PlayerContentFrame](https://github.com/anilbeesetti/nextplayer/blob/f50a5d5fe300a7a9ca9e8cf5e504f795b4453a0b/feature/player/src/main/java/dev/anilbeesetti/nextplayer/feature/player/PlayerContentFrame.kt)：显示表面常驻，遮挡层独立。
- [Plezy PlayerBase](https://github.com/edde746/plezy/blob/main/lib/mpv/player/player_base.dart)：按资源身份过滤事件，用播放重启参与首次显示状态管理。
- [mpv UPDATE_VO](https://github.com/mpv-player/mpv/blob/v0.40.0/player/command.c#L7289)、[暂停状态下首帧处理](https://github.com/mpv-player/mpv/blob/v0.40.0/player/playloop.c#L1066)：输出重建与精确 seek 后产生新的 restart。

采用的是生命周期和事件交接方式，未直接移植这些项目的整个播放器。

## 检查与诊断

- 队列测试覆盖取消、连续替换、旧所有者取消、失败后继续工作。
- 首帧协议测试覆盖旧源、同 URI 重开、旧结束事件、输出重配、空 VO、seek 与新 restart。
- 展示组件测试检查 player 状态不重建、尺寸不变、加载时接收播放点击、隐藏封面后点击穿透。
- PiP viewport/source rect 既有测试用于防止误改边界。
- `[PLAYBACK]` 记录请求、cid、纹理和尺寸；`[PLAYBACK_FRAME]` 记录 gate/entry、VO、重配与 restart；`[PLAYBACK_UI]` 记录挂载、显示、播放及耗时。
- 不截屏、不录屏。实际设备检查记录在本轮 diagnostics 中；未完成人工视觉验收前不标记无闪烁。
