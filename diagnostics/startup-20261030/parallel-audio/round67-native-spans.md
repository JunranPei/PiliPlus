# Round67 native span attribution and Round68 hypothesis

Capture: filtered-audio-native-spans-01/capture, new app PID8426 on retained QA139. Native67 selected-PTS diagnostics. Actual consumed video2343.5012ms, cover2477.7587ms. External app/video Perfetto12,882,115bytes; no scheduler switches or stacks. Diagnostic-only; do not compare absolute times with lean samples.

| Recorded stage | Input-relative ms | Duration ms |
|---|---:|---:|
| Source open |228.7067| |
| Decoder init |593.5209–717.0399|123.5190|
| First empty output dequeue |767.9805–815.3227|47.3422|
| Core event waits before input |836.151–867.539;869.268–990.253|152.373|
| First codec input to target output release |1003.2282–2195.4484|1192.2202|
| Target release to restart notification queued |2195.4484–2218.3257|22.8773|
| Target release to first positive consumed texture |2195.4484–2343.5012|148.0528|

Within the prerelease1192.2202ms interval, exclusive core-thread wall time: queueInput302.416ms, dequeueOutput195.885ms, dequeueInput116.591ms, audioReinit68.283ms, releaseOutput28.803ms, and filter-graph scheduling216.918ms. These are wall-time contexts, not CPU-time attribution. Other threads overlap and must not be added.

First10 output PTS checks reach confidence0 at1712.8383ms. First safe drop2 at1718.2932ms, after14 feed decisions. Keep this correctness guard unchanged.

93 filtered audio frames were retained from1244.501 to1530.137ms. Meanwhile video output checks were60.000 at1172.7044,60.033313 at1371.1301,60.066688 at1557.764ms. The current priming process continually calls mark_progress and can consume available audio without a per-player-loop quota; both audio filtering and video packet feeding execute on core TID8473. This establishes a serial burst, but its net removable time is not established by this instrumented sample.

Round68 changes only that priming scheduling:4 output frames per core cycle, one core wakeup when yielded, and filter wakeup at the next fill_audio_out_buffers boundary. FIFO limits, exact selected video PTS clipping, codec confidence, normal audio drain, format change, and passthrough semantics stay unchanged. Existing bounded native events add yieldedCycles/maxCycleFrames to prove activation without a new trace. Must compare on the same retained Android with fresh app processes and identical Dart/Flutter payload, then check real cancellation and continued playback.

Underlying upstream API reference: https://github.com/mpv-player/mpv/blob/master/filters/filter.c ; the authoritative implementation for this build is archived native-loop-trace-01/filters-filter.c.after. No default video decode queue change: https://mpv.io/manual/stable/#options-vd-queue-enable documents constraints on hardware decoding.
