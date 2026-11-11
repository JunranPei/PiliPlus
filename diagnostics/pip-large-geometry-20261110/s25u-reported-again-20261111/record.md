# 三星 2.2.0 跳转故障再次排查

用户反馈正式版仍会跳转后画面和进度停住、声音继续。重新连接真机后读取包版本为 2.2.0-功耗修复、versionCode=8；当前进程 4945 的原始日志保存为 original-release-logcat.log，其中实际存在 AAudio 的启动、暂停、刷新、重建。

## 已确定的兼容缺口

上次真机记录 SDK=36；当前真机 ro.build.version.sdk=37，manufacturer=samsung，model=SM-S9380，ro.build.display.id=CP2A.260605.016.S9380ZHUDDZIF。版本不同的原因尚未核查，不推断用户做过什么操作。当前信息保存于 device.json 和本轮命令输出。

2.2.0 的 AndroidAudioOutputPolicy.apply 及纯策略函数都要求 sdk==36；SDK37直接返回 AAudio-first 列表。旧测试也明确要求 SDK37 保留 AAudio，因而此前通过的测试没有覆盖当前系统。已将两个判断改为 sdk>=36，覆盖三星当前系统，并在测试中要求 SDK37、38 去除 AAudio。其他厂商、SDK35和未包含AAudio的显式列表保持原行为。

此次只改兼容条件，不改原生库、视频同步、解码、取流、启动优化。监听状态额外提供设备SDK和 options/ao，结合 current-ao 验证实际选择。

## 执行

- 依赖缓存原有 Git 工作副本缺失，首次构建在读取 real.dart 时失败，未修改依赖或原生库；按锁文件恢复，pubspec.lock 未改。网络解析详细日志 pub-recover.log；离线检查 pub-offline.log。
- 初期 ADB 间歇失联中断控件树拉取和旧监听 APK 安装，没有取得有效跳转样本；用户重新连接后继续。
- policy-tests.log 中 3 项通过，含 SDK37、38；不代替真机回归。
- SDK37修复监听包已安装，SHA-256 a6552ba9bc9c938e4c5d0ac108086178fbd6288fe672083c716ae0d69ffe6827，原生库仍为5d93acb683355870dc8cc5a1f119f92f9a421565e049072a51542fe60497748f。安装后Activity重建导致最初控制桥未注册，force-stop完整启动后恢复回包；NO_PLAYER仅为当时主页未创建播放器。测试过程中不更换安装包。
- 用户追加要求换10个不同视频。已完成10个不同BV／CID的实际点击、拖动及进度、音频时钟、纹理核对，详情见 ten-video-results.md、ten-video-summary.json。9个视频持续推进；第2视频保留HTTP超时、seek失败及慢样本，不计全通过。第10视频小窗恢复后跳转通过。
- 第7视频首次点击的纹理采集提前停止，补测获得10个不同纹理PTS，缓冲结束后正常推进；原缺项保留。
- 新增正式包 PiliPlus-2.2.0+8-S25U-sdk37-release-20261111.apk，SHA-256 cb4a25fcc7b829c14092b78ec9a63753bdcd195bdd7cc5efa2e048aacd849178。检查Dart／native CLI及详细seek监听均移除，尚未安装；手机保留监听版继续追查第2视频。未提交／推送此次SDK37修正。
- 恢复缓存后还遇到未引用既有material_ui补丁和C盘满等构建失败，原始构建日志保留于对应build目录。Pub缓存完整迁至 tmp/pub-cache-20261111（42,686文件）；原路径连接解析异常，当前package_config和插件清单直接引用D盘，构建使用PUB_CACHE指向该目录，C盘恢复约4.2GB。没有改pubspec.lock。修复C盘旧缓存连接仍待检查，其他项目若复用旧路径需迁移引用。
- 起播性能未测，未宣称净收益。

| 操作 | 当前结果 |
| --- | --- |
| SDK37 新进程首次播放，读取后端 | 通过，配置与实际均为AudioTrack |
| 实际进度条点击／拖动，持续进度与纹理 | 10视频已测；9正常，1重复取流超时失败 |
| 换视频／返回再打开后重复跳转 | 已实际执行；失败样本保留 |
| 小窗进出后跳转 | 第10视频恢复后推进3320ms |

对照资料为上游 mpv-android 的 https://github.com/mpv-android/mpv-android/issues/1283 ，说明三星 Android16 AAudio 跳转同症状；当前 SDK37 仍须用本机监听确认，不能直接继承 SDK36 的结果。
