# 第86轮：起播音频解码队列临时限量

Same QA145/native72; callbacks1/wait0/decode0/videoqueue1, initial/resume winner gates off. Only STARTUP_AUDIO_DECODE_QUEUE_BOUNDED differs. Freshprocess61.5s BAAB,25s/back18. Allsamples retained. Not physicaldisplay or exact consumedPTS proof.

|样本|首纹理ms|封面ms|首消费PTS秒|最大连续帧间隔ms|返回|重试/切换|
|---|---:|---:|---:|---:|---|---:|
|01-candidate|1936.8264|2072.7725|61.566688000|122.4481|True|0/0|
|02-control|1834.7250|1988.5493|61.500000000|101.7183|True|0/0|
|03-control|2116.4439|2234.2119|61.566688000|109.8071|True|0/0|
|04-candidate|1682.7530|1799.8704|61.500000000|138.1244|True|1/0|

控制中位数1975.5845ms，候选1809.7897ms；净收益+165.7948ms（+8.39%）。封面净收益+175.0591ms。

本轮实际重试1次，验证后切换0次。精确首消费61.5秒2/4；原生起点4/4；返回4/4。

N2 per arm; Small paired cohort; native instrumentation must verify fewer decoded audio frames before video target release; source-ready restoration is separately checked. Different-thread intervals overlap. Never add this difference to prior85.

35项生命周期/帧监听/换源测试通过。音频帧数量和恢复机制须以实际原生跟踪验证；取消和拖动另记。

原生机制（独立重跟踪，不用作起播性能对照）：目标视频帧61.5秒输出前音频解码189→99帧，最后PTS64→62.08；过滤FIFO保持93帧、末PTS61.952。首帧后实际恢复0.08→2秒。

取消初版PID6563被源代次递增误判为换源，跳过恢复；原始事件保留。修正后PID7671在源代次1内恢复2秒，首目标帧前返回、无drain、源与线程回收通过。36项测试通过。拖动PID8119恢复新位置1617.0613ms，随后播放14.3秒、3次flush/返回通过；该拖动速度仍慢，不当作提速成果。

本轮相邻对净差-102.1014/+433.6909ms，方向不同；完整中位净差+165.7948ms（+8.3922%）。第一receive中位差-2.6880ms，receive→drain差+176.2827ms。保留候选继续叠加/复核，不把小样本差推广为稳定保证。
