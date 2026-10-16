import 'package:PiliPlus/plugin/pl_player/media3_player.dart';
import 'package:get/get_rx/get_rx.dart';

class NativeConvertWebp {
  static int _nextId = 0;
  final int _id = ++_nextId;
  final String url;
  final String outFile;
  final double start;
  final double duration;
  final RxDouble? progress;
  final WebpPreset preset;

  NativeConvertWebp(
    this.url,
    this.outFile,
    this.start,
    double end, {
    this.progress,
    this.preset = WebpPreset.def,
  }) : duration = end - start;

  Future<bool> convert() => Media3Player.exportWebp(
    id: _id,
    url: url,
    outFile: outFile,
    start: start,
    duration: duration,
    preset: preset.flag,
    onProgress: (value) => progress?.value = value,
  );

  void dispose() {
    Media3Player.cancelExport(_id);
  }
}

enum WebpPreset {
  none('none', '无', '不使用预设'),
  def('default', '默认', '默认预设'),
  picture('picture', '图片', '数码照片，如人像、室内拍摄'),
  photo('photo', '照片', '户外摄影，自然光环境'),
  drawing('drawing', '绘图', '手绘或线稿，高对比度细节'),
  icon('icon', '图标', '小型彩色图像'),
  text('text', '文本', '文字类'),
  ;

  final String flag;
  final String name;
  final String desc;

  const WebpPreset(this.flag, this.name, this.desc);
}
