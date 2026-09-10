import 'package:PiliPlus/services/audio_handler.dart';
import 'package:PiliPlus/services/audio_session.dart';

VideoPlayerServiceHandler? videoPlayerServiceHandler;
AudioSessionHandler? audioSessionHandler;

Future<void> setupServiceLocator() async {
  // AudioService initialization crosses the Android service boundary and may
  // be delayed while an OEM is restoring a process. Do not make the app's
  // first Flutter frame depend on it.
  audioSessionHandler ??= AudioSessionHandler();
  videoPlayerServiceHandler ??= await initAudioService();
}
