#ifndef PILI_CODEC_FLUSH_TRACE_H
#define PILI_CODEC_FLUSH_TRACE_H
#include <android/log.h>
#include <inttypes.h>
#include <time.h>
#include <sys/syscall.h>
#include <unistd.h>

/* One first-receive event and at most eight flush pairs per decoder instance.
 * The same listener is present in both experimental variants. */
static void pili_codec_flush_trace(const void *instance, const char *event,
                                  int enabled, int started, int skipped,
                                  int ordinal)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t ns = (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
    __android_log_print(ANDROID_LOG_INFO, "PiliCodecFlush",
        "[CODEC_FLUSH] {\"event\":\"%s\",\"instance\":\"%p\","
        "\"monoNs\":%"PRId64",\"tid\":%ld,\"enabled\":%d,"
        "\"receiveStarted\":%d,\"skipped\":%d,\"ordinal\":%d}",
        event, instance, ns, (long)syscall(SYS_gettid), enabled,
        started, skipped, ordinal);
}
#endif
