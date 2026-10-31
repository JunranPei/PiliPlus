"""Run serialized ABBAAB APK comparisons on the already selected test emulator."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
parser.add_argument('--control', type=Path, required=True)
parser.add_argument('--candidate', type=Path, required=True)
parser.add_argument('--serial', default='emulator-5554')
parser.add_argument('--index', type=int, default=5)
parser.add_argument('--warmup', action='store_true')
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
base = ['adb', '-s', args.serial]
avd = subprocess.check_output(base+['emu','avd','name'],timeout=10).decode().splitlines()[0]
if avd != 'PiliPlusStartupIsolated_20261018':
    raise SystemExit('Refusing to install on unrelated device: '+avd)
sequence = ([('warmup',args.control)] if args.warmup else [])+[
    ('control',args.control), ('candidate',args.candidate), ('candidate',args.candidate),
    ('control',args.control), ('control',args.control), ('candidate',args.candidate)]
results = []
for number, (kind, apk) in enumerate(sequence):
    label = f'{number:02d}-{kind}'
    print(json.dumps({'event':'begin','run':label}),flush=True)
    with (out/(label+'-install.txt')).open('wb') as log:
        subprocess.run(base+['install','-r',str(apk.resolve())],check=True,timeout=45,
                       stdout=log,stderr=subprocess.STDOUT)
    with (out/(label+'.log')).open('wb') as log:
        result = subprocess.run([sys.executable,str(ROOT/'tool/capture_startup_listener.py'),
            str(out/label),'--serial',args.serial,'--index',str(args.index),'--apk',str(apk.resolve())],
            stdout=log,stderr=subprocess.STDOUT,timeout=180)
    if result.returncode:
        print(json.dumps({'event':'failed','run':label,'log':str(out/(label+'.log'))}),flush=True)
        raise SystemExit(result.returncode)
    summary = json.loads((out/label/'summary.json').read_text(encoding='utf-8'))
    times = {e['event']:e['afterInputMs'] for e in summary['milestones']}
    texture = summary['firstChangedTextureConsumedAfterInputMs']
    row = {'run':label,'kind':kind,'textureMs':texture,
           'apiMs':times['query.primary.end']-times['query.primary.begin'],
           'afterOpenMs':texture-times['source.open.begin'],
           'buffering':summary['buffering']}
    results.append(row)
    (out/'results.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    print(json.dumps(row),flush=True)
