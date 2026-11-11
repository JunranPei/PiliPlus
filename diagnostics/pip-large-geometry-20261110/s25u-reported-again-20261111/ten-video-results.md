# 三星 SDK37 十视频跳转实测

同一监听包 SHA-256 a6552ba9bc9c938e4c5d0ac108086178fbd6288fe672083c716ae0d69ffe6827；SDK37、实际 current-ao 全为 audiotrack。逐个真实点击、拖动进度条，按 CID 关联进度和纹理。

| BV | CID | 点击与拖动结果 |
| --- | --- | --- |
| BV1xU4E6iE9y | 43406134202 | 进度和纹理持续推进 |
| BV1zXTC63EWV | 39667892368 | 复测发生HTTP读取超时、seek未完成；慢样本也保留 |
| BV1UB4v67Exr | 43375264631 | 进度和纹理持续推进 |
| BV19v4y1M7sK | 757426177 | 进度和纹理持续推进 |
| BV1ve4y1C7vu | 828307112 | 进度和纹理持续推进 |
| BV1q3411w7rE | 758283733 | 进度和纹理持续推进 |
| BV1KJ411k7K5 | 42815521509 | 进度和纹理持续推进；点击纹理首次提前停止，已补测 |
| BV1r1421r78r | 1590922279 | 进度和纹理持续推进 |
| BV1AE411a7qB | 130746380 | 进度和纹理持续推进 |
| BV1uE411x7GH | 160048029 | 进度和纹理持续推进 |

10个不同BV、10个不同CID。9个视频有点击及拖动后持续进度与纹理；第2视频有成功样本，也有慢样本及持续seek失败，按失败保留。末尾第10视频小窗进入／恢复后再次跳转推进 3320ms。

第2失败的ffmpeg日志为 HTTP response Connection timed out、Seek failed、partial file；持续seeking时音频PTS为空。其数据不同于此前AAudio音频仍播放而计时冻结的样本，未归因成同一缺陷。

第7视频首次点击的纹理采集在跳转后约1秒停止，原段缺项保留；补测从1597.5s到1600.832s，缓冲恢复、纹理PTS连续变化。

原始文件见 ten-videos/、ten-videos-continuation/、ten-videos-rest/、settled-repeat/、video7-recheck-*。最终导出 fileLimit=false、dropped=0、ioError=null。纹理消费不包含物理屏幕显示围栏。

正式包已构建并检查CLI及详细监听均关闭，尚未安装，手机当前保留监听版便于继续追查第2视频。