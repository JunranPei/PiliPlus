"""Count named/unresolved native samples by observed startup window."""
from collections import Counter, defaultdict
import json
from pathlib import Path
import sys

NDK = Path('D:/Android_Studio_Sdk/ndk/28.2.13676358/simpleperf')
sys.path.insert(0, str(NDK))
from simpleperf_report_lib import GetReportLib

root = Path(__file__).resolve().parents[1]
out = root/'diagnostics/startup-20261019/runtime-profile'
trial = root/'diagnostics/startup-20261017/mpv-phase1/runtime-profile-d2-20261019-5'
lib = GetReportLib(str(trial/'native-perf.data'))
lib.SetSymfs(str(out/'binary_cache'))
lib.ShowIpForUnknownSymbol()
windows = [(0,1129.392,'primaryAPI'), (1129.392,1233.099,'prepare'),
           (1233.099,2463.602,'sourceOpenToCodecInit'),
           (2463.602,2816.523,'codecInitConfigureStart'),
           (2816.523,3081.008,'codecStartedToPostFlushInput'),
           (3081.008,3955.888,'postFlushInputToFirstSurfaceRelease')]
stats = defaultdict(lambda: {'self':Counter(), 'inclusive':Counter(), 'threads':Counter(),
                              'unresolvedLeaf':Counter(), 'leafLibraries':Counter()})
samples = []
while (sample := lib.GetNextSample()) is not None:
    leaf = lib.GetSymbolOfCurrentSample()
    chain = lib.GetCallChainOfCurrentSample()
    symbols = [leaf]+[chain.entries[i].symbol for i in range(chain.nr)]
    relative_ms = (sample.time-397741391000)/1e6
    labels = ['wholeNativeCapture']+[label for begin,end,label in windows if begin<=relative_ms<end]
    unresolved = leaf.symbol_addr == 0 or '[+' in leaf.symbol_name or leaf.symbol_name.startswith('0x')
    frames = [f'{s.symbol_name} ({Path(s.dso_name).name})' for s in symbols]
    samples.append({'primaryMs':relative_ms, 'tid':sample.tid, 'thread':sample.thread_comm,
                    'frames':frames})
    for label in labels:
        record = stats[label]
        record['self'][frames[0]] += 1
        record['inclusive'].update(set(frames))
        record['threads'][sample.thread_comm] += 1
        record['leafLibraries'][leaf.dso_name] += 1
        if unresolved:
            record['unresolvedLeaf'][leaf.dso_name] += 1
lib.Close()
report = {label:{key:counter.most_common(25) for key,counter in record.items()}
          for label,record in stats.items()}
(out/'native-window-summary.json').write_text(json.dumps(report,indent=2),encoding='utf8')
(out/'native-samples.json').write_text(json.dumps(samples),encoding='utf8')
print(json.dumps({label:{'samples':sum(record['self'].values()),
                        'topSelf':record['self'].most_common(4),
                        'topThreads':record['threads'].most_common(4),
                        'unresolvedLeafSamples':sum(record['unresolvedLeaf'].values())}
                  for label,record in stats.items()},indent=2))
