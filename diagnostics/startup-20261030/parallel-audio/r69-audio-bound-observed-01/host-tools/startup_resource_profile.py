"""Validated resource profiles; general/heavy captures retain the old limits."""
import time


def wait_startup_memory(read_memory, profile, maximum_wait_seconds, *,
                        observe=None, monotonic=time.monotonic, sleep=time.sleep):
    """Settle before measured input; retain the exact configured start floors."""
    if not 0 < maximum_wait_seconds <= 90:
        raise ValueError('Memory settling must be bounded to1..90seconds')
    began=monotonic();samples=[];consecutive=0
    while True:
        sample=read_memory();samples.append(sample)
        if observe is not None:observe(sample)
        ready=(sample['commitHeadroomGiB']>=profile['startCommitGiB']
               and sample['availableRamGiB']>=profile['startPhysicalGiB'])
        consecutive=consecutive+1 if ready else 0
        elapsed=monotonic()-began
        if consecutive>=3 or elapsed>=maximum_wait_seconds:
            return {'ready':consecutive>=3,'elapsedSeconds':elapsed,
                    'maximumWaitSeconds':maximum_wait_seconds,'samples':samples,
                    'startCommitGiB':profile['startCommitGiB'],
                    'startPhysicalGiB':profile['startPhysicalGiB']}
        sleep(min(2.5,maximum_wait_seconds-elapsed))


def startup_resource_profile(name, *, seconds, build, heavy):
    if name == 'default':
        commit = 8
    elif name in ('lean-short', 'lean-monitored'):
        defines = dict(item.split('=', 1) for item in build.get('defines', []) if '=' in item)
        if (not 22 <= seconds <= 25 or heavy or build.get('buildMode') != 'release'
                or build.get('leanTrace') is not True
                or defines.get('PLAYBACK_TRACE_GEOMETRY') != 'false'
                or any(defines.get(key) == 'true' for key in
                       ['PLAYBACK_STARTUP_DEEP', 'PLAYBACK_STARTUP_VERBOSE', 'TRACE_STARTUP_TEXT_INVENTORY'])):
            raise ValueError('lean-short requires22..25s lean release without geometry or heavy tracing')
        # Retain4GiB above the live abort floor.243 calibrated short lean runs
        # showed at most0.971GiB growth, including setup, failed captures and
        # return. See diagnostics/startup-20261030/parallel-audio/
        # native-sidx-cohort-01/lean-resource-calibration-02.json.
        commit = 7
    else:
        raise ValueError('Unknown resource profile')
    # Separate cohort, never silently relax lean-short or heavy captures.
    # 318 qualifying short captures: maximum whole-host physical drawdown
    # 2.476GiB including preparation/return/failures. A 5GiB start keeps
    # 3GiB above the stricter 2GiB runtime stop. See round65 calibration.
    monitored = name == 'lean-monitored'
    return {'name':name,'startCommitGiB':commit,'startPhysicalGiB':5 if monitored else 6,
        'abortCommitGiB':3,'abortPhysicalGiB':2 if monitored else 1}
