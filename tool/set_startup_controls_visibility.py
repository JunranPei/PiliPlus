"""Toggle long-lived controls only on the isolated startup QA AVD, using semantics."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
parser.add_argument('--enabled', choices=['true', 'false'], required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
base = ['adb', '-s', 'emulator-5554']
package = 'com.personal.piliplus'

def adb(*args, timeout=12):
    return subprocess.run(base+list(args), capture_output=True, check=True, timeout=timeout).stdout

assert adb('emu', 'avd', 'name').decode().splitlines()[0] == 'PiliPlusStartupIsolated_20261018'
sequence = 0

def hierarchy():
    global sequence
    data = adb('exec-out', 'uiautomator', 'dump', '/dev/tty')
    sequence += 1
    (out/f'{sequence:02d}.xml').write_bytes(data)
    text = data.decode('utf-8')
    return ET.fromstring(text[text.index('<?xml'):text.rindex('</hierarchy>')+12])

def find(root, label, *, prefix=False):
    return next((node for node in root.iter('node')
                 if (node.get('content-desc', '').startswith(label) if prefix
                     else node.get('content-desc') == label)), None)

def tap(node):
    if node is None:
        raise RuntimeError('Required accessible control missing; inspect saved XML')
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds', '')))
    adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))

# This is setup between captures, never part of a measured playback run.
adb('shell', 'am', 'force-stop', package)
adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.MAIN',
    '-c', 'android.intent.category.LAUNCHER', '-n', package+'/com.personal.piliplus.MainActivity')
root = hierarchy()
tap(find(root, '我的\n第', prefix=True))
root = hierarchy()
tap(find(root, '设置'))
root = hierarchy()
tap(find(root, '播放器设置', prefix=True))
root = hierarchy()
for _ in range(7):
    node = find(root, '延长播放控件显示时间', prefix=True)
    switch = next((n for n in node.iter('node') if n.get('class') == 'android.widget.Switch'), None) if node is not None else None
    if switch is not None:
        bounds = list(map(int, re.findall(r'\d+', switch.get('bounds', ''))))
        if bounds[1] > 210 and bounds[3] < 2250:
            break
    adb('shell', 'input', 'swipe', '520', '2000', '520', '1300', '350')
    root = hierarchy()
else:
    raise RuntimeError('Long controls setting not found in bounded scroll')

before = switch.get('checked') == 'true'
wanted = args.enabled == 'true'
record = {'setting': 'enableLongShowControl', 'before': before, 'requested': wanted,
          'avd': 'PiliPlusStartupIsolated_20261018', 'verified': False}
(out/'setting.json').write_text(json.dumps(record, indent=2))
if before != wanted:
    tap(switch)
    root = hierarchy()
    node = find(root, '延长播放控件显示时间', prefix=True)
    switch = next(n for n in node.iter('node') if n.get('class') == 'android.widget.Switch')
assert (switch.get('checked') == 'true') == wanted
adb('shell', 'sync')
record['verified'] = True
record['guestFilesystemSynced'] = True
(out/'setting.json').write_text(json.dumps(record, indent=2))
print(json.dumps(record), flush=True)
