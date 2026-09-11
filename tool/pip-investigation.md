# PiP investigation — 2026-09-10

Branch: `pip`. The inherited experiments are preserved separately in checkpoint
`0299be56f`; they are not evidence that PiP works.

## Reproduced defects and evidence

Evidence directory (local, not committed): `diagnostics/pip-research-20260910/`.

1. Baseline auto entry on API 36 shows a white app-icon overlay before video.
   Native playback configuration logs `rect=null`; no later layout update occurs.
   See `baseline.mp4`, `baseline-native.log` and `baseline-activity.txt`.
2. Reporting the actual rendered video rectangle after paint removes that overlay
   in `20260910-141442-847-Home.mp4`. Native now logs
   `sourceRect=Rect(0, 63 - 1080, 670)` before entry.
3. That first iteration still has roughly two black samples in a 10 fps contact
   sheet when the page switches to a PiP-only layout. It is **not** a passing result.
   Reparenting the Flutter video widget is a suspect, not proof that its native
   Surface was destroyed. The current media-kit fork disposes the subscription in
   `SimpleVideo`; the output belongs to its VideoController.

## Architecture under test

- Native `PipCoordinator` is the single source of PiP phase. Freeze the source
  rectangle during entering/active; ignore measurements of shrinking PiP bounds.
- Measure the transformed visible video, not its letterboxed FittedBox container.
  Report after paint because playback can be configured before video layout exists.
- `AndroidPipViewport` wraps video/live routes above their responsive layout.
  Preserve the same page, MediaQuery and original layout size while entering/PiP.
  Crop and scale the source video into the destination bounds without replacing
  the player subtree. Clip out the rest of the page, including during letterboxing.
- Do not create another decoder, video Activity, playback session or overlay window.
- On exit restore current page constraints and report the normal source rect again.

## Verification

- Seven Flutter tests pass: transformed landscape/portrait coordinates, cover
  intersection, late first layout, unmounted measurement, stable viewport state
  through entry/resize/exit, portrait clipping in a wide destination.
- Scoped Flutter analysis passes.
- Emulator recordings must begin with the target app focused and no pinned task.
  `record_pip_transition.ps1` asserts the target really reaches `mode=pinned`.
  This is necessary but insufficient: inspect the video transition and ongoing
  video frames before declaring visual success.
- Stable-viewport emulator result: pending.
- Android versions other than API 36, physical devices and live playback: unverified.

## Primary references

- [Android PiP guide](https://developer.android.com/develop/ui/views/picture-in-picture):
  proper sourceRectHint, layout updates, content-overlay fallback, automatic entry,
  retaining playback and hiding other UI.
- [AOSP Android 15 PipTransition](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1/libs/WindowManager/Shell/src/com/android/wm/shell/pip/PipTransition.java):
  app-icon overlay when the valid source rectangle is absent.
- [AOSP PipBoundsAlgorithm](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1/libs/WindowManager/Shell/src/com/android/wm/shell/common/pip/PipBoundsAlgorithm.java):
  source hint containment, destination-size and aspect-ratio checks. Correct
  coordinates alone cannot force Android to accept every small/cropped source.
- [Flutter Texture](https://api.flutter.dev/flutter/widgets/Texture-class.html):
  the backend texture is identified by a texture ID, not by a page name.

## Local toolchain

The existing Flutter directory is named 3.44.2 but reports 3.44.4; pubspec pins
3.44.2. Use `--no-pub` with the existing resolved dependencies. Do not upgrade the
SDK or dependencies as a PiP workaround. Emulator APK uses `android-x64`.

No emulator data wipe, app uninstall, or emulator configuration change was used.
