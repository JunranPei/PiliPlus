# PiliPlus Android PiP 落定后跳动记录

- 记录日期：2026-10-02
- 分支：`pip`
- 应用：`com.personal.piliplus`
- 设备：`emulator-5554`，Android API 36，Medium_Phone AVD
- 播放器：`media_kit` Flutter Texture
- 现象阶段：进入 PiP 后窗口已经落定，约 1–2 秒后出现一次画面跳动。

## 已确认的视觉现象

PiP 小窗的外框已经固定，视频内容却短暂以左上角为原点放大并裁切：

- 顶部出现一条黑色区域；
- 右侧人物只剩半边，画面被截掉；
- 随后画面恢复为完整的 16:9 视频。

![完整异常帧](pip-settled-jump-glitch-full.png)

上图是原始全屏截图，异常 PiP 位于右下角。下面是同一帧的 PiP 局部裁剪，专门用于后续对比：

![PiP 异常局部](pip-settled-jump-glitch-crop.png)

证据文件：

- 原始录屏：`..\\.codex-pip-entry-current2.mp4`
- 原始帧：`pip-settled-jump-glitch-full.png`（来自录屏抽帧 `old-06.png`）
- 局部帧：`pip-settled-jump-glitch-crop.png`
- 联系表：`old-detail.png` 只能用于辅助定位，不能把左上角的全屏帧当作 PiP 证据。

## 时序证据

该录屏在发送 Home 手势前已开始录制。原生日志记录：

```text
11:00:21.832 phase=entering generation=28 reason=ui-transition
11:00:22.855 phase=active generation=29 reason=mode-changed
```

录屏中前几帧是正常的 PiP 画面；约在 `1.1 s` 的抽帧出现异常放大/裁切。因此问题不只是“进入动画还没完成”，而是 PiP 已经进入 `active` 后仍发生了第二次显示变换。

用户对证据的修正：联系表左上角第一张是误截到的非目标帧，不能作为结论依据。

## 用户补充的两条复现路径

这不是一个可以合并描述的现象，必须分别验证：

### 路径一：直接上滑回桌面

正在播放的页面直接随手势缩成 PiP。画面在转场中以极快速度变形并闪一下，随后通常落定。此前用 `KEYCODE_HOME` 做的录屏对应这条路径；它可以捕获“落定瞬间”的短暂异常，但不能证明第二条路径已经解决。

### 路径二：先进入最近任务，再点空白进入桌面

上滑进入最近任务页面后，点击任意空白区域进入桌面，PiP 会直接显现，几乎没有转场变形；但视频会持续以左上角为原点放大裁切，而不是只闪一下。用户提供的原始证据如下：

![路径二：持续左上角放大裁切](user-case2-persistent-top-left-crop.png)

该原图已保存为 `user-case2-persistent-top-left-crop.png`。后续录屏和日志必须标记 `direct-home` 或 `recents-then-desktop`，不能把两种入口混为一次通过。

## 当前实现中需要重点检查的地方

1. `PipCoordinator` 在 Android 12+ 先收到 `onPictureInPictureUiStateChanged(entering)`，随后收到 `onPictureInPictureModeChanged(active)`。
2. `AndroidPipViewport` 保留同一个页面和 Texture，但原实现只在 `active` 阶段套用 Transform/Crop。
3. Android 可能先把 Activity 的约束缩到 PiP，再异步把 phase 回调送到 Dart；这会造成首个小窗口帧仍按整页/左上角布局绘制。
4. 如果首个小窗口帧已正确，随后 `active` 再套一次 Transform/Crop，就可能出现“外框不动、内容再次放大裁切”的第二次跳变。
5. 退出阶段曾观察到临时的 `sourceRect=Rect(1, 0 - 597, 336)`；此类 PiP 尺寸矩形不能写回下一次全屏的 `sourceRectHint`。

### 2026-10-02 新发现：状态回调出现反向顺序

`20261002-223208-574-Home-after.log` 记录到一段不应出现的状态回退：

```text
14:21:52.955 phase=active generation=7 reason=mode-changed
14:21:53.148 phase=entering generation=8 reason=ui-transition
```

也就是已经收到 `onPictureInPictureModeChanged(true)` 进入 `active` 后，延迟到达的 `onPictureInPictureUiStateChanged(transitioningToPip=true)` 又把状态改回 `entering`。这会让 Dart 的 `PipViewport` 再次收到状态变化并重新计算保护/裁剪几何，和“窗口外框不动、内容再次跳动或持续裁切”相符。状态机应保持单调 `idle → entering → active`；`ui-transition` 到达时若当前已经是 `active`，必须忽略，不能回退。

同一时间段的旧记录 `pip-research-20260910/*-Home-after.log` 没有这种 `active → entering` 顺序，说明它不是 Android 固有的正常顺序，而是当前 S+ `onUserLeaveHint` 提前设为 `entering` 后引入的竞态候选。

## 当前修复方向（暂未证明解决）

- 在 Dart 收到 phase 回调之前，依据窗口从全屏骤缩到 PiP 尺寸的事实识别一次 PiP resize，保留进入前的 MediaQuery/source layout。
- 只有在窗口同时显著小于原始宽高时才套视频裁剪，避免把状态栏/insets 的小变化误判成 PiP。
- `active` 回调到达后不得再次改变已经正确显示的视频几何位置。
- 继续保持同一个播放器、同一个 Texture 和同一棵页面树，不创建第二个解码器或第二个 PiP 页面。

## 验收标准

- 进入后持续录制至少 4 秒；
- 小窗外框固定后 1–2 秒内，视频始终完整、比例稳定、没有左上角放大裁切或黑色顶部跳变；
- 日志中 `active` 前后不再出现第二次视频几何切换；
- 退出再进入时不发送 PiP 尺寸的临时 `sourceRect`；
- Flutter PiP widget tests、Flutter analyze、Debug APK 构建通过，并重新安装到 `emulator-5554` 后复测。

## 2026-10-02 中间版本验证（不能作为解决证明）

- `test/pip_viewport_test.dart`：2 个测试通过；覆盖了 Android 先缩小窗口、后到达 `active` 回调的时序。
- Flutter analyze：通过。
- Debug APK：构建成功并安装到 `emulator-5554`。
- 真实录屏：`20261002-214857-997-Home.mp4`，持续约 4.3 秒；日志只有一次 `entering` 和一次 `active`：

```text
13:48:41.076 phase=entering generation=1 reason=ui-transition
13:48:42.161 phase=active generation=2 reason=mode-changed
```

本次录屏的落定帧 `current-frames/frame-04.png` 至 `frame-09.png` 未看到旧证据中的“左上角放大、右侧被截掉、顶部黑条随后跳变”。这只能说明该次真实录屏未复现，不能证明两条入口路径都已解决；用户随后确认第二条路径仍会持续左上角放大裁切。录屏由后台无窗口模拟器产生：模拟器进程使用 `-no-window`，截图和录屏均来自 `emulator-5554` 的 ADB 输出，不是桌面上另一个可见模拟器窗口。

## 其他开发者的处理方式

检索了开源播放器、Flutter PiP 插件和实际问题报告后，能重复看到的处理模式不是继续给整页 Flutter 页面叠加缩放/裁切，而是把 PiP 内容边界收窄到一个连续的原生视频 surface：

1. **PiP 只承载视频 surface，控制层移出 PiP。** `flutter-native-video-player` 使用原生 ExoPlayer/AVPlayer，并在 PiP 或全屏时回退到原生 platform view；它明确把 PiP 限定为视频 surface，隐藏 Flutter 叠加层。这个结构避免了 PiP 窗口缩小时整棵 Flutter 页面按左上角重新排版。参考：[flutter-native-video-player](https://github.com/plug-and-pay/flutter-native-video-player)。
2. **保留同一个 Surface/解码器，不在生命周期回调里重建。** Android PiP 的回调顺序由 SystemUI 和 WindowManager 异步协调；SurfaceView 的连续性比在 `onStop`、`surfaceChanged` 或 `active` 回调中重建播放器更重要。参考：[Android PiP 生命周期与 SurfaceView 分析](https://xckevin.github.io/en/blog/android-picture-in-picture-pip/)、[ExoPlayer SurfaceView 闪烁问题](https://github.com/google/ExoPlayer/issues/8611)。
3. **等真实窗口尺寸变化，再更新 surface 布局。** VLC 在视频 surface 容器上监听 layout change，并在布局完成后重新安排视频 surface；腾讯 RTC 的 PiP 示例也在 `onPictureInPictureModeChanged` 中重新设置视频 view 的宽高。参考：[VLC VideoHelper.java](https://github.com/videolan/vlc-android/blob/master/libvlc/src/org/videolan/libvlc/VideoHelper.java)、[腾讯 RTC PiP 文档](https://trtc.io/document/74577)。
4. **把 `sourceRectHint` 当作系统动画提示，而不是最终画面变换。** 开源 Flutter 示例通常同时设置 source rect、视频宽高比和 `seamlessResizeEnabled`，但仍用原生回调/外部状态监视器判断是否真的进入 PiP；调用成功不等于窗口已经落定。参考：[Agora Flutter PiP 示例](https://github.com/AgoraIO-Extensions/Agora-Flutter-SDK/blob/main/example/lib/examples/advanced/picture_in_picture/picture_in_picture.dart)、[opentraa/pip](https://github.com/opentraa/pip)。
5. **不要把不同入口当成同一种时序。** 直接回桌面会经过系统 PiP 动画，容易出现一次性的错误几何帧；最近任务再点桌面可能跳过或改变动画阶段，错误的全页布局就会持续留下。ExoPlayer 也有“先未缩放、数秒后才调整”的记录，说明不能只用 `active` 回调作为“最终尺寸已经提交”的标志。参考：[ExoPlayer 初始未缩放/延迟调整问题](https://github.com/google/ExoPlayer/issues/5557)。

### 对 PiliPlus 的结论

当前 `AndroidPipViewport` 仍在 Dart 侧保存整页 MediaQuery，并对整棵页面使用 `Transform`、`OverflowBox` 和裁剪矩形。这可以遮住一部分时序问题，但不能保证第二条入口路径不会留下“全页按左上角排版”的状态。更稳妥的改法是：让原生播放器 surface 成为 PiP 的唯一内容，Flutter 页面只负责控制；如果暂时不迁移，则至少停止用整页 Transform 作为最终 PiP 几何，改由原生 surface 的 layout listener 在实际小窗尺寸到达后更新，并把 `sourceRectHint` 只用于系统转场提示。

## 2026-10-03 architecture-v2 verification

- Baseline commit: `5091b9353` (`fix(pip): stabilize auto-enter and texture surface timing`).
- Architecture-v1 commit: `3922fce3e` (`refactor(pip): keep native video surface in PiP`). It removed Flutter-side Transform/Crop, but the emulator evidence showed a roughly 0.9-second black PiP frame after settling (`arch-v1-frames/frame-034..043`).
- Architecture-v2 commit: `b3a254d3e` (`fix(pip): avoid remounting video surface`). `PLVideoPlayer` now remains in the original page tree and retains the same media_kit Texture; after native `active`, only the Flutter control layers are omitted. No page-level PiP subtree is mounted.
- Direct home evidence: `arch-v2-home-100ms.png`, `arch-v2-home-500ms.png`, `arch-v2-home-1300ms.png`, `arch-v2-home-3300ms.png`. The 500 ms, 1.3 s and 3.3 s frames show continuous video with no black interval.
- Recent-apps-then-desktop evidence: `arch-v2-recents.png`, `arch-v2-recents-home-100ms.png`, `arch-v2-recents-home-500ms.png`, `arch-v2-recents-home-1300ms.png`, `arch-v2-recents-home-3300ms.png`. The PiP video remains continuous through the handoff.
- The final debug APK was installed on `emulator-5554`; manual verification is still required for the exact physical swipe gesture.

> The older conclusion above describes the pre-v1 Transform/Crop implementation. It is superseded for the current code by the architecture-v2 entry below.

## 2026-10-03 Surface resize patch and current evidence

用户随后确认：两条入口都仍有黑屏闪烁，原来的放大裁切位置变成了黑帧。这个反馈说明只保持 Flutter widget 树还不够，必须同时避免旧版 `media_kit_video 1.2.5` 在 Android SurfaceTexture 重建期间发布 `Rect.zero`。

已提交两层修复：

- `9f09c3b08`：`PipSimpleVideo` 保留最后一个有效矩形；`PLVideoPlayer` 在 PiP 时保留原来的 `Stack` 和同一个 Texture 父节点。
- `af1720a9d`：把项目使用的 `media_kit_video 1.2.5` 固定到 `third_party/media_kit_video`，在 `android_video_controller/real.dart` 中不再先写 `Rect.zero`，只在 SurfaceTexture 尺寸更新完成后提交最终矩形。这样与上游后来采用的“保持连续 Surface、等真实尺寸更新”处理方向一致，同时不触发本项目无法承受的整套 media_kit API 升级。

当前版本验证：

- `flutter analyze --no-pub`（PiP 相关文件）通过。
- `flutter test --no-pub test/pip_viewport_test.dart`：2 个测试通过。
- Debug APK 构建通过并安装到 `emulator-5554`。
- 直达桌面录屏：`vendor-direct2/`，日志为一次 `entering` 后一次 `active`；抽帧中 PiP 保持正常视频，未出现持续左上角裁切。
- 最近任务再点空白：`vendor-recents.png` → `vendor-recents-desktop-001.png` 至 `003.png`；窗口落到桌面后视频仍保持正常比例和连续画面。

这些 ADB 抽帧不能替代用户肉眼对真实上滑手势的判断；用户报告的亚帧级黑闪仍按未完全验收处理，后续复测必须继续分别记录 `direct-home` 和 `recents-then-desktop`。
