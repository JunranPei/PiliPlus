# Home PiP route guard — 2026-11-07

User report: occasional Home page entering PiP after PiP → video → Home → desktop; previous fix insufficient.

Code finding: native PipCoordinator has no route ownership state. configure/updateActions can reapply auto entry. Dart disableAutoEnter is serialized behind previous commands. Native mode-exit flag reset alone cannot prevent later configure. This establishes missing protection; no runtime reproduction of the user's rare race has yet been captured.

Change: Navigator page-stack observer publishes current page before RouteAware teardown. Native defaults to deny and only allows /videoV and /liveRoom. Page revisions invalidate pending Dart and late native commands. Dialogs retain the underlying page; page replacement/removal/pop updates the gate. All native automatic/manual/transition paths check eligibility. Already pinned invalid routes request full-screen restoration.

Official source: https://developer.android.com/develop/ui/views/picture-in-picture (auto-enter is Activity-wide; update parameters early; disable when inappropriate).

| Case | Layer | Result |
|---|---|---|
| Modified Dart files analyze | static | passed |
| Late video commands after Home / old revision | native unit | pending |
| Old video revision against new video | native unit | pending |
| PiP → video → Home → desktop repeated | emulator system listener | pending |
| Home → recents → desktop | emulator system listener | pending |
| New video manual PiP still enters | emulator system listener | pending |

Environment incident: installed phone ARM64 release crashes on x64 emulator with EM_AARCH64 instead of EM_X86_64. Old install success did not prove startup. Candidate test build uses android-x64. No phone installation or phone release delivery in this round.

Native test attempt 1: invalid excluded task; no tests ran. Attempt 2: daemon disappeared while compileDebugKotlin; no passing result. Retrying sequentially after release build.

Playback speed net benefit: unmeasured; no controlled startup samples. Playback source/decoder changes are outside this fix.

## Verified outcome
- Candidate SHA256: 3647febea36a71d6041da3c1e2b08bb15e7352448dee9cb01059576098d05692 (android-x64 release).
- Actual installed process: 5823, emulator-5562, API 36, hardware GPU unchanged. All operations used ADB/system and application event listeners and accessibility XML; no image recognition.
- Native unit tests: 2 tests, 0 failures, 0 errors; native-tests.xml. Final command testDebugUnitTest with quoted in-process Kotlin option and one worker succeeded. Earlier attempt 3 used an unavailable release test task; attempt 4 daemon exited; attempt 5 PowerShell split unquoted dotted property, task selection failed; preserved logs at diagnostics/pip-route-guard-native-tests*.log.
- Actual full sequence initially passed once. Six additional recorded trials all entered video PiP (system pinned task), returned full-screen, returned to route=/ allowed=false, then reached desktop with no pinned PiliPlus task. Three direct desktop, three through recents; see settled-repeats.json and settled-repeat-*-*.txt.
- Invalid scripted repetition: repeat-1 restored too early during entry animation; wrong-PiP-state error retained, excluded from successful counts. Settled repetitions wait 1.5 seconds after pinned entry, then verify full-screen restoration before continuing.
- Manual PiP-button attempts did not obtain a valid entering/active event; manual entry regression remains unverified (do not count as pass). These attempts do not change the seven complete auto-entry sequence results.
- Rare phone failure itself was not reproduced or traced. No claim of complete elimination or measured speed effect.
- Source diff in source.patch. Changes limited to PiP route/command eligibility; pre-existing unrelated dirty files preserved.
