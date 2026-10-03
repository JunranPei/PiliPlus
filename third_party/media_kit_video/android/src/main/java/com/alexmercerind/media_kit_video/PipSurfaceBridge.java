package com.alexmercerind.media_kit_video;

import android.util.Log;
import android.view.Surface;
import android.os.Handler;
import android.os.Looper;

import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.HashSet;

/**
 * Small bridge for the application's native PiP SurfaceView.
 *
 * The normal media_kit output remains a Flutter SurfaceProducer.  During PiP
 * the Activity can temporarily give libmpv a real SurfaceView surface instead
 * of making the Flutter texture participate in the WindowManager resize.
 */
public final class PipSurfaceBridge {
    private static final String TAG = "PipSurfaceBridge";
    private static Method NEW_GLOBAL_OBJECT_REF;
    private static Method DELETE_GLOBAL_OBJECT_REF;
    private static final HashMap<Long, Long> REFERENCES = new HashMap<>();
    private static final HashMap<Long, Surface> SURFACES = new HashMap<>();
    private static final HashSet<Long> DELETED = new HashSet<>();
    private static final Handler HANDLER = new Handler(Looper.getMainLooper());

    static {
        try {
            final Class<?> helper = Class.forName(
                    "com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            NEW_GLOBAL_OBJECT_REF = helper.getDeclaredMethod("newGlobalObjectRef", Object.class);
            DELETE_GLOBAL_OBJECT_REF = helper.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            NEW_GLOBAL_OBJECT_REF.setAccessible(true);
            DELETE_GLOBAL_OBJECT_REF.setAccessible(true);
        } catch (Throwable error) {
            // Keep the normal Flutter Texture path usable if the optional JNI
            // helper is unavailable in a custom media_kit build.
            Log.w(TAG, "JNI global-reference helper unavailable", error);
            NEW_GLOBAL_OBJECT_REF = null;
            DELETE_GLOBAL_OBJECT_REF = null;
        }
    }

    private PipSurfaceBridge() {}

    /** Returns a global JNI reference suitable for mpv's --wid option. */
    public static synchronized long attach(long handle, Surface surface) {
        if (surface == null || !surface.isValid()) return 0;
        if (NEW_GLOBAL_OBJECT_REF == null) return 0;
        final Long existing = REFERENCES.get(handle);
        if (existing != null && SURFACES.get(handle) == surface) {
            return existing;
        }
        detach(handle);
        try {
            final Object value = NEW_GLOBAL_OBJECT_REF.invoke(null, surface);
            final long reference = value instanceof Number ? ((Number) value).longValue() : 0;
            if (reference != 0) {
                REFERENCES.put(handle, reference);
                SURFACES.put(handle, surface);
            }
            Log.i(TAG, "attach handle=" + handle + " wid=" + reference);
            return reference;
        } catch (Throwable error) {
            Log.e(TAG, "attach failed", error);
            return 0;
        }
    }

    public static synchronized void detach(long handle) {
        final Long reference = REFERENCES.remove(handle);
        SURFACES.remove(handle);
        if (reference != null) {
            // Dart must first set mpv's --wid=0. Keep the JNI reference alive
            // briefly so libmpv cannot dereference a deleted Surface during
            // the asynchronous MethodChannel round trip.
            HANDLER.postDelayed(() -> delete(reference), 1000L);
        }
    }

    private static void delete(long reference) {
        if (reference == 0 || DELETE_GLOBAL_OBJECT_REF == null || DELETED.contains(reference)) return;
        if (DELETED.size() > 100) DELETED.clear();
        DELETED.add(reference);
        try {
            DELETE_GLOBAL_OBJECT_REF.invoke(null, reference);
        } catch (Throwable error) {
            Log.w(TAG, "delete failed", error);
        }
    }
}
