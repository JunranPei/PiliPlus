# 第85轮：慢速正文追赶，原连接持续交付

Same QA145/native72; callbacks1/wait0/decode0/videoqueue1, initial/resume winner gates off. Only RESUME_BODY_PROGRESS_RACE differs. Freshprocess61.5s BAAB,25s/back18. Allsamples retained. Not physicaldisplay or exact consumedPTS proof.

|样本|首纹理ms|封面ms|首消费PTS秒|最大连续帧间隔ms|返回|重试/切换|
|---|---:|---:|---:|---:|---|---:|
|01-candidate|1611.6720|1683.6333|61.500000000|130.4658|True|0/0|
|02-control|1816.3970|1863.1751|61.566688000|122.6911|True|0/0|
|03-control|1842.8990|1886.2432|61.533313000|117.4889|True|0/0|
|04-candidate|1660.8562|1763.7708|61.500000000|231.0051|True|1/0|

控制中位数1829.6480ms，候选1636.2641ms；净收益+193.3839ms（+10.57%）。封面净收益+151.0071ms。

本轮实际重试1次，验证后切换0次。精确首消费61.5秒2/4；原生起点4/4；返回4/4。

N2 per arm; Small paired cohort; attribute speed only if the alternate actually supplies earlier pre-target bytes. Controlled slow-prefix HTTP evidence is separate. Never add this difference to prior81.

59项控制条件测试验证慢速正文追赶、原始字节不变、无前置等待；初次重复比较错误及超时日志已保存，修复后通过。控制条件测试不等于真实应用收益。取消和拖动的独立实测另记。

功能：真实播放前取消PID13242无目标帧/无drain，返回及零队列/线程关闭通过；拖动PID13679从已监听到的播放画面发出，恢复新位置1597.2067ms，后续单调播放14.4秒，三次flush及返回通过。该拖动仍慢，不列为速度改善。

原QA144队列完整3条（B1727.7389/A3354.8359/A2118.9423ms），第4条起播后模拟器暂停再退出，BACK和拉取超时；崩溃处理器Windows事件与原始日志已保留。恢复后从同一磁盘数据启动QA145，独立种子+完整BAAB；不跨重启混算。新队列全过程主机进程监听只记录running。详见resume-body-progress-observed-02/regressions-and-interruption-reviewed.json。
