# 三星播放诊断 CLI

入口为 `python -X utf8 tool/pili_cli.py --serial R5CY13T5Z3J`，命令放在末尾。
手机须已解锁，诊断 APK 须已安装。CLI 逐条返回 JSON，可在命令前加
`--out 路径.json` 保存结果。全程使用 ADB、无障碍控件树和播放器监听，不读取图像。

| 操作 | 命令及参数 |
| --- | --- |
| 启动／回到应用 | `launch` |
| 回到应用主页 | `app-home` |
| 打开指定视频 | `open BV1xU4E6iE9y`，也可给完整视频网址 |
| 列出可见视频 | `videos` |
| 按标题选视频 | `select-video 标题片段` |
| 按序号选视频 | `--index 0 select-video`，从 0 开始 |
| 播放／暂停 | `play` / `pause` |
| 按秒直接跳转 | `seek 48` |
| 点击实际进度条 | `click-progress 50`，参数为百分比 |
| 拖动实际进度条 | `drag-progress 25`，参数为百分比 |
| 保持显示／隐藏控制条 | `controls show` / `controls hide` |
| 全屏／退出全屏 | `fullscreen on` / `fullscreen off` |
| 进入小窗 | `pip` |
| 倍速 | `speed 1.25`，范围 0.25–4 |
| 返回／手机桌面 | `back` / `home` |
| 查看控件／进度条 | `ui` / `progress` |
| 按文字／说明／ID点击 | `tap-text 文本` / `tap-desc 说明` / `tap-id ID` |
| 坐标点击／滑动 | `tap 540,330` / `swipe 540,1600,540,800,350` |
| 当前播放状态与原生时钟 | `status` |
| 导出当前进程诊断 | `--out capture.json export`，同时拉取 `capture.zip` |
| 单变量音频诊断 | `audio-output audiotrack` / `audio-output aaudio`，只改变当前播放器 |

`seek` 直接调用播放器；`click-progress` 和 `drag-progress` 先保持控制条显示，
从当前控件树取得进度条坐标，再注入真实触摸，并在结束或异常时解除显示保持。
多个匹配必须指定 `--index`，无匹配、应用被覆盖或不在前台时不盲点。
触摸结果同时包含选中控件及播放器回读状态；注入动作本身不能证明画面继续播放。

原生接收器仅在诊断构建中开启，要求发送者持有 `android.permission.DUMP`，
不监听网络端口。普通 release 不开启控制接口。

依据 Android 官方 [ADB 文档](https://developer.android.com/tools/adb)、
[UiDevice 控件树文档](https://developer.android.com/reference/androidx/test/uiautomator/UiDevice)。
真实操作记录见 `diagnostics/pip-large-geometry-20261110/s25u-cli-record.md`。
