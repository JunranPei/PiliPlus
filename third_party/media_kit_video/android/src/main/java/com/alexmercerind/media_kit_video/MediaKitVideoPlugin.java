/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 *
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import androidx.annotation.NonNull;

import java.util.HashMap;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/** MediaKitVideoPlugin. */
public class MediaKitVideoPlugin implements FlutterPlugin, MethodCallHandler {
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
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        if (videoOutputManager == null) {
            result.error("NOT_ATTACHED", "Video output manager is not attached", null);
            return;
        }
        try {
            switch (call.method) {
                case "VideoOutputManager.Create": {
                    final long handle = Long.parseLong(String.valueOf(call.argument("handle")));
                    final VideoOutput output = videoOutputManager.create(handle,
                            (id, wid, width, height) -> {
                                final HashMap<String, Object> data = new HashMap<>();
                                data.put("handle", handle);
                                data.put("id", id);
                                data.put("wid", wid);
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
                // Kept for the 1.2.x Dart controller.  SurfaceProducer already
                // owns the Surface; this returns its current global reference.
                case "VideoOutputManager.CreateSurface": {
                    final long handle = Long.parseLong(String.valueOf(call.argument("handle")));
                    final HashMap<String, Long> data = new HashMap<>();
                    data.put("wid", videoOutputManager.createSurface(handle));
                    result.success(data);
                    break;
                }
                case "VideoOutputManager.SetSurfaceSize":
                case "VideoOutputManager.SetSurfaceTextureSize": {
                    final long handle = Long.parseLong(String.valueOf(call.argument("handle")));
                    final int width = Integer.parseInt(String.valueOf(call.argument("width")));
                    final int height = Integer.parseInt(String.valueOf(call.argument("height")));
                    final VideoOutput output = videoOutputManager.setSurfaceSize(handle, width, height);
                    final HashMap<String, Long> data = new HashMap<>();
                    if (output != null) {
                        data.put("id", output.id);
                        data.put("wid", output.wid);
                    }
                    result.success(data);
                    break;
                }
                case "VideoOutputManager.Dispose": {
                    final long handle = Long.parseLong(String.valueOf(call.argument("handle")));
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
        } catch (Throwable e) {
            result.error("VIDEO_OUTPUT", e.toString(), null);
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) {
            channel.setMethodCallHandler(null);
        }
        channel = null;
        videoOutputManager = null;
    }
}
