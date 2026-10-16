# Ten release videos with emulator audio enabled, 2026-10-17

APK source: `5bbcc02c13a12c92e35c9ec73d34169c5025ad0a`; SHA-256 `D3C790C3717891825E92D5957F7CE548C84488338C99DAB5C673C2F05F54B898`.
Environment: the existing 4-vCPU, 2-GB Android emulator using Swiftshader, with audio enabled; app PID `5882` throughout. Native Media3 is the only playback backend.

The app was already running. Each of ten distinct sources was opened through an Android video intent and recorded for 35 seconds with the emulator host recorder. Disk cache was preserved, and all ten used cached media before their first frame. Playback API requests still occurred. This is a warm-process, cached-media test, not ten uncached first visits or a physical-device result. Host recording has different overhead from Android `screenrecord`; results must not be silently mixed across those methods.

| Video CID | Request to native first-frame notification, ms | Request to increasing video PTS, ms | Last position, ms |
| --- | ---: | ---: | ---: |
| 42781444806 | 1152 | 1168 | 33049 |
| 42756868744 | 986 | 1281 | 33061 |
| 42788979177 | 847 | 1073 | 33014 |
| 42752999555 | 1090 | 1509 | 32057 |
| 42788521380 | 966 | 1110 | 33044 |
| 42790290231 | 1125 | 1233 | 33176 |
| 42702671393 | 985 | 1330 | 32023 |
| 42762438366 | 997 | 1328 | 32076 |
| 42782426469 | 871 | 1162 | 33142 |
| 42766829000 | 1333 | 1346 | 33091 |

First-frame notifications: minimum 847 ms, median 991.5 ms, maximum 1333 ms. All ten reached 32–33 seconds with one source open each, no post-start pause intent, no transition back into buffering after ready, no playback errors, and no observed audio underrun. Actual opened CIDs were checked against the fixture and were unique.

The recorded video crop was sampled at 10 fps after the first six seconds. Longest near-static runs were 0.1, 0, 0.7, 0, 0.1, 0.3, 0.2, 1.0, 0.6, and 0.2 seconds. The overview was visually inspected: it contains the ten different sources with changing content. Its final black column is unused contact-sheet padding, not recorded video blackness. Authored static scenes and danmaku can affect the crop metric, so this is supporting evidence against a persistent mid-play freeze, not proof of every rendered frame being smooth.

The first-frame notification and increasing PTS are diagnostic timestamps. Neither is a pixel measurement of the first visible dynamic picture. Stable approximately 0.8-second visual startup remains unachieved.

A separate cold-process run of CID `42702671393` used the same release APK, host recorder, enabled emulator audio, and preserved disk cache. It took 4000 ms from the intent request to the native first-frame notification, including approximately 2750 ms before the native source open and 1250 ms after it. Increasing PTS was reported at 4620 ms. The 25-second capture reached position 19044 ms with no post-start pause intent or observed underrun. This cold result is substantially slower and is not included in the warm-process median. Evidence: `diagnostics/startup-20261016/startup-recordings/release-audio-cold-20261017/`.

Raw evidence:

- `diagnostics/startup-20261016/ten-video-regressions/release-audio-ui-20261017/results.json`
- The same directory's `summary.json`, `recording-analysis.json`, and `continuity-overview.jpg`
- `diagnostics/startup-20261016/startup-recordings/release-audio-ui-20261017-01` through `-10`, each containing `screen.webm`, `playback.log`, and `result.json`

One slower sample also illustrates why the good result is not yet stable: video 4 submitted its first video output at native 345 ms, recorded the surface render at 361 ms, but delivered the surface callback about 256 ms later. Video 3's corresponding callback delay was 3 ms. This identifies an output-to-application scheduling difference; it does not establish which concurrent work caused it.
