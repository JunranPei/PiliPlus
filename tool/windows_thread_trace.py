"""Bounded, read-only Windows thread snapshots for the owned QA emulator.

Uses Microsoft's documented SystemProcessInformation layout. Sampling is not an
ETW scheduling trace and cannot identify a lock owner or recover a call stack.
No thread is suspended. Unrelated processes are not retained in the output.
"""
import ctypes as C
import gzip
import json
import os
from pathlib import Path
import threading
import time

import psutil

U32, I32, I64, PTR = C.c_uint32, C.c_int32, C.c_int64, C.c_void_p


class UnicodeString(C.Structure):
    _fields_ = [('length', C.c_uint16), ('maximum', C.c_uint16), ('buffer', PTR)]


class ProcessInfo(C.Structure):
    _fields_ = [('next', U32), ('count', U32), ('reserved1', C.c_byte * 48),
                ('name', UnicodeString), ('priority', I32), ('pid', PTR), ('parent', PTR),
                ('handles', U32), ('session', U32), ('reserved3', PTR),
                ('peakVirtual', C.c_size_t), ('virtual', C.c_size_t), ('reserved4', U32),
                ('peakWorking', C.c_size_t), ('working', C.c_size_t), ('reserved5', PTR),
                ('paged', C.c_size_t), ('reserved6', PTR), ('nonpaged', C.c_size_t),
                ('pagefile', C.c_size_t), ('peakPagefile', C.c_size_t),
                ('private', C.c_size_t), ('reserved7', I64 * 6)]


class ThreadInfo(C.Structure):
    _fields_ = [('kernel', I64), ('user', I64), ('created', I64), ('waitTime', U32),
                ('start', PTR), ('pid', PTR), ('tid', PTR), ('priority', I32),
                ('basePriority', I32), ('switches', U32), ('state', U32), ('reason', U32)]


class WindowsThreadTrace:
    columns = ['tid', 'createTime100ns', 'kernel100ns', 'user100ns',
               'contextSwitches', 'state', 'waitReason', 'cycles']

    def __init__(self, pid, output, interval=.1, max_seconds=12):
        assert os.name == 'nt' and C.sizeof(PTR) == 8
        assert C.sizeof(ProcessInfo) == 256 and C.sizeof(ThreadInfo) == 80
        assert .01 <= interval <= 1 and 1 <= max_seconds <= 60
        self.process = psutil.Process(pid)
        self.created = self.process.create_time()
        self.output = Path(output)
        assert not self.output.exists()
        self.interval, self.max_seconds = interval, max_seconds
        self.rows, self.names, self.handles = [], {}, {}
        self.errors = []
        self.done = threading.Event()
        self.nt = C.WinDLL('ntdll').NtQuerySystemInformation
        self.nt.argtypes = [U32, PTR, U32, C.POINTER(U32)]
        self.nt.restype = I32
        self.kernel = C.WinDLL('kernel32', use_last_error=True)
        self.kernel.OpenThread.argtypes = [U32, C.c_bool, U32]
        self.kernel.OpenThread.restype = PTR
        self.kernel.GetThreadDescription.argtypes = [PTR, C.POINTER(PTR)]
        self.kernel.GetThreadDescription.restype = I32
        self.kernel.QueryThreadCycleTime.argtypes = [PTR, C.POINTER(C.c_uint64)]
        self.kernel.QueryThreadCycleTime.restype = C.c_bool
        self.kernel.CloseHandle.argtypes = [PTR]
        self.kernel.LocalFree.argtypes = [PTR]
        self.buffer = C.create_string_buffer(2 * 1024 * 1024)

    def snapshot(self):
        begin = time.perf_counter_ns()
        needed = U32()
        for attempt in range(3):
            status = self.nt(5, self.buffer, len(self.buffer), C.byref(needed))
            if status == 0:
                break
            if status & 0xffffffff != 0xc0000004:
                raise OSError(f'NtQuerySystemInformation failed: {status & 0xffffffff:08x}')
            self.buffer = C.create_string_buffer(max(len(self.buffer) * 2, needed.value + 65536))
        assert status == 0 and needed.value <= len(self.buffer)
        offset = 0
        threads = []
        while offset + C.sizeof(ProcessInfo) <= needed.value:
            process = ProcessInfo.from_buffer(self.buffer, offset)
            if process.pid == self.process.pid:
                assert process.count < 4096
                base = offset + C.sizeof(ProcessInfo)
                assert base + process.count * C.sizeof(ThreadInfo) <= needed.value
                for n in range(process.count):
                    thread = ThreadInfo.from_buffer(self.buffer, base + n * C.sizeof(ThreadInfo))
                    assert thread.pid == self.process.pid and thread.tid and thread.state < 16
                    identity = f'{thread.tid}:{thread.created}'
                    if identity not in self.handles:
                        handle = self.kernel.OpenThread(0x0800, False, thread.tid)
                        self.handles[identity] = handle
                        name = PTR()
                        description = ''
                        if handle and self.kernel.GetThreadDescription(handle, C.byref(name)) == 0 and name:
                            description = C.wstring_at(name)
                            self.kernel.LocalFree(name)
                        self.names[identity] = {'description': description,
                                                'startAddress': hex(thread.start or 0),
                                                'openError': None if handle else C.get_last_error()}
                    cycles = C.c_uint64()
                    ok = self.handles[identity] and self.kernel.QueryThreadCycleTime(
                        self.handles[identity], C.byref(cycles))
                    threads.append([thread.tid, thread.created, thread.kernel, thread.user,
                                    thread.switches, thread.state, thread.reason,
                                    cycles.value if ok else None])
                break
            if not process.next:
                raise ProcessLookupError(self.process.pid)
            assert process.next >= C.sizeof(ProcessInfo)
            offset += process.next
        assert threads, 'Target process missing from snapshot'
        return {'beginNs': begin, 'endNs': time.perf_counter_ns(), 'threads': threads}

    def start(self):
        assert self.process.create_time() == self.created
        self.rows.append(self.snapshot())  # Resolve existing thread names before input.
        self.start_ns = time.perf_counter_ns()
        self.worker = threading.Thread(target=self._run, name='qa-host-thread-sampler', daemon=True)
        self.worker.start()

    def _run(self):
        next_at = time.perf_counter()
        try:
            while not self.done.is_set() and time.perf_counter_ns() - self.start_ns < self.max_seconds * 1e9:
                self.rows.append(self.snapshot())
                next_at += self.interval
                self.done.wait(max(0, next_at - time.perf_counter()))
                if time.perf_counter() > next_at + self.interval:
                    next_at = time.perf_counter()
        except Exception as e:
            self.errors.append(f'{type(e).__name__}: {e}')

    def stop(self):
        self.done.set()
        self.worker.join(5)
        assert not self.worker.is_alive()
        for handle in self.handles.values():
            if handle:
                self.kernel.CloseHandle(handle)
        report = {'pid': self.process.pid, 'createTime': self.created,
                  'intervalMs': self.interval * 1000, 'maxSeconds': self.max_seconds,
                  'clock': 'Windows QueryPerformanceCounter via Python perf_counter_ns',
                  'columns': self.columns, 'threadNames': self.names, 'samples': self.rows,
                  'errors': self.errors,
                  'boundary': 'Read-only snapshots, not a lossless scheduling trace. Wait reasons are instantaneous. CPU times can be coarsely accounted. Cycle counts cannot be converted to elapsed time without additional assumptions. No stack or lock-owner evidence.'}
        with gzip.open(self.output, 'xt', encoding='utf-8') as f:
            json.dump(report, f, separators=(',', ':'))
        costs = sorted((r['endNs'] - r['beginNs'])/1e6 for r in self.rows)
        return {'samples': len(self.rows), 'errors': self.errors,
                'medianSnapshotMs': costs[len(costs)//2], 'maxSnapshotMs': max(costs)}
