#ifndef PILI_PREROLL_QUEUE_H
#define PILI_PREROLL_QUEUE_H
#include <stdbool.h>
#include <stdint.h>
#include <math.h>

/* This changes buffering only. It never decides whether to discard a frame. */
static inline int64_t pili_preroll_queue_limit(bool enabled, bool video,
        bool queued, bool attached_picture, int play_dir, double target,
        int64_t configured)
{
    return enabled && video && queued && !attached_picture && play_dir > 0 &&
        isfinite(target) && target > 0 && configured == 1 ? 4 : configured;
}

#ifdef __ANDROID__
#include <android/log.h>
#include <sys/system_properties.h>
#include <inttypes.h>
#include <time.h>
static inline bool pili_preroll_queue_enabled(void)
{
    char value[PROP_VALUE_MAX] = {0};
    return __system_property_get("debug.piliplus.preroll_queue", value) > 0 &&
        value[0] == '1' && value[1] == 0;
}
static inline void pili_preroll_queue_log(void *owner, int64_t previous,
        int64_t actual, int64_t configured, double target, int frames)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    int64_t ns = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
    __android_log_print(ANDROID_LOG_INFO, "PiliPrerollQueue",
        "[PREROLL_QUEUE] {\"event\":\"config\",\"monoNs\":%" PRId64
        ",\"owner\":\"%p\",\"previous\":%" PRId64 ",\"actual\":%" PRId64
        ",\"configured\":%" PRId64 ",\"targetPending\":%d,\"target\":%.9f,\"queuedFrames\":%d}",
        ns, owner, previous, actual, configured, isfinite(target) && target > 0,
        isfinite(target) && target > 0 ? target : 0, frames);
}
#else
static inline bool pili_preroll_queue_enabled(void) { return false; }
static inline void pili_preroll_queue_log(void *owner, int64_t previous,
        int64_t actual, int64_t configured, double target, int frames)
{ (void)owner; (void)previous; (void)actual; (void)configured; (void)target; (void)frames; }
#endif
#endif
