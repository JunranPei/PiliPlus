# Historical mpv baseline reconstruction and standby transplant

The current c35 GPU standby version was committed first as `fca5f2aa1` on `codex/playback-startup-latency`. It contains the App sources and versioned Android controller used for APK `51a4eb198abe20df0ac08eb44ffce2a534c646a00a85b5244dcdbdc40fe08b73`, a guarded build entry, and the measured limitations. No remote push was requested or performed.

This separate branch starts from `e79b9d9c07c25e001e844011d0723f19785a5e3a`. The historical `noclip-control-v1-5` APK was `09213586a9437f3ccf543bbdb0a7651dd549cfee2a73e2b026ff2891e35e119f`. Its recorded build used `PLAYBACK_TRACE=true` and `PLAYBACK_STARTUP_VERBOSE=true`; no startup source probe directory was defined, so it used selected remote media normally. Its output was `mediacodec_embed` with immediate Surface attachment, not Media3.

The exact intervening App patches were recovered from the local original session, not inferred from the final proxy experiment backup:

- Session `01a13f91-8e78-75c2-b09a-0dc27dcded75`, recorded lines 16510 and 16531: selected-track completeness guard, guarded background quality completion, preference/request overlap, and waiting for quality options in menus.
- Line 17396: enable verbose milestone diagnostics independently of source replacement, source hook begin/end markers, reset milestone budget per source, and buffering events.
- Line 17404: historical stage-diagnostic build command. Line 17455 saved and installed the historical control APK.
- No additional App mutation was found between the preference candidate and the stage-diagnostic patch. Recording-tool edits in that interval do not change runtime App code.

The three recovered patches are retained in this directory. They were reviewed and applied in order to e79, then formatted with the existing Dart SDK. This reconstructs the historical runtime source state; it does not promise byte-identical APK reproduction across builds. The new controlled pair will include identical observers in both variants and differ only in the standby build flag.

The old output route must stay `mediacodec_embed`. The transplant reserves the same empty engine and unused Surface, preparing the configured output rather than forcing the newer GPU route onto the old version. No real media, dummy clip, Media3 component or decoder is preloaded. The older direct output route already attaches before decoding, so the expected extra saving may be smaller than on c35; only recordings can establish it.
