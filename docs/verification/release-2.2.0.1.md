# PiliPlus 2.2.0.1

按用户要求新增第四段版本并设为1，APK和应用内显示2.2.0.1，Android versionCode=9。Flutter内部pubspec保持合法语义版本2.2.0+9，发布显示名由tool/release_profile.json的versionName=2.2.0.1统一传入Dart和Android，不修改播放优化开关。

三星兼容条件由仅SDK36改为SDK36及以上，避免SDK37重新使用AAudio。SDK35和其他厂商保持原行为。策略测试3项通过，包含SDK37、38的覆盖。

三星SM-S9380、SDK37上的10个不同视频已执行点击和拖动进度条。9个视频有持续进度及纹理；BV1zXTC63EWV另有HTTP超时、seek未完成和慢样本，按失败保留。第7视频初次点击纹理采集提前结束，已补测；末尾第10视频小窗恢复后跳转也有持续进度。逐视频资料见diagnostics/pip-large-geometry-20261110/s25u-reported-again-20261111/ten-video-results.md。

本次发布关闭CLI及详细监听，保持r116原生库SHA-256为5d93acb683355870dc8cc5a1f119f92f9a421565e049072a51542fe60497748f。构建后核对APK签名、版本、实际原生库和诊断代码裁剪，并通过install -r覆盖安装三星，保留应用数据；最终安装核对另存JSON。
