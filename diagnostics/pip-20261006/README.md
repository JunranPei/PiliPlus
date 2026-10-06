# PiP 固定根画布修复与逐帧诊断

当前方案保留 Flutter 根缓冲区的正常尺寸，由 Android `PipRenderHost` 将视频区域缩放、裁切到 PiP 窗口。用户已确认直接上滑、最近任务入口和返回播放页三种情况正常。详细历史及验收在 `../pip-20261002/pip-settled-jump.md`。

本目录提交问题分析、采集配置和选定的合成状态证据。原始 pftrace、完整日志、下载的解析器、APK、缓存及源码备份只保留在本地，不进入 Git；历史文档中的这些本地路径不表示仓库包含对应文件。

`pip-frame-listener.pbtxt` 是 4 秒采集验证配置；`pip-frame-listener-live.pbtxt` 是最多 180 秒 / 128 MiB 的手工测试配置。它们使用 SurfaceFlinger 连续图层、缓冲变化、实际帧时序、WindowManager 和转场元数据，不捕获像素图像。采集有额外开销，不能把其耗时当作原 bug 的耗时。配置依据 [AOSP 图层追踪文档](https://source.android.com/docs/core/graphics/winscope/capture/adb)。

工具入口：

- `tool/pip_pull_logs.py <输出目录>`：只读取应用私有 Flutter / mpv 日志，校验序号。
- `tool/pip_trace.py <文本日志或JSONL> <输出目录>`：重组分段记录并报告损坏、缺段。
- `tool/pip_layer_trace.py <pftrace> <输出目录> --processor <trace_processor_shell路径>`：导出实际缓冲尺寸、帧号、原始变换/裁切和父图层。解析器使用 [Perfetto 官方版本](https://perfetto.dev/docs/analysis/trace-processor)，不随本仓库提交。

`entry-buffer-handoff-analysis.md` 中的状态可由 `handoff-parent-evidence.json` 逐层检查。这里的 frameNumber 是系统缓冲队列帧号，不是视频文件中的解码帧号；相同帧号可以在多个合成时点重复显示。源材料确认了同一大缓冲在缩放取消后仍被显示的间隔，不能据此宣称单张快照或所有入口已被系统数据完整覆盖。

验证：5 项 Android 原生布局/异常隔离单测、4 项 Flutter viewport 测试通过，相关 Dart 静态检查通过。原生单测运行 `:app:testDebugUnitTest --tests 'com.personal.piliplus.Pip*Test'`；Flutter 测试运行 `flutter test --no-pub test/pip_viewport_test.dart`。功耗尚未测量，小尺寸缓冲区同步交接是后续优化，不应覆盖已验收基线。
