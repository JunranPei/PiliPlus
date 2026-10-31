# Round70 — callback-backed MediaCodec availability

Status: actual app BAAB, callback cancellation cleanup and seek regression reviewed. Target0.8s not reached or claimed.

The prior native traces identified synchronous MediaCodec service waits before the target frame. This round compares two mechanisms before changing the app: move queueInputBuffer to a worker, or receive buffer availability through MediaCodec callbacks. Queueing stays synchronous in the selected implementation.

## Mechanism evidence

QA141, public same-video480p HEVC fixture, c2.goldfish.hevc.decoder, Surface output, compressed packets preloaded. Each process starts from the preceding keyframe60s and decodes through the61.5s target to EOS. These timings start at the first queued input and exclude app entry, networking, audio and configuration. They are not comparable to click-to-first-frame app timings at1080p.

| Method | Candidate target-output median ms | Neighboring sync median ms | Difference ms |
|---|---:|---:|---:|
| Queue worker only |319.463|322.735|−3.272|
| Callback availability only |295.831|338.098|−42.267|
| Callbacks plus queue worker |502.987|379.747|+123.240|

All13 runs completed and produced identical122-output timestamp sequences; seed0 excluded. Samples9–12 include a slow configure outlier, retained. Small sample counts do not establish a stable performance distribution. Raw results and paired comparisons: `codec-queue-probe-02/completed.json`, `paired-reviewed.json`.

Initial probe01 callback setup failed before configuration because standalone app_process did not prepare a main Looper. Its failure printer then accessed a missing field. Both corrected in02, along with matched8ms synchronous output waiting.01 timings are excluded; its edited Java is explicitly qualified as not matching the original compiled jar.

## Implementation and lifecycle

`tool/native_codec_callbacks/PiliCodecCallbacks.java` attaches to the exact existing codec selected/reserved by FFmpeg. It owns a callback thread and bounded-by-codec input/output availability queues. It preserves output format ordering, BufferInfo values, synchronous input queueing, EOS and errors. Flush drops old callbacks through a handler barrier and restarts asynchronous input. Close wakes waiters, clears queues and joins the callback thread.

The locally compiled helper-only DEX is embedded in libmpv and loaded with the public API26 InMemoryDexClassLoader. No app Java/Dart change or downloaded code is involved. JNI routes the existing wrapper calls to the helper only for requested HEVC Surface decoding on API26+. `debug.piliplus.codec_callbacks` defaults off. The native codec reservation, nonreference skipping, timestamp confidence and audio priming are preserved. Decode-only remains present but off in both arms of this comparison.

Real Android Java lifecycle tests passed twice, including via the exact embedded DEX loading path with helper absent from parent classpath: initial122frames; seek after EOS111frames; flush during partial decode then seek111frames; all exact timestamp sequences match fresh synchronous references. Four flushes, repeated close, partial cancellation and waking a blocked owner passed. Callback thread stopped and queues emptied. These do not by themselves prove app integration or rendered pixel equivalence.

Native library SHA256: `22dddc4ca67b0671ba809a4129c996e3706eedf89059646a4742387f06b81369`.
QA APK SHA256: `8aeb386acf199c42918a0edc304cc37b661e3b67ca3be5d7f2f1cebbdb95655c`.
707 non-signature entries retained; only lib/x86_64/libmpv.so changed. Same signer and16KiB alignment verified. Native sources checked against actual69 hashes before mutation; build volume unmounted after success.

## App protocol

One retained QA142 Android lifetime, excluded control zero-start seed, then B/A/A/B at61.5s. Every formal sample starts a new app process. Same binary, source quality, fixture, listeners and cache protocol. Configure and close events prove callback activation and thread cleanup; normal source/input, exact first consumed PTS, native selected PTS, continuous playback and return checks remain. Cancellation is triggered by actual active callback configuration; its real phase is determined from listeners.

## Actual app cohort

Same QA142, four fresh app processes, native70 in both arms, decode-only off:

|Sample|PID|First consumed texture ms|Cover removed ms|First consumed PTS s|
|---|---:|---:|---:|---:|
|B1 callback|4747|1935.523|2094.524|61.566688|
|A2 synchronous|5108|2201.444|2382.938|61.566688|
|A3 synchronous|5518|2169.556|2269.587|61.566688|
|B4 callback|5883|1693.306|1827.899|61.500000|

All four actual mechanism/source/input/cache/native-selected-video-and-audio61.5/continuous-playback/return checks passed. Existing exact-first-consumed criterion passes only B4; no rule relaxed. Both callbacks active,10.768–21.172ms setup, close queues empty/thread stopped/no error. Actual used flush on return succeeded.

Candidate medians: texture1814.415ms, cover1961.211ms. Control:2185.500ms,2326.263ms. Observed differences−371.086/−365.051ms. Receive-to-selected median1101.629 vs1287.985ms (−186.357ms); however control samples1006.823 and1569.148ms vary widely and overlap candidates1077.053/1126.204ms. First receive itself141.847ms earlier in candidate median, outside the decode interval. Thus this cohort supports retaining the promising callback experiment, not a stable371ms attributable gain or completion. All raw samples retained; do not combine prior QA141 results as same-cohort controls.

Cancellation02 PID7115: after real callback configure662.135ms and verified keyboard-hidden state, BACK host command began1.677s after input-command completion. Native selected target/drain1973.936ms, callback close2392.070ms (39input/30output callbacks, oneflush, zeroqueue/thread, noerror), audio clear2425.056ms with12pendingframes. Three source closures ~499ms after route.leave, active audio zero. Cleanup passed; cancellation before target/drain did NOT occur and is not claimed. Java lifecycle tests separately cover partial decode and blocked owner cancellation.

Seek03 PID7489 passed: actual horizontal gesture released6519.583ms after original input. First new sampled PTS91.766688s appeared829.890ms later; subsequent sampled timestamps increase to102.433313s with no old-position reappearance. Two actual seek flushes36.375/12.094ms and one return flush completed. Callback close had zero queued buffers, stopped thread and no error; three source closures ~397ms after route.leave and zero active audio. This functional capture is separate from the speed cohort and does not establish pixel equivalence.

## Sources

- [Android Media3 customization](https://developer.android.com/media/media3/exoplayer/customization)
- [Media3 callback availability and flush handling](https://raw.githubusercontent.com/androidx/media/release/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/mediacodec/AsynchronousMediaCodecCallback.java)
- [Media3 adapter selection](https://raw.githubusercontent.com/androidx/media/release/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/mediacodec/AsynchronousMediaCodecAdapter.java)
- [Android InMemoryDexClassLoader](https://developer.android.com/reference/dalvik/system/InMemoryDexClassLoader)

## Preparation provenance

Source preparation first selected the earlier Round62 archive lacking its later prototype repair. Expected native69 hash rejected it before any source write; corrected to the recorded `mediacodec-wrapper-prototypes.after`. DEX header builder originally recorded LF text hash but wrote Windows CRLF; both text and actual file hashes are now recorded, embedded DEX bytes unchanged. No playback result was produced or erased by these preparation corrections.

QA142 first excluded-seed preparation stopped before any video tap: Android key injection produced `bilbili://...` instead of `bilibili://...`. Actual focused EditText XML proves one missing character; no player failure or playback timing occurred. Capture now waits for an enabled focused search field, preserves each text observation, and repairs a mismatch once through the actual clear control plus paced individual key events. Submission still requires exact full URI. Three focused host tests and the existing three clear-control tests pass. Real same-process Android fault injection reproduced the exact missing character and verified full recovery without submitting a video. Original failure kept in `codec-callback-observed-01`; same QA142 PID21852 retained. Formal cohort continues under `codec-callback-observed-02`; new readiness/input preparation applies equally to every arm outside measured input timing.

Cancellation01 sent BACK while keyboard hide was still completing (same PID6276 system ImeTracker supplement); no route.leave, so rejected. Playback itself continued.02 waits actual input_method hidden state before sending BACK and records the timing; no claim of cancellation before the target. A generated wrapper indentation error was caught before running, preserved as `cancel-ime-syntax-failed.py`, corrected before02.

Seek01 custom wrapper wrongly requested32seconds with a22..25second capture profile; argument parser rejected before app launch.02 used the existing22second capture but its slider selection found only the8pixel mini progress bar after controls hid, not the required visible control. No seek was sent; actual playback data retained separately from the speed cohort.03 uses the existing horizontal seek gesture directly, which does not depend on controls staying visible during a UI hierarchy dump. No pixels/OCR used in any case.
