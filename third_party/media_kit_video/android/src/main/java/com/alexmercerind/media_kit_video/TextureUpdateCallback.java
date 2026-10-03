package com.alexmercerind.media_kit_video;

/** Notifies Dart when the native SurfaceView changes its backing Surface. */
public interface TextureUpdateCallback {
    void onTextureUpdate(long id, long wid, int width, int height, long retiredWid);
}
