# 恢复封面占位版本，只保留原尺寸画面缩放

用户要求：全面回退到本轮 PiP 修复调查前，再应用全程缩放原尺寸方案，
废除其他实验。

恢复基线：`b4b0f1faed0f436a53a665236fa2e73664596149`，2026-06-25 的
`Optimize video transition: replace screenshot with cover image placeholder and restore play position`。
用户明确指定的是“回退上个视频后用封面占位”这一版。
此前误选的 `0299be56f` 是在此基础上又加入其他实验的存档，不符合该要求。
固定画布实现来源：`d0b40bfce` 的 PipRenderHost 与配套 PiP 状态同步。
失败实验只保留在历史归档分支 `codex/archive-pip-experiments-20261007`。

## 当前活动代码

- main、audio_session、service_locator、play_settings、视频详情 controller
  与基线一致。播放器 controller 保留 PiP 状态桥接，普通 open/play/pause、
  双击播放、解码参数恢复基线；删除后台 30 秒后的 video-reload 实验。
- 封面占位与返回上个视频的进度恢复使用基线代码。didPushNext 仅在实际
  PiP active 时跳过暂停，不能用 entering/pending/布局冻结扩大这一判断。
- MainActivity 恢复基线 onDestroy 的音频服务停止行为，保留 PiP 清理。
- pubspec.yaml/lock 恢复基线。media_kit_video 再次引用锁定的 Git 版本
  deac6b62569584b6a5e28e6c60c187a0a7281b3a，缓存源码与该提交一致。
- 删除实验性 vendored media_kit_video、原生视频输出迁移、SurfaceProducer
  改造、C++ 缓冲尺寸修改、ImageReader、自建 SurfaceControl 图层、隐藏标记、
  小尺寸缓冲交接以及应用根 PipFrameRoot。
- PiP 从进入到返回保留 Flutter 原尺寸画布，由 PipRenderHost 缩放/裁切视频
  区域。只有正常窗口与系统边距恢复后才释放布局冻结。
- 在原播放器 SimpleVideo 外增加无画面复制的尺寸观察器，提供真实视频
  sourceRect；不更换 Texture、解码器、播放器或音频路径。
- 视频页进入 PiP 时不切换为全屏布局，以保持原视频区域不变。
- 稳定普通播放阶段原样传递 MediaQuery，不把 route constraints 改成屏幕
  尺寸；原生锁定及进入/退出阶段继续使用固定画布保护。包装树保持不变。

普通播放关键文件和依赖以 b4b0f1fae 做 Git 差异检查，不能再用 0299be56f
作为“原版”参照。固定画布 PipRenderHost/PipCoordinator 原生实现保留当前
版本，与 d0b40bfce 相同；普通模式仍有宿主容器和 PiP 测量观察器，不能
声称整个视图结构与基线逐字相同。

用户已验收 c32532a24 的 PiP 正常，同时报告该包普通播放不正常。因此
本次修正基线；新组合的普通播放和 PiP 仍需实际验收，自动检查不能替代。

工具链目录名为 Flutter 3.44.2，实际版本为 3.44.4。重新生成依赖配置时
临时匹配该工具版本，并在 finally 中恢复原 pubspec；使用 offline 与
enforce-lockfile，未升级任何播放器或其他依赖。

验证入口：Flutter viewport/sourceRect 测试与 Android Pip 布局测试。
安装采用 adb install -r，不清除应用数据，不截图或录屏。

本次静态分析无问题；Flutter 10 项、Android 5 项测试通过。另逐方法比较
确认 play/pause/onDoubleTapCenter/didPopNext 与 b4b0f1fae 一致（忽略空白）。
新包为 cover-baseline-fixed-root.apk。首次安装因空间不足失败，调用系统
pm trim-caches 清理可回收缓存后安装成功，保留用户数据和已安装应用。
精确 APK 哈希与安装状态保存在 cover-baseline-build.json / current-build.json。
