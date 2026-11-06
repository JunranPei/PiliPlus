"""Hard preflight gate for PiP tests.

This gate is deliberately separate from APK building.  A PiP test cannot
proceed unless the owned AVD is online, the requested APK is installed, and
the application has a live process.  It writes an INCOMPLETE record on every
failure so a failed preflight cannot be reported as a test result.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path


def run(adb: Path, serial: str, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        [str(adb), "-s", serial, *args],
        text=True,
        capture_output=True,
        timeout=45,
    )
    if check and result.returncode:
        raise RuntimeError(f"adb {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def online(adb: Path, serial: str) -> bool:
    result = subprocess.run([str(adb), "devices"], text=True, capture_output=True, timeout=15)
    return any(line.split()[:2] == [serial, "device"] for line in result.stdout.splitlines())


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--adb", type=Path, default=Path("D:/Android_studio_sdk/platform-tools/adb.exe"))
    parser.add_argument("--emulator", type=Path, default=Path("D:/workplace/antigravity/PiliPlus/tmp/startup-test-emulator-37.2.12/emulator/emulator.exe"))
    parser.add_argument("--avd", default="PiliPlusStartupIsolated_20261018")
    parser.add_argument("--serial", default="emulator-5562")
    parser.add_argument("--package", default="com.personal.piliplus")
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--record", type=Path, default=Path("diagnostics/pip-test-gate.json"))
    parser.add_argument("--start", action="store_true")
    args = parser.parse_args()
    record = {"status": "INCOMPLETE", "serial": args.serial, "avd": args.avd, "package": args.package}
    args.record.parent.mkdir(parents=True, exist_ok=True)
    try:
        if args.start and not online(args.adb, args.serial):
            subprocess.Popen([
                str(args.emulator), "-avd", args.avd, "-port", args.serial.rsplit("-", 1)[-1],
                "-no-window", "-no-snapshot", "-no-boot-anim", "-gpu", "host", "-feature", "-Vulkan",
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 120
        if args.start:
            while not online(args.adb, args.serial) and time.monotonic() < deadline:
                time.sleep(2)
        if not online(args.adb, args.serial):
            raise RuntimeError("指定 AVD 未上线：ADB 没有显示 emulator-5562 device")
        record["deviceOnline"] = True
        if args.apk:
            if not args.apk.is_file():
                raise RuntimeError(f"APK 不存在: {args.apk}")
            record["hostApkSha256"] = sha256(args.apk)
            run(args.adb, args.serial, "install", "-r", str(args.apk))
        remote = run(args.adb, args.serial, "shell", "pm", "path", args.package)
        if not remote.startswith("package:"):
            raise RuntimeError("目标 APK 未安装")
        record["installedApkPath"] = remote
        run(args.adb, args.serial, "shell", "am", "start", "-W", "-n", f"{args.package}/.MainActivity")
        pid = run(args.adb, args.serial, "shell", "pidof", args.package)
        if not pid:
            raise RuntimeError("应用未启动：pidof 为空")
        record.update({"appPid": pid, "status": "READY"})
    except Exception as error:
        record["error"] = str(error)
        args.record.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(record, ensure_ascii=False))
        return 2
    args.record.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(record, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
