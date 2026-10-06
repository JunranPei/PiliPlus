/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import androidx.annotation.NonNull;
import android.util.Log;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Registers the native SurfaceProducer video output. */
public final class MediaKitVideoPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private VideoOutputManager videoOutputManager;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(),
                "com.alexmercerind/media_kit_video");
        channel.setMethodCallHandler(this);
        videoOutputManager = new VideoOutputManager(binding.getTextureRegistry());
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        Log.i("VideoOutputChannel", "receive method=" + call.method + " arguments=" + String.valueOf(call.arguments));
        if (videoOutputManager == null) {
            result.error("NOT_ATTACHED", "Video output manager is not attached", null);
            return;
        }
        try {
            switch (call.method) {
                case "VideoOutputManager.Create": {
                    final long handle = Long.parseLong(String.valueOf(call.<Object>argument("handle")));
                    final VideoOutput output = videoOutputManager.create(handle,
                            (id, wid, width, height, retiredWid) -> {
                                final HashMap<String, Object> data = new HashMap<>();
                                data.put("handle", handle);
                                data.put("id", id);
                                data.put("wid", wid);
                                data.put("retiredWid", retiredWid);
                                final HashMap<String, Object> rect = new HashMap<>();
                                rect.put("left", 0);
                                rect.put("top", 0);
                                rect.put("width", width);
                                rect.put("height", height);
                                data.put("rect", rect);
                                channel.invokeMethod("VideoOutput.Resize", data);
                            });
                    final HashMap<String, Long> data = new HashMap<>();
                    data.put("id", output.id);
                    result.success(data);
                    break;
                }
                case "VideoOutputManager.CreateSurface": {
                    final long handle = Long.parseLong(String.valueOf(call.<Object>argument("handle")));
                    final HashMap<String, Long> data = new HashMap<>();
                    data.put("wid", videoOutputManager.createSurface(handle));
                    result.success(data);
                    break;
                }
                case "VideoOutputManager.SetSurfaceSize":
                case "VideoOutputManager.SetSurfaceTextureSize": {
                    final long handle = Long.parseLong(String.valueOf(call.<Object>argument("handle")));
                    final int width = Integer.parseInt(String.valueOf(call.<Object>argument("width")));
                    final int height = Integer.parseInt(String.valueOf(call.<Object>argument("height")));
                    final VideoOutput output = videoOutputManager.setSurfaceSize(handle, width, height);
                    final HashMap<String, Long> data = new HashMap<>();
                    if (output != null) {
                        data.put("id", output.id);
                        data.put("wid", output.wid);
                    }
                    result.success(data);
                    break;
                }
                case "VideoOutputManager.ResetSurfaceSize": {
                    final long handle = Long.parseLong(String.valueOf(call.<Object>argument("handle")));
                    videoOutputManager.resetSurfaceSize(handle);
                    result.success(null);
                    break;
                }
                case "VideoOutputManager.ReleaseSurfaceRef": {
                    final Object rawReference = call.arguments instanceof Map
                            ? (((Map<?, ?>) call.arguments).containsKey("wid")
                            ? ((Map<?, ?>) call.arguments).get("wid")
                            : ((Map<?, ?>) call.arguments).get("ref"))
                            : call.arguments;
                    final long reference = Long.parseLong(String.valueOf(rawReference));
                    result.success(videoOutputManager.releaseSurfaceRef(reference));
                    break;
                }
                case "VideoOutputManager.Dispose": {
                    final long handle = Long.parseLong(String.valueOf(call.<Object>argument("handle")));
                    videoOutputManager.dispose(handle);
                    result.success(null);
                    break;
                }
                case "Utils.IsEmulator":
                    result.success(Utils.isEmulator());
                    break;
                default:
                    result.notImplemented();
                    break;
            }
        } catch (Throwable error) {
            Log.e("VideoOutputChannel", "failed method=" + call.method, error);
            result.error("VIDEO_OUTPUT", error.toString(), null);
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
        videoOutputManager = null;
    }
}
