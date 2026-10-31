# Round71 — retain callback availability, add decode-only preroll

Same running QA142 PID21852, native70 and identical APK. No build, emulator restart or repeated seed. Fresh app process for each61.5s resume; disk indexes verified in each capture. Callbacks enabled in both arms; candidate alone enables API34 decode-only for eligible pretarget reference packets. Both original debug properties restored to empty afterward.

|Sample|PID|Texture ms|Cover ms|First consumed PTS s|
|---|---:|---:|---:|---:|
|B1 stacked|7968|1732.684|1823.248|61.566688|
|A2 callbacks only|8353|1832.863|1938.000|61.566688|
|A3 callbacks only|8712|1786.607|1883.859|61.533313|
|B4 stacked|9081|2125.089|2349.206|61.500000|

All four actual playback captures completed. Callback and decode-only mechanism checks passed, native selected video/audio61.5, continuous playback and return cleanup passed. The existing exact-first-consumed acceptance passes only B4; others remain failed.

Candidate medians texture1928.887/cover2086.227ms vs control1809.735/1910.930ms: candidate119.152/175.297ms slower in this small cohort. No supported stacked gain. Both experimental implementations retained; no rollback of earlier improvements and no0.8s claim.

Receive-to-selected candidate1134.613 vs1059.903ms; firsteligible-to-selected446.096 vs397.110ms. B1 latter segment360.598ms but B4 rises531.593ms, so choosing B1 alone would misrepresent the comparison. Firstreceive also54.181ms later in candidate median. Two samples per arm do not establish stable distribution or isolate every scheduling effect.

The repeated earlier interval is firstreceive to first eligible packet after timestamp confidence:716.191,681.699,643.888,660.843ms. Existing mpv source increments `has_broken_packet_pts` from−10 on decoded output, then permits framedrop_type2 only at0. Existing Round67 spans locate the first eligible packet after that confidence transition. This makes the initial confidence/decode feeding phase the next defined target; it is not evidence that deleting the guard is safe. Next inspect packet/output timestamp guarantees and malformed/reordered cases before any narrowly guarded change. Do not repeat arbitrary queue or codec parameter probes.

Evidence: `codec-callback-stack-observed-01/completed-samples.json`, individual capture logs/traces, and `native-codec-callback-01/stack-device-reviewed.json`. Only these four are compared; prior cohorts are not pooled.
