# Historical mpv output standby transplant

This branch ports the preserved `fca5f2aa1` experiment onto the reconstructed historical `mediacodec_embed` baseline. It retains that output route and its original autoplay/cover handling. Only GPU output uses the idle 960x540 buffer setup; direct MediaCodec output keeps decoder-controlled sizing. Both build variants include the same observers and historical verbose logging; `--control` disables only startup standby. The older runtime baseline reconstruction is committed as `2bdf889aa` and documented in `diagnostics/startup-20261019/old-mpv-standby/provenance.md`.

The following paragraph documents the preserved c35 checkpoint, not a performance claim for this transplant:

This checkpoint preserves the exact App and Android controller sources used to build the tested APK `51a4eb198abe20df0ac08eb44ffce2a534c646a00a85b5244dcdbdc40fe08b73`. It is an investigation checkpoint, not an accepted performance fix. The base is `c35b53769e9577416e89aeab3f06fbbc5b8200f6`, with the original mpv/media_kit, UI and features.

`lib/main.dart` schedules one empty Player/VideoController after the first App frame. The Android controller prepares an unused Surface/GPU output and hands it to the first real media load. It does not open or preload media, prepare a decoder, create a second player, or rearm output standby for later media. Settings changes discard the speculative engine, and failures retain on-demand creation.

The native controller dependency is versioned here because the experiment adds an API absent from the pinned upstream package. Do not edit the shared Pub cache permanently. The build entry temporarily installs this file into the exact pinned dependency revision and restores it on success or failure:

```powershell
python tool/build_startup_standby.py --output diagnostics/checkpoint-gpu-standby.apk
python tool/build_startup_standby.py --control --output diagnostics/checkpoint-control.apk
```

The local environment requires the existing Flutter package configuration, Java 21 and Android SDK. The guard refuses to build with an emulator running or insufficient host memory. Build output includes a SHA-256 and flags manifest. Normal builds do not enable standby unless `PLAYER_STANDBY=true`; use this entry point for a reproducible experiment.

Validation already completed: four 35-second same-video A/B/B/A captures and one homepage idle probe. GPU configuration and handoff were confirmed, with no software-to-hardware parameter transition in the candidates. Motion confirmation: control 4.4/3.7 seconds, standby 3.5/3.3 seconds. Stable end-to-end benefit remains unproven; no ten-video acceptance or full feature regression claim. See `diagnostics/startup-20261019/gpu-standby/findings.md` and `evaluation.json`.

Raw recordings and APKs remain in local diagnostics and are not added to Git. Only selected source, summaries and scripts belong to this checkpoint. The dependency file retains its upstream MIT attribution.
