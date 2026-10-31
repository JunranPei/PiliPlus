# Round72: yield the first-output dual-EAGAIN loop

2026-10-31. Goal remains active. 0.8 seconds and exact first consumed PTS are not yet achieved. This report distinguishes targeted trace attribution, a real codec mechanism test, and application timing.

## Observed cause and scope

The native70 diagnostic capture `callback-native-spans-01/capture` used callbacks=1, decode_only=0, fresh application PID9551/coreTID9599 and a61.5s resume. Its texture listener was2086.4024ms; this instrumented capture is not pooled with lean performance samples. First receive921.0437ms, first queue1035.5875ms, tenth decoded output1616.4596ms, first eligible pretarget packet1634.6608ms, target release2042.5649ms.

The ten-output timestamp confidence check is not a fixed sleep: its recorded code spans total0.1146ms. The695.4159ms from first receive to confidence comprises queueInputBuffer184.0294ms, remaining avcodec_send174.9861ms, event waits95.6907ms, filter graph76.9151ms, audio reinit65.165ms and smaller spans. These are exclusive wall intervals, not CPU attribution. One avcodec_send interval outside the recorded queue call is161.3902ms.

Exact FFmpeg sources show a first-output loop: unavailable input and output both return EAGAIN; receive_frame immediately retries to preserve FFmpeg's send/receive contract. Before the first output, the backend overrides the nominal8ms wait with timeout0. Under callback-backed local queues, this can spin on the monitor. This source mechanism is consistent with the unexplained send interval, but the trace does not prove the whole161ms was CPU spinning.

## Change

Only after both ports return EAGAIN, and only while output_buffer_count==0, the callback path waits on the existing monitor for input/output/error/close, bounded at8ms. Availability wakes it immediately. The original synchronous and NDK paths are unchanged. The10-output confidence guard, reference requirements, selected codec, quality, timestamps, clipping and EOS path remain intact. `debug.piliplus.callback_wait` defaults off; both application comparison arms enable callbacks and disable decode-only. The close event records emptyPolls, waitCalls and waitNs in both arms.

Sources and exact before/after hashes: `native-callback-wait-01/source-provenance.json`, `callback-wait.patch` and archived headers. Native library SHA256 `b07a6e3cdad94bc0fe8576f55abea584781733cb3500f68af8be4f9bd1b6fca4`. Build passed and the build volume unmounted. The test APK SHA256 is `12d18674384d4033a38afb5c001f3de29acee04fba076f86cd410b7e9abdebe6`; all707 nonsignature entries match the previous APK except lib/x86_64/libmpv.so. Signature and16KiB alignment verified; Dart/Flutter unchanged.

## Completed mechanism and lifecycle tests

Actual embedded DEX loading and Android codec lifecycle passed:122 initial frames,111 frames after EOS seek,111 after partial seek, exact PTS equivalence, four flushes, repeated close, empty queues and stopped callback thread. A blocked awaitActivity owner was woken by close. Evidence: `native-callback-wait-01/embedded-device-reviewed.json` and raw device output.

The real480p HEVC Surface probe uses the production helper and the FFmpeg-like first-output protocol. Four runs use control/candidate/candidate/control. All122 output timestamps match exactly in all runs.

| Arm | First output ms | Owner CPU ms | Empty polls | Wait calls |
| --- | ---: | ---: | ---: | ---: |
| Control1 |90.7917|41.399884|494|0|
| Candidate2 |83.3444|4.336161|7|7|
| Candidate3 |61.9576|3.737704|6|6|
| Control4 |61.9855|31.821123|458|0|

This verifies removal of the busy loop and reduced owner CPU in the probe. It does not establish1080p application startup improvement. Evidence: `native-callback-wait-01/wait-probe-reviewed.json`, raw stdout/stderr and compiled probe provenance.

## Application comparison completed

`run-callback-wait-observed.py` used one QA143 Android lifetime, excluded one zero-start seed, then ran candidate/control/control/candidate. Every formal sample started a new application process and the first click resumed61.5s. Same APK, native binary, listeners, source, persisted indexes and quality; only callback_wait varied. All four mechanism/native61.5/continuous playback/return checks passed. Exact first consumed61.5 passed2/4; other samples remain failed for that criterion.

| Sample | PID | Texture ms | Cover ms | Empty polls | Wait calls | First consumed PTS s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Candidate1 |3877|2496.9770|2591.6718|8|8|61.633313|
| Control2 |4326|1813.5127|1982.3075|1077|0|61.500000|
| Control3 |4751|2002.1676|2087.3601|96|0|61.533313|
| Candidate4 |5152|2680.5238|2787.1086|8|8|61.500000|

Median texture2588.7504 vs1907.8402ms, cover2689.3902 vs2034.8338ms: no overall speed benefit demonstrated. The wait mechanism is active and removes empty polling, but it is not an accepted startup acceleration. Code retained, experimental switch defaults off.

The fresh API responses selected different CDN hosts: both candidates used upos-sz-estgoss.bilivideo.com; the controls selected different mcdn.bilivideo.cn backups. Candidate4 has a1252.434ms worker-clock gap between resume body progress events, with only8192 additional bytes at the latter event. `_retainChunk` executes in the downstream-coupled body iterator, so this is a delivery observation gap, not proof of an exclusively network/CDN delay. Candidate4 firstreceive626.0168→firsteligible1241.1706→selected2660.4691ms. Candidate1 has firstreceive1105.7017→firsteligible1640.7181→selected2319.3682ms. Keep all raw records; do not subtract the gap to invent an adjusted speed result or attribute all of the group difference to the native wait.

## Follow-up seek exposed a transport failure

`callback-wait-seek-01/capture`, PID5564, actual input/playback captured successfully. Initial texture2144.4967ms. During the actual horizontal seek, the old resume delivery closed and `isolated.closed expected=false` appeared before route.leave. Return review correctly failed because both track closures were missing. Native callback close itself has13waits/138.3006ms, threeflushes, empty queues, stopped thread and no native error; audio flinger reports zero active tracks. Post-seek texture eventually progressed86.366688→94.966688s, with a long seek stall; it is not a passed seek/continuity regression.

The existing parent listener discarded the worker error list to avoid exposing signed URLs, so the captured trace cannot identify the original exception. Round73 adds only a bounded sanitized type/stack listener before an Android reproduction. A real local TCP-abandonment regression on the existing transport passed and therefore did not reproduce this Android failure. No cause or fix claimed yet. QA143 remains running, both debug properties were restored, and the new diagnostic build retains the same native72 binary and build defines.
