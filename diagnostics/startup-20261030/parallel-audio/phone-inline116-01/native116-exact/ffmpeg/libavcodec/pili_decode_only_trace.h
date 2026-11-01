#ifndef PILI_DECODE_ONLY_TRACE_H
#define PILI_DECODE_ONLY_TRACE_H
#include <android/log.h>
#include <inttypes.h>
#include <time.h>
// At most two records per decoder, matched in enabled and disabled samples.
static void pili_decode_only_trace(MediaCodecDecContext *s, const char *event,
                                   int64_t pts, unsigned flags)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t ns = (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
    __android_log_print(ANDROID_LOG_INFO, "PiliDecodeOnly",
        "[DECODE_ONLY] {\"event\":\"%s\",\"instance\":\"%p\","
        "\"monoNs\":%"PRId64",\"sdk\":%d,\"enabled\":%d,"
        "\"ptsUs\":%"PRId64",\"flags\":%u,\"eligible\":%u,\"applied\":%u}",
        event, s, ns, s->pili_decode_only_sdk, s->pili_decode_only_enabled,
        pts, flags, s->pili_decode_only_eligible, s->pili_decode_only_applied);
}
#endif
