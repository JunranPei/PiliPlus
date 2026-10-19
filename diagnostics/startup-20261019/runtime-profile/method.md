# Whole-app startup profiling

Purpose: explain work and waits before actual moving picture. This profile build
is not a performance candidate or a release speed comparison. Original mpv,
stream selection, UI and playback gates stay intact; SOURCE_EARLY_PREPARE is off.

## Correlated observations

| Layer | Observation | Limit |
| --- | --- | --- |
| Dart functions | VM CPU stack samples, requested period 1000us, all surviving isolates | Statistical samples, not every invocation; exited isolates can be missing |
| Dart asynchronous work | Developer timeline, existing playback boundaries, adapter spans | A callback timestamp is delivery time, not native execution time |
| API transport | Adapter begin, headers delivery, first body chunk delivery, body end/error/cancel | Includes adapter pooling/DNS/connect/TLS until headers; does not separately expose each transport boundary or JSON completion |
| Platform channels | Flutter's built-in platform channel TimelineTasks in profile mode | Send/reply interval excludes message encoding/decoding; channel names only |
| Native app functions | simpleperf task-clock:u, requested 1000Hz, DWARF stacks, 15s/64MiB output and 8MiB buffer | d1r off-CPU feature failed despite advertisement; d2 on-CPU worked; stripped library interiors can remain unknown |
| Scheduling | Perfetto sched_switch/waking, gfx/view/video/audio/binder, 20s/32MiB | Running, runnable and sleeping durations differ; sleeping alone does not identify a cause |
| Memory | Guest meminfo/vmstat/PSI snapshots, 250ms process/system counters, reclaim/RSS events if supported | Missing kernel events must be reported; no heap allocation tracing by default |
| Actual display | Same original UI search-URI submit and WebM frame PTS review | Texture, codec output, surface release, cover removal and Flutter raster are not proof of moving picture |

The first VM ring trace lost its beginning. The second records Timeline events
over the service WebSocket in real time; CPU sample buffer is bounded to 12s of
the VM's duration sizing policy. Measured sample counts/coverage are in findings.md.
CPU sampling plus a system scheduler timeline is the first pass. Global method
entry/exit or allocation tracing is not enabled: it changes timing and can
produce excessive data. A short targeted trace may follow a specifically
identified gap. No raw media URLs, headers, payloads or general HTTP profile
bodies are intentionally saved by the added adapter observer. It observes the
existing response stream without replacing response metadata or retry policy.

Native mpv/FFmpeg networking does not go through Dio. App-native sampled stacks
may locate transport/parsing work but do not automatically supply a timestamp
for the first media byte. Codec2 service internals are outside app-scoped native
sampling; its system slices and scheduler records remain available. These are
coverage gaps to measure, not claims that all milliseconds are already explained.

## Resource and measurement policy

One existing AVD, 2048MiB/4 cores/audio. Build alone, release its own idle compiler
resources, then launch only after the existing memory gate and >=10GiB physical
availability. Capture retains >=8GiB commit / >=6GiB RAM start gates and live
abort thresholds. Preserve failed profiler output, do not weaken permissions or
memory limits to make a sample succeed. No repeated sampling to select a fast
result. No Media3, local forwarding or no_clip experiment.

## Official references

- [Flutter CPU profiler](https://docs.flutter.dev/tools/devtools/cpu-profiler): profile builds, call trees, sampling rates and overhead.
- [Flutter performance timeline](https://docs.flutter.dev/tools/devtools/performance): synchronous and asynchronous timeline instrumentation.
- [Flutter Network view](https://docs.flutter.dev/tools/devtools/network): Dart-originated traffic coverage and recorded contents.
- [Android Java/Kotlin method tracing](https://developer.android.com/studio/profile/record-java-kotlin-methods): instrumentation overhead and short recording guidance.
- [AOSP simpleperf application profiling](https://android.googlesource.com/platform/system/extras/+/android16-release/simpleperf/doc/android_application_profiling.md): profileable apps, software CPU samples, symbol requirements and off-CPU feature checks.
- [Perfetto CPU scheduling](https://perfetto.dev/docs/data-sources/cpu-scheduling): scheduler events distinguish running from waiting.
- [Perfetto memory counters](https://perfetto.dev/docs/data-sources/memory-counters): process polling and kernel memory events.

Local SDK source verification: Flutter services/platform_channel.dart uses
debugProfilePlatformChannels only outside release, creating TimelineTasks around
send/reply. kProfilePlatformChannels is hard-coded false in this SDK; it is not
an environment flag. No SDK source was modified.
