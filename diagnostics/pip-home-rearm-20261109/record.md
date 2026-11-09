# PiliPlus PiP 重复退主页与转场首帧记录

日期：2026-11-09（Asia/Tokyo）

## 复现输入

- 视频：`BV1TPWn6eE8n`
- 公开元数据：2560×1280、2:1、263 秒
- 设备：`emulator-5562`
- 观察方式：Android Activity/PiP 生命周期日志、SurfaceFlinger 层状态、UI 自动化树；未使用图像识别

## 修复前证据

1. 同一视频第一次退到主页时，原生日志出现：
   - `ui-transition`
   - `active`
   - Activity 窗口从 `1080x2400` 缩为 `598x336`
2. `PipCoordinator.onPictureInPictureModeChanged(false)` 将 `autoEnterRequested` 设为 `false`，退出 PiP 后没有重新设置 `setAutoEnterEnabled(true)`。这解释了同一视频第二次退主页变成后台播放；切换视频重新配置播放器后又能第一次进入 PiP。
3. Flutter `stream.playing` 事件早于现有稳定输出/首帧确认，原代码在该事件直接调用 `enterPip(autoEnter: true)`。2:1 视频在系统 PiP 转场开始时可能仍未提交可见纹理，因此画面在转场结束后才出现。

## 本轮修改

- `PipCoordinator`：退出 PiP 或恢复 Activity 后，若当前仍是 `/videoV` 或 `/liveRoom`、仍在播放且处于空闲阶段，重新设置自动进入参数；Home 路由不满足条件。
- `PlPlayerController`：移除 `stream.playing` 时的提前自动进入；在 `PlaybackStart.run` 完成稳定输出后异步配置自动进入，避免把首帧稳定等待加入播放调用的等待路径。

## 验证

- `:app:compileDebugKotlin -x :app:compileFlutterBuildDebug`：通过。
- `:app:testDebugUnitTest --tests com.personal.piliplus.PipRouteGuardTest -x :app:compileFlutterBuildDebug`：通过。
- Dart 格式化：通过，文件无格式改动。
- 完整 Flutter 单元测试构建：未完成；依赖编译阶段 Dart 进程内存耗尽，未产生测试结果。
- 第一次 x64 release 构建：未完成；在 CMake 多 ABI 阶段中断，旧 `build/app/outputs/apk/release/app-release.apk` 未作为本轮产物使用。随后用干净的临时 override 状态重跑成功，见下方产物记录。

## 真实回归结果

- x64 release 源包：`output/releases/PiliPlus-2.1.7+6-pip-rearm-stable-output-x64-20261109-r2.apk`
- 源包 SHA-256：`ffe509d86e0d37efb977f59f5f4ed72921770afe7d5d3c454a56113550415423`
- x64 `libmpv.so` SHA-256：`35e8847edc59d9cd4ac84ee3e47506929ed079d0b0cad62f41fa479981c8ee86`
- 由于模拟器已有 versionCode 7，生成了只改变 manifest versionCode 的安装副本：`output/releases/PiliPlus-2.1.7+6-pip-rearm-stable-output-x64-20261109-r2-version7.apk`；未卸载应用，保留测试数据。
- 设备：`emulator-5562`，AVD：`PiliPlusStartupIsolated_20261018`。
- 视频：`BV1TPWn6eE8n`。
- 第一次退主页：`ui-transition` → `active`，窗口缩为 `598x299`，进入 PiP。
- 返回应用后第二次退主页：再次出现 `ui-transition` → `active`，窗口缩为 `598x299`，仍进入 PiP；未出现后台播放。
