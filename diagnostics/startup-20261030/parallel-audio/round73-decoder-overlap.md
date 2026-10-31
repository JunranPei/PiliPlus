# Round73: transport diagnostics and decoder/audio overlap

Diagnostic APK `transport-exit-diagnostic.apk`, SHA256 `995bbb3a1dde9c9c89ca0f1a4b676aec5de2b4e29afb8b0d5226195223243070`, retains native72 `b07a6e3cdad94bc0fe8576f55abea584781733cb3500f68af8be4f9bd1b6fca4`. Only production change from the preceding build is sanitized worker error reporting; no transport behavior fix is claimed.

`transport-exit-device-01` failed before measured input: host adb exited C0000409. No playback result. The completed, idle PiliPlus Gradle daemon 18268 was identified by creation time and its final build log, then released; unrelated Gradle 46396 remained untouched. Same QA143 emulator remained running. `transport-exit-device-02` completed actual playback, seek and return: PID6942, texture2114.2848ms, no worker exception, return closure validation passed. This does not prove the original intermittent worker exit fixed. Original native debug properties were restored after retry.

`callback-wait-native-spans-01` completed on the same QA143, PID7369; callbacks1/wait1/decode-only0, diagnostic trace only. Texture2856.7182ms is not a lean comparison. Core7422/audio7638. First receive956.750ms, first queue1249.7418, ten-output confidence2019.7489, first eligible2049.4003, target release2833.8289. All return closures passed. Native72 wait14calls/158.2838ms closely accounts for the initial send162.065ms at1280.962–1443.027. CPU busy polling was reduced but this wait remained.

Audio first decoded frame1241.448ms; core audio output reinitialization1507.574–1581.274ms. Video occupied core across the intervening interval. Main playback loop already calls audio filling before video, so swapping those calls is not a fix. Investigate an independent decoder owner with one queued video frame. Existing mpv dispatch serializes reset and destruction, clears the queue before decoder reset and joins the owner before freeing decoder state; FFmpeg output references retain codec lifetime and check flush serial. This review is not device proof. Official manual warns against generic hardware decoder queuing: https://mpv.io/manual/master/#options-vd-queue-enable. Experiment must remain default off, with actual seek/return and exact first-consumed PTS checked.

The confidence analyzer's hardcoded native70 label was stale. `metadata-correction.json` records native72 identity without replacing raw trace or numeric results; future analyzer no longer hardcodes version.

Next candidate uses `STARTUP_VIDEO_DECODE_QUEUE=true`, one-frame/16MiB/0.05s limits, same native72, image quality, clipping and timestamp confidence guards. It tests whole decoder ownership, distinct from Round70's slower input-queue worker. No gain claimed before actual measurements. Dart-only compile/repack helper preserves Android/native/engine/assets and verifies payload differences to avoid another full Gradle build. Goal active; 0.8s and exact-first-consumed acceptance remain unachieved.

## Round74 implementation and actual mechanism

Two Dart-only builds completed in132.547 and97.277seconds. Candidate SHA8e645f3affb0a5b33c5e10141ec45b7d89a8d21469dc11aa7ae6a55d025f6b17; control60e1026841e1cd647b6c1a4c07f1f220bfd08e9a04921c7f4fbcd6e24b557333. Onlylibapp.so differs from verified baseline; native72/engine/assets/signer/16KiB alignment unchanged. Same source in both; onlySTARTUP_VIDEO_DECODE_QUEUE flag differs.

Diagnostic01 wrapper supplied25seconds/back23, violating required cleanup interval, so parser rejected beforecapture. Trace pull then masked primaryfailure due nonexistentcapture directory. Corrected25/back21; preserved01 and fixedpull/errorreporting. No emulator restart or data deletion. Diagnostic02 actualPID8090 completed: decoder8369 distinct fromcore8141, audio8372. Video send868.1753–977.7295ms overlaps entireaudio reinit869.3222–951.8395ms. Firstaudio829.598ms. This confirms the intended parallelism, not a total-speed benefit. Texture1987.6203ms/firstPTS61.5. Actualseek resumes91.633313s after1122.4283ms and advances to104.666688s; threeflushes, emptycallbackqueues/threadstopped/error0, alltrackclosures andactiveaudio0. No repeattransportworkererror. Fullmechanismreview andseekreview saved undernative-video-thread-01. Formalno-traceBAAB nowrunning onretainedQA143, freshApp eachtime.

## Round74 formal cohort and decision

|Order|App PID|Queue|Texture ms|Cover ms|First consumed PTS|
|---|---:|---|---:|---:|---:|
|01-candidate|8531|candidate|1881.8865|1954.2384|61.566688|
|02-control|8953|control|1719.9875|1824.6476|61.533313|
|03-control|9311|control|1830.7730|1979.3024|61.500000|
|04-candidate|9721|candidate|2000.9115|2034.6170|61.600000|

Allfoursource/native61.5/callback/wait/ownerthread/cache/continuity/return mechanisms passed. Exactfirstconsumedonly1/4passed, retainedfailedforothers. Candidate mediantexture1941.399vs1775.3803ms(+166.0188),cover1994.4277vs1901.9750(+92.4527); nooverallbenefit. Receive-to-selected959.3979vs1103.1004(-143.7025), butfirstreceive877.1139vs632.5552(+244.5587) andselected-to-texture104.8873vs39.7247(+65.1627). N2perarm, variableCDN; do notclaimstablecausal144msgain. Keepdefaultoffexperimentforstacking, do notdeleteitjustbecause0.8unmet.

CancellationPID10101actualconfiguredcallbackthenIMEhidden/BACK completedallsourceclosures/callbackclosed/queues0/thread0; targethadalreadyproducedpositiveframe anddrainoccurred. Thereforebefore-targetcancellationremainsunproved; not relabeledpassed.

Initialfetchbreakdown: B1resumeheaders473.8584msbutinitialvideoheaders768.3054; reservedcodecwasready331.4192buttaken874.9308. Controls initialheaders335.4216/379.7264, B4initial505.124. Sourceevent timestamps are forwardedDart events, not exclusiveDNS/TLS measurements. CurrentPersistedResumeIndexHints alreadytrimsftyp/moov/sidxmetadata butexplicitlyusesitonlyasoffsetprediction; ParallelAudioSource._serve alwaysawaits_current_initial_headers. Nextinvestigatevalidatedinitialmetadata delivery without stalebytes (currentresponsevalidator/total checks), or freshinitialrequest path, ratherthanblindqueue-size tuning. No newmetadata-serving codewritten.

Alltestdebugpropertiesrestoredempty. QA143retainedPID64008, dataintact; noactivebuild/capture. Nativevolumeunmounted. Goalactive/unachieved; restoreGalleryonlyatfulltestingcompletion.
