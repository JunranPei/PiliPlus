run `dart run tool/jnigen.dart`

## 保留播放提速的 Android release

使用 `D:/Python/python.exe tool/build_verified_release.py --output output/releases/<新文件名>.apk`。默认构建手机 ARM64 release；模拟器使用 `--target-platform android-x64 --benchmark`。

`tool/release_profile.json` 固定 r116 功能开关、媒体依赖补丁与两种架构的定制 libmpv 哈希。构建入口从已核验的本地基线包提取对应库，完成后恢复依赖并保存命令、源码快照和 APK 哈希。Gradle 会拒绝缺失提速开关或带入默认播放器库的 release。实验构建只有显式传入 `-PpiliStartupExperiment` 才可跳过该限制，不能作为正式交付。
