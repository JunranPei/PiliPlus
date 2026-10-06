/** This file is a part of media_kit (https://github.com/media-kit/media-kit). */
package com.alexmercerind.media_kit_video;

import android.util.Log;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;

import io.flutter.view.TextureRegistry;

/** Keeps one engine texture/output for each media player handle. */
public final class VideoOutputManager {
    private static final String TAG = "VideoOutputManager";
    private final HashMap<Long, VideoOutput> videoOutputs = new HashMap<>();
    private final List<VideoOutput> retiredOutputs = new ArrayList<>();
    private final TextureRegistry textureRegistry;
    private final Object lock = new Object();

    VideoOutputManager(TextureRegistry textureRegistry) {
        this.textureRegistry = textureRegistry;
    }

    public VideoOutput create(long handle, TextureUpdateCallback callback) {
        synchronized (lock) {
            VideoOutput output = videoOutputs.get(handle);
            if (output == null) {
                output = new VideoOutput(textureRegistry, callback);
                videoOutputs.put(handle, output);
                Log.i(TAG, String.format(Locale.ENGLISH, "create handle=%d texture=%d",
                        handle, output.id));
            }
            return output;
        }
    }

    public void dispose(long handle) {
        synchronized (lock) {
            final VideoOutput output = videoOutputs.remove(handle);
            if (output != null) {
                Log.i(TAG, String.format(Locale.ENGLISH, "dispose handle=%d", handle));
                output.dispose();
                if (!output.isFullyReleased()) {
                    retiredOutputs.add(output);
                }
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
            final VideoOutput output = videoOutputs.get(handle);
            if (output != null) output.setSurfaceSize(width, height);
            return output;
        }
    }

    public void resetSurfaceSize(long handle) {
        synchronized (lock) {
            final VideoOutput output = videoOutputs.get(handle);
            if (output != null) output.resetSurfaceSize();
        }
    }

    public boolean releaseSurfaceRef(long reference) {
        synchronized (lock) {
            boolean released = false;
            for (VideoOutput output : videoOutputs.values()) {
                released |= output.releaseSurfaceRef(reference);
            }
            for (VideoOutput output : new ArrayList<>(retiredOutputs)) {
                released |= output.releaseSurfaceRef(reference);
                if (output.isFullyReleased()) {
                    retiredOutputs.remove(output);
                }
            }
            return released;
        }
    }
}
