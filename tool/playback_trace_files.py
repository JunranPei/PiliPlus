"""Associate trace files with the process generation announced by logcat."""
import re


def validate_trace_pair(names, pid=None):
    if len(names) != 2:
        raise ValueError('Exactly one Flutter/native trace pair is required')
    parsed = {}
    for name in names:
        match = re.fullmatch(r'(flutter|native)-(\d+)-(\d+)\.jsonl', name)
        if not match or match[1] in parsed:
            raise ValueError('Ambiguous trace file identity')
        parsed[match[1]] = (match[2], int(match[3]))
    if set(parsed) != {'flutter', 'native'}:
        raise ValueError('Missing one trace stream')
    flutter_pid, flutter_us = parsed['flutter']
    native_pid, native_ms = parsed['native']
    if flutter_pid != native_pid or (pid is not None and flutter_pid != str(pid)):
        raise ValueError('Trace process identifiers disagree')
    if abs(flutter_us / 1000 - native_ms) > 5000:
        raise ValueError('Flutter/native files belong to different generations')
    return sorted(names)


def announced_trace_pair(logcat, available_names, pid):
    """Use exact paths announced by this run, never the PID alone or mtime."""
    selected = []
    for kind, marker in [('native', 'configured file='),
                         ('flutter', '[PLAYBACK_TRACE_FILE] ')]:
        pattern = re.escape(marker) + r'[^\r\n]*?(' + kind + '-' + re.escape(str(pid)) + r'-\d+\.jsonl)'
        matches = re.findall(pattern, logcat)
        if not matches:
            raise ValueError(f'No current {kind} trace announcement for PID {pid}')
        selected.append(matches[-1])
    selected = validate_trace_pair(selected, pid)
    if available_names is not None and not set(selected).issubset(available_names):
        raise ValueError('An announced trace file is missing')
    return selected
