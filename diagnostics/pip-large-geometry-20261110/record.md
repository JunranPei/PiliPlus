# PiP 大窗几何修复记录（2026-11-10）

## 修改

- `PipRenderHost` 将 PiP 缩放从 `min(width/sourceWidth, height/sourceHeight)` 改为覆盖比例 `max(...)`。源视频矩形仍由 `clipBounds` 限定，避免宿主纵横比变化时由黑色宿主背景形成上方黑条。
- Android 12 及以上的 `onUserLeaveHint` 在已有源矩形时立即锁定 Flutter 画布，并把同一矩形交给 PiP 过场；`uiStateChanged` 仍保留为迟到回调的兜底，避免图标先于画面。
- `PipRenderHost` 的锁定、布局和释放事件增加轻量 `PiliPlusPiPTrace` 日志。只记录尺寸、缩放、平移和裁剪，不读像素、不截图、不触发重绘。
- `pubspec.yaml` 版本提升为 `2.1.7+7`。本机 `android/local.properties` 的缓存 `flutter.versionCode` 同步为 `7`，否则 Flutter Gradle 插件仍会生成 versionCode 6。

## 监听验证

目标设备：`emulator-5562`，AVD `PiliPlusStartupIsolated_20261018`，系统启动完成，分辨率 `1080×2400`。

- 小 PiP 第一次：窗口状态 `mode=pinned`，`mBounds=Rect(440, 1527 - 1038, 1863)`，应用日志依次出现 `entering generation=1`、`active generation=2`，宿主布局 `598×336`，`scale=0.5537037`，源裁剪 `Rect(0, 63 - 1080, 670)`。
- 小 PiP 第二次：同一安装包重新回到应用后再次 Home，窗口仍为 `mode=pinned`、同一 `598×336`，日志依次出现 `entering generation=4`、`active generation=5`，宿主缩放和裁剪与第一次一致。
- 两次均未出现只显示图标而没有进入 PiP 的状态；日志和 `dumpsys activity` 均由监听取得，未使用图像识别。
- 早先的六次自动脚本在第 2 条等待 PiP 时超时；该条没有完整的播放/路由前置证据，未计入结果。随后改为等待播放后再采集的两次监听路径，才作为有效结果。
- 该 AVD 的双击 PiP 手势没有触发尺寸变化，因此没有把“大 PiP 已在 AVD 实际展开”的结论写入记录。非等比大宿主 `700×300` 的覆盖几何由 `PipRenderHostTest.expandedHostUsesCoverScaleAndNeverLeavesTopLetterbox` 覆盖。

## 测试

- `:app:testDebugUnitTest --tests com.personal.piliplus.PipRenderHostTest --tests com.personal.piliplus.PipRouteGuardTest`：488 个任务成功，目标测试全部通过。
- 首次原生编译曾因删掉仍被恢复逻辑使用的 `min` 导入失败；补回后 `:app:compileDebugKotlin` 成功。该失败不进入最终通过项。

## 包

- x64 AVD 验证包：`output/releases/PiliPlus-2.1.7+7-pip-large-geometry-x64-20261110-v3.apk`
- x64 包 SHA-256：`9e5f39443c2da14a21abc607d82a008d2742395f21ba3b3c2d54aa553148464d`。
- ARM64 手机包：`output/releases/PiliPlus-2.1.7+7-pip-large-geometry-arm64-20261110-v1.apk`。
- ARM64 包 SHA-256：`4b94b255d556110c761f6474f970ef7abdcd351e8b075e3a3b283000c9a32d4e`；两包均使用 versionCode 7。
