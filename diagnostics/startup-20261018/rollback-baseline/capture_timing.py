"""Bounded startup capture using the existing UI, with host memory limits."""
import argparse
import ctypes
import _thread
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tool'))
import mpv_startup_recording as recorder


class PerformanceInfo(ctypes.Structure):
    _fields_ = [('cb', ctypes.c_ulong)] + [
        (key, ctypes.c_size_t) for key in (
            'CommitTotal', 'CommitLimit', 'CommitPeak', 'PhysicalTotal',
            'PhysicalAvailable', 'SystemCache', 'KernelTotal', 'KernelPaged',
            'KernelNonpaged', 'PageSize')
    ] + [(key, ctypes.c_ulong) for key in ('HandleCount', 'ProcessCount', 'ThreadCount')]


def memory():
    info = PerformanceInfo()
    info.cb = ctypes.sizeof(info)
    if not ctypes.windll.psapi.GetPerformanceInfo(ctypes.byref(info), info.cb):
        raise ctypes.WinError()
    gib = info.PageSize / 1024 ** 3
    return {'hostMonotonicSeconds': time.monotonic(),
            'commitGiB': round(info.CommitTotal * gib, 3),
            'commitHeadroomGiB': round((info.CommitLimit - info.CommitTotal) * gib, 3),
            'availableRamGiB': round(info.PhysicalAvailable * gib, 3)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('label')
    parser.add_argument('--serial', required=True)
    parser.add_argument('--index', type=int, default=5)
    parser.add_argument('--seconds', type=int, default=35)
    parser.add_argument('--cold-app', action='store_true')
    parser.add_argument('--keep-player', action='store_true')
    parser.add_argument('--perfetto', action='store_true')
    parser.add_argument('--collect-standby', action='store_true')
    parser.add_argument('--verify-search-uri', action='store_true')
    args = parser.parse_args()
    initial = memory()
    # This only records an already running emulator. The previous 35-second
    # capture saw a 2.51 GiB whole-system commit increase. Reserve 8 GiB here,
    # with a live abort at 3 GiB; launching/building still requires 10 GiB.
    if initial['commitHeadroomGiB'] < 8 or initial['availableRamGiB'] < 6:
        raise SystemExit('Memory gate refused capture: ' + json.dumps(initial))
    recorder.ADB = ['adb', '-s', args.serial]
    original_adb = recorder.adb
    old = {key: original_adb('shell', 'settings', 'get', 'system', key).decode().strip()
           for key in ('show_touches', 'pointer_location')}
    package_path = original_adb('shell', 'pm', 'path', recorder.PACKAGE).decode().strip()
    installed_sha = original_adb('shell', 'sha256sum', package_path.removeprefix('package:')).decode().split()[0]
    label = args.label + '-' + str(args.index)
    out = ROOT / 'diagnostics/startup-20261017/mpv-phase1' / label
    metadata = ROOT / 'diagnostics/startup-20261018/rollback-baseline' / (label + '-capture.json')
    samples = [initial]
    abort = threading.Event()
    done = threading.Event()

    def watch():
        while not done.wait(2):
            sample = memory()
            samples.append(sample)
            if sample['commitHeadroomGiB'] < 3 or sample['availableRamGiB'] < 1:
                abort.set()
                _thread.interrupt_main()
                return

    def guest_pressure(prefix):
        for suffix, remote in [('vmstat', '/proc/vmstat'),
                               ('memory-pressure', '/proc/pressure/memory')]:
            target = out/f'{prefix}-guest-{suffix}.txt'
            try:
                target.write_bytes(original_adb('shell', 'cat', remote))
            except (OSError, subprocess.SubprocessError) as error:
                target.with_suffix('.unavailable.txt').write_text(str(error), encoding='utf8')

    def adb(*arguments, **kwargs):
        if args.collect_standby and arguments == ('logcat', '-c'):
            log = original_adb('logcat', '-d', '-v', 'epoch', '-s', 'flutter').decode('utf-8', 'replace')
            (out/'pre-click-standby.log').write_text('\n'.join(
                line for line in log.splitlines() if '[PLAYER_STANDBY]' in line), encoding='utf-8')
            (out/'pre-click-output.log').write_text('\n'.join(
                line for line in log.splitlines() if any(tag in line for tag in (
                    '[GPU_STANDBY]', '[OUTPUT_STANDBY]', '[SURFACE_CALL]'))), encoding='utf-8')
            (out/'pre-click-meminfo.txt').write_bytes(original_adb('shell', 'dumpsys', 'meminfo', recorder.PACKAGE))
            (out/'pre-click-guest-meminfo.txt').write_bytes(original_adb('shell', 'cat', '/proc/meminfo'))
            guest_pressure('pre-click')
        if args.keep_player and arguments == ('shell', 'input', 'keyevent', '4'):
            return b''
        return original_adb(*arguments, **kwargs)

    recorder.adb = adb
    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    status = 'failed'
    perfetto_remote = '/data/misc/perfetto-traces/startup-bounded.pftrace'
    perfetto_started = False
    def start_perfetto():
        nonlocal perfetto_started
        # Bound guest tracing to 20 seconds and 32 MiB. No sampling profiler,
        # memory dump, second emulator, or compiler is started.
        config = metadata.with_suffix('.perfetto.pbtxt')
        config.write_text('''buffers { size_kb: 32768 fill_policy: RING_BUFFER }
duration_ms: 20000
data_sources { config { name: "linux.ftrace" ftrace_config {
  ftrace_events: "sched/sched_switch"
  ftrace_events: "sched/sched_waking"
  atrace_categories: "gfx"
  atrace_categories: "view"
  atrace_categories: "video"
  atrace_categories: "audio"
  atrace_categories: "binder_driver"
  atrace_apps: "com.personal.piliplus"
  compact_sched { enabled: true }
} } }
data_sources { config { name: "linux.process_stats" process_stats_config {
  scan_all_processes_on_start: true
} } }
data_sources { config { name: "android.log" android_log_config {
  filter_tags: "StartupTest"
} } }
''', encoding='utf-8')
        original_adb('push', str(config), '/data/misc/perfetto-configs/startup-bounded.pbtxt')
        original_adb('shell', 'perfetto', '--background-wait', '--txt', '-c',
                     '/data/misc/perfetto-configs/startup-bounded.pbtxt', '-o', perfetto_remote)
        perfetto_started = True
    try:
        original_adb('shell', 'settings', 'put', 'system', 'show_touches', '1')
        if args.cold_app:
            original_adb('shell', 'am', 'force-stop', recorder.PACKAGE)
        recorder.capture(label, args.index, args.seconds, [990, 135], False, True,
                         verify_search_uri=args.verify_search_uri,
                         before_recording=start_perfetto if args.perfetto else None)
        if args.collect_standby:
            (out/'post-capture-guest-meminfo.txt').write_bytes(original_adb('shell', 'cat', '/proc/meminfo'))
            guest_pressure('post-capture')
        (out/'native-plugin.log').write_bytes(original_adb('logcat', '-d', '-v', 'epoch', '-s', 'media_kit'))
        if perfetto_started:
            original_adb('pull', perfetto_remote, str(out/'startup-bounded.pftrace'))
        status = 'recorded; pixel and foreground review required'
    finally:
        done.set()
        watcher.join(timeout=3)
        for key, value in old.items():
            original_adb('shell', 'settings', *(
                ['delete', 'system', key] if value == 'null'
                else ['put', 'system', key, value]))
        metadata.write_text(json.dumps({
            'status': 'aborted: host memory pressure' if abort.is_set() else status,
            'serial': args.serial, 'apkSha256': installed_sha,
            'appForceStoppedBeforeSearch': args.cold_app,
            'mediaPreloaded': False, 'leftVideoPageAlive': args.keep_player,
            'searchUriVerifiedBeforeTiming': args.verify_search_uri,
            'playerRetention': 'verify previous.playerId in source.prepare.begin',
            'timingEntry': 'tap on in-app search button submitting a video URI',
            'recordingFolder': str(out), 'memorySamples': samples,
            'visibleMotionSeconds': None,
            'collectStandbyBeforeMeasuredClick': args.collect_standby,
            'memoryPolicy': {'minimumCaptureStartHeadroomGiB': 8,
                             'abortHeadroomGiB': 3,
                             'buildOrEmulatorLaunchMinimumHeadroomGiB': 10},
        }, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
