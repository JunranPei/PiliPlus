# PiliPlus Android 4K 播放功耗优化与黑屏修复说明文档

本项目在针对 Android 端进行包名重构以及 4K 视频播放功耗优化时，遇到了两个核心问题。以下为问题的根源分析与技术解决方案记录。

---

## 一、 Android 4K 播放功耗过高且波动剧烈问题

### 1. 问题根源
1. **AV1 格式的 CPU 软解回落（主要功耗源）**：
   * B站的 4K 视频流主要采用 **HEVC (H.265)** 和 **AV1** 两种编码格式进行分发。
   * PiliPlus 原有的默认解码器配置中，首选解码为 `AVC (H.264)`，次选解码为 `AV1`。
   * 当用户尝试播放 4K 视频时，由于 B站不提供 H.264 4K 流，播放器自动向服务器请求备选的 **AV1** 视频流。
   * 绝大多数中低端及前两代旗舰手机的 CPU **不支持 AV1 格式的硬件解码**。因此播放器会默默回落到 **CPU 软件解码**。
   * 4K AV1 的软件解码在播放时会瞬间榨干 CPU 的多个核心，导致手机严重发热、电量急剧消耗，且由于网络分片下载与关键帧渲染频率的不一致，功耗上下起伏剧烈波动。
2. **`hwdec` 选项在底层被覆盖**：
   * 原生 `media_kit_video` 的 `AndroidVideoController` 在建立链接后，会强制使用自身传入的配置去覆盖我们在 `Player` 初始化阶段注入 of `opt` 选项。
   * 如果用户本地有旧版本残留的 `auto-safe` 设置，会被底层识别并可能协商到性能较差、具有高内存拷贝开销的 `mediacodec-copy` 拷贝模式。

### 2. 解决方案
1. **修改默认解码器优先级**：
   * 在 [storage_pref.dart](file:///D:/workplace/antigravity/PiliPlus/lib/utils/storage_pref.dart) 中，将首选解码器修改为 **`HEVC` (H.265)**，次选修改为 `AVC` (H.264)。
   * **效果**：确保 4K 视频播放时一定会向 B站服务器请求支持极其广泛、硬件解码率达 100% 的 **HEVC** 流，绝不拉取 AV1 流，彻底走 GPU 硬件加速通道。
2. **强制穿透硬解设置（Mediadec 零拷贝）**：
   * 在 [controller.dart](file:///D:/workplace/antigravity/PiliPlus/lib/plugin/pl_player/controller.dart) 的 `VideoController.create` 配置中，将 `hwdec` 属性硬编码为 `Platform.isAndroid ? 'mediacodec' : hwdec`。
   * **效果**：穿透原生 controller 的配置覆盖，强制启用 `mediacodec` 直通零拷贝硬解，最大程度释放 CPU 压力。
3. **注入 `profile=fast` 渲染预设**：
   * 在 `Player` 初始化选项中加入 `'profile': 'fast'`。
   * **效果**：将 GPU 的高阶插值渲染算法降低为普通的 `Bilinear` 双线性过滤缩放，大幅削减手机 GPU 在进行 4K 画面渲染时的发热与耗电。
4. **视频同步与缓存优化**：
   * 将默认视频同步 `videoSync` 从 `display-resample` 调整为 `audio`，避免高刷屏下因强行插值重绘导致的 GPU 额外开销。
   * 开启合理的缓存大小（16秒缓存上限）防止频繁网络 I/O 导致电力损耗。

---

## 二、 包名重构后启动直接黑屏崩溃问题

### 1. 问题根源
1. **JNI 生成绑定的类路径失效**：
   * 之前的包名重构中，仅将包名修改为了 `com.personal.piliplus`，并移动了 `MainActivity.kt` 的文件路径，而原生 `src/main/java/` 下的 `AndroidHelper.java` 和 `MediaHelper.java` 仍留在旧包名路径下。
   * 在移动并更正 Java 文件路径后，编译虽然通过，但 Flutter 端通过 `jnigen` 生成的 [bindings.g.dart](file:///D:/workplace/antigravity/PiliPlus/lib/utils/android/bindings.g.dart) JNI 调用代码依然硬编码着 `com/example/piliplus/AndroidHelper` 类路径。
   * 这导致应用在冷启动时，Dart 端尝试通过 JNI 反射加载 Java 类，由于类不存在直接报 `ClassNotFoundException`，进而引发应用闪退/黑屏。

### 2. 解决方案
1. **同步修改 JNI 绑定定义**：
   * 在 [bindings.g.dart](file:///D:/workplace/antigravity/PiliPlus/lib/utils/android/bindings.g.dart) 中，将所有的 `com/example/piliplus/AndroidHelper` 和 `com/example/piliplus/AndroidHelper$ToDart` 类路径引用更新为最新的新包名类路径 `com/personal/piliplus/AndroidHelper`。
2. **更正前台音频服务通道**：
   * 在 [audio_handler.dart](file:///D:/workplace/antigravity/PiliPlus/lib/services/audio_handler.dart) 中，将 `androidNotificationChannelId` 同步更新为新包名下的 `'com.personal.piliplus.audio'`。

---

## 三、 代码修改涉及文件列表
* **硬解选项优化**：[controller.dart](file:///D:/workplace/antigravity/PiliPlus/lib/plugin/pl_player/controller.dart)
* **默认优先级与缓存调整**：[storage_pref.dart](file:///D:/workplace/antigravity/PiliPlus/lib/utils/storage_pref.dart)
* **JNI 反射路径更正**：[bindings.g.dart](file:///D:/workplace/antigravity/PiliPlus/lib/utils/android/bindings.g.dart)
* **通知通道名更正**：[audio_handler.dart](file:///D:/workplace/antigravity/PiliPlus/lib/services/audio_handler.dart)
* **辅助类包路径更正**：
  * [AndroidHelper.java](file:///D:/workplace/antigravity/PiliPlus/android/app/src/main/java/com/personal/piliplus/AndroidHelper.java)
  * [MediaHelper.java](file:///D:/workplace/antigravity/PiliPlus/android/app/src/main/java/com/personal/piliplus/MediaHelper.java)
