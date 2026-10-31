"""Resolve a touch target from Android's dispatcher window regions, without pixels."""
import re


def input_target(dump, x, y, display_id=0):
    windows = []
    for line in dump.splitlines():
        match = re.match(r'\s+\d+: name=(.*?), id=\d+, displayId=(\d+), inputConfig=(.*?), alpha=', line)
        if match is None or int(match[2]) != display_id:
            continue
        name, flags = match[1], match[3]
        if any(flag in flags.split(' | ') for flag in ('NOT_TOUCHABLE','NO_INPUT_CHANNEL','SPY')):
            continue
        region = re.search(r'touchableRegion=(.*?), ownerPid=', line)
        if region is None:
            raise ValueError('Unrecognized touch region: '+name)
        rectangles = [tuple(map(int,values)) for values in re.findall(
            r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]',region[1])]
        if not rectangles and region[1] != '<empty>':
            raise ValueError('Unrecognized touchableRegion format: '+name)
        windows.append(name)
        if any(left <= x < right and top <= y < bottom for left,top,right,bottom in rectangles):
            return {'window':name,'displayId':display_id,'tap':[x,y],'rectangles':rectangles,
                    'eligibleWindowsVisited':windows}
    raise ValueError('No dispatcher window owns the intended touch coordinate')
