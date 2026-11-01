#ifndef PILI_AUDIO_LEAD_LOG_H
#define PILI_AUDIO_LEAD_LOG_H
#ifdef __ANDROID__
#include <android/log.h>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <inttypes.h>
#endif
static void pili_audio_lead_log(struct ao_chain *ao_c, const char *event)
{
#ifdef __ANDROID__
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    struct pili_audio_lead *q = &ao_c->filtered_lead;
    __android_log_print(ANDROID_LOG_INFO, "PiliAudioLead",
        "[AUDIO_LEAD] {\"event\":\"%s\",\"monoNs\":%" PRId64
        ",\"tid\":%ld,\"instance\":\"%p\",\"count\":%u,\"bytes\":%zu,"
        "\"seconds\":%.6f,\"pushed\":%u,\"popped\":%u,"
        "\"videoPtsKnown\":%d,\"videoPts\":%.6f,\"audioStartKnown\":%d,\"audioStartPts\":%.6f,\"yieldedCycles\":%u,\"maxCycleFrames\":%u}",
        event, (int64_t)now.tv_sec * 1000000000 + now.tv_nsec,
        syscall(SYS_gettid), (void *)ao_c, q->count, q->bytes,
        q->seconds, q->pushed, q->popped,
        ao_c->mpctx->video_pts != MP_NOPTS_VALUE,
        ao_c->mpctx->video_pts != MP_NOPTS_VALUE ? ao_c->mpctx->video_pts : 0,
        ao_c->start_pts_known, ao_c->start_pts_known ? ao_c->start_pts : 0,
        q->yielded_cycles, q->max_cycle_used);
#endif
}

// Diagnostic only. At most12 state transitions per reset; no scheduling change.
static void pili_audio_lead_gate_log(struct ao_chain *a)
{
#ifdef __ANDROID__
    struct MPContext *m = a->mpctx;
    if (m->restart_complete)
        return;
    struct pili_audio_lead *q = &a->filtered_lead;
    bool playing = a->ao && ao_is_playing(a->ao);
    unsigned mask = (!m->opts->pili_filtered_audio_lead << 0) |
        (!a->queue_filter << 1) | (!m->hrseek_active << 2) |
        (m->hrseek_lastframe << 3) | (m->hrseek_backstep << 4) |
        ((m->play_dir <= 0) << 5) | (!m->vo_chain << 6) |
        ((m->vo_chain && m->vo_chain->is_sparse) << 7) |
        ((m->video_status >= STATUS_READY) << 8) | (!a->ao << 9) |
        (playing << 10) | (a->spdif_passthrough << 11) |
        (a->start_pts_known << 12) | (q->stopped << 13) |
        ((unsigned)m->audio_status << 16) | ((unsigned)m->video_status << 20);
    if (q->gate_records >= 12 || (q->gate_seen && q->gate_mask == mask))
        return;
    q->gate_seen = true;
    q->gate_mask = mask;
    q->gate_records++;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    __android_log_print(ANDROID_LOG_INFO, "PiliAudioLead",
        "[AUDIO_LEAD_GATE] {\"monoNs\":%" PRId64 ",\"tid\":%ld,"
        "\"instance\":\"%p\",\"ordinal\":%u,\"mask\":%u,"
        "\"enabled\":%d,\"queue\":%d,\"hrseek\":%d,\"lastframe\":%d,"
        "\"backstep\":%d,\"playDir\":%d,\"vo\":%d,\"sparse\":%d,"
        "\"videoStatus\":%d,\"audioStatus\":%d,\"ao\":%d,\"aoPlaying\":%d,"
        "\"spdif\":%d,\"startKnown\":%d,\"stopped\":%d,\"count\":%u,\"seekPts\":%.6f,"
        "\"videoPtsKnown\":%d,\"videoPts\":%.6f,\"audioStartPts\":%.6f}",
        (int64_t)now.tv_sec * 1000000000 + now.tv_nsec, syscall(SYS_gettid),
        (void *)a, q->gate_records, mask, m->opts->pili_filtered_audio_lead,
        !!a->queue_filter, m->hrseek_active, m->hrseek_lastframe, m->hrseek_backstep,
        m->play_dir, !!m->vo_chain, m->vo_chain && m->vo_chain->is_sparse,
        m->video_status, m->audio_status, !!a->ao, playing, a->spdif_passthrough,
        a->start_pts_known, q->stopped, q->count, m->hrseek_pts, m->video_pts != MP_NOPTS_VALUE,
        m->video_pts != MP_NOPTS_VALUE ? m->video_pts : 0, a->start_pts_known ? a->start_pts : 0);
#endif
}
#endif
