"""Save the authorized pre-stacking checkpoint without adding local binaries."""
from pathlib import Path
import collections
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[3]
BASE = Path(__file__).resolve().parent
OUT = ROOT / 'diagnostics/checkpoints/resume-before-r69-stack-20261101'
OUT.mkdir(parents=True, exist_ok=True)

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT).decode('utf-8')

assert not git('diff', '--cached', '--name-only').strip(), 'Preserve existing staging'
paths = set(git('diff', '--name-only').splitlines())
untracked = git('ls-files', '--others', '--exclude-standard', '--', 'lib', 'android', 'tool').splitlines()
unrelated = {'media3_controls_regression.py', 'media3_enable_probe_audio.py', 'mpv_focused_pixel_review.py'}
paths.update(p for p in untracked if Path(p).name not in unrelated)
paths.update(p.relative_to(ROOT).as_posix() for p in (ROOT / 'test').rglob('*.dart')
             if not p.name.startswith('pip_'))

records = [*BASE.glob('*.md'), BASE/'net-gains.json', BASE/'update-net-gains.py', Path(__file__)]
records += [BASE/n for n in ['review-async-input-app87.py', 'review-async-wait-stacked.py',
    'review-wait89-delivery.py', 'record-stage88-findings.py', 'review-stage88-polling.py',
    'review-codec-stages88-isolated.py', 'analyze-async-input-spans.py',
    'run-async-input-observed.py', 'run-async-wait-stacked.py', 'run-async-input-cancel.py',
    'run-async-input-seek.py', 'native_sidx_host.py', 'active-continuation.json']]
net = json.loads((BASE/'net-gains.json').read_text(encoding='utf-8'))
for row in net['rows']:
    cohort = BASE/row['cohort']
    records += [p for p in [cohort/'completed-samples.json', cohort/'net-gains-reviewed.json',
        cohort/'device-reviewed.json', cohort/'regressions-and-interruption-reviewed.json', cohort/'plan.json'] if p.exists()]
for cohort in ['common-baseline-observed-01', 'async-input-cancel-01', 'async-input-seek-01',
        'codec-stages-native-spans-02', 'native-async-input-integration-01']:
    records += list((BASE/cohort).glob('*reviewed.json'))
records += [BASE/'async-wait-stacked-plan.json', BASE/'async-input-candidate.build.json',
    BASE/'decode-only-candidate.build.json']
native = BASE/'native-async-input-integration-01'
records += [p for p in native.iterdir() if p.is_file() and p.suffix in {'.py', '.h', '.java', '.before', '.after'}]
for name in ['plan.json', 'source-provenance.json', 'native-build-01.json', 'repack-verified.json']:
    records.append(native/name)
records = [p for p in records if p.is_file()]
paths.update(p.relative_to(ROOT).as_posix() for p in records)

artifacts = []
for p in [ROOT/'output/releases/PiliPlus-fastest-resume-r69-arm64-release-20261031.apk',
        BASE/'async-input-candidate.apk', BASE/'async-input-candidate.sources.zip',
        native/'libmpv-async-input-x86_64.so']:
    assert p.is_file(), p
    artifacts.append({'path': p.relative_to(ROOT).as_posix(), 'bytes': p.stat().st_size,
        'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'retainedLocally': True})

# Raw capture files remain intact. Index the evidence used in the net-gain table.
captures = []
for row in net['rows']:
    for sample in row['samples']:
        folder = BASE/row['cohort']/sample['label']
        for name in ['capture.json', 'logcat.txt', 'return-cleanup-reviewed.json', 'continuity-analysis/summary.json']:
            p = folder/name
            if p.is_file():
                captures.append({'path': p.relative_to(ROOT).as_posix(), 'bytes': p.stat().st_size,
                    'sha256': hashlib.sha256(p.read_bytes()).hexdigest()})

manifest = {'parentHead': git('rev-parse', 'HEAD').strip(), 'branch': git('branch', '--show-current').strip(),
    'purpose': 'User requested a commit before adding later positive-gain changes to round69.',
    'goalComplete': False, 'next': 'Use round69 as common baseline; measure each later candidate and its interactions. Do not sum historical gains.',
    'artifactsRetainedLocally': artifacts, 'rawEvidenceRetainedLocally': captures,
    'files': [{'path': p, 'bytes': (ROOT/p).stat().st_size,
        'sha256': hashlib.sha256((ROOT/p).read_bytes()).hexdigest()} for p in sorted(paths)]}
(OUT/'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
(OUT/'README.md').write_text('''# 第69轮重新叠加之前的保存点

用户要求先提交当前状态，再以第69轮为共同基线逐项叠加后续正净收益候选。

保存当前应用源代码、起播监听和采集工具、相关回归测试、原生异步送包实现及其构建源码快照，以及各轮净收益和完整正式样本汇总。未宣称0.8秒目标达成，也未将不同轮次差值相加。

历史最快单次是第69轮1560.7618毫秒；该轮候选两条中位数1683.9909毫秒。第85轮候选中位数1636.2641毫秒，第87轮1666.6469毫秒，尚无充分同批证据给这些版本作整体速度排名。第89轮回调等待叠加变慢，保持关闭。

手机ARM64 release包已交付；本次不重新编译。原始APK、源码ZIP、系统跟踪、日志和旧失败样本保留在本机原路径，manifest.json记录主要构建产物和所有净收益队列关键原始记录的SHA256。大体积产物、SDK、缓存及更早PiP截图未加入本次提交。

此前构建、控制条件测试和实机模拟器记录见各轮报告。此次为保存当前研究状态，不新增“全功能通过”或“稳定提速”结论。后续代码修改必须在这个保存点之后进行。
''', encoding='utf-8')
paths.update(p.relative_to(ROOT).as_posix() for p in OUT.glob('*') if p.is_file())
path_file = OUT/'staging-paths.txt'
path_file.write_text('\n'.join(sorted(paths))+'\n', encoding='utf-8')
paths.add(path_file.relative_to(ROOT).as_posix())
path_file.write_text('\n'.join(sorted(paths))+'\n', encoding='utf-8')
print(json.dumps({'files': len(paths), 'bytes': sum((ROOT/p).stat().st_size for p in paths),
    'extensions': dict(collections.Counter(Path(p).suffix for p in paths)),
    'manifest': str(OUT/'manifest.json'), 'paths': str(path_file)}, ensure_ascii=False))
