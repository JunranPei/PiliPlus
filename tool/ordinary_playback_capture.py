"""Bounded, pixel-free Android playback capture; never starts or resets the app.

Examples:
  python tool/ordinary_playback_capture.py capture diagnostics/playback/run-01 --seconds 30
  python tool/ordinary_playback_capture.py pull diagnostics/playback/manual-01 --package com.personal.piliplus.dev

The app must already have its diagnostic build and listener enabled. SurfaceFlinger
tracing availability depends on Android; failures remain in capture.json. Raw app
files and the system trace are preserved even when another source is unavailable.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import uuid


LOG_NAME = re.compile(r"(?P<stream>flutter|native)-(?:\d+-)?(?P<stamp>\d+)\.jsonl")
PACKAGE = re.compile(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+")


def perfetto_config(seconds, session):
    if not 1 <= seconds <= 180:
        raise ValueError("duration must be between 1 and 180 seconds")
    return f'''unique_session_name: "{session}"
buffers {{ size_kb: 65536 fill_policy: RING_BUFFER }}
duration_ms: {round(seconds * 1000)}
write_into_file: true
file_write_period_ms: 1000
flush_period_ms: 5000
max_file_size_bytes: 134217728
data_sources {{ config {{
  name: "android.surfaceflinger.layers"
  surfaceflinger_layers_config {{
    mode: MODE_ACTIVE
    trace_flags: TRACE_FLAG_COMPOSITION
    trace_flags: TRACE_FLAG_HWC
    trace_flags: TRACE_FLAG_BUFFERS
  }}
}} }}
data_sources {{ config {{ name: "android.surfaceflinger.frametimeline" }} }}
data_sources {{ config {{ name: "com.android.wm.shell.transition" }} }}
data_sources {{ config {{
  name: "android.windowmanager"
  windowmanager_config {{
    log_level: LOG_LEVEL_VERBOSE
    log_frequency: LOG_FREQUENCY_FRAME
  }}
}} }}
'''


def selected_logs(names, started_ms=None):
    """Include the latest process of each stream plus processes born in this run."""
    groups = {}
    for name in names:
        match = LOG_NAME.fullmatch(name)
        if match:
            stamp = int(match["stamp"])
            # Dart startup filenames may use microseconds; Android uses millis.
            millis = stamp / 1000 if stamp > 100_000_000_000_000 else stamp
            groups.setdefault(match["stream"], []).append((stamp, millis, name))
    result = set()
    for files in groups.values():
        result.add(max(files)[2])
        if started_ms is not None:
            result.update(name for _, stamp, name in files if stamp >= started_ms)
    return sorted(result)


def adb_run(base, arguments, *, timeout=20, check=True):
    return subprocess.run(base + arguments, capture_output=True, timeout=timeout,
                          check=check)


def file_info(path):
    data = path.read_bytes()
    return {"file": path.name, "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}


def pull_logs(base, package, destination, started_ms=None):
    remote = f"/sdcard/Android/data/{package}/files/playback-diagnostics"
    result = adb_run(base, ["shell", "ls", remote], check=False)
    if result.returncode:
        return {"remote": remote, "files": [], "error": result.stderr.decode("utf-8", "replace")
                or result.stdout.decode("utf-8", "replace")}
    names = selected_logs(result.stdout.decode("utf-8", "replace").split(), started_ms)
    destination.mkdir(parents=True, exist_ok=True)
    files, errors = [], []
    for name in names:
        path = destination / name
        result = adb_run(base, ["pull", f"{remote}/{name}", str(path)], check=False,
                         timeout=60)
        if result.returncode:
            errors.append({"file": name, "error": result.stderr.decode("utf-8", "replace")})
        else:
            files.append(file_info(path))
    return {"remote": remote, "files": files, "errors": errors,
            "selection": "latest stream files and any process started during capture",
            "note": "Active files can end with a partial final line; analyzer reports it."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("capture", "pull"))
    parser.add_argument("destination", type=Path)
    parser.add_argument("--adb", type=Path,
                        default=Path("D:/Android_studio_sdk/platform-tools/adb.exe"))
    parser.add_argument("--serial", default="emulator-5554")
    parser.add_argument("--package", default="com.personal.piliplus.debug")
    parser.add_argument("--seconds", type=float, default=30)
    args = parser.parse_args()
    if not PACKAGE.fullmatch(args.package):
        parser.error("invalid Android package name")
    if not 1 <= args.seconds <= 180:
        parser.error("--seconds must be between 1 and 180")
    destination = args.destination.resolve()
    if destination.exists() and any(destination.iterdir()):
        parser.error("destination must be new or empty; existing captures are never overwritten")
    destination.mkdir(parents=True, exist_ok=True)
    base = [str(args.adb.resolve()), "-s", args.serial]
    started_ms = int(time.time() * 1000)
    metadata = {"schema": 1, "operation": args.operation, "package": args.package,
                "serial": args.serial, "startedUtc": datetime.now(timezone.utc).isoformat(),
                "requestedDurationSeconds": args.seconds if args.operation == "capture" else 0,
                "pixelsCaptured": False, "appStarted": False, "errors": []}

    def save():
        (destination / "capture.json").write_text(
            json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")

    save()
    logcat = None
    log_file = None
    try:
        for key, command in (
            ("deviceFingerprint", ["shell", "getprop", "ro.build.fingerprint"]),
            ("deviceSdk", ["shell", "getprop", "ro.build.version.sdk"]),
            ("appPidStart", ["shell", "pidof", args.package]),
            ("deviceUptimeStart", ["shell", "cat", "/proc/uptime"]),
        ):
            result = adb_run(base, command, check=False)
            metadata[key] = result.stdout.decode("utf-8", "replace").strip()
        if args.operation == "capture":
            session = f"piliplus_playback_{uuid.uuid4().hex}"
            config = destination / "capture.pbtxt"
            config.write_text(perfetto_config(args.seconds, session), encoding="utf-8")
            # Perfetto's SELinux domain cannot read arbitrary /data/local/tmp
            # files on current Android releases; use its supported config dir.
            remote_config = f"/data/misc/perfetto-configs/{session}.pbtxt"
            remote_trace = f"/data/misc/perfetto-traces/{session}.pftrace"
            metadata.update(remoteConfig=remote_config, remoteTrace=remote_trace,
                            perfettoSession=session)
            adb_run(base, ["push", str(config), remote_config])
            log_file = (destination / "logcat.txt").open("wb")
            logcat = subprocess.Popen(base + ["logcat", "-v", "threadtime", "-T", "1",
                "flutter:I", "PiliPlusPlaybackTrace:V", "PiliPlaybackTrace:V", "AndroidRuntime:E", "*:S"],
                stdout=log_file, stderr=subprocess.STDOUT)
            save()
            print(json.dumps({"event": "capture.start", "seconds": args.seconds,
                              "destination": str(destination)}), flush=True)
            result = adb_run(base, ["shell", "perfetto", "--txt", "-c", remote_config,
                                   "-o", remote_trace], timeout=args.seconds + 30, check=False)
            (destination / "perfetto-output.txt").write_bytes(result.stdout + result.stderr)
            metadata["perfettoExitCode"] = result.returncode
            if result.returncode:
                metadata["errors"].append({"source": "perfetto", "error":
                    f"Perfetto exited {result.returncode}; see perfetto-output.txt"})
            pulled = adb_run(base, ["pull", remote_trace, str(destination / "system.pftrace")],
                             check=False, timeout=60)
            if pulled.returncode:
                metadata["errors"].append({"source": "perfetto", "error":
                    pulled.stderr.decode("utf-8", "replace")})
            elif (destination / "system.pftrace").exists():
                metadata["systemTrace"] = file_info(destination / "system.pftrace")
            # Only text buffers are flushed; no screen capture, force-stop or UI action.
        metadata["appLogs"] = pull_logs(base, args.package, destination / "app", started_ms)
        if not metadata["appLogs"]["files"]:
            metadata["errors"].append({"source": "app", "error": "No playback NDJSON copied"})
    except (subprocess.SubprocessError, OSError) as error:
        metadata["errors"].append({"source": "capture", "error": str(error)})
        # Salvage app evidence if system tracing failed, without changing the app.
        try:
            metadata["appLogs"] = pull_logs(base, args.package, destination / "app", started_ms)
        except (subprocess.SubprocessError, OSError) as pull_error:
            metadata["errors"].append({"source": "app", "error": str(pull_error)})
    finally:
        if logcat is not None:
            logcat.terminate()
            try:
                logcat.wait(timeout=5)
            except subprocess.TimeoutExpired:
                logcat.kill()
                logcat.wait(timeout=5)
        if log_file is not None:
            log_file.close()
        metadata["finishedUtc"] = datetime.now(timezone.utc).isoformat()
        save()
    print(json.dumps({"event": "capture.done", "destination": str(destination),
                      "errors": metadata["errors"]}), flush=True)
    return int(bool(metadata["errors"]))


if __name__ == "__main__":
    raise SystemExit(main())
