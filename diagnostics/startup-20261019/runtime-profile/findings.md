# Whole-app diagnosis: two recordings, one complete combined trace

The 0.8s objective is not achieved. These are instrumented cause samples, not a
new release baseline or evidence of an effective speed change. No new playback
optimization was enabled. The original goal was verified active in this turn.

## Actual work and results

- Four changed Dart files passed `dart analyze` with no issues after corrections.
- Profile APK built successfully, SHA256
  `a4fa155e530e93286921f2e96e1f61c1c2953c195bf42ea9fe52d1d4da198c08`.
  Matching source snapshot and per-file hashes are alongside the APK.
- One failed preflight (`runtime-profile-d1-20261019-5`) rejected the HTTP VM
  service enum-list parameter before recording/tap. It is not a playback sample.
- Two valid 25s recordings, one video, original in-app search URI submit,
  process force-stopped before home launch, VM connection and input setup
  completed before measured tap; Player/Surface standby on, no media preload.
  `coldProcess:false` in the shared recorder means it did not force-stop again
  at the measured tap; capture-context.json documents actual process preparation.

| Trial | Pointer PTS | First actual media image PTS | First confirmed motion PTS | Click to image | Click to confirmed motion |
| --- | ---: | ---: | ---: | ---: | ---: |
| d1r | 1.178 | 5.849 | 5.917 | 4.671s | 4.739s |
| d2 | 1.108 | 6.164 | 6.197 | 5.056s | 5.089s |

PTS are original WebM timestamps, reviewed in pointer-before-after.png,
review-pts.jpg and motion-pts.jpg. Thumbnail/cover and its spinner do not count
as actual media. Frame intervals around onset are about 33–35ms; the motion
boundary is a confirmed observation, not sub-millisecond first-pixel precision.

No renewed buffering/playing=false event was recorded after initial startup in
either ~20s app trace. Later d2 frame samples through 24.558s move; that is not
proof of continuous frame cadence or zero stutter. Host minima were
7.736/7.135GiB available RAM and 11.023/10.411GiB commit headroom for d1r/d2.
No gate was lowered, compiler overlapped with the emulator, or other task stopped.

d1r collected 2058 Dart samples at 1000us, with 34 marked truncated. Its VM ring
timeline overwrote the beginning; its native off-CPU attempt failed because
`sched:sched_switch` was unavailable to simpleperf despite the advertised feature.
Both failures remain saved. A separate idle 0.5s on-CPU capability check succeeded
(2 samples, zero lost); it is not another playback trial.

d2 used a real-time VM Timeline subscription, preserving 61,045 events including
8 HTTP adapter intervals, plus 2242 Dart samples at 1000us (40 marked truncated).
Native app sampling recorded 1790 samples, zero lost, 82 truncated stacks. Native
buffer was limited to 8MiB, stack copies to 8192 bytes and output to 64MiB/15s.
The system trace was bounded to 32MiB/20s. Not all native functions resolved:
the leaf-name heuristic flags 606/1790, mainly Flutter engine (445), Dart AOT
(113), mpv (39) and VM service (9). Dart AOT names are separately available in
the VM profile. External Codec2 service functions were not app-sampled.

## What d2 actually spent time on

All following intervals are relative to `query.primary.begin`, not an invented
exact click timestamp. API timeline timestamps are Dart delivery. Native mapping
uses clock-start.json midpoint; its 5.616ms RPC interval leaves about +/-2.808ms
uncertainty. See inspect-d2.sql/txt and memory-scheduler-d2.sql/txt.

| Boundary | Relative to primary begin | Meaning |
| --- | ---: | --- |
| playurl adapter entered | 316.739ms | Upstream signing, interceptor, queue and UI scheduling occurred before this; not all crypto CPU time |
| playurl headers delivered | 1001.614ms | Adapter wait to headers 684.875ms; does not separately prove DNS/TCP/TLS/remote time |
| playurl first body chunk delivered | 1002.157ms | Dart adapter delivery, not native media first byte |
| playurl body ended | 1034.711ms | Adapter interval 717.972ms |
| primary function ended | 1129.392ms | Another 94.681ms after body end; CPU stacks can inspect decode/model/scheduling, not assume all JSON CPU |
| real source open submitted | 1233.099ms | ~103.7ms after primary return |
| native codec Init entered | 2463.602ms | ~1230.5ms after source submission, includes native source connection/demux path |
| codec Init completed | 2658.001ms | Init slice 194.399ms |
| configure | 2683.552–2729.556ms | 46.004ms |
| start | 2729.760–2816.514ms | 86.754ms |
| flush | 2947.109–3052.076ms | 104.967ms |
| first post-flush client input | 3081.008ms | Flags/size absent; cannot call it exact first real media bytes |
| first onWorkDone(ts=0) | 3352.836ms | Work callback may be empty, not a first decoded frame |
| next onWorkDone(ts=0) | 3823.474ms | Still no payload-size proof |
| first Surface release | 3955.888ms | 874.880ms after first post-flush client input; not actual display |

Init/configure/start sum to ~327ms of recorded call intervals. They do not explain
the entire post-source delay. The 875ms input-to-Surface interval contains:

- HEVC goldfish service thread scheduled Running ~696.5ms, runnable ~42.6ms.
- Client MediaCodec_loop Running ~176.8ms, runnable ~175.5ms, sleeping ~519.7ms.
- mpv Thread-6 Running ~214.6ms, runnable ~257.6ms, sleeping ~398.8ms.
- kswapd0 Running ~544.7ms in parallel.

These overlap on different virtual CPUs and must not be summed into wall time.
Guest scheduler Running includes its kernel execution and is not a measurement
of host physical CPU or proof that the service spent all this time decoding.
It is nevertheless clear that this interval includes active service processing,
client sleep and scheduling waits, not just creating a decoder.

## Memory and observer effects are material

Within primary+0–5.5s, kswapd0 was scheduled Running ~3256.7ms. Guest counters
show pswpin +9302 pages, pswpout +15495 pages and pgscan_kswapd +115693 pages.
PiliPlus RSS ranges ~279–317MiB and swap ~31–57MiB. The codec service RSS ranges
~5–85MiB; Wellbeing also ranges ~83–136MiB. These min/max ranges are not an
allocation call stack or proof that one process alone triggered reclaim.
There was only one recorded direct reclaim slice (~0.093ms); background reclaim
and runnable contention must not be called a long direct allocator stall.

Observability has a measurable footprint. 421/1790 native samples contain the
diagnostic class in the call chain or belong to Dart Profiler T; 126/649 do so
before first Surface release. Dart `_reportTaskEvent` has 301 self samples over
the full capture. These are sampled observations, not additive delay estimates.
The SDK profile build inherits Android debuggable=true, as checked in the merged
manifest and native record metadata; it also tracks widget creation. Debug-level
mpv logging, per-frame geometry/JSON, ART activity and the profiler itself can
perturb the app. Therefore 4.74/5.09s must not replace the previous 2.45s release
sample as a supposedly identical baseline.

## What is still missing, and next work

1. Native media first byte, per-track DNS/TCP/TLS and demux read boundaries remain
   incomplete. Dio observations cover API requests, not FFmpeg streaming.
2. Native stripped interiors and Codec2 service function stacks remain unresolved.
   `mpv_wait_event(ctx,0)` appears in Dart native-event-loop samples; its sample
   count is not proof that it blocks or is the dominant startup cost.
3. First Surface release to actual picture still crosses texture consumption,
   Flutter/SurfaceFlinger and emulator capture. Current clocks do not isolate all
   of that; neither cover removal nor output-size change proves a displayed frame.
4. Reduce redundant observer work before using another profiled duration for a
   comparison, retain CPU/scheduler/async coverage, and use a stable click clock.
   Re-establish a release baseline under explicitly equal App/Player/media/guest
   conditions. Do not enable a new playback candidate merely because this trace
   names waits; no speed benefit has yet been proved.

Native HTML flamegraph is native-cpu.html; VM CPU profiles and Speedscope exports
are in the original trial folders. Tool methodology and official references are
in method.md. No third playback sample was taken to chase a better result.

After collection the verified 17b4cf41… release control was reinstalled, the
notification setting was restored to this turn's saved 0, and this task's AVD
was closed. No compiler/emulator remained. The earlier saved notification value
1 is a historical discrepancy documented in continuation.md, not overwritten.
