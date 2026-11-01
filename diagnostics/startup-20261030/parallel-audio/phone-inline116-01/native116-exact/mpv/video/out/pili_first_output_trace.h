#ifndef PILI_FIRST_OUTPUT_TRACE_H
#define PILI_FIRST_OUTPUT_TRACE_H
#include <inttypes.h>
#include <string.h>
#include <time.h>
#include <sys/system_properties.h>
#include <android/log.h>

/* One owner thread per instance; VO and codec maintain separate arrays.
 * First12 entries only, no logging until owner teardown. No presentation claim. */
typedef struct PiliFirstOutputEvent {
    int64_t draw_ns, begin_ns, end_ns, schedule_ns, mpv_now_ns, index;
    double pts;
    int render, result;
} PiliFirstOutputEvent;
typedef struct PiliFirstOutputTrace {
    int enabled, dumped;
    unsigned count;
    PiliFirstOutputEvent events[12];
} PiliFirstOutputTrace;

static int64_t pili_first_now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static void pili_first_init(PiliFirstOutputTrace *t, int eligible)
{
    char value[PROP_VALUE_MAX] = {0};
    __system_property_get("debug.piliplus.first_output", value);
    t->enabled = eligible && !strcmp(value, "1");
}

static int pili_first_reserve(PiliFirstOutputTrace *t)
{
    return t->enabled && t->count < 12 ? t->count++ : -1;
}

static void pili_first_dump(PiliFirstOutputTrace *t, const char *layer, void *owner)
{
    if (!t->enabled || t->dumped) return;
    t->dumped = 1;
    __android_log_print(ANDROID_LOG_INFO, "PiliCodecCallbacks",
        "[FIRST_OUTPUT] {\"event\":\"summary\",\"layer\":\"%s\",\"owner\":\"%p\",\"count\":%u,\"limit\":12}",
        layer, owner, t->count);
    for (unsigned i = 0; i < t->count; i++) {
        PiliFirstOutputEvent *e = &t->events[i];
        __android_log_print(ANDROID_LOG_INFO, "PiliCodecCallbacks",
            "[FIRST_OUTPUT] {\"event\":\"frame\",\"layer\":\"%s\",\"owner\":\"%p\",\"ordinal\":%u,\"pts\":%.9f"
            ",\"index\":%" PRId64 ",\"drawNs\":%" PRId64 ",\"beginNs\":%" PRId64 ",\"endNs\":%" PRId64
            ",\"scheduleNs\":%" PRId64 ",\"mpvNowNs\":%" PRId64 ",\"render\":%d,\"result\":%d}",
            layer, owner, i, e->pts, e->index, e->draw_ns, e->begin_ns, e->end_ns,
            e->schedule_ns, e->mpv_now_ns, e->render, e->result);
    }
}
#endif
