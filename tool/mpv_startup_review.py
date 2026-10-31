"""Extract diagnostic intervals, separately from manually reviewed pixel times."""
import argparse
from collections import Counter
import json
from pathlib import Path


def summarize(folder):
    result = json.loads((folder / 'result.json').read_text(encoding='utf8'))
    label = folder.name
    log = (folder / 'playback.log').read_text(encoding='utf8')
    line = next(x for x in log.splitlines() if 'open-request ' + label in x)
    start = float(line.split()[0]) * 1_000_000
    cid = result['video']['cid']
    points = {}
    commands = []
    buffers = []
    positions = []
    dimensions = []
    supplements = []
    event_counts = Counter()
    for path in (folder / 'traces').glob('flutter-*'):
        for line in path.open(encoding='utf8'):
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            dt = (event.get('utcUs', 0) - start) / 1000
            if not 0 <= dt <= result['recordedPlaybackSeconds'] * 1000:
                continue
            source = event.get('source', {})
            if event.get('cid', source.get('cid')) != cid:
                continue
            name = event.get('event', '')
            event_counts[name] += 1
            if name in ('source.url.begin', 'source.url.response',
                        'source.open.begin', 'command.play', 'output.stable',
                        'ui.frameReady.after', 'query.preferences.begin',
                        'query.preferences.end', 'query.primary.begin',
                        'query.primary.end', 'query.supplement.begin',
                        'query.supplement.end'):
                points.setdefault(name, round(dt, 1))
            if name.startswith('command.') and name != 'command.play':
                commands.append({'ms': round(dt, 1), 'event': name})
            if name == 'media.buffering':
                buffers.append({'ms': round(dt, 1), 'value': event.get('value')})
            player = event if 'positionMs' in event else source.get('player', {})
            pos = player.get('positionMs')
            if isinstance(pos, (int, float)):
                positions.append((round(dt, 1), pos))
            if name == 'media.videoParams':
                dimensions.append({k: v for k, v in event.items()
                                   if k not in ('source', 'utcUs', 'seq', 'elapsedUs')})
            if name.startswith('query.supplement.'):
                supplements.append({'ms': round(dt, 1), **{
                    k: v for k, v in event.items()
                    if k in ('event', 'quality', 'deferred', 'current', 'type')}})
    return {'label': label, 'cid': cid, 'entry': result['entry'],
            'pid': result['traces']['pid'], 'pointsMsFromRequest': points,
            'otherCommands': commands, 'bufferingChanges': buffers,
            'lastObservedPosition': positions[-1] if positions else None,
            'maxObservedPositionMs': max((p for _, p in positions), default=None),
            'videoParameters': dimensions, 'supplementEvents': supplements,
            'errorEvents': {k: v for k, v in event_counts.items() if 'error' in k},
            'visibleMotionMs': result.get('visibleMotionMs'),
            'warning': 'Diagnostic times do not establish visible video presentation. '
                       'Missing buffering events do not prove absence of stalls.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folders', nargs='+', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    rows = [summarize(folder) for folder in args.folders]
    args.output.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf8')
    for row in rows:
        print(json.dumps({k: v for k, v in row.items()
                          if k not in ('videoParameters', 'warning')}, ensure_ascii=False))
