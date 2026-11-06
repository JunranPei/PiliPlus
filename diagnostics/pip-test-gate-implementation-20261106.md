# PiP test gate implementation — 2026-11-06

Implemented `tool/pip_test_gate.py` as a hard preflight. `--start` launches the fixed AVD `PiliPlusStartupIsolated_20261018` on port 5562 and waits up to 120 seconds for the exact ADB state `emulator-5562 device`. Without that state it writes `status=INCOMPLETE` and exits 2. With `--apk`, it installs and records the host APK hash; it then requires `pm path`, starts `.MainActivity`, and requires a non-empty `pidof` result. Every failure is persisted to the requested JSON record.

Integrated the gate at the first executable step of `tool/record_pip_transition.ps1`; failed preflight stops before focus checks, input, screen recording, or logs. Default serial is now emulator-5562.

Self-check: `py_compile` passed. Offline gate invocation correctly produced `INCOMPLETE` with the explicit ADB-not-online reason. No APK was built or packaged by this change. Real device acceptance remains pending until the AVD is online.
