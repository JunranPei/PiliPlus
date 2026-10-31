# 第89轮：异步送包与音频限量之上回调等待

Same Android lifetime, same APK/native87 and bounded audio decode queue. callbacks1/wait0/decode0/videoqueue1, old body failover enabled, progress race off. Both async1; only callback_wait0/1 differs. BAAB fresh processes61.5s with retained disk index;25s/back18. Texture consumption is not physical presentation.

|样本|首纹理ms|封面ms|首次receive ms|receive→drain ms|首消费PTS秒|连续帧最大间隔ms|输入提交/完成/取消|
|---|---:|---:|---:|---:|---:|---:|---|
|01-candidate|1908.6403|2319.4162|755.0311|1065.5450|61.533313000|238.1716|527/527/0|
|02-control|1756.7305|1865.8397|713.8423|986.8608|61.533313000|194.0252|527/527/0|
|03-control|1662.0060|1744.8148|492.4691|1118.5039|61.533313000|112.3090|536/536/0|
|04-candidate|3353.7166|3499.8643|817.0172|2511.2154|61.500000000|1066.9763|463/463/0|

控制中位数1709.3682ms，候选2631.1785ms；净收益-921.8102ms（-53.93%）。封面净收益-1104.3130ms。

N2 per arm. Network and scheduler variation remain; compare firstReceive and receive-to-drain. Do not add local83 or prior86 differences to measured87.

首次receive净差-182.8684ms，receive→drain净差-735.6979ms。相邻两对[-151.90980000000013, -1691.7106]ms。

精确首消费61.5秒1/4，原生目标61.5秒4/4；返回4/4；超过500ms连续帧间隔：['04-candidate']。
