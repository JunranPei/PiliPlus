"""Bounded resource settling and verified reuse for native seek experiments."""
from pathlib import Path
import importlib.util
import json
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('capture_memory',
    ROOT/'diagnostics/startup-20261018/rollback-baseline/capture_timing.py')
memory_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory_module)

def wait_capture_memory(output, minimum_commit_gib=7, minimum_ram_gib=6, maximum_wait_seconds=50):
    samples=[]
    began=time.monotonic()
    consecutive=0
    while True:
        sample=memory_module.memory()
        samples.append(sample)
        # Match the already calibrated lean-short gate. The extra0.2GiB here
        # rejected the first three valid samples in session86 even though the
        # capture gate required7/6 and checks again immediately before input.
        consecutive=consecutive+1 if sample['commitHeadroomGiB']>=minimum_commit_gib and sample['availableRamGiB']>=minimum_ram_gib else 0
        report={'samples':samples,'elapsedSeconds':time.monotonic()-began,'ready':consecutive>=3,
            'captureProfile':f'{minimum_commit_gib} GiB commit /{minimum_ram_gib} GiB physical; three consecutive samples, capture rechecks before input'}
        output.write_text(json.dumps(report,indent=2),encoding='utf-8')
        if report['ready']:return
        if time.monotonic()-began>=maximum_wait_seconds:
            raise RuntimeError(f'Resource headroom did not settle within{maximum_wait_seconds}seconds; no measured input')
        time.sleep(2.5)

def install_if_different(adb, apk, expected, output):
    package=subprocess.run(adb+['shell','pm','path','com.personal.piliplus'],capture_output=True,timeout=12)
    remote=package.stdout.decode().strip().removeprefix('package:')
    installed=None
    if package.returncode==0 and remote:
        result=subprocess.run(adb+['shell','sha256sum',remote],capture_output=True,timeout=15)
        if result.returncode==0:installed=result.stdout.decode().split()[0]
    output.write_text(json.dumps({'expectedSha256':expected,'installedSha256':installed,
        'reusedExactApk':installed==expected},indent=2),encoding='utf-8')
    if installed!=expected:
        with output.with_suffix('.install.txt').open('xb') as log:
            subprocess.run(adb+['install','-r',str(apk)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=45)
