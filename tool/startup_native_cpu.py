"""Bounded native stack sampling for explicitly authorized diagnostic APKs."""
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import uuid


class StartupNativeCpu:
    def __init__(self, adb, base, output: Path, pid: str, package: str, *, off_cpu=False,
                 scope='raster'):
        if scope not in ['raster', 'process']:
            raise ValueError('Unknown native sampling scope')
        frequency = 100 if scope == 'process' else 200
        self.adb = adb
        self.output = output
        self.process = None
        self.log = None
        self.reader = None
        self.closed = False
        self.report = {'profileOnly': scope == 'raster', 'diagnosticOnly': True,
                       'scope': scope, 'releaseSpeedComparable': False,
                       'pid': str(pid), 'durationSeconds': 8, 'frequencyHz': frequency,
                       'event': 'task-clock:u', 'callGraph': 'dwarf',
                       'offCpu': off_cpu,
                       'helperSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
        threads = adb('shell', 'ps', '-T', '-p', str(pid), '-o', 'TID,CMD').decode()
        (output/'native-cpu-threads.txt').write_text(threads, encoding='utf-8')
        tids = [line.split(maxsplit=1)[0] for line in threads.splitlines()
                if len(line.split(maxsplit=1)) == 2 and line.split(maxsplit=1)[1].strip().endswith('.raster')]
        if scope == 'raster' and (len(tids) != 1 or not tids[0].isdigit()):
            self.report['error'] = 'Expected exactly one native raster thread'
            self.save()
            raise RuntimeError('Expected exactly one native raster thread')
        if not str(pid).isdigit():
            raise ValueError('Invalid target PID')
        self.remote = '/data/local/tmp/pili-native-' + uuid.uuid4().hex + '.data'
        target = ['-t', tids[0]] if scope == 'raster' else ['-p', str(pid)]
        self.report.update(tid=tids[0] if scope == 'raster' else None, remote=self.remote)
        command = [*base, 'shell', '/system/bin/simpleperf', 'record', '--app', package,
                   *target, '-e', 'task-clock:u', '-f', str(frequency), '-g',
                   '--duration', '8', '--stdio-controls-profiling', '-o', self.remote]
        if scope == 'process':
            command += ['--clockid', 'monotonic']
            self.report['clock'] = 'monotonic'
        if off_cpu:
            command.append('--trace-offcpu')
        self.report['command'] = command
        try:
            self.log = (output/'native-cpu-record.log').open('wb')
            self.report['hostStartMonotonic'] = time.monotonic()
            self.process = subprocess.Popen(command, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=self.log,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            replies = queue.Queue()
            def read_control():
                with (output/'native-cpu-control.log').open('wb') as control:
                    for line in iter(self.process.stdout.readline, b''):
                        control.write(line)
                        control.flush()
                        if line.strip() == b'started':
                            replies.put(('started', time.monotonic()))
                    replies.put(('eof', time.monotonic()))
            self.reader = threading.Thread(target=read_control, daemon=True)
            self.reader.start()
            # AOSP emits this only from DoRecording after map/JIT setup and
            # event-file setup. Never substitute a fixed sleep for readiness.
            try:
                reply, received = replies.get(timeout=8)
            except queue.Empty as error:
                raise RuntimeError('Native recorder did not acknowledge readiness') from error
            if reply != 'started' or self.process.poll() is not None:
                raise RuntimeError('Native recorder exited before readiness acknowledgement')
            self.report['readyAcknowledged'] = True
            self.report['hostReadyMonotonic'] = received
            self.save()
        except Exception:
            self.close()
            raise

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            if self.process is not None:
                try:
                    self.report['returncode'] = self.process.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    # Only our host transport is terminated. The device command
                    # has its own eight-second duration; no global process kill.
                    self.process.terminate()
                    self.process.wait(timeout=3)
                    self.report['error'] = 'Recorder transport exceeded bounded wait'
                if self.report.get('returncode') == 0:
                    local = self.output/'native-cpu.data'
                    self.adb('pull', self.remote, str(local), timeout=15)
                    self.report['bytes'] = local.stat().st_size
                    self.report['sha256'] = hashlib.file_digest(local.open('rb'), 'sha256').hexdigest()
                    self.report['pulled'] = True
        except Exception as error:
            self.report['error'] = type(error).__name__ + ': ' + str(error)
        finally:
            if self.process is not None:
                if self.process.stdin is not None:
                    self.process.stdin.close()
                if self.reader is not None:
                    self.reader.join(timeout=2)
                if self.process.stdout is not None:
                    self.process.stdout.close()
            if self.log is not None:
                self.log.close()
            self.report['hostEndMonotonic'] = time.monotonic()
            self.save()

    def save(self):
        (self.output/'native-cpu-collection.json').write_text(
            json.dumps(self.report, indent=2), encoding='utf-8')
