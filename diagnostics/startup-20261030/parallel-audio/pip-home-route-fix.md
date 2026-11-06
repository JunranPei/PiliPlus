# PiP home route cleanup — 2026-11-01

Round116 checkpoint: 17e99dd76. Archived release sources were committed through the index; later workspace experiments remain uncommitted.

Changes: disarm Android auto-entry independently of user preference; disarm at video route didPop before disposal; reject entry requests outside video/live routes and recheck route/player after asynchronous configure; clear native pending flag; disable Android12+ auto-entry with minimal params independent of media receiver/action lifetime.

Acceleration: no edits to decoding, fetch, frame gates, queue settings or native mpv library. Existing116 delivered APK SHA256 remains a291c6c72615ccf4b291944bd9fe5142826f67842fec6bff6258174e00ed3e3d.

Validation: pip_source_rect_test.dart and pip_viewport_test.dart, 10 tests passed. Targeted diff whitespace check passed with CRLF allowance. Device sequence and fresh startup timing NOT yet measured; layout tests do not establish the reported bug is fixed on device. Dart standalone analyses did not return promptly and are not counted as passed.

## Cancelled request toast
Screenshot playurl cancellation traced to AccountManager.toast: every GET error including caller cancellation was displayed with full URL. VideoHttp prefetch cancels at deadline or deselection. Added cancellation-only early return to toast; error propagation, request cancellation, prefetch and playback code unchanged. Widget regression request_cancel_toast_test.dart passed: both cancellation reasons silent, Playing remains present, badResponse server error remains visible. No replacement phone APK delivered yet.
