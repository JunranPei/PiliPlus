#include <jni.h>
#include <android/native_window_jni.h>
#include <cerrno>

extern "C" JNIEXPORT jint JNICALL
Java_com_personal_piliplus_PipBufferGeometry_resize(JNIEnv* env, jclass,
                                                 jobject surface, jint width,
                                                 jint height) {
  if (!surface || width <= 0 || height <= 0) return -EINVAL;
  ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
  if (!window) return -EINVAL;
  const int result = ANativeWindow_setBuffersGeometry(window, width, height, 0);
  ANativeWindow_release(window);
  return result;
}
