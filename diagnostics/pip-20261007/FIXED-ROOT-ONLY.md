# 恢复调查前播放器，只保留原尺寸画面缩放

用户要求：全面回退到本轮 PiP 修复调查前，再应用全程缩放原尺寸方案，
废除其他实验。

恢复基线：`0299be56f`，调查开始前保存的现有播放器快照。
固定画布实现来源：`d0b40bfce` 的 PipRenderHost 与配套 PiP 状态同步。
失败实验只保留在历史归档分支 `codex/archive-pip-experiments-20261007`。

## 当前活动代码

- 普通播放的 controller、封面与路由回退处理、音频服务、应用根构建恢复为基线。
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

普通播放关键文件和依赖通过与 0299be56f 的 Git 差异检查；固定画布原生
实现与 d0b40bfce 相同。原实现曾被用户验收，但移植到调查前播放器后仍需
用户确认实际效果，不能沿用此前验收作为本次成功证明。

工具链目录名为 Flutter 3.44.2，实际版本为 3.44.4。重新生成依赖配置时
临时匹配该工具版本，并在 finally 中恢复原 pubspec；使用 offline 与
enforce-lockfile，未升级任何播放器或其他依赖。

验证入口：Flutter viewport/sourceRect 测试与 Android Pip 布局测试。
安装采用 adb install -r，不清除应用数据，不截图或录屏。
