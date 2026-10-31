# 第87轮：实际播放器异步视频送包

Same Android lifetime, same APK/native87 and bounded audio decode queue. callbacks1/wait0/decode0/videoqueue1, old body failover enabled, progress race off. Only debug.piliplus.async_input0/1 differs. BAAB fresh processes61.5s with separate excluded0sseed;25s/back18. Texture consumption is not physical presentation.

|样本|首纹理ms|封面ms|首次receive ms|receive→drain ms|首消费PTS秒|连续帧最大间隔ms|输入提交/完成/取消|
|---|---:|---:|---:|---:|---:|---:|---|
|01-candidate|1668.9571|1787.6812|773.6058|847.4625|61.533313000|142.1115|531/531/0|
|02-control|1847.8953|1936.1165|674.2078|1065.9797|61.600000000|97.6559|0/0/0|
|03-control|1602.6630|1755.0911|588.9424|971.2619|61.500000000|116.8436|0/0/0|
|04-candidate|1664.3367|1716.5809|571.1665|1056.4112|61.500000000|104.3620|530/530/0|

控制中位数1725.2791ms，候选1666.6469ms；净收益+58.6322ms（+3.40%）。封面净收益+93.4727ms。

N2 per arm. Network and scheduler variation remain; compare firstReceive and receive-to-drain. Do not add local83 or prior86 differences to measured87.

首次receive净差-40.8111ms，receive→drain净差+66.6839ms。相邻两对[178.93819999999982, -61.67370000000005]ms。

精确首消费61.5秒2/4，原生目标61.5秒4/4；返回4/4；超过500ms连续帧间隔：[]。
