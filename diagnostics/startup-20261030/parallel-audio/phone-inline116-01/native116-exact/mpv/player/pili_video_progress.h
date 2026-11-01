#ifndef PILI_VIDEO_PROGRESS_H
#define PILI_VIDEO_PROGRESS_H
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
struct pili_video_progress {
    bool initialized, enabled;
    unsigned calls, reads, skipped, extra_reads, max_reads;
    unsigned waits, new_frames, eof, errors, budget_exhausted;
    double target;
};
#ifdef __ANDROID__
#include <android/log.h>
#include <sys/system_properties.h>
#include <time.h>
static inline bool pili_video_progress_enabled(void)
{
    char value[PROP_VALUE_MAX] = {0};
    return __system_property_get("debug.piliplus.video_progress", value) > 0 && value[0] == '1' && value[1] == 0;
}
static inline void pili_video_progress_dump(struct pili_video_progress *s, void *owner)
{
    if (!s->enabled || !s->calls) return;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    int64_t ns=(int64_t)ts.tv_sec*1000000000LL+ts.tv_nsec;
    __android_log_print(ANDROID_LOG_INFO,"PiliPrerollQueue",
        "[VIDEO_PROGRESS] {\"event\":\"reset\",\"monoNs\":%" PRId64 ",\"owner\":\"%p\",\"target\":%.9f,"
        "\"calls\":%u,\"reads\":%u,\"skipped\":%u,\"extraReads\":%u,\"maxReads\":%u,"
        "\"waits\":%u,\"newFrames\":%u,\"eof\":%u,\"errors\":%u,\"budgetExhausted\":%u}",
        ns,owner,s->target,s->calls,s->reads,s->skipped,s->extra_reads,s->max_reads,s->waits,s->new_frames,s->eof,s->errors,s->budget_exhausted);
}
#else
static inline bool pili_video_progress_enabled(void) { return false; }
static inline void pili_video_progress_dump(struct pili_video_progress *s, void *owner) { (void)s; (void)owner; }
#endif
static inline void pili_video_progress_reset(struct pili_video_progress *s, void *owner)
{
    pili_video_progress_dump(s,owner);
    bool initialized=s->initialized,enabled=s->enabled;
    *s=(struct pili_video_progress){.initialized=initialized,.enabled=enabled};
}
#endif
