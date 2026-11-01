#include <stdatomic.h>
#include <sys/system_properties.h>

/* One decoder thread writes counters/events. The rendering thread only freezes
 * the window atomically. Dump after codec release, never in the first-frame path.
 * Timing/ring writes are opt-in. With timing off, only decoder-thread lifetime
 * counters remain; the single summary is emitted after codec release.
 * This is bounded diagnostic state, not a playback queue. */
enum { PILI_INPUT_POLL, PILI_INPUT_QUEUE, PILI_OUTPUT_CALL, PILI_OUTPUT_FIELDS, PILI_INFO_METRICS };
typedef struct PiliInfoEvent {
    int kind, index, flags;
    int64_t begin, end, pts, bytes;
} PiliInfoEvent;
typedef struct PiliInfoTrace {
    atomic_int_fast64_t render_ns;
    int surface, enabled, skip_empty, dumped;
    uint64_t counts[PILI_INFO_METRICS], wall_ns[PILI_INFO_METRICS];
    uint64_t negative_polls, skipped_fields, negative_fields_ns;
    int64_t begin_ns;
    unsigned count, dropped;
    PiliInfoEvent events[256];
} PiliInfoTrace;

static int64_t pili_info_now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static void pili_info_init(PiliInfoTrace *t, int surface)
{
    char value[PROP_VALUE_MAX] = {0};
    atomic_init(&t->render_ns, 0);
    t->surface = surface;
    __system_property_get("debug.piliplus.info_trace", value);
    t->enabled = surface && !strcmp(value, "1");
    value[0] = 0;
    __system_property_get("debug.piliplus.skip_empty_info", value);
    t->skip_empty = surface && !strcmp(value, "1");
}

static int64_t pili_info_begin(PiliInfoTrace *t)
{
    return t->enabled && !atomic_load_explicit(&t->render_ns, memory_order_relaxed)
        ? pili_info_now() : 0;
}

static int64_t pili_info_span_ns(PiliInfoTrace *t, int64_t begin, int64_t end)
{
    if (!begin) return 0;
    int64_t stop = atomic_load_explicit(&t->render_ns, memory_order_relaxed);
    if (stop && begin >= stop) return 0;
    if (stop && end > stop) end = stop;
    return end - begin;
}

static void pili_info_metric(PiliInfoTrace *t, int kind, int64_t begin, int64_t end)
{
    if (!begin) return;
    int64_t duration = pili_info_span_ns(t, begin, end);
    if (duration <= 0) return;
    if (!t->begin_ns) t->begin_ns = begin;
    t->counts[kind]++;
    t->wall_ns[kind] += duration;
}

static void pili_info_event(PiliInfoTrace *t, int kind, int index, int flags,
                            int64_t begin, int64_t end, int64_t pts, int64_t bytes)
{
    if (!begin) return;
    int64_t stop = atomic_load_explicit(&t->render_ns, memory_order_relaxed);
    if (stop && begin >= stop) return;
    if (t->count == 256) { t->dropped++; return; }
    t->events[t->count++] = (PiliInfoEvent){kind, index, flags, begin, end, pts, bytes};
}

static void pili_info_render(PiliInfoTrace *t)
{
    if (!t->enabled) return;
    int_fast64_t expected = 0;
    atomic_compare_exchange_strong_explicit(&t->render_ns, &expected, pili_info_now(),
                                            memory_order_relaxed, memory_order_relaxed);
}

static void pili_info_dump(PiliInfoTrace *t, void *codec)
{
    if (!t->surface || t->dumped) return;
    t->dumped = 1;
    __android_log_print(ANDROID_LOG_INFO, "PiliCodecCallbacks",
        "[CODEC_INFO] {\"event\":\"summary\",\"codec\":\"%p\",\"monoNs\":%" PRId64
        ",\"firstPollNs\":%" PRId64 ",\"firstRenderNs\":%" PRId64
        ",\"traceEnabled\":%d,\"counterScope\":\"%s\""
        ",\"skipEmpty\":%d,\"negativePolls\":%" PRIu64 ",\"skippedFields\":%" PRIu64
        ",\"negativeFieldsNs\":%" PRIu64 ",\"events\":%u,\"dropped\":%u}",
        codec, pili_info_now(), t->begin_ns, (int64_t)atomic_load(&t->render_ns),
        t->enabled, t->enabled ? "before-render" : "codec-lifetime",
        t->skip_empty, t->negative_polls, t->skipped_fields, t->negative_fields_ns, t->count, t->dropped);
    if (!t->enabled) return;
    for (unsigned i = 0; i < PILI_INFO_METRICS; i++)
        __android_log_print(ANDROID_LOG_INFO, "PiliCodecCallbacks",
            "[CODEC_INFO] {\"event\":\"metric\",\"codec\":\"%p\",\"kind\":%u,\"calls\":%" PRIu64 ",\"wallNs\":%" PRIu64 "}",
            codec, i, t->counts[i], t->wall_ns[i]);
    for (unsigned i = 0; i < t->count; i++) {
        PiliInfoEvent *e = &t->events[i];
        __android_log_print(ANDROID_LOG_INFO, "PiliCodecCallbacks",
            "[CODEC_INFO] {\"event\":\"buffer\",\"codec\":\"%p\",\"kind\":%d,\"index\":%d,\"flags\":%d,\"beginNs\":%" PRId64
            ",\"endNs\":%" PRId64 ",\"ptsUs\":%" PRId64 ",\"bytes\":%" PRId64 "}",
            codec, e->kind, e->index, e->flags, e->begin, e->end, e->pts, e->bytes);
    }
}
