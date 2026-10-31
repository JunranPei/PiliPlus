"""Save rounds 90/91 and their exact source inputs before the next experiment."""
from pathlib import Path
import ast
import hashlib
import json
import shutil
import subprocess

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
BASE = ROOT / 'diagnostics/startup-20261030/parallel-audio'


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT).decode('utf-8')


def record(path):
    return {'path': path.relative_to(ROOT).as_posix(), 'bytes': path.stat().st_size,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


assert not git('diff', '--cached', '--name-only').strip(), 'Existing staging must be preserved'
assert not git('diff', '--name-only', '--', 'lib', 'android', 'tool').strip()
paths = {ROOT / p for p in git('diff', '--name-only').splitlines()}
assert all(p.is_relative_to(BASE) for p in paths)
for p in BASE.iterdir():
    if p.is_file() and p.suffix in {'.py', '.json', '.md'} and (
        'r69-' in p.name or p.name.startswith(('round90-', 'round91-'))
    ):
        paths.add(p)

cohorts = [p for p in BASE.glob('r69-audio-bound-*') if p.is_dir()
           and p.suffix != '.dart-build']
raw = []
for folder in cohorts:
    raw.extend(record(p) for p in sorted(folder.rglob('*')) if p.is_file())
    for p in folder.iterdir():
        if p.is_file() and p.suffix in {'.json', '.py'}:
            paths.add(p)
    for p in folder.glob('host-tools/*.py'):
        paths.add(p)
    for p in folder.glob('*/return-cleanup-reviewed.json'):
        paths.add(p)
    for p in folder.glob('*/continuity-analysis/summary.json'):
        paths.add(p)

build = BASE / 'r69-audio-bound-build-01'
for name in ['analyze.txt', 'focused-tests.txt', 'candidate-build.txt', 'control-build.txt']:
    paths.add(build / name)
review = json.loads((build / 'build-reviewed.json').read_text(encoding='utf-8'))
source_records = []
for relative, digest in review['plan']['stagedSourceHashes'].items():
    source = build / 'staged-sources' / relative
    assert hashlib.sha256(source.read_bytes()).hexdigest() == digest, source
    target = OUT / 'sources' / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    paths.add(target)
    source_records.append(record(target))
helper = build / 'startup_audio_decode_queue.dart'
assert hashlib.sha256(helper.read_bytes()).hexdigest() == review['plan']['helperSha256']
target = OUT / 'sources/lib/plugin/pl_player/playback/startup_audio_decode_queue.dart'
shutil.copyfile(helper, target)
paths.add(target)
source_records.append(record(target))

artifacts = [p for p in BASE.glob('r69-audio-bound-*')
             if p.is_file() and (p.suffix == '.apk' or p.name.endswith('.sources.zip'))]
artifacts += [BASE / 'native-codec-callback-01/libmpv-codec-callback-x86_64.so',
              ROOT / 'output/releases/PiliPlus-fastest-resume-r69-arm64-release-20261031.apk']
net = json.loads((BASE / 'net-gains.json').read_text(encoding='utf-8'))
rows = [r for r in net['rows'] if r['round'] in [90, 91]]
assert len(rows) == 2 and all(r['sampleCount'] == 8 for r in rows)
assert all(len(r['samples']) == 8 for r in rows)
assert review['pairedBuildPassed'] and review['workspaceRestored']

(OUT / '.gitattributes').write_text('sources/** -text whitespace=cr-at-eol\n', encoding='utf-8')
(build / '.gitattributes').write_text('analyze.txt -whitespace\n', encoding='utf-8')
paths.add(build / '.gitattributes')
(OUT / 'README.md').write_text('''# 第90、91轮叠加实验保存点

用户要求在下一轮改动前提交。此保存点保留第69轮共同基线上的音频解码限量及回调通知实验、构建输入、八条完整正式样本、取消/拖动/返回回归和净收益表。

第90轮：控制中位1812.4413ms，音频限量候选1622.3782ms，净收益190.0631ms；四对均快，保留组合。第91轮：控制1602.0736ms，加入回调候选1567.36205ms，净收益34.71155ms；两对快两对慢，保留可选候选，稳定性未确立。单次最低1314.2205ms，慢样本2466.2538ms完整计入。

计时为输入到首个正PTS纹理消费，不等于物理显示完成。原生选择61.5秒与实际消费位置分别记录。不同轮次收益不可直接相加；0.8秒未达到，组合与纯69的最终同条件对照仍未完成。手机ARM64包保持此前已交付版本。

sources/保存第90、91轮实际应用构建的四个替换源文件及音频限量辅助文件，按原始字节保留。其余源文件由构建元数据、源码归档和前一保存点追溯。第91轮只替换为第70轮回调原生库，两组使用同一APK切换回调。

首次取消触发过晚的记录和拖动监听聚合间隔误读的纠正均保留。完整原始日志、APK和源码ZIP留在本机原路径；manifest.json记录其SHA256。本提交保存实验状态，主应用源码仍是前一保存点状态；实验组合通过保存的构建脚本和sources还原。
''', encoding='utf-8')
paths.update([Path(__file__), OUT / '.gitattributes', OUT / 'README.md'])
for p in paths:
    if p.suffix == '.json':
        json.loads(p.read_bytes())
    elif p.suffix == '.py':
        ast.parse(p.read_text(encoding='utf-8-sig'), filename=str(p))
manifest = {
    'parentHead': git('rev-parse', 'HEAD').strip(),
    'branch': git('branch', '--show-current').strip(),
    'purpose': 'User requested commit before round92. Save completed rounds90/91.',
    'goalComplete': False,
    'sourceSnapshots': source_records,
    'artifactsRetainedLocally': [record(p) for p in artifacts],
    'rawEvidenceRetainedLocally': raw,
    'files': [record(p) for p in sorted(paths)],
    'validation': {'jsonParsed': True, 'pythonSyntaxParsed': True,
                   'all16FormalSamplesRetained': True, 'sourceHashesVerified': True,
                   'productWorkspaceUnchanged': True},
}
(OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
paths.update([OUT / 'manifest.json', OUT / 'staging-paths.txt'])
relative_paths = [p.relative_to(ROOT).as_posix() for p in sorted(paths)]
(OUT / 'staging-paths.txt').write_text('\n'.join(relative_paths) + '\n', encoding='utf-8')
print(json.dumps({'files': len(paths), 'bytes': sum(p.stat().st_size for p in paths),
                  'rawEvidenceFiles': len(raw), 'artifacts': len(artifacts),
                  'sourceSnapshots': len(source_records)}, ensure_ascii=False))
