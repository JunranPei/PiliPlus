import 'package:PiliPlus/models/common/enum_with_label.dart';

enum AudioOutput implements EnumWithLabel {
  audiotrack('AudioTrack'),
  aaudio('AAudio'),
  opensles('OpenSL ES'),
  ;

  static final defaultValue = values.map((e) => e.name).join(',');

  @override
  final String label;
  const AudioOutput(this.label);
}
