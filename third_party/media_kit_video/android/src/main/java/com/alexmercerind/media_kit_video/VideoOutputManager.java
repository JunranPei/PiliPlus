/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 */
package com.alexmercerind.media_kit_video;

import android.util.Log;

import java.util.HashMap;
import java.util.Locale;
import java.util.Objects;

import io.flutter.view.TextureRegistry;

public class VideoOutputManager {
    private static final String TAG = "VideoOutputManager";

    private final HashMap<Long, VideoOutput> videoOutputs = new HashMap<>();
    private final TextureRegistry textureRegistryReference;
    private final Object lock = new Object();

    VideoOutputManager(TextureRegistry textureRegistryReference) {
        this.textureRegistryReference = textureRegistryReference;
    }

    public VideoOutput create(long handle, TextureUpdateCallback callback) {
        synchronized (lock) {
            Log.i(TAG, String.format(Locale.ENGLISH,
                    "com.alexmercerind.media_kit_video.VideoOutputManager.create: %d", handle));
            if (!videoOutputs.containsKey(handle)) {
                videoOutputs.put(handle, new VideoOutput(textureRegistryReference, callback));
            }
            return videoOutputs.get(handle);
        }
    }

    public VideoOutput get(long handle) {
        synchronized (lock) {
            return videoOutputs.get(handle);
        }
    }

    public void dispose(long handle) {
        synchronized (lock) {
            Log.i(TAG, String.format(Locale.ENGLISH,
                    "com.alexmercerind.media_kit_video.VideoOutputManager.dispose: %d", handle));
            if (videoOutputs.containsKey(handle)) {
                Objects.requireNonNull(videoOutputs.get(handle)).dispose();
                videoOutputs.remove(handle);
            }
        }
    }

    public long createSurface(long handle) {
        synchronized (lock) {
            final VideoOutput output = videoOutputs.get(handle);
            return output == null ? 0 : output.createSurface();
        }
    }

    public void setSurfaceSize(long handle, int width, int height) {
        synchronized (lock) {
            Log.i(TAG, String.format(Locale.ENGLISH,
                    "com.alexmercerind.media_kit_video.VideoOutputManager.setSurfaceSize: %d %d %d",
                    handle, width, height));
            final VideoOutput output = videoOutputs.get(handle);
            if (output != null) {
                output.setSurfaceSize(width, height);
            }
        }
    }
}
