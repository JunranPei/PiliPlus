"""Build the committed standby checkpoint and restore the dependency cache afterward."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile
from urllib.parse import urljoin, urlsplit
from urllib.request import url2pathname
from startup_native_library import NativeLibraryOverride

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--offline', action='store_true', help='Use already cached Gradle dependencies')
parser.add_argument('--observe-build-resources', action='store_true', help='Record current host resources without a pre-build threshold veto')
parser.add_argument('--wait-trace', action='store_true', help='Diagnostic only: record transform, decompression and account-persistence waits')
parser.add_argument('--target-platform', choices=['android-x64', 'android-arm64', 'android-arm'], default='android-x64', help='APK Flutter runtime architecture')
parser.add_argument('--native-mpv', type=Path, help='Experimental libmpv for this ABI; stage a separate verified JAR and restore the dependency definition after building')
parser.add_argument('--no-trace', action='store_true', help='User testing release with playback/timing collection disabled; preserves optimization defines')
parser.add_argument('--control', action='store_true', help='Same source, with startup standby disabled')
parser.add_argument('--deep', action='store_true', help='Bounded classified decoder/HTTP diagnosis; not a performance candidate')
parser.add_argument('--early-source', action='store_true', help='Prepare the selected real source while its page is mounting')
parser.add_argument('--parallel-audio', action='store_true', help='Start selected audio HTTP while mpv opens video; video transport unchanged')
parser.add_argument('--cancel-closed-media-delivery', action='store_true', help='Propagate closed native HTTP consumers to their own upstream response, preserving cached ranges and separate resume streams')
parser.add_argument('--parallel-resume-media', action='store_true', help='Also warm selected initialization ranges for exact nonzero resumes; subsequent seeks preserve origin Range semantics')
parser.add_argument('--isolated-media', action='store_true', help='Prefetch both selected tracks in a worker isolate')
parser.add_argument('--hedge-media', action='store_true', help='Try one API-provided backup for a slow selected video endpoint')
parser.add_argument('--hedge-audio', action='store_true', help='Try one API-provided backup for the exact selected audio track')
parser.add_argument('--hedge-delay-ms', type=int, default=120, help='Selected video backup delay; requires --hedge-media')
parser.add_argument('--omit-zero-start', action='store_true', help='Omit redundant mpv initial seek for new zero-position network loads')
parser.add_argument('--stream-forward', action='store_true', help='Forward each selected full response with one backpressured stream subscription')
parser.add_argument('--uncut-dash', action='store_true', help='Avoid unnecessary EDL segment resets for two complete network tracks')
parser.add_argument('--defer-auxiliary', action='store_true', help='Wait for playback readiness before automatic related/tags/author requests')
parser.add_argument('--prioritize-play-url', action='store_true', help='For known UGC CID, let play URL settle before fetching introduction; bounded at 500ms')
parser.add_argument('--autosync-zero', action='store_true', help='Android diagnostic comparison: use mpv default audio delay timing without smoothing; does not change saved preference')
parser.add_argument('--aaudio-first', action='store_true', help='Android diagnostic: prefer AAudio, preserving fallback and saved preference')
parser.add_argument('--audio-decode-queue', action='store_true', help='Experimental bounded independent audio decoding; preserve final video/audio synchronization')
parser.add_argument('--filtered-audio-lead', action='store_true', help='Boundedly prime already-filtered audio before the video sync position is known; requires patched native mpv')
parser.add_argument('--ndk-codec', action='store_true', help='Android diagnostic: use the FFmpeg NDK MediaCodec wrapper for the same selected track')
parser.add_argument('--reserve-selected-codec', action='store_true', help='Overlap first selected resume decoder creation with source initialization; requires native reservation exports')
parser.add_argument('--skip-unused-codec-flush', action='store_true', help='Skip only pristine JNI Surface decoder flushes before its first receive call; requires patched native decoder')
parser.add_argument('--visible-url-prefetch', action='store_true', help='Bounded Wi-Fi URL-only prefetch for one visible known-CID recommendation card')
parser.add_argument('--visible-media-prefetch', action='store_true', help='Warm selected media HTTP responses for the one visible URL-prefetched card; requires isolated sources')
parser.add_argument('--event-output-gate', action='store_true', help='Observe output changes and verify geometry across Flutter frames instead of 16ms polling')
parser.add_argument('--event-output-dwell', action='store_true', help='Wait for 32ms of unchanged output notifications without forcing Flutter frames')
parser.add_argument('--dm-parse-worker', action='store_true', help='Decode danmaku gRPC responses above 16KiB off the UI isolate')
parser.add_argument('--visible-native-preload', action='store_true', help='Prepare one matching visible-card source paused and adopt its decoder on click')
parser.add_argument('--visible-resume-preload', action='store_true', help='Prepare the exact predicted nonzero history position; mismatched progress discards the preparation')
parser.add_argument('--test-resume-ms', type=int, default=0, help='Isolated diagnostic fixture only: replace local UGC response history for longer videos; ordinary playback history behavior is retained')
parser.add_argument('--retain-ready-url', action='store_true', help='Retain only completed valid URL data on scroll; media and decoder still cancel')
parser.add_argument('--source-buffer-ready-gate', action='store_true', help='Exclude still-buffering placeholder geometry from output stability; retain existing deadline and PiP policy')
parser.add_argument('--source-frame-ready-gate', action='store_true', help='Require the current native load restart before accepting output geometry; preserve deadline and PiP policy')
parser.add_argument('--codec-operating-rate', type=int, default=0, help='Experimental Android decoder resource-planning rate; zero preserves the existing default')
parser.add_argument('--prefetch-resume-range', action='store_true', help='Predict one bounded-replay sidx resume range per selected track; exact native ranges still govern consumption')
parser.add_argument('--prefetch-resume-audio-master', action='store_true', help='Align the speculative audio range with the predicted video decode start; keep the exact requested playback position')
parser.add_argument('--prefetch-resume-body', action='store_true', help='Boundedly read the selected resume response body before native claim, then hand off the same stream')
parser.add_argument('--prefetch-resume-segment-body', action='store_true', help='Warm one selected resume segment within 256 KiB..1 MiB; never delay native claim to fill it')
parser.add_argument('--reuse-resume-index', action='store_true', help='Reuse bounded recent index hints to overlap target Range with fresh initialization; never cache history or authorized URLs')
parser.add_argument('--persist-resume-index', action='store_true', help='Keep bounded sidx-only hints across app restarts; still fetch current URLs and validate native ranges')
parser.add_argument('--hedge-resume-prefetch', action='store_true', help='Let an early hinted resume request race the same one current backup as initialization')
parser.add_argument('--hedge-fresh-resume-prefetch', action='store_true', help='Let freshly indexed target ranges race the other current API endpoint as well')
parser.add_argument('--prefetch-resume-presentation-time', action='store_true', help='Predict current sidx segment boundaries for a patched native library; requires native-mpv and resume prefetch')
parser.add_argument('--warm-orientation-service', action='store_true', help='Once after the first app frame, discover the Android sensor service off the main thread without registering a listener')
parser.add_argument('--warm-codec-registry', action='store_true', help='Once after the first app frame, populate Android codec capability metadata on a background thread without creating a decoder')
parser.add_argument('--orientation-timing', action='store_true', help='Diagnostic-only native orientation construction/registration phase timings; dependency restored after build')
parser.add_argument('--async-orientation-registration', action='store_true', help='Experimental serial background sensor registration with immediate lifecycle cancellation')
parser.add_argument('--text-atlas-warmup', action='store_true', help='Bounded first-home rendering of video tab/danmaku glyphs at the current device scale')
parser.add_argument('--action-text-warmup', action='store_true', help='Warm only the six first-video action glyphs at their observed 18dp size')
parser.add_argument('--text-inventory', action='store_true', help='Diagnostic-only first-transition render paragraph/font metadata, no pixels')
parser.add_argument('--transfer-trace', action='store_true', help='Bounded body-progress and position-listener timing; compare only matching instrumentation')
parser.add_argument('--resume-stage-timing', action='store_true', help='Diagnostic: timestamp transport events in their worker and measure synchronous frame-gate property reads')
parser.add_argument('--async-source-frame-gate', action='store_true', help='Read frame gate properties asynchronously while preserving ordered source/event validation')
parser.add_argument('--startup-read-ahead', action='store_true', help='Limit initial demux read-ahead to one second and restore after first presentation')
parser.add_argument('--tcp-nodelay', action='store_true', help='Disable native TCP Nagle waits for the selected network media')
parser.add_argument('--full-profile', action='store_true', help='Profile build for bounded Dart/native sampling; not a speed candidate')
parser.add_argument('--lean-trace', action='store_true', help='Sparse stage/input observations, no geometry polling or debug mpv log')
parser.add_argument('--frame-trace', action='store_true', help='Lean trace plus bounded texture consumption and window/Flutter frame timings')
parser.add_argument('--continuity-trace', action='store_true', help='Separate 60-second diagnostic: distinct positive texture timestamp gaps; not a matched startup speed sample')
args = parser.parse_args()
if not 0 <= args.codec_operating_rate <= 1000:
    parser.error('--codec-operating-rate must be 0..1000')
if args.prefetch_resume_range and not (args.parallel_resume_media and args.isolated_media):
    parser.error('--prefetch-resume-range requires isolated parallel resume media')
if args.prefetch_resume_audio_master and not args.prefetch_resume_range:
    parser.error('--prefetch-resume-audio-master requires --prefetch-resume-range')
if args.prefetch_resume_body and not args.prefetch_resume_range:
    parser.error('--prefetch-resume-body requires --prefetch-resume-range')
if args.prefetch_resume_segment_body and not args.prefetch_resume_body:
    parser.error('--prefetch-resume-segment-body requires --prefetch-resume-body')
if args.reuse_resume_index and not (args.prefetch_resume_range and args.isolated_media):
    parser.error('--reuse-resume-index requires isolated resume range prefetch')
if args.persist_resume_index and not args.reuse_resume_index:
    parser.error('--persist-resume-index requires --reuse-resume-index')
if args.reserve_selected_codec and (not args.native_mpv or args.ndk_codec):
    parser.error('--reserve-selected-codec requires custom native-mpv and the JNI codec backend')
if args.cancel_closed_media_delivery and not args.parallel_audio:
    parser.error('--cancel-closed-media-delivery requires parallel media sources')
if args.skip_unused_codec_flush and (not args.native_mpv or args.ndk_codec):
    parser.error('--skip-unused-codec-flush requires custom native-mpv and the JNI codec backend')
if args.filtered_audio_lead and (not args.native_mpv or not args.audio_decode_queue):
    parser.error('--filtered-audio-lead requires custom native-mpv and audio-decode-queue')
if args.hedge_resume_prefetch and not args.reuse_resume_index:
    parser.error('--hedge-resume-prefetch requires --reuse-resume-index')
if args.hedge_fresh_resume_prefetch and not args.prefetch_resume_range:
    parser.error('--hedge-fresh-resume-prefetch requires --prefetch-resume-range')
if args.prefetch_resume_presentation_time and not (args.native_mpv and args.prefetch_resume_range):
    parser.error('--prefetch-resume-presentation-time requires --native-mpv and --prefetch-resume-range')
if args.no_trace and any([args.wait_trace, args.resume_stage_timing, args.full_profile, args.deep, args.lean_trace, args.frame_trace,
                         args.continuity_trace, args.transfer_trace, args.text_inventory, args.test_resume_ms]):
    parser.error('--no-trace cannot be combined with diagnostic collection options')
if args.test_resume_ms < 0 or (args.test_resume_ms and not args.frame_trace and not args.continuity_trace):
    parser.error('--test-resume-ms requires positive position and explicit frame/continuity diagnostics')
if args.async_orientation_registration:
    args.orientation_timing = True
if args.retain_ready_url and not args.visible_url_prefetch:
    parser.error('--retain-ready-url requires --visible-url-prefetch')
if args.visible_native_preload and not args.visible_media_prefetch:
    parser.error('--visible-native-preload requires --visible-media-prefetch')
if args.visible_resume_preload and not (args.visible_native_preload and args.parallel_resume_media):
    parser.error('--visible-resume-preload requires native preload and parallel resume media')
if args.event_output_gate and args.event_output_dwell:
    parser.error('Choose one output stability experiment')
if args.visible_media_prefetch and not (args.visible_url_prefetch and args.isolated_media):
    parser.error('--visible-media-prefetch requires --visible-url-prefetch and --isolated-media')
if args.continuity_trace:
    args.frame_trace = True
if not 0 <= args.hedge_delay_ms <= 1000 or (args.hedge_delay_ms != 120 and not args.hedge_media):
    parser.error('--hedge-delay-ms must be 0..1000 and non-default values require --hedge-media')
if args.frame_trace:
    args.lean_trace = True
output = args.output.resolve()
if output.exists():
    raise SystemExit(f'Refusing to overwrite an existing APK: {output}')
config = ROOT/'.dart_tool/package_config.json'
packages = json.loads(config.read_text(encoding='utf-8'))['packages']
material = next(p for p in packages if p['name']=='material_ui')
material_root = Path(url2pathname(urlsplit(urljoin(config.as_uri(), material['rootUri'])).path))
if 'typedef IndicatorPainterNotifier' not in (material_root/'lib/src/tabs.dart').read_text(encoding='utf-8'):
    raise SystemExit('material_ui points to an unpatched dependency; restore the existing isolated patched copy before building.')
package = next(p for p in packages if p['name']=='media_kit_video')
package_uri = urljoin(config.as_uri(), package['rootUri'])
package_root = Path(url2pathname(urlsplit(package_uri).path))
dependency = package_root/'lib/src/video_controller/android_video_controller/real.dart'
original = dependency.read_bytes()
dependency_tree = package_root.parent
if subprocess.check_output(['git','status','--porcelain'],cwd=dependency_tree).strip():
    raise SystemExit('Dependency checkout has local changes; preserve them before building.')
revision = subprocess.check_output(['git','rev-parse','HEAD'],cwd=dependency_tree,text=True).strip()
if revision!='fd8421d21eade4d6d12de137fa7df902fec20292':
    raise SystemExit(f'Unexpected media_kit_video revision: {revision}')
orientation_originals = {}
if args.orientation_timing:
    orientation = next(p for p in packages if p['name']=='native_device_orientation')
    orientation_root = Path(url2pathname(urlsplit(urljoin(config.as_uri(),orientation['rootUri'])).path))
    orientation_revision = subprocess.check_output(['git','rev-parse','HEAD'],cwd=orientation_root,text=True).strip()
    if orientation_revision != '7be186c79adca7d3ff5abc34bc75d171c68c2694':
        raise SystemExit('Unexpected orientation dependency revision')
    if subprocess.check_output(['git','status','--porcelain'],cwd=orientation_root).strip():
        raise SystemExit('Orientation dependency has local changes; preserve them before building')
    for name in ['NativeDeviceOrientationPlugin.java','SensorOrientationListener.java','OrientationEventListener.java']:
        target=orientation_root/'android/src/main/java/com/github/rmtmckenzie/native_device_orientation'/name
        orientation_originals[target]=target.read_bytes()
    if args.async_orientation_registration:
        helper=orientation_root/'android/src/main/java/com/github/rmtmckenzie/native_device_orientation/SerialSensorRegistration.java'
        if helper.exists():
            raise SystemExit('Unexpected existing orientation registration helper; preserve it')
        orientation_originals[helper]=None
output.parent.mkdir(parents=True,exist_ok=True)
if args.observe_build_resources:
    import psutil
    output.with_suffix('.build-resource-observation.json').write_text(
        json.dumps({'mode': 'observation-only', 'before': psutil.virtual_memory()._asdict()}, indent=2), encoding='utf-8')
else:
    guard = subprocess.run(['powershell','-NoProfile','-File',
        str(ROOT/'diagnostics/startup-20261018/rollback-baseline/memory-gate.ps1'),'-Kind','build'],cwd=ROOT)
    if guard.returncode: raise SystemExit(guard.returncode)
native_override = None
if args.native_mpv:
    native_package = next(p for p in packages if p['name'] == 'media_kit_libs_android_video')
    native_root = Path(url2pathname(urlsplit(urljoin(config.as_uri(), native_package['rootUri'])).path))
    native_override = NativeLibraryOverride(native_root/'android/build.gradle',
        ROOT/'build/media_kit_libs_android_video', args.native_mpv,
        output.with_suffix('.native.jar'), args.target_platform)
try:
    if native_override:
        native_override.apply()
    dependency.write_bytes((ROOT/'tool/startup_gpu_standby/android_video_controller.dart').read_bytes())
    for target in orientation_originals:
        directory = 'startup_orientation_async' if args.async_orientation_registration and target.name in ['OrientationEventListener.java','SerialSensorRegistration.java'] else 'startup_orientation_timing'
        target.write_bytes((ROOT/'tool'/directory/target.name).read_bytes())
    tracing = str(not args.no_trace).lower()
    flags = [f'PLAYBACK_TRACE={tracing}',f'STARTUP_TIMING={tracing}',f'PLAYER_STANDBY={str(not args.control).lower()}']
    if not args.no_trace:
        flags.append('PLAYBACK_TRACE_GEOMETRY=false' if args.lean_trace else 'PLAYBACK_STARTUP_VERBOSE=true')
    if args.frame_trace:
        flags += ['PLAYBACK_TRACE_TEXTURE=true', 'PLAYBACK_TRACE_FRAMES=true',
                  'PLAYBACK_NETWORK_TRACE=true']
    if args.continuity_trace:
        flags += ['PLAYBACK_TRACE_CONTINUITY=true', 'PLAYBACK_TRACE_DURATION_MS=60000']
    if args.resume_stage_timing:
        flags.append('RESUME_STAGE_TIMING=true')
    if args.wait_trace:
        flags.append('STARTUP_WAIT_TRACE=true')
    if args.async_source_frame_gate:
        flags.append('ASYNC_SOURCE_FRAME_GATE=true')
    if args.prefetch_resume_body:
        flags.append('PREFETCH_RESUME_BODY=true')
    if args.prefetch_resume_segment_body:
        flags.append('PREFETCH_RESUME_SEGMENT_BODY=true')
    if args.reuse_resume_index:
        flags.append('REUSE_RESUME_INDEX=true')
    if args.persist_resume_index:
        flags.append('PERSIST_RESUME_INDEX=true')
    if args.hedge_resume_prefetch:
        flags.append('HEDGE_RESUME_PREFETCH=true')
    if args.hedge_fresh_resume_prefetch:
        flags.append('HEDGE_FRESH_RESUME_PREFETCH=true')
    if args.defer_auxiliary:
        flags.append('DEFER_VIDEO_AUXILIARY=true')
    if args.prioritize_play_url:
        flags.append('PRIORITIZE_PLAY_URL=true')
    if args.autosync_zero:
        flags.append('STARTUP_AUTOSYNC_ZERO=true')
    if args.aaudio_first:
        flags.append('STARTUP_AAUDIO_FIRST=true')
    if args.audio_decode_queue:
        flags.append('STARTUP_AUDIO_DECODE_QUEUE=true')
    if args.filtered_audio_lead:
        flags.append('STARTUP_FILTERED_AUDIO_LEAD=true')
    if args.warm_codec_registry:
        flags.append('WARM_CODEC_REGISTRY=true')
    if args.ndk_codec:
        flags.append('STARTUP_NDK_CODEC=true')
    if args.reserve_selected_codec:
        flags.append('RESERVE_SELECTED_CODEC=true')
    if args.skip_unused_codec_flush:
        flags.append('SKIP_UNUSED_CODEC_FLUSH=true')
    if args.codec_operating_rate:
        flags.append(f'STARTUP_CODEC_OPERATING_RATE={args.codec_operating_rate}')
    if args.visible_url_prefetch:
        flags.append('VISIBLE_URL_PREFETCH=true')
    if args.visible_media_prefetch:
        flags.append('VISIBLE_MEDIA_PREFETCH=true')
    if args.event_output_gate:
        flags.append('EVENT_DRIVEN_OUTPUT_GATE=true')
    if args.event_output_dwell:
        flags.append('EVENT_DRIVEN_OUTPUT_DWELL=true')
    if args.dm_parse_worker:
        flags.append('STARTUP_DM_PARSE_WORKER=true')
    if args.visible_native_preload:
        flags.append('VISIBLE_NATIVE_PRELOAD=true')
    if args.visible_resume_preload:
        flags.append('VISIBLE_RESUME_PRELOAD=true')
    if args.test_resume_ms:
        flags.append(f'STARTUP_TEST_RESUME_MS={args.test_resume_ms}')
    if args.retain_ready_url:
        flags.append('RETAIN_COMPLETED_PLAY_URL=true')
    if args.source_buffer_ready_gate:
        flags.append('SOURCE_BUFFER_READY_GATE=true')
    if args.source_frame_ready_gate:
        flags.append('SOURCE_FRAME_READY_GATE=true')
    if args.warm_orientation_service:
        flags.append('WARM_ORIENTATION_SERVICE=true')
    if args.text_atlas_warmup:
        flags.append('STARTUP_TEXT_WARMUP=true')
    if args.action_text_warmup:
        flags.append('STARTUP_ACTION_TEXT_WARMUP=true')
    if args.text_inventory:
        flags.append('TRACE_STARTUP_TEXT_INVENTORY=true')
    if args.transfer_trace:
        flags.append('STARTUP_TRANSFER_TRACE=true')
    if args.deep:
        if args.lean_trace:
            flags.append('PLAYBACK_STARTUP_VERBOSE=true')
        flags.append('PLAYBACK_STARTUP_DEEP=true')
    if args.early_source:
        flags.append('SOURCE_EARLY_PREPARE=true')
    if args.parallel_audio:
        flags.append('PARALLEL_AUDIO_SOURCE=true')
    if args.cancel_closed_media_delivery:
        flags.append('CANCEL_CLOSED_MEDIA_DELIVERY=true')
    if args.parallel_resume_media:
        flags.append('PARALLEL_RESUME_MEDIA=true')
    if args.prefetch_resume_range:
        flags.append('PREFETCH_RESUME_RANGE=true')
    if args.prefetch_resume_audio_master:
        flags.append('PREFETCH_RESUME_AUDIO_MASTER=true')
    if args.prefetch_resume_presentation_time:
        flags.append('PREFETCH_RESUME_PRESENTATION_TIME=true')
    if args.isolated_media:
        flags.append('ISOLATED_MEDIA_SOURCES=true')
    if args.hedge_audio:
        if not args.isolated_media:
            raise SystemExit('--hedge-audio requires --isolated-media')
        flags.append('HEDGE_AUDIO_SOURCE=true')
    if args.hedge_media:
        if not args.isolated_media:
            raise SystemExit('--hedge-media requires --isolated-media')
        flags.append('HEDGE_MEDIA_SOURCE=true')
        flags.append(f'MEDIA_HEDGE_DELAY_MS={args.hedge_delay_ms}')
    if args.startup_read_ahead:
        flags.append('STARTUP_READ_AHEAD=true')
    if args.omit_zero_start:
        flags.append('OMIT_ZERO_MEDIA_START=true')
    if args.stream_forward:
        flags.append('STREAM_MEDIA_FORWARD=true')
    if args.uncut_dash:
        flags.append('UNCUT_DASH_TRACKS=true')
    if args.tcp_nodelay:
        flags.append('STARTUP_TCP_NODELAY=true')
    if args.full_profile:
        flags.append('PLAYBACK_FULL_PROFILE=true')
    mode = 'profile' if args.full_profile else 'release'
    defines = ','.join(base64.b64encode(f.encode()).decode() for f in flags)
    command = [str(ROOT/'android/gradlew.bat'),'-p','android','assemble'+mode.title(),
        f'-Ptarget-platform={args.target_platform}','-Ptarget=lib/main.dart',f'-Pdart-defines={defines}',
        '-Dorg.gradle.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=768m -Dfile.encoding=UTF-8',
        '--max-workers=1','--console=plain']
    if args.offline:
        command.append('--offline')
    env=dict(os.environ)
    env['JAVA_HOME']='D:/Program Files/Eclipse Adoptium/jdk-21.0.7.6-hotspot'
    env['PATH']=env['JAVA_HOME']+'/bin;'+env['PATH']
    with output.with_suffix('.build.log').open('w',encoding='utf-8') as log:
        result=subprocess.run(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
    if result.returncode: raise SystemExit(result.returncode)
    shutil.copy2(ROOT/f'build/app/outputs/apk/{mode}/app-{mode}.apk',output)
    if native_override:
        native_override.verify_apk(output)
    manifest={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        'apk':str(output),'sha256':hashlib.file_digest(output.open('rb'),'sha256').hexdigest(),
        'defines':flags,'dependencyRevision':revision,
        'buildMode':mode,
        'targetPlatform':args.target_platform,
        'nativeLibraryOverride':native_override.manifest if native_override else None,
        'diagnosticCollectionEnabled':not args.no_trace,
        'resumeStageTiming':args.resume_stage_timing,
        'startupWaitTrace':args.wait_trace,
        'asyncSourceFrameGate':args.async_source_frame_gate,
        'dependencySourceSha256':hashlib.sha256(dependency.read_bytes()).hexdigest(),
        'packageConfigSha256':hashlib.sha256(config.read_bytes()).hexdigest(),
        'materialUiRoot':str(material_root),
        'standbyEnabled':not args.control,'mediaPreload':args.visible_media_prefetch,
        'visibleUrlPrefetch':args.visible_url_prefetch,
        'visibleMediaHttpWarmup':args.visible_media_prefetch,
        'eventDrivenOutputGate':args.event_output_gate,
        'eventDrivenOutputDwell':args.event_output_dwell,
        'dmParseWorker':args.dm_parse_worker,
        'visibleNativePreload':args.visible_native_preload,
        'visibleResumePreload':args.visible_resume_preload,
        'testResumeFixtureMs':args.test_resume_ms,
        'retainCompletedPlayUrl':args.retain_ready_url,
        'sourceBufferReadyGate':args.source_buffer_ready_gate,
        'sourceFrameReadyGate':args.source_frame_ready_gate,
        'codecOperatingRate':args.codec_operating_rate,
        'prefetchResumeRange':args.prefetch_resume_range,
        'prefetchResumeAudioMaster':args.prefetch_resume_audio_master,
        'prefetchResumeBody':args.prefetch_resume_body,
        'prefetchResumeSegmentBody':args.prefetch_resume_segment_body,
        'reuseResumeIndex':args.reuse_resume_index,
        'persistResumeIndex':args.persist_resume_index,
        'hedgeResumePrefetch':args.hedge_resume_prefetch,
        'hedgeFreshResumePrefetch':args.hedge_fresh_resume_prefetch,
        'prefetchResumePresentationTime':args.prefetch_resume_presentation_time,
        'warmOrientationService':args.warm_orientation_service,
        'warmCodecRegistry':args.warm_codec_registry,
        'reserveSelectedCodec':args.reserve_selected_codec,
        'cancelClosedMediaDelivery':args.cancel_closed_media_delivery,
        'skipUnusedCodecFlush':args.skip_unused_codec_flush,
        'filteredAudioLead':args.filtered_audio_lead,
        'orientationPhaseTiming':args.orientation_timing,
        'asyncOrientationRegistration':args.async_orientation_registration,
        'textAtlasWarmup':args.text_atlas_warmup,
        'actionTextWarmup':args.action_text_warmup,
        'textInventory':args.text_inventory,
        'orientationDependencyOriginalSha256':{p.name:hashlib.sha256(v).hexdigest() if v is not None else None for p,v in orientation_originals.items()},
        'orientationDependencyPatchedSha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in orientation_originals},
        'applicationPrefixPreloaded':None if args.visible_native_preload else False,
        'selectedTrackPrefetch': 'video+audio-worker' if args.isolated_media else ('audio' if args.parallel_audio else 'none'),
        'parallelResumeMedia':args.parallel_resume_media,
        'sourcePreparationOverlapsPresentation':args.early_source,
        'leanTrace':args.lean_trace,
        'frameTrace':args.frame_trace,
        'continuityTrace':args.continuity_trace,
        'acceptedPerformanceFix':False}
    if args.full_profile or args.lean_trace or args.no_trace:
        sources = ['lib/main.dart','lib/http/init.dart', 'lib/http/video.dart',
            'lib/plugin/pl_player/playback/codec_registry_warmup.dart',
            'android/app/src/main/kotlin/com/personal/piliplus/StartupCodecRegistry.kt',
            'tool/startup_adb_preparation_test.py',
            'lib/plugin/pl_player/playback/startup_wait_trace.dart',
            'lib/utils/accounts/account_manager/account_mgr.dart',
            'lib/grpc/dm.dart','lib/grpc/grpc_req.dart','lib/grpc/grpc_decode.dart',
            'lib/pages/danmaku/controller.dart','test/grpc_decode_test.dart',
            'lib/plugin/pl_player/playback/playback_start.dart','test/playback_start_test.dart',
            'lib/plugin/pl_player/playback/prepared_resource.dart',
            'lib/plugin/pl_player/playback/prepared_media_engine.dart',
            'lib/plugin/pl_player/playback/mpv_frame_gate.dart',
            'lib/plugin/pl_player/playback/mpv_async_property_reader.dart',
            'test/mpv_async_property_reader_test.dart',
            'test/mpv_frame_gate_test.dart',
            'test/prepared_resource_test.dart',
            'lib/pages/rcmd/view.dart',
            'lib/plugin/pl_player/playback/one_shot_prefetch.dart',
            'lib/plugin/pl_player/playback/selected_media_warmup.dart',
            'lib/plugin/pl_player/playback/selected_codec_reservation.dart',
            'lib/plugin/pl_player/playback/visible_media_prefetch.dart',
            'test/selected_media_warmup_test.dart',
            'test/one_shot_prefetch_test.dart',
            'lib/plugin/pl_player/playback/stable_output_gate.dart',
            'test/stable_output_gate_test.dart',
            'test/stable_output_dwell_test.dart',
            'lib/plugin/pl_player/controller.dart',
            'lib/plugin/pl_player/models/data_source.dart',
            'lib/plugin/pl_player/playback/parallel_audio_source.dart',
            'lib/plugin/pl_player/playback/bounded_body_warmup.dart',
            'test/bounded_body_warmup_test.dart',
            'lib/plugin/pl_player/playback/resume_index_hint.dart',
            'lib/plugin/pl_player/playback/persisted_resume_index_hints.dart',
            'test/persisted_resume_index_hints_test.dart',
            'test/resume_index_hint_test.dart',
            'test/resume_hint_hedge_test.dart',
            'test/isolated_resume_index_test.dart',
            'lib/plugin/pl_player/playback/mp4_resume_range.dart',
            'test/mp4_resume_range_test.dart',
            'test/resume_range_source_test.dart',
            'test/resume_presentation_source_test.dart',
            'test/isolated_resume_alignment_test.dart',
            'test/fixtures/resume_index_fixture.dart',
            'lib/plugin/pl_player/playback/isolated_media_sources.dart',
            'test/isolated_media_sources_test.dart',
            'test/parallel_audio_source_test.dart',
            'test/parallel_source_disconnect_test.dart',
            'test/hedged_media_source_test.dart',
            'test/source_preparation_test.dart',
            'test/playback_source_queue_test.dart',
            'tool/capture_startup_listener.py',
            'tool/startup_resource_profile.py','tool/startup_resource_profile_test.py',
            'tool/startup_search_clear_test.py',
            'tool/startup_history_uri_test.py','lib/utils/app_scheme.dart',
            'tool/startup_vm_timeline.py',
            'tool/startup_home_card.py',
            'tool/startup_input_target.py',
            'tool/review_startup_return_cleanup.py',
            'tool/playback_trace_files.py',
            'tool/playback_trace_files_test.py',
            'tool/run_startup_pairs.py',
            'tool/summarize_parallel_audio.py',
            'lib/plugin/pl_player/playback/source_preparation.dart',
            'lib/pages/video/controller.dart',
            'lib/pages/video/view.dart',
            'lib/pages/common/common_intro_controller.dart',
            'lib/pages/video/introduction/ugc/controller.dart',
            'lib/pages/video/related/controller.dart',
            'lib/plugin/pl_player/playback/startup_auxiliary_gate.dart',
            'test/startup_auxiliary_gate_test.dart',
            'tool/summarize_startup_codec.py',
            'tool/summarize_startup_continuity.py',
            'tool/summarize_startup_transport.py',
            'tool/set_startup_controls_visibility.py',
            'lib/plugin/pl_player/playback/runtime_profile.dart',
            'lib/plugin/pl_player/playback/playback_diagnostics.dart',
            'android/app/src/profile/AndroidManifest.xml',
            'android/app/src/main/kotlin/com/personal/piliplus/PlaybackDiagnostics.kt',
            'android/app/src/main/kotlin/com/personal/piliplus/PlaybackTextureProbe.kt',
            'android/app/src/main/kotlin/com/personal/piliplus/MainActivity.kt',
            'android/app/src/main/kotlin/com/personal/piliplus/StartupOrientationServices.kt',
            'lib/plugin/pl_player/playback/orientation_service_warmup.dart',
            'lib/plugin/pl_player/playback/startup_text_warmup.dart',
            'lib/plugin/pl_player/playback/startup_text_inventory.dart',
            'test/orientation_service_warmup_test.dart',
            'tool/startup_orientation_timing/NativeDeviceOrientationPlugin.java',
            'tool/startup_orientation_timing/SensorOrientationListener.java',
            'tool/startup_orientation_timing/OrientationEventListener.java',
            'tool/startup_orientation_async/OrientationEventListener.java',
            'tool/startup_orientation_async/SerialSensorRegistration.java',
            'tool/startup_orientation_async/SerialSensorRegistrationTest.java',
            'tool/build_startup_standby.py','tool/startup_native_library.py',
            'tool/startup_native_library_test.py','tool/startup_gpu_standby/android_video_controller.dart']
        manifest['diagnosticSourcesSha256'] = {
            name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sources}
        with zipfile.ZipFile(output.with_suffix('.sources.zip'),'w',zipfile.ZIP_DEFLATED) as archive:
            for name in sources: archive.write(ROOT/name,name)
            archive.write(config,'.dart_tool/package_config.json')
        manifest['releaseSpeedComparable'] = False
    output.with_suffix('.build.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print(json.dumps(manifest),flush=True)
finally:
    try:
        dependency.write_bytes(original)
        for target, original_source in orientation_originals.items():
            if original_source is None:
                target.unlink(missing_ok=True)
            else:
                target.write_bytes(original_source)
    finally:
        if native_override:
            native_override.restore()
