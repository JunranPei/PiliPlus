# 起播叠加优化（2026-10-30）

用户要求：0.8 秒是最终目标。确认有收益且无功能退化的单项改动保留，继续寻找其他突破口叠加；不得仅因单项未到 0.8 秒而撤回。持续目标仍 active。

本候选仅提前发起已选音轨 HTTP 请求，视频继续使用原 mpv transport。音频最多保留 256 KiB 前缀，首次请求流式传递；范围外重开/拖动 307 回原地址，响应头等待上限 3 秒，最终释放随播放源替换/播放器销毁，不随页面准备完成取消。非网络、直播、纯音频、非零起点不启用。编译开关 PARALLEL_AUDIO_SOURCE 默认 false，尚未获得设备提速证据。

9 项传输测试通过：请求提前发出、首块及时交付、前缀复用与范围外 seek、HEAD/416、200 完整响应、无效 206 回退、慢头回退、dispose 断开、旧流停滞时 seek。尚不能替代设备连续播放、音轨、返回/取消验证。

对照使用 listener-frame.apk（b4fdd63a…）与 candidate.apk，相同独立 AVD/画质/监听开关，交错重复；分别比较输入到纹理消费、API 结束到纹理消费及媒体打开到纹理消费。texture.consumed 仍非物理显示完成证明。旧并行代理的 API 波动不能继承为本方案收益。

依据：mpv v0.41.0 player/loadfile.c 在 open_demux_reentrant 返回后才调用 load_external_opts，改 external audio 文件仍串行。https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/player/loadfile.c

后续候选须由采样决定：已观察到 MediaCodec 首次排队到输出约 472ms，其中调度等待与 guest kswapd 活动明显；不是简单把 cache-secs=16 改小即可消除。https://mpv.io/manual/stable/#options-cache-pause-initial
