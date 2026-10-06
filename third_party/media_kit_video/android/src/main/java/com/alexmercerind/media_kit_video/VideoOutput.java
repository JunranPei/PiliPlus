/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.util.Log;

import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;

import io.flutter.view.TextureRegistry;

/** Owns one Flutter SurfaceProducer and the Surface reference used by libmpv. */
public final class VideoOutput implements TextureRegistry.SurfaceProducer.Callback {
    private static final String TAG = "VideoOutput";
    private static final Method NEW_GLOBAL_OBJECT_REF;
    private static final Method DELETE_GLOBAL_OBJECT_REF;

    static {
        try {
            final Class<?> helper = Class.forName(
                    "com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            NEW_GLOBAL_OBJECT_REF = helper.getDeclaredMethod("newGlobalObjectRef", Object.class);
            DELETE_GLOBAL_OBJECT_REF = helper.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            NEW_GLOBAL_OBJECT_REF.setAccessible(true);
            DELETE_GLOBAL_OBJECT_REF.setAccessible(true);
        } catch (Throwable error) {
            Log.i(TAG, "package:media_kit_libs_android_video missing", error);
            throw new RuntimeException("Failed to initialize the media_kit Android JNI helper.", error);
        }
    }

    /** Stable Flutter texture id. */
    public final long id;
    /** Current JNI global reference passed to mpv's --wid option. */
    public long wid = 0;

    private final TextureUpdateCallback textureUpdateCallback;
    private final TextureRegistry.SurfaceProducer surfaceProducer;
    private final Object lock = new Object();
    private final HashSet<Long> retainedReferences = new HashSet<>();
    private final HashMap<Long, android.view.Surface> retainedSurfaces = new HashMap<>();
    private android.view.Surface currentSurface;
    private int videoWidth = 1;
    private int videoHeight = 1;
    private boolean disposed = false;

    VideoOutput(TextureRegistry textureRegistry, TextureUpdateCallback textureUpdateCallback) {
        this.textureUpdateCallback = textureUpdateCallback;
        surfaceProducer = textureRegistry.createSurfaceProducer();
        id = surfaceProducer.id();
        surfaceProducer.setCallback(this);
        Log.i(TAG, String.format(Locale.ENGLISH, "created texture=%d", id));
    }

    /** Set the producer buffer size. The Flutter texture id remains stable. */
    public void setSurfaceSize(int width, int height) {
        synchronized (lock) {
            Log.i(TAG, "setSize request texture=" + id + " old=" + videoWidth + "x" + videoHeight + " new=" + width + "x" + height + " wid=" + wid + " disposed=" + disposed);
            if (disposed) return;
            videoWidth = Math.max(1, width);
            videoHeight = Math.max(1, height);
            try {
                surfaceProducer.setSize(videoWidth, videoHeight);
                // Publish synchronously for engines which deliver the callback
                // on the next frame. Duplicate callbacks are identity-guarded.
                publishSurfaceLocked("size");
            } catch (Throwable error) {
                Log.e(TAG, "setSurfaceSize failed", error);
            }
        }
    }

    /** Legacy 1.2.x API; the producer owns the Surface already. */
    public long createSurface() {
        synchronized (lock) {
            if (!disposed && wid == 0 && videoWidth > 1 && videoHeight > 1) {
                publishSurfaceLocked("create");
            }
            return wid;
        }
    }

    /**
     * Start a new media-size epoch without blanking the existing texture.
     * libmpv is detached by the Dart controller before this call.  Keeping the
     * producer and its current Surface alive lets the last decoded frame stay
     * visible while the next item is opening; a real producer replacement is
     * still reported by onSurfaceCleanup/onSurfaceAvailable when Android
     * actually gives us one.
     */
    public void resetSurfaceSize() {
        synchronized (lock) {
            if (disposed) return;
            videoWidth = 1;
            videoHeight = 1;
            Log.i(TAG, String.format(Locale.ENGLISH, "reset texture=%d", id));
        }
    }

    public void dispose() {
        synchronized (lock) {
            if (disposed) return;
            disposed = true;
            retireSurfaceLocked();
            try {
                surfaceProducer.setCallback(null);
            } catch (Throwable ignored) {
                // Nullable callbacks are unavailable on some older embeddings.
            }
            try {
                surfaceProducer.release();
            } catch (Throwable error) {
                Log.e(TAG, "release SurfaceProducer failed", error);
            }
        }
    }

    public boolean releaseSurfaceRef(long reference) {
        synchronized (lock) {
            if (reference == 0 || reference == wid || !retainedReferences.remove(reference)) {
                return false;
            }
            deleteGlobalObjectRef(reference);
            final android.view.Surface surface = retainedSurfaces.remove(reference);
            if (surface != null) {
                try {
                    surface.release();
                } catch (Throwable error) {
                    Log.w(TAG, "release Surface failed", error);
                }
            }
            Log.i(TAG, String.format(Locale.ENGLISH,
                    "released texture=%d wid=%d remaining=%d",
                    id, reference, retainedReferences.size()));
            return true;
        }
    }

    /**
     * A disposed output can still own a JNI reference until Dart has
     * synchronously detached that Surface from mpv.  The manager keeps such
     * outputs in a retired list and removes them only after every reference
     * has been acknowledged.
     */
    public boolean isFullyReleased() {
        synchronized (lock) {
            return disposed && wid == 0 && retainedReferences.isEmpty();
        }
    }

    @Override
    public void onSurfaceAvailable() {
        synchronized (lock) {
            Log.i(TAG, "callback available texture=" + id + " wid=" + wid + " surface=" + currentSurface);
            publishSurfaceLocked("available");
        }
    }

    @Override
    public void onSurfaceCleanup() {
        synchronized (lock) {
            Log.i(TAG, "callback cleanup texture=" + id + " wid=" + wid + " surface=" + currentSurface);
            retireSurfaceLocked();
        }
    }

    private void publishSurfaceLocked(String reason) {
        if (disposed || videoWidth <= 1 || videoHeight <= 1) return;
        final android.view.Surface surface;
        try {
            surface = surfaceProducer.getSurface();
        } catch (Throwable error) {
            Log.w(TAG, "getSurface failed", error);
            return;
        }
        if (surface == null || !surface.isValid()) return;
        if (currentSurface == surface && wid != 0) {
            Log.i(TAG, "publish unchanged reason=" + reason + " texture=" + id + " wid=" + wid + " valid=" + surface.isValid() + " surface=" + surface);
            return;
        }

        final long retired = wid;
        final long next = newGlobalObjectRef(surface);
        if (next == 0) return;
        retainedReferences.add(next);
        retainedSurfaces.put(next, surface);
        currentSurface = surface;
        wid = next;
        Log.i(TAG, String.format(Locale.ENGLISH,
                "surface %s texture=%d wid=%d retiredWid=%d buffer=%dx%d",
                reason, id, next, retired, videoWidth, videoHeight));
        textureUpdateCallback.onTextureUpdate(id, next, videoWidth, videoHeight, retired);
    }

    private void retireSurfaceLocked() {
        final long retired = wid;
        currentSurface = null;
        wid = 0;
        if (retired != 0) {
            Log.i(TAG, String.format(Locale.ENGLISH,
                    "surface retired texture=%d wid=%d", id, retired));
            textureUpdateCallback.onTextureUpdate(
                    id, 0, videoWidth, videoHeight, retired);
        }
    }

    private static long newGlobalObjectRef(Object object) {
        try {
            final Object value = NEW_GLOBAL_OBJECT_REF.invoke(null, object);
            return value instanceof Number ? ((Number) value).longValue() : 0;
        } catch (Throwable error) {
            Log.e(TAG, "newGlobalRef failed", error);
            return 0;
        }
    }

    private static void deleteGlobalObjectRef(long reference) {
        if (reference == 0) return;
        try {
            DELETE_GLOBAL_OBJECT_REF.invoke(null, reference);
        } catch (Throwable error) {
            Log.e(TAG, String.format(Locale.ENGLISH,
                    "deleteGlobalRef failed ref=%d", reference), error);
        }
    }
}
