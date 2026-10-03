/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.lang.reflect.Method;
import java.util.HashSet;
import java.util.Locale;
import java.util.Objects;

import io.flutter.view.TextureRegistry;

/**
 * Owns one Android SurfaceProducer and its current libmpv Surface reference.
 * SurfaceTextureEntry is deliberately not used here: a SurfaceProducer lets
 * Flutter replace the backing surface during a resize or PiP transition while
 * keeping the texture id stable.
 */
public class VideoOutput implements TextureRegistry.SurfaceProducer.Callback {
    private static final String TAG = "VideoOutput";
    private static final Method newGlobalObjectRef;
    private static final Method deleteGlobalObjectRef;
    private static final HashSet<Long> deletedGlobalObjectRefs = new HashSet<>();
    private static final Handler handler = new Handler(Looper.getMainLooper());

    static {
        try {
            final Class<?> helper = Class.forName(
                    "com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            newGlobalObjectRef = helper.getDeclaredMethod("newGlobalObjectRef", Object.class);
            deleteGlobalObjectRef = helper.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            newGlobalObjectRef.setAccessible(true);
            deleteGlobalObjectRef.setAccessible(true);
        } catch (Throwable e) {
            Log.i("media_kit", "package:media_kit_libs_android_video missing. Make sure you have added it to pubspec.yaml.");
            throw new RuntimeException("Failed to initialize com.alexmercerind.media_kit_video.VideoOutput.");
        }
    }

    /** Current Flutter texture id, kept public for the legacy Dart create response. */
    public long id = 0;
    /** Current global reference to the Android Surface passed to libmpv. */
    public long wid = 0;

    private final TextureUpdateCallback textureUpdateCallback;
    private final TextureRegistry.SurfaceProducer surfaceProducer;
    private final Object lock = new Object();

    VideoOutput(TextureRegistry textureRegistryReference,
                TextureUpdateCallback textureUpdateCallback) {
        this.textureUpdateCallback = textureUpdateCallback;
        surfaceProducer = textureRegistryReference.createSurfaceProducer();
        surfaceProducer.setCallback(this);
    }

    public void dispose() {
        synchronized (lock) {
            try {
                surfaceProducer.getSurface().release();
            } catch (Throwable e) {
                Log.e(TAG, "dispose surface", e);
            }
            try {
                surfaceProducer.release();
            } catch (Throwable e) {
                Log.e(TAG, "dispose producer", e);
            }
            onSurfaceCleanup();
        }
    }

    public void setSurfaceSize(int width, int height) {
        setSurfaceSize(width, height, false);
    }

    private void setSurfaceSize(int width, int height, boolean force) {
        synchronized (lock) {
            try {
                if (!force && surfaceProducer.getWidth() == width
                        && surfaceProducer.getHeight() == height) {
                    return;
                }
                surfaceProducer.setSize(width, height);
                // Some Flutter engine versions only deliver the callback on a
                // subsequent frame. Publish the new Surface synchronously so
                // Dart can update --wid before it re-attaches --vo=gpu.
                onSurfaceAvailable();
            } catch (Throwable e) {
                Log.e(TAG, "setSurfaceSize", e);
            }
        }
    }

    /** Legacy API used by media_kit_video 1.2.x. */
    public long createSurface() {
        synchronized (lock) {
            if (wid == 0) {
                onSurfaceAvailable();
            }
            return wid;
        }
    }

    @Override
    public void onSurfaceAvailable() {
        synchronized (lock) {
            Log.i(TAG, "onSurfaceAvailable");
            id = surfaceProducer.id();
            final long previousWid = wid;
            wid = newGlobalObjectRef(surfaceProducer.getSurface());
            if (previousWid != 0 && previousWid != wid) {
                final long staleWid = previousWid;
                handler.postDelayed(() -> deleteGlobalObjectRef(staleWid), 5000);
            }
            textureUpdateCallback.onTextureUpdate(
                    id, wid, surfaceProducer.getWidth(), surfaceProducer.getHeight());
        }
    }

    @Override
    public void onSurfaceCleanup() {
        synchronized (lock) {
            Log.i(TAG, "onSurfaceCleanup");
            textureUpdateCallback.onTextureUpdate(
                    id, 0, surfaceProducer.getWidth(), surfaceProducer.getHeight());
            if (wid != 0) {
                final long widReference = wid;
                wid = 0;
                handler.postDelayed(() -> deleteGlobalObjectRef(widReference), 5000);
            }
        }
    }

    private static long newGlobalObjectRef(Object object) {
        Log.i(TAG, String.format(Locale.ENGLISH, "newGlobalRef: object = %s", object));
        try {
            return (long) Objects.requireNonNull(newGlobalObjectRef.invoke(null, object));
        } catch (Throwable e) {
            Log.e(TAG, "newGlobalRef", e);
            return 0;
        }
    }

    private static void deleteGlobalObjectRef(long ref) {
        if (ref == 0) {
            return;
        }
        synchronized (deletedGlobalObjectRefs) {
            if (deletedGlobalObjectRefs.contains(ref)) {
                Log.i(TAG, String.format(Locale.ENGLISH,
                        "deleteGlobalObjectRef: ref = %d ALREADY DELETED", ref));
                return;
            }
            if (deletedGlobalObjectRefs.size() > 100) {
                deletedGlobalObjectRefs.clear();
            }
            deletedGlobalObjectRefs.add(ref);
        }
        Log.i(TAG, String.format(Locale.ENGLISH, "deleteGlobalObjectRef: ref = %d", ref));
        try {
            deleteGlobalObjectRef.invoke(null, ref);
        } catch (Throwable e) {
            Log.e(TAG, "deleteGlobalObjectRef", e);
        }
    }
}
