/* Bounded, owning FIFO of already-filtered audio. Core thread only. */
#ifndef PILI_AUDIO_LEAD_H
#define PILI_AUDIO_LEAD_H

#include <math.h>
#include <stddef.h>

#define PILI_AUDIO_LEAD_FRAMES 96
#define PILI_AUDIO_LEAD_BYTES (1024 * 1024)
#define PILI_AUDIO_LEAD_SECONDS 2.0

struct pili_audio_lead {
    struct mp_frame frames[PILI_AUDIO_LEAD_FRAMES];
    unsigned head, count;
    size_t bytes;
    double seconds;
    bool stopped;
    unsigned pushed, popped;
    unsigned cycle_used, max_cycle_used, yielded_cycles;
    bool cycle_yielded;
    unsigned gate_mask, gate_records;
    bool gate_seen;
};

static inline size_t pili_audio_lead_bytes(struct mp_frame frame)
{
    return frame.type == MP_FRAME_AUDIO ?
        (size_t)MPMAX(0, mp_aframe_approx_byte_size(frame.data)) : 0;
}

static inline double pili_audio_lead_seconds(struct mp_frame frame)
{
    return frame.type == MP_FRAME_AUDIO ? mp_aframe_duration(frame.data) : 0;
}

static inline bool pili_audio_lead_push(struct pili_audio_lead *q, struct mp_frame frame)
{
    size_t bytes = pili_audio_lead_bytes(frame);
    double seconds = pili_audio_lead_seconds(frame);
    if (q->stopped || (frame.type != MP_FRAME_AUDIO && frame.type != MP_FRAME_EOF) ||
        q->count == PILI_AUDIO_LEAD_FRAMES || !isfinite(seconds) || seconds < 0 ||
        bytes > PILI_AUDIO_LEAD_BYTES - q->bytes ||
        seconds > PILI_AUDIO_LEAD_SECONDS - q->seconds)
    {
        q->stopped = true;
        return false; // caller retains ownership
    }
    q->frames[(q->head + q->count) % PILI_AUDIO_LEAD_FRAMES] = frame;
    q->count++;
    q->pushed++;
    q->bytes += bytes;
    q->seconds += seconds;
    if (frame.type == MP_FRAME_EOF || q->count == PILI_AUDIO_LEAD_FRAMES ||
        q->bytes == PILI_AUDIO_LEAD_BYTES || q->seconds >= PILI_AUDIO_LEAD_SECONDS)
        q->stopped = true;
    return true;
}

static inline struct mp_frame pili_audio_lead_pop(struct pili_audio_lead *q)
{
    if (!q->count)
        return MP_NO_FRAME;
    struct mp_frame frame = q->frames[q->head];
    q->frames[q->head] = MP_NO_FRAME;
    q->head = (q->head + 1) % PILI_AUDIO_LEAD_FRAMES;
    q->count--;
    q->popped++;
    q->bytes -= pili_audio_lead_bytes(frame);
    q->seconds -= pili_audio_lead_seconds(frame);
    if (!q->count)
        q->seconds = 0;
    return frame; // ownership moves to the ordinary clipping/output path
}

static inline void pili_audio_lead_unread(struct pili_audio_lead *q, struct mp_frame frame)
{
    mp_assert(q->count < PILI_AUDIO_LEAD_FRAMES && q->popped > 0);
    q->head = (q->head + PILI_AUDIO_LEAD_FRAMES - 1) % PILI_AUDIO_LEAD_FRAMES;
    q->frames[q->head] = frame;
    q->count++;
    q->popped--;
    q->bytes += pili_audio_lead_bytes(frame);
    q->seconds += pili_audio_lead_seconds(frame);
}

static inline void pili_audio_lead_clear(struct pili_audio_lead *q)
{
    while (q->count) {
        struct mp_frame frame = pili_audio_lead_pop(q);
        mp_frame_unref(&frame);
    }
    *q = (struct pili_audio_lead){0};
}
#endif
