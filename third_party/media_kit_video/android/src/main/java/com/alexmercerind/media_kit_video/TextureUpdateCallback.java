package com.alexmercerind.media_kit_video;

/** Notifies Dart when Flutter replaces the SurfaceProducer's backing surface. */
public interface TextureUpdateCallback {
    void onTextureUpdate(long id, long wid, int width, int height);
}
