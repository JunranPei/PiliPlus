#ifndef PILI_CODEC_CALLBACK_WAIT_H
#define PILI_CODEC_CALLBACK_WAIT_H
/* Internal FFmpeg extension; caller includes mediacodec_wrapper.h first. */
int ff_pili_mediacodec_wait_for_activity(FFAMediaCodec *codec, int64_t timeout_us);
#endif
