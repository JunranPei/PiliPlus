import 'package:PiliPlus/plugin/pl_player/playback/android_audio_output_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const startup = 'aaudio,audiotrack,opensles';
  test('Samsung Android 16 and later bypass the stalled AAudio clock', () {
    expect(
      audioOutputForAndroidDevice(
        configured: startup,
        manufacturer: 'samsung',
        sdk: 36,
      ),
      'audiotrack,opensles',
    );
    expect(
      audioOutputForAndroidDevice(
        configured: 'aaudio',
        manufacturer: 'Samsung',
        sdk: 36,
      ),
      'audiotrack',
    );
    for (final sdk in [37, 38]) {
      expect(
        audioOutputForAndroidDevice(
          configured: startup,
          manufacturer: 'samsung',
          sdk: sdk,
        ),
        'audiotrack,opensles',
      );
    }
  });
  test(
    'other devices and earlier Android retain the startup backend order',
    () {
      expect(
        audioOutputForAndroidDevice(
          configured: startup,
          manufacturer: 'samsung',
          sdk: 35,
        ),
        startup,
      );
      expect(
        audioOutputForAndroidDevice(
          configured: startup,
          manufacturer: 'Google',
          sdk: 36,
        ),
        startup,
      );
      expect(
        audioOutputForAndroidDevice(
          configured: startup,
          manufacturer: 'OnePlus',
          sdk: 36,
        ),
        startup,
      );
    },
  );
  test('explicit outputs without AAudio are preserved', () {
    for (final value in [
      'opensles',
      'audiotrack',
      'null',
      'opensles,audiotrack',
    ]) {
      expect(
        audioOutputForAndroidDevice(
          configured: value,
          manufacturer: 'samsung',
          sdk: 36,
        ),
        value,
      );
    }
  });
}
