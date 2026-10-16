"""Capture only a bounded startup trace to locate Android main-thread blocking."""
from pathlib import Path
import argparse
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--warm', action='store_true')
parser.add_argument('--index', type=int, default=6)
parser.add_argument('--label', default='startup')
args = parser.parse_args()
OUT = ROOT / 'diagnostics/startup-20261016/perfetto' / args.label
OUT.mkdir(parents=True, exist_ok=True)
ADB = ['adb', '-s', 'emulator-5554']
config = '''buffers { size_kb: 32768 fill_policy: RING_BUFFER }
duration_ms: 16000
data_sources { config { name: "linux.ftrace" ftrace_config {
  ftrace_events: "sched/sched_switch"
  ftrace_events: "sched/sched_waking"
  atrace_categories: "gfx"
  atrace_categories: "view"
  atrace_categories: "am"
  atrace_categories: "wm"
  atrace_categories: "dalvik"
  atrace_categories: "binder_driver"
  atrace_apps: "com.personal.piliplus"
} } }
data_sources { config { name: "linux.process_stats" process_stats_config { scan_all_processes_on_start: true } } }
data_sources { config { name: "android.log" } }
'''
(OUT / 'startup.pbtxt').write_text(config, encoding='utf-8')
def adb(*args):
    return subprocess.run(ADB + list(args), capture_output=True, check=True)

if not args.warm:
    adb('shell', 'am', 'force-stop', 'com.personal.piliplus')
with (OUT / 'capture.log').open('wb') as log:
    capture = subprocess.Popen(ADB + ['shell', 'perfetto', '--txt', '-c', '-',
        '-o', '/data/misc/perfetto-traces/pili-startup.perfetto-trace'], stdin=subprocess.PIPE, stdout=log, stderr=log)
    capture.stdin.write(config.encode('utf-8'))
    capture.stdin.close()
    time.sleep(.8)
    command = ['python', str(ROOT / 'tool/media3_startup_recording.py'),
        'perfetto-' + args.label, '--index', str(args.index), '--seconds', '10', '--no-back']
    if not args.warm:
        command.append('--cold')
    subprocess.run(command, check=True)
    capture.wait(timeout=25)
adb('pull', '/data/misc/perfetto-traces/pili-startup.perfetto-trace', str(OUT / 'startup.perfetto-trace'))
print('Captured startup trace', (OUT / 'startup.perfetto-trace').stat().st_size, flush=True)
adb('shell', 'input', 'keyevent', '4')
