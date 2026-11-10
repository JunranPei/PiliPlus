import 'dart:io';

import 'package:PiliPlus/utils/device_utils.dart';
import 'package:jni/jni.dart';

/// Samsung Android 16 AAudio can keep playing sound while its reported clock
/// stops after a seek. Keep that clock out of mpv's A/V synchronization path.
String audioOutputForAndroidDevice({
  required String configured,
  required String manufacturer,
  required int sdk,
}) {
  if (sdk != 36 || manufacturer.toLowerCase() != 'samsung') return configured;
  final outputs = configured.split(',');
  if (!outputs.contains('aaudio')) return configured;
  return [
    'audiotrack',
    ...outputs.where((o) => o != 'aaudio' && o != 'audiotrack'),
  ].join(',');
}

abstract final class AndroidAudioOutputPolicy {
  // Read once through JNI; do not add a platform-channel round trip to opening
  // videos or standby-player construction.
  static final String _manufacturer = _readManufacturer();

  static String _readManufacturer() {
    final build = JClass.forName('android/os/Build');
    try {
      final name = build
          .staticFieldId('MANUFACTURER', 'Ljava/lang/String;')
          .getNullable(build, JString.type);
      return name?.toDartString(releaseOriginal: true) ?? '';
    } finally {
      build.release();
    }
  }

  static String apply(String configured) {
    if (!Platform.isAndroid || DeviceUtils.sdkInt != 36) return configured;
    return audioOutputForAndroidDevice(
      configured: configured,
      manufacturer: _manufacturer,
      sdk: DeviceUtils.sdkInt,
    );
  }
}
