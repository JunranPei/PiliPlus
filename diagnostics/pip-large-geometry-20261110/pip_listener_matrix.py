import json
import pathlib
import re
import subprocess
import time

OUT = pathlib.Path(__file__).parent
ADB = ["D:/Android_studio_sdk/platform-tools/adb.exe", "-s", "emulator-5562"]


def adb(*args):
    return subprocess.check_output(ADB + list(args), timeout=30).decode("utf-8", "replace")


def activity_state():
    return adb("shell", "dumpsys", "activity", "activities")


def wait_for(predicate, name, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    raise RuntimeError(name)


def pinned_bounds():
    text = activity_state()
    if "mode=pinned" not in text:
        return None
    match = re.search(r"mBounds=Rect\((\d+), (\d+) - (\d+), (\d+)\).*?windowingMode=pinned", text, re.S)
    return tuple(map(int, match.groups())) if match else ("pinned",)


def media_playing():
    return "state=PLAYING(3)" in adb("shell", "dumpsys", "media_session")


def save(name, text):
    (OUT / name).write_text(text, encoding="utf-8")


adb("shell", "am", "force-stop", "com.personal.piliplus")
adb("shell", "am", "start", "-W", "-n", "com.personal.piliplus/.MainActivity")
time.sleep(3)
adb("shell", "input", "tap", "280", "1100")
wait_for(media_playing, "initial playback")
time.sleep(2)
adb("logcat", "-c")
adb("shell", "input", "keyevent", "KEYCODE_HOME")
small = wait_for(pinned_bounds, "small PiP entry")
time.sleep(2)
save("listener-small-entry.log", adb("logcat", "-d", "-s", "PiliPlusPiP:V", "PiliPlusPiPTrace:V"))
save("listener-small-entry.activity.txt", activity_state())

# Android 12+ uses a double tap on the PiP surface to toggle its expanded size.
if len(small) == 4:
    x = (small[0] + small[2]) // 2
    y = (small[1] + small[3]) // 2
    adb("shell", "input", "tap", str(x), str(y))
    time.sleep(0.08)
    adb("shell", "input", "tap", str(x), str(y))
expanded = wait_for(lambda: pinned_bounds() if pinned_bounds() != small else None, "PiP expand resize", 12)
time.sleep(2)
save("listener-expanded.log", adb("logcat", "-d", "-s", "PiliPlusPiP:V", "PiliPlusPiPTrace:V"))
save("listener-expanded.activity.txt", activity_state())

# Restore, then take the direct app-to-Home path once more.
adb("shell", "am", "start", "-W", "-n", "com.personal.piliplus/.MainActivity")
wait_for(lambda: pinned_bounds() is None, "PiP restore")
time.sleep(3)
adb("logcat", "-c")
adb("shell", "input", "keyevent", "KEYCODE_HOME")
direct = wait_for(pinned_bounds, "direct Home PiP entry")
time.sleep(2)
save("listener-direct-home.log", adb("logcat", "-d", "-s", "PiliPlusPiP:V", "PiliPlusPiPTrace:V"))
save("listener-direct-home.activity.txt", activity_state())

result = {"smallBounds": small, "expandedBounds": expanded, "directHomeBounds": direct}
(OUT / "listener-matrix.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
print(json.dumps(result), flush=True)
