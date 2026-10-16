# Startup comparisons, 2026-10-17

Both comparisons used the same original UI, CID `42752999555`, 1920×1080 HEVC, preserved disk cache, enabled emulator audio, and host recording. Each followed ABBA order in one app process, with 35-second recordings. Profile measurements must remain separate from the release ten-video results.

## Construct details after the first frame

Source `68d75da96`; evidence: `diagnostics/startup-20261016/startup-ab/details-construction-20261017/`.

| Case | Details construction | API, ms | Request to native notification, ms | Request to completed cover reveal, ms |
| --- | --- | ---: | ---: | ---: |
| 1 | Original timing | 130 | 1286 | 1324 |
| 2 | After first frame | 287 | 1092 | 1314 |
| 3 | After first frame | 256 | 1195 | 1303 |
| 4 | Original timing | 398 | 1193 | 1253 |

The candidate moved the native notification earlier by 96 ms on average, but UI reveal was 20 ms slower on average. It was not adopted. The release getter always disables this diagnostic mode; the original details remain in the production UI.

## Overlap connectivity lookup with the primary playback request

Source `4b9a33e8e`; evidence: `diagnostics/startup-20261016/startup-ab/network-preferences-20261017/`.

The primary request always asks for the same quality ceiling and does not use the Wi-Fi/mobile preference. The change starts that request while resolving connectivity, then awaits the preference before selecting video quality, audio quality, or codec. A profile-only switch keeps the previous serial order available for comparison.

| Case | Lookup order | Lookup duration, ms | Overlap with API, ms | API, ms | Request to completed cover reveal, ms |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | Serial | 35 | 0 | 150 | 1066 |
| 2 | Parallel | 22 | 22 | 293 | 1669 |
| 3 | Parallel | 30 | 29 | 352 | 1220 |
| 4 | Serial | 28 | 0 | 243 | 1280 |

The parallel dependency is confirmed, but this small warm comparison did not demonstrate an end-to-end speedup. API duration and output callback delay varied. For example, case 2 produced its first output at native 496 ms, but its main-thread callback marker ran at 1133 ms; case 1's corresponding values were 467 and 494 ms. This identifies the delay, without proving which competing work caused it.

The saved cold profile setup log directly measures connectivity from `query.preferences.begin` to `.end` at about 691 ms. The API began about 1 ms after the lookup began, so approximately 690 ms overlapped. This confirms removal of that sequential wait; it is not a claim of 690 ms faster visible startup. A previous cold profile setup had an approximately 811 ms gap before the primary API began, but that older version did not separately time connectivity and cannot assign the entire gap to it.

All eight measured comparison cases reached 32–33 seconds with no post-start pause intent, native playback error, or observed audio underrun. The focused component regression remained 26/26 passing. Stable approximately 0.8-second visible startup is still not achieved.

## Release check of the overlapping request

The release APK from `4b9a33e8e` is saved as `diagnostics/startup-20261017/media3-preference-overlap-release.apk`, SHA-256 `A094C620C10E2D44C929A876557C5DC241B2BADBF3E1662B04FD921F887C9142`. It was installed and tested on the same audio-enabled emulator, with the same CID `42702671393` and preserved disk cache.

- Cold process: request to native first-frame notification 5596 ms; increasing PTS 5461 ms. The surface was rendered before its notification, so PTS advancement preceding the notification is possible. The 25-second recording reached position 18155 ms, with no post-start pause intent or observed underrun.
- Same process, reopened video: notification 883 ms, increasing PTS 1225 ms. The 35-second recording reached position 33066 ms, with no post-start pause intent or observed underrun.

The cold result remains substantially too slow. This single before/after pair does not demonstrate an end-to-end gain over the earlier 4000 ms cold release result. Evidence: `release-overlap-cold-20261017` and `release-overlap-warm-20261017` under `diagnostics/startup-20261016/startup-recordings/`. The ten-video report uses the earlier `5bbcc02c1` APK and must not be presented as ten runs of this later APK.

## Cold process: local prewarming versus direct real source

Profile source `0cfd8d03e`; same 1080p HEVC source and recording conditions. Only profile builds honor the diagnostic `media3_skip_warmup` intent flag. Release behavior is unchanged.

| Case | Local prewarming | API, ms | Request to native notification, ms | Request to completed cover reveal, ms | Observed audio underruns |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | Enabled | 408 | 6862 | 7235 | 1 |
| 2 | Skipped | 931 | 5913 | 5932 | 1 |
| 3 | Skipped | 961 | 5897 | 6100 | 5 |
| 4 | Enabled | 915 | 5709 | 5789 | 0 |

Skipping did not consistently beat the warmed path and both skipped cases had audio underruns after the first-frame notification. It is not adopted. In case 3 the nearest preceding native state still reported 19,705 ms of media buffer, while the subsequent AudioTrack underruns occurred 1.07–1.34 seconds after the first-frame notification. This is evidence of output starvation in that sample, not exhausted media buffering or a deliberate pause. Evidence: `diagnostics/startup-20261017/cold-warmup/warmup-abba-20261017/` and its four linked recordings.

## Fresh release scheduler capture with audio

After the profile comparison, the `4b9a33e8e` release APK was reinstalled. A bounded cold-start Perfetto capture with host recording reproduced a 447 ms interval between the video metadata output callback and the queued main-thread marker.

Within that 447 ms interval, the main thread ran for 238.76 ms, was runnable but not scheduled for 184.12 ms, slept for 23.74 ms, and spent 0.38 ms in uninterruptible sleep. A recorded Dart closure occupied 63.66 ms of wall time; an audio-manager platform call occupied 28.23 ms, including an 18.55 ms binder transaction. These are inclusive slice times and must not be added to the thread running time as independent costs.

In the 900 ms before an audio-underrun log, the ExoPlayer playback thread was runnable but not scheduled for 170.12 ms, ran for 61.43 ms, and slept for 668.44 ms. The same window included software HEVC decoding, raster work, and memory reclamation. The delayed underrun log does not identify the exact instant the audio sink became empty, so this window supports investigating scheduling pressure but does not prove one competing task caused the underrun.

Evidence: `diagnostics/startup-20261016/perfetto/cold-release-audio-20261017/{startup.perfetto-trace,output-audio.sql,output-audio.txt,main-work.sql}` and `diagnostics/startup-20261016/startup-recordings/perfetto-cold-release-audio-20261017/`. The instrumented capture recorded one underrun; it is a diagnostic capture, separate from the uninstrumented release continuity samples above.

The local Flutter engine contains the `--no-enable-merged-platform-ui-thread` switch, and this capture has no separate `1.ui` thread. A thread-layout experiment has not been implemented or tested. This is a possible future comparison, not an established fix; JNI/UI-thread requirements need checking before any default changes.
