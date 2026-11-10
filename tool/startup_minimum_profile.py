"""One versioned observer configuration for all minimum-interference scores."""
PROFILE_ID = 'minimum-startup-v2'
DEFINES = {
    'BENCHMARK_PREFLIGHT': 'true',
    'MINIMUM_STARTUP_BENCHMARK': 'true',
    'PLAYBACK_TRACE': 'true',
    'PLAYBACK_TRACE_GEOMETRY': 'false',
    'PLAYBACK_TRACE_TEXTURE': 'true',
    'PLAYBACK_TRACE_FRAMES': 'false',
    # The frozen native observer uses this to emit the FIRST distinct positive
    # image even after >4 blank/old callbacks. Disabling it can miss that image.
    # It remains sparse: no transform matrices or per-frame JSON/file writes.
    'PLAYBACK_TRACE_CONTINUITY': 'true',
    'PLAYBACK_TRACE_DURATION_MS': '60000',
    'PLAYBACK_NETWORK_TRACE': 'false',
    'STARTUP_TRANSFER_TRACE': 'false',
    'STARTUP_WAIT_TRACE': 'false',
    'RESUME_STAGE_TIMING': 'false',
    'STARTUP_TIMING': 'false',
}

def validate_minimum_build(build):
    flags = dict(item.split('=', 1) for item in build.get('defines', []) if '=' in item)
    mismatches = {key: flags.get(key) for key, value in DEFINES.items() if flags.get(key) != value}
    if build.get('buildMode') != 'release' or mismatches:
        raise ValueError(f'{PROFILE_ID} requires the fixed release observation flags: {mismatches}')
    if any(flags.get(key) == 'true' for key in (
            'PLAYBACK_STARTUP_DEEP', 'PLAYBACK_STARTUP_VERBOSE',
            'TRACE_STARTUP_TEXT_INVENTORY', 'PLAYBACK_FULL_PROFILE')):
        raise ValueError('Detailed instrumentation is not a minimum-startup score')
    return {'name': PROFILE_ID, 'duringMeasurementHostSampling': False,
            'resourceThresholds': False, 'nativeTextureObserver': 'unchanged sparse exact-first-positive',
            'continuousPlaybackAcceptance': False}
