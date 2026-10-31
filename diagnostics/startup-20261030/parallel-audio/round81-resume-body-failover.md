# 第81轮：正文停顿后续接，取消起播前等满缓冲

Same QA144/native72; callbacks1/wait0/decode0/videoqueue1, initial/resume winner gates off. Only RESUME_BODY_FAILOVER differs. Freshprocess61.5s BAAB,25s/back18. Allsamples retained. Not physicaldisplay or exact consumedPTS proof.

|样本|首纹理ms|封面ms|首消费PTS秒|最大连续帧间隔ms|返回|重试/切换|
|---|---:|---:|---:|---:|---|---:|
|01-candidate|1673.5524|1813.0708|61.500000000|112.1685|True|0/0|
|02-control|1832.6436|1868.0645|61.600000000|633.1204|True|0/0|
|03-control|2050.7833|2234.1250|61.533313000|129.4821|True|0/0|
|04-candidate|1708.7726|1892.0338|61.500000000|167.9171|True|1/0|

控制中位数1941.7135ms，候选1691.1625ms；净收益+250.5510ms（+12.90%）。封面净收益+198.5424ms。

本轮实际重试1次，验证后切换0次。精确首消费61.5秒2/4；原生起点4/4；返回4/4。

N2 per arm; ordinary-network difference cannot establish stall-recovery gain when no validated switch occurred. Controlled HTTP stall evidence is separate. Never add this difference to prior80.

52项控制条件测试证明113KB后停顿可以恢复、原始字节不变、无前置等待；不能据此填写真实应用净收益。取消和拖动的独立实测另记。
