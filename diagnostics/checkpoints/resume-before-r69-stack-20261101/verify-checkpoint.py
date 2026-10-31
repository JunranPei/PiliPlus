from pathlib import Path
import hashlib
import json
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
BASE = ROOT/'diagnostics/startup-20261030/parallel-audio'
state_path = BASE/'active-continuation.json'
state = json.loads(state_path.read_text())
state.update(next='Commit current state first, then use round69 as common baseline and add later positive-gain candidates one at a time. User redirected pending slow-body experiment; no round90 build/capture has started.',
    nextRunner=None, buildHandle=None, captureHandle=None,
    previousTurn='Progress:89 completed and negative configuration disabled; user requested pre-stacking Git checkpoint.')
state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')

# Recover exact effective native sources from preserved source archives where present.
meta = json.loads((BASE/'async-input-candidate.build.json').read_text())
required = meta['nativeLibraryOverride']['nativeSourceHashes']
by_hash = {v:k for k,v in required.items()}
matched = {}
with zipfile.ZipFile(BASE/'async-input-candidate.sources.zip') as archive:
    for info in archive.infolist():
        if info.is_dir() or info.file_size > 3_000_000:
            continue
        data = archive.read(info)
        digest = hashlib.sha256(data).hexdigest()
        if digest in by_hash:
            name = by_hash[digest]
            destination = OUT/'native-sources'/name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            matched[name] = {'archiveEntry': info.filename, 'sha256': digest}
for folder in BASE.glob('native-*'):
    if not folder.is_dir():
        continue
    for source in folder.rglob('*'):
        if not source.is_file() or source.suffix not in {'.c', '.h', '.after', '.before', '.baseline'} or source.stat().st_size > 3_000_000:
            continue
        data = source.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest in by_hash and by_hash[digest] not in matched:
            name = by_hash[digest]
            destination = OUT/'native-sources'/name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            matched[name] = {'localSource': source.relative_to(ROOT).as_posix(), 'sha256': digest}
(OUT/'native-source-recovery.json').write_text(json.dumps({'matched': matched,
    'notEmbeddedInArchive': {k:v for k,v in required.items() if k not in matched},
    'buildVolumeRemainsUnmodified': True}, indent=2)+'\n')

path_file = OUT/'staging-paths.txt'
paths = set(path_file.read_text().splitlines())
paths.update(p.relative_to(ROOT).as_posix() for p in OUT.rglob('*') if p.is_file())
patterns = [r'(?i)SESSDATA[=:][^\s\x22\x27]{8,}',
    r'(?i)access_token[=:][^\s\x22\x27]{12,}',
    r'(?i)refresh_token[=:][^\s\x22\x27]{12,}',
    r'(?i)Bearer [A-Za-z0-9_.-]{20,}', r'BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY']
hits = []
for name in sorted(paths):
    data = (ROOT/name).read_text(encoding='utf-8', errors='replace')
    found = [i for i,pattern in enumerate(patterns) if re.search(pattern, data)]
    if found:
        hits.append({'path': name, 'patternIds': found})
assert not hits, json.dumps(hits)
manifest_file = OUT/'manifest.json'
manifest = json.loads(manifest_file.read_text(encoding='utf-8'))
manifest['files'] = [{'path': name, 'bytes': (ROOT/name).stat().st_size,
    'sha256': hashlib.sha256((ROOT/name).read_bytes()).hexdigest()} for name in sorted(paths)
    if name not in {manifest_file.relative_to(ROOT).as_posix(), path_file.relative_to(ROOT).as_posix()}]
manifest_file.write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
path_file.write_text('\n'.join(sorted(paths))+'\n', encoding='utf-8')
print(json.dumps({'files': len(paths), 'nativeRecovered': len(matched),
    'nativeMissing': len(required)-len(matched), 'credentialPatternHits': hits}))
