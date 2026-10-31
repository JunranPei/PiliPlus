"""Bounded profile-only Flutter/Skia timeline collection through VM service."""
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

import websocket


class StartupVmTimeline:
    def __init__(self, adb, output: Path, pid: str, logcat: str):
        self.adb = adb
        self.output = output
        self.socket = None
        self.local_port = None
        self.original_streams = None
        self.sequence = 0
        self.stopped = False
        self.report = {'profileOnly': True, 'releaseSpeedComparable': False,
                       'pid': str(pid), 'boundedWindowSeconds': 6}
        lines = [line for line in logcat.splitlines()
                 if len(line.split()) > 2 and line.split()[1] == str(pid)
                 and 'The Dart VM service is listening on ' in line]
        if len(lines) != 1:
            raise RuntimeError('Expected one VM service announcement for the current PID')
        match = re.search(r'http://127\.0\.0\.1:\d+/[^\s]*/', lines[0])
        if not match:
            raise RuntimeError('Malformed local VM service announcement')
        uri = urlsplit(match.group())
        try:
            self.local_port = adb('forward', 'tcp:0', f'tcp:{uri.port}').decode().strip()
            if not self.local_port.isdigit():
                raise RuntimeError('ADB did not return a local forwarding port')
            self.socket = websocket.create_connection(
                f'ws://127.0.0.1:{self.local_port}{uri.path}ws', timeout=12,
                http_no_proxy=['127.0.0.1', 'localhost'], suppress_origin=True)
            flags = self.call('getVMTimelineFlags')
            self.report['originalFlags'] = flags
            self.original_streams = flags['recordedStreams']
            # Systrace owns its own storage and rejects getVMTimeline. This mode
            # deliberately does not launch trace-systrace or depend on its slices.
            if flags.get('recorderName', '').lower() in ('systrace', 'fuchsia', 'macos'):
                raise RuntimeError('OS timeline recorder cannot return VM timeline events')
            self.call('setVMTimelineFlags', {'recordedStreams': ['Dart', 'Embedder', 'GC']})
            self.report['enabledFlags'] = self.call('getVMTimelineFlags')
            if 'Embedder' not in self.report['enabledFlags']['recordedStreams']:
                raise RuntimeError('Embedder timeline stream was not enabled')
            self.call('clearVMTimeline')
            self.report['startVmMicros'] = self.call('getVMTimelineMicros')
            self.save()
        except BaseException:
            self.close()
            raise

    def call(self, method, params=None):
        self.sequence += 1
        identity = str(self.sequence)
        self.socket.send(json.dumps({'jsonrpc': '2.0', 'id': identity,
                                     'method': method, 'params': params or {}}))
        while True:
            response = json.loads(self.socket.recv())
            if response.get('id') != identity:
                continue
            if 'error' in response:
                raise RuntimeError(f'VM {method}: {response["error"]}')
            return response['result']

    def stop(self):
        if self.stopped:
            return
        self.call('setVMTimelineFlags', {'recordedStreams': []})
        self.report['stopVmMicros'] = self.call('getVMTimelineMicros')
        timeline = self.call('getVMTimeline')
        (self.output/'vm-timeline.json').write_text(json.dumps(timeline), encoding='utf-8')
        self.report['eventCount'] = len(timeline.get('traceEvents', []))
        self.stopped = True
        self.save()

    def save(self):
        (self.output/'vm-timeline-collection.json').write_text(
            json.dumps(self.report, indent=2), encoding='utf-8')

    def close(self):
        if self.socket is not None:
            try:
                if self.original_streams is not None:
                    self.call('setVMTimelineFlags', {'recordedStreams': self.original_streams})
                    self.report['streamsRestored'] = True
            except Exception as error:
                self.report['restoreError'] = str(error)
            finally:
                self.socket.close()
                self.socket = None
        if self.local_port and self.local_port.isdigit():
            self.adb('forward', '--remove', f'tcp:{self.local_port}', check=False)
            self.report['forwardRemoved'] = True
            self.local_port = None
        self.save()
