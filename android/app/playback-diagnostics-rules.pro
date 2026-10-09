# PlaybackTextureProbe only reads these members and attaches Flutter's optional
# consumption callback. Preserve names in opt-in release diagnostic builds.
-keepclassmembers class com.alexmercerind.media_kit_video.MediaKitVideoPlugin {
    *** videoOutputManager;
}
-keepclassmembers class com.alexmercerind.media_kit_video.VideoOutputManager {
    *** lock;
    *** videoOutputs;
}
-keepclassmembers class com.alexmercerind.media_kit_video.VideoOutput {
    *** surfaceTextureEntry;
    *** surface;
    long wid;
}
-keepclassmembers class io.flutter.embedding.engine.renderer.FlutterRenderer$SurfaceTextureRegistryEntry {
    *** frameConsumedListener;
}
