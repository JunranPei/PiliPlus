# 旧 mpv 版本移植待命：当前状态

已先保存新版待命提交fca5f2aa1，再在codex/mpv-old-output-standby分支重建旧运行版本（2bdf889aa）并移植待命（2fd859459）。两个新APK均已编译，尚未完成视频画面对照，不能声称比旧版更快。

## 已完成

- 从原始会话恢复e79之后的请求并行、选轨补全及阶段诊断改动，见provenance.md和三份原始补丁。旧mediacodec_embed、立即附着Surface、自动播放及封面流程保持。
- 移植启动时创建一个空Player/VideoController、准备配置指定的输出、首次点击一次性接管的机制。没有真实媒体或假片段预播，不重新引入Media3或并行转发。
- Dart检查无告警；恢复的8项选轨检查全部通过。对比确认视频输出配置、视频页面、画质菜单、HTTP取流代码未因待命移植改变。
- 相同源码和依赖内容下顺序构建开关关闭/开启两包，唯一定义差异是PLAYER_STANDBY=false/true。mpv与Flutter引擎二进制均与历史09213586…APK中的x86_64版本一致。

| 包 | SHA-256 |
|---|---|
| 待命关闭 | bc6e2951df05d06a27bd002230e9bc18cab9f77e51aecb12827549857e023aa1 |
| 待命开启 | 32290cf8c85c8d02a47ac244198663a38b7fabd3a520f83d8234296bbe168f46 |

## 已测范围

有效视频录制0条、不同视频0个；首页机制检查2条（关闭/开启各1）。第一条视频对照在进入录制前被内存门槛拒绝，不计为播放样本；未产生画面耗时或卡顿结论。

待命首页日志：PLAYER_STANDBY begin到ready约118.632ms；输出准备约10.484ms，currentVo=mediacodec_embed、configured=yes、mediaCount=0、playing=false、videoCodec为空。原生日志未创建CCodec/MediaCodec解码器。尚未通过实际视频证明接管和画面收益。

两次首页截图均可使用。空闲PSS分别87689/158149KiB，SWAP PSS分别55617/549KiB；交换内存差异大，不能将PSS差额解释为净待命开销。ActivityLaunch记录是内部指标，不是视频真实画面。

## 暂停录制的具体原因

本任务编译完成并清理自己的Gradle后台进程后，仅启动了一个PiliPlus原AVD。随后另一项目启动CodexLabelsQuickSortQA模拟器及Gradle/Kotlin进程，导致宿主提交余量低于不变的8GiB录制门槛：首次拒绝时7.835GiB，随后观察到约5.577GiB。没有降低门槛或尝试双模拟器录制。

已恢复本任务临时的heads-up通知设置为1并关闭本任务的PiliPlus模拟器；未停止另一项目的进程。保留capture-refused-a1.json及resource-interruption.json。待资源可用且先后安排明确后，继续protocol.md中的4条A/B/B/A同条件录制。仅编译通过、首页输出ready及内部通知不能作为提速结果。
