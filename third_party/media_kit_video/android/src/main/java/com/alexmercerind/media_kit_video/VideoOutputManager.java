/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 */
package com.alexmercerind.media_kit_video;

import android.content.Context;
import android.util.Log;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;

public class VideoOutputManager {
    private static final String TAG = "VideoOutputManager";

    private final HashMap<Long, VideoOutput> videoOutputs = new HashMap<>();
    private final List<VideoOutput> retiredOutputs = new ArrayList<>();
    private final Context applicationContext;
    private final Object lock = new Object();

    VideoOutputManager(Context applicationContext) {
        this.applicationContext = applicationContext.getApplicationContext();
    }

    public VideoOutput create(long handle, TextureUpdateCallback callback) {
        synchronized (lock) {
            Log.i(TAG, String.format(Locale.ENGLISH, "create handle=%d", handle));
            final VideoOutput existing = videoOutputs.get(handle);
            if (existing != null && !existing.isDisposed()) return existing;
            if (existing != null) retiredOutputs.add(existing);
            final VideoOutput output = new VideoOutput(applicationContext, handle, callback);
            videoOutputs.put(handle, output);
            return output;
        }
    }

    public VideoOutput get(long handle) {
        synchronized (lock) {
            return videoOutputs.get(handle);
        }
    }

    public void dispose(long handle) {
        synchronized (lock) {
            Log.i(TAG, String.format(Locale.ENGLISH, "dispose handle=%d", handle));
            final VideoOutput output = videoOutputs.get(handle);
            if (output != null) {
                output.dispose();
                if (output.isFullyReleased()) videoOutputs.remove(handle);
            }
        }
    }

    public long createSurface(long handle) {
        synchronized (lock) {
            final VideoOutput output = videoOutputs.get(handle);
            return output == null ? 0 : output.createSurface();
        }
    }

    public VideoOutput setSurfaceSize(long handle, int width, int height) {
        synchronized (lock) {
            Log.i(TAG, String.format(Locale.ENGLISH,
                    "setSurfaceSize handle=%d buffer=%dx%d", handle, width, height));
            final VideoOutput output = videoOutputs.get(handle);
            if (output != null) output.setSurfaceSize(width, height);
            return output;
        }
    }

    /** Called after Dart has set mpv vo=null and wid=0 for the retired ref. */
    public boolean releaseSurfaceRef(long reference) {
        synchronized (lock) {
            boolean released = false;
            for (VideoOutput output : new ArrayList<>(videoOutputs.values())) {
                released |= output.releaseSurfaceRef(reference);
                if (output.isFullyReleased() && videoOutputs.get(output.id) == output) {
                    videoOutputs.remove(output.id);
                }
            }
            for (VideoOutput output : new ArrayList<>(retiredOutputs)) {
                released |= output.releaseSurfaceRef(reference);
                if (output.isFullyReleased()) retiredOutputs.remove(output);
            }
            return released;
        }
    }
}
