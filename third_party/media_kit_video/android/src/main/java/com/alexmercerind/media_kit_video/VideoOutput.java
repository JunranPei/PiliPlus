/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.content.Context;
import android.content.ContextWrapper;
import android.app.Activity;
import android.util.Log;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;

import java.lang.reflect.Method;
import java.util.HashSet;
import java.util.Locale;

import io.flutter.plugin.platform.PlatformView;

/**
 * Owns the one native SurfaceView used by both the normal Flutter layout and
 * Android PiP. Keeping one SurfaceView avoids switching libmpv between a
 * SurfaceProducer and a second PiP-only surface during a window transition.
 */
public class VideoOutput implements PlatformView {
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
        } catch (Throwable e) {
            Log.i(TAG, "package:media_kit_libs_android_video missing. Make sure it is in pubspec.yaml.", e);
            throw new RuntimeException("Failed to initialize the media_kit Android JNI helper.", e);
        }
    }

    /** A stable sentinel accepted by the existing Dart controller. */
    public final long id;

    /** Current global reference passed to libmpv, or zero before mount. */
    public long wid = 0;

    private final TextureUpdateCallback textureUpdateCallback;
    private final SurfaceView surfaceView;
    private final SurfaceHolder.Callback surfaceCallback;
    private final Object lock = new Object();
    private final HashSet<Long> retainedReferences = new HashSet<>();
    private Surface currentSurface;
    private Activity activity;
    private View decorView;
    private View.OnLayoutChangeListener windowLayoutListener;
    private int windowWidth;
    private int windowHeight;
    private int videoWidth = 1;
    private int videoHeight = 1;
    private boolean disposed = false;

    VideoOutput(Context applicationContext, long handle, TextureUpdateCallback textureUpdateCallback) {
        this.id = handle;
        this.textureUpdateCallback = textureUpdateCallback;
        final Context context = applicationContext.getApplicationContext();
        surfaceView = new SurfaceView(context);
        surfaceView.setFocusable(false);
        surfaceView.setClickable(false);
        surfaceView.addOnAttachStateChangeListener(new android.view.View.OnAttachStateChangeListener() {
            @Override
            public void onViewAttachedToWindow(android.view.View view) {
                Log.i(TAG, String.format(Locale.ENGLISH,
                        "view attached handle=%d size=%dx%d measured=%dx%d",
                        id, view.getWidth(), view.getHeight(), view.getMeasuredWidth(), view.getMeasuredHeight()));
            }

            @Override
            public void onViewDetachedFromWindow(android.view.View view) {
                Log.i(TAG, String.format(Locale.ENGLISH,
                        "view detached handle=%d size=%dx%d measured=%dx%d",
                        id, view.getWidth(), view.getHeight(), view.getMeasuredWidth(), view.getMeasuredHeight()));
            }
        });
        surfaceView.addOnLayoutChangeListener((view, left, top, right, bottom,
                oldLeft, oldTop, oldRight, oldBottom) -> {
            synchronized (lock) {
                final android.graphics.Rect frame = surfaceView.getHolder().getSurfaceFrame();
                Log.i(TAG, String.format(Locale.ENGLISH,
                        "layout handle=%d new=%dx%d@(%d,%d) old=%dx%d@(%d,%d) " +
                                "measured=%dx%d frame=%dx%d fixed=%dx%d wid=%d surface=%d",
                        id,
                        right - left, bottom - top, left, top,
                        oldRight - oldLeft, oldBottom - oldTop, oldLeft, oldTop,
                        view.getMeasuredWidth(), view.getMeasuredHeight(),
                        frame.width(), frame.height(), videoWidth, videoHeight,
                        wid, currentSurface == null ? 0 : System.identityHashCode(currentSurface)));
                applyWindowScaleLocked();
            }
        });
        surfaceCallback = new SurfaceHolder.Callback() {
            @Override
            public void surfaceCreated(SurfaceHolder holder) {
                synchronized (lock) {
                    final android.graphics.Rect frame = holder.getSurfaceFrame();
                    Log.i(TAG, String.format(Locale.ENGLISH,
                            "surfaceCreated handle=%d callbackFrame=%dx%d fixed=%dx%d surface=%d",
                            id, frame.width(), frame.height(), videoWidth, videoHeight,
                            System.identityHashCode(holder.getSurface())));
                    attachSurfaceLocked(holder.getSurface(), frame.width(), frame.height(), "created");
                }
            }

            @Override
            public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
                synchronized (lock) {
                    final android.graphics.Rect frame = holder.getSurfaceFrame();
                    final int actualWidth = width > 0 ? width : frame.width();
                    final int actualHeight = height > 0 ? height : frame.height();
                    Log.i(TAG, String.format(Locale.ENGLISH,
                            "surfaceChanged handle=%d callback=%dx%d frame=%dx%d fixed=%dx%d " +
                                    "view=%dx%d surface=%d wid=%d",
                            id, width, height, frame.width(), frame.height(), videoWidth, videoHeight,
                            surfaceView.getWidth(), surfaceView.getHeight(),
                            System.identityHashCode(holder.getSurface()), wid));
                    attachSurfaceLocked(holder.getSurface(), actualWidth, actualHeight, "changed");
                }
            }

            @Override
            public void surfaceDestroyed(SurfaceHolder holder) {
                synchronized (lock) {
                    final long retired = wid;
                    currentSurface = null;
                    wid = 0;
                    if (retired != 0) {
                        Log.i(TAG, String.format(Locale.ENGLISH,
                                "surface destroyed handle=%d retiredWid=%d", id, retired));
                    }
                    notifyTextureUpdateLocked(0, actualBufferWidthLocked(), actualBufferHeightLocked(), retired);
                }
            }
        };
        surfaceView.getHolder().addCallback(surfaceCallback);
        Log.i(TAG, String.format(Locale.ENGLISH, "created handle=%d", id));
    }

    @Override
    public android.view.View getView() {
        return surfaceView;
    }

    /** Attach to the Activity window so PiP scaling is applied before Flutter's next frame. */
    public void attachWindowContext(Context context) {
        synchronized (lock) {
            Activity next = findActivity(context);
            if (next == activity && decorView != null) return;
            detachWindowListenerLocked();
            activity = next;
            if (activity == null) return;
            decorView = activity.getWindow().getDecorView();
            windowLayoutListener = (view, left, top, right, bottom,
                    oldLeft, oldTop, oldRight, oldBottom) -> {
                synchronized (lock) {
                    windowWidth = right - left;
                    windowHeight = bottom - top;
                    Log.i(TAG, String.format(Locale.ENGLISH,
                            "window layout handle=%d new=%dx%d old=%dx%d inPip=%s view=%dx%d",
                            id, windowWidth, windowHeight,
                            oldRight - oldLeft, oldBottom - oldTop,
                            activity.isInPictureInPictureMode(),
                            surfaceView.getWidth(), surfaceView.getHeight()));
                    applyWindowScaleLocked();
                }
            };
            decorView.addOnLayoutChangeListener(windowLayoutListener);
            windowWidth = decorView.getWidth();
            windowHeight = decorView.getHeight();
            applyWindowScaleLocked();
        }
    }

    /** Update the fixed video buffer size while allowing the view to resize. */
    public void setSurfaceSize(int width, int height) {
        synchronized (lock) {
            videoWidth = Math.max(1, width);
            videoHeight = Math.max(1, height);
            final android.graphics.Rect frame = surfaceView.getHolder().getSurfaceFrame();
            Log.i(TAG, String.format(Locale.ENGLISH,
                    "setFixedSize handle=%d requested=%dx%d view=%dx%d frame=%dx%d wid=%d",
                    id, videoWidth, videoHeight, surfaceView.getWidth(), surfaceView.getHeight(),
                    frame.width(), frame.height(), wid));
            try {
                surfaceView.getHolder().setFixedSize(videoWidth, videoHeight);
            } catch (Throwable error) {
                Log.w(TAG, "setFixedSize failed", error);
            }
        }
    }

    /** Returns the current Surface reference, or zero before PlatformView mount. */
    public long createSurface() {
        synchronized (lock) {
            return wid;
        }
    }

    /** Called by VideoOutputManager.Dispose and PlatformView.dispose. */
    @Override
    public void dispose() {
        synchronized (lock) {
            if (disposed) return;
            disposed = true;
            final long retired = wid;
            currentSurface = null;
            wid = 0;
            if (retired != 0) {
                Log.i(TAG, String.format(Locale.ENGLISH,
                        "dispose handle=%d retiredWid=%d", id, retired));
                notifyTextureUpdateLocked(0, actualBufferWidthLocked(), actualBufferHeightLocked(), retired);
            }
            // A PlatformView can be removed and recreated while Flutter is
            // changing routes or PiP constraints.  SurfaceView's SurfaceControl
            // teardown is asynchronous; hide the old view immediately so its
            // previous full-window layer cannot remain visible underneath the
            // replacement native view for a frame (or longer).
            surfaceView.setVisibility(View.GONE);
            surfaceView.setAlpha(0f);
            surfaceView.getHolder().removeCallback(surfaceCallback);
            detachWindowListenerLocked();
        }
    }

    public boolean isDisposed() {
        synchronized (lock) {
            return disposed;
        }
    }

    /** True only after Dart has acknowledged every retired JNI reference. */
    public boolean isFullyReleased() {
        synchronized (lock) {
            return disposed && retainedReferences.isEmpty() && wid == 0;
        }
    }

    /**
     * Release a reference only after Dart has synchronously set mpv vo=null
     * and wid=0. There is intentionally no timer here.
     */
    public boolean releaseSurfaceRef(long reference) {
        synchronized (lock) {
            if (reference == 0 || reference == wid || !retainedReferences.remove(reference)) {
                return false;
            }
            deleteGlobalObjectRef(reference);
            Log.i(TAG, String.format(Locale.ENGLISH,
                    "released handle=%d wid=%d remaining=%d", id, reference, retainedReferences.size()));
            return true;
        }
    }

    private void attachSurfaceLocked(Surface surface, int width, int height, String reason) {
        if (disposed || surface == null || !surface.isValid()) return;
        // Do not attach the full Activity-sized buffer before mpv has
        // published the video's dimensions.  SetSurfaceSize will trigger the
        // first attach with the fixed video buffer; this avoids an initial
        // full-window output followed by a second resize.
        if (videoWidth <= 1 || videoHeight <= 1) {
            Log.d(TAG, "surface " + reason + " waiting for video size handle=" + id);
            return;
        }
        if (currentSurface == surface && wid != 0) {
            // SurfaceHolder reports the current SurfaceView/window size here.
            // During a PiP transition that value briefly becomes the expanding
            // Activity window. It is not the video buffer size and must never
            // be sent to mpv or Dart as a new video rectangle.
            return;
        }

        final long retired = wid;
        final long next = newGlobalObjectRef(surface);
        if (next == 0) return;
        retainedReferences.add(next);
        currentSurface = surface;
        wid = next;
        Log.i(TAG, String.format(Locale.ENGLISH,
                "surface %s handle=%d wid=%d retiredWid=%d buffer=%dx%d",
                reason, id, next, retired, videoWidth, videoHeight));
        // SetSurfaceSize is authoritative. The holder callback dimensions are
        // deliberately ignored because they describe the resizable view, not
        // the fixed video buffer.
        notifyTextureUpdateLocked(next, videoWidth, videoHeight, retired);
    }

    private int actualBufferWidthLocked() {
        final android.graphics.Rect frame = surfaceView.getHolder().getSurfaceFrame();
        return frame.width() > 0 ? frame.width() : videoWidth;
    }

    private int actualBufferHeightLocked() {
        final android.graphics.Rect frame = surfaceView.getHolder().getSurfaceFrame();
        return frame.height() > 0 ? frame.height() : videoHeight;
    }

    private void applyWindowScaleLocked() {
        // Flutter's hybrid-composition platform-view wrapper owns the native
        // view bounds.  Applying a second transform here races that layout:
        // the decor callback can still contain the old full-window bounds when
        // PiP has already been entered, producing a left/top-origin jump.  We
        // only observe the two geometries for diagnostics and leave all
        // positioning to the single Flutter layout pass.
        if (surfaceView.getWidth() <= 0 || surfaceView.getHeight() <= 0 ||
                windowWidth <= 0 || windowHeight <= 0) return;
        Log.i(TAG, String.format(Locale.ENGLISH,
                "window geometry handle=%d window=%dx%d view=%dx%d scaleX=%.4f scaleY=%.4f",
                id, windowWidth, windowHeight, surfaceView.getWidth(), surfaceView.getHeight(),
                surfaceView.getScaleX(), surfaceView.getScaleY()));
    }

    private void detachWindowListenerLocked() {
        if (decorView != null && windowLayoutListener != null) {
            decorView.removeOnLayoutChangeListener(windowLayoutListener);
        }
        decorView = null;
        windowLayoutListener = null;
        activity = null;
        windowWidth = 0;
        windowHeight = 0;
    }

    private static Activity findActivity(Context context) {
        Context current = context;
        while (current instanceof ContextWrapper) {
            if (current instanceof Activity) return (Activity) current;
            final Context base = ((ContextWrapper) current).getBaseContext();
            if (base == current) break;
            current = base;
        }
        return current instanceof Activity ? (Activity) current : null;
    }

    private void notifyTextureUpdateLocked(long nextWid, int width, int height, long retiredWid) {
        textureUpdateCallback.onTextureUpdate(id, nextWid, width, height, retiredWid);
    }

    private static long newGlobalObjectRef(Object object) {
        try {
            final Object value = NEW_GLOBAL_OBJECT_REF.invoke(null, object);
            return value instanceof Number ? ((Number) value).longValue() : 0;
        } catch (Throwable e) {
            Log.e(TAG, "newGlobalRef failed", e);
            return 0;
        }
    }

    private static void deleteGlobalObjectRef(long reference) {
        if (reference == 0) return;
        try {
            DELETE_GLOBAL_OBJECT_REF.invoke(null, reference);
        } catch (Throwable e) {
            Log.e(TAG, String.format(Locale.ENGLISH,
                    "deleteGlobalRef failed ref=%d", reference), e);
        }
    }
}
