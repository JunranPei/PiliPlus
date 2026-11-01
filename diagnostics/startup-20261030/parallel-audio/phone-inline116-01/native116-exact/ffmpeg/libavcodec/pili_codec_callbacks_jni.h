/* Included after FFAMediaCodecJni and the MediaFormat JNI helpers. */
#include <pthread.h>
#include <sys/system_properties.h>
#include "pili_codec_callbacks_dex.h"

static struct {
    pthread_mutex_t lock;
    jclass klass;
    jmethodID constructor, input, output, queue, format, flush, close, snapshot;
} pili_callbacks = { .lock = PTHREAD_MUTEX_INITIALIZER };

static int64_t pili_callbacks_now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

/* All classes resolved here are framework classes. The embedded, locally built
 * DEX needs no app class lookup from FFmpeg's attached native thread. */
static int pili_callbacks_load(JNIEnv *env, void *log_ctx)
{
    int ok = 0;
    jclass loaders, memory_loader, helper;
    jmethodID system_loader, load_class, constructor;
    jobject parent, buffer, loader;
    jstring name;
    pthread_mutex_lock(&pili_callbacks.lock);
    if (pili_callbacks.klass) { ok = 1; goto done; }
    if ((*env)->PushLocalFrame(env, 16) < 0) goto done;
#define PILI_JNI_CHECK(value) do { if (!(value) || (*env)->ExceptionCheck(env)) goto failed; } while (0)
    loaders = (*env)->FindClass(env, "java/lang/ClassLoader");
    PILI_JNI_CHECK(loaders);
    system_loader = (*env)->GetStaticMethodID(env, loaders, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
    PILI_JNI_CHECK(system_loader);
    load_class = (*env)->GetMethodID(env, loaders, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    PILI_JNI_CHECK(load_class);
    parent = (*env)->CallStaticObjectMethod(env, loaders, system_loader);
    PILI_JNI_CHECK(parent);
    memory_loader = (*env)->FindClass(env, "dalvik/system/InMemoryDexClassLoader");
    PILI_JNI_CHECK(memory_loader);
    constructor = (*env)->GetMethodID(env, memory_loader, "<init>", "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V");
    PILI_JNI_CHECK(constructor);
    buffer = (*env)->NewDirectByteBuffer(env, (void *)pili_codec_callbacks_dex, sizeof(pili_codec_callbacks_dex));
    PILI_JNI_CHECK(buffer);
    loader = (*env)->NewObject(env, memory_loader, constructor, buffer, parent);
    PILI_JNI_CHECK(loader);
    name = (*env)->NewStringUTF(env, "com.personal.piliplus.PiliCodecCallbacks");
    PILI_JNI_CHECK(name);
    helper = (*env)->CallObjectMethod(env, loader, load_class, name);
    PILI_JNI_CHECK(helper);
#define PILI_METHOD(field, method, signature) do { \
    pili_callbacks.field = (*env)->GetMethodID(env, helper, method, signature); \
    PILI_JNI_CHECK(pili_callbacks.field); \
} while (0)
    PILI_METHOD(constructor, "<init>", "(Landroid/media/MediaCodec;)V");
    PILI_METHOD(input, "dequeueInputBuffer", "(J)I");
    PILI_METHOD(output, "dequeueOutputBuffer", "(Landroid/media/MediaCodec$BufferInfo;J)I");
    PILI_METHOD(queue, "queueInputBuffer", "(IIIJI)V");
    PILI_METHOD(format, "getOutputFormat", "()Landroid/media/MediaFormat;");
    PILI_METHOD(flush, "flush", "()V");
    PILI_METHOD(close, "close", "()V");
    PILI_METHOD(snapshot, "snapshot", "()[J");
    pili_callbacks.klass = (*env)->NewGlobalRef(env, helper);
    PILI_JNI_CHECK(pili_callbacks.klass);
    ok = 1;
failed:
    ff_jni_exception_check(env, 1, log_ctx);
    (*env)->PopLocalFrame(env, NULL);
done:
    if (!ok) ff_jni_exception_check(env, 1, log_ctx);
    pthread_mutex_unlock(&pili_callbacks.lock);
    return ok;
#undef PILI_METHOD
#undef PILI_JNI_CHECK
}

static int pili_callbacks_prepare(JNIEnv *env, FFAMediaCodecJni *codec,
                                  const FFAMediaFormat *format, int surface)
{
    char value[PROP_VALUE_MAX] = {0};
    const char *mime = NULL;
    int requested, sdk, eligible, error = 0;
    int64_t begin = pili_callbacks_now();
    __system_property_get("debug.piliplus.codec_callbacks", value);
    requested = !strcmp(value, "1");
    value[0] = 0;
    __system_property_get("ro.build.version.sdk", value);
    sdk = atoi(value);
    mediaformat_jni_getString((FFAMediaFormat *)format, "mime", &mime);
    eligible = surface && sdk >= 26 && mime && !strcmp(mime, "video/hevc");
    av_freep(&mime);
    if (requested && eligible) {
        if (!codec->has_get_i_o_buffer || !pili_callbacks_load(env, codec)) {
            error = AVERROR_EXTERNAL;
        } else {
            jobject helper = (*env)->NewObject(env, pili_callbacks.klass,
                                              pili_callbacks.constructor, codec->object);
            if (ff_jni_exception_check(env, 1, codec) < 0 || !helper) {
                error = AVERROR_EXTERNAL;
            } else {
                codec->pili_callback_bridge = (*env)->NewGlobalRef(env, helper);
                if (ff_jni_exception_check(env, 1, codec) < 0 || !codec->pili_callback_bridge) {
                    (*env)->CallVoidMethod(env, helper, pili_callbacks.close);
                    ff_jni_exception_check(env, 1, codec);
                    error = AVERROR_EXTERNAL;
                }
                (*env)->DeleteLocalRef(env, helper);
            }
        }
    }
    __android_log_print(ANDROID_LOG_INFO, "PiliCodecCallbacks",
        "[CODEC_CALLBACK] {\"event\":\"configure\",\"monoNs\":%" PRId64 ",\"codec\":\"%p\",\"requested\":%d,\"eligible\":%d,\"active\":%d,\"setupNs\":%" PRId64 ",\"error\":%d}",
        pili_callbacks_now(), (void *)codec, requested, eligible,
        codec->pili_callback_bridge != NULL, pili_callbacks_now() - begin, error);
    return error;
}

static int pili_callbacks_close(JNIEnv *env, FFAMediaCodecJni *codec)
{
    int error = 0;
    jlong state[7] = {0};
    jlongArray snapshot;
    if (!codec->pili_callback_bridge || codec->pili_callback_closed) return 0;
    (*env)->CallVoidMethod(env, codec->pili_callback_bridge, pili_callbacks.close);
    if (ff_jni_exception_check(env, 1, codec) < 0) error = AVERROR_EXTERNAL;
    snapshot = (*env)->CallObjectMethod(env, codec->pili_callback_bridge, pili_callbacks.snapshot);
    if (ff_jni_exception_check(env, 1, codec) < 0) error = AVERROR_EXTERNAL;
    if (snapshot) {
        if ((*env)->GetArrayLength(env, snapshot) == 7)
            (*env)->GetLongArrayRegion(env, snapshot, 0, 7, state);
        if (ff_jni_exception_check(env, 1, codec) < 0) error = AVERROR_EXTERNAL;
        (*env)->DeleteLocalRef(env, snapshot);
    }
    codec->pili_callback_closed = !error;
    __android_log_print(ANDROID_LOG_INFO, "PiliCodecCallbacks",
        "[CODEC_CALLBACK] {\"event\":\"close\",\"monoNs\":%" PRId64 ",\"codec\":\"%p\",\"inputCallbacks\":%lld,\"outputCallbacks\":%lld,\"flushes\":%lld,\"pendingInput\":%lld,\"pendingOutput\":%lld,\"closed\":%lld,\"threadAlive\":%lld,\"error\":%d}",
        pili_callbacks_now(), (void *)codec, (long long)state[0], (long long)state[1],
        (long long)state[2], (long long)state[3], (long long)state[4],
        (long long)state[5], (long long)state[6], error);
    return error;
}

#define PILI_CALLBACK_OBJECT(c) ((c)->pili_callback_bridge ? (c)->pili_callback_bridge : (c)->object)
#define PILI_CALLBACK_METHOD(c, field, original) ((c)->pili_callback_bridge ? pili_callbacks.field : (c)->jfields.original)
