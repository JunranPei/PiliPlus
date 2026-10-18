# Historical mpv + standby controlled comparison

First preserve the tested c35 standby checkpoint (`fca5f2aa1`), then reconstruct the historical e79 + preference-overlap + stage-observer runtime (`2bdf889aa`), then transplant standby. Do not revive Media3, local proxy forwarding, `!no_clip`, change stream choices, or force the old direct output onto the newer GPU path.

The only A/B difference is `PLAYER_STANDBY=false/true`. Both variants use original `mediacodec_embed`, immediate Surface attachment, historical autoplay/cover gates, the same native observer source, PLAYBACK_TRACE, PLAYBACK_STARTUP_VERBOSE and STARTUP_TIMING. Empty Player and configured output are created after the first App frame and claimed once; no media preload or dummy clip. Later videos keep the historical lifecycle.

Build one variant at a time, emulator off, existing memory gate intact. First perform one homepage probe per variant to check configured output, empty playlist, no playback/decoder opening, and approximate idle memory; do not use activity-launch or first-frame callbacks as video timing.

If the standby mechanism works, record exactly four 35-second cold-App first-video samples in A/B/B/A order, on one original AVD in one emulator reboot session, with no build running. Same video BV15BJX6dEoR/CID42790290231, same in-App URI search submission, original WebM PTS/pointer anchor, separate first image and confirmed media motion. Do not compare these directly to the historical warm-process 2.4-second sample as if conditions were identical. Inspect failures, slow samples, buffering and pause events, with bounded-log and later recording limits stated.

Require actual output/Player handoff, preserve the old output mode, and check continuing playback. A failed readiness check or fallback is not a valid standby gain. Extend to at least ten different videos only if directional testing shows a clear real-picture benefit and normal continued playback; do not keep sampling the same video until a favorable result appears.
