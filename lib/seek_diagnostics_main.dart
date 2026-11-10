import 'package:PiliPlus/common/widgets/scale_app.dart';
import 'package:PiliPlus/plugin/pl_player/playback/seek_diagnostic_cli.dart';

import 'main.dart' as app;

void main() {
  ScaledWidgetsFlutterBinding.ensureInitialized();
  SeekDiagnosticCli.install();
  app.main();
}
