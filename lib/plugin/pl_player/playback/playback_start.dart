/// Keep a delayed native play/presentation completion from reviving an old owner.
abstract final class PlaybackStart {
  static Future<bool> run({
    required bool Function() isCurrent,
    required bool Function() isPlaying,
    required Future<void> Function() start,
    required Future<void> Function() present,
    required void Function() activate,
  }) async {
    if (!isCurrent()) return false;
    // Finish the serialized native write before allowing a replacement source.
    await start();
    if (!isCurrent()) return false;
    await present();
    if (!isCurrent() || !isPlaying()) return false;
    activate();
    return true;
  }
}
